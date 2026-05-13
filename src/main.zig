const rl = @import("raylib");

const galaga_aspect: f32 = 0.777_777_8;
const target_fps: i32 = 60;
const player_size: f32 = 20.0;
const player_speed: f32 = 300.0;

// Reserve room for the macOS menu bar (~24 pt) and window title bar (~28 pt)
// so the window's full content area stays on screen.
const macos_chrome_height: i32 = 52;

pub fn main() void {
    const window = openWindow("zigga");
    defer rl.closeWindow();

    var pos: rl.Vector2 = .{
        .x = @as(f32, @floatFromInt(window.w)) * 0.5,
        .y = @as(f32, @floatFromInt(window.h)) * 0.875,
    };

    while (!rl.windowShouldClose()) {
        var dx: f32 = 0;
        var dy: f32 = 0;
        if (rl.isKeyDown(.w)) dy -= 1;
        if (rl.isKeyDown(.s)) dy += 1;
        if (rl.isKeyDown(.a)) dx -= 1;
        if (rl.isKeyDown(.d)) dx += 1;
        if (dx != 0 or dy != 0) {
            const len = @sqrt(dx * dx + dy * dy);
            const step = player_speed * rl.getFrameTime();
            pos.x += dx / len * step;
            pos.y += dy / len * step;
        }

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(rl.Color.black);
        rl.drawTriangle(
            .{ .x = pos.x, .y = pos.y - player_size },
            .{ .x = pos.x - player_size, .y = pos.y + player_size },
            .{ .x = pos.x + player_size, .y = pos.y + player_size },
            rl.Color.white,
        );
    }
}

fn openWindow(title: [:0]const u8) struct { w: i32, h: i32 } {
    // HIGHDPI must be set before initWindow to take effect. WINDOW_HIDDEN keeps
    // the probe window off-screen during sizing.
    rl.setConfigFlags(.{
        .window_highdpi = true,
        .window_hidden = true,
    });
    rl.initWindow(1, 1, title);

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

    return .{ .w = win_w, .h = win_h };
}
