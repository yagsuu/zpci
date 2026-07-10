//! MSI-X capability and table programming. Spec: docs/specs/interrupts/msix.md.

const std = @import("std");

const config = @import("../config.zig");
const list = @import("../capabilities/list.zig");
const memory = @import("../memory.zig");

pub const cap_id: u8 = 0x11;

pub const register = struct {
    pub const message_control: u8 = 0x02;
    pub const table_offset_bir: u8 = 0x04;
    pub const pba_offset_bir: u8 = 0x08;
};

pub const entry = struct {
    pub const message_address_lo: usize = 0x0;
    pub const message_address_hi: usize = 0x4;
    pub const message_data: usize = 0x8;
    pub const vector_control: usize = 0xC;
};

pub const table_entry_size: usize = 16;
pub const pba_bits_per_dword: usize = 32;
pub const max_table_size: u16 = 2048;

pub const MessageControl = packed struct(u16) {
    table_size_minus_one: u11,
    _reserved11: u3,
    function_mask: bool,
    msix_enable: bool,

    comptime {
        std.debug.assert(@sizeOf(MessageControl) == 2);
        std.debug.assert(@alignOf(MessageControl) == 2);
        std.debug.assert(@bitSizeOf(MessageControl) == 16);
    }
};

pub const VectorControl = packed struct(u32) {
    masked: bool,
    _reserved1: u31,

    comptime {
        std.debug.assert(@sizeOf(VectorControl) == 4);
        std.debug.assert(@alignOf(VectorControl) == 4);
        std.debug.assert(@bitSizeOf(VectorControl) == 32);
    }
};

pub const TableLocation = struct {
    bir: u3,
    offset: u32,
};

pub const PbaLocation = struct {
    bir: u3,
    offset: u32,
};

pub const VectorEntry = struct {
    address: u64,
    data: u32,
    masked: bool,
};

