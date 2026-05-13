//! Fixed-capacity generational pool storage.

const std = @import("std");

pub fn Pool(comptime T: type) type {
    return struct {
        rows: std.MultiArrayList(T),
        generations: []u32,
        alive: []bool,
        doomed: []bool,
        free: []u32,
        free_len: u32,
        live_len: u32,

        pub const Handle = packed struct(u64) {
            index: u32,
            generation: u32,
        };

        pub const Iter = struct {
            pool: *const Self,
            index: u32 = 0,

            pub fn next(self: *Iter) ?u32 {
                while (self.index < self.pool.capacity()) {
                    const index = self.index;
                    self.index += 1;
                    if (self.pool.alive[index] and !self.pool.doomed[index]) {
                        return index;
                    }
                }
                return null;
            }
        };

        const Self = @This();

        pub fn init(gpa: std.mem.Allocator, cap: u32) !Self {
            const capacity_usize: usize = @intCast(cap);
            var rows: std.MultiArrayList(T) = .empty;
            errdefer rows.deinit(gpa);
            try rows.ensureTotalCapacity(gpa, capacity_usize);
            try rows.resize(gpa, capacity_usize);

            const generations = try gpa.alloc(u32, capacity_usize);
            errdefer gpa.free(generations);
            const alive = try gpa.alloc(bool, capacity_usize);
            errdefer gpa.free(alive);
            const doomed = try gpa.alloc(bool, capacity_usize);
            errdefer gpa.free(doomed);
            const free = try gpa.alloc(u32, capacity_usize);
            errdefer gpa.free(free);

            @memset(generations, 0);
            @memset(alive, false);
            @memset(doomed, false);
            for (free, 0..) |*slot, i| {
                slot.* = cap - 1 - @as(u32, @intCast(i));
            }

            return .{
                .rows = rows,
                .generations = generations,
                .alive = alive,
                .doomed = doomed,
                .free = free,
                .free_len = cap,
                .live_len = 0,
            };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.rows.deinit(gpa);
            gpa.free(self.generations);
            gpa.free(self.alive);
            gpa.free(self.doomed);
            gpa.free(self.free);
            self.* = undefined;
        }

        pub fn spawn(self: *Self, value: T) ?Handle {
            if (self.free_len == 0) return null;

            self.free_len -= 1;
            const index = self.free[self.free_len];
            self.rows.set(index, value);
            self.alive[index] = true;
            self.doomed[index] = false;
            self.live_len += 1;
            return .{
                .index = index,
                .generation = self.generations[index],
            };
        }

        pub fn resolve(self: *const Self, h: Handle) ?u32 {
            if (h.index >= self.capacity()) return null;
            if (!self.alive[h.index]) return null;
            if (self.generations[h.index] != h.generation) return null;
            return h.index;
        }

        /// Marks a slot for end-of-tick reclaim; doomed handles still resolve until sweep.
        pub fn kill(self: *Self, h: Handle) void {
            const index = self.resolve(h) orelse return;
            self.doomed[index] = true;
        }

        /// Reclaims doomed slots, bumps generations, and returns indices to the free list.
        pub fn sweep(self: *Self) void {
            var index: u32 = 0;
            while (index < self.capacity()) : (index += 1) {
                if (self.alive[index] and self.doomed[index]) {
                    self.generations[index] +%= 1;
                    self.alive[index] = false;
                    self.doomed[index] = false;
                    self.free[self.free_len] = index;
                    self.free_len += 1;
                    self.live_len -= 1;
                }
            }
        }

        pub fn clearActive(self: *Self) void {
            var index: u32 = 0;
            while (index < self.capacity()) : (index += 1) {
                if (self.alive[index]) {
                    self.generations[index] +%= 1;
                }
                self.alive[index] = false;
                self.doomed[index] = false;
            }

            for (self.free, 0..) |*slot, i| {
                slot.* = self.capacity() - 1 - @as(u32, @intCast(i));
            }
            self.free_len = self.capacity();
            self.live_len = 0;
        }

        /// Iterates currently active slots, skipping slots already marked doomed.
        pub fn iter(self: *const Self) Iter {
            return .{ .pool = self };
        }

        pub fn len(self: *const Self) u32 {
            return self.live_len;
        }

        fn capacity(self: *const Self) u32 {
            return @intCast(self.generations.len);
        }
    };
}

