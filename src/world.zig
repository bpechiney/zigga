//! Deterministic simulation state and systems.

const std = @import("std");

const math = @import("math.zig");
const Pool = @import("pool.zig").Pool;

const Vec2 = math.Vec2;

pub const sim_dt: f32 = 1.0 / 60.0;
/// Default dive cadence: roughly one dive per 3.3 s of formation hover, matching
/// the pre-milestone-3 hard-coded value. `levels.spawn` overrides it per level.
const default_dive_chance_per_tick: f32 = 0.005;
const player_speed: f32 = 300;
const bullet_speed: f32 = 500;
const bullet_lifetime: f32 = 2;
const enemy_bullet_speed: f32 = 220;
const enemy_bullet_lifetime: f32 = 3;

pub const WorldCaps = struct {
    bullet_cap: u32 = 128,
    enemy_bullet_cap: u32 = 128,
    enemy_cap: u32 = 64,
    particle_cap: u32 = 512,

    pub const defaults: WorldCaps = .{};
};

pub const Bounds = struct {
    width: f32,
    height: f32,

    pub const default: Bounds = .{ .width = 700, .height = 900 };
};

pub const Input = struct {
    thrust: Vec2,
    fire: bool,

    pub const zero: Input = .{ .thrust = Vec2.zero, .fire = false };
};

pub const Player = struct {
    pos: Vec2,
    vel: Vec2,
    dead: bool = false,

    pub fn init(bounds: Bounds) Player {
        return .{
            .pos = .{ .x = bounds.width * 0.5, .y = bounds.height * 0.875 },
            .vel = Vec2.zero,
            .dead = false,
        };
    }
};

pub const FormationSlot = struct {
    home: Vec2,
    kind_index: u8,
};

pub const Bullet = struct {
    pos: Vec2,
    vel: Vec2,
    lifetime: f32,
};

pub const EnemyBullet = struct {
    pos: Vec2,
    vel: Vec2,
    lifetime: f32,
};

pub const EnemyKind = enum { grunt, zako, goei };

pub const EnemyState = union(enum) {
    formation: struct { home: Vec2, phase: f32 },
    diving: struct { home: Vec2, target: Vec2, t: f32 },
    returning: struct { home: Vec2, t: f32 },
};

pub const Enemy = struct {
    pos: Vec2,
    vel: Vec2,
    hp: u8,
    state: EnemyState,
    kind: EnemyKind,
};

pub const Particle = struct {
    pos: Vec2,
    vel: Vec2,
    lifetime_s: f32,
    color_r: u8,
    color_g: u8,
    color_b: u8,
    color_a: u8,
    size: f32,
};

pub const BulletPool = Pool(Bullet);
pub const EnemyBulletPool = Pool(EnemyBullet);
pub const EnemyPool = Pool(Enemy);
pub const ParticlePool = Pool(Particle);

