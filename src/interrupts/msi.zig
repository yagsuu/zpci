//! MSI capability view and programming. Spec: docs/specs/interrupts/msi.md.

const std = @import("std");

const config = @import("../config.zig");
const list = @import("../capabilities/list.zig");
const programming = @import("programming.zig");

const ConfigSpace = config.ConfigSpace;
const Function = config.Function;

pub const cap_id: u8 = 0x05;

pub const register = struct {
    pub const message_control: u8 = 0x02;
    pub const message_address_lo: u8 = 0x04;
    pub const message_address_hi_64: u8 = 0x08;
    pub const message_data_32: u8 = 0x08;
    pub const message_data_64: u8 = 0x0C;
    pub const ext_message_data_32: u8 = 0x0A;
    pub const ext_message_data_64: u8 = 0x0E;
    pub const mask_bits_32: u8 = 0x0C;
    pub const mask_bits_64: u8 = 0x10;
    pub const pending_bits_32: u8 = 0x10;
    pub const pending_bits_64: u8 = 0x14;
};

pub const MalformedFieldError = error{MalformedField};
pub const InvalidRoutingError = error{InvalidRouting};

pub const MessageControl = packed struct(u16) {
    msi_enable: bool,
    multiple_message_capable: u3,
    multiple_message_enable: u3,
    addr_64_capable: bool,
    pvm_capable: bool,
    ext_msg_data_capable: bool,
    ext_msg_data_enable: bool,
    _reserved11: u5,

    comptime {
        std.debug.assert(@sizeOf(MessageControl) == 2);
        std.debug.assert(@alignOf(MessageControl) == 2);
        std.debug.assert(@bitSizeOf(MessageControl) == 16);
    }

    pub fn raw(self: MessageControl) u16 {
        return @bitCast(self);
    }
};

pub const VectorCount = enum(u3) {
    one = 0,
    two = 1,
    four = 2,
    eight = 3,
    sixteen = 4,
    thirty_two = 5,
    _,

    pub fn numVectors(self: VectorCount) MalformedFieldError!u6 {
        return switch (@intFromEnum(self)) {
            0...5 => @as(u6, 1) << @as(u3, @intCast(@intFromEnum(self))),
            else => error.MalformedField,
        };
    }

    pub fn fromCount(n: u6) InvalidRoutingError!VectorCount {
        return switch (n) {
            1 => .one,
            2 => .two,
            4 => .four,
            8 => .eight,
            16 => .sixteen,
            32 => .thirty_two,
            else => error.InvalidRouting,
        };
    }
};

