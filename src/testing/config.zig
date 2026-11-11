//! Config-space test support.

const std = @import("std");

const config = @import("config");
const core = @import("core");

const ConfigSpace = config.ConfigSpace;
const ConfigError = ConfigSpace.Error;
const Sbdf = core.Sbdf;

pub const TestConfigSpace = struct {
    backing: Backing,

    pub const Entry = struct {
        sbdf: Sbdf,
        bytes: []u8,
    };

    const Backing = union(enum) {
        single: Entry,
        multi: []Entry,
    };

    pub fn fromSingle(sbdf: Sbdf, bytes: []u8) TestConfigSpace {
        std.debug.assert(bytes.len == core.config.extended_size);
        return .{ .backing = .{ .single = .{ .sbdf = sbdf, .bytes = bytes } } };
    }

    pub fn from(entries: []Entry) TestConfigSpace {
        for (entries) |entry| {
            std.debug.assert(entry.bytes.len == core.config.extended_size);
        }

        return .{ .backing = .{ .multi = entries } };
    }

    pub fn config(self: *TestConfigSpace) ConfigSpace {
        return ConfigSpace.from(@ptrCast(self), &vtable);
    }

    const vtable: ConfigSpace.VTable = .{
        .read8 = read8,
        .read16 = read16,
        .read32 = read32,
        .write8 = write8,
        .write16 = write16,
        .write32 = write32,
    };

    fn read8(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigError!u8 {
        const self: *TestConfigSpace = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return 0xFF;
        return bytes[offset];
    }

    fn read16(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigError!u16 {
        const self: *TestConfigSpace = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return 0xFFFF;
        return std.mem.readInt(u16, bytes[offset..][0..@sizeOf(u16)], .little);
    }

    fn read32(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigError!u32 {
        const self: *TestConfigSpace = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return 0xFFFF_FFFF;
        return std.mem.readInt(u32, bytes[offset..][0..@sizeOf(u32)], .little);
    }

    fn write8(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u8) ConfigError!void {
        const self: *TestConfigSpace = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return;
        bytes[offset] = value;
    }

    fn write16(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u16) ConfigError!void {
        const self: *TestConfigSpace = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return;
        std.mem.writeInt(u16, bytes[offset..][0..@sizeOf(u16)], value, .little);
    }

    fn write32(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u32) ConfigError!void {
        const self: *TestConfigSpace = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return;
        std.mem.writeInt(u32, bytes[offset..][0..@sizeOf(u32)], value, .little);
    }

    fn functionBytes(self: *TestConfigSpace, sbdf: Sbdf) ?[]u8 {
        switch (self.backing) {
            .single => |entry| {
                if (entry.sbdf.eql(sbdf)) {
                    return entry.bytes;
                }
            },
            .multi => |entries| {
                for (entries) |entry| {
                    if (entry.sbdf.eql(sbdf)) {
                        return entry.bytes;
                    }
                }
            },
        }

        return null;
    }
};

pub const unit = struct {
    const testing = std.testing;

    const pcie_window_size = core.config.extended_size;

    const Offset = core.Offset;

    test "byte accesses round-trip at boundary and unaligned offsets" {
        var buf: [pcie_window_size]u8 = @splat(0);
        const sbdf = Sbdf.from(.from(0), 0, 0, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &buf);
        const space = backend.config();
        const first = Offset(u8).from(0);
        const second = Offset(u8).from(1);
        const last = Offset(u8).from(0xFFF);

        try space.write(sbdf, first, 0xAB);
        try space.write(sbdf, second, 0xCD);
        try space.write(sbdf, last, 0xEF);

        try testing.expectEqual(@as(u8, 0xAB), try space.read(sbdf, first));
        try testing.expectEqual(@as(u8, 0xCD), try space.read(sbdf, second));
        try testing.expectEqual(@as(u8, 0xEF), try space.read(sbdf, last));
    }

    test "word accesses round-trip with little-endian encoding" {
        var buf: [pcie_window_size]u8 = @splat(0);
        const sbdf = Sbdf.from(.from(0), 0, 0, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &buf);
        const space = backend.config();
        const offset = Offset(u16).from(0);

        try space.write(sbdf, offset, 0xBEEF);

        try testing.expectEqual(@as(u16, 0xBEEF), try space.read(sbdf, offset));
        try testing.expectEqualSlices(u8, &.{ 0xEF, 0xBE }, buf[0..2]);
    }

    test "dword accesses round-trip with little-endian encoding" {
        var buf: [pcie_window_size]u8 = @splat(0);
        const sbdf = Sbdf.from(.from(0), 0, 0, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &buf);
        const space = backend.config();
        const offset = Offset(u32).from(0x10);

        try space.write(sbdf, offset, 0xDEAD_BEEF);

        try testing.expectEqual(@as(u32, 0xDEAD_BEEF), try space.read(sbdf, offset));
        try testing.expectEqualSlices(u8, &.{ 0xEF, 0xBE, 0xAD, 0xDE }, buf[0x10..0x14]);
    }

    test "multi-entry dispatch isolates distinct SBDF storage" {
        var buf_a: [pcie_window_size]u8 = @splat(0);
        var buf_b: [pcie_window_size]u8 = @splat(0);
        const a = Sbdf.from(.from(0), 0, 1, 0);
        const b = Sbdf.from(.from(0), 0, 2, 0);
        var entries = [_]TestConfigSpace.Entry{
            .{ .sbdf = a, .bytes = &buf_a },
            .{ .sbdf = b, .bytes = &buf_b },
        };
        var backend = TestConfigSpace.from(&entries);
        const space = backend.config();
        const offset = Offset(u32).from(0);

        try space.write(a, offset, 0xAAAA_AAAA);
        try space.write(b, offset, 0xBBBB_BBBB);

        try testing.expectEqual(@as(u32, 0xAAAA_AAAA), try space.read(a, offset));
        try testing.expectEqual(@as(u32, 0xBBBB_BBBB), try space.read(b, offset));
    }

    test "multi-entry dispatch takes the first entry when SBDFs alias" {
        var buf_first: [pcie_window_size]u8 = @splat(0xAA);
        var buf_second: [pcie_window_size]u8 = @splat(0xBB);
        const sbdf = Sbdf.from(.from(0), 0, 3, 0);
        var entries = [_]TestConfigSpace.Entry{
            .{ .sbdf = sbdf, .bytes = &buf_first },
            .{ .sbdf = sbdf, .bytes = &buf_second },
        };
        var backend = TestConfigSpace.from(&entries);
        const space = backend.config();
        const first = Offset(u8).from(0);
        const offset = Offset(u32).from(0x10);

        try testing.expectEqual(@as(u8, 0xAA), try space.read(sbdf, first));

        try space.write(sbdf, offset, 0xCAFE_BABE);

        try testing.expectEqual(@as(u32, 0xCAFE_BABE), try space.read(sbdf, offset));
        try testing.expectEqualSlices(u8, &.{ 0xBB, 0xBB, 0xBB, 0xBB }, buf_second[0x10..0x14]);
    }

    test "unmatched Sbdf reads as absence marker and drops writes" {
        var buf: [pcie_window_size]u8 = @splat(0);
        var backend = TestConfigSpace.fromSingle(Sbdf.from(.from(0), 0, 0, 0), &buf);
        const space = backend.config();
        const absent = Sbdf.from(.from(0), 0, 5, 0);
        const word = Offset(u16).from(0);
        const dword = Offset(u32).from(0);
        const byte = Offset(u8).from(7);

        try testing.expectEqual(@as(u16, 0xFFFF), try space.read(absent, word));
        try testing.expectEqual(@as(u32, 0xFFFF_FFFF), try space.read(absent, dword));
        try testing.expectEqual(@as(u8, 0xFF), try space.read(absent, byte));

        try space.write(absent, dword, 0xDEAD_BEEF);

        try testing.expectEqualSlices(u8, &@as([pcie_window_size]u8, @splat(0)), &buf);
    }
};
