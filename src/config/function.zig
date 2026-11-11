//! Configuration-space function view.

const accessor = @import("accessor.zig");
const core = @import("core");

const ConfigSpace = accessor.ConfigSpace;
const ConfigError = ConfigSpace.Error;

const Sbdf = core.Sbdf;
const Offset = core.Offset;
const VendorId = core.VendorId;
const DeviceId = core.DeviceId;
const RevisionId = core.RevisionId;
const ClassCode = core.ClassCode;

const HeaderFormat = core.header.Format;
const Type = core.header.Type;
const Command = core.header.Command;
const Status = core.header.Status;
const Bist = core.header.Bist;
const CommandWord = Command.Word;
const StatusWord = Status.Word;
const BistWord = Bist.Word;

const header = core.header;

pub const Function = struct {
    config: ConfigSpace,
    sbdf: Sbdf,

    pub const Error = ConfigError || error{
        AbsentFunction,
        BadHeaderType,
    };

    pub fn tryFrom(config: ConfigSpace, sbdf: Sbdf) Error!Function {
        const function = from(config, sbdf);
        const vendor = try function.vendorId();

        if (vendor == .absent) {
            return error.AbsentFunction;
        }

        _ = try function.format();
        return function;
    }

    pub fn from(config: ConfigSpace, sbdf: Sbdf) Function {
        return .{
            .config = config,
            .sbdf = sbdf,
        };
    }

    pub fn read(self: Function, offset: anytype) ConfigError!AccessInt(@TypeOf(offset)) {
        return self.config.read(self.sbdf, offset);
    }

    pub fn write(self: Function, offset: anytype, value: AccessInt(@TypeOf(offset))) ConfigError!void {
        return self.config.write(self.sbdf, offset, value);
    }

    pub fn vendorId(self: Function) ConfigError!VendorId {
        return VendorId.from(try self.read(offsets.vendor_id));
    }

    pub fn deviceId(self: Function) ConfigError!DeviceId {
        return DeviceId.from(try self.read(offsets.device_id));
    }

    pub fn revisionId(self: Function) ConfigError!RevisionId {
        return RevisionId.from(try self.read(offsets.revision_id));
    }

    pub fn classCode(self: Function) ConfigError!ClassCode {
        const pif = try self.read(offsets.prog_if);
        const sub = try self.read(offsets.subclass);
        const base = try self.read(offsets.base_class);
        return ClassCode.from(base, sub, pif);
    }

    pub fn command(self: Function) ConfigError!CommandWord {
        return Command.from(try self.read(offsets.command));
    }

    pub fn setCommand(self: Function, value: CommandWord) ConfigError!void {
        return self.write(offsets.command, Command.raw(value));
    }

    pub fn status(self: Function) ConfigError!StatusWord {
        return Status.from(try self.read(offsets.status));
    }

    pub fn clearStatusBits(self: Function, bits: u16) ConfigError!void {
        return self.write(offsets.status, bits);
    }

    pub fn cacheLineSize(self: Function) ConfigError!u8 {
        return self.read(offsets.cache_line_size);
    }

    pub fn setCacheLineSize(self: Function, value: u8) ConfigError!void {
        return self.write(offsets.cache_line_size, value);
    }

    pub fn latencyTimer(self: Function) ConfigError!u8 {
        return self.read(offsets.latency_timer);
    }

    pub fn setLatencyTimer(self: Function, value: u8) ConfigError!void {
        return self.write(offsets.latency_timer, value);
    }

    pub fn typeByte(self: Function) ConfigError!u8 {
        return self.read(offsets.type);
    }

    pub fn format(self: Function) Error!HeaderFormat {
        const word = Type.from(try self.typeByte());
        return switch (word.format) {
            0x00 => .type0,
            0x01 => .type1,
            else => error.BadHeaderType,
        };
    }

    pub fn multifunction(self: Function) ConfigError!bool {
        const word = Type.from(try self.typeByte());
        return word.multifunction;
    }

    pub fn bist(self: Function) ConfigError!BistWord {
        return Bist.from(try self.read(offsets.bist));
    }

    pub fn setBist(self: Function, value: BistWord) ConfigError!void {
        return self.write(offsets.bist, Bist.raw(value));
    }

    pub fn capPtr(self: Function) ConfigError!u8 {
        return self.read(offsets.cap_ptr);
    }

    pub fn intrLine(self: Function) ConfigError!u8 {
        return self.read(offsets.intr_line);
    }

    pub fn setIntrLine(self: Function, value: u8) ConfigError!void {
        return self.write(offsets.intr_line, value);
    }

    pub fn eql(self: Function, other: Function) bool {
        const same_context = self.config.context == other.config.context;
        const same_vtable = self.config.vtable == other.config.vtable;
        const same_sbdf = self.sbdf.eql(other.sbdf);
        return same_context and same_vtable and same_sbdf;
    }

    pub const offsets = struct {
        pub const vendor_id = Offset(u16).from(header.offsets.vendor_id);
        pub const device_id = Offset(u16).from(header.offsets.device_id);
        pub const command = Offset(u16).from(header.offsets.command);
        pub const status = Offset(u16).from(header.offsets.status);
        pub const revision_id = Offset(u8).from(header.offsets.revision_id);
        pub const prog_if = Offset(u8).from(header.offsets.prog_if);
        pub const subclass = Offset(u8).from(header.offsets.subclass);
        pub const base_class = Offset(u8).from(header.offsets.base_class);
        pub const cache_line_size = Offset(u8).from(header.offsets.cache_line_size);
        pub const latency_timer = Offset(u8).from(header.offsets.latency_timer);
        pub const @"type" = Offset(u8).from(header.offsets.type);
        pub const bist = Offset(u8).from(header.offsets.bist);
        pub const cap_ptr = Offset(u8).from(header.offsets.cap_ptr);
        pub const intr_line = Offset(u8).from(header.offsets.intr_line);
        pub const intr_pin = Offset(u8).from(header.offsets.intr_pin);
    };

    fn AccessInt(comptime O: type) type {
        return switch (O) {
            Offset(u8) => u8,
            Offset(u16) => u16,
            Offset(u32) => u32,
            else => @compileError("configuration access requires an absolute Offset"),
        };
    }
};

