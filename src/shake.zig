//! Frame-paced camera shake. Decays linearly; offset uses squared trauma.

const std = @import("std");
const rl = @import("raylib");

const max_offset_px_default: f32 = 8;
const decay_default: f32 = 1.5;

pub const Shake = struct {
    trauma: f32 = 0,
    decay: f32 = decay_default,
    max_offset_px: f32 = max_offset_px_default,
    rng: std.Random,

    pub fn init(prng: *std.Random.DefaultPrng) Shake {
        return .{ .rng = prng.random() };
    }

    pub fn kick(self: *Shake, amount: f32) void {
        self.trauma = @min(1.0, self.trauma + amount);
    }

    pub fn update(self: *Shake, frame_dt: f32) void {
        self.trauma = @max(0.0, self.trauma - self.decay * frame_dt);
    }

    pub fn offset(self: *Shake) rl.Vector2 {
        const amp = self.trauma * self.trauma * self.max_offset_px;
        const angle = self.rng.float(f32) * std.math.tau;
        return .{ .x = amp * @cos(angle), .y = amp * @sin(angle) };
    }
};

test "kick saturates at 1.0" {
    var prng = std.Random.DefaultPrng.init(0);
    var shake = Shake.init(&prng);
    shake.kick(0.5);
    shake.kick(0.8);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), shake.trauma, 0.000_001);
}

test "trauma decays to zero over 1/decay seconds" {
    var prng = std.Random.DefaultPrng.init(0);
    var shake = Shake.init(&prng);
    shake.kick(1.0);

    const total_time = 1.0 / shake.decay;
    const step: f32 = 1.0 / 60.0;
    var elapsed: f32 = 0;
    while (elapsed < total_time) : (elapsed += step) {
        shake.update(step);
    }
    // Overshoot a hair to make the inequality clean.
    shake.update(step);
    try std.testing.expectApproxEqAbs(@as(f32, 0), shake.trauma, 0.000_001);
}

test "offset samples within max_offset_px disk" {
    var prng = std.Random.DefaultPrng.init(42);
    var shake = Shake.init(&prng);
    shake.kick(1.0);

    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        const o = shake.offset();
        const r = @sqrt(o.x * o.x + o.y * o.y);
        try std.testing.expect(r <= shake.max_offset_px + 0.000_01);
    }
}

test "offset is zero when trauma is zero" {
    var prng = std.Random.DefaultPrng.init(7);
    var shake = Shake.init(&prng);
    const o = shake.offset();
    try std.testing.expectEqual(@as(f32, 0), o.x);
    try std.testing.expectEqual(@as(f32, 0), o.y);
}
