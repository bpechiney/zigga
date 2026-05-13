//! By convention, root.zig is the root source file when making a package.

pub const game = @import("game.zig");
pub const math = @import("math.zig");
pub const pool = @import("pool.zig");
pub const world = @import("world.zig");

test {
    _ = @import("replay_test.zig");
}