pub const unit = struct {
    const std = @import("std");

    const testing = std.testing;

    const pcie_window_size = core.config.extended_size;

    const TestConfig = struct {
        entries: []Entry,
        read_count: usize = 0,
        fail_read8: bool = false,

        const Entry = struct {
            sbdf: Sbdf,
            bytes: []u8,
        };

        fn from(entries: []Entry) TestConfig {
            for (entries) |entry| {
                std.debug.assert(entry.bytes.len == pcie_window_size);
            }
            return .{ .entries = entries };
        }

        fn config(self: *TestConfig) ConfigSpace {
            return ConfigSpace.from(@ptrCast(self), &vtable);
        }

        fn functionBytes(self: *TestConfig, sbdf: Sbdf) ?[]u8 {
            for (self.entries) |entry| {
                if (entry.sbdf.eql(sbdf)) {
                    return entry.bytes;
                }
            }

            return null;
        }

        const vtable: ConfigSpace.VTable = .{
            .read8 = read8,
            .read16 = read16,
            .read32 = read32,
            .write8 = write8,
            .write16 = write16,
            .write32 = write32,
        };

        fn read8(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigError!u8 {
            const self: *TestConfig = @ptrCast(@alignCast(context));
            self.read_count += 1;

            if (self.fail_read8) {
                return error.UnsupportedAccessWidth;
            }

            const bytes = self.functionBytes(sbdf) orelse return 0xFF;
            return bytes[byte_offset];
        }

        fn read16(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigError!u16 {
            const self: *TestConfig = @ptrCast(@alignCast(context));
            self.read_count += 1;

            const bytes = self.functionBytes(sbdf) orelse return 0xFFFF;
            return std.mem.readInt(u16, bytes[byte_offset..][0..@sizeOf(u16)], .little);
        }

        fn read32(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigError!u32 {
            const self: *TestConfig = @ptrCast(@alignCast(context));
            self.read_count += 1;

            const bytes = self.functionBytes(sbdf) orelse return 0xFFFF_FFFF;
            return std.mem.readInt(u32, bytes[byte_offset..][0..@sizeOf(u32)], .little);
        }

        fn write8(context: *anyopaque, sbdf: Sbdf, byte_offset: usize, value: u8) ConfigError!void {
            const self: *TestConfig = @ptrCast(@alignCast(context));
            const bytes = self.functionBytes(sbdf) orelse return;
            bytes[byte_offset] = value;
        }

        fn write16(context: *anyopaque, sbdf: Sbdf, byte_offset: usize, value: u16) ConfigError!void {
            const self: *TestConfig = @ptrCast(@alignCast(context));
            const bytes = self.functionBytes(sbdf) orelse return;
            std.mem.writeInt(u16, bytes[byte_offset..][0..@sizeOf(u16)], value, .little);
        }

        fn write32(context: *anyopaque, sbdf: Sbdf, byte_offset: usize, value: u32) ConfigError!void {
            const self: *TestConfig = @ptrCast(@alignCast(context));
            const bytes = self.functionBytes(sbdf) orelse return;
            std.mem.writeInt(u32, bytes[byte_offset..][0..@sizeOf(u32)], value, .little);
        }
    };

    const offset = struct {
        const vendor_id: usize = 0x00;
        const device_id: usize = 0x02;
        const revision_id: usize = 0x08;
        const prog_if: usize = 0x09;
        const subclass: usize = 0x0A;
        const base_class: usize = 0x0B;
        const @"type": usize = 0x0E;
    };

    test "tryFrom accepts present type0 and reads identifiers" {
        var bytes: [pcie_window_size]u8 = undefined;
        seedFunction(&bytes, .{ .header = 0x00 });
        const sbdf = Sbdf.from(.from(0), 0, 1, 0);
        var backend_entries: [1]TestConfig.Entry = undefined;
        var backend = oneEntryConfig(&bytes, sbdf, &backend_entries);

        const function = try Function.tryFrom(backend.config(), sbdf);

        try testing.expectEqual(HeaderFormat.type0, try function.format());
        try testing.expect(!try function.multifunction());
        try testing.expectEqual(@as(u16, 0x1234), @intFromEnum(try function.vendorId()));
        try testing.expectEqual(@as(u16, 0x5678), @intFromEnum(try function.deviceId()));
        try testing.expectEqual(@as(u8, 0x9A), @intFromEnum(try function.revisionId()));
        try testing.expect((try function.classCode()).eql(ClassCode.from(0x01, 0x08, 0x02)));
    }

    test "tryFrom accepts type1 while masking multifunction bit" {
        var bytes: [pcie_window_size]u8 = undefined;
        seedFunction(&bytes, .{ .header = 0x81 });
        const sbdf = Sbdf.from(.from(0), 0, 2, 0);
        var backend_entries: [1]TestConfig.Entry = undefined;
        var backend = oneEntryConfig(&bytes, sbdf, &backend_entries);

        const function = try Function.tryFrom(backend.config(), sbdf);

        try testing.expectEqual(HeaderFormat.type1, try function.format());
        try testing.expect(try function.multifunction());
    }

    test "tryFrom reports AbsentFunction for vendor id FFFF" {
        var bytes: [pcie_window_size]u8 = undefined;
        seedFunction(&bytes, .{ .vendor = 0xFFFF, .header = 0x00 });
        const sbdf = Sbdf.from(.from(0), 0, 3, 0);
        var entries: [1]TestConfig.Entry = undefined;
        var backend = oneEntryConfig(&bytes, sbdf, &entries);

        try testing.expectError(error.AbsentFunction, Function.tryFrom(backend.config(), sbdf));
        try testing.expectEqual(@as(usize, 1), backend.read_count);
    }

    test "tryFrom reports BadHeaderType after masking multifunction bit" {
        var bytes: [pcie_window_size]u8 = undefined;
        seedFunction(&bytes, .{ .header = 0x82 });
        const sbdf = Sbdf.from(.from(0), 0, 4, 0);
        var entries: [1]TestConfig.Entry = undefined;
        var backend = oneEntryConfig(&bytes, sbdf, &entries);

        try testing.expectError(error.BadHeaderType, Function.tryFrom(backend.config(), sbdf));
        try testing.expectEqual(@as(usize, 2), backend.read_count);
    }

    test "from performs no validation I/O and reads live bytes" {
        var bytes: [pcie_window_size]u8 = undefined;
        seedFunction(&bytes, .{ .vendor = 0xFFFF, .header = 0x7F });
        const sbdf = Sbdf.from(.from(0), 0, 5, 0);
        var entries: [1]TestConfig.Entry = undefined;
        var backend = oneEntryConfig(&bytes, sbdf, &entries);

        const function = Function.from(backend.config(), sbdf);

        try testing.expectEqual(@as(usize, 0), backend.read_count);
        try testing.expect((try function.vendorId()) == .absent);
        try testing.expectError(error.BadHeaderType, function.format());
    }

    test "Function eq compares backend identity and SBDF" {
        var bytes_a: [pcie_window_size]u8 = undefined;
        var bytes_b: [pcie_window_size]u8 = undefined;
        seedFunction(&bytes_a, .{});
        seedFunction(&bytes_b, .{});
        const sbdf_a = Sbdf.from(.from(0), 0, 10, 0);
        const sbdf_b = Sbdf.from(.from(0), 0, 11, 0);
        var backend_a_entries: [1]TestConfig.Entry = undefined;
        var backend_a = oneEntryConfig(&bytes_a, sbdf_a, &backend_a_entries);
        var backend_b_entries: [1]TestConfig.Entry = undefined;
        var backend_b = oneEntryConfig(&bytes_b, sbdf_a, &backend_b_entries);
        const config_a = backend_a.config();
        const function = Function.from(config_a, sbdf_a);

        try testing.expect(function.eql(Function.from(config_a, sbdf_a)));
        try testing.expect(!function.eql(Function.from(config_a, sbdf_b)));
        try testing.expect(!function.eql(Function.from(backend_b.config(), sbdf_a)));
    }

    test "scoped reads and writes use the stored Sbdf" {
        var bytes_a: [pcie_window_size]u8 = undefined;
        var bytes_b: [pcie_window_size]u8 = undefined;
        seedFunction(&bytes_a, .{ .vendor = 0x1111 });
        seedFunction(&bytes_b, .{ .vendor = 0x2222 });
        const sbdf_a = Sbdf.from(.from(0), 0, 6, 0);
        const sbdf_b = Sbdf.from(.from(0), 0, 7, 0);
        var entries = [_]TestConfig.Entry{
            .{ .sbdf = sbdf_a, .bytes = &bytes_a },
            .{ .sbdf = sbdf_b, .bytes = &bytes_b },
        };
        var backend = TestConfig.from(&entries);
        const function = Function.from(backend.config(), sbdf_b);
        const device_id = Function.offsets.device_id;

        try function.write(device_id, 0xBEEF);

        try testing.expectEqual(@as(u16, 0x5678), load16(&bytes_a, offset.device_id));
        try testing.expectEqual(@as(u16, 0xBEEF), try function.read(device_id));
    }

    test "identifier reads observe live bytes without absence translation" {
        var bytes: [pcie_window_size]u8 = undefined;
        seedFunction(&bytes, .{ .vendor = 0x1234 });
        const sbdf = Sbdf.from(.from(0), 0, 8, 0);
        var backend_entries: [1]TestConfig.Entry = undefined;
        var backend = oneEntryConfig(&bytes, sbdf, &backend_entries);
        const function = try Function.tryFrom(backend.config(), sbdf);

        store16(&bytes, offset.vendor_id, 0xFFFF);

        try testing.expect((try function.vendorId()) == .absent);
    }

    test "ConfigSpace errors propagate through Function methods" {
        var bytes: [pcie_window_size]u8 = undefined;
        seedFunction(&bytes, .{});
        const sbdf = Sbdf.from(.from(0), 0, 9, 0);
        var entries: [1]TestConfig.Entry = undefined;
        var backend = oneEntryConfig(&bytes, sbdf, &entries);
        const function = Function.from(backend.config(), sbdf);

        backend.fail_read8 = true;

        try testing.expectError(error.UnsupportedAccessWidth, Function.tryFrom(backend.config(), sbdf));
        try testing.expectError(error.UnsupportedAccessWidth, function.format());
    }

    test "Function command and status use separate 16-bit registers" {
        var bytes: [pcie_window_size]u8 = @splat(0xA5);
        const sbdf = Sbdf.from(.from(0), 0, 1, 0);
        var backend_entries: [1]TestConfig.Entry = undefined;
        var backend = oneEntryConfig(&bytes, sbdf, &backend_entries);
        const function = Function.from(backend.config(), sbdf);
        store16(&bytes, 0x04, 0x0005);
        store16(&bytes, 0x06, 0xFFFF);

        const command = try function.command();

        try testing.expect(command.io_enable);
        try testing.expect(!command.mem_enable);
        try testing.expect(command.bus_master);
        try testing.expectEqual(@as(u16, 0xFFFF), @as(u16, @bitCast(try function.status())));

        try function.setCommand(@bitCast(@as(u16, 0x0002)));

        try testing.expectEqual(@as(u16, 0x0002), load16(&bytes, 0x04));
        try testing.expectEqual(@as(u16, 0xFFFF), load16(&bytes, 0x06));

        try function.clearStatusBits(0x8000);

        try testing.expectEqual(@as(u16, 0x8000), load16(&bytes, 0x06));
        try testing.expectEqual(@as(u16, 0x0002), load16(&bytes, 0x04));
        try testing.expectEqual(@as(u8, 0xA5), bytes[0x03]);
        try testing.expectEqual(@as(u8, 0xA5), bytes[0x08]);
    }

    test "Function shared byte registers preserve neighboring bytes" {
        var bytes: [pcie_window_size]u8 = @splat(0xA5);

        const sbdf = Sbdf.from(.from(0), 0, 1, 0);
        var backend_entries: [1]TestConfig.Entry = undefined;
        var backend = oneEntryConfig(&bytes, sbdf, &backend_entries);
        const function = Function.from(backend.config(), sbdf);
        bytes[0x0E] = 0x81;
        bytes[0x34] = 0x43;

        try function.setCacheLineSize(0x10);
        try function.setLatencyTimer(0x20);
        try function.setBist(@bitCast(@as(u8, 0x40)));
        try function.setIntrLine(0x09);

        try testing.expectEqual(@as(u8, 0x10), bytes[0x0C]);
        try testing.expectEqual(@as(u8, 0x20), bytes[0x0D]);
        try testing.expectEqual(@as(u8, 0x81), bytes[0x0E]);
        try testing.expectEqual(@as(u8, 0x40), bytes[0x0F]);
        try testing.expectEqual(@as(u8, 0xA5), bytes[0x10]);
        try testing.expectEqual(@as(u8, 0x09), bytes[0x3C]);
        try testing.expectEqual(@as(u8, 0xA5), bytes[0x3D]);
        try testing.expectEqual(@as(u8, 0x10), try function.cacheLineSize());
        try testing.expectEqual(@as(u8, 0x20), try function.latencyTimer());
        try testing.expectEqual(@as(u8, 0x81), try function.typeByte());
        try testing.expectEqual(@as(u8, 0x40), @as(u8, @bitCast(try function.bist())));
        try testing.expectEqual(@as(u8, 0x43), try function.capPtr());
        try testing.expectEqual(@as(u8, 0x09), try function.intrLine());
    }

    fn seedFunction(bytes: *[pcie_window_size]u8, fields: struct {
        vendor: u16 = 0x1234,
        device: u16 = 0x5678,
        revision: u8 = 0x9A,
        base: u8 = 0x01,
        sub: u8 = 0x08,
        pif: u8 = 0x02,
        header: u8 = 0x00,
    }) void {
        bytes.* = @splat(0);
        store16(bytes, offset.vendor_id, fields.vendor);
        store16(bytes, offset.device_id, fields.device);
        bytes[offset.revision_id] = fields.revision;
        bytes[offset.prog_if] = fields.pif;
        bytes[offset.subclass] = fields.sub;
        bytes[offset.base_class] = fields.base;
        bytes[offset.type] = fields.header;
    }

    fn store16(bytes: *[pcie_window_size]u8, byte_offset: usize, value: u16) void {
        std.mem.writeInt(u16, bytes[byte_offset..][0..@sizeOf(u16)], value, .little);
    }

    fn load16(bytes: *const [pcie_window_size]u8, byte_offset: usize) u16 {
        return std.mem.readInt(u16, bytes[byte_offset..][0..@sizeOf(u16)], .little);
    }

    fn oneEntryConfig(bytes: *[pcie_window_size]u8, sbdf: Sbdf, entry: *[1]TestConfig.Entry) TestConfig {
        entry[0] = .{ .sbdf = sbdf, .bytes = bytes };
        return TestConfig.from(entry);
    }
};
