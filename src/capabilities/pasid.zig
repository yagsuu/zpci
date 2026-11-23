const std = @import("std");

const config = @import("config");
const core = @import("core");

const extended = @import("extended.zig");

const pasid = core.capabilities.pasid;

const Rel16 = core.RelativeOffset(u16);

const Function = config.Function;
const Entry = extended.Entry;
const Registers = extended.Registers;

const Capabilities = pasid.Capabilities.Word;
const Control = pasid.Control.Word;
const ControlArgs = pasid.Control.AssignArgs;

pub const Error = extended.Error;

pub const Capability = struct {
    registers: Registers,

    pub fn tryFrom(function: Function, entry: Entry) Error!Capability {
        std.debug.assert(entry.id == pasid.id);

        const registers = try Registers.tryFrom(function, entry.offset);
        if (!registers.contains(offsets.control)) {
            return error.MalformedCapability;
        }

        return .{ .registers = registers };
    }

    pub fn find(function: Function) Error!?Capability {
        const entry = (try extended.find(function, pasid.id)) orelse return null;
        return try Capability.tryFrom(function, entry);
    }

    pub fn capabilities(self: Capability) Error!Capabilities {
        return pasid.Capabilities.from(try self.registers.read(offsets.capabilities));
    }

    pub fn control(self: Capability) Error!Control {
        return pasid.Control.from(try self.registers.read(offsets.control));
    }

    pub fn updateControl(self: Capability, args: ControlArgs) Error!void {
        const observed = try self.control();
        const updated = pasid.Control.replace(observed, args);

        return self.registers.write(offsets.control, pasid.Control.raw(updated));
    }
};

pub const offsets = struct {
    pub const capabilities = Rel16.from(pasid.offsets.capabilities);
    pub const control = Rel16.from(pasid.offsets.control);
};

pub const unit = struct {
    const testing = std.testing;
    const support = @import("testing");

    const ConfigSpace = config.ConfigSpace;
    const ConfigError = ConfigSpace.Error;
    const Sbdf = core.Sbdf;
    const TestConfigSpace = support.config.TestConfigSpace;

    const address = Sbdf.from(.from(0), 2, 3, 0);

    test "PASID discovery binds live registers without version gating" {
        var bytes: [core.config.extended_size]u8 = @splat(0);
        var backend = TestConfigSpace.fromSingle(address, &bytes);
        const function = Function.from(backend.config(), address);

        try testing.expectEqual(@as(?Capability, null), try Capability.find(function));

        store(u32, &bytes, 0x100, 0x1801_000E);
        store(u32, &bytes, 0x180, 0x000F_001B);
        store(u16, &bytes, 0x184, 0x140E);
        store(u16, &bytes, 0x186, 0xA5A6);

        const cap = (try Capability.find(function)).?;
        try testing.expectEqual(@as(u16, 0x140E), pasid.Capabilities.raw(try cap.capabilities()));

        try cap.updateControl(.{ .enable = true });
        try testing.expectEqual(@as(u16, 0xA5A7), pasid.Control.raw(try cap.control()));

        store(u16, &bytes, 0x184, 0);
        try testing.expectEqual(@as(u16, 0), pasid.Capabilities.raw(try cap.capabilities()));

        store(u16, &bytes, 0x186, 0x5A59);
        try cap.updateControl(.{ .enable = false });
        try testing.expectEqual(@as(u16, 0x5A58), pasid.Control.raw(try cap.control()));
    }

    test "PASID binding requires the complete eight byte extent" {
        var bytes: [core.config.extended_size]u8 = @splat(0);
        var backend = TestConfigSpace.fromSingle(address, &bytes);
        const function = Function.from(backend.config(), address);

        for ([_]u16{ 0xFC, 0x102, 0xFFC }) |position| {
            try testing.expectError(error.MalformedCapability, Capability.tryFrom(function, .{
                .id = pasid.id,
                .version = 0,
                .offset = position,
            }));
        }

        const cap = try Capability.tryFrom(function, .{ .id = pasid.id, .version = 15, .offset = 0xFF8 });
        try cap.updateControl(.{ .enable = true });
        try testing.expect((try cap.control()).enable);
    }

    test "PASID operations propagate backend failures without changing control" {
        var bytes: [core.config.extended_size]u8 = @splat(0);
        var backend = TestConfigSpace.fromSingle(address, &bytes);
        const space = backend.config();
        var vtable = space.vtable.*;
        const function = Function.from(ConfigSpace.from(space.context, &vtable), address);
        const cap = try Capability.tryFrom(function, .{ .id = pasid.id, .version = 1, .offset = 0x100 });

        vtable.read16 = failRead;
        try testing.expectError(error.UnsupportedAccessWidth, cap.capabilities());
        try testing.expectError(error.UnsupportedAccessWidth, cap.control());
        try testing.expectError(error.UnsupportedAccessWidth, cap.updateControl(.{ .enable = true }));

        vtable.read16 = space.vtable.read16;
        vtable.write16 = failWrite;
        try testing.expectError(error.UnsupportedAccessWidth, cap.updateControl(.{ .enable = true }));
        try testing.expectEqual(@as(u16, 0), pasid.Control.raw(try cap.control()));
    }

    fn failRead(_: *anyopaque, _: Sbdf, _: usize) ConfigError!u16 {
        return error.UnsupportedAccessWidth;
    }

    fn failWrite(_: *anyopaque, _: Sbdf, _: usize, _: u16) ConfigError!void {
        return error.UnsupportedAccessWidth;
    }

    fn store(comptime T: type, bytes: []u8, position: usize, value: T) void {
        std.mem.writeInt(T, bytes[position..][0..@sizeOf(T)], value, .little);
    }
};
