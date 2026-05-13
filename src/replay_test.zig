//! End-to-end deterministic replay tests.

const std = @import("std");

const audio_mod = @import("audio.zig");
const math = @import("math.zig");
const shake_mod = @import("shake.zig");
const systems = @import("systems.zig");
const world_mod = @import("world.zig");

const Vec2 = math.Vec2;

test "replay determinism: player + bullets + enemies + particles" {
    const seed: u64 = 0xA11CE;
    const caps: world_mod.WorldCaps = .{
        .bullet_cap = 16,
        .enemy_bullet_cap = 16,
        .enemy_cap = 16,
        .particle_cap = 256,
    };

    var harness_a = try Harness.init(seed, caps);
    defer harness_a.deinit();
    var harness_b = try Harness.init(seed, caps);
    defer harness_b.deinit();

    seedFormation(&harness_a.world);
    seedFormation(&harness_b.world);

    var hit_cap = false;
    var saw_particles = false;
    var tick: u32 = 0;
    while (tick < 1200) : (tick += 1) {
        const input = inputAt(tick);
        systems.simTick(&harness_a.world, &harness_a.audio, &harness_a.shake, input, world_mod.sim_dt);
        systems.simTick(&harness_b.world, &harness_b.audio, &harness_b.shake, input, world_mod.sim_dt);
        hit_cap = hit_cap or harness_a.world.bullets.len() == caps.bullet_cap;
        saw_particles = saw_particles or harness_a.world.particles.len() > 0;
        try expectWorldsEqual(&harness_a.world, &harness_b.world);
    }
    try std.testing.expect(hit_cap);
    try std.testing.expect(saw_particles);
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
    world.spawnFormation(.{ .x = 150, .y = 120 }, 4, 3, .{ .x = 80, .y = 60 });
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
    try expectParticleCountsEqual(&a.particles, &b.particles);
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

// Particles spawn from sim_prng (verifies sim_prng wasn't drained off-loop),
// but their post-spawn motion runs on frame_dt outside simTick. So we assert
// equal counts during the in-process replay, not full byte-equality.
fn expectParticleCountsEqual(
    a: *const world_mod.ParticlePool,
    b: *const world_mod.ParticlePool,
) !void {
    try std.testing.expectEqual(a.len(), b.len());
}
