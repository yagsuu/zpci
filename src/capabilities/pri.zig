const std = @import("std");

const config = @import("config");
const core = @import("core");

const extended = @import("extended.zig");

const pri = core.capabilities.pri;

const Rel16 = core.RelativeOffset(u16);
const Rel32 = core.RelativeOffset(u32);

const Function = config.Function;
const Entry = extended.Entry;
const Registers = extended.Registers;

const Control = pri.Control.Word;
const ControlArgs = pri.Control.AssignArgs;
const Status = pri.Status.Word;

pub const Error = extended.Error || error{ InvalidState, InvalidValue };

pub const Capability = struct {
    registers: Registers,

    pub fn tryFrom(function: Function, entry: Entry) Error!Capability {
        std.debug.assert(entry.id == pri.id);

        const registers = try Registers.tryFrom(function, entry.offset);
        if (!registers.contains(offsets.request_allocation)) {
            return error.MalformedCapability;
        }

        return .{ .registers = registers };
    }

    pub fn find(function: Function) Error!?Capability {
        const entry = (try extended.find(function, pri.id)) orelse return null;
        return try Capability.tryFrom(function, entry);
    }

    pub fn control(self: Capability) Error!Control {
        return pri.Control.from(try self.registers.read(offsets.control));
    }

    pub fn updateControl(self: Capability, args: ControlArgs) Error!void {
        const observed = try self.control();
        const updated = pri.Control.replace(observed, args);
        const raw = pri.Control.raw(updated) & ~pri.Control.masks.trigger;

        return self.registers.write(offsets.control, raw);
    }

    pub fn status(self: Capability) Error!Status {
        return pri.Status.from(try self.registers.read(offsets.status));
    }

    pub fn ackStatus(self: Capability, observed: Status, comptime fields: anytype) Error!void {
        return self.registers.write(offsets.status, pri.Status.ack(observed, fields));
    }

    pub fn requestCapacity(self: Capability) Error!u32 {
        return self.registers.read(offsets.request_capacity);
    }

    pub fn requestAllocation(self: Capability) Error!u32 {
        return self.registers.read(offsets.request_allocation);
    }

    pub fn setRequestAllocation(self: Capability, value: u32) Error!void {
        const observed = try self.control();
        if (observed.enable) {
            return error.InvalidState;
        }

        const capacity = try self.requestCapacity();
        if (value > capacity) {
            return error.InvalidValue;
        }

        return self.registers.write(offsets.request_allocation, value);
    }

    pub fn reset(self: Capability) Error!void {
        const observed = try self.control();
        if (observed.enable) {
            return error.InvalidState;
        }

        const raw = (pri.Control.raw(observed) & ~pri.Control.masks.trigger) | pri.Control.trigger(.{.reset});

        return self.registers.write(offsets.control, raw);
    }
};

pub const offsets = struct {
    pub const control = Rel16.from(pri.offsets.control);
    pub const status = Rel16.from(pri.offsets.status);
    pub const request_capacity = Rel32.from(pri.offsets.request_capacity);
    pub const request_allocation = Rel32.from(pri.offsets.request_allocation);
};

