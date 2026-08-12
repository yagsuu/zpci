//! PCI Express extended capability-list traversal. Spec: docs/specs/capabilities/extended.md.

const std = @import("std");

const stdx = @import("stdx");

const config = @import("../config.zig");

const ConfigSpace = config.ConfigSpace;
const Function = config.Function;
const VisitedSet = stdx.bits.BitSet.Static(ext.window.slot_count);

pub const ext = struct {
    pub const window = struct {
        pub const range = stdx.core.InclusiveRange(u16).of(0x100, 0xFFC);
        pub const step: u16 = 4;
        pub const slot_count: usize = 960;
    };
};

pub const Error = ConfigSpace.Error || error{MalformedCapability};

pub const Id = enum(u16) {
    _,
};

pub const ExtCapability = struct {
    id: u16,
    version: u4,
    offset: u16,

    pub fn idTag(self: ExtCapability) Id {
        return @enumFromInt(self.id);
    }
};

pub const Iterator = struct {
    function: Function,
    head: ?u16,
    visited: VisitedSet,

    /// Reads the extended-capability head dword and captures the root when present.
    pub fn validate(function: Function) Error!Iterator {
        const head = try function.read32(ext.window.range.start);
        if (head == 0 or head == 0xFFFF_FFFF) return Iterator.empty(function);

        return .{
            .function = function,
            .head = ext.window.range.start,
            .visited = VisitedSet.init(),
        };
    }

    pub fn next(self: *Iterator) Error!?ExtCapability {
        const p = self.head orelse return null;
        const slot = try validateNodeOffset(p);
        if (self.visited.isSet(slot)) return error.MalformedCapability;
        _ = self.visited.set(slot) catch unreachable;

        const raw = try self.function.read32(p);
        const next_offset: u16 = @intCast((raw >> 20) & 0xFFF);

        self.head = if (next_offset == 0) null else next_offset;
        return .{
            .id = @truncate(raw),
            .version = @intCast((raw >> 16) & 0xF),
            .offset = p,
        };
    }

    pub fn find(self: *Iterator, target: u16) Error!?ExtCapability {
        while (try self.next()) |capability| {
            if (capability.id == target) return capability;
        }

        return null;
    }

    fn empty(function: Function) Iterator {
        return .{
            .function = function,
            .head = null,
            .visited = VisitedSet.init(),
        };
    }
};

/// Constructs an iterator and walks it for the first extended capability with `id == target`.
pub fn find(function: Function, target: u16) Error!?ExtCapability {
    var iterator = try Iterator.validate(function);
    return iterator.find(target);
}

pub const Cursor = struct {
    function: Function,
    base: u16,

    pub fn from(function: Function, base: u16) Error!Cursor {
        _ = try validateNodeOffset(base);
        return .{ .function = function, .base = base };
    }

    pub fn read8(self: Cursor, offset: u16) Error!u8 {
        const absolute = try self.absoluteOffset(offset, 1);
        return self.function.read8(absolute);
    }

    pub fn read16(self: Cursor, offset: u16) Error!u16 {
        const absolute = try self.absoluteOffset(offset, 2);
        return self.function.read16(absolute);
    }

    pub fn read32(self: Cursor, offset: u16) Error!u32 {
        const absolute = try self.absoluteOffset(offset, 4);
        return self.function.read32(absolute);
    }

    pub fn write8(self: Cursor, offset: u16, value: u8) Error!void {
        const absolute = try self.absoluteOffset(offset, 1);
        return self.function.write8(absolute, value);
    }

    pub fn write16(self: Cursor, offset: u16, value: u16) Error!void {
        const absolute = try self.absoluteOffset(offset, 2);
        return self.function.write16(absolute, value);
    }

    pub fn write32(self: Cursor, offset: u16, value: u32) Error!void {
        const absolute = try self.absoluteOffset(offset, 4);
        return self.function.write32(absolute, value);
    }

    fn absoluteOffset(self: Cursor, offset: u16, width: usize) Error!usize {
        std.debug.assert(width == 1 or width == 2 or width == 4);

        const absolute = @as(usize, self.base) + @as(usize, offset);
        try validateAccess(absolute, width, 0x1000);
        return absolute;
    }
};

fn validateNodeOffset(offset: u16) Error!usize {
    if (!ext.window.range.contains(offset)) return error.MalformedCapability;
    if (offset % ext.window.step != 0) return error.MalformedCapability;

    return @intCast(@divExact(offset - ext.window.range.start, ext.window.step));
}

fn validateAccess(offset: usize, width: usize, end: usize) Error!void {
    std.debug.assert(width == 1 or width == 2 or width == 4);

    if (offset > end) return error.MalformedCapability;
    if (width > end - offset) return error.MalformedCapability;
    if (width == 2 and offset % 2 != 0) return error.MalformedCapability;
    if (width == 4 and offset % 4 != 0) return error.MalformedCapability;
}
