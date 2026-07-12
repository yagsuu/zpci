//! Tests for docs/specs/bar.md.

const std = @import("std");

const pci = @import("pci");

const Entry = pci.bar.Entry;

const ExpectedIo = struct {
    index: usize,
    base: u32,
    size: u32,
};

const ExpectedMemory = struct {
    index: usize,
    slot_count: usize,
    base: u64,
    size: u64,
    width: pci.bar.Kind.Width,
    prefetchable: bool,
};

const Function = pci.config.Function;
const Kind = pci.bar.Kind;
const Layout = pci.bar.Layout;
const Sbdf = pci.core.Sbdf;
const View = pci.bar.View;

const bar_count: usize = pci.header.type0.bar_count;
const function_window_size: usize = 0x1000;
const offset = struct {
    const command: usize = 0x04;
    const header_type: usize = 0x0E;
    const bars: usize = 0x10;
};

test "layout: pci.bar facade exposes BAR counts and header layouts" {
    // Compare public constants and explicit layouts against header-owned counts.
    try std.testing.expectEqual(@as(usize, 6), pci.bar.max_entries);

    var backend = ProbeConfig.init(.type0);
    const function = Function.unchecked(backend.configSpace(), backend.sbdf);

    try std.testing.expectEqual(@as(usize, 6), View.init(function, .type0).count());
    try std.testing.expectEqual(@as(usize, 2), View.init(function, .type1).count());
}

test "unit: View.detect maps config header kind to BAR layout" {
    // Seed type-0 and type-1 header bytes, then map them through `View.detect`.
    var endpoint = ProbeConfig.init(.type0);
    var bridge = ProbeConfig.init(.type1);

    const endpoint_view = (try View.detect(Function.unchecked(endpoint.configSpace(), endpoint.sbdf))).?;
    const bridge_view = (try View.detect(Function.unchecked(bridge.configSpace(), bridge.sbdf))).?;

    try std.testing.expectEqual(Layout.type0, endpoint_view.layout);
    try std.testing.expectEqual(@as(usize, 6), endpoint_view.count());
    try std.testing.expectEqual(Layout.type1, bridge_view.layout);
    try std.testing.expectEqual(@as(usize, 2), bridge_view.count());
}

test "unit: get decodes none, IO, 32-bit memory, and 64-bit memory BARs" {
    // Seed representative raw BAR dwords and assert each decoded entry shape.
    var backend = ProbeConfig.init(.type0);
    backend.setBar(0, 0x0000_0000);
    backend.setBar(1, 0x0000_C001);
    backend.setBar(2, 0x8000_1008);
    backend.setBar(3, 0x0000_200C);
    backend.setBar(4, 0x1234_5670);
    const view = View.init(Function.unchecked(backend.configSpace(), backend.sbdf), .type0);

    try expectNone(try view.get(0), 0);
    try expectIo(try view.get(1), .{ .index = 1, .base = 0x0000_C000, .size = 0 });
    try expectMemory(try view.get(2), .{
        .index = 2,
        .slot_count = 1,
        .base = 0x0000_0000_8000_1000,
        .size = 0,
        .width = .bits_32,
        .prefetchable = true,
    });
    try expectMemory(try view.get(3), .{
        .index = 3,
        .slot_count = 2,
        .base = 0x1234_5670_0000_2000,
        .size = 0,
        .width = .bits_64,
        .prefetchable = true,
    });
}

test "unit: iterator advances past the high slot of a 64-bit BAR" {
    // Seed a 64-bit pair followed by a 32-bit BAR and assert high-slot skipping.
    var backend = ProbeConfig.init(.type0);
    backend.setBar(0, 0x0000_1004);
    backend.setBar(1, 0x0000_0000);
    backend.setBar(2, 0x0000_2000);
    const view = View.init(Function.unchecked(backend.configSpace(), backend.sbdf), .type0);

    var it = view.iterator();
    try expectMemory((try it.next()).?, .{
        .index = 0,
        .slot_count = 2,
        .base = 0x0000_0000_0000_1000,
        .size = 0,
        .width = .bits_64,
        .prefetchable = false,
    });
    try expectMemory((try it.next()).?, .{
        .index = 2,
        .slot_count = 1,
        .base = 0x0000_0000_0000_2000,
        .size = 0,
        .width = .bits_32,
        .prefetchable = false,
    });
    try expectNone((try it.next()).?, 3);
    try expectNone((try it.next()).?, 4);
    try expectNone((try it.next()).?, 5);
    try std.testing.expectEqual(@as(?Entry, null), try it.next());
}

