//! Persistent replay trace: file format, recorder, replayer.
//!
//! File layout (`.zrpl` — "Zigga RePLay"):
//!   offset  size  field
//!   0       4     magic "ZRPL"
//!   4       4     version u32 LE
//!   8       8     seed   u64 LE  — sim_prng seed
//!   16      4     tick_count u32 LE
//!   20      ...   InputRecord × tick_count, 12 bytes each
//!
//! Determinism contract: one InputRecord per sim tick (not per frame). A
//! 33ms frame draining 2 ticks writes 2 records with the same Input payload;
//! replay feeds them into simTick one at a time. `extern struct` (not
//! `packed`) is required: `packed struct` layout shifted across recent Zig
//! versions and the file format must be bit-stable across compiler versions.

const std = @import("std");
const world_mod = @import("world.zig");

const Input = world_mod.Input;
const Vec2 = @import("math.zig").Vec2;

pub const magic_bytes = [4]u8{ 'Z', 'R', 'P', 'L' };
pub const current_version: u32 = 1;

/// Wire layout: 20 bytes on disk, packed without trailing padding. The struct
/// itself has a Zig-side `@sizeOf` of 24 (u64 alignment forces tail padding),
/// so we serialize field-by-field through `writeHeader` / `readHeader` rather
/// than `std.mem.asBytes` to keep the on-disk layout stable.
pub const Header = struct {
    magic: [4]u8,
    version: u32,
    seed: u64,
    tick_count: u32,
};

/// 12 bytes on disk and 12 bytes in memory. `extern struct` not `packed struct`
/// because `packed struct` layout shifted across recent Zig versions; the file
/// format contract must survive compiler upgrades.
pub const InputRecord = extern struct {
    thrust_x: f32,
    thrust_y: f32,
    flags: u32,

    pub const flag_fire: u32 = 1 << 0;
    /// Reserved for future pause-bit support. Currently always zero on write
    /// and ignored on read.
    pub const flag_pause: u32 = 1 << 1;
};

pub const header_size: u64 = 20;
const tick_count_offset: u64 = 16;

comptime {
    std.debug.assert(@sizeOf(InputRecord) == 12);
}

fn encodeHeader(h: Header) [header_size]u8 {
    var buf: [header_size]u8 = undefined;
    @memcpy(buf[0..4], &h.magic);
    std.mem.writeInt(u32, buf[4..8], h.version, .little);
    std.mem.writeInt(u64, buf[8..16], h.seed, .little);
    std.mem.writeInt(u32, buf[16..20], h.tick_count, .little);
    return buf;
}

fn decodeHeader(buf: *const [header_size]u8) Header {
    return .{
        .magic = buf[0..4].*,
        .version = std.mem.readInt(u32, buf[4..8], .little),
        .seed = std.mem.readInt(u64, buf[8..16], .little),
        .tick_count = std.mem.readInt(u32, buf[16..20], .little),
    };
}

pub const ReadError = error{
    BadMagic,
    UnsupportedVersion,
    Truncated,
};

pub fn fromInput(i: Input) InputRecord {
    var flags: u32 = 0;
    if (i.fire) flags |= InputRecord.flag_fire;
    return .{
        .thrust_x = i.thrust.x,
        .thrust_y = i.thrust.y,
        .flags = flags,
    };
}

pub fn toInput(r: InputRecord) Input {
    return .{
        .thrust = .{ .x = r.thrust_x, .y = r.thrust_y },
        .fire = (r.flags & InputRecord.flag_fire) != 0,
    };
}

