//! Standard PCI capability-list traversal. Spec: docs/specs/capabilities/list.md.

const std = @import("std");

const stdx = @import("stdx");

const config = @import("../config.zig");
const header = @import("../header.zig");

const ConfigSpace = config.ConfigSpace;
const Function = config.Function;
const VisitedSet = stdx.bits.BitSet.Static(standard.window.slot_count);

pub const standard = struct {
    pub const head_offset: u8 = 0x34;

    pub const window = struct {
        pub const start: u8 = 0x40;
        pub const end: u8 = 0xFC;
        pub const step: u8 = 4;
        pub const slot_count: usize = 48;
    };
};

pub const Error = ConfigSpace.Error || error{MalformedCapability};

pub const Id = enum(u8) {
    pci_express = 0x10,
    msi = 0x05,
    msi_x = 0x11,
    _,
};

pub const Capability = struct {
    id: u8,
    offset: u8,

    pub fn idTag(self: Capability) Id {
        return @enumFromInt(self.id);
    }
};

pub const Iterator = struct {
    function: Function,
    head: ?u8,
    visited: VisitedSet,

    /// Validates the common-header capability-list status bit and captures the first node pointer.
    pub fn validate(function: Function) Error!Iterator {
        const common = header.common.View.init(function);
        const status = try common.status();
        if (!status.capabilities_list) return Iterator.empty(function);

        const raw_head = try common.capabilitiesPointer();
        const head = raw_head & ~@as(u8, 0b11);
        if (head == 0) return Iterator.empty(function);

        return .{
            .function = function,
            .head = head,
            .visited = VisitedSet.init(),
        };
    }

    pub fn next(self: *Iterator) Error!?Capability {
        const p = self.head orelse return null;
        const slot = try validateNodeOffset(p);
        if (self.visited.isSet(slot)) return error.MalformedCapability;
        _ = self.visited.set(slot) catch unreachable;

        const id = try self.function.read8(p);
        const raw_next = try self.function.read8(@as(usize, p) + 1);
        if (raw_next & 0b11 != 0) return error.MalformedCapability;

        self.head = if (raw_next == 0) null else raw_next;
        return .{ .id = id, .offset = p };
    }

    pub fn find(self: *Iterator, target: Id) Error!?Capability {
        while (try self.next()) |capability| {
            if (capability.idTag() == target) return capability;
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

/// Constructs an iterator and walks it for the first capability with `id == target`.
pub fn find(function: Function, target: Id) Error!?Capability {
    var iterator = try Iterator.validate(function);
    return iterator.find(target);
}

pub const Cursor = struct {
    function: Function,
    base: u8,

    pub fn from(function: Function, base: u8) Error!Cursor {
        _ = try validateNodeOffset(base);
        return .{ .function = function, .base = base };
    }

    pub fn read8(self: Cursor, offset: u8) Error!u8 {
        const absolute = try self.absoluteOffset(offset, 1);
        return self.function.read8(absolute);
    }

    pub fn read16(self: Cursor, offset: u8) Error!u16 {
        const absolute = try self.absoluteOffset(offset, 2);
        return self.function.read16(absolute);
    }

    pub fn read32(self: Cursor, offset: u8) Error!u32 {
        const absolute = try self.absoluteOffset(offset, 4);
        return self.function.read32(absolute);
    }

    pub fn write8(self: Cursor, offset: u8, value: u8) Error!void {
        const absolute = try self.absoluteOffset(offset, 1);
        return self.function.write8(absolute, value);
    }

    pub fn write16(self: Cursor, offset: u8, value: u16) Error!void {
        const absolute = try self.absoluteOffset(offset, 2);
        return self.function.write16(absolute, value);
    }

    pub fn write32(self: Cursor, offset: u8, value: u32) Error!void {
        const absolute = try self.absoluteOffset(offset, 4);
        return self.function.write32(absolute, value);
    }

    fn absoluteOffset(self: Cursor, offset: u8, width: usize) Error!usize {
        std.debug.assert(width == 1 or width == 2 or width == 4);

        const absolute = @as(usize, self.base) + @as(usize, offset);
        try validateAccess(absolute, width, 0x100);
        return absolute;
    }
};

fn validateNodeOffset(offset: u8) Error!usize {
    if (offset < standard.window.start) return error.MalformedCapability;
    if (offset > standard.window.end) return error.MalformedCapability;
    if (offset % standard.window.step != 0) return error.MalformedCapability;

    return @intCast(@divExact(offset - standard.window.start, standard.window.step));
}

fn validateAccess(offset: usize, width: usize, end: usize) Error!void {
    std.debug.assert(width == 1 or width == 2 or width == 4);

    if (offset > end) return error.MalformedCapability;
    if (width > end - offset) return error.MalformedCapability;
    if (width == 2 and offset % 2 != 0) return error.MalformedCapability;
    if (width == 4 and offset % 4 != 0) return error.MalformedCapability;
}