test "malformed: reserved and incomplete BAR encodings are rejected" {
    // Table-drive every malformed low/high-slot encoding owned by the BAR spec.
    const cases = [_]struct {
        name: []const u8,
        index: usize,
        bars: [bar_count]u32,
    }{
        .{ .name = "memory type 0b01", .index = 0, .bars = .{ 0x0000_0002, 0, 0, 0, 0, 0 } },
        .{ .name = "memory type 0b11", .index = 0, .bars = .{ 0x0000_0006, 0, 0, 0, 0, 0 } },
        .{ .name = "IO reserved bit", .index = 0, .bars = .{ 0x0000_0003, 0, 0, 0, 0, 0 } },
        .{ .name = "64-bit low in last slot", .index = 5, .bars = .{ 0, 0, 0, 0, 0, 0x0000_0004 } },
        .{ .name = "64-bit high decode bits", .index = 0, .bars = .{ 0x0000_0004, 0x0000_0001, 0, 0, 0, 0 } },
    };

    for (cases) |case| {
        var backend = ProbeConfig.init(.type0);
        for (case.bars, 0..) |raw, index| backend.setBar(index, raw);
        const view = View.init(Function.unchecked(backend.configSpace(), backend.sbdf), .type0);

        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectError(error.MalformedBar, view.get(case.index));
    }
}

test "unit: size probes IO BAR with IO decode disabled, then restores BAR and Command" {
    // Probe an IO BAR and assert only IO decode is disabled before restoration.
    var backend = ProbeConfig.init(.type0);
    backend.setCommand(0x0557);
    backend.setBar(0, 0x0000_C001);
    backend.setProbe(0, 0xFFFF_FF01);
    const view = View.init(Function.unchecked(backend.configSpace(), backend.sbdf), .type0);

    try expectIo(try view.size(0), .{ .index = 0, .base = 0x0000_C000, .size = 0x100 });

    try std.testing.expectEqual(@as(u32, 0x0000_C001), backend.bar(0));
    try expectCommandWrites(&backend, &.{ 0x0556, 0x0557 });
}

test "unit: size probes 32-bit memory BAR with memory decode disabled, then restores BAR and Command" {
    // Probe a 32-bit memory BAR and assert memory decode is disabled before restoration.
    var backend = ProbeConfig.init(.type0);
    backend.setCommand(0x0557);
    backend.setBar(0, 0x8000_1008);
    backend.setProbe(0, 0xFFFF_F000);
    const view = View.init(Function.unchecked(backend.configSpace(), backend.sbdf), .type0);

    try expectMemory(try view.size(0), .{
        .index = 0,
        .slot_count = 1,
        .base = 0x0000_0000_8000_1000,
        .size = 0x1000,
        .width = .bits_32,
        .prefetchable = true,
    });

    try std.testing.expectEqual(@as(u32, 0x8000_1008), backend.bar(0));
    try expectCommandWrites(&backend, &.{ 0x0555, 0x0557 });
}

