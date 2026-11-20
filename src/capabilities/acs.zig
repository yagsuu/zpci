const std = @import("std");

const config = @import("config");
const core = @import("core");

const extended = @import("extended.zig");

const acs = core.capabilities.acs;

const Rel16 = core.RelativeOffset(u16);
const Rel32 = core.RelativeOffset(u32);

const Function = config.Function;
const Entry = extended.Entry;
const Registers = extended.Registers;

const Capabilities = acs.Capabilities.Word;
const Control = acs.Control.Word;
const ControlArgs = acs.Control.AssignArgs;

pub const Error = extended.Error;

pub const Capability = struct {
    registers: Registers,

    pub fn tryFrom(function: Function, entry: Entry) Error!Capability {
        std.debug.assert(entry.id == acs.id);

        const registers = try Registers.tryFrom(function, entry.offset);
        if (!registers.contains(offsets.control)) {
            return error.MalformedCapability;
        }

        return .{ .registers = registers };
    }

    pub fn find(function: Function) Error!?Capability {
        const entry = (try extended.find(function, acs.id)) orelse return null;
        return try Capability.tryFrom(function, entry);
    }

    pub fn capabilities(self: Capability) Error!Capabilities {
        return acs.Capabilities.from(try self.registers.read(offsets.capabilities));
    }

    pub fn control(self: Capability) Error!Control {
        return acs.Control.from(try self.registers.read(offsets.control));
    }

    pub fn updateControl(self: Capability, args: ControlArgs) Error!void {
        const observed = try self.control();
        const updated = acs.Control.replace(observed, args);

        return self.registers.write(offsets.control, acs.Control.raw(updated));
    }

    pub fn egress(self: Capability) Error!?Egress {
        const caps = try self.capabilities();
        if (!caps.p2p_egress_control) {
            return null;
        }

        var num_bits: u9 = caps.egress_size;
        if (num_bits == 0) {
            num_bits = 256;
        }

        const last = Rel32.from(acs.offsets.egress + (@as(u16, num_bits) - 1) / 32 * 4);
        if (!self.registers.contains(last)) {
            return error.MalformedCapability;
        }

        return .{ .registers = self.registers, .num_bits = num_bits };
    }
};

pub const Egress = struct {
    registers: Registers,
    num_bits: u9,

    pub fn len(self: Egress) u9 {
        return self.num_bits;
    }

    pub fn read(self: Egress, index: u8) Error!bool {
        const position = try self.offset(index);
        const observed = try self.registers.read(position);
        const bit = @as(u32, 1) << @as(u5, @truncate(index));

        return observed & bit != 0;
    }

    pub fn set(self: Egress, index: u8, value: bool) Error!void {
        const position = try self.offset(index);
        const observed = try self.registers.read(position);
        const bit = @as(u32, 1) << @as(u5, @truncate(index));

        const updated = if (value)
            observed | bit
        else
            observed & ~bit;

        return self.registers.write(position, updated);
    }

    pub fn fill(self: Egress, value: bool) Error!void {
        const full_words = self.num_bits / 32;
        const word: u32 = if (value) 0xFFFF_FFFF else 0;

        var index: u16 = 0;
        while (index < full_words) : (index += 1) {
            const position = Rel32.from(acs.offsets.egress + index * 4);
            try self.registers.write(position, word);
        }

        const remaining: u5 = @truncate(self.num_bits);
        if (remaining == 0) {
            return;
        }

        const position = Rel32.from(acs.offsets.egress + index * 4);
        const observed = try self.registers.read(position);
        const mask = (@as(u32, 1) << remaining) - 1;

        const updated = if (value)
            observed | mask
        else
            observed & ~mask;

        return self.registers.write(position, updated);
    }

    fn offset(self: Egress, index: u8) Error!Rel32 {
        if (index >= self.num_bits) {
            return error.OutOfBounds;
        }

        return .from(acs.offsets.egress + @as(u16, index) / 32 * 4);
    }
};

