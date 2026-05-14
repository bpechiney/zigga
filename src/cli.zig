//! Command-line argument parsing. Pure: returns a Plan or an error,
//! no global state mutation, no printing — main owns stdout/stderr.

const std = @import("std");

pub const Plan = union(enum) {
    normal,
    record: []const u8,
    replay_watch: []const u8,
    replay_speed: []const u8,
    help,
};

pub const Config = struct {
    plan: Plan,
};

pub const ParseError = error{
    UnknownFlag,
    MissingArgument,
    ConflictingFlags,
    SpeedRequiresReplay,
};

pub const usage =
    \\Usage: zigga [OPTIONS]
    \\
    \\Options:
    \\  --record <path>     Record a replay trace to <path>
    \\  --replay <path>     Replay a recorded trace from <path>
    \\  --speed             With --replay: run headless as fast as possible
    \\  --help              Show this help and exit
    \\
;

/// Parse a slice of argv (typically argv[1..]) into a Config.
pub fn parse(args: []const []const u8) ParseError!Config {
    var record_path: ?[]const u8 = null;
    var replay_path: ?[]const u8 = null;
    var speed: bool = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            return .{ .plan = .help };
        } else if (std.mem.eql(u8, a, "--record")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            record_path = args[i];
        } else if (std.mem.eql(u8, a, "--replay")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            replay_path = args[i];
        } else if (std.mem.eql(u8, a, "--speed")) {
            speed = true;
        } else {
            return ParseError.UnknownFlag;
        }
    }

    if (record_path != null and replay_path != null) return ParseError.ConflictingFlags;
    if (speed and replay_path == null) return ParseError.SpeedRequiresReplay;

    if (record_path) |p| return .{ .plan = .{ .record = p } };
    if (replay_path) |p| return .{
        .plan = if (speed) .{ .replay_speed = p } else .{ .replay_watch = p },
    };
    return .{ .plan = .normal };
}

test "no args -> normal" {
    const c = try parse(&.{});
    try std.testing.expect(c.plan == .normal);
}

test "--record path -> record" {
    const c = try parse(&.{ "--record", "trace.zrpl" });
    try std.testing.expect(c.plan == .record);
    try std.testing.expectEqualStrings("trace.zrpl", c.plan.record);
}

test "--replay path -> replay_watch" {
    const c = try parse(&.{ "--replay", "trace.zrpl" });
    try std.testing.expect(c.plan == .replay_watch);
    try std.testing.expectEqualStrings("trace.zrpl", c.plan.replay_watch);
}

test "--replay path --speed -> replay_speed" {
    const c = try parse(&.{ "--replay", "trace.zrpl", "--speed" });
    try std.testing.expect(c.plan == .replay_speed);
    try std.testing.expectEqualStrings("trace.zrpl", c.plan.replay_speed);
}

test "--record and --replay together is rejected" {
    try std.testing.expectError(ParseError.ConflictingFlags, parse(&.{
        "--record",
        "a.zrpl",
        "--replay",
        "b.zrpl",
    }));
}

test "--speed without --replay is rejected" {
    try std.testing.expectError(ParseError.SpeedRequiresReplay, parse(&.{"--speed"}));
}

test "--help -> help plan" {
    const c = try parse(&.{"--help"});
    try std.testing.expect(c.plan == .help);
}

test "unknown flag -> UnknownFlag" {
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{"--banana"}));
}

test "--record without path -> MissingArgument" {
    try std.testing.expectError(ParseError.MissingArgument, parse(&.{"--record"}));
}

test "--replay without path -> MissingArgument" {
    try std.testing.expectError(ParseError.MissingArgument, parse(&.{"--replay"}));
}
