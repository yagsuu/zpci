//! Tests for docs/specs/capabilities/extended.md.

const std = @import("std");

const stdx = @import("stdx");
const zpci = @import("zpci");

const ConfigSpace = zpci.config.ConfigSpace;
const Cursor = zpci.capabilities.extended.Cursor;
const ExtCapability = zpci.capabilities.extended.ExtCapability;
const Function = zpci.config.Function;
const Id = zpci.capabilities.extended.Id;
const Iterator = zpci.capabilities.extended.Iterator;
const Sbdf = zpci.core.Sbdf;
const TestConfigSpace = zpci.testing.config.TestConfigSpace;

const ext = zpci.capabilities.extended.ext;
const function_window_size: usize = 0x1000;

const find = zpci.capabilities.extended.find;

const NoDwordConfig = struct {
    bytes: [function_window_size]u8 = @splat(0),

    fn configSpace(self: *NoDwordConfig) ConfigSpace {
        return ConfigSpace.init(@ptrCast(self), &vtable);
    }

    const vtable: ConfigSpace.VTable = .{
        .read8 = read8,
        .read16 = read16,
        .read32 = read32Unsupported,
        .write8 = write8,
        .write16 = write16,
        .write32 = write32Unsupported,
    };

    fn read8(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigSpace.Error!u8 {
        _ = sbdf;
        const self: *NoDwordConfig = @ptrCast(@alignCast(context));
        return self.bytes[byte_offset];
    }

    fn read16(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigSpace.Error!u16 {
        _ = sbdf;
        const self: *NoDwordConfig = @ptrCast(@alignCast(context));
        const wrapped = stdx.bytes.load(stdx.layout.Le(u16), &self.bytes, byte_offset) catch |err| switch (err) {
            error.EndOfStream => return error.OutOfBounds,
        };
        return wrapped.native();
    }

    fn read32Unsupported(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigSpace.Error!u32 {
        _ = context;
        _ = sbdf;
        _ = byte_offset;
        return error.UnsupportedAccessWidth;
    }

    fn write8(context: *anyopaque, sbdf: Sbdf, byte_offset: usize, value: u8) ConfigSpace.Error!void {
        _ = sbdf;
        const self: *NoDwordConfig = @ptrCast(@alignCast(context));
        self.bytes[byte_offset] = value;
    }

    fn write16(context: *anyopaque, sbdf: Sbdf, byte_offset: usize, value: u16) ConfigSpace.Error!void {
        _ = sbdf;
        const self: *NoDwordConfig = @ptrCast(@alignCast(context));
        const encoded = stdx.layout.Le(u16).fromNative(value);
        stdx.bytes.store(stdx.layout.Le(u16), &self.bytes, byte_offset, encoded) catch |err| switch (err) {
            error.EndOfStream => return error.OutOfBounds,
        };
    }

    fn write32Unsupported(context: *anyopaque, sbdf: Sbdf, byte_offset: usize, value: u32) ConfigSpace.Error!void {
        _ = context;
        _ = sbdf;
        _ = byte_offset;
        _ = value;
        return error.UnsupportedAccessWidth;
    }
};

test "layout: extended capability window covers PCIe extended dword slots" {
    try std.testing.expectEqual(@as(u16, 0x100), ext.window.start);
    try std.testing.expectEqual(@as(u16, 0xFFC), ext.window.end);
    try std.testing.expectEqual(@as(u16, 4), ext.window.step);
    try std.testing.expectEqual(@as(usize, 960), ext.window.slot_count);

    const span: usize = @as(usize, ext.window.end) - @as(usize, ext.window.start);
    const step: usize = ext.window.step;
    try std.testing.expectEqual(ext.window.slot_count, @divExact(span, step) + 1);
}

test "unit: iterator treats absent extended config and zero head as empty" {
    const heads = [_]u32{
        0xFFFF_FFFF,
        0x0000_0000,
    };

    for (heads) |head| {
        var bytes: [function_window_size]u8 = @splat(0xA5);
        store32(&bytes, ext.window.start, head);
        const sbdf = Sbdf.of(0, 0, 0, 0);
        var backend = TestConfigSpace.initSingle(sbdf, &bytes);
        const function = Function.unchecked(backend.configSpace(), sbdf);

        var it = try Iterator.validate(function);

        try std.testing.expectEqual(@as(?ExtCapability, null), try it.next());
        try std.testing.expectEqual(@as(?ExtCapability, null), try find(function, 0x0001));
    }
}

test "unit: iterator yields a single extended capability and terminates" {
    var bytes: [function_window_size]u8 = @splat(0);
    storeHeader(&bytes, ext.window.start, 0x0001, 3, 0);
    const sbdf = Sbdf.of(0, 0, 1, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const function = Function.unchecked(backend.configSpace(), sbdf);

    var it = try Iterator.validate(function);

    const cap = (try it.next()).?;
    try expectCapability(cap, .{ .id = 0x0001, .version = 3, .offset = ext.window.start });
    try std.testing.expectEqual(@as(Id, @enumFromInt(0x0001)), cap.idTag());
    try std.testing.expectEqual(@as(?ExtCapability, null), try it.next());
}

test "unit: iterator traverses multiple extended capabilities through the end slot" {
    var bytes: [function_window_size]u8 = @splat(0);
    storeHeader(&bytes, ext.window.start, 0x0001, 1, 0x120);
    storeHeader(&bytes, 0x120, 0x0002, 5, ext.window.end);
    storeHeader(&bytes, ext.window.end, 0x0003, 15, 0);
    const sbdf = Sbdf.of(0, 0, 2, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const function = Function.unchecked(backend.configSpace(), sbdf);

    var it = try Iterator.validate(function);

    try expectCapability((try it.next()).?, .{ .id = 0x0001, .version = 1, .offset = ext.window.start });
    try expectCapability((try it.next()).?, .{ .id = 0x0002, .version = 5, .offset = 0x120 });
    try expectCapability((try it.next()).?, .{ .id = 0x0003, .version = 15, .offset = ext.window.end });
    try std.testing.expectEqual(@as(?ExtCapability, null), try it.next());
}

test "unit: find returns the first matching capability and null for a terminated miss" {
    var bytes: [function_window_size]u8 = @splat(0);
    storeHeader(&bytes, ext.window.start, 0x000A, 1, 0x108);
    storeHeader(&bytes, 0x108, 0x000B, 2, 0x110);
    storeHeader(&bytes, 0x110, 0x000C, 3, 0);
    const sbdf = Sbdf.of(0, 0, 3, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const function = Function.unchecked(backend.configSpace(), sbdf);

    var it = try Iterator.validate(function);

    try expectCapability((try it.find(0x000B)).?, .{ .id = 0x000B, .version = 2, .offset = 0x108 });
    try std.testing.expectEqual(@as(?ExtCapability, null), try find(function, 0x9999));
}

test "malformed: iterator rejects next pointers outside extended capability slots" {
    const next_offsets = [_]u16{
        0x0FC,
        0x102,
    };

    for (next_offsets) |next| {
        var bytes: [function_window_size]u8 = @splat(0);
        storeHeader(&bytes, ext.window.start, 0x000D, 1, next);
        const sbdf = Sbdf.of(0, 0, 4, 0);
        var backend = TestConfigSpace.initSingle(sbdf, &bytes);
        const function = Function.unchecked(backend.configSpace(), sbdf);

        var it = try Iterator.validate(function);

        try expectCapability((try it.next()).?, .{ .id = 0x000D, .version = 1, .offset = ext.window.start });
        try std.testing.expectError(error.MalformedCapability, it.next());
    }
}

test "malformed: iterator detects cycles before yielding a repeated capability" {
    var bytes: [function_window_size]u8 = @splat(0);
    storeHeader(&bytes, ext.window.start, 0x0010, 1, 0x108);
    storeHeader(&bytes, 0x108, 0x0011, 2, ext.window.start);
    const sbdf = Sbdf.of(0, 0, 5, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const function = Function.unchecked(backend.configSpace(), sbdf);

    var it = try Iterator.validate(function);

    try expectCapability((try it.next()).?, .{ .id = 0x0010, .version = 1, .offset = ext.window.start });
    try expectCapability((try it.next()).?, .{ .id = 0x0011, .version = 2, .offset = 0x108 });
    try std.testing.expectError(error.MalformedCapability, it.next());
}

test "malformed: cursor rejects bases outside extended capability slots" {
    const bases = [_]u16{
        0x0FC,
        0x1000,
        0x102,
    };

    var bytes: [function_window_size]u8 = @splat(0);
    const sbdf = Sbdf.of(0, 0, 6, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const function = Function.unchecked(backend.configSpace(), sbdf);

    for (bases) |base| {
        try std.testing.expectError(error.MalformedCapability, Cursor.from(function, base));
    }
}

test "unit: cursor reads and writes relative to an extended capability base" {
    var bytes: [function_window_size]u8 = @splat(0);
    store32(&bytes, 0x130, 0xDEAD_BEEF);
    const sbdf = Sbdf.of(0, 0, 7, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const function = Function.unchecked(backend.configSpace(), sbdf);

    const cursor = try Cursor.from(function, 0x120);

    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), try cursor.read32(0x10));
    try cursor.write16(0x12, 0xCAFE);
    try cursor.write8(0x1F, 0x7E);
    try std.testing.expectEqual(@as(u16, 0xCAFE), load16(&bytes, 0x132));
    try std.testing.expectEqual(@as(u8, 0x7E), bytes[0x13F]);
}

test "malformed: cursor maps containment and alignment failures to MalformedCapability" {
    var bytes: [function_window_size]u8 = @splat(0x5A);
    const sbdf = Sbdf.of(0, 0, 8, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const function = Function.unchecked(backend.configSpace(), sbdf);

    const end = try Cursor.from(function, ext.window.end);
    const start = try Cursor.from(function, ext.window.start);

    try std.testing.expectEqual(@as(u8, 0x5A), try end.read8(3));
    try std.testing.expectError(error.MalformedCapability, end.read8(4));
    try std.testing.expectError(error.MalformedCapability, end.read16(3));
    try std.testing.expectError(error.MalformedCapability, end.write8(4, 0));
    try std.testing.expectError(error.MalformedCapability, end.write16(3, 0));
    try std.testing.expectError(error.MalformedCapability, start.read16(1));
    try std.testing.expectError(error.MalformedCapability, start.write32(2, 0));
    try std.testing.expectEqual(@as(u8, 0x5A), bytes[0xFFF]);
}

test "malformed: cursor propagates backend width failures after prevalidation succeeds" {
    var backend = NoDwordConfig{};
    const sbdf = Sbdf.of(0, 0, 9, 0);
    const function = Function.unchecked(backend.configSpace(), sbdf);

    const cursor = try Cursor.from(function, ext.window.start);

    try std.testing.expectError(error.UnsupportedAccessWidth, cursor.read32(0));
    try std.testing.expectError(error.UnsupportedAccessWidth, cursor.write32(0, 0));
}

fn expectCapability(cap: ExtCapability, expected: struct {
    id: u16,
    version: u4,
    offset: u16,
}) !void {
    try std.testing.expectEqual(expected.id, cap.id);
    try std.testing.expectEqual(expected.version, cap.version);
    try std.testing.expectEqual(expected.offset, cap.offset);
}

fn storeHeader(bytes: *[function_window_size]u8, byte_offset: u16, id: u16, version: u4, next: u16) void {
    store32(bytes, byte_offset, header(id, version, next));
}

fn header(id: u16, version: u4, next: u16) u32 {
    return @as(u32, id) | (@as(u32, version) << 16) | (@as(u32, next) << 20);
}

fn store32(bytes: *[function_window_size]u8, byte_offset: usize, value: u32) void {
    const encoded = stdx.layout.Le(u32).fromNative(value);
    stdx.bytes.store(stdx.layout.Le(u32), bytes, byte_offset, encoded) catch |err| switch (err) {
        error.EndOfStream => unreachable,
    };
}

fn load16(bytes: *const [function_window_size]u8, byte_offset: usize) u16 {
    const wrapped = stdx.bytes.load(stdx.layout.Le(u16), bytes, byte_offset) catch |err| switch (err) {
        error.EndOfStream => unreachable,
    };
    return wrapped.native();
}
