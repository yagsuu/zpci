//! Tests for docs/specs/config/space.md.

const std = @import("std");

const stdx = @import("stdx");
const zpci = @import("zpci");

const ConfigSpace = zpci.config.ConfigSpace;
const TestConfigSpace = zpci.testing.config.TestConfigSpace;
const Function = zpci.config.Function;
const HeaderKind = zpci.config.HeaderKind;
const Sbdf = zpci.core.Sbdf;

comptime {
    if (@hasDecl(zpci.config, "TestConfigSpace")) {
        @compileError("zpci.config must not expose TestConfigSpace; use zpci.testing.config.TestConfigSpace");
    }
    if (@hasDecl(zpci.config, "FakeConfig")) {
        @compileError("zpci.config must not expose FakeConfig; use zpci.testing.config.TestConfigSpace");
    }
    if (@hasDecl(zpci.testing.config, "FakeConfig")) {
        @compileError("zpci.testing.config must not expose FakeConfig; use TestConfigSpace");
    }
    if (@hasDecl(zpci.testing.config, "FakeConfigSpace")) {
        @compileError("zpci.testing.config must not expose FakeConfigSpace; use TestConfigSpace");
    }
}

const function_window_size: usize = 0x1000;
const offset = struct {
    const vendor_id: usize = 0x00;
    const device_id: usize = 0x02;
    const revision_id: usize = 0x08;
    const prog_if: usize = 0x09;
    const subclass: usize = 0x0A;
    const base_class: usize = 0x0B;
    const header_type: usize = 0x0E;
};

