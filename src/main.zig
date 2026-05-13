const rl = @import("raylib");

const galaga_aspect: f32 = 0.777_777_8;
const target_fps: i32 = 60;

pub fn main() void {
    rl.initWindow(1, 1, "zigga");
    defer rl.closeWindow();

    const monitor = rl.getCurrentMonitor();
    const monitor_w = rl.getMonitorWidth(monitor);
    const monitor_h = rl.getMonitorHeight(monitor);

    const height = monitor_h;
    const width: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(monitor_h)) * galaga_aspect));

    rl.setWindowSize(width, height);
    rl.setWindowPosition(@divFloor(monitor_w - width, 2), 0);
    rl.setTargetFPS(target_fps);

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(rl.Color.black);
    }
}
