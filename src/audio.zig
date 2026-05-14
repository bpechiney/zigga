//! Frame-batched SFX event queue plus music streaming + crossfade.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");

pub const Tag = enum {
    shot,
    bullet_hit_enemy,
    bullet_hit_wall,
    enemy_dive,
    enemy_explode,
    player_explode,
};

pub const Policy = enum {
    always,
    coalesce,
    latest,
};

pub const MusicTrack = enum { none, level_1, level_2, level_3 };

pub const Event = struct {
    tag: Tag,
    variant: u8,
};

pub const FlushStats = struct {
    distinct_plays: u32,
    total_plays: u32,
};

const default_base_volume: f32 = 1.0;
const default_sfx_prefix: []const u8 = "assets/sfx/";
const default_music_prefix: []const u8 = "assets/music/";
const crossfade_duration_s: f32 = 1.5;

const FadeMode = enum { none, crossfade, fade_in, fade_out };

/// Music streaming and crossfade ramp state. Three fade modes:
///   - fade_in:   current ramps 0→1; no `next`.
///   - crossfade: current ramps start→0, next ramps 0→1; promote `next` at the end.
///   - fade_out:  current ramps start→0; unload at the end.
/// `current_fade_start` is the value `current_volume` had when the active fade
/// began — so `stopMusic` mid-fade-in ramps from the current partial value
/// down to 0 instead of jumping back to full volume first.
pub const MusicState = struct {
    current: ?rl.Music = null,
    current_volume: f32 = 0,
    current_fade_start: f32 = 0,
    current_track: MusicTrack = .none,
    next: ?rl.Music = null,
    next_volume: f32 = 0,
    next_track: MusicTrack = .none,
    crossfade_s: f32 = crossfade_duration_s,
    crossfade_t: f32 = 0,
    fade_mode: FadeMode = .none,
};