test "unit: size probes 64-bit memory BAR with memory decode disabled and restores both slots" {
    // Probe a 64-bit BAR and assert both low/high slots and Command are restored.
    var backend = ProbeConfig.init(.type0);
    backend.setCommand(0x0557);
    backend.setBar(0, 0x0000_2004);
    backend.setBar(1, 0x1234_5670);
    backend.setProbe(0, 0xFFE0_0004);
    backend.setProbe(1, 0xFFFF_FFFF);
    const view = View.init(Function.unchecked(backend.configSpace(), backend.sbdf), .type0);

    try expectMemory(try view.size(0), .{
        .index = 0,
        .slot_count = 2,
        .base = 0x1234_5670_0000_2000,
        .size = 0x0020_0000,
        .width = .bits_64,
        .prefetchable = false,
    });

    try std.testing.expectEqual(@as(u32, 0x0000_2004), backend.bar(0));
    try std.testing.expectEqual(@as(u32, 0x1234_5670), backend.bar(1));
    try expectCommandWrites(&backend, &.{ 0x0555, 0x0557 });
}

test "unit: sizeAll probes every BAR under one decode-disable window and returns compact entries" {
    // Probe mixed BARs in one batch and assert compact output plus full restoration.
    var backend = ProbeConfig.init(.type0);
    backend.setCommand(0x0557);
    backend.setBar(0, 0x0000_C001);
    backend.setProbe(0, 0xFFFF_FF01);
    backend.setBar(1, 0x0000_2004);
    backend.setBar(2, 0x1234_5670);
    backend.setProbe(1, 0xFFE0_0004);
    backend.setProbe(2, 0xFFFF_FFFF);
    backend.setBar(3, 0x8000_1008);
    backend.setProbe(3, 0xFFFF_F000);
    backend.setBar(4, 0x0000_0000);
    backend.setProbe(4, 0x0000_0000);
    backend.setBar(5, 0x0000_D001);
    backend.setProbe(5, 0xFFFF_FC01);
    const view = View.init(Function.unchecked(backend.configSpace(), backend.sbdf), .type0);

    var scratch: [pci.bar.max_entries]Entry = undefined;
    const entries = try view.sizeAll(&scratch);

    try std.testing.expectEqual(@as(usize, 5), entries.len);
    try expectIo(entries[0], .{ .index = 0, .base = 0x0000_C000, .size = 0x100 });
    try expectMemory(entries[1], .{
        .index = 1,
        .slot_count = 2,
        .base = 0x1234_5670_0000_2000,
        .size = 0x0020_0000,
        .width = .bits_64,
        .prefetchable = false,
    });
    try expectMemory(entries[2], .{
        .index = 3,
        .slot_count = 1,
        .base = 0x0000_0000_8000_1000,
        .size = 0x1000,
        .width = .bits_32,
        .prefetchable = true,
    });
    try expectNone(entries[3], 4);
    try expectIo(entries[4], .{ .index = 5, .base = 0x0000_D000, .size = 0x400 });

    try std.testing.expectEqual(@as(u32, 0x0000_C001), backend.bar(0));
    try std.testing.expectEqual(@as(u32, 0x0000_2004), backend.bar(1));
    try std.testing.expectEqual(@as(u32, 0x1234_5670), backend.bar(2));
    try std.testing.expectEqual(@as(u32, 0x8000_1008), backend.bar(3));
    try std.testing.expectEqual(@as(u32, 0x0000_0000), backend.bar(4));
    try std.testing.expectEqual(@as(u32, 0x0000_D001), backend.bar(5));
    try expectCommandWrites(&backend, &.{ 0x0554, 0x0557 });
}

test "malformed: sizeAll rejects short scratch before touching config space" {
    // Pass undersized scratch and assert the backend observes no config I/O.
    var backend = ProbeConfig.init(.type0);
    backend.setCommand(0x0557);
    backend.setBar(0, 0x0000_C001);
    backend.setProbe(0, 0xFFFF_FF01);
    const view = View.init(Function.unchecked(backend.configSpace(), backend.sbdf), .type0);

    var scratch: [pci.bar.max_entries - 1]Entry = undefined;
    try std.testing.expectError(error.StorageExhausted, view.sizeAll(&scratch));

    try std.testing.expectEqual(@as(usize, 0), backend.read_count);
    try std.testing.expectEqual(@as(usize, 0), backend.write_count);
    try std.testing.expectEqual(@as(usize, 0), backend.command_write_count);
    try std.testing.expectEqual(@as(u32, 0x0000_C001), backend.bar(0));
    try std.testing.expectEqual(@as(u16, 0x0557), backend.command());
}

