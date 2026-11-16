const std = @import("std");

const config = @import("config");
const core = @import("core");

const extended = @import("extended.zig");
const sriov = core.capabilities.sriov;

const Rel8 = core.RelativeOffset(u8);
const Rel16 = core.RelativeOffset(u16);
const Rel32 = core.RelativeOffset(u32);

const Function = config.Function;
const Entry = extended.Entry;
const Registers = extended.Registers;
const Control = sriov.Control.Word;

pub const Error = extended.Error || error{
    InvalidValue,
    ActiveVfs,
    BusRangeExhausted,
    ProgrammingReadbackMismatch,
    ProgrammingPartial,
};

pub const Capability = struct {
    registers: Registers,

    pub fn tryFrom(function: Function, entry: Entry) Error!Capability {
        std.debug.assert(entry.id == sriov.id);

        const registers = try Registers.tryFrom(function, entry.offset);
        if (!registers.contains(offsets.migration_array)) {
            return error.MalformedCapability;
        }

        return .{ .registers = registers };
    }

    pub fn find(function: Function) Error!?Capability {
        const entry = (try extended.find(function, sriov.id)) orelse return null;
        return try Capability.tryFrom(function, entry);
    }

    pub fn control(self: Capability) Error!Control {
        return sriov.Control.from(try self.registers.read(offsets.control));
    }

    pub fn totalVfs(self: Capability) Error!u16 {
        return self.registers.read(offsets.total_vfs);
    }

    pub fn setAriHierarchy(self: Capability, enabled: bool) Error!void {
        const raw = try self.registers.read(offsets.control);
        if (sriov.Control.from(raw).vf_enable) {
            return error.ActiveVfs;
        }

        const ctl = sriov.Control.replace(sriov.Control.from(raw), .{ .ari_hierarchy = enabled });
        const updated = sriov.Control.raw(ctl);

        if (updated == raw) {
            return;
        }

        try self.registers.write(offsets.control, updated);
        if (try self.registers.read(offsets.control) != updated) {
            return error.ProgrammingReadbackMismatch;
        }
    }

    pub fn reserveBuses(self: Capability, capacity: u16) Error!u8 {
        if ((try self.control()).vf_enable) {
            return error.ActiveVfs;
        }

        const result = self.probeBuses(capacity);
        self.setNumVfs(0) catch return error.ProgrammingPartial;
        return result;
    }

    fn probeBuses(self: Capability, capacity: u16) Error!u8 {
        try self.setNumVfs(0);

        if (capacity > try self.totalVfs()) {
            return error.InvalidValue;
        }

        const bdf = self.registers.function.sbdf.bdf;

        var highest = bdf.bus;
        var count: u32 = 1;
        while (count <= capacity) : (count += 1) {
            try self.setNumVfs(@intCast(count));

            const offset = try self.registers.read(offsets.first_vf_offset);
            const stride = try self.registers.read(offsets.vf_stride);

            if (offset == 0 or (count > 1 and stride == 0)) {
                return error.InvalidValue;
            }

            const last = @as(u64, bdf.raw()) + offset + @as(u64, stride) * (count - 1);
            if (last > std.math.maxInt(u16)) {
                return error.BusRangeExhausted;
            }

            const bus: u8 = @intCast(last >> 8);
            if (bus < bdf.bus) {
                return error.BusRangeExhausted;
            }

            highest = @max(highest, bus);
        }

        return highest;
    }

    fn setNumVfs(self: Capability, count: u16) Error!void {
        try self.registers.write(offsets.num_vfs, count);
        if (try self.registers.read(offsets.num_vfs) != count) {
            return error.ProgrammingReadbackMismatch;
        }
    }
};

