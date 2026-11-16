const std = @import("std");

const config = @import("config");
const core = @import("core");

const extended = @import("extended.zig");
const ari = core.capabilities.ari;

const Rel16 = core.RelativeOffset(u16);

const Function = config.Function;
const Entry = extended.Entry;
const Registers = extended.Registers;
const Capabilities = ari.Capabilities.Word;
const Control = ari.Control.Word;
const ControlArgs = ari.Control.AssignArgs;

pub const Error = extended.Error;

pub const Capability = struct {
    registers: Registers,

    pub fn tryFrom(function: Function, cap: Entry) Error!Capability {
        std.debug.assert(cap.id == ari.id);

        const registers = try Registers.tryFrom(function, cap.offset);
        if (!registers.contains(offsets.control)) {
            return error.MalformedCapability;
        }

        return .{ .registers = registers };
    }

    pub fn find(function: Function) Error!?Capability {
        const cap = (try extended.find(function, ari.id)) orelse return null;
        return try Capability.tryFrom(function, cap);
    }

    pub fn capabilities(self: Capability) Error!Capabilities {
        return ari.Capabilities.from(try self.registers.read(offsets.capabilities));
    }

    pub fn control(self: Capability) Error!Control {
        return ari.Control.from(try self.registers.read(offsets.control));
    }

    pub fn updateControl(self: Capability, args: ControlArgs) Error!void {
        const observed = try self.control();
        const updated = ari.Control.replace(observed, args);

        return self.registers.write(offsets.control, ari.Control.raw(updated));
    }
};

pub const offsets = struct {
    pub const capabilities = Rel16.from(ari.offsets.capabilities);
    pub const control = Rel16.from(ari.offsets.control);
};

pub const unit = struct {
    const testing = std.testing;
    const support = @import("testing");

    const TestConfigSpace = support.config.TestConfigSpace;
    const Sbdf = core.Sbdf;

    test "ARI discovery reads the live physical-function chain fields" {
        var bytes: [core.config.extended_size]u8 = @splat(0);
        store32(&bytes, 0x100, 0x0001_000E);
        store16(&bytes, 0x104, 0xFE03);

        const sbdf = Sbdf.from(.from(0), 0, 0, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);

        const function = Function.from(backend.config(), sbdf);
        const cap = (try Capability.find(function)).?;
        const caps = try cap.capabilities();

        try testing.expect(caps.mfvc_groups);
        try testing.expect(caps.acs_groups);
        try testing.expectEqual(@as(u8, 254), caps.next_function);

        store16(&bytes, 0x104, 0);
        try testing.expectEqual(@as(u8, 0), (try cap.capabilities()).next_function);
    }

    test "ARI discovery distinguishes absence and malformed capability chains" {
        var bytes: [core.config.extended_size]u8 = @splat(0);
        const sbdf = Sbdf.from(.from(0), 0, 0, 0);

        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);

        try testing.expectEqual(@as(?Capability, null), try Capability.find(function));

        store32(&bytes, 0x100, 0x1021_0001);
        try testing.expectError(error.MalformedCapability, Capability.find(function));

        store32(&bytes, 0x100, 0x1001_0001);
        try testing.expectError(error.MalformedCapability, Capability.find(function));
    }

    test "ARI construction rejects misaligned and truncated extents" {
        var bytes: [core.config.extended_size]u8 = @splat(0);
        const sbdf = Sbdf.from(.from(0), 0, 0, 0);

        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);

        for ([_]u16{ 0xFC, 0x102, 0xFFC }) |base| {
            try testing.expectError(error.MalformedCapability, Capability.tryFrom(function, .{
                .id = ari.id,
                .version = 1,
                .offset = base,
            }));
        }

        _ = try Capability.tryFrom(function, .{ .id = ari.id, .version = 1, .offset = 0xFF8 });
    }

    test "ARI control updates preserve unselected controls and reserved bits" {
        var bytes: [core.config.extended_size]u8 = @splat(0);
        store32(&bytes, 0x100, 0x0001_000E);
        store16(&bytes, 0x106, 0xFFFF);

        const sbdf = Sbdf.from(.from(0), 0, 0, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);

        const function = Function.from(backend.config(), sbdf);
        const cap = (try Capability.find(function)).?;

        try cap.updateControl(.{ .mfvc_groups_enable = false, .function_group = 3 });

        try testing.expectEqual(@as(u16, 0xFFBE), std.mem.readInt(u16, bytes[0x106..0x108], .little));
        const current = try cap.control();
        try testing.expect(!current.mfvc_groups_enable);
        try testing.expect(current.acs_groups_enable);
        try testing.expectEqual(@as(u3, 3), current.function_group);
    }

    fn store16(bytes: []u8, offset: usize, value: u16) void {
        std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
    }

    fn store32(bytes: []u8, offset: usize, value: u32) void {
        std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
    }
};