pub const unit = struct {
    const testing = std.testing;

    const ConfigSpace = config.ConfigSpace;
    const ConfigError = ConfigSpace.Error;
    const Sbdf = core.Sbdf;

    const address = Sbdf.from(.from(0), 2, 3, 0);
    const base: u16 = 0x100;

    const ConfigBackend = struct {
        bytes: [core.config.extended_size]u8 = @splat(0),
        reads: usize = 0,
        writes: usize = 0,
        fail_read_at: ?usize = null,
        fail_write: bool = false,
        mutate_on_failure: bool = false,
        pending: u32 = 0,
        last_value: u32 = 0,

        const vtable: ConfigSpace.VTable = .{
            .read8 = read8,
            .read16 = read16,
            .read32 = read32,
            .write8 = write8,
            .write16 = write16,
            .write32 = write32,
        };

        fn configSpace(self: *ConfigBackend) ConfigSpace {
            return ConfigSpace.from(@ptrCast(self), &vtable);
        }

        fn capability(self: *ConfigBackend, position: u16) Error!Capability {
            return Capability.tryFrom(Function.from(self.configSpace(), address), .{
                .id = pri.id,
                .version = 1,
                .offset = position,
            });
        }

        fn read8(_: *anyopaque, _: Sbdf, _: usize) ConfigError!u8 {
            return error.UnsupportedAccessWidth;
        }

        fn write8(_: *anyopaque, _: Sbdf, _: usize, _: u8) ConfigError!void {
            return error.UnsupportedAccessWidth;
        }

        fn read16(context: *anyopaque, _: Sbdf, position: usize) ConfigError!u16 {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));

            self.reads += 1;

            if (self.fail_read_at == position) {
                return error.UnsupportedAccessWidth;
            }

            const raw = std.mem.readInt(u16, self.bytes[position..][0..2], .little);
            return if (position == base + pri.offsets.control) raw & ~@as(u16, 2) else raw;
        }

        fn read32(context: *anyopaque, _: Sbdf, position: usize) ConfigError!u32 {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));

            self.reads += 1;

            if (self.fail_read_at == position) {
                return error.UnsupportedAccessWidth;
            }

            return std.mem.readInt(u32, self.bytes[position..][0..4], .little);
        }

        fn write16(context: *anyopaque, _: Sbdf, position: usize, value: u16) ConfigError!void {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));

            self.writes += 1;
            self.last_value = value;

            if (self.fail_write and !self.mutate_on_failure) {
                return error.UnsupportedAccessWidth;
            }

            const observed = std.mem.readInt(u16, self.bytes[position..][0..2], .little);

            switch (position) {
                base + pri.offsets.status => {
                    store16(self, position, observed & ~(value & 3));
                },
                base + pri.offsets.control => {
                    var status = std.mem.readInt(u16, self.bytes[base + pri.offsets.status ..][0..2], .little);

                    if (value & 1 != 0 and observed & 1 == 0) {
                        status &= ~@as(u16, 0x0103);
                    }

                    if (value & 1 == 0 and observed & 1 != 0) {
                        status &= ~@as(u16, 0x0100);
                    }

                    if (value & 3 == 2) {
                        self.pending = 0;
                        status |= 0x0100;
                    }

                    store16(self, base + pri.offsets.status, status);
                    store16(self, position, value & ~@as(u16, 2));
                },
                else => {
                    store16(self, position, value);
                },
            }

            if (self.fail_write) {
                return error.UnsupportedAccessWidth;
            }
        }

        fn write32(context: *anyopaque, _: Sbdf, position: usize, value: u32) ConfigError!void {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));

            self.writes += 1;
            self.last_value = value;

            if (!self.fail_write or self.mutate_on_failure) {
                store32(self, position, value);
            }

            if (self.fail_write) {
                return error.UnsupportedAccessWidth;
            }
        }
    };

    test "PRI binds the complete fixed extent without IO" {
        var backend: ConfigBackend = .{};

        for ([_]u16{ 0xFC, 0x102, 0xFF4, 0xFF8, 0xFFC }) |position| {
            try testing.expectError(error.MalformedCapability, backend.capability(position));
        }

        _ = try backend.capability(0xFF0);

        try testing.expectEqual(@as(usize, 0), backend.reads);
        try testing.expectEqual(@as(usize, 0), backend.writes);
    }

    test "PRI discovery and live request words retain full width" {
        var backend: ConfigBackend = .{};
        const function = Function.from(backend.configSpace(), address);

        try testing.expectEqual(@as(?Capability, null), try Capability.find(function));

        store32(&backend, base, 0x0001_0013);
        store32(&backend, base + pri.offsets.request_capacity, 0xFFFF_FFFF);

        const cap = (try Capability.find(function)).?;

        try testing.expectEqual(@as(u32, 0xFFFF_FFFF), try cap.requestCapacity());

        try cap.setRequestAllocation(0x8000_0001);
        try testing.expectEqual(@as(u32, 0x8000_0001), try cap.requestAllocation());

        try cap.setRequestAllocation(0);
        try testing.expectEqual(@as(u32, 0), try cap.requestAllocation());
    }

    test "PRI selected status acknowledgement preserves unselected events" {
        var backend: ConfigBackend = .{};
        const cap = try backend.capability(base);

        store16(&backend, base + pri.offsets.status, 0x8103);

        const observed = try cap.status();
        const reads = backend.reads;

        try cap.ackStatus(observed, .{.response_failure});
        try testing.expectEqual(reads, backend.reads);
        try testing.expectEqual(@as(u32, 1), backend.last_value);

        const after = try cap.status();

        try testing.expect(!after.response_failure);
        try testing.expect(after.unexpected_prg and after.stopped and after.response_pasid_required);

        try cap.ackStatus(observed, .{.unexpected_prg});
        try testing.expectEqual(@as(u16, 0x8100), pri.Status.raw(try cap.status()));
    }

    test "PRI disable starts stopping and explicit reset discards pending requests" {
        var backend: ConfigBackend = .{ .pending = 5 };
        const cap = try backend.capability(base);

        store16(&backend, base + pri.offsets.control, 0xA001);

        try cap.updateControl(.{ .enable = false });
        try testing.expectEqual(@as(u32, 0xA000), backend.last_value);
        try testing.expect(!(try cap.status()).stopped);
        try testing.expectEqual(@as(u32, 5), backend.pending);

        try cap.reset();
        try testing.expectEqual(@as(u32, 0xA002), backend.last_value);
        try testing.expectEqual(@as(u32, 0), backend.pending);
        try testing.expect((try cap.status()).stopped);
        try testing.expectEqual(@as(u16, 0xA000), pri.Control.raw(try cap.control()));
    }

    test "PRI allocation and reset reject prohibited writes" {
        var backend: ConfigBackend = .{};
        const cap = try backend.capability(base);

        store16(&backend, base + pri.offsets.control, 1);
        backend.fail_read_at = base + pri.offsets.request_capacity;

        try testing.expectError(error.InvalidState, cap.setRequestAllocation(1));
        try testing.expectError(error.InvalidState, cap.reset());
        try testing.expectEqual(@as(usize, 2), backend.reads);

        store16(&backend, base + pri.offsets.control, 0);
        backend.fail_read_at = null;
        store32(&backend, base + pri.offsets.request_capacity, 4);

        try testing.expectError(error.InvalidValue, cap.setRequestAllocation(5));
        try testing.expectEqual(@as(usize, 0), backend.writes);

        try cap.setRequestAllocation(4);
        try testing.expectEqual(@as(u32, 4), try cap.requestAllocation());
        try testing.expect(!(try cap.status()).stopped);
    }

    test "PRI read failures prevent writes and propagate" {
        var backend: ConfigBackend = .{ .fail_read_at = base + pri.offsets.control };
        const cap = try backend.capability(base);

        try testing.expectError(error.UnsupportedAccessWidth, cap.control());
        try testing.expectError(error.UnsupportedAccessWidth, cap.updateControl(.{ .enable = true }));
        try testing.expectError(error.UnsupportedAccessWidth, cap.reset());
        try testing.expectError(error.UnsupportedAccessWidth, cap.setRequestAllocation(0));

        backend.fail_read_at = base + pri.offsets.request_capacity;
        try testing.expectError(error.UnsupportedAccessWidth, cap.setRequestAllocation(0));
        try testing.expectError(error.UnsupportedAccessWidth, cap.requestCapacity());

        backend.fail_read_at = base + pri.offsets.request_allocation;
        try testing.expectError(error.UnsupportedAccessWidth, cap.requestAllocation());

        backend.fail_read_at = base + pri.offsets.status;
        try testing.expectError(error.UnsupportedAccessWidth, cap.status());
        try testing.expectEqual(@as(usize, 0), backend.writes);
    }

    test "PRI failed writes propagate without rollback even after mutation" {
        inline for (.{ false, true }) |mutate| {
            var backend: ConfigBackend = .{ .fail_write = true, .mutate_on_failure = mutate, .pending = 7 };
            const cap = try backend.capability(base);
            store32(&backend, base + pri.offsets.request_capacity, 8);

            try testing.expectError(error.UnsupportedAccessWidth, cap.setRequestAllocation(6));
            try testing.expectEqual(@as(u32, if (mutate) 6 else 0), try cap.requestAllocation());

            try testing.expectError(error.UnsupportedAccessWidth, cap.reset());
            try testing.expectEqual(@as(u32, if (mutate) 0 else 7), backend.pending);

            store16(&backend, base + pri.offsets.status, 3);

            try testing.expectError(error.UnsupportedAccessWidth, cap.ackStatus(try cap.status(), .{.response_failure}));
            try testing.expectEqual(@as(u16, if (mutate) 2 else 3), pri.Status.raw(try cap.status()));

            try testing.expectError(error.UnsupportedAccessWidth, cap.updateControl(.{ .enable = true }));
            try testing.expectEqual(mutate, (try cap.control()).enable);
            try testing.expectEqual(@as(usize, 4), backend.writes);
        }
    }

    fn store16(backend: *ConfigBackend, position: usize, value: u16) void {
        std.mem.writeInt(u16, backend.bytes[position..][0..2], value, .little);
    }

    fn store32(backend: *ConfigBackend, position: usize, value: u32) void {
        std.mem.writeInt(u32, backend.bytes[position..][0..4], value, .little);
    }
};
