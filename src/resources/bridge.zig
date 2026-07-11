//! Bridge-window aggregation and encoding. Spec: docs/specs/resources/bridge.md.

const std = @import("std");

const config = @import("../config.zig");
const model = @import("model.zig");

pub const Requirement = model.Requirement;
pub const Assignment = model.Assignment;
pub const Kind = model.Kind;
pub const Source = model.Source;

pub const Error = error{BridgeWindowUnencodable};
pub const AggregateError = error{StorageExhausted};
pub const AllErrors = Error || AggregateError;

const bridge_io_alignment = model.bridge_io_alignment;
const bridge_memory_alignment = model.bridge_memory_alignment;

pub const EncodedWindow = union(enum) {
    io: IoEncoding,
    memory: MemoryEncoding,
    prefetchable_memory_32: Prefetchable32Encoding,
    prefetchable_memory_64: Prefetchable64Encoding,

    pub const IoEncoding = struct {
        /// Value for config-space offset `0x1C`.
        /// Low nibble `[3:0]` = type (`0x0` = 16-bit, `0x1` = 32-bit);
        /// high nibble `[7:4]` = base bits `[15:12]`.
        base_lo: u8,
        /// Value for config-space offset `0x1D`; same encoding as `base_lo` for the limit.
        limit_lo: u8,
        /// Value for config-space offset `0x30`; zero when `is_32bit == false`.
        base_upper: u16,
        /// Value for config-space offset `0x32`; zero when `is_32bit == false`.
        limit_upper: u16,
        /// True when the low-nibble encoding is `0x1` and upper-16 registers carry high address bits.
        is_32bit: bool,
    };

    pub const MemoryEncoding = struct {
        /// Value for config-space offset `0x20`; bits `[15:4]` = base bits `[31:20]`.
        base: u16,
        /// Value for config-space offset `0x22`; bits `[15:4]` = limit bits `[31:20]`.
        limit: u16,
    };

    pub const Prefetchable32Encoding = struct {
        /// Value for config-space offset `0x24`; low nibble is `0x0`.
        base_lo: u16,
        /// Value for config-space offset `0x26`; low nibble is `0x0`.
        limit_lo: u16,
    };

    pub const Prefetchable64Encoding = struct {
        /// Value for config-space offset `0x24`; low nibble is `0x1`.
        base_lo: u16,
        /// Value for config-space offset `0x26`; low nibble is `0x1`.
        limit_lo: u16,
        /// Value for config-space offset `0x28`; base bits `[63:32]`.
        base_upper: u32,
        /// Value for config-space offset `0x2C`; limit bits `[63:32]`.
        limit_upper: u32,
    };
};

/// Aggregates child requirements into bridge-window requirements borrowed through `out`.
///
/// Allocation: never allocates. I/O: none. Ordering: IO, memory, then prefetchable memory.
/// Errors: `StorageExhausted` is checked before `out` is modified.
pub fn aggregateWindows(
    bridge_function: config.Function,
    children: []const Requirement,
    out: []Requirement,
) AggregateError![]const Requirement {
    const bucket_set = classifyBuckets(children);
    if (out.len < bucket_set.count()) return error.StorageExhausted;

    var written: usize = 0;
    if (bucket_set.io) {
        out[written] = aggregateBucket(bridge_function, children, .io);
        written += 1;
    }
    if (bucket_set.memory) {
        out[written] = aggregateBucket(bridge_function, children, .memory);
        written += 1;
    }
    if (bucket_set.prefetchable_memory) {
        out[written] = aggregateBucket(bridge_function, children, .prefetchable_memory);
        written += 1;
    }

    std.debug.assert(written == bucket_set.count());
    return out[0..written];
}

/// Encodes one bridge-window assignment into type-1 register values.
///
/// Allocation: never allocates. I/O: none. Errors: unrepresentable wire ranges return `BridgeWindowUnencodable`.
pub fn encodeWindow(assignment: Assignment) Error!EncodedWindow {
    const requirement = assignment.requirement;
    std.debug.assert(requirement.source == .bridge_window);
    std.debug.assert(requirement.alignment > 0);
    std.debug.assert(assignment.base % requirement.alignment == 0);

    if (requirement.size == 0) {
        return disabledWindow(requirement.source.bridge_window.window);
    }

    const end = std.math.add(u64, assignment.base, requirement.size - 1) catch {
        return error.BridgeWindowUnencodable;
    };

    return switch (requirement.source.bridge_window.window) {
        .io => encodeIo(assignment.base, end),
        .memory => encodeMemory(assignment.base, end),
        .prefetchable_memory => encodePrefetchable(assignment.base, end),
    };
}

