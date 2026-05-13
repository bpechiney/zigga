//! Game-owned lifetime state and outer frame loop.

const std = @import("std");
const rl = @import("raylib");

const audio_mod = @import("audio.zig");
const levels_mod = @import("levels.zig");
const math = @import("math.zig");
const shake_mod = @import("shake.zig");
const state_mod = @import("state.zig");
const systems = @import("systems.zig");
const world_mod = @import("world.zig");

const Vec2 = math.Vec2;

pub const sim_dt: f32 = world_mod.sim_dt;
pub const Audio = audio_mod.Audio;
pub const Shake = shake_mod.Shake;
pub const State = state_mod.State;
pub const Playing = state_mod.Playing;
pub const GameOver = state_mod.GameOver;

const max_ticks_per_frame: u32 = 5;
const player_size: f32 = 28.0;
const bullet_draw_radius: f32 = 6.0;
const enemy_draw_radius: f32 = 22.0;
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
    state: State,
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

        self.world.player = world_mod.Player.init(bounds);

        self.input = world_mod.Input.zero;
        self.accumulator = 0;
        self.audio.init();
        self.shake = Shake.init(self.shake_prng);
        self.state = .attract;
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

    pub fn frame(self: *Game) !void {
        _ = self.frame_arena.reset(.retain_capacity);
        self.input = pollInput();
        switch (self.state) {
            .attract => try self.frameAttract(),
            .playing => |*p| try self.framePlaying(p),
            .paused => |*p| self.framePaused(p),
            .game_over => |*g| self.frameGameOver(g),
        }
    }

    fn frameAttract(self: *Game) !void {
        const frame_dt = rl.getFrameTime();
        if (rl.getKeyPressed() != .null) {
            self.state = .{ .playing = state_mod.fresh() };
            try self.loadLevel(0);
        }

        systems.updateParticles(&self.world, frame_dt);
        self.shake.update(frame_dt);
        self.audio.updateMusic(frame_dt);
        _ = self.audio.flush();
        self.drawCurrent();
    }

    fn framePlaying(self: *Game, p: *Playing) !void {
        const frame_dt = rl.getFrameTime();

        if (rl.isKeyPressed(.escape)) {
            self.state = .{ .paused = p.* };
        } else if (p.death_pause > 0) {
            p.death_pause = @max(0, p.death_pause - frame_dt);
            self.accumulator = 0;
            if (p.death_pause == 0) _ = self.finishDeath(p);
        } else {
            self.runSimTicks(self.input, frame_dt);
            self.drainKills(p);
            p.level_timer += frame_dt;

            if (self.world.player.dead) {
                p.death_pause = state_mod.death_pause_s;
            } else if (self.world.enemies.len() == 0) {
                const next_index: u8 = (p.level_index + 1) % levels_mod.level_count;
                p.level_index = next_index;
                p.level_timer = 0;
                try self.loadLevel(next_index);
            }
        }

        systems.updateParticles(&self.world, frame_dt);
        self.shake.update(frame_dt);
        self.audio.updateMusic(frame_dt);
        _ = self.audio.flush();
        self.drawCurrent();
    }

    fn framePaused(self: *Game, p: *Playing) void {
        const frame_dt = rl.getFrameTime();
        if (rl.isKeyPressed(.escape)) {
            self.state = .{ .playing = p.* };
            // Reset the accumulator so paused wall-time doesn't burst-tick on resume.
            self.accumulator = 0;
        }
        systems.updateParticles(&self.world, frame_dt);
        self.shake.update(frame_dt);
        self.audio.updateMusic(frame_dt);
        _ = self.audio.flush();
        self.drawCurrent();
    }

    fn frameGameOver(self: *Game, g: *GameOver) void {
        const frame_dt = rl.getFrameTime();
        g.timer_s = @max(0, g.timer_s - frame_dt);
        if (g.timer_s == 0) {
            self.audio.stopMusic();
            self.state = .attract;
        }
        systems.updateParticles(&self.world, frame_dt);
        self.shake.update(frame_dt);
        self.audio.updateMusic(frame_dt);
        _ = self.audio.flush();
        self.drawCurrent();
    }

    fn drawCurrent(self: *Game) void {
        // World, HUD, and overlay coords are all GLFW screen coordinates
        // (points). With HIGHDPI on macOS Retina, raylib's draw pipeline handles
        // the upscale to the framebuffer internally — measureText and drawText
        // both speak points, so centering math uses window_w/window_h (points),
        // not getRenderWidth/Height (pixels). Don't reintroduce a Camera2D zoom
        // here: world entities are authored in points already, so a zoom would
        // push them past the visible canvas. Shake offset is points too.
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

        switch (self.state) {
            .attract => {
                drawAttract(self.window_w, self.window_h);
                return;
            },
            else => {},
        }

        {
            camera.begin();
            defer camera.end();
            drawEnemies(&self.world);
            drawBullets(&self.world);
            drawEnemyBullets(&self.world);
            drawParticles(&self.world);
            if (!self.world.player.dead) drawPlayer(&self.world);
        }

        switch (self.state) {
            .playing => |p| drawHud(self.window_w, p),
            .paused => |p| {
                drawHud(self.window_w, p);
                drawPausedOverlay(self.window_w, self.window_h);
            },
            .game_over => |g| drawGameOverOverlay(self.window_w, self.window_h, g),
            .attract => unreachable,
        }
    }

    /// On death the killer (collide) has already emitted player_explode and
    /// kicked shake. Here we close the loop: decrement lives, then either
    /// transition to game_over or respawn into a cleaned-up world. Returns
    /// true if state advanced to game_over (caller should bail).
    fn finishDeath(self: *Game, p: *Playing) bool {
        if (p.lives > 0) p.lives -= 1;
        if (p.lives == 0) {
            self.state = .{ .game_over = .{ .final_score = p.score, .timer_s = state_mod.game_over_s } };
            return true;
        }
        // Respawn: revive player + scrub stale projectiles/particles. Enemies stay.
        self.world.player = world_mod.Player.init(self.world.bounds);
        self.world.bullets.clearActive();
        self.world.enemy_bullets.clearActive();
        self.world.particles.clearActive();
        return false;
    }

    /// Hard reset for a level boundary. Step order matters:
    ///   1. perm_arena.reset — frees the previous level's ZON slices.
    ///   2. world.clearActive — bumps every pool's generation so stale handles
    ///      held over the call return null.
    ///   3. audio.flush — drain residual events from the prior frame.
    ///   4. audio.clearPending — drop any events queued *after* flush.
    ///   5. Load the new def — allocations land in the freshly-reset arena.
    ///   6. Spawn formation + start music — sim ready, audio ramps in.
    /// Re-ordering produces stale handles or audio gaps. Don't.
    pub fn loadLevel(self: *Game, level_index: u8) !void {
        _ = self.perm_arena.reset(.retain_capacity);
        self.world.clearActive();
        _ = self.audio.flush();
        self.audio.clearPending();

        const def = try levels_mod.loadLevelDef(self.perm_arena.allocator(), level_index);

        self.world.player = world_mod.Player.init(self.world.bounds);
        levels_mod.spawn(&self.world, def);

        self.audio.playMusic(def.music_track);
        self.accumulator = 0;
        self.fire_cooldown = 0;
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

    fn drainKills(self: *Game, p: *Playing) void {
        var it = self.world.kills_by_kind.iterator();
        while (it.next()) |entry| {
            const count = entry.value.*;
            if (count == 0) continue;
            p.score += state_mod.killScore(entry.key) * count;
            entry.value.* = 0;
        }
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
};

fn pollInput() world_mod.Input {
    var thrust = Vec2.zero;
    if (rl.isKeyDown(.w)) thrust.y -= 1;
    if (rl.isKeyDown(.s)) thrust.y += 1;
    if (rl.isKeyDown(.a)) thrust.x -= 1;
    if (rl.isKeyDown(.d)) thrust.x += 1;
    return .{ .thrust = thrust, .fire = rl.isKeyDown(.space) };
}

fn drawPlayer(world: *const world_mod.World) void {
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
        rl.drawCircleV(.{ .x = b.pos.x, .y = b.pos.y }, bullet_draw_radius, rl.Color.yellow);
    }
}