pub const offsets = struct {
    pub const capabilities = Rel32.from(sriov.offsets.capabilities);
    pub const control = Rel16.from(sriov.offsets.control);
    pub const status = Rel16.from(sriov.offsets.status);
    pub const initial_vfs = Rel16.from(sriov.offsets.initial_vfs);
    pub const total_vfs = Rel16.from(sriov.offsets.total_vfs);
    pub const num_vfs = Rel16.from(sriov.offsets.num_vfs);
    pub const function_dependency = Rel8.from(sriov.offsets.function_dependency);
    pub const first_vf_offset = Rel16.from(sriov.offsets.first_vf_offset);
    pub const vf_stride = Rel16.from(sriov.offsets.vf_stride);
    pub const vf_device_id = Rel16.from(sriov.offsets.vf_device_id);
    pub const supported_page_sizes = Rel32.from(sriov.offsets.supported_page_sizes);
    pub const system_page_size = Rel32.from(sriov.offsets.system_page_size);
    pub const vf_bar0 = Rel32.from(sriov.offsets.vf_bar0);
    pub const vf_bar1 = Rel32.from(sriov.offsets.vf_bar1);
    pub const vf_bar2 = Rel32.from(sriov.offsets.vf_bar2);
    pub const vf_bar3 = Rel32.from(sriov.offsets.vf_bar3);
    pub const vf_bar4 = Rel32.from(sriov.offsets.vf_bar4);
    pub const vf_bar5 = Rel32.from(sriov.offsets.vf_bar5);
    pub const migration_array = Rel32.from(sriov.offsets.migration_array);
};

