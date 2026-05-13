//! End-to-end deterministic replay tests.

const std = @import("std");

const math = @import("math.zig");
const world_mod = @import("world.zig");

const Vec2 = math.Vec2;

test "replay determinism" {
    const seed: u64 = 0xA11CE;
    const caps: world_mod.WorldCaps = .{ .bullet_cap = 16 };

    var prng_a = std.Random.DefaultPrng.init(seed);
    var world_a = try world_mod.World.init(std.testing.allocator, caps, &prng_a);
    defer world_a.deinit(std.testing.allocator);

    var prng_b = std.Random.DefaultPrng.init(seed);
    var world_b = try world_mod.World.init(std.testing.allocator, caps, &prng_b);
    defer world_b.deinit(std.testing.allocator);

    var hit_cap = false;
    var tick: u32 = 0;
    while (tick < 600) : (tick += 1) {
        const input = inputAt(tick);
        world_a.simTick(input, world_mod.sim_dt);
        world_b.simTick(input, world_mod.sim_dt);
        hit_cap = hit_cap or world_a.bullets.len() == caps.bullet_cap;
        try expectWorldsEqual(&world_a, &world_b);
    }
    try std.testing.expect(hit_cap);
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

    var iter_a = a.bullets.iter();
    var iter_b = b.bullets.iter();
    while (true) {
        const index_a = iter_a.next();
        const index_b = iter_b.next();
        try std.testing.expectEqual(index_a, index_b);
        const index = index_a orelse break;

        const bullet_a = a.bullets.rows.get(index);
        const bullet_b = b.bullets.rows.get(index);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&bullet_a), std.mem.asBytes(&bullet_b));
    }
}
