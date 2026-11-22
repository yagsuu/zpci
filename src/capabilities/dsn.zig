const std = @import("std");

const config = @import("config");
const core = @import("core");

const extended = @import("extended.zig");
const dsn = core.capabilities.dsn;

const Rel32 = core.RelativeOffset(u32);

const Function = config.Function;
const Entry = extended.Entry;
const Registers = extended.Registers;

pub const Error = extended.Error;

pub const Capability = struct {
    registers: Registers,

    pub fn tryFrom(function: Function, cap: Entry) Error!Capability {
        std.debug.assert(cap.id == dsn.id);

        const registers = try Registers.tryFrom(function, cap.offset);
        if (!registers.contains(offsets.serial_hi)) {
            return error.MalformedCapability;
        }

        return .{ .registers = registers };
    }

    pub fn find(function: Function) Error!?Capability {
        const cap = (try extended.find(function, dsn.id)) orelse return null;
        return try Capability.tryFrom(function, cap);
    }

    pub fn serial(self: Capability) Error!u64 {
        const lo = try self.registers.read(offsets.serial_lo);
        const hi = try self.registers.read(offsets.serial_hi);

        return @as(u64, lo) | (@as(u64, hi) << 32);
    }
};

pub const offsets = struct {
    pub const serial_lo = Rel32.from(dsn.offsets.serial_lo);
    pub const serial_hi = Rel32.from(dsn.offsets.serial_hi);
};

pub const unit = struct {
    const testing = std.testing;
    const support = @import("testing");

    const ConfigSpace = config.ConfigSpace;
    const ConfigError = ConfigSpace.Error;
    const Sbdf = core.Sbdf;
    const TestConfigSpace = support.config.TestConfigSpace;

    test "DSN discovery reconstructs both serial words without filtering values" {
        var bytes: [core.config.extended_size]u8 = @splat(0);
        store32(&bytes, 0x100, 0x1801_0001);
        store32(&bytes, 0x180, 0x0001_0003);
        store32(&bytes, 0x184, 0x89AB_CDEF);
        store32(&bytes, 0x188, 0x0123_4567);

        const sbdf = Sbdf.from(.from(0), 0, 0, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);
        const cap = (try Capability.find(function)).?;

        try testing.expectEqual(@as(u64, 0x0123_4567_89AB_CDEF), try cap.serial());

        store32(&bytes, 0x184, 0);
        store32(&bytes, 0x188, 0);
        try testing.expectEqual(@as(u64, 0), try cap.serial());

        store32(&bytes, 0x184, 0xFFFF_FFFF);
        store32(&bytes, 0x188, 0xFFFF_FFFF);
        try testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFF), try cap.serial());
    }

    test "DSN construction checks the complete serial register extent" {
        var bytes: [core.config.extended_size]u8 = @splat(0);
        store32(&bytes, 0xFF8, 0x7654_3210);
        store32(&bytes, 0xFFC, 0xFEDC_BA98);

        const sbdf = Sbdf.from(.from(0), 0, 0, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);
        const cap = try Capability.tryFrom(function, .{ .id = .dsn, .version = 1, .offset = 0xFF4 });

        try testing.expectEqual(@as(u64, 0xFEDC_BA98_7654_3210), try cap.serial());

        for ([_]u16{ 0xFF8, 0xFFC }) |base| {
            try testing.expectError(error.MalformedCapability, Capability.tryFrom(function, .{
                .id = .dsn,
                .version = 1,
                .offset = base,
            }));
        }
    }

    test "DSN serial propagates failures from either DWORD read" {
        var bytes: [core.config.extended_size]u8 = @splat(0);
        const sbdf = Sbdf.from(.from(0), 0, 0, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);

        inline for (.{ failRead, failHighRead }) |read32| {
            var space = backend.config();
            var vtable = space.vtable.*;
            vtable.read32 = read32;
            space.vtable = &vtable;

            const function = Function.from(space, sbdf);
            const cap = try Capability.tryFrom(function, .{ .id = .dsn, .version = 1, .offset = 0x100 });

            try testing.expectError(error.UnsupportedAccessWidth, cap.serial());
        }
    }

    fn failRead(_: *anyopaque, _: Sbdf, _: usize) ConfigError!u32 {
        return error.UnsupportedAccessWidth;
    }

    fn failHighRead(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigError!u32 {
        if (offset == 0x108) {
            return error.UnsupportedAccessWidth;
        }

        const backend: *TestConfigSpace = @ptrCast(@alignCast(context));
        return backend.config().read(sbdf, core.Offset(u32).from(offset));
    }

    fn store32(bytes: []u8, offset: usize, value: u32) void {
        std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
    }
};
