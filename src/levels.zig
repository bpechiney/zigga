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

pub const LoadError = error{
    FileNotFound,
    LoadFailed,
    ParseZon,
} || std.mem.Allocator.Error;

pub const LevelDef = struct {
    name: []const u8,
    enemy_count: u16,
    formation: []const FormationSlot,
    enemy_kinds: []const EnemyKind,
    dive_interval: f32,
    music_track: MusicTrack,
};

/// Reads `assets/levels/<NN>.zon` and parses into a `LevelDef` whose backing
/// allocations live in `allocator`. ZON failures surface as `error.ParseZon` —
/// they are authored content bugs and should crash on dev.
pub fn loadLevelDef(allocator: std.mem.Allocator, level_index: u8) LoadError!LevelDef {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(
        &path_buf,
        "assets/levels/{d:0>2}.zon",
        .{level_index + 1},
    ) catch return error.FileNotFound;
    if (!rl.fileExists(path)) return error.FileNotFound;

    const raw = rl.loadFileText(path);
    defer rl.unloadFileText(raw);

    const source = try allocator.dupeZ(u8, raw);
    return std.zon.parse.fromSliceAlloc(LevelDef, allocator, source, null, .{
        .free_on_error = false,
    }) catch return error.ParseZon;
}

pub fn spawn(world: *World, def: LevelDef) void {
    world.spawnFormation(def.formation, def.enemy_kinds);
}

test "loadLevelDef parses level 01" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const def = try loadLevelDef(arena.allocator(), 0);
    try std.testing.expect(def.formation.len > 0);
    try std.testing.expect(def.enemy_kinds.len > 0);
    try std.testing.expect(def.dive_interval > 0);
}