fn drawEnemyBullets(world: *const world_mod.World) void {
    var iter = world.enemy_bullets.iter();
    while (iter.next()) |index| {
        const b = world.enemy_bullets.rows.get(index);
        rl.drawCircleV(.{ .x = b.pos.x, .y = b.pos.y }, bullet_draw_radius, rl.Color.red);
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
        rl.drawPoly(.{ .x = e.pos.x, .y = e.pos.y }, 6, enemy_draw_radius, 0, color);
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

fn drawAttract(window_w: i32, window_h: i32) void {
    const title = "ZIGGA";
    const prompt = "PRESS ANY KEY";
    const footer = "(C) 2026 you";

    const title_size: i32 = 96;
    const prompt_size: i32 = 32;
    const footer_size: i32 = 14;

    const title_w = rl.measureText(title, title_size);
    rl.drawText(
        title,
        @divTrunc(window_w - title_w, 2),
        @divTrunc(window_h, 4),
        title_size,
        rl.Color.white,
    );

    const prompt_w = rl.measureText(prompt, prompt_size);
    rl.drawText(
        prompt,
        @divTrunc(window_w - prompt_w, 2),
        @divTrunc(window_h, 2),
        prompt_size,
        rl.Color.ray_white,
    );

    const footer_w = rl.measureText(footer, footer_size);
    rl.drawText(
        footer,
        @divTrunc(window_w - footer_w, 2),
        window_h - 40,
        footer_size,
        rl.Color.gray,
    );
}

fn drawHud(window_w: i32, p: Playing) void {
    var buf: [64]u8 = undefined;
    const score = std.fmt.bufPrintZ(&buf, "SCORE {d:0>6}", .{p.score}) catch return;
    rl.drawText(score, 16, 12, 20, rl.Color.white);

    var lives_buf: [32]u8 = undefined;
    const lives = std.fmt.bufPrintZ(&lives_buf, "LIVES x {d}", .{p.lives}) catch return;
    const lives_w = rl.measureText(lives, 20);
    rl.drawText(lives, window_w - lives_w - 16, 12, 20, rl.Color.white);
}

fn drawPausedOverlay(window_w: i32, window_h: i32) void {
    const dim = rl.Color.init(0, 0, 0, 128);
    rl.drawRectangle(0, 0, window_w, window_h, dim);

    const text = "PAUSED";
    const size: i32 = 64;
    const text_w = rl.measureText(text, size);
    rl.drawText(text, @divTrunc(window_w - text_w, 2), @divTrunc(window_h - size, 2), size, rl.Color.white);
}

fn drawGameOverOverlay(window_w: i32, window_h: i32, g: GameOver) void {
    const dim = rl.Color.init(0, 0, 0, 180);
    rl.drawRectangle(0, 0, window_w, window_h, dim);

    const title = "GAME OVER";
    const title_size: i32 = 72;
    const title_w = rl.measureText(title, title_size);
    rl.drawText(title, @divTrunc(window_w - title_w, 2), @divTrunc(window_h, 2) - title_size, title_size, rl.Color.red);

    var buf: [64]u8 = undefined;
    const final = std.fmt.bufPrintZ(&buf, "FINAL SCORE: {d}", .{g.final_score}) catch return;
    const final_size: i32 = 28;
    const final_w = rl.measureText(final, final_size);
    rl.drawText(final, @divTrunc(window_w - final_w, 2), @divTrunc(window_h, 2) + 16, final_size, rl.Color.white);
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

test "Game starts in attract state" {
    var game: Game = undefined;
    try game.init(std.testing.allocator, .{}, 800, 600, 7);
    defer game.deinit();

    try std.testing.expect(std.meta.activeTag(game.state) == .attract);
}

test "loadLevel populates enemies and invalidates prior handles" {
    var game: Game = undefined;
    try game.init(std.testing.allocator, .{}, 800, 600, 11);
    defer game.deinit();

    try game.loadLevel(0);
    try std.testing.expect(game.world.enemies.len() > 0);

    var iter = game.world.enemies.iter();
    const first_index = iter.next().?;
    const stale_handle = world_mod.EnemyPool.Handle{
        .index = first_index,
        .generation = game.world.enemies.generations[first_index],
    };

    try game.loadLevel(1);
    try std.testing.expect(game.world.enemies.resolve(stale_handle) == null);
    try std.testing.expect(game.world.enemies.len() > 0);
}

test "loadLevel keeps perm_arena capacity stable across reloads" {
    var game: Game = undefined;
    try game.init(std.testing.allocator, .{}, 800, 600, 13);
    defer game.deinit();

    try game.loadLevel(0);
    const first_cap = game.perm_arena.queryCapacity();
    try game.loadLevel(0);
    const second_cap = game.perm_arena.queryCapacity();
    try game.loadLevel(0);
    const third_cap = game.perm_arena.queryCapacity();

    try std.testing.expectEqual(first_cap, second_cap);
    try std.testing.expectEqual(first_cap, third_cap);
}

test "Playing.score accumulates across simulated kills" {
    var p = state_mod.fresh();
    const kinds = [_]world_mod.EnemyKind{ .grunt, .zako, .goei, .grunt, .zako };
    for (kinds) |k| p.score += state_mod.killScore(k);
    const expected: u32 = state_mod.killScore(.grunt) * 2 +
        state_mod.killScore(.zako) * 2 +
        state_mod.killScore(.goei);
    try std.testing.expectEqual(expected, p.score);
}

test "state transition table: attract+key, pause toggle, death paths, game_over expiry" {
    var game: Game = undefined;
    try game.init(std.testing.allocator, .{}, 800, 600, 17);
    defer game.deinit();

    // attract → playing via loadLevel
    try std.testing.expect(std.meta.activeTag(game.state) == .attract);
    game.state = .{ .playing = state_mod.fresh() };
    try game.loadLevel(0);
    try std.testing.expect(std.meta.activeTag(game.state) == .playing);
    try std.testing.expectEqual(@as(u8, state_mod.starting_lives), game.state.playing.lives);

    // playing → paused (snapshot Playing by value)
    const before_pause = game.state.playing;
    game.state = .{ .paused = before_pause };
    try std.testing.expect(std.meta.activeTag(game.state) == .paused);

    // paused → playing (resume preserves snapshot)
    game.state = .{ .playing = game.state.paused };
    try std.testing.expect(std.meta.activeTag(game.state) == .playing);
    try std.testing.expectEqual(before_pause.score, game.state.playing.score);
    try std.testing.expectEqual(before_pause.lives, game.state.playing.lives);

    // playing + player death with lives > 0 → respawn (state stays .playing)
    game.state.playing.lives = 2;
    game.world.player.dead = true;
    _ = game.finishDeath(&game.state.playing);
    try std.testing.expect(std.meta.activeTag(game.state) == .playing);
    try std.testing.expect(!game.world.player.dead);
    try std.testing.expectEqual(@as(u8, 1), game.state.playing.lives);

    // playing + player death with lives == 1 → game_over
    game.state.playing.lives = 1;
    game.world.player.dead = true;
    _ = game.finishDeath(&game.state.playing);
    try std.testing.expect(std.meta.activeTag(game.state) == .game_over);
    try std.testing.expectEqual(game.state.game_over.timer_s, state_mod.game_over_s);

    // game_over timer expiry → attract
    game.state.game_over.timer_s = 0;
    if (game.state.game_over.timer_s == 0) game.state = .attract;
    try std.testing.expect(std.meta.activeTag(game.state) == .attract);
}