pub const offsets = struct {
    pub const capabilities = Rel16.from(acs.offsets.capabilities);
    pub const control = Rel16.from(acs.offsets.control);
    pub const egress = Rel32.from(acs.offsets.egress);
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
        read16s: usize = 0,
        read32s: usize = 0,
        write16s: usize = 0,
        write32s: usize = 0,
        last_offset: usize = 0,
        fail_read: bool = false,
        fail_write: bool = false,
        fail_write_at: ?usize = null,
        write_offsets: [16]usize = undefined,
        write_count: usize = 0,
        hardwired_zero: u32 = 0,

        const vtable: ConfigSpace.VTable = .{
            .read8 = read8,
            .read16 = read16,
            .read32 = read32,
            .write8 = write8,
            .write16 = write16,
            .write32 = write32,
        };

        fn config(self: *ConfigBackend) ConfigSpace {
            return ConfigSpace.from(@ptrCast(self), &vtable);
        }

        fn capability(self: *ConfigBackend, position: u16) Error!Capability {
            return Capability.tryFrom(Function.from(self.config(), address), .{
                .id = acs.id,
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

        fn read16(context: *anyopaque, sbdf: Sbdf, position: usize) ConfigError!u16 {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            std.debug.assert(address.eql(sbdf));
            self.read16s += 1;

            if (self.fail_read) {
                return error.UnsupportedAccessWidth;
            }

            return std.mem.readInt(u16, self.bytes[position..][0..2], .little);
        }

        fn read32(context: *anyopaque, sbdf: Sbdf, position: usize) ConfigError!u32 {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            std.debug.assert(address.eql(sbdf));
            self.read32s += 1;

            if (self.fail_read) {
                return error.UnsupportedAccessWidth;
            }

            return std.mem.readInt(u32, self.bytes[position..][0..4], .little);
        }

        fn write16(context: *anyopaque, sbdf: Sbdf, position: usize, value: u16) ConfigError!void {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            std.debug.assert(address.eql(sbdf));
            self.write16s += 1;

            if (self.fail_write) {
                return error.UnsupportedAccessWidth;
            }

            self.last_offset = position;
            store16(&self.bytes, position, value);
            self.write_offsets[self.write_count] = position;
            self.write_count += 1;
        }

        fn write32(context: *anyopaque, sbdf: Sbdf, position: usize, value: u32) ConfigError!void {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            std.debug.assert(address.eql(sbdf));
            self.write32s += 1;

            if (self.fail_write or self.fail_write_at == position) {
                return error.UnsupportedAccessWidth;
            }

            self.last_offset = position;
            store32(&self.bytes, position, value & ~self.hardwired_zero);
            self.write_offsets[self.write_count] = position;
            self.write_count += 1;
        }
    };

    test "ACS discovery rebases live capability and control accesses" {
        var backend: ConfigBackend = .{};
        const function = Function.from(backend.config(), address);

        try testing.expectEqual(@as(?Capability, null), try Capability.find(function));

        store32(&backend.bytes, 0x100, 0x1801_000E);
        store32(&backend.bytes, 0x180, 0x0001_000D);
        store16(&backend.bytes, 0x184, 0x21A1);
        store16(&backend.bytes, 0x186, 0xE000);

        const cap = (try Capability.find(function)).?;
        const caps = try cap.capabilities();

        try testing.expect(caps.source_validation);
        try testing.expect(caps.enhanced);
        try testing.expectEqual(@as(u8, 33), caps.egress_size);

        try cap.updateControl(.{
            .source_validation_enable = true,
            .dsp_mem_access = .redirect,
            .usp_mem_access = .block,
        });

        try testing.expectEqual(@as(u16, 0xE601), std.mem.readInt(u16, backend.bytes[0x186..0x188], .little));
        try testing.expectEqual(@as(usize, 0x186), backend.last_offset);
        try testing.expectEqual(@as(usize, 1), backend.write16s);

        store16(&backend.bytes, 0x184, 0x0140);
        try testing.expectEqual(@as(u8, 1), (try cap.capabilities()).egress_size);

        store16(&backend.bytes, 0x186, 0x1000);
        try testing.expect((try cap.control()).unclaimed_request_redirect_enable);
    }

    test "ACS binding checks fixed registers before IO" {
        var backend: ConfigBackend = .{ .fail_read = true };

        for ([_]u16{ 0xFC, 0x102, 0xFFC }) |position| {
            try testing.expectError(error.MalformedCapability, backend.capability(position));
        }

        const cap = try backend.capability(0xFF8);
        try testing.expectError(error.UnsupportedAccessWidth, cap.control());
        try testing.expectEqual(@as(usize, 1), backend.read16s);
        try testing.expectEqual(@as(usize, 0), backend.read32s);
    }

    test "ACS egress binds advertised length and preserves adjacent and unused bits" {
        for ([_]u9{ 1, 31, 32, 33, 256 }) |size| {
            var backend: ConfigBackend = .{};
            const cap = try backend.capability(base);
            const encoded: u8 = @truncate(size);
            store16(&backend.bytes, 0x104, @as(u16, encoded) << 8 | 0x20);

            const egress = (try cap.egress()).?;
            try testing.expectEqual(size, egress.len());

            const index: u8 = @intCast(size - 1);
            const position = 0x108 + @as(usize, index) / 32 * 4;
            const bit = @as(u32, 1) << @as(u5, @truncate(index));
            const initial: u32 = 0xA5A5_A5A5;
            store32(&backend.bytes, position, initial);

            try egress.set(index, true);
            try testing.expectEqual(initial | bit, std.mem.readInt(u32, backend.bytes[position..][0..4], .little));
            try testing.expectEqual(position, backend.last_offset);
            try testing.expect(try egress.read(index));

            try egress.set(index, false);
            try testing.expectEqual(initial & ~bit, std.mem.readInt(u32, backend.bytes[position..][0..4], .little));
            try testing.expect(!try egress.read(index));
            try testing.expectEqual(@as(usize, 1), backend.read16s);
            try testing.expectEqual(@as(usize, 4), backend.read32s);
            try testing.expectEqual(@as(usize, 2), backend.write32s);

            if (size < 256) {
                try testing.expectError(error.OutOfBounds, egress.read(@intCast(size)));
                try testing.expectError(error.OutOfBounds, egress.set(@intCast(size), true));
                try testing.expectEqual(@as(usize, 4), backend.read32s);
                try testing.expectEqual(@as(usize, 2), backend.write32s);
            }
        }
    }

    test "ACS egress checks support and the whole dword extent before vector access" {
        var backend: ConfigBackend = .{};
        const cap = try backend.capability(0xFF4);

        store16(&backend.bytes, 0xFF8, 0xFF00);
        try testing.expectEqual(@as(?Egress, null), try cap.egress());

        store16(&backend.bytes, 0xFF8, 0x0120);
        const egress = (try cap.egress()).?;
        try testing.expectEqual(@as(u9, 1), egress.len());

        store32(&backend.bytes, 0xFFC, 1);
        try testing.expect(try egress.read(0));
        try testing.expectEqual(@as(usize, 1), backend.read32s);

        store16(&backend.bytes, 0xFF8, 0x2120);
        try testing.expectError(error.MalformedCapability, cap.egress());
        try testing.expectEqual(@as(usize, 1), backend.read32s);
        try testing.expectEqual(@as(usize, 0), backend.write32s);
    }

    test "ACS egress writes do not require hardwired zero bits to read back set" {
        var backend: ConfigBackend = .{ .hardwired_zero = 1 };
        const cap = try backend.capability(base);
        store16(&backend.bytes, 0x104, 0x0120);

        const egress = (try cap.egress()).?;

        try egress.set(0, true);
        try testing.expectEqual(@as(usize, 1), backend.read32s);
        try testing.expectEqual(@as(usize, 1), backend.write32s);
        try testing.expect(!try egress.read(0));
    }

    test "ACS access failures propagate without writes after read failure or retries" {
        var backend: ConfigBackend = .{ .fail_read = true };
        const cap = try backend.capability(base);

        try testing.expectError(error.UnsupportedAccessWidth, cap.egress());
        try testing.expectError(error.UnsupportedAccessWidth, cap.updateControl(.{ .source_validation_enable = true }));
        try testing.expectEqual(@as(usize, 0), backend.write16s);

        backend.fail_read = false;
        store16(&backend.bytes, 0x104, 0x0120);
        const egress = (try cap.egress()).?;

        backend.fail_read = true;
        try testing.expectError(error.UnsupportedAccessWidth, egress.set(0, true));
        try testing.expectEqual(@as(usize, 0), backend.write32s);

        backend.fail_read = false;
        backend.fail_write = true;

        try testing.expectError(error.UnsupportedAccessWidth, egress.set(0, true));
        try testing.expectEqual(@as(usize, 2), backend.read32s);
        try testing.expectEqual(@as(usize, 1), backend.write32s);

        try testing.expectError(error.UnsupportedAccessWidth, cap.updateControl(.{ .source_validation_enable = true }));
        try testing.expectEqual(@as(usize, 4), backend.read16s);
        try testing.expectEqual(@as(usize, 1), backend.write16s);
    }

    test "ACS fill covers applicable bits with no reads of complete dwords" {
        for ([_]struct { size: u9, words: usize, reads: usize, set: u32, cleared: u32 }{
            .{ .size = 1, .words = 1, .reads = 1, .set = 0xA5A5_A5A5, .cleared = 0xA5A5_A5A4 },
            .{ .size = 31, .words = 1, .reads = 1, .set = 0xFFFF_FFFF, .cleared = 0x8000_0000 },
            .{ .size = 32, .words = 1, .reads = 0, .set = 0xFFFF_FFFF, .cleared = 0 },
            .{ .size = 33, .words = 2, .reads = 1, .set = 0xA5A5_A5A5, .cleared = 0xA5A5_A5A4 },
            .{ .size = 256, .words = 8, .reads = 0, .set = 0xFFFF_FFFF, .cleared = 0 },
        }) |case| {
            for ([_]bool{ false, true }) |value| {
                var backend: ConfigBackend = .{};
                const cap = try backend.capability(base);
                const encoded: u8 = @truncate(case.size);
                store16(&backend.bytes, 0x104, @as(u16, encoded) << 8 | 0x20);
                store16(&backend.bytes, 0x106, 0xE000);

                for (0..case.words) |i| {
                    store32(&backend.bytes, 0x108 + i * 4, 0xA5A5_A5A4);
                }

                const end = 0x108 + case.words * 4;
                store32(&backend.bytes, end, 0x1234_5678);

                const egress = (try cap.egress()).?;
                backend.fail_read = case.reads == 0;

                try egress.fill(value);
                try testing.expectEqual(case.reads, backend.read32s);
                try testing.expectEqual(case.words, backend.write32s);

                for (0..case.words) |i| {
                    const position = 0x108 + i * 4;
                    const expected = if (i == case.words - 1)
                        (if (value) case.set else case.cleared)
                    else
                        (if (value) @as(u32, 0xFFFF_FFFF) else 0);

                    try testing.expectEqual(expected, std.mem.readInt(u32, backend.bytes[position..][0..4], .little));
                    try testing.expectEqual(position, backend.write_offsets[i]);
                }

                try testing.expectEqual(@as(u32, 0x1234_5678), std.mem.readInt(u32, backend.bytes[end..][0..4], .little));
                try testing.expectEqual(@as(u16, 0xE000), std.mem.readInt(u16, backend.bytes[0x106..0x108], .little));
                try testing.expectEqual(@as(usize, 0), backend.write16s);
            }
        }
    }

    test "ACS fill stops at a failed dword without rollback or later writes" {
        var backend: ConfigBackend = .{ .fail_write_at = 0x10C };
        const cap = try backend.capability(base);
        store16(&backend.bytes, 0x104, 0x6020);
        store32(&backend.bytes, 0x108, 0x1111_1111);
        store32(&backend.bytes, 0x10C, 0x2222_2222);
        store32(&backend.bytes, 0x110, 0x3333_3333);

        const egress = (try cap.egress()).?;

        try testing.expectError(error.UnsupportedAccessWidth, egress.fill(true));
        try testing.expectEqual(@as(u32, 0xFFFF_FFFF), std.mem.readInt(u32, backend.bytes[0x108..0x10C], .little));
        try testing.expectEqual(@as(u32, 0x2222_2222), std.mem.readInt(u32, backend.bytes[0x10C..0x110], .little));
        try testing.expectEqual(@as(u32, 0x3333_3333), std.mem.readInt(u32, backend.bytes[0x110..0x114], .little));
        try testing.expectEqual(@as(usize, 0), backend.read32s);
        try testing.expectEqual(@as(usize, 2), backend.write32s);
        try testing.expectEqualSlices(usize, &.{0x108}, backend.write_offsets[0..backend.write_count]);
    }

    test "ACS fill preserves the final partial word when its read fails" {
        var backend: ConfigBackend = .{};
        const cap = try backend.capability(base);
        store16(&backend.bytes, 0x104, 0x4120);
        store32(&backend.bytes, 0x108, 0x1111_1111);
        store32(&backend.bytes, 0x10C, 0x2222_2222);
        store32(&backend.bytes, 0x110, 0x3333_3333);

        const egress = (try cap.egress()).?;
        backend.fail_read = true;

        try testing.expectError(error.UnsupportedAccessWidth, egress.fill(false));
        try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, backend.bytes[0x108..0x10C], .little));
        try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, backend.bytes[0x10C..0x110], .little));
        try testing.expectEqual(@as(u32, 0x3333_3333), std.mem.readInt(u32, backend.bytes[0x110..0x114], .little));
        try testing.expectEqual(@as(usize, 1), backend.read32s);
        try testing.expectEqual(@as(usize, 2), backend.write32s);
    }

    test "firmware fills and selects peer routes before enabling egress control" {
        var backend: ConfigBackend = .{};
        const cap = try backend.capability(base);
        store16(&backend.bytes, 0x104, 0x2120);
        store16(&backend.bytes, 0x106, 0xE000);
        store32(&backend.bytes, 0x10C, 0xA5A5_A5A4);

        const egress = (try cap.egress()).?;

        try egress.fill(true);
        try egress.set(7, false);
        try cap.updateControl(.{ .p2p_egress_control_enable = true });

        try testing.expectEqualSlices(usize, &.{ 0x108, 0x10C, 0x108, 0x106 }, backend.write_offsets[0..backend.write_count]);
        try testing.expectEqual(@as(u32, 0xFFFF_FF7F), std.mem.readInt(u32, backend.bytes[0x108..0x10C], .little));
        try testing.expectEqual(@as(u32, 0xA5A5_A5A5), std.mem.readInt(u32, backend.bytes[0x10C..0x110], .little));
        try testing.expectEqual(@as(u16, 0xE020), std.mem.readInt(u16, backend.bytes[0x106..0x108], .little));
    }

    fn store16(bytes: []u8, position: usize, value: u16) void {
        std.mem.writeInt(u16, bytes[position..][0..2], value, .little);
    }

    fn store32(bytes: []u8, position: usize, value: u32) void {
        std.mem.writeInt(u32, bytes[position..][0..4], value, .little);
    }
};