pub const Recorder = struct {
    io: std.Io,
    file: std.Io.File,
    write_offset: u64,
    tick_count: u32,

    pub fn open(dir: std.Io.Dir, io: std.Io, path: []const u8, seed: u64) !Recorder {
        const file = try dir.createFile(io, path, .{});
        errdefer file.close(io);

        const buf = encodeHeader(.{
            .magic = magic_bytes,
            .version = current_version,
            .seed = seed,
            .tick_count = 0,
        });
        try file.writePositionalAll(io, &buf, 0);

        return .{
            .io = io,
            .file = file,
            .write_offset = header_size,
            .tick_count = 0,
        };
    }

    pub fn writeTick(self: *Recorder, input: Input) !void {
        const record = fromInput(input);
        try self.file.writePositionalAll(self.io, std.mem.asBytes(&record), self.write_offset);
        self.write_offset += @sizeOf(InputRecord);
        self.tick_count += 1;
    }

    pub fn finalize(self: *Recorder) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, self.tick_count, .little);
        try self.file.writePositionalAll(self.io, &buf, tick_count_offset);
    }

    pub fn close(self: *Recorder) void {
        self.file.close(self.io);
        self.* = undefined;
    }
};

pub const Replayer = struct {
    io: std.Io,
    file: std.Io.File,
    seed: u64,
    tick_count: u32,
    ticks_read: u32,
    read_offset: u64,

    pub fn open(dir: std.Io.Dir, io: std.Io, path: []const u8) !Replayer {
        const file = try dir.openFile(io, path, .{ .mode = .read_only });
        errdefer file.close(io);

        var buf: [header_size]u8 = undefined;
        const n = try file.readPositionalAll(io, &buf, 0);
        if (n < header_size) return ReadError.Truncated;
        const header = decodeHeader(&buf);
        if (!std.mem.eql(u8, &header.magic, &magic_bytes)) return ReadError.BadMagic;
        if (header.version != current_version) return ReadError.UnsupportedVersion;

        return .{
            .io = io,
            .file = file,
            .seed = header.seed,
            .tick_count = header.tick_count,
            .ticks_read = 0,
            .read_offset = header_size,
        };
    }

    /// Returns the next Input, or null when the trace is exhausted.
    /// Trailing truncation (header claims N ticks, file has fewer full records)
    /// returns null gracefully. Structural truncation (a partial record at EOF)
    /// returns ReadError.Truncated.
    pub fn nextTick(self: *Replayer) !?Input {
        if (self.ticks_read >= self.tick_count) return null;
        var record: InputRecord = undefined;
        const n = try self.file.readPositionalAll(self.io, std.mem.asBytes(&record), self.read_offset);
        if (n == 0) return null;
        if (n < @sizeOf(InputRecord)) return ReadError.Truncated;
        self.read_offset += @sizeOf(InputRecord);
        self.ticks_read += 1;
        return toInput(record);
    }

    pub fn close(self: *Replayer) void {
        self.file.close(self.io);
        self.* = undefined;
    }
};

test "round-trip: 100 random inputs encode and decode identically" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const seed: u64 = 0xC0FFEE_BEEF;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var inputs: [100]Input = undefined;
    for (&inputs) |*in| {
        in.* = .{
            .thrust = .{
                .x = (random.float(f32) - 0.5) * 2,
                .y = (random.float(f32) - 0.5) * 2,
            },
            .fire = random.boolean(),
        };
    }

    {
        var rec = try Recorder.open(tmp.dir, io, "trace.zrpl", seed);
        defer rec.close();
        for (inputs) |in| try rec.writeTick(in);
        try rec.finalize();
    }

    var rep = try Replayer.open(tmp.dir, io, "trace.zrpl");
    defer rep.close();
    try std.testing.expectEqual(seed, rep.seed);
    try std.testing.expectEqual(@as(u32, inputs.len), rep.tick_count);

    for (inputs) |expected| {
        const got = (try rep.nextTick()) orelse return error.UnexpectedEnd;
        try std.testing.expectEqual(expected.thrust.x, got.thrust.x);
        try std.testing.expectEqual(expected.thrust.y, got.thrust.y);
        try std.testing.expectEqual(expected.fire, got.fire);
    }
    try std.testing.expect((try rep.nextTick()) == null);
}