pub const View = struct {
    function: config.Function,
    base: u8,
    control_snapshot: MessageControl,
    table_location: TableLocation,
    pba_location: PbaLocation,

    pub const ReadError = error{
        MalformedCapability,
        MalformedField,
        InvalidRouting,
    } || config.ConfigSpace.Error || memory.BarMemory.Error;

    pub const ProgramError = error{
        MalformedField,
        InvalidRouting,
        BarMemoryOutOfBounds,
        UnalignedAccess,
        ProgrammingReadbackMismatch,
        ProgrammingWriteFailed,
        ProgrammingPartial,
    };

    const MessageControlUpdate = union(enum) {
        msix_enable: bool,
        function_mask: bool,
    };

    pub fn find(function: config.Function) ReadError!?View {
        var iterator = try list.Iterator.validate(function);
        while (try iterator.next()) |capability| {
            if (capability.id == cap_id) return try validate(function, capability);
        }

        return null;
    }

    pub fn validate(function: config.Function, capability: list.Capability) ReadError!View {
        std.debug.assert(capability.id == cap_id);

        const control_offset = @as(usize, capability.offset) + register.message_control;
        const control = messageControlFromRaw(try function.read16(control_offset));

        const table_location = try decodeTableLocation(try function.read32(
            @as(usize, capability.offset) + register.table_offset_bir,
        ));

        const pba_location = try decodePbaLocation(try function.read32(
            @as(usize, capability.offset) + register.pba_offset_bir,
        ));

        return .{
            .function = function,
            .base = capability.offset,
            .control_snapshot = control,
            .table_location = table_location,
            .pba_location = pba_location,
        };
    }

    pub fn tableSize(self: View) u16 {
        const size = @as(u16, self.control_snapshot.table_size_minus_one) + 1;
        std.debug.assert(size >= 1);
        std.debug.assert(size <= max_table_size);
        return size;
    }

    pub fn tableLocation(self: View) TableLocation {
        return self.table_location;
    }

    pub fn pbaLocation(self: View) PbaLocation {
        return self.pba_location;
    }

    /// Byte length of the table region covered by a caller-supplied `table_memory`.
    pub fn tableSpanBytes(self: View) usize {
        return @as(usize, self.tableSize()) * table_entry_size;
    }

    /// Byte length of the PBA region covered by a caller-supplied `pba_memory`.
    pub fn pbaSpanBytes(self: View) usize {
        const adjusted_size = @as(usize, self.tableSize()) + pba_bits_per_dword - 1;
        const dword_count = @divFloor(adjusted_size, pba_bits_per_dword);
        return dword_count * @sizeOf(u32);
    }

    pub fn messageControl(self: View) ReadError!MessageControl {
        return messageControlFromRaw(try self.function.read16(self.controlOffset()));
    }

    pub fn enabled(self: View) ReadError!bool {
        return (try self.messageControl()).msix_enable;
    }

    pub fn functionMasked(self: View) ReadError!bool {
        return (try self.messageControl()).function_mask;
    }

    pub fn readEntry(
        self: View,
        table_memory: memory.BarMemory,
        vector_index: u11,
    ) ReadError!VectorEntry {
        if (vector_index >= self.tableSize()) return error.InvalidRouting;

        const entry_base = @as(usize, vector_index) * table_entry_size;
        const vector_control_offset = entry_base + entry.vector_control;
        if (!containsDword(table_memory.len(), vector_control_offset)) return error.BarMemoryOutOfBounds;

        const address_lo = try table_memory.read32(entry_base + entry.message_address_lo);
        const address_hi = try table_memory.read32(entry_base + entry.message_address_hi);
        const data = try table_memory.read32(entry_base + entry.message_data);
        const vector_control = vectorControlFromRaw(try table_memory.read32(entry_base + entry.vector_control));
        const address = (@as(u64, address_hi) << 32) | @as(u64, address_lo);

        return .{ .address = address, .data = data, .masked = vector_control.masked };
    }

    pub fn vectorPending(
        self: View,
        pba_memory: memory.BarMemory,
        vector_index: u11,
    ) ReadError!bool {
        if (vector_index >= self.tableSize()) return error.InvalidRouting;

        const dword_index = @divFloor(@as(usize, vector_index), pba_bits_per_dword);
        const bit_index = @mod(@as(usize, vector_index), pba_bits_per_dword);
        const bits = try self.pendingDword(pba_memory, dword_index);
        const shift: u5 = @intCast(bit_index);

        return bits & (@as(u32, 1) << shift) != 0;
    }

    pub fn pendingDword(self: View, pba_memory: memory.BarMemory, dword_index: usize) ReadError!u32 {
        const offset = std.math.mul(usize, dword_index, @sizeOf(u32)) catch {
            return error.BarMemoryOutOfBounds;
        };
        if (!containsDword(self.pbaSpanBytes(), offset)) return error.BarMemoryOutOfBounds;
        if (!containsDword(pba_memory.len(), offset)) return error.BarMemoryOutOfBounds;

        return pba_memory.read32(offset);
    }

    pub fn enable(self: View) ProgramError!void {
        try self.commitMessageControl(.{ .msix_enable = true });
    }

    pub fn disable(self: View) ProgramError!void {
        try self.commitMessageControl(.{ .msix_enable = false });
    }

    pub fn setFunctionMask(self: View, masked: bool) ProgramError!void {
        try self.commitMessageControl(.{ .function_mask = masked });
    }

    pub fn programEntry(
        self: View,
        table_memory: memory.BarMemory,
        vector_index: u11,
        vector_entry: VectorEntry,
    ) ProgramError!void {
        const entry_base = try self.checkedEntryBase(table_memory, vector_index);
        var save: EntrySave = undefined;

        try programEntryAt(table_memory, entry_base, vector_entry, &save);
    }

    pub fn programEntries(
        self: View,
        table_memory: memory.BarMemory,
        first_index: u11,
        entries: []const VectorEntry,
    ) ProgramError!void {
        if (entries.len == 0) return;

        const max_additional_entries = std.math.maxInt(usize) - @as(usize, first_index);
        std.debug.assert(entries.len <= max_additional_entries);

        const start = @as(usize, first_index);
        const end = start + entries.len;
        if (end > self.tableSize()) return error.InvalidRouting;
        if (end * table_entry_size > table_memory.len()) return error.BarMemoryOutOfBounds;

        var save: EntrySave = undefined;
        for (entries, 0..) |vector_entry, i| {
            try programEntryAt(table_memory, (start + i) * table_entry_size, vector_entry, &save);
        }
    }

    pub fn setVectorMask(
        self: View,
        table_memory: memory.BarMemory,
        vector_index: u11,
        masked: bool,
    ) ProgramError!void {
        const entry_base = try self.checkedEntryBase(table_memory, vector_index);
        const offset = entry_base + entry.vector_control;
        const saved = table_memory.read32(offset) catch return error.ProgrammingWriteFailed;
        var control = vectorControlFromRaw(saved);
        control.masked = masked;
        const updated = vectorControlToRaw(control);

        commitDword(table_memory, offset, updated) catch |err| {
            try restoreDword(table_memory, offset, saved);
            return err;
        };
    }

    fn checkedEntryBase(
        self: View,
        table_memory: memory.BarMemory,
        vector_index: u11,
    ) ProgramError!usize {
        if (vector_index >= self.tableSize()) return error.InvalidRouting;

        const entry_base = @as(usize, vector_index) * table_entry_size;
        if (!containsDword(table_memory.len(), entry_base + entry.vector_control)) return error.BarMemoryOutOfBounds;

        return entry_base;
    }

    fn commitMessageControl(self: View, update: MessageControlUpdate) ProgramError!void {
        const offset = self.controlOffset();
        const saved = self.function.read16(offset) catch return error.ProgrammingWriteFailed;
        var control = messageControlFromRaw(saved);

        switch (update) {
            .msix_enable => |enabled_value| control.msix_enable = enabled_value,
            .function_mask => |masked_value| control.function_mask = masked_value,
        }

        const updated = messageControlToRaw(control);
        self.function.write16(offset, updated) catch return error.ProgrammingWriteFailed;
        const readback = self.function.read16(offset) catch return error.ProgrammingWriteFailed;
        if (readback != updated) return error.ProgrammingReadbackMismatch;
    }

    fn controlOffset(self: View) usize {
        return @as(usize, self.base) + register.message_control;
    }
};

