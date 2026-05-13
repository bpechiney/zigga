//! Game-owned lifetime state and outer frame loop.

const std = @import("std");
const rl = @import("raylib");

const math = @import("math.zig");
const world_mod = @import("world.zig");

const Vec2 = math.Vec2;

pub const sim_dt: f32 = world_mod.sim_dt;
const max_ticks_per_frame: u32 = 5;
const player_size: f32 = 20.0;

pub const Audio = struct {};
pub const Shake = struct {};

/// Owns allocator-backed runtime state. Non-copyable after init; keep it behind
/// a single `*Game` and call `deinit` exactly once.
pub const Game = struct {
    gpa: std.mem.Allocator,
    // Present from the first milestone to pin allocator ownership boundaries.
    frame_arena: std.heap.ArenaAllocator,
    perm_arena: std.heap.ArenaAllocator,
    sim_prng: *std.Random.DefaultPrng,
    shake_prng: *std.Random.DefaultPrng,
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

        self.sim_prng = try gpa.create(std.Random.DefaultPrng);
        errdefer gpa.destroy(self.sim_prng);
        self.sim_prng.* = std.Random.DefaultPrng.init(seed);

        self.shake_prng = try gpa.create(std.Random.DefaultPrng);
        errdefer gpa.destroy(self.shake_prng);
        self.shake_prng.* = std.Random.DefaultPrng.init(seed +% 0x9E37_79B9_7F4A_7C15);

        self.world = try world_mod.World.init(gpa, caps, self.sim_prng);
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
        self.gpa.destroy(self.shake_prng);
        self.gpa.destroy(self.sim_prng);
        self.perm_arena.deinit();
        self.frame_arena.deinit();
        self.* = undefined;
    }

    pub fn frame(self: *Game) void {
        // This is intentionally a no-op until frame-lifetime allocations arrive.
        _ = self.frame_arena.reset(.retain_capacity);
        self.input = pollInput();
        self.runSimTicks(self.input, rl.getFrameTime());

        drawWorld(&self.world);
    }

    fn runSimTicks(self: *Game, input: world_mod.Input, frame_dt: f32) void {
        const dt = std.math.clamp(frame_dt, 0, sim_dt * max_ticks_per_frame);
        self.accumulator += dt;
        var ticks: u32 = 0;
        while (self.accumulator >= sim_dt and ticks < max_ticks_per_frame) {
            self.world.simTick(input, sim_dt);
            self.accumulator -= sim_dt;
            ticks += 1;
        }
        if (ticks == max_ticks_per_frame) self.accumulator = 0;
    }
};

fn pollInput() world_mod.Input {
    var thrust = Vec2.zero;
    if (rl.isKeyDown(.w)) thrust.y -= 1;
    if (rl.isKeyDown(.s)) thrust.y += 1;
    if (rl.isKeyDown(.a)) thrust.x -= 1;
    if (rl.isKeyDown(.d)) thrust.x += 1;
    // Firing is intentionally unbound in this milestone; tests drive bullets directly.
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

test "runSimTicks caps catch-up after a large frame stall" {
    var game: Game = undefined;
    try game.init(std.testing.allocator, .{ .bullet_cap = 4 }, 800, 600, 123);
    defer game.deinit();

    game.runSimTicks(.{ .thrust = .{ .x = 1, .y = 0 }, .fire = false }, 1);

    try std.testing.expect(game.accumulator < sim_dt);
    try std.testing.expectApproxEqAbs(@as(f32, 425), game.world.player.pos.x, 0.000_001);
}

test "Game init cleans up after allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initGameForFailureTest, .{});
}

fn initGameForFailureTest(allocator: std.mem.Allocator) !void {
    var game: Game = undefined;
    try game.init(allocator, .{ .bullet_cap = 4 }, 800, 600, 123);
    game.deinit();
}