pub const Audio = struct {
    pending_buf: [256]Event = undefined,
    pending: std.ArrayList(Event),
    sounds: std.EnumArray(Tag, rl.Sound),
    sound_loaded: std.EnumArray(Tag, bool),
    use_fallback: std.EnumArray(Tag, bool),
    policies: std.EnumArray(Tag, Policy),
    base_volume: std.EnumArray(Tag, f32),
    music: MusicState,
    playback_enabled: bool,
    /// Borrowed prefixes — the owning `Game` keeps the backing storage alive
    /// for Audio's lifetime, so no fixed buffers / silent truncation here.
    /// `Audio.init` seeds them with the cwd-relative defaults; `setAssetRoots`
    /// swaps in `Game`'s allocator-owned paths after `Game.init` resolves them.
    sfx_prefix: []const u8,
    music_prefix: []const u8,

    pub fn init(self: *Audio) void {
        self.pending = std.ArrayList(Event).initBuffer(&self.pending_buf);
        self.sounds = std.EnumArray(Tag, rl.Sound).initUndefined();
        self.sound_loaded = std.EnumArray(Tag, bool).initFill(false);
        self.use_fallback = std.EnumArray(Tag, bool).initFill(true);
        self.policies = defaultPolicies();
        self.base_volume = std.EnumArray(Tag, f32).initFill(default_base_volume);
        self.music = .{};
        self.playback_enabled = false;
        self.sfx_prefix = default_sfx_prefix;
        self.music_prefix = default_music_prefix;
        self.resolveSfxSources(self.sfx_prefix);
    }

    /// Borrow the caller-owned asset prefixes (no copy). The caller must keep
    /// the backing storage valid until Audio.deinit. Trailing slash required.
    pub fn setAssetRoots(self: *Audio, sfx_prefix: []const u8, music_prefix: []const u8) void {
        self.sfx_prefix = sfx_prefix;
        self.music_prefix = music_prefix;
        self.resolveSfxSources(self.sfx_prefix);
    }

    pub fn deinit(self: *Audio) void {
        if (self.playback_enabled) {
            var it = self.sound_loaded.iterator();
            while (it.next()) |entry| {
                if (entry.value.*) rl.unloadSound(self.sounds.get(entry.key));
            }
            if (self.music.current) |m| rl.unloadMusicStream(m);
            if (self.music.next) |m| rl.unloadMusicStream(m);
        }
        self.* = undefined;
    }

    /// Decides per-tag whether to use a real asset or the placeholder sine wave.
    /// Pure file-existence check — does not touch raylib's audio device, so it
    /// is safe to run in unit tests with no audio context.
    pub fn resolveSfxSources(self: *Audio, prefix: []const u8) void {
        var missing_count: u32 = 0;
        inline for (@typeInfo(Tag).@"enum".fields) |field| {
            const tag = @field(Tag, field.name);
            const found = sfxFileExists(prefix, field.name);
            self.use_fallback.set(tag, !found);
            if (!found) missing_count += 1;
        }
        // One summary line per resolve, suppressed in test mode — the
        // orchestrated test runner's `--listen=-` pipe deadlocks under
        // accumulated stderr from many tests.
        if (missing_count > 0 and !builtin.is_test) std.log.warn(
            "audio: {d} sfx file(s) missing under {s}, using placeholder sines",
            .{ missing_count, prefix },
        );
    }

    /// Lights up real raylib playback. Caller must have initialized the audio
    /// device. Loads sounds either from disk or from placeholder waves based on
    /// what `resolveSfxSources` decided.
    pub fn enablePlayback(self: *Audio) void {
        self.playback_enabled = true;
        const sample_rate: u32 = 22_050;
        const prefix = self.sfx_prefix;
        inline for (@typeInfo(Tag).@"enum".fields) |field| {
            const tag = @field(Tag, field.name);
            self.sounds.set(tag, loadSfx(tag, self.use_fallback.get(tag), prefix, sample_rate));
            self.sound_loaded.set(tag, true);
        }
    }

    pub fn emit(self: *Audio, tag: Tag, variant: u8) void {
        self.pending.appendBounded(.{ .tag = tag, .variant = variant }) catch {};
    }

    pub fn clearPending(self: *Audio) void {
        self.pending.clearRetainingCapacity();
    }

    /// Starts the right kind of fade to reach `track`. Calling with the
    /// currently-playing track is a no-op; calling mid-fade snaps the in-flight
    /// fade to completion first so handles never leak.
    pub fn playMusic(self: *Audio, track: MusicTrack) void {
        if (track == .none) {
            self.stopMusic();
            return;
        }
        if (self.music.fade_mode == .none and self.music.current_track == track) return;
        if (self.music.fade_mode != .none) self.finalizeCrossfade();

        const incoming: ?rl.Music = if (self.playback_enabled) loadMusicTrack(self.music_prefix, track) else null;
        if (incoming) |m| {
            rl.playMusicStream(m);
            rl.setMusicVolume(m, 0);
        }

        if (self.music.current == null) {
            self.music.current = incoming;
            self.music.current_track = track;
            self.music.current_volume = 0;
            self.music.current_fade_start = 0;
            self.music.fade_mode = .fade_in;
        } else {
            self.music.next = incoming;
            self.music.next_track = track;
            self.music.next_volume = 0;
            // Capture the partial volume so crossfades that follow a mid-fade-in
            // start from the actual current value, not a hard-coded 1.0.
            self.music.current_fade_start = self.music.current_volume;
            self.music.fade_mode = .crossfade;
        }
        self.music.crossfade_t = 0;
    }

    pub fn stopMusic(self: *Audio) void {
        if (self.music.fade_mode == .crossfade) self.finalizeCrossfade();
        // Empty-check via `current_track`, not `current`: with `playback_enabled
        // = false` the stream handle is always null but the track + fade state
        // still progress, and the test harness exercises exactly that path.
        if (self.music.current_track == .none and self.music.fade_mode == .none) {
            self.music = .{};
            return;
        }
        // Snapshot the live volume so the fade-out ramps from wherever we are
        // (e.g. mid fade-in at 0.4) instead of jumping back to 1.0 first.
        self.music.current_fade_start = self.music.current_volume;
        self.music.fade_mode = .fade_out;
        self.music.crossfade_t = 0;
    }

    /// Pumps raylib's music stream and advances the ramp. Must run ONCE per
    /// frame at display rate — `updateMusicStream` needs wall-clock cadence
    /// to keep the decode buffer fed; per-sim-tick calls would starve audio
    /// on slow frames and double-feed on fast ones.
    pub fn updateMusic(self: *Audio, frame_dt: f32) void {
        if (!self.playback_enabled) {
            // Still progress the ramp so tests can observe state transitions.
            if (self.music.fade_mode != .none) self.advanceFade(frame_dt);
            return;
        }
        if (self.music.current) |m| rl.updateMusicStream(m);
        if (self.music.next) |m| rl.updateMusicStream(m);
        if (self.music.fade_mode == .none) {
            if (self.music.current) |m| rl.setMusicVolume(m, self.music.current_volume);
            return;
        }
        self.advanceFade(frame_dt);
        if (self.music.current) |m| rl.setMusicVolume(m, self.music.current_volume);
        if (self.music.next) |m| rl.setMusicVolume(m, self.music.next_volume);
    }

    fn advanceFade(self: *Audio, frame_dt: f32) void {
        self.music.crossfade_t = @min(self.music.crossfade_s, self.music.crossfade_t + frame_dt);
        const ratio = self.music.crossfade_t / self.music.crossfade_s;
        const start = self.music.current_fade_start;
        switch (self.music.fade_mode) {
            .none => {},
            .fade_in => self.music.current_volume = ratio,
            .crossfade => {
                self.music.current_volume = start * (1.0 - ratio);
                self.music.next_volume = ratio;
            },
            .fade_out => self.music.current_volume = start * (1.0 - ratio),
        }
        if (self.music.crossfade_t >= self.music.crossfade_s) self.finalizeCrossfade();
    }

    fn finalizeCrossfade(self: *Audio) void {
        switch (self.music.fade_mode) {
            .none => return,
            .fade_in => self.music.current_volume = 1,
            .crossfade => {
                if (self.music.current) |old| {
                    if (self.playback_enabled) rl.unloadMusicStream(old);
                }
                self.music.current = self.music.next;
                self.music.current_track = self.music.next_track;
                self.music.current_volume = 1;
                if (self.playback_enabled) if (self.music.current) |m| rl.setMusicVolume(m, 1);
                self.music.next = null;
                self.music.next_track = .none;
                self.music.next_volume = 0;
            },
            .fade_out => {
                if (self.music.current) |old| {
                    if (self.playback_enabled) rl.unloadMusicStream(old);
                }
                self.music.current = null;
                self.music.current_track = .none;
                self.music.current_volume = 0;
            },
        }
        self.music.fade_mode = .none;
        self.music.crossfade_t = 0;
    }

    /// Buckets pending events by tag, applies the per-tag policy, and clears the queue.
    /// Returned stats are for test verification; the queue is always drained.
    pub fn flush(self: *Audio) FlushStats {
        var counts = std.EnumArray(Tag, u32).initFill(0);
        var last_variant = std.EnumArray(Tag, u8).initFill(0);
        for (self.pending.items) |event| {
            const current = counts.get(event.tag);
            counts.set(event.tag, current + 1);
            last_variant.set(event.tag, event.variant);
        }

        var distinct: u32 = 0;
        var total: u32 = 0;
        var it = counts.iterator();
        while (it.next()) |entry| {
            const count = entry.value.*;
            if (count == 0) continue;
            const tag = entry.key;
            const policy = self.policies.get(tag);
            const base = self.base_volume.get(tag);
            distinct += 1;
            switch (policy) {
                .always => {
                    var i: u32 = 0;
                    while (i < count) : (i += 1) self.playOne(tag, base);
                    total += count;
                },
                .coalesce => {
                    const count_f: f32 = @floatFromInt(count);
                    const volume = base * (1.0 - 1.0 / (1.0 + 0.5 * count_f));
                    self.playOne(tag, volume);
                    total += 1;
                },
                .latest => {
                    self.playOne(tag, base);
                    total += 1;
                    _ = last_variant.get(tag);
                },
            }
        }

        self.pending.clearRetainingCapacity();
        return .{ .distinct_plays = distinct, .total_plays = total };
    }

    fn playOne(self: *Audio, tag: Tag, volume: f32) void {
        if (!self.playback_enabled) return;
        if (!self.sound_loaded.get(tag)) return;
        const sound = self.sounds.get(tag);
        rl.setSoundVolume(sound, volume);
        rl.playSound(sound);
    }
};

