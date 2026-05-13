//! Frame-batched SFX event queue plus music stubs.

const std = @import("std");
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

pub const MusicTrack = enum { none, gameplay, menu };

pub const Event = struct {
    tag: Tag,
    variant: u8,
};

pub const FlushStats = struct {
    distinct_plays: u32,
    total_plays: u32,
};

const default_base_volume: f32 = 1.0;

pub const Audio = struct {
    pending_buf: [256]Event = undefined,
    pending: std.ArrayList(Event),
    sounds: std.EnumArray(Tag, rl.Sound),
    sound_loaded: std.EnumArray(Tag, bool),
    policies: std.EnumArray(Tag, Policy),
    base_volume: std.EnumArray(Tag, f32),
    music_state: MusicTrack,
    playback_enabled: bool,

    pub fn init(self: *Audio) void {
        self.pending = std.ArrayList(Event).initBuffer(&self.pending_buf);
        self.sounds = std.EnumArray(Tag, rl.Sound).initUndefined();
        self.sound_loaded = std.EnumArray(Tag, bool).initFill(false);
        self.policies = defaultPolicies();
        self.base_volume = std.EnumArray(Tag, f32).initFill(default_base_volume);
        self.music_state = .none;
        self.playback_enabled = false;
    }

    pub fn deinit(self: *Audio) void {
        if (self.playback_enabled) {
            var it = self.sound_loaded.iterator();
            while (it.next()) |entry| {
                if (entry.value.*) {
                    rl.unloadSound(self.sounds.get(entry.key));
                }
            }
        }
        self.* = undefined;
    }

    /// Lights up real raylib playback. Caller is responsible for having
    /// initialized the audio device. Safe to skip in unit tests.
    pub fn enablePlayback(self: *Audio) void {
        self.playback_enabled = true;
        const sample_rate: u32 = 22_050;
        var it = self.sounds.iterator();
        while (it.next()) |entry| {
            const freq = placeholderFreq(entry.key);
            // loadSoundFromWave copies the sample data; we deliberately do NOT
            // call unloadWave here because wave.data points at static storage
            // and raylib's UnloadWave would free() that pointer (UB).
            const wave = makeSineWave(sample_rate, freq);
            entry.value.* = rl.loadSoundFromWave(wave);
            self.sound_loaded.set(entry.key, true);
        }
    }

    pub fn emit(self: *Audio, tag: Tag, variant: u8) void {
        // Full queue drops silently — an enemy swarm shouldn't be able to crash a frame.
        self.pending.appendBounded(.{ .tag = tag, .variant = variant }) catch {};
    }

    pub fn clearPending(self: *Audio) void {
        self.pending.clearRetainingCapacity();
    }

    pub fn playMusic(self: *Audio, track: MusicTrack) void {
        self.music_state = track;
    }

    pub fn stopMusic(self: *Audio) void {
        self.music_state = .none;
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
                    while (i < count) : (i += 1) {
                        self.playOne(tag, base);
                    }
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

test "Audio.playMusic and stopMusic toggle music_state" {
    var audio: Audio = undefined;
    audio.init();
    defer audio.deinit();

    try std.testing.expectEqual(MusicTrack.none, audio.music_state);
    audio.playMusic(.gameplay);
    try std.testing.expectEqual(MusicTrack.gameplay, audio.music_state);
    audio.stopMusic();
    try std.testing.expectEqual(MusicTrack.none, audio.music_state);
}
