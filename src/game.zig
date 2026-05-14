//! Game-owned lifetime state and outer frame loop.

const std = @import("std");
const rl = @import("raylib");

const audio_mod = @import("audio.zig");
const levels_mod = @import("levels.zig");
const math = @import("math.zig");
const replay = @import("replay.zig");
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
pub const Recorder = replay.Recorder;
pub const Replayer = replay.Replayer;

const max_ticks_per_frame: u32 = 5;
const player_size: f32 = 28.0;
const bullet_draw_radius: f32 = 6.0;
const enemy_draw_radius: f32 = 22.0;
const fire_cooldown_ticks_default: u8 = 8;

const default_asset_root: []const u8 = "assets/";

/// `record` carries an extra `finished` flag because the spec records ONLY the
/// first playing session; on game_over we finalize and stop writing. Replay
/// modes borrow a Replayer that main owns.
pub const Mode = union(enum) {
    normal,
    record: RecordMode,
    replay_watch: *Replayer,
    replay_speed: *Replayer,
};

pub const RecordMode = struct {
    recorder: *Recorder,
    finished: bool = false,
};

/// Replay reads the seed from the trace; everything else uses a literal.
pub const SeedSource = union(enum) {
    literal: u64,
    replayer: *Replayer,
};

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
    /// `world.player.pos` immediately before the most recent sim tick.
    /// `drawCurrent` lerps from prev → cur with `alpha = accumulator / sim_dt`
    /// so the player isn't visually quantized into sim_dt jumps when
    /// `frame_dt` straddles the boundary. Render-only — replay-irrelevant.
    prev_player_pos: Vec2,
    audio: Audio,
    shake: Shake,
    state: State,
    fire_cooldown: u8,
    window_w: i32,
    window_h: i32,
    /// Asset paths resolved at init and owned by the gpa for Game's lifetime.
    /// `asset_root` prefers `<getApplicationDirectory()>../assets/` (installed
    /// layout from `b.installDirectory` → `zig-out/assets/`), falling back to
    /// cwd-relative `assets/` for tests / untweaked source-tree runs. `sfx_prefix`
    /// and `music_prefix` are derived from it; `Audio` borrows both. Allocated
    /// strings handle arbitrary install-prefix depths without truncation.
    asset_root: []const u8,
    sfx_prefix: []const u8,
    music_prefix: []const u8,
    mode: Mode,
    should_exit: bool,

    pub fn init(
        self: *Game,
        gpa: std.mem.Allocator,
        caps: world_mod.WorldCaps,
        window_w: i32,
        window_h: i32,
        seed_source: SeedSource,
        mode: Mode,
    ) !void {
        const seed: u64 = switch (seed_source) {
            .literal => |v| v,
            .replayer => |rp| rp.seed,
        };

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
        self.prev_player_pos = self.world.player.pos;

        self.input = world_mod.Input.zero;
        self.accumulator = 0;
        self.audio.init();
        self.shake = Shake.init(self.shake_prng);
        self.state = .attract;
        self.fire_cooldown = 0;
        self.window_w = window_w;
        self.window_h = window_h;
        self.mode = mode;
        self.should_exit = false;

        self.asset_root = try resolveAssetRoot(gpa);
        errdefer gpa.free(self.asset_root);
        self.sfx_prefix = try std.fmt.allocPrint(gpa, "{s}sfx/", .{self.asset_root});
        errdefer gpa.free(self.sfx_prefix);
        self.music_prefix = try std.fmt.allocPrint(gpa, "{s}music/", .{self.asset_root});
        errdefer gpa.free(self.music_prefix);
        self.audio.setAssetRoots(self.sfx_prefix, self.music_prefix);
    }

    pub fn deinit(self: *Game) void {
        self.audio.deinit();
        self.gpa.free(self.music_prefix);
        self.gpa.free(self.sfx_prefix);
        self.gpa.free(self.asset_root);
        self.world.deinit(self.gpa);
        self.gpa.destroy(self.shake_prng);
        self.gpa.destroy(self.sim_prng);
        self.perm_arena.deinit();
        self.frame_arena.deinit();
        self.* = undefined;
    }

    pub fn frame(self: *Game) !void {
        _ = self.frame_arena.reset(.retain_capacity);
        switch (self.mode) {
            .replay_speed => |rep| {
                try self.frameReplaySpeed(rep);
                return;
            },
            .replay_watch => |rep| {
                if (rl.windowShouldClose()) {
                    self.should_exit = true;
                    return;
                }
                try self.frameReplayWatch(rep);
                return;
            },
            .normal, .record => {
                if (rl.windowShouldClose()) {
                    self.should_exit = true;
                    return;
                }
            },
        }
        self.input = pollInput();
        switch (self.state) {
            .attract => try self.frameAttract(),
            .playing => |*p| try self.framePlaying(p),
            .paused => |*p| self.framePaused(p),
            .game_over => |*g| self.frameGameOver(g),
        }
    }

    /// Headless replay: pure sim, no audio/render/particles/shake. The trace
    /// captures only `playing`-state ticks (and only the first session), so
    /// jump straight there on the first tick and stop when exhausted.
    fn frameReplaySpeed(self: *Game, rep: *Replayer) !void {
        if (self.state == .attract) {
            self.state = .{ .playing = state_mod.fresh() };
            try self.loadLevel(0);
        }
        while (try rep.nextTick()) |input| {
            systems.simTick(&self.world, &self.audio, &self.shake, input, sim_dt);
        }
        self.should_exit = true;
    }

    /// Visual replay: one recorded tick per frame, full rendering, no
    /// accumulator. raylib's `setTargetFPS(60)` paces the loop to sim_dt.
    fn frameReplayWatch(self: *Game, rep: *Replayer) !void {
        if (self.state == .attract) {
            self.state = .{ .playing = state_mod.fresh() };
            try self.loadLevel(0);
        }
        const maybe = try rep.nextTick();
        if (maybe) |input| {
            systems.simTick(&self.world, &self.audio, &self.shake, input, sim_dt);
        } else {
            self.should_exit = true;
        }
        const frame_dt = rl.getFrameTime();
        systems.updateParticles(&self.world, frame_dt);
        self.shake.update(frame_dt);
        self.audio.updateMusic(frame_dt);
        _ = self.audio.flush();
        self.drawCurrent();
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
        // raylib on macOS HIGHDPI uses two coord systems at once: shapes (and the
        // Camera2D transform) operate in framebuffer PIXELS; drawText/measureText
        // operate in POINTS. So we zoom the world's point coords up to pixels
        // inside the camera, and pass window_w/window_h (points) to text-based
        // overlays for correct centering. Full-screen dim rectangles use
        // getRenderWidth/Height (pixels) since drawRectangle is a shape.
        const rh = rl.getRenderHeight();
        const zoom = @as(f32, @floatFromInt(rh)) / self.world.bounds.height;
        const off = self.shake.offset();
        const camera: rl.Camera2D = .{
            .offset = .{ .x = off.x, .y = off.y },
            .target = .{ .x = 0, .y = 0 },
            .rotation = 0,
            .zoom = zoom,
        };
        // Fixed-timestep alias kill: lerp player draw position from the
        // pre-tick snapshot to the post-tick state. Render-only — sim never
        // sees `alpha`, so determinism / replay are unaffected.
        const alpha = std.math.clamp(self.accumulator / sim_dt, 0, 1);
        const draw_player_pos = Vec2.lerp(self.prev_player_pos, self.world.player.pos, alpha);

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
            if (!self.world.player.dead) drawPlayer(draw_player_pos);
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
            // Spec: record only the first playing session. Finalize once on
            // the first game_over and skip subsequent attract→playing cycles.
            switch (self.mode) {
                .record => |*rm| if (!rm.finished) {
                    rm.recorder.finalize() catch |err| {
                        std.log.warn("record: finalize failed: {s}", .{@errorName(err)});
                    };
                    rm.finished = true;
                },
                else => {},
            }
            return true;
        }
        // Respawn: revive player + scrub stale projectiles/particles. Enemies stay.
        self.world.player = world_mod.Player.init(self.world.bounds);
        self.prev_player_pos = self.world.player.pos;
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

        const def = try levels_mod.loadLevelDef(self.perm_arena.allocator(), self.asset_root, level_index);

        self.world.player = world_mod.Player.init(self.world.bounds);
        self.prev_player_pos = self.world.player.pos;
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
            // One record per sim tick, not per frame. A 33ms frame draining two
            // ticks writes two identical-payload records — replay drives each
            // tick separately.
            switch (self.mode) {
                .record => |*rm| if (!rm.finished and self.state == .playing) {
                    rm.recorder.writeTick(gated) catch |err| {
                        std.log.warn("record: writeTick failed: {s}", .{@errorName(err)});
                    };
                },
                else => {},
            }
            self.prev_player_pos = self.world.player.pos;
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