const TestEntity = struct {
    id: u32,
    value: f32,
};

const TestPool = Pool(TestEntity);

fn entity(id: u32) TestEntity {
    return .{ .id = id, .value = @floatFromInt(id) };
}

test "spawn returns null when capacity is full" {
    var pool = try TestPool.init(std.testing.allocator, 64);
    defer pool.deinit(std.testing.allocator);

    for (0..64) |i| {
        try std.testing.expect(pool.spawn(entity(@intCast(i))) != null);
    }
    try std.testing.expect(pool.spawn(entity(64)) == null);
}

test "spawn resolve returns index and value" {
    var pool = try TestPool.init(std.testing.allocator, 4);
    defer pool.deinit(std.testing.allocator);

    const handle = pool.spawn(.{ .id = 7, .value = 12.5 }).?;
    const index = pool.resolve(handle).?;

    try std.testing.expectEqual(@as(u32, 0), index);
    try std.testing.expectEqual(TestEntity{ .id = 7, .value = 12.5 }, pool.rows.get(index));
}

test "kill leaves doomed handle resolvable before sweep" {
    var pool = try TestPool.init(std.testing.allocator, 4);
    defer pool.deinit(std.testing.allocator);

    const handle = pool.spawn(entity(1)).?;
    pool.kill(handle);

    try std.testing.expect(pool.resolve(handle) != null);
}

test "kill sweep invalidates handle" {
    var pool = try TestPool.init(std.testing.allocator, 4);
    defer pool.deinit(std.testing.allocator);

    const handle = pool.spawn(entity(1)).?;
    pool.kill(handle);
    pool.sweep();

    try std.testing.expect(pool.resolve(handle) == null);
}

test "sweep reuses slot with fresh generation" {
    var pool = try TestPool.init(std.testing.allocator, 4);
    defer pool.deinit(std.testing.allocator);

    const old_handle = pool.spawn(entity(1)).?;
    pool.kill(old_handle);
    pool.sweep();
    const new_handle = pool.spawn(entity(2)).?;

    try std.testing.expectEqual(old_handle.index, new_handle.index);
    try std.testing.expect(pool.resolve(old_handle) == null);
    try std.testing.expect(pool.resolve(new_handle) != null);
}

test "iter skips doomed slots before sweep" {
    var pool = try TestPool.init(std.testing.allocator, 4);
    defer pool.deinit(std.testing.allocator);

    const first = pool.spawn(entity(1)).?;
    const second = pool.spawn(entity(2)).?;
    _ = pool.spawn(entity(3)).?;
    pool.kill(second);

    var iter = pool.iter();
    try std.testing.expectEqual(first.index, iter.next().?);
    try std.testing.expectEqual(@as(u32, 2), iter.next().?);
    try std.testing.expect(iter.next() == null);
}

test "clearActive invalidates existing handles and resets free list" {
    var pool = try TestPool.init(std.testing.allocator, 4);
    defer pool.deinit(std.testing.allocator);

    const first = pool.spawn(entity(1)).?;
    const second = pool.spawn(entity(2)).?;
    pool.clearActive();

    try std.testing.expect(pool.resolve(first) == null);
    try std.testing.expect(pool.resolve(second) == null);
    try std.testing.expectEqual(@as(u32, 0), pool.len());

    const new_first = pool.spawn(entity(3)).?;
    const new_second = pool.spawn(entity(4)).?;

    try std.testing.expectEqual(@as(u32, 0), new_first.index);
    try std.testing.expectEqual(@as(u32, 1), new_second.index);
    try std.testing.expectEqual(first.generation +% 1, new_first.generation);
    try std.testing.expectEqual(second.generation +% 1, new_second.generation);
}
