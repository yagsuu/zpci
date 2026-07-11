//! Read-only bridge inspection helpers. Spec: docs/specs/topology/bridge.md.

const std = @import("std");

const config = @import("../config.zig");
const tree = @import("tree.zig");

const ConfigSpace = config.ConfigSpace;

const offset = struct {
    const primary_bus: usize = 0x18;
    const secondary_bus: usize = 0x19;
    const subordinate_bus: usize = 0x1A;
    const io_base: usize = 0x1C;
    const io_limit: usize = 0x1D;
    const memory_base: usize = 0x20;
    const memory_limit: usize = 0x22;
    const prefetchable_memory_base: usize = 0x24;
    const prefetchable_memory_limit: usize = 0x26;
    const prefetchable_base_upper: usize = 0x28;
    const prefetchable_limit_upper: usize = 0x2C;
    const io_base_upper: usize = 0x30;
    const io_limit_upper: usize = 0x32;
};

pub const BusRange = struct {
    primary: u8,
    secondary: u8,
    subordinate: u8,

    /// Downstream bus number is unprogrammed.
    pub fn isUnprogrammed(self: BusRange) bool {
        return self.secondary == 0;
    }

    /// `bus` is inside the programmed downstream bus interval.
    pub fn forwards(self: BusRange, bus: u8) bool {
        return self.secondary != 0 and self.secondary <= bus and bus <= self.subordinate;
    }
};

pub const Window = struct {
    /// Decoded inclusive byte base.
    base: u64,
    /// Decoded inclusive byte limit.
    limit: u64,
    /// Bridge forwards a non-empty range for this window kind.
    enabled: bool,

    /// The closed byte range `[address, address + size - 1]` is wholly forwarded.
    pub fn contains(self: Window, address: u64, size: u64) bool {
        if (!self.enabled) return false;
        if (size == 0) return false;

        const end = std.math.add(u64, address, size - 1) catch return false;
        return self.base <= address and end <= self.limit;
    }
};

pub const PrefetchableWindow = struct {
    base: u64,
    limit: u64,
    /// Both low registers advertise 64-bit prefetchable addressing.
    is_64bit: bool,
    enabled: bool,

    /// The closed byte range `[address, address + size - 1]` is wholly forwarded.
    pub fn contains(self: PrefetchableWindow, address: u64, size: u64) bool {
        if (!self.enabled) return false;
        if (size == 0) return false;

        const end = std.math.add(u64, address, size - 1) catch return false;
        return self.base <= address and end <= self.limit;
    }
};

pub const WindowState = struct {
    io: Window,
    memory: Window,
    prefetchable_memory: PrefetchableWindow,
};

pub const Error = ConfigSpace.Error || error{StorageExhausted};

/// Reads type-1 bus-number bytes.
/// I/O: three 8-bit config reads. Errors: `ConfigSpace.Error`.
pub fn busRangeOf(node: *const tree.Node) ConfigSpace.Error!BusRange {
    std.debug.assert(node.header_kind == .type1);

    return .{
        .primary = try node.function.read8(offset.primary_bus),
        .secondary = try node.function.read8(offset.secondary_bus),
        .subordinate = try node.function.read8(offset.subordinate_bus),
    };
}

/// Reads decoded type-1 I/O, memory, and prefetchable windows.
/// I/O: config reads; prefetchable upper dwords only for 64-bit windows.
/// Errors: `ConfigSpace.Error`.
pub fn windowStateOf(node: *const tree.Node) ConfigSpace.Error!WindowState {
    std.debug.assert(node.header_kind == .type1);

    const io_base_lo = try node.function.read8(offset.io_base);
    const io_limit_lo = try node.function.read8(offset.io_limit);
    const io_base_upper = try node.function.read16(offset.io_base_upper);
    const io_limit_upper = try node.function.read16(offset.io_limit_upper);
    const io = decodeIoWindow(io_base_lo, io_limit_lo, io_base_upper, io_limit_upper);

    const memory_base = try node.function.read16(offset.memory_base);
    const memory_limit = try node.function.read16(offset.memory_limit);
    const memory = decodeMemoryWindow(memory_base, memory_limit);

    const pref_base_lo = try node.function.read16(offset.prefetchable_memory_base);
    const pref_limit_lo = try node.function.read16(offset.prefetchable_memory_limit);
    const pref_is_64bit = (pref_base_lo & 0xF) == 0x1 and (pref_limit_lo & 0xF) == 0x1;
    const pref_base_upper = if (pref_is_64bit) try node.function.read32(offset.prefetchable_base_upper) else 0;
    const pref_limit_upper = if (pref_is_64bit) try node.function.read32(offset.prefetchable_limit_upper) else 0;

    return .{
        .io = io,
        .memory = memory,
        .prefetchable_memory = decodePrefetchableWindow(
            pref_base_lo,
            pref_limit_lo,
            pref_base_upper,
            pref_limit_upper,
            pref_is_64bit,
        ),
    };
}

/// Builds the root-to-`index` ancestor path in caller scratch.
/// Allocation: none. Lifetime: returned slice aliases `scratch`.
/// Errors: `StorageExhausted` when scratch is too short.
pub fn pathTo(
    t: *const tree.Tree,
    index: tree.NodeIndex,
    scratch: []tree.NodeIndex,
) error{StorageExhausted}![]const tree.NodeIndex {
    std.debug.assert(@as(usize, index) < t.nodes.len);

    var depth: usize = 1;
    var cursor = index;
    while (t.node(cursor).parent) |parent| {
        cursor = parent;
        depth += 1;
    }

    if (depth > scratch.len) return error.StorageExhausted;

    var remaining = depth;
    cursor = index;
    while (true) {
        remaining -= 1;
        scratch[remaining] = cursor;
        cursor = t.node(cursor).parent orelse break;
    }

    std.debug.assert(remaining == 0);
    return scratch[0..depth];
}

fn decodeIoWindow(base_lo: u8, limit_lo: u8, base_upper: u16, limit_upper: u16) Window {
    const base = (@as(u64, base_lo & 0xF0) << 8) | (@as(u64, base_upper) << 16);
    const limit = (@as(u64, limit_lo & 0xF0) << 8) | 0xFFF | (@as(u64, limit_upper) << 16);

    return .{
        .base = base,
        .limit = limit,
        .enabled = (base_lo != 0 or limit_lo != 0) and base <= limit,
    };
}

fn decodeMemoryWindow(base: u16, limit: u16) Window {
    return .{
        .base = @as(u64, base & 0xFFF0) << 16,
        .limit = (@as(u64, limit & 0xFFF0) << 16) | 0x000F_FFFF,
        .enabled = base <= limit,
    };
}

fn decodePrefetchableWindow(
    base_lo: u16,
    limit_lo: u16,
    base_upper: u32,
    limit_upper: u32,
    is_64bit: bool,
) PrefetchableWindow {
    const base = (@as(u64, base_lo & 0xFFF0) << 16) | (@as(u64, base_upper) << 32);
    const limit = (@as(u64, limit_lo & 0xFFF0) << 16) | 0x000F_FFFF | (@as(u64, limit_upper) << 32);

    return .{
        .base = base,
        .limit = limit,
        .is_64bit = is_64bit,
        .enabled = base <= limit,
    };
}

comptime {
    std.debug.assert(@sizeOf(BusRange) == 3);
    std.debug.assert(@sizeOf(Window) == 24);
    std.debug.assert(@sizeOf(PrefetchableWindow) == 24);
}
