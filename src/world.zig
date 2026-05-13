//! Deterministic simulation state and systems.

const std = @import("std");

const math = @import("math.zig");
const Pool = @import("pool.zig").Pool;

const Vec2 = math.Vec2;

pub const player_speed: f32 = 300;
const bullet_speed: f32 = 500;
const bullet_lifetime: f32 = 2;

pub const WorldCaps = struct {
    bullet_cap: u32,

    pub const defaults: WorldCaps = .{ .bullet_cap = 128 };
};

pub const Input = struct {
    thrust: Vec2,
    fire: bool,

    pub const zero: Input = .{ .thrust = Vec2.zero, .fire = false };
};

pub const Player = struct {
    pos: Vec2,
    vel: Vec2,
};

pub const Bullet = struct {
    pos: Vec2,
    vel: Vec2,
    lifetime: f32,
};

pub const BulletPool = Pool(Bullet);

pub const World = struct {
    player: Player,
    bullets: BulletPool,
    sim_prng: *std.Random.DefaultPrng,

    pub fn init(gpa: std.mem.Allocator, caps: WorldCaps, sim_prng: *std.Random.DefaultPrng) !World {
        return .{
            .player = .{ .pos = Vec2.zero, .vel = Vec2.zero },
            .bullets = try BulletPool.init(gpa, caps.bullet_cap),
            .sim_prng = sim_prng,
        };
    }

    pub fn deinit(self: *World, gpa: std.mem.Allocator) void {
        self.bullets.deinit(gpa);
        self.* = undefined;
    }

    pub fn simTick(self: *World, input: Input, sim_dt: f32) void {
        self.updatePlayer(input, sim_dt);
        if (input.fire) self.fireBullet();
        self.updateBullets(sim_dt);
        self.bullets.sweep();
    }

    fn updatePlayer(self: *World, input: Input, sim_dt: f32) void {
        const thrust = clampToUnit(input.thrust);
        self.player.vel = thrust.scale(player_speed);
        self.player.pos = self.player.pos.add(self.player.vel.scale(sim_dt));
    }

    fn fireBullet(self: *World) void {
        const random = self.sim_prng.random();
        const jitter = 0.95 + random.float(f32) * 0.1;
        _ = self.bullets.spawn(.{
            .pos = self.player.pos,
            .vel = .{ .x = 0, .y = -bullet_speed * jitter },
            .lifetime = bullet_lifetime,
        });
    }

    fn updateBullets(self: *World, sim_dt: f32) void {
        var iter = self.bullets.iter();
        while (iter.next()) |index| {
            var bullet = self.bullets.rows.get(index);
            bullet.pos = bullet.pos.add(bullet.vel.scale(sim_dt));
            bullet.lifetime -= sim_dt;
            self.bullets.rows.set(index, bullet);
            if (bullet.lifetime <= 0) {
                self.bullets.kill(.{
                    .index = index,
                    .generation = self.bullets.generations[index],
                });
            }
        }
    }
};

fn clampToUnit(v: Vec2) Vec2 {
    const len_sq = v.lengthSquared();
    if (len_sq <= 1) return v;
    return v.normalize();
}

test "simTick moves player and bullets" {
    var prng = std.Random.DefaultPrng.init(123);
    var world = try World.init(std.testing.allocator, .{ .bullet_cap = 4 }, &prng);
    defer world.deinit(std.testing.allocator);

    world.simTick(.{ .thrust = .{ .x = 2, .y = 0 }, .fire = true }, 1.0 / 60.0);

    try std.testing.expectApproxEqAbs(@as(f32, 5), world.player.pos.x, 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), world.player.pos.y, 0.000_001);
    try std.testing.expectEqual(@as(u32, 1), world.bullets.len());
}