const EntrySave = struct {
    address_lo: u32,
    address_hi: u32,
    data: u32,
    vector_control: u32,
};

const RollbackDepth = enum {
    vector_control,
    address_lo,
    address_hi,
    data,
};

fn programEntryAt(
    table_memory: memory.BarMemory,
    entry_base: usize,
    vector_entry: VectorEntry,
    save: *EntrySave,
) View.ProgramError!void {
    save.* = try readEntrySave(table_memory, entry_base);
    var masked_control = vectorControlFromRaw(save.vector_control);
    masked_control.masked = true;
    const masked_raw = vectorControlToRaw(masked_control);
    var final_control = vectorControlFromRaw(save.vector_control);
    final_control.masked = vector_entry.masked;
    const final_raw = vectorControlToRaw(final_control);
    const address_lo: u32 = @truncate(vector_entry.address);
    const address_hi: u32 = @truncate(vector_entry.address >> 32);

    commitDword(table_memory, entry_base + entry.vector_control, masked_raw) catch |err| {
        try rollbackEntry(table_memory, entry_base, save, .vector_control);
        return err;
    };

    writeDword(table_memory, entry_base + entry.message_address_lo, address_lo) catch |err| {
        try rollbackEntry(table_memory, entry_base, save, .vector_control);
        return err;
    };

    readbackDword(table_memory, entry_base + entry.message_address_lo, address_lo) catch |err| {
        try rollbackEntry(table_memory, entry_base, save, .address_lo);
        return err;
    };

    writeDword(table_memory, entry_base + entry.message_address_hi, address_hi) catch |err| {
        try rollbackEntry(table_memory, entry_base, save, .address_lo);
        return err;
    };

    readbackDword(table_memory, entry_base + entry.message_address_hi, address_hi) catch |err| {
        try rollbackEntry(table_memory, entry_base, save, .address_hi);
        return err;
    };

    writeDword(table_memory, entry_base + entry.message_data, vector_entry.data) catch |err| {
        try rollbackEntry(table_memory, entry_base, save, .address_hi);
        return err;
    };

    readbackDword(table_memory, entry_base + entry.message_data, vector_entry.data) catch |err| {
        try rollbackEntry(table_memory, entry_base, save, .data);
        return err;
    };

    writeDword(table_memory, entry_base + entry.vector_control, final_raw) catch |err| {
        try rollbackEntry(table_memory, entry_base, save, .data);
        return err;
    };

    readbackDword(table_memory, entry_base + entry.vector_control, final_raw) catch |err| {
        try rollbackEntry(table_memory, entry_base, save, .data);
        return err;
    };
}