pub const View = struct {
    function: Function,
    base: u8,
    control_snapshot: MessageControl,

    pub const ReadError = error{
        MalformedCapability,
        MalformedField,
    } || ConfigSpace.Error;

    pub const ProgramError = error{
        MalformedField,
        InvalidRouting,
        ProgrammingReadbackMismatch,
        ProgrammingWriteFailed,
        ProgrammingPartial,
    };

    pub const Routing = struct {
        address: u64,
        data: u16,
        vector_count: VectorCount,
        pvm: PvmRouting = .unused,
        ext_data: ExtDataRouting = .unused,

        pub const PvmRouting = union(enum) {
            unused: void,
            initial_mask: u32,
        };

        pub const ExtDataRouting = union(enum) {
            unused: void,
            value: u16,
        };
    };

    pub fn find(function: Function) ReadError!?View {
        var iterator = try list.Iterator.validate(function);
        while (try iterator.next()) |capability| {
            if (capability.id == cap_id) return try View.validate(function, capability);
        }

        return null;
    }

    pub fn validate(function: Function, capability: list.Capability) ReadError!View {
        std.debug.assert(capability.id == cap_id);

        const control = try readMessageControl(function, capability.offset);
        _ = try controlCount(control.multiple_message_capable).numVectors();

        return .{
            .function = function,
            .base = capability.offset,
            .control_snapshot = control,
        };
    }

    pub fn addr64Capable(self: View) bool {
        return self.control_snapshot.addr_64_capable;
    }

    pub fn pvmCapable(self: View) bool {
        return self.control_snapshot.pvm_capable;
    }

    pub fn extMessageDataCapable(self: View) bool {
        return self.control_snapshot.ext_msg_data_capable;
    }

    pub fn multipleMessageCapable(self: View) ReadError!VectorCount {
        const count = controlCount(self.control_snapshot.multiple_message_capable);
        _ = try count.numVectors();
        return count;
    }

    pub fn messageControl(self: View) ReadError!MessageControl {
        return readMessageControl(self.function, self.base);
    }

    pub fn messageAddress(self: View) ReadError!u64 {
        const low = try self.read32(register.message_address_lo);
        if (!self.addr64Capable()) return low;

        const high = try self.read32(register.message_address_hi_64);
        return (@as(u64, high) << 32) | @as(u64, low);
    }

    pub fn messageData(self: View) ReadError!u16 {
        return self.read16(self.messageDataOffset());
    }

    pub fn multipleMessageEnable(self: View) ReadError!VectorCount {
        const control = try self.messageControl();
        const count = controlCount(control.multiple_message_enable);
        _ = try count.numVectors();
        return count;
    }

    pub fn extendedMessageData(self: View) ReadError!u16 {
        std.debug.assert(self.extMessageDataCapable());
        return self.read16(self.extMessageDataOffset());
    }

    pub fn extendedMessageDataEnabled(self: View) ReadError!bool {
        const control = try self.messageControl();
        return control.ext_msg_data_enable;
    }

    pub fn mask(self: View) ReadError!u32 {
        std.debug.assert(self.pvmCapable());
        return self.read32(self.maskOffset());
    }

    pub fn pending(self: View) ReadError!u32 {
        std.debug.assert(self.pvmCapable());
        return self.read32(self.pendingOffset());
    }

    pub fn readRouting(self: View) ReadError!Routing {
        const control = try self.messageControl();
        const vector_count = controlCount(control.multiple_message_enable);
        _ = try vector_count.numVectors();

        return .{
            .address = try self.messageAddress(),
            .data = try self.messageData(),
            .vector_count = vector_count,
            .pvm = if (self.pvmCapable()) .{ .initial_mask = try self.mask() } else .unused,
            .ext_data = if (self.extMessageDataCapable()) .{ .value = try self.extendedMessageData() } else .unused,
        };
    }

    pub fn setVectorMasked(self: View, index: u5, masked: bool) ProgramError!void {
        std.debug.assert(self.pvmCapable());

        const vector_count = try self.controlSnapshotVectorLimit();
        std.debug.assert(index < vector_count);

        var value = self.mask() catch return error.ProgrammingWriteFailed;
        const bit = @as(u32, 1) << index;
        if (masked) {
            value |= bit;
        } else {
            value &= ~bit;
        }

        return self.setMask(value);
    }

    pub fn setMask(self: View, value: u32) ProgramError!void {
        std.debug.assert(self.pvmCapable());

        var tx = ProgramTransaction.init(ConfigTarget.init(self));
        const offset = self.maskOffset();
        const saved = tx.read32(offset) catch return error.ProgrammingWriteFailed;
        try tx.writeReadback32(offset, value, saved);
    }

    pub fn program(self: View, routing: Routing) ProgramError!void {
        try self.validateRouting(routing);

        var tx = ProgramTransaction.init(ConfigTarget.init(self));
        const saved = SaveFrame.read(self, &tx) catch return error.ProgrammingWriteFailed;

        var disabled_control = saved.control;
        disabled_control.msi_enable = false;
        try tx.writeReadback16(register.message_control, disabled_control.raw(), saved.control.raw());

        switch (routing.pvm) {
            .unused => {},
            .initial_mask => |value| try tx.writeReadback32(self.maskOffset(), value, saved.mask),
        }

        try tx.writeReadback32(register.message_address_lo, @truncate(routing.address), saved.address_lo);
        if (self.addr64Capable()) {
            try tx.writeReadback32(register.message_address_hi_64, @truncate(routing.address >> 32), saved.address_hi);
        }

        try tx.writeReadback16(self.messageDataOffset(), routing.data, saved.data);

        switch (routing.ext_data) {
            .unused => {},
            .value => |value| try tx.writeReadback16(self.extMessageDataOffset(), value, saved.ext_data),
        }

        var enabled_control = saved.control;
        enabled_control.msi_enable = true;
        enabled_control.multiple_message_enable = @intFromEnum(routing.vector_count);
        enabled_control.ext_msg_data_enable = routing.ext_data == .value;
        try tx.writeReadback16(register.message_control, enabled_control.raw(), saved.control.raw());
    }

    pub fn disable(self: View) ProgramError!void {
        var tx = ProgramTransaction.init(ConfigTarget.init(self));
        const saved_raw = tx.read16(register.message_control) catch return error.ProgrammingWriteFailed;
        var control: MessageControl = @bitCast(saved_raw);
        control.msi_enable = false;

        try tx.writeReadback16(register.message_control, control.raw(), saved_raw);
    }

    fn validateRouting(self: View, routing: Routing) ProgramError!void {
        const requested_vectors = try routing.vector_count.numVectors();
        const capable_vectors = try self.controlSnapshotVectorLimit();
        if (requested_vectors > capable_vectors) return error.InvalidRouting;
        if (!self.addr64Capable() and routing.address > std.math.maxInt(u32)) return error.InvalidRouting;

        const data_mask = @as(u16, @intCast(requested_vectors - 1));
        if (routing.data & data_mask != 0) return error.InvalidRouting;

        switch (routing.pvm) {
            .unused => {},
            .initial_mask => if (!self.pvmCapable()) return error.InvalidRouting,
        }

        switch (routing.ext_data) {
            .unused => if (self.extMessageDataCapable()) return error.InvalidRouting,
            .value => if (!self.extMessageDataCapable()) return error.InvalidRouting,
        }
    }

    fn controlSnapshotVectorLimit(self: View) ProgramError!u6 {
        return controlCount(self.control_snapshot.multiple_message_capable).numVectors();
    }

    fn messageDataOffset(self: View) u8 {
        return if (self.addr64Capable()) register.message_data_64 else register.message_data_32;
    }

    fn extMessageDataOffset(self: View) u8 {
        std.debug.assert(self.extMessageDataCapable());
        return if (self.addr64Capable()) register.ext_message_data_64 else register.ext_message_data_32;
    }

    fn maskOffset(self: View) u8 {
        std.debug.assert(self.pvmCapable());
        return if (self.addr64Capable()) register.mask_bits_64 else register.mask_bits_32;
    }

    fn pendingOffset(self: View) u8 {
        std.debug.assert(self.pvmCapable());
        return if (self.addr64Capable()) register.pending_bits_64 else register.pending_bits_32;
    }

    fn read16(self: View, offset: u8) ConfigSpace.Error!u16 {
        return self.function.read16(self.byteOffset(offset));
    }

    fn read32(self: View, offset: u8) ConfigSpace.Error!u32 {
        return self.function.read32(self.byteOffset(offset));
    }

    fn write16(self: View, offset: u8, value: u16) ConfigSpace.Error!void {
        return self.function.write16(self.byteOffset(offset), value);
    }

    fn write32(self: View, offset: u8, value: u32) ConfigSpace.Error!void {
        return self.function.write32(self.byteOffset(offset), value);
    }

    fn byteOffset(self: View, offset: u8) usize {
        return @as(usize, self.base) + @as(usize, offset);
    }
};