/// Probes `<getApplicationDirectory()>../assets/levels/01.zon`; if present, we
/// own an installed binary and assets live under the install prefix. Otherwise
/// falls back to cwd-relative `assets/` (dev source tree, tests). Returned
/// slice is owned by the caller's `gpa`.
fn resolveAssetRoot(gpa: std.mem.Allocator) ![]const u8 {
    const app_dir = rl.getApplicationDirectory();
    var probe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const probe = std.fmt.bufPrintZ(
        &probe_buf,
        "{s}../assets/levels/01.zon",
        .{app_dir},
    ) catch {
        return try gpa.dupe(u8, default_asset_root);
    };
    if (rl.fileExists(probe)) {
        return try std.fmt.allocPrint(gpa, "{s}../assets/", .{app_dir});
    }
    return try gpa.dupe(u8, default_asset_root);
}

fn pollInput() world_mod.Input {
    var thrust = Vec2.zero;
    if (rl.isKeyDown(.w)) thrust.y -= 1;
    if (rl.isKeyDown(.s)) thrust.y += 1;
    if (rl.isKeyDown(.a)) thrust.x -= 1;
    if (rl.isKeyDown(.d)) thrust.x += 1;
    return .{ .thrust = thrust, .fire = rl.isKeyDown(.space) };
}

