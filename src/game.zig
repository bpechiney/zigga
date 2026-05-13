//! Game-owned lifetime state and outer frame loop.

const std = @import("std");
const rl = @import("raylib");

const audio_mod = @import("audio.zig");
const math = @import("math.zig");
const shake_mod = @import("shake.zig");
const systems = @import("systems.zig");
const world_mod = @import("world.zig");

const Vec2 = math.Vec2;

pub const sim_dt: f32 = world_mod.sim_dt;
pub const Audio = audio_mod.Audio;
pub const Shake = shake_mod.Shake;

const max_ticks_per_frame: u32 = 5;
const player_size: f32 = 16.0;
const formation_top: f32 = 120.0;
const formation_cols: u32 = 4;
const formation_rows: u32 = 3;
const formation_spacing_x: f32 = 80;
const formation_spacing_y: f32 = 60;
const fire_cooldown_ticks_default: u8 = 8;

/// Owns allocator-backed runtime state. Non-copyable after init; keep it behind
/// a single `*Game` and call `deinit` exactly once.
pub const Game = struct {
    gpa: std.mem.Allocator,
    frame_arena: std.heap.ArenaAllocator,
    perm_arena: std.heap.ArenaAllocator,
    sim_prng: *std.Random.DefaultPrng,
    shake_prng: *std.Random.DefaultPrng,
    world: world_mod.World,
    input: world_mod.Input,
    accumulator: f32,
    audio: Audio,
    shake: Shake,
    fire_cooldown: u8,
    window_w: i32,
    window_h: i32,

    pub fn init(
        self: *Game,
        gpa: std.mem.Allocator,
        caps: world_mod.WorldCaps,
        window_w: i32,
        window_h: i32,
        seed: u64,
    ) !void {
        self.gpa = gpa;
        self.frame_arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.frame_arena.deinit();
        self.perm_arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.perm_arena.deinit();

        self.sim_prng = try gpa.create(std.Random.DefaultPrng);
        errdefer gpa.destroy(self.sim_prng);
        self.sim_prng.* = std.Random.DefaultPrng.init(seed);

        self.shake_prng = try gpa.create(std.Random.DefaultPrng);
        errdefer gpa.destroy(self.shake_prng);
        self.shake_prng.* = std.Random.DefaultPrng.init(seed +% 0x9E37_79B9_7F4A_7C15);

        const bounds: world_mod.Bounds = .{
            .width = @floatFromInt(window_w),
            .height = @floatFromInt(window_h),
        };
        self.world = try world_mod.World.init(gpa, caps, bounds, self.sim_prng);
        errdefer self.world.deinit(gpa);

        self.world.player.pos = .{
            .x = bounds.width * 0.5,
            .y = bounds.height * 0.875,
        };
        seedFormation(&self.world, window_w);

        self.input = world_mod.Input.zero;
        self.accumulator = 0;
        self.audio.init();
        self.shake = Shake.init(self.shake_prng);
        self.fire_cooldown = 0;
        self.window_w = window_w;
        self.window_h = window_h;
    }

    pub fn deinit(self: *Game) void {
        self.audio.deinit();
        self.world.deinit(self.gpa);
        self.gpa.destroy(self.shake_prng);
        self.gpa.destroy(self.sim_prng);
        self.perm_arena.deinit();
        self.frame_arena.deinit();
        self.* = undefined;
    }

    pub fn frame(self: *Game) void {
        _ = self.frame_arena.reset(.retain_capacity);
        self.input = pollInput();
        const frame_dt = rl.getFrameTime();
        self.runSimTicks(self.input, frame_dt);
        systems.updateParticles(&self.world, frame_dt);
        self.shake.update(frame_dt);
        // audio.flush runs once per frame — multiple sim ticks accumulate into
        // one drain so a 4-tick frame's coalesce events still merge to one play.
        _ = self.audio.flush();
        self.draw();
    }

    fn runSimTicks(self: *Game, input: world_mod.Input, frame_dt: f32) void {
        const dt = std.math.clamp(frame_dt, 0, sim_dt * max_ticks_per_frame);
        self.accumulator += dt;
        var ticks: u32 = 0;
        while (self.accumulator >= sim_dt and ticks < max_ticks_per_frame) {
            const gated = self.gateInput(input);
            systems.simTick(&self.world, &self.audio, &self.shake, gated, sim_dt);
            self.accumulator -= sim_dt;
            ticks += 1;
            if (self.fire_cooldown > 0) self.fire_cooldown -= 1;
        }
        if (ticks == max_ticks_per_frame) self.accumulator = 0;
    }

    fn gateInput(self: *Game, input: world_mod.Input) world_mod.Input {
        var gated = input;
        if (gated.fire) {
            if (self.fire_cooldown > 0) {
                gated.fire = false;
            } else {
                self.fire_cooldown = fire_cooldown_ticks_default;
            }
        }
        return gated;
    }

    fn draw(self: *Game) void {
        // shake.offset() is called only here — the sim never observes shake.
        const off = self.shake.offset();
        const camera: rl.Camera2D = .{
            .offset = .{ .x = off.x, .y = off.y },
            .target = .{ .x = 0, .y = 0 },
            .rotation = 0,
            .zoom = 1,
        };

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(rl.Color.black);

        camera.begin();
        defer camera.end();

        drawEnemies(&self.world);
        drawBullets(&self.world);
        drawEnemyBullets(&self.world);
        drawParticles(&self.world);
        drawPlayer(&self.world);
    }
};