const ConfigTarget = struct {
    function: Function,
    base: usize,

    pub fn init(view: View) ConfigTarget {
        return .{ .function = view.function, .base = view.base };
    }

    pub fn read16(self: ConfigTarget, offset: usize) ConfigSpace.Error!u16 {
        return self.function.read16(self.base + offset);
    }

    pub fn read32(self: ConfigTarget, offset: usize) ConfigSpace.Error!u32 {
        return self.function.read32(self.base + offset);
    }

    pub fn write16(self: ConfigTarget, offset: usize, value: u16) ConfigSpace.Error!void {
        return self.function.write16(self.base + offset, value);
    }

    pub fn write32(self: ConfigTarget, offset: usize, value: u32) ConfigSpace.Error!void {
        return self.function.write32(self.base + offset, value);
    }
};

const ProgramTransaction = programming.Transaction(ConfigTarget, .{
    .max_entries = 7,
    .word16 = true,
    .word32 = true,
});

const SaveFrame = struct {
    control: MessageControl,
    address_lo: u32,
    address_hi: u32 = 0,
    data: u16,
    ext_data: u16 = 0,
    mask: u32 = 0,

    fn read(view: View, tx: *ProgramTransaction) programming.Error!SaveFrame {
        const control: MessageControl = @bitCast(try tx.read16(register.message_control));
        const address_lo = try tx.read32(register.message_address_lo);
        const address_hi = if (view.addr64Capable()) try tx.read32(register.message_address_hi_64) else 0;
        const data = try tx.read16(view.messageDataOffset());
        const ext_data = if (view.extMessageDataCapable()) try tx.read16(view.extMessageDataOffset()) else 0;
        const mask = if (view.pvmCapable()) try tx.read32(view.maskOffset()) else 0;

        return .{
            .control = control,
            .address_lo = address_lo,
            .address_hi = address_hi,
            .data = data,
            .ext_data = ext_data,
            .mask = mask,
        };
    }
};

fn readMessageControl(function: Function, base: u8) ConfigSpace.Error!MessageControl {
    const raw = try function.read16(@as(usize, base) + register.message_control);
    return @bitCast(raw);
}

fn controlCount(raw: u3) VectorCount {
    return @enumFromInt(raw);
}
