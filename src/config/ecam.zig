//! ECAM config-space backend. Spec: docs/specs/config/ecam.md.

const std = @import("std");

const stdx = @import("stdx");

const accessor = @import("accessor.zig");
const core = @import("../core.zig");

const ConfigSpace = accessor.ConfigSpace;
const SegmentId = core.SegmentId;
const Sbdf = core.Sbdf;
const VirtAddr = stdx.addr.VirtAddr;

pub const Segment = struct {
    segment: SegmentId,
    base: VirtAddr,
    bus_start: u8,
    bus_end: u8,

    pub const Error = error{InvalidBusRange};

    pub fn validate(self: Segment) Error!void {
        if (self.bus_start > self.bus_end) return error.InvalidBusRange;
    }

    pub fn contains(self: Segment, sbdf: Sbdf) bool {
        return self.segment.eql(sbdf.segment) and
            sbdf.bdf.bus >= self.bus_start and
            sbdf.bdf.bus <= self.bus_end;
    }

    pub fn whole(segment: SegmentId, base: VirtAddr) Segment {
        return .{
            .segment = segment,
            .base = base,
            .bus_start = 0,
            .bus_end = 0xFF,
        };
    }
};

pub const Ecam = struct {
    segments: []const Segment,

    pub const Error = Segment.Error || error{
        NoSegments,
        DuplicateSegment,
    };

    pub fn from(segments: []const Segment) Error!Ecam {
        if (segments.len == 0) return error.NoSegments;

        for (segments, 0..) |segment, index| {
            try segment.validate();
            for (segments[0..index]) |previous| {
                if (previous.segment.eql(segment.segment)) return error.DuplicateSegment;
            }
        }

        return .{ .segments = segments };
    }

    pub fn configSpace(self: *Ecam) ConfigSpace {
        return ConfigSpace.init(@ptrCast(self), &vtable);
    }

    pub fn find(self: Ecam, sbdf: Sbdf) ?*const Segment {
        for (self.segments) |*segment| {
            if (segment.segment.eql(sbdf.segment)) return segment;
        }

        return null;
    }

    fn address(self: *Ecam, sbdf: Sbdf, offset: usize) ConfigSpace.Error!VirtAddr {
        if (offset > 0xFFF) return error.OutOfBounds;
        const segment = self.find(sbdf) orelse return error.OutOfBounds;
        if (!segment.contains(sbdf)) return error.OutOfBounds;

        const register: u12 = @intCast(offset);
        const byte_offset = (@as(u32, sbdf.bdf.bus - segment.bus_start) << 20) |
            (@as(u32, sbdf.bdf.device) << 15) |
            (@as(u32, sbdf.bdf.function) << 12) |
            @as(u32, register);
        return segment.base.add(@intCast(byte_offset)) catch return error.OutOfBounds;
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
        const self: *Ecam = @ptrCast(@alignCast(context));
        const ptr: *volatile u8 = @ptrFromInt((try self.address(sbdf, offset)).raw());
        return ptr.*;
    }

    fn read16(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigSpace.Error!u16 {
        const self: *Ecam = @ptrCast(@alignCast(context));
        const ptr: *volatile u16 = @ptrFromInt((try self.address(sbdf, offset)).raw());
        return std.mem.littleToNative(u16, ptr.*);
    }

    fn read32(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigSpace.Error!u32 {
        const self: *Ecam = @ptrCast(@alignCast(context));
        const ptr: *volatile u32 = @ptrFromInt((try self.address(sbdf, offset)).raw());
        return std.mem.littleToNative(u32, ptr.*);
    }

    fn write8(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u8) ConfigSpace.Error!void {
        const self: *Ecam = @ptrCast(@alignCast(context));
        const ptr: *volatile u8 = @ptrFromInt((try self.address(sbdf, offset)).raw());
        ptr.* = value;
    }

    fn write16(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u16) ConfigSpace.Error!void {
        const self: *Ecam = @ptrCast(@alignCast(context));
        const ptr: *volatile u16 = @ptrFromInt((try self.address(sbdf, offset)).raw());
        ptr.* = std.mem.nativeToLittle(u16, value);
    }

    fn write32(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u32) ConfigSpace.Error!void {
        const self: *Ecam = @ptrCast(@alignCast(context));
        const ptr: *volatile u32 = @ptrFromInt((try self.address(sbdf, offset)).raw());
        ptr.* = std.mem.nativeToLittle(u32, value);
    }
};
