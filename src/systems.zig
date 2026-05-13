//! Sim-tick and frame-paced system passes. Wired together by Game.

const std = @import("std");

const audio_mod = @import("audio.zig");
const math = @import("math.zig");
const shake_mod = @import("shake.zig");
const world_mod = @import("world.zig");

const Audio = audio_mod.Audio;
const Shake = shake_mod.Shake;
const Vec2 = math.Vec2;
const World = world_mod.World;

const enemy_radius: f32 = 22;
const bullet_radius: f32 = 6;
const player_radius: f32 = 22;
const formation_sway_amplitude: f32 = 12;
const formation_phase_speed: f32 = 1.6;
const formation_dive_threshold: f32 = 6.0;
const dive_chance_per_tick: f32 = 0.005;
const dive_fire_chance_per_tick: f32 = 0.012;
const dive_speed: f32 = 280;
const return_speed: f32 = 200;
const return_arrive_eps: f32 = 4.0;

/// Runs one deterministic 60Hz sim tick: input, bullets, enemies, collisions, sweep.
/// Audio + shake are passed by parameter — World stays sim-pure, but death effects
/// (queue audio events, kick shake) live on the killer side per the design.
pub fn simTick(
    world: *World,
    audio: *Audio,
    shake: *Shake,
    input: world_mod.Input,
    dt: f32,
) void {
    world.updatePlayer(input, dt);
    if (input.fire and !world.player.dead) {
        const before = world.bullets.len();
        world.fireBullet();
        if (world.bullets.len() > before) audio.emit(.shot, 0);
    }

    updateEnemies(world, audio, dt);

    var wall_kills: u32 = 0;
    world.updateBullets(dt, &wall_kills);
    world.updateEnemyBullets(dt, &wall_kills);
    var i: u32 = 0;
    while (i < wall_kills) : (i += 1) {
        audio.emit(.bullet_hit_wall, 0);
    }

    collide(world, audio, shake);

    world.bullets.sweep();
    world.enemy_bullets.sweep();
    world.enemies.sweep();
}

pub fn updateEnemies(world: *World, audio: *Audio, dt: f32) void {
    const random = world.sim_prng.random();
    var iter = world.enemies.iter();
    while (iter.next()) |index| {
        var enemy = world.enemies.rows.get(index);
        switch (enemy.state) {
            .formation => |*f| {
                f.phase += formation_phase_speed * dt;
                const sway = @sin(f.phase) * formation_sway_amplitude;
                enemy.pos = .{ .x = f.home.x + sway, .y = f.home.y };
                if (f.phase > formation_dive_threshold and random.float(f32) < dive_chance_per_tick) {
                    const target = sampleDiveTarget(world.player.pos, random);
                    enemy.state = .{ .diving = .{ .home = f.home, .target = target, .t = 0 } };
                    audio.emit(.enemy_dive, 0);
                }
            },
            .diving => |*d| {
                d.t = @min(1.0, d.t + dive_speed * dt / 600.0);
                const dir = d.target.sub(enemy.pos);
                const len = dir.length();
                if (len > 0.001) {
                    const step = @min(len, dive_speed * dt);
                    enemy.pos = enemy.pos.add(dir.scale(step / len));
                }
                if (random.float(f32) < dive_fire_chance_per_tick and !world.player.dead) {
                    world.spawnEnemyBulletAt(enemy.pos, world.player.pos);
                }
                if (d.t >= 1.0 and enemy.pos.y > world.player.pos.y) {
                    enemy.state = .{ .returning = .{ .home = d.home, .t = 0 } };
                }
            },
            .returning => |*r| {
                r.t = @min(1.0, r.t + return_speed * dt / 600.0);
                const dir = r.home.sub(enemy.pos);
                const len = dir.length();
                if (len > return_arrive_eps) {
                    const step = @min(len, return_speed * dt);
                    enemy.pos = enemy.pos.add(dir.scale(step / len));
                } else {
                    enemy.pos = r.home;
                    enemy.state = .{ .formation = .{ .home = r.home, .phase = 0 } };
                }
            },
        }

        if (enemy.pos.y < -50 or enemy.pos.y > world.bounds.height + 50) {
            world.enemies.kill(.{
                .index = index,
                .generation = world.enemies.generations[index],
            });
            continue;
        }
        world.enemies.rows.set(index, enemy);
    }
}

fn sampleDiveTarget(player_pos: Vec2, random: std.Random) Vec2 {
    const spread: f32 = 120;
    const dx = (random.float(f32) - 0.5) * 2 * spread;
    const dy = 40 + random.float(f32) * 60;
    return .{ .x = player_pos.x + dx, .y = player_pos.y + dy };
}