fn drawPlayer(pos: Vec2) void {
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
    // Full-canvas dim: drawRectangle is a shape, so size in framebuffer pixels.
    rl.drawRectangle(0, 0, rl.getRenderWidth(), rl.getRenderHeight(), dim);

    const text = "PAUSED";
    const size: i32 = 64;
    const text_w = rl.measureText(text, size);
    rl.drawText(text, @divTrunc(window_w - text_w, 2), @divTrunc(window_h - size, 2), size, rl.Color.white);
}

fn drawGameOverOverlay(window_w: i32, window_h: i32, g: GameOver) void {
    const dim = rl.Color.init(0, 0, 0, 180);
    rl.drawRectangle(0, 0, rl.getRenderWidth(), rl.getRenderHeight(), dim);

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
    try game.init(std.testing.allocator, .{}, 800, 600, .{ .literal = 123 }, .normal);
    defer game.deinit();

    const before = game.world.player.pos.x;
    game.runSimTicks(.{ .thrust = .{ .x = 1, .y = 0 }, .fire = false }, 1);

    try std.testing.expect(game.accumulator < sim_dt);
    const expected = before + max_ticks_per_frame * 300 * sim_dt;
    try std.testing.expectApproxEqAbs(expected, game.world.player.pos.x, 0.000_001);
}

test "prev_player_pos enables continuous draw-pos across 0-tick / 2-tick alias" {
    var game: Game = undefined;
    try game.init(std.testing.allocator, .{}, 800, 600, .{ .literal = 123 }, .normal);
    defer game.deinit();

    const input: world_mod.Input = .{ .thrust = .{ .x = 1, .y = 0 }, .fire = false };

    // Frame 1: slightly-fast frame, no tick runs. Accumulator carries.
    const fast_dt: f32 = sim_dt * 0.9;
    const cur_before = game.world.player.pos;
    game.runSimTicks(input, fast_dt);
    try std.testing.expectEqual(cur_before, game.world.player.pos);
    const alpha_fast = std.math.clamp(game.accumulator / sim_dt, 0, 1);
    const draw_fast = Vec2.lerp(game.prev_player_pos, game.world.player.pos, alpha_fast);
    try std.testing.expectEqual(cur_before.x, draw_fast.x);

    // Frame 2: slightly-slow frame, two ticks run. Without interpolation the
    // player jumps 2*sim_dt*speed; with the lerp the draw position should fall
    // smoothly between the pre-second-tick snapshot and the post-second-tick
    // pos by `alpha` of one tick's worth of motion.
    const slow_dt: f32 = sim_dt * 1.1;
    game.runSimTicks(input, slow_dt);
    const ticks_per_frame_speed: f32 = 300 * sim_dt;
    const alpha_slow = std.math.clamp(game.accumulator / sim_dt, 0, 1);
    const draw_slow = Vec2.lerp(game.prev_player_pos, game.world.player.pos, alpha_slow);
    // Draw position must advance from frame 1 to frame 2 by less than two
    // ticks' worth — i.e. the lerp killed the 2x jump.
    const naive_jump = 2 * ticks_per_frame_speed;
    try std.testing.expect(draw_slow.x - draw_fast.x < naive_jump);
    // And by more than zero — we're still making progress.
    try std.testing.expect(draw_slow.x > draw_fast.x);
}

test "Game init cleans up after allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initGameForFailureTest, .{});
}

fn initGameForFailureTest(allocator: std.mem.Allocator) !void {
    var game: Game = undefined;
    try game.init(allocator, .{}, 800, 600, .{ .literal = 123 }, .normal);
    game.deinit();
}

test "fire cooldown gates bullets to one per cooldown window" {
    var game: Game = undefined;
    try game.init(std.testing.allocator, .{}, 800, 600, .{ .literal = 99 }, .normal);
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
    try game.init(std.testing.allocator, .{}, 800, 600, .{ .literal = 7 }, .normal);
    defer game.deinit();

    try std.testing.expect(std.meta.activeTag(game.state) == .attract);
}

test "loadLevel populates enemies and invalidates prior handles" {
    var game: Game = undefined;
    try game.init(std.testing.allocator, .{}, 800, 600, .{ .literal = 11 }, .normal);
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
    try game.init(std.testing.allocator, .{}, 800, 600, .{ .literal = 13 }, .normal);
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
    try game.init(std.testing.allocator, .{}, 800, 600, .{ .literal = 17 }, .normal);
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

    // paused → playing (resume preserves snapshot). The carryover must be
    // copied out before reassigning self.state — Zig sets the new tag before
    // evaluating the RHS, so reading `game.state.paused` inline panics.
    const carried = game.state.paused;
    game.state = .{ .playing = carried };
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
