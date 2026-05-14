const std = @import("std");
const rl = @import("raylib");
const zigga = @import("zigga");

const galaga_aspect: f32 = 0.777_777_8;
const target_fps: i32 = 60;
const default_seed: u64 = 0x5EED;

// Reserve room for the macOS menu bar (~24 pt) and window title bar (~28 pt)
// so the window's full content area stays on screen.
const macos_chrome_height: i32 = 52;
// Headless replay (--replay --speed) runs without a window — use the test
// default bounds so replays produced by tests (which use Bounds.default) are
// reproducible across machines.
const headless_w: i32 = 700;
const headless_h: i32 = 900;

const Window = struct {
    fn init(title: [:0]const u8, w: i32, h: i32) Window {
        rl.initWindow(w, h, title);
        return .{};
    }

    fn deinit(_: Window) void {
        rl.closeWindow();
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const program_args: []const [:0]const u8 = if (args.len > 0) args[1..] else args;
    var argv_buf = try init.arena.allocator().alloc([]const u8, program_args.len);
    for (program_args, 0..) |arg, i| argv_buf[i] = arg;

    const config = zigga.cli.parse(argv_buf) catch |err| {
        printCliError(err);
        std.process.exit(1);
    };

    switch (config.plan) {
        .help => {
            std.debug.print("{s}", .{zigga.cli.usage});
            return;
        },
        .normal => try runWindowed(gpa, .{ .literal = default_seed }, .normal),
        .record => |path| try runRecord(gpa, io, path),
        .replay_watch => |path| try runReplayWatch(gpa, io, path),
        .replay_speed => |path| try runReplaySpeed(gpa, io, path),
    }
}

fn runWindowed(
    gpa: std.mem.Allocator,
    seed_source: zigga.game.SeedSource,
    mode: zigga.game.Mode,
) !void {
    const opened = openWindow("zigga");
    defer opened.window.deinit();

    rl.initAudioDevice();
    defer rl.closeAudioDevice();

    var game: zigga.game.Game = undefined;
    try game.init(gpa, zigga.world.WorldCaps.defaults, opened.w, opened.h, seed_source, mode);
    defer game.deinit();

    if (rl.isAudioDeviceReady()) game.audio.enablePlayback();

    while (!game.should_exit) {
        try game.frame();
    }
}

fn runRecord(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    var recorder = try zigga.replay.Recorder.open(std.Io.Dir.cwd(), io, path, default_seed);
    defer recorder.close();

    const mode: zigga.game.Mode = .{ .record = .{ .recorder = &recorder } };
    runWindowed(gpa, .{ .literal = default_seed }, mode) catch |err| {
        recorder.finalize() catch {};
        return err;
    };
    // Finalize on clean exit. If the game ended naturally (game_over), the
    // recorder was already finalized — a redundant write is harmless.
    recorder.finalize() catch |err| {
        std.log.warn("record: finalize failed: {s}", .{@errorName(err)});
    };
}

fn runReplayWatch(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    var replayer = try zigga.replay.Replayer.open(std.Io.Dir.cwd(), io, path);
    defer replayer.close();
    try runWindowed(gpa, .{ .replayer = &replayer }, .{ .replay_watch = &replayer });
}

/// `--replay --speed` MUST NOT touch raylib so CI machines without GL/audio
/// can verify traces. No initWindow, no initAudioDevice, fixed bounds.
fn runReplaySpeed(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    var replayer = try zigga.replay.Replayer.open(std.Io.Dir.cwd(), io, path);
    defer replayer.close();

    var game: zigga.game.Game = undefined;
    try game.init(
        gpa,
        zigga.world.WorldCaps.defaults,
        headless_w,
        headless_h,
        .{ .replayer = &replayer },
        .{ .replay_speed = &replayer },
    );
    defer game.deinit();

    while (!game.should_exit) {
        try game.frame();
    }
}

fn printCliError(err: zigga.cli.ParseError) void {
    const msg = switch (err) {
        error.UnknownFlag => "unknown flag",
        error.MissingArgument => "missing argument for flag",
        error.ConflictingFlags => "--record and --replay are mutually exclusive",
        error.SpeedRequiresReplay => "--speed requires --replay",
    };
    std.debug.print("zigga: {s}\n{s}", .{ msg, zigga.cli.usage });
}

fn openWindow(title: [:0]const u8) struct { window: Window, w: i32, h: i32 } {
    // HIGHDPI must be set before initWindow to take effect. WINDOW_HIDDEN keeps
    // the probe window off-screen during sizing.
    rl.setConfigFlags(.{
        .window_highdpi = true,
        .window_hidden = true,
    });
    const window = Window.init(title, 1, 1);

    const monitor = rl.getCurrentMonitor();
    // getMonitorWidth/Height and setWindowSize both speak GLFW screen
    // coordinates (points on macOS); use the values directly.
    const monitor_w = rl.getMonitorWidth(monitor);
    const monitor_h = rl.getMonitorHeight(monitor);

    const win_h: i32 = monitor_h - macos_chrome_height;
    const win_w: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(win_h)) * galaga_aspect));

    rl.setWindowSize(win_w, win_h);
    rl.setWindowPosition(@divFloor(monitor_w - win_w, 2), 0);
    rl.clearWindowState(.{ .window_hidden = true });
    rl.setTargetFPS(target_fps);

    return .{ .window = window, .w = win_w, .h = win_h };
}
