//! Persistent replay determinism: record a scripted session to disk, reopen
//! the trace as a Replayer, replay it against a fresh sim, then byte-compare
//! every World pool. This is the test that validates the file format actually
//! captures enough state to reproduce the simulation across program runs.

const std = @import("std");

const audio_mod = @import("audio.zig");
const math = @import("math.zig");
const replay = @import("replay.zig");
const shake_mod = @import("shake.zig");
const systems = @import("systems.zig");
const world_mod = @import("world.zig");

const Vec2 = math.Vec2;

test "persistent replay: trace round-trips to identical final World state" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const seed: u64 = 0xA55B_C0DE;
    const caps: world_mod.WorldCaps = .{
        .bullet_cap = 16,
        .enemy_bullet_cap = 16,
        .enemy_cap = 16,
        .particle_cap = 256,
    };
    const total_ticks: u32 = 600;

    var record_h = try Harness.init(seed, caps);
    defer record_h.deinit();
    seedFormation(&record_h.world);

    {
        var rec = try replay.Recorder.open(tmp.dir, io, "trace.zrpl", seed);
        defer rec.close();
        var t: u32 = 0;
        while (t < total_ticks) : (t += 1) {
            const input = inputAt(t);
            try rec.writeTick(input);
            systems.simTick(&record_h.world, &record_h.audio, &record_h.shake, input, world_mod.sim_dt);
        }
        try rec.finalize();
    }

    var replay_h = try Harness.init(seed, caps);
    defer replay_h.deinit();
    seedFormation(&replay_h.world);

    var rep = try replay.Replayer.open(tmp.dir, io, "trace.zrpl");
    defer rep.close();
    try std.testing.expectEqual(seed, rep.seed);
    try std.testing.expectEqual(total_ticks, rep.tick_count);

    var ticks_seen: u32 = 0;
    while (try rep.nextTick()) |input| : (ticks_seen += 1) {
        systems.simTick(&replay_h.world, &replay_h.audio, &replay_h.shake, input, world_mod.sim_dt);
    }
    try std.testing.expectEqual(total_ticks, ticks_seen);

    try expectWorldsEqual(&record_h.world, &replay_h.world);
    // PRNG state must match too: any later sim_prng draw would otherwise
    // diverge between the two runs.
    try std.testing.expectEqual(record_h.prng.s, replay_h.prng.s);
}

const Harness = struct {
    prng: *std.Random.DefaultPrng,
    shake_prng: *std.Random.DefaultPrng,
    world: world_mod.World,
    audio: audio_mod.Audio,
    shake: shake_mod.Shake,

    fn init(seed: u64, caps: world_mod.WorldCaps) !Harness {
        const alloc = std.testing.allocator;
        const prng = try alloc.create(std.Random.DefaultPrng);
        errdefer alloc.destroy(prng);
        prng.* = std.Random.DefaultPrng.init(seed);

        const shake_prng = try alloc.create(std.Random.DefaultPrng);
        errdefer alloc.destroy(shake_prng);
        shake_prng.* = std.Random.DefaultPrng.init(seed +% 0x9E37_79B9_7F4A_7C15);

        var world = try world_mod.World.init(alloc, caps, world_mod.Bounds.default, prng);
        errdefer world.deinit(alloc);

        world.player.pos = .{ .x = 350, .y = 800 };

        var harness: Harness = .{
            .prng = prng,
            .shake_prng = shake_prng,
            .world = world,
            .audio = undefined,
            .shake = undefined,
        };
        harness.audio.init();
        harness.shake = shake_mod.Shake.init(shake_prng);
        return harness;
    }

    fn deinit(self: *Harness) void {
        const alloc = std.testing.allocator;
        self.audio.deinit();
        self.world.deinit(alloc);
        alloc.destroy(self.shake_prng);
        alloc.destroy(self.prng);
    }
};

fn seedFormation(world: *world_mod.World) void {
    const top_left: Vec2 = .{ .x = 150, .y = 120 };
    const spacing: Vec2 = .{ .x = 80, .y = 60 };
    var slots: [12]world_mod.FormationSlot = undefined;
    var i: u32 = 0;
    var row: u32 = 0;
    while (row < 3) : (row += 1) {
        var col: u32 = 0;
        while (col < 4) : (col += 1) {
            slots[i] = .{
                .home = .{
                    .x = top_left.x + @as(f32, @floatFromInt(col)) * spacing.x,
                    .y = top_left.y + @as(f32, @floatFromInt(row)) * spacing.y,
                },
                .kind_index = @intCast(row % 3),
            };
            i += 1;
        }
    }
    const kinds = [_]world_mod.EnemyKind{ .goei, .zako, .grunt };
    world.spawnFormation(&slots, &kinds);
}

fn inputAt(tick: u32) world_mod.Input {
    const horizontal: f32 = switch (tick % 90) {
        0...29 => -1,
        30...59 => 1,
        else => 0,
    };
    const vertical: f32 = switch ((tick / 45) % 3) {
        0 => -0.5,
        1 => 0.75,
        else => 0,
    };
    return .{
        .thrust = Vec2{ .x = horizontal, .y = vertical },
        .fire = tick % 2 == 0,
    };
}

fn expectWorldsEqual(a: *const world_mod.World, b: *const world_mod.World) !void {
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&a.player.pos), std.mem.asBytes(&b.player.pos));
    try std.testing.expectEqual(a.player.dead, b.player.dead);
    try expectPoolEqual(world_mod.Bullet, &a.bullets, &b.bullets);
    try expectPoolEqual(world_mod.EnemyBullet, &a.enemy_bullets, &b.enemy_bullets);
    try expectEnemiesEqual(&a.enemies, &b.enemies);
    try std.testing.expectEqual(a.particles.len(), b.particles.len());
}

fn expectPoolEqual(
    comptime T: type,
    a: *const @import("pool.zig").Pool(T),
    b: *const @import("pool.zig").Pool(T),
) !void {
    try std.testing.expectEqual(a.len(), b.len());
    var iter_a = a.iter();
    var iter_b = b.iter();
    while (true) {
        const ia = iter_a.next();
        const ib = iter_b.next();
        try std.testing.expectEqual(ia, ib);
        const index = ia orelse break;
        const va = a.rows.get(index);
        const vb = b.rows.get(index);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&va), std.mem.asBytes(&vb));
    }
}

fn expectEnemiesEqual(
    a: *const world_mod.EnemyPool,
    b: *const world_mod.EnemyPool,
) !void {
    try std.testing.expectEqual(a.len(), b.len());
    var iter_a = a.iter();
    var iter_b = b.iter();
    while (true) {
        const ia = iter_a.next();
        const ib = iter_b.next();
        try std.testing.expectEqual(ia, ib);
        const index = ia orelse break;
        const ea = a.rows.get(index);
        const eb = b.rows.get(index);
        try std.testing.expectEqual(ea.hp, eb.hp);
        try std.testing.expectEqual(ea.kind, eb.kind);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&ea.pos), std.mem.asBytes(&eb.pos));
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&ea.vel), std.mem.asBytes(&eb.vel));
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&ea.state), std.mem.asBytes(&eb.state));
    }
}
