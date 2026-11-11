//! ECAM configuration-space backend.

const std = @import("std");

const stdx = @import("stdx");

const accessor = @import("accessor.zig");
const segment = @import("segment.zig");
const core = @import("core");

const ConfigSpace = accessor.ConfigSpace;
const ConfigError = ConfigSpace.Error;

const Segment = segment.Segment;
const Sbdf = core.Sbdf;
const VirtAddr = stdx.addr.VirtAddr;

pub const Ecam = struct {
    regions: []const Region,

    pub const Region = struct {
        segment: Segment,
        base: VirtAddr,
    };

    pub const Error = error{
        NoRegions,
        InvalidBusRange,
        DuplicateSegment,
    };

    pub fn tryFrom(regions: []const Region) Error!Ecam {
        if (regions.len == 0) {
            return error.NoRegions;
        }

        for (regions, 0..) |region, index| {
            if (!region.segment.buses.isValid()) {
                return error.InvalidBusRange;
            }

            for (regions[0..index]) |previous| {
                if (previous.segment.segment == region.segment.segment) {
                    return error.DuplicateSegment;
                }
            }
        }

        return .{ .regions = regions };
    }

    pub fn config(self: *Ecam) ConfigSpace {
        return ConfigSpace.from(@ptrCast(self), &vtable);
    }

    pub fn find(self: Ecam, sbdf: Sbdf) ?*const Region {
        for (self.regions) |*region| {
            if (region.segment.segment == sbdf.segment) {
                return region;
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

    fn read8(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigError!u8 {
        const self: *Ecam = @ptrCast(@alignCast(context));
        const ptr: *volatile u8 = @ptrFromInt((try self.address(sbdf, offset)).raw());
        return ptr.*;
    }

    fn read16(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigError!u16 {
        const self: *Ecam = @ptrCast(@alignCast(context));
        const ptr: *volatile u16 = @ptrFromInt((try self.address(sbdf, offset)).raw());
        return std.mem.littleToNative(u16, ptr.*);
    }

    fn read32(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigError!u32 {
        const self: *Ecam = @ptrCast(@alignCast(context));
        const ptr: *volatile u32 = @ptrFromInt((try self.address(sbdf, offset)).raw());
        return std.mem.littleToNative(u32, ptr.*);
    }

    fn write8(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u8) ConfigError!void {
        const self: *Ecam = @ptrCast(@alignCast(context));
        const ptr: *volatile u8 = @ptrFromInt((try self.address(sbdf, offset)).raw());
        ptr.* = value;
    }

    fn write16(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u16) ConfigError!void {
        const self: *Ecam = @ptrCast(@alignCast(context));
        const ptr: *volatile u16 = @ptrFromInt((try self.address(sbdf, offset)).raw());
        ptr.* = std.mem.nativeToLittle(u16, value);
    }

    fn write32(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u32) ConfigError!void {
        const self: *Ecam = @ptrCast(@alignCast(context));
        const ptr: *volatile u32 = @ptrFromInt((try self.address(sbdf, offset)).raw());
        ptr.* = std.mem.nativeToLittle(u32, value);
    }

    fn address(self: *Ecam, sbdf: Sbdf, offset: usize) ConfigError!VirtAddr {
        const region = self.find(sbdf) orelse return error.OutOfBounds;
        if (!region.segment.contains(sbdf)) {
            return error.OutOfBounds;
        }

        const register: u12 = @truncate(offset);
        const byte_offset = (@as(u32, sbdf.bdf.bus - region.segment.buses.start) << 20) |
            (@as(u32, sbdf.bdf.device) << 15) |
            (@as(u32, sbdf.bdf.function) << 12) |
            @as(u32, register);

        return region.base.add(@intCast(byte_offset)) catch return error.OutOfBounds;
    }
};

pub const unit = struct {
    const testing = std.testing;

    const ecam_len = 6 * 1024 * 1024;

    const Offset = core.Offset;

    test "Ecam.tryFrom rejects empty invalid and duplicate region tables" {
        const base = VirtAddr.from(0x3000);
        const empty: [0]Ecam.Region = .{};

        try testing.expectError(error.NoRegions, Ecam.tryFrom(&empty));

        const invalid = [_]Ecam.Region{.{
            .segment = .{ .segment = .from(1), .buses = .{ .start = 2, .end = 1 } },
            .base = base,
        }};

        try testing.expectError(error.InvalidBusRange, Ecam.tryFrom(&invalid));

        const duplicate = [_]Ecam.Region{
            .{ .segment = .{ .segment = .from(2), .buses = .of(0, 3) }, .base = base },
            .{ .segment = .{ .segment = .from(2), .buses = .of(4, 7) }, .base = base },
        };

        try testing.expectError(error.DuplicateSegment, Ecam.tryFrom(&duplicate));
    }

    test "Ecam.find matches segment id without applying bus containment" {
        const base = VirtAddr.from(0x4000);
        const regions = [_]Ecam.Region{
            .{ .segment = .{ .segment = .from(3), .buses = .of(0x20, 0x2F) }, .base = base },
            .{ .segment = .{ .segment = .from(4), .buses = .of(0x00, 0x0F) }, .base = base },
        };
        const ecam = try Ecam.tryFrom(&regions);

        const outside_bus = ecam.find(Sbdf.from(.from(3), 0x10, 0, 0)) orelse return error.TestUnexpectedResult;

        try testing.expect(outside_bus.segment.segment == core.SegmentId.from(3));
        try testing.expectEqual(@as(u8, 0x20), outside_bus.segment.buses.start);
        try testing.expectEqual(@as(?*const Ecam.Region, null), ecam.find(Sbdf.from(.from(5), 0x20, 0, 0)));
    }

    test "ConfigSpace accesses use bus-relative ECAM addresses for nonzero range starts" {
        const backing = try testing.allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(u32)), ecam_len);
        defer testing.allocator.free(backing);
        @memset(backing, 0);

        const start: u8 = 4;
        const sbdf = Sbdf.from(.from(9), 5, 2, 3);
        const window = ecamWindowOffset(sbdf, start);
        const regions = [_]Ecam.Region{.{
            .segment = .{ .segment = .from(9), .buses = .of(start, 8) },
            .base = backingBase(backing),
        }};
        var ecam = try Ecam.tryFrom(&regions);
        const config = ecam.config();

        try config.write(sbdf, Offset(u8).from(0x24), 0x5A);

        try testing.expectEqual(@as(u8, 0x5A), backing[window + 0x24]);

        try config.write(sbdf, Offset(u16).from(0x26), 0xBEEF);

        try testing.expectEqualSlices(u8, &.{ 0xEF, 0xBE }, backing[window + 0x26 .. window + 0x28]);

        try config.write(sbdf, Offset(u32).from(0x28), 0xCAFE_BABE);

        try testing.expectEqualSlices(u8, &.{ 0xBE, 0xBA, 0xFE, 0xCA }, backing[window + 0x28 .. window + 0x2C]);

        @memset(backing, 0);
        backing[window + 0x30] = 0xA5;
        backing[window + 0x32] = 0x34;
        backing[window + 0x33] = 0x12;
        backing[window + 0x34] = 0x78;
        backing[window + 0x35] = 0x56;
        backing[window + 0x36] = 0x34;
        backing[window + 0x37] = 0x12;

        try testing.expectEqual(@as(u8, 0xA5), try config.read(sbdf, Offset(u8).from(0x30)));
        try testing.expectEqual(@as(u16, 0x1234), try config.read(sbdf, Offset(u16).from(0x32)));
        try testing.expectEqual(@as(u32, 0x1234_5678), try config.read(sbdf, Offset(u32).from(0x34)));

        var last_bus_backing: [core.config.extended_size]u8 align(4) = @splat(0);
        const last_bus_regions = [_]Ecam.Region{.{
            .segment = .{ .segment = .from(9), .buses = .of(0xFF, 0xFF) },
            .base = backingBase(&last_bus_backing),
        }};
        const last_sbdf = Sbdf.from(.from(9), 0xFF, 0, 0);

        try testing.expect(last_bus_regions[0].segment.contains(last_sbdf));
        try testing.expect(!last_bus_regions[0].segment.contains(Sbdf.from(.from(9), 0xFE, 0, 0)));

        var last_bus_ecam = try Ecam.tryFrom(&last_bus_regions);
        const last_bus_config = last_bus_ecam.config();
        const last_offset = Offset(u32).from(0xFFC);

        try last_bus_config.write(last_sbdf, last_offset, 0x1234_5678);

        try testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12 }, last_bus_backing[0xFFC..]);
        try testing.expectEqual(@as(u32, 0x1234_5678), try last_bus_config.read(last_sbdf, last_offset));
    }

    test "ConfigSpace reports OutOfBounds for unknown segments and buses outside the matched segment" {
        var backing: [core.config.extended_size]u8 align(4) = @splat(0);
        const regions = [_]Ecam.Region{.{
            .segment = .{ .segment = .from(1), .buses = .of(0x10, 0x1F) },
            .base = backingBase(&backing),
        }};
        var ecam = try Ecam.tryFrom(&regions);
        const config = ecam.config();

        const byte = Offset(u8).from(0);
        const word = Offset(u16).from(0);
        const dword = Offset(u32).from(0);

        try testing.expectError(error.OutOfBounds, config.read(Sbdf.from(.from(2), 0x10, 0, 0), byte));
        try testing.expectError(error.OutOfBounds, config.read(Sbdf.from(.from(1), 0x20, 0, 0), dword));
        try testing.expectError(error.OutOfBounds, config.write(Sbdf.from(.from(1), 0x0F, 0, 0), word, 0xFFFF));
    }

    fn backingBase(bytes: []u8) VirtAddr {
        return VirtAddr.from(@intFromPtr(bytes.ptr));
    }

    fn ecamWindowOffset(sbdf: Sbdf, start: u8) usize {
        return (@as(usize, sbdf.bdf.bus - start) << 20) |
            (@as(usize, sbdf.bdf.device) << 15) |
            (@as(usize, sbdf.bdf.function) << 12);
    }
};
