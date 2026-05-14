//! Level definitions loaded from disk as ZON, spawned into the world.

const std = @import("std");
const rl = @import("raylib");

const audio_mod = @import("audio.zig");
const world_mod = @import("world.zig");

const MusicTrack = audio_mod.MusicTrack;
const EnemyKind = world_mod.EnemyKind;
const FormationSlot = world_mod.FormationSlot;
const World = world_mod.World;

pub const level_count: u8 = 3;

pub const ValidateError = error{
    EmptyEnemyKinds,
    EmptyFormation,
    KindIndexOutOfRange,
    EnemyCountMismatch,
    InvalidDiveInterval,
};

pub const LoadError = error{
    FileNotFound,
    LoadFailed,
    PathTooLong,
    ParseZon,
} || ValidateError || std.mem.Allocator.Error;

pub const LevelDef = struct {
    name: []const u8,
    enemy_count: u16,
    formation: []const FormationSlot,
    enemy_kinds: []const EnemyKind,
    dive_interval: f32,
    music_track: MusicTrack,
};

/// Reads `<asset_root>levels/<NN>.zon` and parses into a `LevelDef` whose
/// backing allocations live in `allocator`. Validates the parsed data before
/// returning so callers (and `world.spawnFormation`) can treat the result as
/// trusted — a bad authored level surfaces as a load error here, not an index
/// panic at spawn time. `asset_root` must end with a trailing slash.
pub fn loadLevelDef(
    allocator: std.mem.Allocator,
    asset_root: []const u8,
    level_index: u8,
) LoadError!LevelDef {
    // Silence raylib's "FILEIO: ... loaded successfully" INFO chatter. It goes
    // to stdout and collides with `zig build test`'s --listen=- protocol stream,
    // which deadlocks the orchestrator on any non-trivial test that loads a
    // file. Setting it here is idempotent and global.
    rl.setTraceLogLevel(.warning);

    // Use the OS PATH_MAX so deep install prefixes still fit; overflow surfaces
    // as an explicit PathTooLong instead of mis-mapping to FileNotFound.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(
        &path_buf,
        "{s}levels/{d:0>2}.zon",
        .{ asset_root, level_index + 1 },
    ) catch return error.PathTooLong;
    if (!rl.fileExists(path)) return error.FileNotFound;

    const raw = rl.loadFileText(path);
    defer rl.unloadFileText(raw);

    const source = try allocator.dupeZ(u8, raw);
    const def = std.zon.parse.fromSliceAlloc(LevelDef, allocator, source, null, .{
        .free_on_error = false,
    }) catch return error.ParseZon;

    try validateLevelDef(def);
    return def;
}

pub fn validateLevelDef(def: LevelDef) ValidateError!void {
    if (def.enemy_kinds.len == 0) return error.EmptyEnemyKinds;
    if (def.formation.len == 0) return error.EmptyFormation;
    if (def.formation.len != def.enemy_count) return error.EnemyCountMismatch;
    if (!(def.dive_interval > 0)) return error.InvalidDiveInterval;
    for (def.formation) |slot| {
        if (slot.kind_index >= def.enemy_kinds.len) return error.KindIndexOutOfRange;
    }
}

/// Spawn the formation into the world and apply per-level tuning. The caller
/// is expected to have run `validateLevelDef` (or obtained `def` from
/// `loadLevelDef`, which validates) so this routine can index `enemy_kinds`
/// without bounds checks.
pub fn spawn(world: *World, def: LevelDef) void {
    world.dive_chance_per_tick = world_mod.sim_dt / def.dive_interval;
    world.spawnFormation(def.formation, def.enemy_kinds);
}

test "loadLevelDef returns PathTooLong when the asset root overflows PATH_MAX" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var long_root_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    @memset(&long_root_buf, 'x');
    long_root_buf[long_root_buf.len - 1] = '/';
    const long_root: []const u8 = &long_root_buf;
    try std.testing.expectError(error.PathTooLong, loadLevelDef(arena.allocator(), long_root, 0));
}

test "loadLevelDef parses level 01" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const def = try loadLevelDef(arena.allocator(), "assets/", 0);
    try std.testing.expect(def.formation.len > 0);
    try std.testing.expect(def.enemy_kinds.len > 0);
    try std.testing.expect(def.dive_interval > 0);
}

test "validateLevelDef rejects empty enemy_kinds" {
    const def: LevelDef = .{
        .name = "x",
        .enemy_count = 0,
        .formation = &.{},
        .enemy_kinds = &.{},
        .dive_interval = 1,
        .music_track = .none,
    };
    try std.testing.expectError(error.EmptyEnemyKinds, validateLevelDef(def));
}

test "validateLevelDef rejects empty formation" {
    const kinds = [_]EnemyKind{.grunt};
    const def: LevelDef = .{
        .name = "x",
        .enemy_count = 0,
        .formation = &.{},
        .enemy_kinds = &kinds,
        .dive_interval = 1,
        .music_track = .none,
    };
    try std.testing.expectError(error.EmptyFormation, validateLevelDef(def));
}

test "validateLevelDef rejects out-of-range kind_index" {
    const kinds = [_]EnemyKind{.grunt};
    const slots = [_]FormationSlot{.{ .home = .{ .x = 0, .y = 0 }, .kind_index = 3 }};
    const def: LevelDef = .{
        .name = "x",
        .enemy_count = 1,
        .formation = &slots,
        .enemy_kinds = &kinds,
        .dive_interval = 1,
        .music_track = .none,
    };
    try std.testing.expectError(error.KindIndexOutOfRange, validateLevelDef(def));
}

test "validateLevelDef rejects enemy_count != formation.len" {
    const kinds = [_]EnemyKind{.grunt};
    const slots = [_]FormationSlot{.{ .home = .{ .x = 0, .y = 0 }, .kind_index = 0 }};
    const def: LevelDef = .{
        .name = "x",
        .enemy_count = 7,
        .formation = &slots,
        .enemy_kinds = &kinds,
        .dive_interval = 1,
        .music_track = .none,
    };
    try std.testing.expectError(error.EnemyCountMismatch, validateLevelDef(def));
}

test "validateLevelDef rejects non-positive dive_interval" {
    const kinds = [_]EnemyKind{.grunt};
    const slots = [_]FormationSlot{.{ .home = .{ .x = 0, .y = 0 }, .kind_index = 0 }};
    const def: LevelDef = .{
        .name = "x",
        .enemy_count = 1,
        .formation = &slots,
        .enemy_kinds = &kinds,
        .dive_interval = 0,
        .music_track = .none,
    };
    try std.testing.expectError(error.InvalidDiveInterval, validateLevelDef(def));
}

test "spawn sets dive_chance_per_tick from def.dive_interval" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    var world = try World.init(std.testing.allocator, world_mod.WorldCaps.defaults, world_mod.Bounds.default, &prng);
    defer world.deinit(std.testing.allocator);

    const kinds = [_]EnemyKind{.grunt};
    const slots = [_]FormationSlot{.{ .home = .{ .x = 0, .y = 0 }, .kind_index = 0 }};
    const def: LevelDef = .{
        .name = "x",
        .enemy_count = 1,
        .formation = &slots,
        .enemy_kinds = &kinds,
        .dive_interval = 4.0,
        .music_track = .none,
    };
    spawn(&world, def);
    try std.testing.expectApproxEqAbs(@as(f32, world_mod.sim_dt / 4.0), world.dive_chance_per_tick, 1e-6);
}