const Bucket = enum {
    io,
    memory,
    prefetchable_memory,
};

const BucketSet = struct {
    io: bool = false,
    memory: bool = false,
    prefetchable_memory: bool = false,

    fn count(self: BucketSet) usize {
        return @as(usize, @intFromBool(self.io)) +
            @as(usize, @intFromBool(self.memory)) +
            @as(usize, @intFromBool(self.prefetchable_memory));
    }
};

fn classifyBuckets(children: []const Requirement) BucketSet {
    var buckets: BucketSet = .{};
    for (children) |child| {
        if (child.size == 0) continue;

        switch (child.kind) {
            .io => buckets.io = true,
            .mmio32, .mmio64 => buckets.memory = true,
            .mmio32_pref, .mmio64_pref => buckets.prefetchable_memory = true,
        }
    }

    return buckets;
}

fn aggregateBucket(bridge_function: config.Function, children: []const Requirement, bucket: Bucket) Requirement {
    var alignment = switch (bucket) {
        .io => bridge_io_alignment,
        .memory, .prefetchable_memory => bridge_memory_alignment,
    };
    var count: usize = 0;
    var has_prefetchable_32 = false;

    for (children) |child| {
        if (!belongsToBucket(child, bucket)) continue;

        std.debug.assert(child.alignment > 0);
        std.debug.assert(std.math.isPowerOfTwo(child.alignment));
        alignment = @max(alignment, child.alignment);
        count += 1;
        has_prefetchable_32 = has_prefetchable_32 or child.kind == .mmio32_pref;
    }

    std.debug.assert(count > 0);
    std.debug.assert(std.math.isPowerOfTwo(alignment));

    var cursor: u64 = 0;
    var rank: usize = 0;
    while (rank < count) : (rank += 1) {
        const child = rankedChild(children, bucket, rank);
        cursor = alignUp(cursor, child.alignment);
        std.debug.assert(child.size <= std.math.maxInt(u64) - cursor);
        cursor = std.math.add(u64, cursor, child.size) catch unreachable;
    }

    const size = alignUp(cursor, alignment);
    std.debug.assert(size >= alignment);
    std.debug.assert(size % alignment == 0);

    return .{
        .kind = aggregateKind(bucket, has_prefetchable_32),
        .size = size,
        .alignment = alignment,
        .source = .{ .bridge_window = .{
            .function = bridge_function,
            .window = switch (bucket) {
                .io => .io,
                .memory => .memory,
                .prefetchable_memory => .prefetchable_memory,
            },
        } },
    };
}

fn rankedChild(children: []const Requirement, bucket: Bucket, rank: usize) Requirement {
    for (children, 0..) |candidate, candidate_index| {
        if (!belongsToBucket(candidate, bucket)) continue;

        var earlier: usize = 0;
        for (children, 0..) |other, other_index| {
            if (!belongsToBucket(other, bucket)) continue;
            if (bucketOrderLess(other, other_index, candidate, candidate_index)) earlier += 1;
        }

        if (earlier == rank) return candidate;
    }

    unreachable;
}

fn belongsToBucket(requirement: Requirement, bucket: Bucket) bool {
    if (requirement.size == 0) return false;

    return switch (bucket) {
        .io => requirement.kind == .io,
        .memory => requirement.kind == .mmio32 or requirement.kind == .mmio64,
        .prefetchable_memory => requirement.kind == .mmio32_pref or requirement.kind == .mmio64_pref,
    };
}

fn bucketOrderLess(left: Requirement, left_index: usize, right: Requirement, right_index: usize) bool {
    if (left.alignment != right.alignment) return left.alignment > right.alignment;
    if (left.size != right.size) return left.size > right.size;
    return left_index < right_index;
}

fn aggregateKind(bucket: Bucket, has_prefetchable_32: bool) Kind {
    return switch (bucket) {
        .io => .io,
        .memory => .mmio32,
        .prefetchable_memory => if (has_prefetchable_32) .mmio32_pref else .mmio64_pref,
    };
}