pub fn collide(world: *World, audio: *Audio, shake: *Shake) void {
    const random = world.sim_prng.random();

    var enemy_iter = world.enemies.iter();
    while (enemy_iter.next()) |ei| {
        var enemy = world.enemies.rows.get(ei);
        var bullet_iter = world.bullets.iter();
        while (bullet_iter.next()) |bi| {
            const bullet = world.bullets.rows.get(bi);
            if (!circlesOverlap(bullet.pos, bullet_radius, enemy.pos, enemy_radius)) continue;

            audio.emit(.bullet_hit_enemy, 0);
            spawnBurst(world, enemy.pos, 8, 120, random, .{ .r = 255, .g = 200, .b = 80, .a = 255 }, 0.35);
            shake.kick(0.15);
            enemy.hp -|= 1;
            world.bullets.kill(.{ .index = bi, .generation = world.bullets.generations[bi] });

            if (enemy.hp == 0) {
                audio.emit(.enemy_explode, 0);
                spawnBurst(world, enemy.pos, 16, 220, random, .{ .r = 255, .g = 120, .b = 60, .a = 255 }, 0.6);
                shake.kick(0.35);
                world.kills_by_kind.set(enemy.kind, world.kills_by_kind.get(enemy.kind) + 1);
                world.enemies.kill(.{ .index = ei, .generation = world.enemies.generations[ei] });
                break;
            }
        }
        world.enemies.rows.set(ei, enemy);
    }

    if (world.player.dead) return;

    var eb_iter = world.enemy_bullets.iter();
    while (eb_iter.next()) |bi| {
        const bullet = world.enemy_bullets.rows.get(bi);
        if (!circlesOverlap(bullet.pos, bullet_radius, world.player.pos, player_radius)) continue;

        audio.emit(.player_explode, 0);
        spawnBurst(world, world.player.pos, 32, 320, random, .{ .r = 220, .g = 255, .b = 255, .a = 255 }, 0.9);
        shake.kick(0.7);
        world.enemy_bullets.kill(.{ .index = bi, .generation = world.enemy_bullets.generations[bi] });
        world.player.dead = true;
        break;
    }
}

const RgbA = struct { r: u8, g: u8, b: u8, a: u8 };

fn spawnBurst(
    world: *World,
    origin: Vec2,
    count: u32,
    base_speed: f32,
    random: std.Random,
    color: RgbA,
    lifetime: f32,
) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const angle = random.float(f32) * std.math.tau;
        const speed = base_speed * (0.5 + random.float(f32) * 0.5);
        if (world.particles.spawn(.{
            .pos = origin,
            .vel = .{ .x = @cos(angle) * speed, .y = @sin(angle) * speed },
            .lifetime_s = lifetime,
            .color_r = color.r,
            .color_g = color.g,
            .color_b = color.b,
            .color_a = color.a,
            .size = 4.5,
        }) == null) return;
    }
}

fn circlesOverlap(pa: Vec2, ra: f32, pb: Vec2, rb: f32) bool {
    const dx = pa.x - pb.x;
    const dy = pa.y - pb.y;
    const r = ra + rb;
    return dx * dx + dy * dy <= r * r;
}

// Particles update on frame_dt, not sim_dt — they're cosmetic, so visual decay
// should track display rate. Sim determinism comes from spawn-time PRNG draws
// inside collide(); subsequent motion is replay-irrelevant.
pub fn updateParticles(world: *World, frame_dt: f32) void {
    var iter = world.particles.iter();
    while (iter.next()) |index| {
        var p = world.particles.rows.get(index);
        p.pos = p.pos.add(p.vel.scale(frame_dt));
        p.lifetime_s -= frame_dt;
        world.particles.rows.set(index, p);
        if (p.lifetime_s <= 0) {
            world.particles.kill(.{
                .index = index,
                .generation = world.particles.generations[index],
            });
        }
    }
    world.particles.sweep();
}

