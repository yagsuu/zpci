//! Tests for docs/specs/config/accessor.md.

const std = @import("std");

const stdx = @import("stdx");
const zpci = @import("zpci");

const ConfigSpace = zpci.config.ConfigSpace;
const Sbdf = zpci.core.Sbdf;

const function_window_size: usize = 0x1000;

/// Byte-backed host-test backend for docs/specs/config/accessor.md §`FakeConfig`.
/// Dispatch uses the first matching `Sbdf`; missing functions read as PCI absence bytes and drop writes.
const FakeConfig = struct {
    backing: Backing,

    pub const Entry = struct {
        sbdf: Sbdf,
        bytes: []u8,
    };

    const Backing = union(enum) {
        single: Entry,
        multi: []Entry,
    };

    fn initSingle(sbdf: Sbdf, bytes: []u8) FakeConfig {
        std.debug.assert(bytes.len == function_window_size);
        return .{ .backing = .{ .single = .{ .sbdf = sbdf, .bytes = bytes } } };
    }

    fn init(entries: []Entry) FakeConfig {
        for (entries) |e| std.debug.assert(e.bytes.len == function_window_size);
        return .{ .backing = .{ .multi = entries } };
    }

    fn configSpace(self: *FakeConfig) ConfigSpace {
        return ConfigSpace.init(@ptrCast(self), &vtable);
    }

    fn functionBytes(self: *FakeConfig, sbdf: Sbdf) ?[]u8 {
        switch (self.backing) {
            .single => |entry| {
                if (entry.sbdf.eql(sbdf)) return entry.bytes;
            },
            .multi => |entries| {
                for (entries) |entry| {
                    if (entry.sbdf.eql(sbdf)) return entry.bytes;
                }
            },
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

    fn read8(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigSpace.Error!u8 {
        const self: *FakeConfig = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return 0xFF;
        return bytes[offset];
    }

    fn read16(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigSpace.Error!u16 {
        const self: *FakeConfig = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return 0xFFFF;
        const wrapped = stdx.bytes.load(stdx.layout.Le(u16), bytes, offset) catch |err| switch (err) {
            error.EndOfStream => return error.OutOfBounds,
        };
        return wrapped.native();
    }

    fn read32(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigSpace.Error!u32 {
        const self: *FakeConfig = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return 0xFFFF_FFFF;
        const wrapped = stdx.bytes.load(stdx.layout.Le(u32), bytes, offset) catch |err| switch (err) {
            error.EndOfStream => return error.OutOfBounds,
        };
        return wrapped.native();
    }

    fn write8(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u8) ConfigSpace.Error!void {
        const self: *FakeConfig = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return;
        bytes[offset] = value;
    }

    fn write16(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u16) ConfigSpace.Error!void {
        const self: *FakeConfig = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return;
        const encoded = stdx.layout.Le(u16).fromNative(value);
        stdx.bytes.store(stdx.layout.Le(u16), bytes, offset, encoded) catch |err| switch (err) {
            error.EndOfStream => return error.OutOfBounds,
        };
    }

    fn write32(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u32) ConfigSpace.Error!void {
        const self: *FakeConfig = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return;
        const encoded = stdx.layout.Le(u32).fromNative(value);
        stdx.bytes.store(stdx.layout.Le(u32), bytes, offset, encoded) catch |err| switch (err) {
            error.EndOfStream => return error.OutOfBounds,
        };
    }
};

/// Restricted backend that reports `UnsupportedAccessWidth` for any 4-byte
/// access. Used to prove the accessor propagates backend width failures
/// after shape validation succeeds.
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

    fn read8(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigSpace.Error!u8 {
        _ = sbdf;
        const self: *NoDwordConfig = @ptrCast(@alignCast(context));
        return self.bytes[offset];
    }

    fn read16(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigSpace.Error!u16 {
        _ = sbdf;
        const self: *NoDwordConfig = @ptrCast(@alignCast(context));
        // ConfigSpace validated offset+2 <= function_window_size before dispatch,
        // so load cannot report EndOfStream.
        const wrapped = stdx.bytes.load(stdx.layout.Le(u16), &self.bytes, offset) catch |err| switch (err) {
            error.EndOfStream => unreachable,
        };
        return wrapped.native();
    }

    fn read32Unsupported(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigSpace.Error!u32 {
        _ = context;
        _ = sbdf;
        _ = offset;
        return error.UnsupportedAccessWidth;
    }

    fn write8(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u8) ConfigSpace.Error!void {
        _ = sbdf;
        const self: *NoDwordConfig = @ptrCast(@alignCast(context));
        self.bytes[offset] = value;
    }

    fn write16(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u16) ConfigSpace.Error!void {
        _ = sbdf;
        const self: *NoDwordConfig = @ptrCast(@alignCast(context));
        const encoded = stdx.layout.Le(u16).fromNative(value);
        // ConfigSpace validated offset+2 <= function_window_size before dispatch,
        // so store cannot report EndOfStream.
        stdx.bytes.store(stdx.layout.Le(u16), &self.bytes, offset, encoded) catch |err| switch (err) {
            error.EndOfStream => unreachable,
        };
    }

    fn write32Unsupported(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u32) ConfigSpace.Error!void {
        _ = context;
        _ = sbdf;
        _ = offset;
        _ = value;
        return error.UnsupportedAccessWidth;
    }
};

test "layout: function_window_size matches PCIe 4 KiB config window" {
    try std.testing.expectEqual(@as(usize, 0x1000), function_window_size);
}

test "unit: read8/write8 round-trip at every alignment" {
    var buf: [function_window_size]u8 = @splat(0);
    const sbdf = Sbdf.of(0, 0, 0, 0);
    var fake = FakeConfig.initSingle(sbdf, &buf);
    const config = fake.configSpace();

    try config.write8(sbdf, 0x00, 0xAB);
    try config.write8(sbdf, 0x01, 0xCD);
    try config.write8(sbdf, 0xFFF, 0xEF);
    try std.testing.expectEqual(@as(u8, 0xAB), try config.read8(sbdf, 0x00));
    try std.testing.expectEqual(@as(u8, 0xCD), try config.read8(sbdf, 0x01));
    try std.testing.expectEqual(@as(u8, 0xEF), try config.read8(sbdf, 0xFFF));
}

test "unit: read16/write16 round-trip encodes little-endian" {
    var buf: [function_window_size]u8 = @splat(0);
    const sbdf = Sbdf.of(0, 0, 0, 0);
    var fake = FakeConfig.initSingle(sbdf, &buf);
    const config = fake.configSpace();

    try config.write16(sbdf, 0x00, 0xBEEF);
    try std.testing.expectEqual(@as(u16, 0xBEEF), try config.read16(sbdf, 0x00));
    try std.testing.expectEqual(@as(u8, 0xEF), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xBE), buf[1]);
}

test "unit: read32/write32 round-trip encodes little-endian" {
    var buf: [function_window_size]u8 = @splat(0);
    const sbdf = Sbdf.of(0, 0, 0, 0);
    var fake = FakeConfig.initSingle(sbdf, &buf);
    const config = fake.configSpace();

    try config.write32(sbdf, 0x10, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), try config.read32(sbdf, 0x10));
    try std.testing.expectEqualSlices(u8, &.{ 0xEF, 0xBE, 0xAD, 0xDE }, buf[0x10..0x14]);
}

test "malformed: read/write beyond 4 KiB reports OutOfBounds" {
    var buf: [function_window_size]u8 = @splat(0);
    const sbdf = Sbdf.of(0, 0, 0, 0);
    var fake = FakeConfig.initSingle(sbdf, &buf);
    const config = fake.configSpace();

    try std.testing.expectError(error.OutOfBounds, config.read8(sbdf, function_window_size));
    try std.testing.expectError(error.OutOfBounds, config.read16(sbdf, function_window_size - 1));
    try std.testing.expectError(error.OutOfBounds, config.read32(sbdf, function_window_size - 3));
    try std.testing.expectError(error.OutOfBounds, config.write8(sbdf, function_window_size, 0));
    try std.testing.expectError(error.OutOfBounds, config.write16(sbdf, function_window_size - 1, 0));
    try std.testing.expectError(error.OutOfBounds, config.write32(sbdf, function_window_size - 3, 0));
}

test "malformed: containment beats alignment for end-of-window offsets" {
    // read32(0xFFF) is both unaligned and overruns; containment must win.
    var buf: [function_window_size]u8 = @splat(0);
    const sbdf = Sbdf.of(0, 0, 0, 0);
    var fake = FakeConfig.initSingle(sbdf, &buf);
    const config = fake.configSpace();

    try std.testing.expectError(error.OutOfBounds, config.read32(sbdf, 0xFFF));
    try std.testing.expectError(error.OutOfBounds, config.write32(sbdf, 0xFFF, 0));
    try std.testing.expectError(error.OutOfBounds, config.read16(sbdf, 0xFFF));
}

test "malformed: offset arithmetic overflow reports OutOfBounds" {
    var buf: [function_window_size]u8 = @splat(0);
    const sbdf = Sbdf.of(0, 0, 0, 0);
    var fake = FakeConfig.initSingle(sbdf, &buf);
    const config = fake.configSpace();

    try std.testing.expectError(error.OutOfBounds, config.read32(sbdf, std.math.maxInt(usize)));
    try std.testing.expectError(error.OutOfBounds, config.write32(sbdf, std.math.maxInt(usize) - 2, 0));
}

test "malformed: unaligned read16/write16 reports UnalignedAccess after containment succeeds" {
    var buf: [function_window_size]u8 = @splat(0);
    const sbdf = Sbdf.of(0, 0, 0, 0);
    var fake = FakeConfig.initSingle(sbdf, &buf);
    const config = fake.configSpace();

    try std.testing.expectError(error.UnalignedAccess, config.read16(sbdf, 1));
    try std.testing.expectError(error.UnalignedAccess, config.read16(sbdf, 3));
    try std.testing.expectError(error.UnalignedAccess, config.write16(sbdf, 1, 0));
    try std.testing.expectError(error.UnalignedAccess, config.write16(sbdf, 5, 0));
}

test "malformed: unaligned read32/write32 reports UnalignedAccess after containment succeeds" {
    var buf: [function_window_size]u8 = @splat(0);
    const sbdf = Sbdf.of(0, 0, 0, 0);
    var fake = FakeConfig.initSingle(sbdf, &buf);
    const config = fake.configSpace();

    try std.testing.expectError(error.UnalignedAccess, config.read32(sbdf, 1));
    try std.testing.expectError(error.UnalignedAccess, config.read32(sbdf, 2));
    try std.testing.expectError(error.UnalignedAccess, config.read32(sbdf, 3));
    try std.testing.expectError(error.UnalignedAccess, config.write32(sbdf, 3, 0));
}

test "malformed: failed writes leave storage unchanged" {
    var buf: [function_window_size]u8 = @splat(0xA5);
    const sbdf = Sbdf.of(0, 0, 0, 0);
    var fake = FakeConfig.initSingle(sbdf, &buf);
    const config = fake.configSpace();
    const before = buf;

    try std.testing.expectError(error.OutOfBounds, config.write8(sbdf, function_window_size, 0));
    try std.testing.expectEqualSlices(u8, &before, &buf);

    try std.testing.expectError(error.UnalignedAccess, config.write16(sbdf, 1, 0xBEEF));
    try std.testing.expectEqualSlices(u8, &before, &buf);

    var backend = NoDwordConfig{ .bytes = @splat(0x5A) };
    const restricted = backend.configSpace();
    const restricted_before = backend.bytes;

    try std.testing.expectError(error.UnsupportedAccessWidth, restricted.write32(sbdf, 0x10, 0xDEAD_BEEF));
    try std.testing.expectEqualSlices(u8, &restricted_before, &backend.bytes);
}

test "unit: read8 accepts any contained offset" {
    var buf: [function_window_size]u8 = @splat(0);
    const sbdf = Sbdf.of(0, 0, 0, 0);
    var fake = FakeConfig.initSingle(sbdf, &buf);
    const config = fake.configSpace();

    inline for (.{ 0, 1, 2, 3, 5, 7, 0xFFF }) |o| {
        _ = try config.read8(sbdf, o);
    }
}

test "unit: multi-function dispatch services the first matching Sbdf" {
    var buf_a: [function_window_size]u8 = @splat(0);
    var buf_b: [function_window_size]u8 = @splat(0);
    var entries = [_]FakeConfig.Entry{
        .{ .sbdf = Sbdf.of(0, 0, 1, 0), .bytes = &buf_a },
        .{ .sbdf = Sbdf.of(0, 0, 2, 0), .bytes = &buf_b },
    };
    var fake = FakeConfig.init(&entries);
    const config = fake.configSpace();

    try config.write32(Sbdf.of(0, 0, 1, 0), 0x00, 0xAAAA_AAAA);
    try config.write32(Sbdf.of(0, 0, 2, 0), 0x00, 0xBBBB_BBBB);

    try std.testing.expectEqual(@as(u32, 0xAAAA_AAAA), try config.read32(Sbdf.of(0, 0, 1, 0), 0x00));
    try std.testing.expectEqual(@as(u32, 0xBBBB_BBBB), try config.read32(Sbdf.of(0, 0, 2, 0), 0x00));
}

test "unit: multi-function dispatch takes the first entry when Sbdfs alias" {
    // Duplicate Sbdf entries with distinct storage prove that ordering
    // beats identity: a broken implementation returning the last match
    // would visibly break, not silently coincide.
    var buf_first: [function_window_size]u8 = @splat(0xAA);
    var buf_second: [function_window_size]u8 = @splat(0xBB);
    const sbdf = Sbdf.of(0, 0, 3, 0);
    var entries = [_]FakeConfig.Entry{
        .{ .sbdf = sbdf, .bytes = &buf_first },
        .{ .sbdf = sbdf, .bytes = &buf_second },
    };
    var fake = FakeConfig.init(&entries);
    const config = fake.configSpace();

    try std.testing.expectEqual(@as(u8, 0xAA), try config.read8(sbdf, 0x00));

    try config.write32(sbdf, 0x10, 0xCAFE_BABE);
    try std.testing.expectEqual(@as(u32, 0xCAFE_BABE), try config.read32(sbdf, 0x10));
    // Second entry MUST remain untouched: its 0xBB filler stays intact.
    try std.testing.expectEqualSlices(u8, &.{ 0xBB, 0xBB, 0xBB, 0xBB }, buf_second[0x10..0x14]);
}

test "unit: unmatched Sbdf reads as absence marker and drops writes" {
    var buf: [function_window_size]u8 = @splat(0);
    var fake = FakeConfig.initSingle(Sbdf.of(0, 0, 0, 0), &buf);
    const config = fake.configSpace();
    const absent = Sbdf.of(0, 0, 5, 0);

    try std.testing.expectEqual(@as(u16, 0xFFFF), try config.read16(absent, 0x00));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), try config.read32(absent, 0x00));
    try std.testing.expectEqual(@as(u8, 0xFF), try config.read8(absent, 0x07));

    try config.write32(absent, 0x00, 0xDEAD_BEEF);
    try std.testing.expectEqualSlices(u8, &@as([function_window_size]u8, @splat(0)), &buf);
}

test "malformed: backend UnsupportedAccessWidth surfaces after shape validation" {
    var backend = NoDwordConfig{};
    const config = backend.configSpace();
    const sbdf = Sbdf.of(0, 0, 0, 0);

    try std.testing.expectError(error.UnsupportedAccessWidth, config.read32(sbdf, 0x10));
    try std.testing.expectError(error.UnsupportedAccessWidth, config.write32(sbdf, 0x10, 0));

    // Narrower accesses still work — the failure is per-width, not per-backend.
    try config.write8(sbdf, 0x00, 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), try config.read8(sbdf, 0x00));
}

test "malformed: containment/alignment fail before the backend runs" {
    // The restricted backend would otherwise report UnsupportedAccessWidth on
    // read32; validation must intercept OutOfBounds and UnalignedAccess first.
    var backend = NoDwordConfig{};
    const config = backend.configSpace();
    const sbdf = Sbdf.of(0, 0, 0, 0);

    try std.testing.expectError(error.OutOfBounds, config.read32(sbdf, function_window_size));
    try std.testing.expectError(error.UnalignedAccess, config.read32(sbdf, 2));
}

test "unit: ConfigSpace handle copies share the same backend context" {
    var buf: [function_window_size]u8 = @splat(0);
    const sbdf = Sbdf.of(0, 0, 0, 0);
    var fake = FakeConfig.initSingle(sbdf, &buf);
    const config_a = fake.configSpace();
    const config_b = config_a;

    try config_a.write32(sbdf, 0x20, 0xCAFE_BABE);
    try std.testing.expectEqual(@as(u32, 0xCAFE_BABE), try config_b.read32(sbdf, 0x20));
}