fn alignUp(value: u64, alignment: u64) u64 {
    std.debug.assert(alignment > 0);
    std.debug.assert(std.math.isPowerOfTwo(alignment));
    return std.mem.alignForward(u64, value, alignment);
}

fn disabledWindow(window: Source.BridgeWindow) EncodedWindow {
    return switch (window) {
        .io => .{ .io = .{
            .base_lo = 0xF0,
            .limit_lo = 0x00,
            .base_upper = 0,
            .limit_upper = 0,
            .is_32bit = false,
        } },
        .memory => .{ .memory = .{
            .base = 0xFFF0,
            .limit = 0x0000,
        } },
        .prefetchable_memory => .{ .prefetchable_memory_32 = .{
            .base_lo = 0xFFF0,
            .limit_lo = 0x0000,
        } },
    };
}

fn encodeIo(base: u64, end: u64) Error!EncodedWindow {
    if (base > std.math.maxInt(u32)) return error.BridgeWindowUnencodable;
    if (end > std.math.maxInt(u32)) return error.BridgeWindowUnencodable;
    if (base % bridge_io_alignment != 0) return error.BridgeWindowUnencodable;
    if (std.math.add(u64, end, 1) catch null) |exclusive_end| {
        if (exclusive_end % bridge_io_alignment != 0) return error.BridgeWindowUnencodable;
    } else return error.BridgeWindowUnencodable;

    const is_32bit = end > std.math.maxInt(u16);
    const type_bits: u8 = if (is_32bit) 0x1 else 0x0;
    const base_lo = (@as(u8, @truncate(base >> 8)) & 0xF0) | type_bits;
    const limit_lo = (@as(u8, @truncate(end >> 8)) & 0xF0) | type_bits;

    return .{ .io = .{
        .base_lo = base_lo,
        .limit_lo = limit_lo,
        .base_upper = if (is_32bit) @as(u16, @truncate(base >> 16)) else 0,
        .limit_upper = if (is_32bit) @as(u16, @truncate(end >> 16)) else 0,
        .is_32bit = is_32bit,
    } };
}

fn encodeMemory(base: u64, end: u64) Error!EncodedWindow {
    if (base > std.math.maxInt(u32)) return error.BridgeWindowUnencodable;
    if (end > std.math.maxInt(u32)) return error.BridgeWindowUnencodable;
    if (base % bridge_memory_alignment != 0) return error.BridgeWindowUnencodable;
    if (std.math.add(u64, end, 1) catch null) |exclusive_end| {
        if (exclusive_end % bridge_memory_alignment != 0) return error.BridgeWindowUnencodable;
    } else return error.BridgeWindowUnencodable;

    return .{ .memory = .{
        .base = @as(u16, @truncate(base >> 16)) & 0xFFF0,
        .limit = @as(u16, @truncate(end >> 16)) & 0xFFF0,
    } };
}

fn encodePrefetchable(base: u64, end: u64) Error!EncodedWindow {
    if (base % bridge_memory_alignment != 0) return error.BridgeWindowUnencodable;
    if (std.math.add(u64, end, 1) catch null) |exclusive_end| {
        if (exclusive_end % bridge_memory_alignment != 0) return error.BridgeWindowUnencodable;
    } else return error.BridgeWindowUnencodable;

    if (end <= std.math.maxInt(u32)) {
        return .{ .prefetchable_memory_32 = .{
            .base_lo = (@as(u16, @truncate(base >> 16)) & 0xFFF0) | 0x0,
            .limit_lo = (@as(u16, @truncate(end >> 16)) & 0xFFF0) | 0x0,
        } };
    }

    return .{ .prefetchable_memory_64 = .{
        .base_lo = (@as(u16, @truncate(base >> 16)) & 0xFFF0) | 0x1,
        .limit_lo = (@as(u16, @truncate(end >> 16)) & 0xFFF0) | 0x1,
        .base_upper = @as(u32, @truncate(base >> 32)),
        .limit_upper = @as(u32, @truncate(end >> 32)),
    } };
}

comptime {
    std.debug.assert(@sizeOf(EncodedWindow.IoEncoding) == 8);
    std.debug.assert(@sizeOf(EncodedWindow.MemoryEncoding) == 4);
    std.debug.assert(@sizeOf(EncodedWindow.Prefetchable32Encoding) == 4);
    std.debug.assert(@sizeOf(EncodedWindow.Prefetchable64Encoding) == 12);
}