test "bullet hits enemy: queues audio, kicks shake, spawns particles" {
    var prng = std.Random.DefaultPrng.init(0xBEEF);
    var shake_prng = std.Random.DefaultPrng.init(0xBEEF +% 1);
    var world = try World.init(std.testing.allocator, world_mod.WorldCaps.defaults, world_mod.Bounds.default, &prng);
    defer world.deinit(std.testing.allocator);
    var audio: Audio = undefined;
    audio.init();
    defer audio.deinit();
    var shake = Shake.init(&shake_prng);

    _ = world.enemies.spawn(.{
        .pos = .{ .x = 100, .y = 100 },
        .vel = Vec2.zero,
        .hp = 1,
        .kind = .grunt,
        .state = .{ .formation = .{ .home = .{ .x = 100, .y = 100 }, .phase = 0 } },
    }).?;
    _ = world.bullets.spawn(.{
        .pos = .{ .x = 100, .y = 100 },
        .vel = Vec2.zero,
        .lifetime = 1,
    }).?;

    collide(&world, &audio, &shake);

    try std.testing.expect(shake.trauma > 0.4);
    try std.testing.expect(world.particles.len() > 0);
    const stats = audio.flush();
    try std.testing.expectEqual(@as(u32, 2), stats.distinct_plays);
}

test "enemy bullet hits player: marks dead and kicks shake hard" {
    var prng = std.Random.DefaultPrng.init(0xF00D);
    var shake_prng = std.Random.DefaultPrng.init(0xF00D +% 1);
    var world = try World.init(std.testing.allocator, world_mod.WorldCaps.defaults, world_mod.Bounds.default, &prng);
    defer world.deinit(std.testing.allocator);
    var audio: Audio = undefined;
    audio.init();
    defer audio.deinit();
    var shake = Shake.init(&shake_prng);

    world.player.pos = .{ .x = 200, .y = 800 };
    _ = world.enemy_bullets.spawn(.{
        .pos = .{ .x = 200, .y = 800 },
        .vel = Vec2.zero,
        .lifetime = 1,
    }).?;

    collide(&world, &audio, &shake);

    try std.testing.expect(world.player.dead);
    try std.testing.expect(shake.trauma >= 0.69);
}

test "dive-to-return preserves original formation home" {
    var prng = std.Random.DefaultPrng.init(0xD1E);
    var world = try World.init(std.testing.allocator, world_mod.WorldCaps.defaults, world_mod.Bounds.default, &prng);
    defer world.deinit(std.testing.allocator);
    var audio: Audio = undefined;
    audio.init();
    defer audio.deinit();

    const home: Vec2 = .{ .x = 200, .y = 100 };
    world.player.pos = .{ .x = 300, .y = 400 };
    // Park the diver where the next tick will both push t past 1.0 and put it
    // below the player — so the dive→returning transition fires immediately.
    _ = world.enemies.spawn(.{
        .pos = .{ .x = 300, .y = 500 },
        .vel = Vec2.zero,
        .hp = 1,
        .kind = .grunt,
        .state = .{ .diving = .{
            .home = home,
            .target = .{ .x = 300, .y = 500 },
            .t = 0.999,
        } },
    }).?;

    updateEnemies(&world, &audio, world_mod.sim_dt);

    var iter = world.enemies.iter();
    const index = iter.next().?;
    const e = world.enemies.rows.get(index);
    switch (e.state) {
        .returning => |r| try std.testing.expectEqual(home, r.home),
        else => return error.TestUnexpectedResult,
    }
}

test "bullets fired at tall-window player height survive culling" {
    // Regression: world bounds must follow the window, not a hard-coded constant.
    const tall_bounds: world_mod.Bounds = .{ .width = 800, .height = 1400 };
    var prng = std.Random.DefaultPrng.init(0x7A11);
    var world = try World.init(std.testing.allocator, world_mod.WorldCaps.defaults, tall_bounds, &prng);
    defer world.deinit(std.testing.allocator);

    world.player.pos = .{ .x = 400, .y = tall_bounds.height * 0.875 };
    world.fireBullet();
    try std.testing.expectEqual(@as(u32, 1), world.bullets.len());

    var wall_kills: u32 = 0;
    world.updateBullets(world_mod.sim_dt, &wall_kills);
    world.bullets.sweep();
    try std.testing.expectEqual(@as(u32, 0), wall_kills);
    try std.testing.expectEqual(@as(u32, 1), world.bullets.len());
}

test "updateParticles ages and reaps at frame_dt" {
    var prng = std.Random.DefaultPrng.init(0);
    var world = try World.init(std.testing.allocator, world_mod.WorldCaps.defaults, world_mod.Bounds.default, &prng);
    defer world.deinit(std.testing.allocator);

    _ = world.particles.spawn(.{
        .pos = Vec2.zero,
        .vel = .{ .x = 10, .y = 0 },
        .lifetime_s = 0.1,
        .color_r = 255,
        .color_g = 255,
        .color_b = 255,
        .color_a = 255,
        .size = 2,
    }).?;
    try std.testing.expectEqual(@as(u32, 1), world.particles.len());

    updateParticles(&world, 0.2);
    try std.testing.expectEqual(@as(u32, 0), world.particles.len());
}