fn defaultPolicies() std.EnumArray(Tag, Policy) {
    var out = std.EnumArray(Tag, Policy).initUndefined();
    out.set(.shot, .coalesce);
    out.set(.bullet_hit_enemy, .coalesce);
    out.set(.bullet_hit_wall, .coalesce);
    out.set(.enemy_dive, .always);
    out.set(.enemy_explode, .always);
    out.set(.player_explode, .always);
    return out;
}

fn placeholderFreq(tag: Tag) f32 {
    return switch (tag) {
        .shot => 880,
        .bullet_hit_enemy => 440,
        .bullet_hit_wall => 220,
        .enemy_dive => 330,
        .enemy_explode => 110,
        .player_explode => 73,
    };
}

fn sfxFileExists(prefix: []const u8, name: []const u8) bool {
    // PATH_MAX so deep install prefixes still resolve. Overflow falls back to
    // the placeholder wave — same outcome as a missing file from raylib's view.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}{s}.wav", .{ prefix, name }) catch return false;
    return rl.fileExists(path);
}

fn loadSfx(tag: Tag, use_fallback: bool, prefix: []const u8, sample_rate: u32) rl.Sound {
    if (use_fallback) return loadPlaceholder(tag, sample_rate);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(
        &path_buf,
        "{s}{s}.wav",
        .{ prefix, @tagName(tag) },
    ) catch return loadPlaceholder(tag, sample_rate);
    return rl.loadSound(path) catch {
        std.log.warn("audio: load failed for {s}, falling back", .{path});
        return loadPlaceholder(tag, sample_rate);
    };
}

