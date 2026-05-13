//! Top-level state machine: attract / playing / paused / game_over.

pub const starting_lives: u8 = 3;
pub const death_pause_s: f32 = 1.5;
pub const game_over_s: f32 = 5.0;

pub const Playing = struct {
    score: u32,
    lives: u8,
    level_index: u8,
    level_timer: f32,
    death_pause: f32 = 0,
};

pub const GameOver = struct {
    final_score: u32,
    timer_s: f32,
};

/// `paused` carries the underlying `Playing` by value so resume is a trivial
/// assignment (`state = .{ .playing = captured }`) — no separate "saved" slot.
pub const State = union(enum) {
    attract,
    playing: Playing,
    paused: Playing,
    game_over: GameOver,
};

pub fn fresh() Playing {
    return .{
        .score = 0,
        .lives = starting_lives,
        .level_index = 0,
        .level_timer = 0,
    };
}

/// Score reward per kind. Tunable — keep in sync with HUD expectations.
pub fn killScore(kind: anytype) u32 {
    return switch (kind) {
        .grunt => 50,
        .zako => 80,
        .goei => 160,
    };
}
