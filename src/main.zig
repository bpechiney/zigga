const std = @import("std");
const rl = @import("raylib");
const zigga = @import("zigga");

const galaga_aspect: f32 = 0.777_777_8;
const target_fps: i32 = 60;
const default_seed: u64 = 0x5EED;

// Reserve room for the macOS menu bar (~24 pt) and window title bar (~28 pt)
// so the window's full content area stays on screen.
const macos_chrome_height: i32 = 52;

const Window = struct {
    fn init(title: [:0]const u8, w: i32, h: i32) Window {
        rl.initWindow(w, h, title);
        return .{};
    }

    fn deinit(_: Window) void {
        rl.closeWindow();
    }
};

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const opened = openWindow("zigga");
    defer opened.window.deinit();

    rl.initAudioDevice();
    defer rl.closeAudioDevice();

    var game: zigga.game.Game = undefined;
    try game.init(gpa, zigga.world.WorldCaps.defaults, opened.w, opened.h, default_seed);
    defer game.deinit();

    if (rl.isAudioDeviceReady()) game.audio.enablePlayback();

    while (!rl.windowShouldClose()) {
        try game.frame();
    }
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