fn loadPlaceholder(tag: Tag, sample_rate: u32) rl.Sound {
    // loadSoundFromWave copies the sample data; we deliberately do NOT call
    // unloadWave here because wave.data points at static storage and raylib's
    // UnloadWave would free() that pointer (UB).
    const wave = makeSineWave(sample_rate, placeholderFreq(tag));
    return rl.loadSoundFromWave(wave);
}

fn loadMusicTrack(prefix: []const u8, track: MusicTrack) ?rl.Music {
    const name = switch (track) {
        .none => return null,
        .level_1 => "level_1",
        .level_2 => "level_2",
        .level_3 => "level_3",
    };
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(
        &path_buf,
        "{s}{s}.ogg",
        .{ prefix, name },
    ) catch return null;
    if (!rl.fileExists(path)) {
        std.log.warn("audio: missing {s}, music silent for this track", .{path});
        return null;
    }
    return rl.loadMusicStream(path) catch {
        std.log.warn("audio: failed to load {s}", .{path});
        return null;
    };
}

const placeholder_frames: u32 = 4_410;
var placeholder_sample_buffer: [placeholder_frames]i16 = undefined;

fn makeSineWave(sample_rate: u32, freq: f32) rl.Wave {
    const rate_f: f32 = @floatFromInt(sample_rate);
    var i: usize = 0;
    while (i < placeholder_sample_buffer.len) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / rate_f;
        const v = @sin(t * std.math.tau * freq);
        const fade = 1.0 - @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(placeholder_sample_buffer.len));
        const sample: f32 = v * fade * 16_000;
        placeholder_sample_buffer[i] = @intFromFloat(sample);
    }
    return .{
        .frameCount = @as(c_uint, @intCast(placeholder_sample_buffer.len)),
        .sampleRate = @as(c_uint, @intCast(sample_rate)),
        .sampleSize = 16,
        .channels = 1,
        .data = @ptrCast(&placeholder_sample_buffer),
    };
}

test "Audio.flush coalesces simultaneous events into one play" {
    var audio: Audio = undefined;
    audio.init();
    defer audio.deinit();

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        audio.emit(.bullet_hit_enemy, 0);
    }
    const stats = audio.flush();
    try std.testing.expectEqual(@as(u32, 1), stats.distinct_plays);
    try std.testing.expectEqual(@as(u32, 1), stats.total_plays);
    try std.testing.expectEqual(@as(usize, 0), audio.pending.items.len);
}