pub const World = struct {
    player: Player,
    bullets: BulletPool,
    enemy_bullets: EnemyBulletPool,
    enemies: EnemyPool,
    particles: ParticlePool,
    bounds: Bounds,
    sim_prng: *std.Random.DefaultPrng,
    /// Per-tick scratch: bumped each time `collide` kills an enemy of that kind.
    /// Game.frame drains this into `Playing.score`. Lives on World because it's
    /// sim-pure data — no external system pointers, no replay implications.
    kills_by_kind: std.EnumArray(EnemyKind, u32),
    /// Probability per sim tick that a formation enemy starts a dive. Configured
    /// by `levels.spawn` from `LevelDef.dive_interval` (mean seconds between
    /// dives); kept on World because the sim reads it every tick.
    dive_chance_per_tick: f32,

    pub fn init(
        gpa: std.mem.Allocator,
        caps: WorldCaps,
        bounds: Bounds,
        sim_prng: *std.Random.DefaultPrng,
    ) !World {
        var bullets = try BulletPool.init(gpa, caps.bullet_cap);
        errdefer bullets.deinit(gpa);
        var enemy_bullets = try EnemyBulletPool.init(gpa, caps.enemy_bullet_cap);
        errdefer enemy_bullets.deinit(gpa);
        var enemies = try EnemyPool.init(gpa, caps.enemy_cap);
        errdefer enemies.deinit(gpa);
        var particles = try ParticlePool.init(gpa, caps.particle_cap);
        errdefer particles.deinit(gpa);

        return .{
            .player = .{ .pos = Vec2.zero, .vel = Vec2.zero, .dead = false },
            .bullets = bullets,
            .enemy_bullets = enemy_bullets,
            .enemies = enemies,
            .particles = particles,
            .bounds = bounds,
            .sim_prng = sim_prng,
            .kills_by_kind = std.EnumArray(EnemyKind, u32).initFill(0),
            .dive_chance_per_tick = default_dive_chance_per_tick,
        };
    }

    pub fn deinit(self: *World, gpa: std.mem.Allocator) void {
        self.particles.deinit(gpa);
        self.enemies.deinit(gpa);
        self.enemy_bullets.deinit(gpa);
        self.bullets.deinit(gpa);
        self.* = undefined;
    }

    pub fn spawnFormation(
        self: *World,
        formation: []const FormationSlot,
        kinds: []const EnemyKind,
    ) void {
        for (formation, 0..) |slot, i| {
            const kind = kinds[slot.kind_index];
            const phase_offset: f32 = @as(f32, @floatFromInt(i)) * 0.31;
            _ = self.enemies.spawn(.{
                .pos = slot.home,
                .vel = Vec2.zero,
                .hp = enemyHp(kind),
                .kind = kind,
                .state = .{ .formation = .{ .home = slot.home, .phase = phase_offset } },
            });
        }
    }

    /// Bumps generations across every pool so any handle held over the call returns
    /// `null` from `resolve`. Player is untouched — callers reset it explicitly when
    /// the semantics demand (e.g. `loadLevel`).
    pub fn clearActive(self: *World) void {
        self.bullets.clearActive();
        self.enemy_bullets.clearActive();
        self.enemies.clearActive();
        self.particles.clearActive();
    }

    pub fn fireBullet(self: *World) void {
        const random = self.sim_prng.random();
        const jitter = 0.95 + random.float(f32) * 0.1;
        _ = self.bullets.spawn(.{
            .pos = self.player.pos,
            .vel = .{ .x = 0, .y = -bullet_speed * jitter },
            .lifetime = bullet_lifetime,
        });
    }

    pub fn updatePlayer(self: *World, input: Input, dt: f32) void {
        if (self.player.dead) {
            self.player.vel = Vec2.zero;
            return;
        }
        const thrust = clampToUnit(input.thrust);
        self.player.vel = thrust.scale(player_speed);
        self.player.pos = self.player.pos.add(self.player.vel.scale(dt));
    }

    pub fn updateBullets(self: *World, dt: f32, off_screen: *u32) void {
        var iter = self.bullets.iter();
        while (iter.next()) |index| {
            var bullet = self.bullets.rows.get(index);
            bullet.pos = bullet.pos.add(bullet.vel.scale(dt));
            bullet.lifetime -= dt;
            self.bullets.rows.set(index, bullet);
            const off = bullet.pos.y < 0 or bullet.pos.y > self.bounds.height;
            if (off) off_screen.* += 1;
            if (bullet.lifetime <= 0 or off) {
                self.bullets.kill(.{
                    .index = index,
                    .generation = self.bullets.generations[index],
                });
            }
        }
    }

    pub fn updateEnemyBullets(self: *World, dt: f32, off_screen: *u32) void {
        var iter = self.enemy_bullets.iter();
        while (iter.next()) |index| {
            var bullet = self.enemy_bullets.rows.get(index);
            bullet.pos = bullet.pos.add(bullet.vel.scale(dt));
            bullet.lifetime -= dt;
            self.enemy_bullets.rows.set(index, bullet);
            const off = bullet.pos.y < 0 or bullet.pos.y > self.bounds.height;
            if (off) off_screen.* += 1;
            if (bullet.lifetime <= 0 or off) {
                self.enemy_bullets.kill(.{
                    .index = index,
                    .generation = self.enemy_bullets.generations[index],
                });
            }
        }
    }

    pub fn spawnEnemyBulletAt(self: *World, origin: Vec2, target: Vec2) void {
        const dir = target.sub(origin).normalize();
        _ = self.enemy_bullets.spawn(.{
            .pos = origin,
            .vel = dir.scale(enemy_bullet_speed),
            .lifetime = enemy_bullet_lifetime,
        });
    }
};

pub fn enemyHp(kind: EnemyKind) u8 {
    return switch (kind) {
        .grunt => 1,
        .zako => 1,
        .goei => 2,
    };
}

pub fn clampToUnit(v: Vec2) Vec2 {
    if (!std.math.isFinite(v.x) or !std.math.isFinite(v.y)) return Vec2.zero;
    const len_sq = v.lengthSquared();
    if (len_sq <= 1) return v;
    return v.normalize();
}

test "clampToUnit preserves boundary and small vectors" {
    try std.testing.expectEqual(Vec2{ .x = 1, .y = 0 }, clampToUnit(.{ .x = 1, .y = 0 }));
    try std.testing.expectEqual(Vec2{ .x = 0.000_001, .y = 0 }, clampToUnit(.{ .x = 0.000_001, .y = 0 }));
}

test "clampToUnit sanitizes non-finite inputs" {
    const result = clampToUnit(.{ .x = std.math.nan(f32), .y = 0 });
    try std.testing.expectEqual(Vec2.zero, result);
    try std.testing.expectEqual(Vec2.zero, clampToUnit(.{ .x = 0, .y = std.math.inf(f32) }));
}

test "Pool(Enemy) round-trips tagged-union state" {
    var pool = try EnemyPool.init(std.testing.allocator, 8);
    defer pool.deinit(std.testing.allocator);

    const home: Vec2 = .{ .x = 100, .y = 200 };
    const handle = pool.spawn(.{
        .pos = home,
        .vel = Vec2.zero,
        .hp = 2,
        .kind = .goei,
        .state = .{ .formation = .{ .home = home, .phase = 0.5 } },
    }).?;
    const index = pool.resolve(handle).?;

    var entry = pool.rows.get(index);
    try std.testing.expectEqual(EnemyKind.goei, entry.kind);
    switch (entry.state) {
        .formation => |f| {
            try std.testing.expectEqual(home, f.home);
            try std.testing.expectApproxEqAbs(@as(f32, 0.5), f.phase, 0.000_001);
        },
        else => return error.TestUnexpectedResult,
    }

    entry.state = .{ .diving = .{ .home = home, .target = .{ .x = 50, .y = 300 }, .t = 0.25 } };
    pool.rows.set(index, entry);

    const updated = pool.rows.get(index);
    switch (updated.state) {
        .diving => |d| {
            try std.testing.expectEqual(home, d.home);
            try std.testing.expectEqual(@as(f32, 50), d.target.x);
            try std.testing.expectApproxEqAbs(@as(f32, 0.25), d.t, 0.000_001);
        },
        else => return error.TestUnexpectedResult,
    }
}
