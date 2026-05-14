//! Foundational math helpers for sim code.

const std = @import("std");

pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub const zero: Vec2 = .{ .x = 0, .y = 0 };
    pub const one: Vec2 = .{ .x = 1, .y = 1 };

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn scale(v: Vec2, s: f32) Vec2 {
        return .{ .x = v.x * s, .y = v.y * s };
    }

    pub fn length(v: Vec2) f32 {
        return @sqrt(v.lengthSquared());
    }

    pub fn lengthSquared(v: Vec2) f32 {
        return v.x * v.x + v.y * v.y;
    }

    pub fn normalize(v: Vec2) Vec2 {
        const len = v.length();
        if (len == 0) return Vec2.zero;
        return v.scale(1 / len);
    }

    pub fn lerp(a: Vec2, b: Vec2, t: f32) Vec2 {
        return .{
            .x = a.x + (b.x - a.x) * t,
            .y = a.y + (b.y - a.y) * t,
        };
    }
};

pub fn clamp(value: f32, min: f32, max: f32) f32 {
    return @min(@max(value, min), max);
}

test "Vec2 add" {
    try std.testing.expectEqual(Vec2{ .x = 4, .y = 6 }, (Vec2{ .x = 1, .y = 2 }).add(.{ .x = 3, .y = 4 }));
}

test "Vec2 sub" {
    try std.testing.expectEqual(Vec2{ .x = 2, .y = 3 }, (Vec2{ .x = 5, .y = 7 }).sub(.{ .x = 3, .y = 4 }));
}

test "Vec2 scale" {
    try std.testing.expectEqual(Vec2{ .x = 6, .y = -9 }, (Vec2{ .x = 2, .y = -3 }).scale(3));
}

test "Vec2 length" {
    try std.testing.expectApproxEqAbs(@as(f32, 5), (Vec2{ .x = 3, .y = 4 }).length(), 0.000_001);
}

test "Vec2 lengthSquared" {
    try std.testing.expectEqual(@as(f32, 25), (Vec2{ .x = 3, .y = 4 }).lengthSquared());
}

test "Vec2 normalize" {
    const normalized = (Vec2{ .x = 3, .y = 4 }).normalize();
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), normalized.x, 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), normalized.y, 0.000_001);
}

test "Vec2 normalize zero" {
    try std.testing.expectEqual(Vec2.zero, Vec2.zero.normalize());
}

test "Vec2 lerp endpoints and midpoint" {
    const a: Vec2 = .{ .x = 0, .y = 0 };
    const b: Vec2 = .{ .x = 10, .y = -4 };
    try std.testing.expectEqual(a, Vec2.lerp(a, b, 0));
    try std.testing.expectEqual(b, Vec2.lerp(a, b, 1));
    try std.testing.expectEqual(Vec2{ .x = 5, .y = -2 }, Vec2.lerp(a, b, 0.5));
}

test "Vec2 consts" {
    try std.testing.expectEqual(Vec2{ .x = 0, .y = 0 }, Vec2.zero);
    try std.testing.expectEqual(Vec2{ .x = 1, .y = 1 }, Vec2.one);
}

test "clamp" {
    try std.testing.expectEqual(@as(f32, 2), clamp(1, 2, 4));
    try std.testing.expectEqual(@as(f32, 3), clamp(3, 2, 4));
    try std.testing.expectEqual(@as(f32, 4), clamp(5, 2, 4));
}