test "Audio.flush always-policy plays once per event" {
    var audio: Audio = undefined;
    audio.init();
    defer audio.deinit();

    audio.emit(.enemy_explode, 0);
    audio.emit(.enemy_explode, 1);
    audio.emit(.enemy_explode, 2);
    const stats = audio.flush();
    try std.testing.expectEqual(@as(u32, 1), stats.distinct_plays);
    try std.testing.expectEqual(@as(u32, 3), stats.total_plays);
}

test "Audio.flush mixes coalesce and always tags" {
    var audio: Audio = undefined;
    audio.init();
    defer audio.deinit();

    audio.emit(.shot, 0);
    audio.emit(.shot, 0);
    audio.emit(.enemy_explode, 0);
    audio.emit(.enemy_explode, 0);
    const stats = audio.flush();
    try std.testing.expectEqual(@as(u32, 2), stats.distinct_plays);
    try std.testing.expectEqual(@as(u32, 3), stats.total_plays);
}

test "Audio.clearPending drops queued events" {
    var audio: Audio = undefined;
    audio.init();
    defer audio.deinit();

    audio.emit(.shot, 0);
    audio.clearPending();
    const stats = audio.flush();
    try std.testing.expectEqual(@as(u32, 0), stats.distinct_plays);
    try std.testing.expectEqual(@as(u32, 0), stats.total_plays);
}

test "Audio.emit drops silently when queue is full" {
    var audio: Audio = undefined;
    audio.init();
    defer audio.deinit();

    var i: u32 = 0;
    while (i < audio.pending_buf.len + 50) : (i += 1) {
        audio.emit(.shot, 0);
    }
    try std.testing.expectEqual(audio.pending_buf.len, audio.pending.items.len);
}

test "Audio fade ramps current_volume on fade_in" {
    var audio: Audio = undefined;
    audio.init();
    defer audio.deinit();

    audio.playMusic(.level_1);
    try std.testing.expect(audio.music.fade_mode == .fade_in);
    audio.updateMusic(crossfade_duration_s);
    try std.testing.expect(audio.music.fade_mode == .none);
    try std.testing.expectEqual(MusicTrack.level_1, audio.music.current_track);
}

test "Audio.stopMusic during fade_in ramps from the partial volume, no jump" {
    var audio: Audio = undefined;
    audio.init();
    defer audio.deinit();

    audio.playMusic(.level_1);
    try std.testing.expect(audio.music.fade_mode == .fade_in);
    // Walk to ~40% of the fade-in ramp; current_volume should be ~0.4.
    audio.updateMusic(crossfade_duration_s * 0.4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), audio.music.current_volume, 1e-5);

    audio.stopMusic();
    try std.testing.expect(audio.music.fade_mode == .fade_out);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), audio.music.current_fade_start, 1e-5);
    // Immediately after the switch, volume must not have jumped back to 1.0.
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), audio.music.current_volume, 1e-5);

    // Half-way through the fade-out, volume should be ~0.2 (0.4 * 0.5).
    audio.updateMusic(crossfade_duration_s * 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), audio.music.current_volume, 1e-5);

    // Completing the fade clears state.
    audio.updateMusic(crossfade_duration_s);
    try std.testing.expectEqual(MusicTrack.none, audio.music.current_track);
}

test "Audio.stopMusic kicks off a fade_out from a settled state" {
    var audio: Audio = undefined;
    audio.init();
    defer audio.deinit();

    // Pretend we've finished a fade-in: a track is "playing" at full volume.
    audio.music.current_track = .level_1;
    audio.music.current_volume = 1;
    audio.music.fade_mode = .none;
    audio.music.current = null; // no real stream but track is set

    audio.stopMusic();
    try std.testing.expect(audio.music.fade_mode == .fade_out);
    try std.testing.expectApproxEqAbs(@as(f32, 1), audio.music.current_fade_start, 1e-5);

    audio.updateMusic(crossfade_duration_s);
    try std.testing.expectEqual(MusicTrack.none, audio.music.current_track);
}

test "Audio resolves to fallback when sfx files are absent" {
    var audio: Audio = undefined;
    audio.init();
    defer audio.deinit();

    audio.resolveSfxSources("definitely/not/a/real/dir/");
    var it = audio.use_fallback.iterator();
    while (it.next()) |entry| {
        try std.testing.expect(entry.value.*);
    }
}
