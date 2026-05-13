//! Game-owned lifetime state and outer frame loop.

const std = @import("std");
const rl = @import("raylib");

const math = @import("math.zig");
const world_mod = @import("world.zig");

const Vec2 = math.Vec2;

pub const sim_dt: f32 = 1.0 / 60.0;
const max_ticks_per_frame: u32 = 5;
const player_size: f32 = 20.0;

pub const Audio = struct {};
pub const Shake = struct {};

pub const Game = struct {
    gpa: std.mem.Allocator,
    frame_arena: std.heap.ArenaAllocator,
    perm_arena: std.heap.ArenaAllocator,
    sim_prng: std.Random.DefaultPrng,
    shake_prng: std.Random.DefaultPrng,
    world: world_mod.World,
    input: world_mod.Input,
    accumulator: f32,
    audio: Audio,
    shake: Shake,

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

        self.sim_prng = std.Random.DefaultPrng.init(seed);
        self.shake_prng = std.Random.DefaultPrng.init(seed +% 0x9E37_79B9_7F4A_7C15);
        self.world = try world_mod.World.init(gpa, caps, &self.sim_prng);
        errdefer self.world.deinit(gpa);

        self.world.player.pos = .{
            .x = @as(f32, @floatFromInt(window_w)) * 0.5,
            .y = @as(f32, @floatFromInt(window_h)) * 0.875,
        };
        self.input = world_mod.Input.zero;
        self.accumulator = 0;
        self.audio = .{};
        self.shake = .{};
    }

    pub fn deinit(self: *Game) void {
        self.world.deinit(self.gpa);
        self.perm_arena.deinit();
        self.frame_arena.deinit();
        self.* = undefined;
    }

    pub fn frame(self: *Game) void {
        _ = self.frame_arena.reset(.retain_capacity);
        self.input = pollInput();
        const dt = std.math.clamp(rl.getFrameTime(), 0, sim_dt * max_ticks_per_frame);
        self.accumulator += dt;

        var ticks: u32 = 0;
        while (self.accumulator >= sim_dt and ticks < max_ticks_per_frame) {
            self.world.simTick(self.input, sim_dt);
            self.accumulator -= sim_dt;
            ticks += 1;
        }
        if (ticks == max_ticks_per_frame) self.accumulator = 0;

        drawWorld(&self.world);
    }
};

fn pollInput() world_mod.Input {
    var thrust = Vec2.zero;
    if (rl.isKeyDown(.w)) thrust.y -= 1;
    if (rl.isKeyDown(.s)) thrust.y += 1;
    if (rl.isKeyDown(.a)) thrust.x -= 1;
    if (rl.isKeyDown(.d)) thrust.x += 1;
    return .{ .thrust = thrust, .fire = false };
}

fn drawWorld(world: *const world_mod.World) void {
    const pos = world.player.pos;

    rl.beginDrawing();
    defer rl.endDrawing();
    rl.clearBackground(rl.Color.black);
    rl.drawTriangle(
        .{ .x = pos.x, .y = pos.y - player_size },
        .{ .x = pos.x - player_size, .y = pos.y + player_size },
        .{ .x = pos.x + player_size, .y = pos.y + player_size },
        rl.Color.white,
    );
}