fn seedFormation(world: *world_mod.World, window_w: i32) void {
    const w: f32 = @floatFromInt(window_w);
    const formation_width = @as(f32, @floatFromInt(formation_cols - 1)) * formation_spacing_x;
    const top_left: Vec2 = .{
        .x = (w - formation_width) * 0.5,
        .y = formation_top,
    };
    world.spawnFormation(top_left, formation_cols, formation_rows, .{
        .x = formation_spacing_x,
        .y = formation_spacing_y,
    });
}

fn pollInput() world_mod.Input {
    var thrust = Vec2.zero;
    if (rl.isKeyDown(.w)) thrust.y -= 1;
    if (rl.isKeyDown(.s)) thrust.y += 1;
    if (rl.isKeyDown(.a)) thrust.x -= 1;
    if (rl.isKeyDown(.d)) thrust.x += 1;
    return .{ .thrust = thrust, .fire = rl.isKeyDown(.space) };
}

fn drawPlayer(world: *const world_mod.World) void {
    if (world.player.dead) return;
    const pos = world.player.pos;
    rl.drawTriangle(
        .{ .x = pos.x, .y = pos.y - player_size },
        .{ .x = pos.x - player_size, .y = pos.y + player_size },
        .{ .x = pos.x + player_size, .y = pos.y + player_size },
        rl.Color.white,
    );
}

fn drawBullets(world: *const world_mod.World) void {
    var iter = world.bullets.iter();
    while (iter.next()) |index| {
        const b = world.bullets.rows.get(index);
        rl.drawCircleV(.{ .x = b.pos.x, .y = b.pos.y }, 3, rl.Color.yellow);
    }
}

fn drawEnemyBullets(world: *const world_mod.World) void {
    var iter = world.enemy_bullets.iter();
    while (iter.next()) |index| {
        const b = world.enemy_bullets.rows.get(index);
        rl.drawCircleV(.{ .x = b.pos.x, .y = b.pos.y }, 3, rl.Color.red);
    }
}

fn drawEnemies(world: *const world_mod.World) void {
    var iter = world.enemies.iter();
    while (iter.next()) |index| {
        const e = world.enemies.rows.get(index);
        const color: rl.Color = switch (e.kind) {
            .grunt => rl.Color.sky_blue,
            .zako => rl.Color.lime,
            .goei => rl.Color.purple,
        };
        rl.drawPoly(.{ .x = e.pos.x, .y = e.pos.y }, 6, 12, 0, color);
    }
}

fn drawParticles(world: *const world_mod.World) void {
    var iter = world.particles.iter();
    while (iter.next()) |index| {
        const p = world.particles.rows.get(index);
        const color = rl.Color.init(p.color_r, p.color_g, p.color_b, p.color_a);
        rl.drawCircleV(.{ .x = p.pos.x, .y = p.pos.y }, p.size, color);
    }
}

test "runSimTicks caps catch-up after a large frame stall" {
    var game: Game = undefined;
    try game.init(std.testing.allocator, .{}, 800, 600, 123);
    defer game.deinit();

    const before = game.world.player.pos.x;
    game.runSimTicks(.{ .thrust = .{ .x = 1, .y = 0 }, .fire = false }, 1);

    try std.testing.expect(game.accumulator < sim_dt);
    const expected = before + max_ticks_per_frame * 300 * sim_dt;
    try std.testing.expectApproxEqAbs(expected, game.world.player.pos.x, 0.000_001);
}

test "Game init cleans up after allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initGameForFailureTest, .{});
}

fn initGameForFailureTest(allocator: std.mem.Allocator) !void {
    var game: Game = undefined;
    try game.init(allocator, .{}, 800, 600, 123);
    game.deinit();
}

test "fire cooldown gates bullets to one per cooldown window" {
    var game: Game = undefined;
    try game.init(std.testing.allocator, .{}, 800, 600, 99);
    defer game.deinit();

    const start_len = game.world.bullets.len();
    const input: world_mod.Input = .{ .thrust = Vec2.zero, .fire = true };
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        const gated = game.gateInput(input);
        systems.simTick(&game.world, &game.audio, &game.shake, gated, sim_dt);
        if (game.fire_cooldown > 0) game.fire_cooldown -= 1;
    }
    try std.testing.expectEqual(start_len + 1, game.world.bullets.len());
}