/// Byte-backed `ConfigSpace` backend for Function view tests.
const TestConfig = struct {
    entries: []Entry,
    read_count: usize = 0,
    fail_read8: bool = false,

    const Entry = struct {
        sbdf: Sbdf,
        bytes: []u8,
    };

    fn init(entries: []Entry) TestConfig {
        for (entries) |entry| std.debug.assert(entry.bytes.len == function_window_size);
        return .{ .entries = entries };
    }

    fn configSpace(self: *TestConfig) ConfigSpace {
        return ConfigSpace.init(@ptrCast(self), &vtable);
    }

    fn functionBytes(self: *TestConfig, sbdf: Sbdf) ?[]u8 {
        for (self.entries) |entry| {
            if (entry.sbdf.eql(sbdf)) return entry.bytes;
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

    fn read8(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigSpace.Error!u8 {
        const self: *TestConfig = @ptrCast(@alignCast(context));
        self.read_count += 1;
        if (self.fail_read8) return error.UnsupportedAccessWidth;
        const bytes = self.functionBytes(sbdf) orelse return 0xFF;
        return bytes[byte_offset];
    }

    fn read16(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigSpace.Error!u16 {
        const self: *TestConfig = @ptrCast(@alignCast(context));
        self.read_count += 1;
        const bytes = self.functionBytes(sbdf) orelse return 0xFFFF;
        const wrapped = stdx.bytes.load(stdx.layout.Le(u16), bytes, byte_offset) catch |err| switch (err) {
            error.EndOfStream => return error.OutOfBounds,
        };
        return wrapped.native();
    }

    fn read32(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigSpace.Error!u32 {
        const self: *TestConfig = @ptrCast(@alignCast(context));
        self.read_count += 1;
        const bytes = self.functionBytes(sbdf) orelse return 0xFFFF_FFFF;
        const wrapped = stdx.bytes.load(stdx.layout.Le(u32), bytes, byte_offset) catch |err| switch (err) {
            error.EndOfStream => return error.OutOfBounds,
        };
        return wrapped.native();
    }

    fn write8(context: *anyopaque, sbdf: Sbdf, byte_offset: usize, value: u8) ConfigSpace.Error!void {
        const self: *TestConfig = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return;
        bytes[byte_offset] = value;
    }

    fn write16(context: *anyopaque, sbdf: Sbdf, byte_offset: usize, value: u16) ConfigSpace.Error!void {
        const self: *TestConfig = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return;
        const encoded = stdx.layout.Le(u16).fromNative(value);
        stdx.bytes.store(stdx.layout.Le(u16), bytes, byte_offset, encoded) catch |err| switch (err) {
            error.EndOfStream => return error.OutOfBounds,
        };
    }

    fn write32(context: *anyopaque, sbdf: Sbdf, byte_offset: usize, value: u32) ConfigSpace.Error!void {
        const self: *TestConfig = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return;
        const encoded = stdx.layout.Le(u32).fromNative(value);
        stdx.bytes.store(stdx.layout.Le(u32), bytes, byte_offset, encoded) catch |err| switch (err) {
            error.EndOfStream => return error.OutOfBounds,
        };
    }
};

fn seedFunction(bytes: *[function_window_size]u8, fields: struct {
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
    bytes[offset.header_type] = fields.header;
}

fn store16(bytes: *[function_window_size]u8, byte_offset: usize, value: u16) void {
    const encoded = stdx.layout.Le(u16).fromNative(value);
    stdx.bytes.store(stdx.layout.Le(u16), bytes, byte_offset, encoded) catch |err| switch (err) {
        error.EndOfStream => unreachable,
    };
}

fn load16(bytes: *const [function_window_size]u8, byte_offset: usize) u16 {
    const wrapped = stdx.bytes.load(stdx.layout.Le(u16), bytes, byte_offset) catch |err| switch (err) {
        error.EndOfStream => unreachable,
    };
    return wrapped.native();
}

fn oneEntryConfig(bytes: *[function_window_size]u8, sbdf: Sbdf, entry: *[1]TestConfig.Entry) TestConfig {
    entry[0] = .{ .sbdf = sbdf, .bytes = bytes };
    return TestConfig.init(entry);
}

test "unit: validate accepts present type0 and reads identifiers" {
    var bytes: [function_window_size]u8 = undefined;
    seedFunction(&bytes, .{ .header = 0x00 });
    const sbdf = Sbdf.of(0, 0, 1, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);

    const function = try Function.validate(backend.configSpace(), sbdf);

    try std.testing.expectEqual(HeaderKind.type0, try function.headerKind());
    try std.testing.expect(!try function.isMultifunction());
    try std.testing.expectEqual(@as(u16, 0x1234), (try function.vendorId()).value);
    try std.testing.expectEqual(@as(u16, 0x5678), (try function.deviceId()).value);
    try std.testing.expectEqual(@as(u8, 0x9A), (try function.revisionId()).value);
    try std.testing.expect((try function.classCode()).eql(zpci.core.ClassCode.from(0x01, 0x08, 0x02)));
}

test "unit: validate accepts type1 while masking multifunction bit" {
    var bytes: [function_window_size]u8 = undefined;
    seedFunction(&bytes, .{ .header = 0x81 });
    const sbdf = Sbdf.of(0, 0, 2, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);

    const function = try Function.validate(backend.configSpace(), sbdf);

    try std.testing.expectEqual(HeaderKind.type1, try function.headerKind());
    try std.testing.expect(try function.isMultifunction());
}

test "malformed: validate reports AbsentFunction for vendor id FFFF" {
    var bytes: [function_window_size]u8 = undefined;
    seedFunction(&bytes, .{ .vendor = 0xFFFF, .header = 0x00 });
    const sbdf = Sbdf.of(0, 0, 3, 0);
    var entries: [1]TestConfig.Entry = undefined;
    var backend = oneEntryConfig(&bytes, sbdf, &entries);

    try std.testing.expectError(error.AbsentFunction, Function.validate(backend.configSpace(), sbdf));
    try std.testing.expectEqual(@as(usize, 1), backend.read_count);
}

test "malformed: validate reports BadHeaderType after masking multifunction bit" {
    var bytes: [function_window_size]u8 = undefined;
    seedFunction(&bytes, .{ .header = 0x82 });
    const sbdf = Sbdf.of(0, 0, 4, 0);
    var entries: [1]TestConfig.Entry = undefined;
    var backend = oneEntryConfig(&bytes, sbdf, &entries);

    try std.testing.expectError(error.BadHeaderType, Function.validate(backend.configSpace(), sbdf));
    try std.testing.expectEqual(@as(usize, 2), backend.read_count);
}

test "unit: unchecked constructs without config reads" {
    var bytes: [function_window_size]u8 = undefined;
    seedFunction(&bytes, .{ .vendor = 0xFFFF, .header = 0x7F });
    const sbdf = Sbdf.of(0, 0, 5, 0);
    var entries: [1]TestConfig.Entry = undefined;
    var backend = oneEntryConfig(&bytes, sbdf, &entries);

    const function = Function.unchecked(backend.configSpace(), sbdf);

    try std.testing.expectEqual(@as(usize, 0), backend.read_count);
    try std.testing.expect((try function.vendorId()).isAbsent());
    try std.testing.expectError(error.BadHeaderType, function.headerKind());
}

test "unit: scoped reads and writes use the stored Sbdf" {
    var bytes_a: [function_window_size]u8 = undefined;
    var bytes_b: [function_window_size]u8 = undefined;
    seedFunction(&bytes_a, .{ .vendor = 0x1111 });
    seedFunction(&bytes_b, .{ .vendor = 0x2222 });
    const sbdf_a = Sbdf.of(0, 0, 6, 0);
    const sbdf_b = Sbdf.of(0, 0, 7, 0);
    var entries = [_]TestConfigSpace.Entry{
        .{ .sbdf = sbdf_a, .bytes = &bytes_a },
        .{ .sbdf = sbdf_b, .bytes = &bytes_b },
    };
    var backend = TestConfigSpace.init(&entries);
    const function = Function.unchecked(backend.configSpace(), sbdf_b);

    try function.write16(offset.device_id, 0xBEEF);

    try std.testing.expectEqual(@as(u16, 0x5678), load16(&bytes_a, offset.device_id));
    try std.testing.expectEqual(@as(u16, 0xBEEF), try function.read16(offset.device_id));
}

test "unit: identifier reads observe live bytes without absence translation" {
    var bytes: [function_window_size]u8 = undefined;
    seedFunction(&bytes, .{ .vendor = 0x1234 });
    const sbdf = Sbdf.of(0, 0, 8, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const function = try Function.validate(backend.configSpace(), sbdf);

    store16(&bytes, offset.vendor_id, 0xFFFF);

    try std.testing.expect((try function.vendorId()).isAbsent());
}

test "malformed: ConfigSpace errors propagate through Function methods" {
    var bytes: [function_window_size]u8 = undefined;
    seedFunction(&bytes, .{});
    const sbdf = Sbdf.of(0, 0, 9, 0);
    var entries: [1]TestConfig.Entry = undefined;
    var backend = oneEntryConfig(&bytes, sbdf, &entries);
    const function = Function.unchecked(backend.configSpace(), sbdf);

    try std.testing.expectError(error.UnalignedAccess, function.read16(1));
    try std.testing.expectError(error.OutOfBounds, function.write32(function_window_size, 0));

    backend.fail_read8 = true;
    try std.testing.expectError(error.UnsupportedAccessWidth, Function.validate(backend.configSpace(), sbdf));
    try std.testing.expectError(error.UnsupportedAccessWidth, function.headerKind());
}