test "failure: size reports ProgrammingPartial when post-probe BAR restore fails" {
    // Inject a restore failure after probing and assert `ProgrammingPartial`.
    var backend = ProbeConfig.init(.type0);
    backend.setCommand(0x0557);
    backend.setBar(0, 0x8000_1000);
    backend.setProbe(0, 0xFFFF_F000);
    backend.fail_restore_offset = offset.bars;
    const view = View.init(Function.unchecked(backend.configSpace(), backend.sbdf), .type0);

    try std.testing.expectError(error.ProgrammingPartial, view.size(0));
    try expectCommandWrites(&backend, &.{ 0x0555, 0x0557 });
    try std.testing.expectEqual(@as(u16, 0x0557), backend.command());
}

fn expectNone(entry: Entry, index: usize) !void {
    try std.testing.expectEqual(index, entry.index);
    try std.testing.expectEqual(@as(usize, 1), entry.slot_count);
    try std.testing.expectEqual(Kind.none, entry.kind);
}

fn expectIo(entry: Entry, expected: ExpectedIo) !void {
    try std.testing.expectEqual(expected.index, entry.index);
    try std.testing.expectEqual(@as(usize, 1), entry.slot_count);
    switch (entry.kind) {
        .io => |io| {
            try std.testing.expectEqual(expected.base, io.base);
            try std.testing.expectEqual(expected.size, io.size);
        },
        else => return error.TestExpectedEqual,
    }
}

fn expectMemory(entry: Entry, expected: ExpectedMemory) !void {
    try std.testing.expectEqual(expected.index, entry.index);
    try std.testing.expectEqual(expected.slot_count, entry.slot_count);
    switch (entry.kind) {
        .memory => |memory| {
            try std.testing.expectEqual(expected.base, memory.base);
            try std.testing.expectEqual(expected.size, memory.size);
            try std.testing.expectEqual(expected.width, memory.width);
            try std.testing.expectEqual(expected.prefetchable, memory.prefetchable);
        },
        else => return error.TestExpectedEqual,
    }
}

fn expectCommandWrites(backend: *const ProbeConfig, expected: []const u16) !void {
    try std.testing.expectEqual(expected.len, backend.command_write_count);
    for (expected, 0..) |raw, index| {
        try std.testing.expectEqual(raw, backend.command_writes[index]);
    }
}