test "open rejects bad magic" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const buf = encodeHeader(.{
        .magic = [4]u8{ 'X', 'Y', 'Z', '!' },
        .version = current_version,
        .seed = 0,
        .tick_count = 0,
    });
    {
        const f = try tmp.dir.createFile(io, "bad.zrpl", .{});
        defer f.close(io);
        try f.writePositionalAll(io, &buf, 0);
    }

    try std.testing.expectError(ReadError.BadMagic, Replayer.open(tmp.dir, io, "bad.zrpl"));
}

test "open rejects unsupported version" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const buf = encodeHeader(.{
        .magic = magic_bytes,
        .version = 999,
        .seed = 0,
        .tick_count = 0,
    });
    {
        const f = try tmp.dir.createFile(io, "bad.zrpl", .{});
        defer f.close(io);
        try f.writePositionalAll(io, &buf, 0);
    }

    try std.testing.expectError(ReadError.UnsupportedVersion, Replayer.open(tmp.dir, io, "bad.zrpl"));
}

test "trailing truncation returns null, structural truncation errors" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Trailing truncation: header claims 100, only 50 records present.
    {
        var rec = try Recorder.open(tmp.dir, io, "trailing.zrpl", 7);
        defer rec.close();
        var i: u32 = 0;
        while (i < 50) : (i += 1) try rec.writeTick(.{ .thrust = .{ .x = 0, .y = 0 }, .fire = false });
        // Patch the header to claim 100 ticks without writing the remaining 50.
        var patch: [4]u8 = undefined;
        std.mem.writeInt(u32, &patch, 100, .little);
        try rec.file.writePositionalAll(io, &patch, tick_count_offset);
    }
    {
        var rep = try Replayer.open(tmp.dir, io, "trailing.zrpl");
        defer rep.close();
        var seen: u32 = 0;
        while (try rep.nextTick()) |_| seen += 1;
        try std.testing.expectEqual(@as(u32, 50), seen);
    }

    // Structural truncation: last record cut mid-bytes.
    {
        var rec = try Recorder.open(tmp.dir, io, "structural.zrpl", 7);
        defer rec.close();
        var i: u32 = 0;
        while (i < 10) : (i += 1) try rec.writeTick(.{ .thrust = .{ .x = 0, .y = 0 }, .fire = false });
        try rec.finalize();
        var patch: [4]u8 = undefined;
        std.mem.writeInt(u32, &patch, 11, .little);
        try rec.file.writePositionalAll(io, &patch, tick_count_offset);
        const garbage = [_]u8{ 1, 2, 3, 4, 5 };
        const end_offset: u64 = header_size + 10 * @sizeOf(InputRecord);
        try rec.file.writePositionalAll(io, &garbage, end_offset);
    }
    {
        var rep = try Replayer.open(tmp.dir, io, "structural.zrpl");
        defer rep.close();
        var i: u32 = 0;
        while (i < 10) : (i += 1) {
            _ = (try rep.nextTick()) orelse return error.UnexpectedEarlyEnd;
        }
        try std.testing.expectError(ReadError.Truncated, rep.nextTick());
    }
}

test "fromInput/toInput roundtrip preserves fire bit and thrust" {
    const i: Input = .{ .thrust = .{ .x = -0.5, .y = 0.75 }, .fire = true };
    const r = fromInput(i);
    try std.testing.expectEqual(@as(u32, InputRecord.flag_fire), r.flags);
    const back = toInput(r);
    try std.testing.expectEqual(i.thrust.x, back.thrust.x);
    try std.testing.expectEqual(i.thrust.y, back.thrust.y);
    try std.testing.expectEqual(i.fire, back.fire);

    const j: Input = Input.zero;
    try std.testing.expectEqual(@as(u32, 0), fromInput(j).flags);
    try std.testing.expectEqual(false, toInput(fromInput(j)).fire);
    _ = Vec2.zero;
}
