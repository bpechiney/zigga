//! By convention, root.zig is the root source file when making a package.

pub const audio = @import("audio.zig");
pub const game = @import("game.zig");
pub const levels = @import("levels.zig");
pub const math = @import("math.zig");
pub const pool = @import("pool.zig");
pub const shake = @import("shake.zig");
pub const state = @import("state.zig");
pub const systems = @import("systems.zig");
pub const world = @import("world.zig");

test {
    // Force-reference every module so its `test {}` blocks are discovered. Top
    // level `pub const X = @import(...)` is lazy in test mode; without these
    // explicit refs, tests in files that aren't pulled in transitively (e.g.
    // game.zig, levels.zig, state.zig) silently never run.
    _ = @import("audio.zig");
    _ = @import("game.zig");
    _ = @import("levels.zig");
    _ = @import("math.zig");
    _ = @import("pool.zig");
    _ = @import("replay_test.zig");
    _ = @import("shake.zig");
    _ = @import("state.zig");
    _ = @import("systems.zig");
    _ = @import("world.zig");
}