const ProbeConfig = struct {
    sbdf: Sbdf = Sbdf.of(0, 0, 1, 0),
    bytes: [function_window_size]u8 = @splat(0),
    probe_values: [bar_count]u32 = @splat(0),
    probe_active: [bar_count]bool = @splat(false),
    read_count: usize = 0,
    write_count: usize = 0,
    command_writes: [8]u16 = @splat(0),
    command_write_count: usize = 0,
    fail_restore_offset: ?usize = null,

    fn init(layout: Layout) ProbeConfig {
        var self: ProbeConfig = .{};
        self.setCommand(0);
        self.bytes[offset.header_type] = switch (layout) {
            .type0 => 0x00,
            .type1 => 0x01,
        };

        return self;
    }

    fn configSpace(self: *ProbeConfig) pci.config.ConfigSpace {
        return pci.config.ConfigSpace.init(@ptrCast(self), &vtable);
    }

    fn setCommand(self: *ProbeConfig, raw: u16) void {
        store16(&self.bytes, offset.command, raw);
    }

    fn command(self: *const ProbeConfig) u16 {
        return load16(&self.bytes, offset.command);
    }

    fn setBar(self: *ProbeConfig, index: usize, raw: u32) void {
        store32(&self.bytes, barOffset(index), raw);
    }

    fn bar(self: *const ProbeConfig, index: usize) u32 {
        return load32(&self.bytes, barOffset(index));
    }

    fn setProbe(self: *ProbeConfig, index: usize, raw: u32) void {
        self.probe_values[index] = raw;
    }

    const vtable: pci.config.ConfigSpace.VTable = .{
        .read8 = read8,
        .read16 = read16,
        .read32 = read32,
        .write8 = write8,
        .write16 = write16,
        .write32 = write32,
    };

    fn read8(context: *anyopaque, _: Sbdf, byte_offset: usize) pci.config.ConfigSpace.Error!u8 {
        const self: *ProbeConfig = @ptrCast(@alignCast(context));
        self.read_count += 1;
        return self.bytes[byte_offset];
    }

    fn read16(context: *anyopaque, _: Sbdf, byte_offset: usize) pci.config.ConfigSpace.Error!u16 {
        const self: *ProbeConfig = @ptrCast(@alignCast(context));
        self.read_count += 1;
        return load16(&self.bytes, byte_offset);
    }

    fn read32(context: *anyopaque, _: Sbdf, byte_offset: usize) pci.config.ConfigSpace.Error!u32 {
        const self: *ProbeConfig = @ptrCast(@alignCast(context));
        self.read_count += 1;
        if (barIndex(byte_offset)) |index| {
            if (self.probe_active[index]) return self.probe_values[index];
        }

        return load32(&self.bytes, byte_offset);
    }

    fn write8(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u8) pci.config.ConfigSpace.Error!void {
        const self: *ProbeConfig = @ptrCast(@alignCast(context));
        self.write_count += 1;
        self.bytes[byte_offset] = value;
    }

    fn write16(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u16) pci.config.ConfigSpace.Error!void {
        const self: *ProbeConfig = @ptrCast(@alignCast(context));
        self.write_count += 1;
        if (byte_offset == offset.command) {
            self.command_writes[self.command_write_count] = value;
            self.command_write_count += 1;
        }

        store16(&self.bytes, byte_offset, value);
    }

    fn write32(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u32) pci.config.ConfigSpace.Error!void {
        const self: *ProbeConfig = @ptrCast(@alignCast(context));
        self.write_count += 1;
        if (barIndex(byte_offset)) |index| {
            if (value == 0xFFFF_FFFF) {
                self.probe_active[index] = true;
                return;
            }
            const failing_restore = self.fail_restore_offset == byte_offset and self.probe_active[index];
            if (failing_restore) return error.UnsupportedAccessWidth;
            self.probe_active[index] = false;
        }
        store32(&self.bytes, byte_offset, value);
    }
};

fn barOffset(index: usize) usize {
    return offset.bars + index * 4;
}

fn barIndex(byte_offset: usize) ?usize {
    if (byte_offset < offset.bars) return null;
    const delta = byte_offset - offset.bars;
    if (delta % 4 != 0) return null;
    const index = @divExact(delta, 4);
    if (index >= bar_count) return null;
    return index;
}

fn load16(bytes: *const [function_window_size]u8, byte_offset: usize) u16 {
    const low = @as(u16, bytes[byte_offset]);
    const high = @as(u16, bytes[byte_offset + 1]) << 8;
    return high | low;
}

fn store16(bytes: *[function_window_size]u8, byte_offset: usize, value: u16) void {
    bytes[byte_offset] = @truncate(value);
    bytes[byte_offset + 1] = @truncate(value >> 8);
}

fn load32(bytes: *const [function_window_size]u8, byte_offset: usize) u32 {
    const byte0 = @as(u32, bytes[byte_offset]);
    const byte1 = @as(u32, bytes[byte_offset + 1]) << 8;
    const byte2 = @as(u32, bytes[byte_offset + 2]) << 16;
    const byte3 = @as(u32, bytes[byte_offset + 3]) << 24;
    return byte3 | byte2 | byte1 | byte0;
}

fn store32(bytes: *[function_window_size]u8, byte_offset: usize, value: u32) void {
    bytes[byte_offset] = @truncate(value);
    bytes[byte_offset + 1] = @truncate(value >> 8);
    bytes[byte_offset + 2] = @truncate(value >> 16);
    bytes[byte_offset + 3] = @truncate(value >> 24);
}