fn readEntrySave(table_memory: memory.BarMemory, entry_base: usize) View.ProgramError!EntrySave {
    return .{
        .address_lo = table_memory.read32(entry_base + entry.message_address_lo) catch {
            return error.ProgrammingWriteFailed;
        },
        .address_hi = table_memory.read32(entry_base + entry.message_address_hi) catch {
            return error.ProgrammingWriteFailed;
        },
        .data = table_memory.read32(entry_base + entry.message_data) catch {
            return error.ProgrammingWriteFailed;
        },
        .vector_control = table_memory.read32(entry_base + entry.vector_control) catch {
            return error.ProgrammingWriteFailed;
        },
    };
}

fn rollbackEntry(
    table_memory: memory.BarMemory,
    entry_base: usize,
    save: *const EntrySave,
    depth: RollbackDepth,
) View.ProgramError!void {
    switch (depth) {
        .data => try restoreDword(table_memory, entry_base + entry.message_data, save.data),
        .address_hi, .address_lo, .vector_control => {},
    }

    switch (depth) {
        .data, .address_hi => try restoreDword(
            table_memory,
            entry_base + entry.message_address_hi,
            save.address_hi,
        ),
        .address_lo, .vector_control => {},
    }

    switch (depth) {
        .data, .address_hi, .address_lo => try restoreDword(
            table_memory,
            entry_base + entry.message_address_lo,
            save.address_lo,
        ),
        .vector_control => {},
    }

    try restoreDword(table_memory, entry_base + entry.vector_control, save.vector_control);
}

fn commitDword(table_memory: memory.BarMemory, offset: usize, value: u32) View.ProgramError!void {
    try writeDword(table_memory, offset, value);
    try readbackDword(table_memory, offset, value);
}

fn writeDword(table_memory: memory.BarMemory, offset: usize, value: u32) View.ProgramError!void {
    table_memory.write32(offset, value) catch return error.ProgrammingWriteFailed;
}

fn readbackDword(table_memory: memory.BarMemory, offset: usize, expected: u32) View.ProgramError!void {
    const readback = table_memory.read32(offset) catch return error.ProgrammingWriteFailed;
    if (readback != expected) return error.ProgrammingReadbackMismatch;
}

fn restoreDword(table_memory: memory.BarMemory, offset: usize, value: u32) View.ProgramError!void {
    table_memory.write32(offset, value) catch return error.ProgrammingPartial;
    const readback = table_memory.read32(offset) catch return error.ProgrammingPartial;
    if (readback != value) return error.ProgrammingPartial;
}

fn decodeTableLocation(raw: u32) error{MalformedField}!TableLocation {
    const bir: u3 = @intCast(raw & 0b111);
    if (bir > 5) return error.MalformedField;

    return .{ .bir = bir, .offset = raw & ~@as(u32, 0b111) };
}

fn decodePbaLocation(raw: u32) error{MalformedField}!PbaLocation {
    const bir: u3 = @intCast(raw & 0b111);
    if (bir > 5) return error.MalformedField;

    return .{ .bir = bir, .offset = raw & ~@as(u32, 0b111) };
}

fn containsDword(len_bytes: usize, offset: usize) bool {
    if (offset > len_bytes) return false;
    return @sizeOf(u32) <= len_bytes - offset;
}

fn messageControlFromRaw(raw: u16) MessageControl {
    return @as(MessageControl, @bitCast(raw));
}

fn messageControlToRaw(control: MessageControl) u16 {
    return @as(u16, @bitCast(control));
}

fn vectorControlFromRaw(raw: u32) VectorControl {
    return @as(VectorControl, @bitCast(raw));
}

fn vectorControlToRaw(control: VectorControl) u32 {
    return @as(u32, @bitCast(control));
}

comptime {
    std.debug.assert(table_entry_size == 16);
    std.debug.assert(max_table_size == 2048);
}