pub const unit = struct {
    const testing = std.testing;

    const ConfigSpace = config.ConfigSpace;
    const ConfigError = ConfigSpace.Error;
    const Sbdf = core.Sbdf;

    const base: u16 = 0x100;

    const Backend = struct {
        control: u16 = 0,
        total: u16 = 3,
        num: u16 = 0xFFFF,
        first: [4]u16 = .{ 0, 0x400, 1, 1 },
        stride: [4]u16 = .{ 0, 0, 1, 1 },
        writes: [16]u16 = @splat(0),
        write_count: usize = 0,
        num_reads: usize = 0,
        fail_write: ?usize = null,
        fail_num_read: ?usize = null,
        reject_write: ?usize = null,
        fail_offset: bool = false,
        fail_total: bool = false,
        bus: u8 = 2,
        device: u5 = 0,
        function: u3 = 0,

        fn capability(self: *Backend) Capability {
            return .{ .registers = .{
                .function = Function.from(ConfigSpace.from(self, &vtable), Sbdf.from(core.SegmentId.from(0), self.bus, self.device, self.function)),
                .base = base,
            } };
        }

        const vtable: ConfigSpace.VTable = .{
            .read8 = read8,
            .read16 = read16,
            .read32 = read32,
            .write8 = write8,
            .write16 = write16,
            .write32 = write32,
        };

        fn read8(_: *anyopaque, _: Sbdf, _: usize) ConfigError!u8 {
            return error.UnsupportedAccessWidth;
        }

        fn read32(_: *anyopaque, _: Sbdf, offset: usize) ConfigError!u32 {
            if (offset == base) {
                return 0x0001_0010;
            }

            return error.UnsupportedAccessWidth;
        }

        fn read16(context: *anyopaque, _: Sbdf, offset: usize) ConfigError!u16 {
            const self: *Backend = @ptrCast(@alignCast(context));
            switch (offset - base) {
                sriov.offsets.control => return self.control,
                sriov.offsets.total_vfs => {
                    if (self.fail_total) {
                        return error.OutOfBounds;
                    }

                    return self.total;
                },
                sriov.offsets.num_vfs => {
                    self.num_reads += 1;
                    if (self.fail_num_read == self.num_reads) {
                        return error.OutOfBounds;
                    }

                    return self.num;
                },
                sriov.offsets.first_vf_offset => {
                    if (self.fail_offset) {
                        return error.OutOfBounds;
                    }

                    return self.first[@min(self.num, 3)];
                },
                sriov.offsets.vf_stride => return self.stride[@min(self.num, 3)],
                else => return error.UnsupportedAccessWidth,
            }
        }

        fn write8(_: *anyopaque, _: Sbdf, _: usize, _: u8) ConfigError!void {
            return error.UnsupportedAccessWidth;
        }

        fn write32(_: *anyopaque, _: Sbdf, _: usize, _: u32) ConfigError!void {
            return error.UnsupportedAccessWidth;
        }

        fn write16(context: *anyopaque, _: Sbdf, offset: usize, value: u16) ConfigError!void {
            const self: *Backend = @ptrCast(@alignCast(context));
            self.write_count += 1;
            if (self.write_count <= self.writes.len) {
                self.writes[self.write_count - 1] = value;
            }
            if (self.fail_write == self.write_count) {
                return error.OutOfBounds;
            }

            if (self.reject_write == self.write_count) {
                return;
            }

            switch (offset - base) {
                sriov.offsets.control => self.control = value,
                sriov.offsets.num_vfs => self.num = value,
                else => return error.UnsupportedAccessWidth,
            }
        }
    };

    test "SR-IOV discovery validates the complete capability extent" {
        var backend: Backend = .{};
        try testing.expect((try Capability.find(backend.capability().registers.function)) != null);
        try testing.expectError(error.MalformedCapability, Capability.tryFrom(backend.capability().registers.function, .{ .id = .sriov, .version = 1, .offset = 0xFE0 }));
    }

    test "SR-IOV probes all counts and reserves the nonmonotonic maximum" {
        var backend: Backend = .{};
        try testing.expectEqual(@as(u8, 6), try backend.capability().reserveBuses(3));
        try testing.expectEqualSlices(u16, &.{ 0, 1, 2, 3, 0 }, backend.writes[0..backend.write_count]);
        try testing.expectEqual(@as(u16, 0), backend.num);
    }

    test "SR-IOV zero capacity normalizes undefined NumVFs without consulting InitialVFs" {
        var backend: Backend = .{};
        try testing.expectEqual(@as(u8, 2), try backend.capability().reserveBuses(0));
        try testing.expectEqualSlices(u16, &.{ 0, 0 }, backend.writes[0..backend.write_count]);
        try testing.expectEqual(@as(u16, 0), backend.num);
    }

    test "SR-IOV supports the full u16 VF count without loop overflow" {
        var backend: Backend = .{
            .bus = 0,
            .total = 65535,
            .first = .{ 0, 1, 1, 1 },
            .stride = .{ 0, 0, 1, 1 },
        };

        try testing.expectEqual(@as(u8, 255), try backend.capability().reserveBuses(65535));
        try testing.expectEqual(@as(usize, 65537), backend.write_count);
        try testing.expectEqual(@as(u16, 0), backend.num);
    }

    test "SR-IOV active VFs reject reservation and hierarchy changes without writes" {
        var backend: Backend = .{ .control = 1 };
        try testing.expectError(error.ActiveVfs, backend.capability().reserveBuses(0));
        try testing.expectError(error.ActiveVfs, backend.capability().setAriHierarchy(true));
        try testing.expectEqual(@as(usize, 0), backend.write_count);
        try testing.expectEqual(@as(u16, 0xFFFF), backend.num);
    }

    test "SR-IOV rejects counts beyond TotalVFs and clears NumVFs" {
        var backend: Backend = .{};
        try testing.expectError(error.InvalidValue, backend.capability().reserveBuses(4));
        try testing.expectEqual(@as(u16, 0), backend.num);
        try testing.expectEqualSlices(u16, &.{ 0, 0 }, backend.writes[0..backend.write_count]);
    }

    test "SR-IOV validates offsets and multi-VF stride after each count" {
        var zero_offset: Backend = .{ .first = .{ 0, 0, 1, 1 } };
        try testing.expectError(error.InvalidValue, zero_offset.capability().reserveBuses(1));
        try testing.expectEqual(@as(u16, 0), zero_offset.num);

        var zero_stride: Backend = .{ .stride = .{ 0, 0, 0, 1 } };
        try testing.expectError(error.InvalidValue, zero_stride.capability().reserveBuses(2));
        try testing.expectEqual(@as(u16, 0), zero_stride.num);
    }

    test "SR-IOV RID includes device and function and accepts the final RID" {
        var backend: Backend = .{ .bus = 255, .device = 31, .function = 6, .first = .{ 0, 1, 1, 1 } };
        try testing.expectEqual(@as(u8, 255), try backend.capability().reserveBuses(1));
        try testing.expectError(error.BusRangeExhausted, backend.capability().reserveBuses(2));
        try testing.expectEqual(@as(u16, 0), backend.num);
    }

    test "SR-IOV widened RID arithmetic rejects very large spans" {
        var backend: Backend = .{ .first = .{ 0, 1, 1, 1 }, .stride = .{ 0, 0, 0xFFFF, 0xFFFF } };
        try testing.expectError(error.BusRangeExhausted, backend.capability().reserveBuses(3));
        try testing.expectEqual(@as(u16, 0), backend.num);
    }

    test "SR-IOV preserves primary read and write errors after successful cleanup" {
        var offset_failure: Backend = .{ .fail_offset = true };
        try testing.expectError(error.OutOfBounds, offset_failure.capability().reserveBuses(2));
        try testing.expectEqual(@as(u16, 0), offset_failure.num);

        var total_failure: Backend = .{ .fail_total = true };
        try testing.expectError(error.OutOfBounds, total_failure.capability().reserveBuses(2));
        try testing.expectEqual(@as(u16, 0), total_failure.num);

        var write_failure: Backend = .{ .fail_write = 2 };
        try testing.expectError(error.OutOfBounds, write_failure.capability().reserveBuses(2));
        try testing.expectEqual(@as(u16, 0), write_failure.num);

        var initial_failure: Backend = .{ .fail_write = 1 };
        try testing.expectError(error.OutOfBounds, initial_failure.capability().reserveBuses(2));
        try testing.expectEqual(@as(u16, 0), initial_failure.num);
    }

    test "SR-IOV detects rejected writes and cleans up failed readbacks" {
        var rejected: Backend = .{ .reject_write = 2 };
        try testing.expectError(error.ProgrammingReadbackMismatch, rejected.capability().reserveBuses(2));
        try testing.expectEqual(@as(u16, 0), rejected.num);

        var failed_read: Backend = .{ .fail_num_read = 2 };
        try testing.expectError(error.OutOfBounds, failed_read.capability().reserveBuses(2));
        try testing.expectEqual(@as(u16, 0), failed_read.num);
    }

    test "SR-IOV cleanup failure takes precedence over primary errors and success" {
        var failed_write: Backend = .{ .fail_offset = true, .fail_write = 3 };
        try testing.expectError(error.ProgrammingPartial, failed_write.capability().reserveBuses(1));

        var failed_read: Backend = .{ .fail_offset = true, .fail_num_read = 3 };
        try testing.expectError(error.ProgrammingPartial, failed_read.capability().reserveBuses(1));

        var rejected: Backend = .{ .reject_write = 3 };
        try testing.expectError(error.ProgrammingPartial, rejected.capability().reserveBuses(1));

        var success: Backend = .{ .fail_write = 3 };
        try testing.expectError(error.ProgrammingPartial, success.capability().reserveBuses(1));
    }

    test "SR-IOV hierarchy updates preserve all unrelated control bits" {
        var backend: Backend = .{ .control = 0xA06E };
        try backend.capability().setAriHierarchy(true);
        try testing.expectEqual(@as(u16, 0xA07E), backend.control);
        try backend.capability().setAriHierarchy(false);
        try testing.expectEqual(@as(u16, 0xA06E), backend.control);

        const writes = backend.write_count;
        try backend.capability().setAriHierarchy(false);
        try testing.expectEqual(writes, backend.write_count);

        var rejected: Backend = .{ .reject_write = 1 };
        try testing.expectError(error.ProgrammingReadbackMismatch, rejected.capability().setAriHierarchy(true));
    }
};
