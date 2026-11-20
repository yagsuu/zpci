const stdx = @import("stdx");

const extended = @import("extended.zig");

const BitFieldExt = stdx.bits.BitFieldExt;

pub const id: extended.Id = .dpc;

pub const Capabilities = BitFieldExt(u16, .{
    .intr_message = .{ .type = u5, .access = .ro },
    .rp_extensions = .{ .type = bool, .access = .ro },
    .poisoned_tlp_egress_blocking_supported = .{ .type = bool, .access = .ro },
    .software_trigger_supported = .{ .type = bool, .access = .ro },
    .pio_log_size_lo = .{ .type = u4, .access = .ro },
    .dl_active_err_cor_supported = .{ .type = bool, .access = .ro },
    .pio_log_size_hi = .{ .type = bool, .access = .ro },
}, .{ .unnamed = .reserved });

pub const Control = BitFieldExt(u16, .{
    .trigger_mode = .{ .type = TriggerMode, .default = .disabled },
    .completion = .{ .type = Completion, .default = .ca },
    .intr_enable = bool,
    .err_cor_enable = bool,
    .poisoned_tlp_egress_blocking_enable = bool,
    .software_trigger = .{ .type = bool, .write = .trigger },
    .dl_active_err_cor_enable = bool,
    .sig_fw_enable = bool,
}, .{ .unnamed = .reserved });

pub const Status = BitFieldExt(u16, .{
    .triggered = .{ .type = bool, .write = .w1c },
    .reason = .{ .type = Reason, .access = .ro, .default = .uncorrectable },
    .intr_pending = .{ .type = bool, .write = .w1c },
    .rp_busy = .{ .type = bool, .access = .ro },
    .reason_ext = .{ .type = ReasonExt, .access = .ro, .default = .pio },
    .first_error = .{ .offset = 8, .type = pio.ErrorCode, .access = .ro, .default = @as(pio.ErrorCode, @fromBackingInt(@intCast(31))) },
    .sig_fw = .{ .type = bool, .write = .w1c },
}, .{ .unnamed = .reserved });

pub const TriggerMode = enum(u2) {
    disabled = 0,
    fatal = 1,
    non_fatal = 2,
    _,
};

pub const Completion = enum(u1) {
    ca = 0,
    ur = 1,
};

pub const Reason = enum(u2) {
    uncorrectable = 0,
    non_fatal = 1,
    fatal = 2,
    extended = 3,
};

pub const ReasonExt = enum(u2) {
    pio = 0,
    software = 1,
    _,
};

pub const pio = struct {
    pub const Status = Register(.status);
    pub const Mask = Register(.mask);
    pub const Severity = Register(.severity);
    pub const SysError = Register(.sys_error);
    pub const Exception = Register(.exception);

    pub const ErrorCode = enum(u5) {
        cfg_ur = 0,
        cfg_ca = 1,
        cfg_timeout = 2,
        io_ur = 8,
        io_ca = 9,
        io_timeout = 10,
        mem_ur = 16,
        mem_ca = 17,
        mem_timeout = 18,
        _,
    };

    pub const HeaderLog = [4]u32;
    pub const PrefixLog = [4]u32;

    pub const flit = struct {
        pub const HeaderLog = [14]u32;

        pub const offsets = struct {
            pub const header_log = [_]u8{
                0x20, 0x24, 0x28, 0x2C,
                0x34, 0x38, 0x3C, 0x40,
                0x44, 0x48, 0x4C, 0x50,
                0x54, 0x58,
            };
        };
    };

    pub const offsets = struct {
        pub const status: u8 = 0x0C;
        pub const mask: u8 = 0x10;
        pub const severity: u8 = 0x14;
        pub const sys_error: u8 = 0x18;
        pub const exception: u8 = 0x1C;
        pub const header_log = [_]u8{ 0x20, 0x24, 0x28, 0x2C };
        pub const imp_spec_log: u8 = 0x30;
        pub const prefix_log = [_]u8{ 0x34, 0x38, 0x3C, 0x40 };
    };

    fn Register(comptime kind: enum { status, mask, severity, sys_error, exception }) type {
        const error_field = .{ .type = bool, .write = if (kind == .status) .w1c else .assign, .default = kind == .mask };

        return BitFieldExt(u32, .{
            .cfg_ur = error_field,
            .cfg_ca = error_field,
            .cfg_timeout = error_field,
            .io_ur = .{ .offset = 8, .type = bool, .write = error_field.write, .default = error_field.default },
            .io_ca = error_field,
            .io_timeout = error_field,
            .mem_ur = .{ .offset = 16, .type = bool, .write = error_field.write, .default = error_field.default },
            .mem_ca = error_field,
            .mem_timeout = error_field,
        }, .{ .unnamed = .reserved });
    }
};

pub const offsets = struct {
    pub const capabilities: u8 = 0x04;
    pub const control: u8 = 0x06;
    pub const status: u8 = 0x08;
    pub const source_id: u8 = 0x0A;
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "DPC capability fields match PCI bit positions" {
        inline for (.{
            .{ .intr_message, 0x001F },
            .{ .rp_extensions, 0x0020 },
            .{ .poisoned_tlp_egress_blocking_supported, 0x0040 },
            .{ .software_trigger_supported, 0x0080 },
            .{ .pio_log_size_lo, 0x0F00 },
            .{ .dl_active_err_cor_supported, 0x1000 },
            .{ .pio_log_size_hi, 0x2000 },
        }) |case| {
            try testing.expectEqual(@as(u16, case[1]), Capabilities.mask(.{case[0]}));
        }

        try testing.expectEqual(@as(u16, 0), Capabilities.masks.assign);
        try testing.expectEqual(@as(u16, 0xC000), Capabilities.masks.reserved);
    }

    test "DPC control fields and enum encodings match PCI" {
        inline for (.{
            .{ .trigger_mode, 0x0003 },
            .{ .completion, 0x0004 },
            .{ .intr_enable, 0x0008 },
            .{ .err_cor_enable, 0x0010 },
            .{ .poisoned_tlp_egress_blocking_enable, 0x0020 },
            .{ .software_trigger, 0x0040 },
            .{ .dl_active_err_cor_enable, 0x0080 },
            .{ .sig_fw_enable, 0x0100 },
        }) |case| {
            try testing.expectEqual(@as(u16, case[1]), Control.mask(.{case[0]}));
        }

        try testing.expectEqual(@as(u2, 0), @backingInt(TriggerMode.disabled));
        try testing.expectEqual(@as(u2, 1), @backingInt(TriggerMode.fatal));
        try testing.expectEqual(@as(u2, 2), @backingInt(TriggerMode.non_fatal));
        try testing.expectEqual(@as(u1, 0), @backingInt(Completion.ca));
        try testing.expectEqual(@as(u1, 1), @backingInt(Completion.ur));
        try testing.expectEqual(@as(u16, 0), Control.encode(.{}));
        try testing.expectEqual(@as(u16, 0x01BF), Control.masks.assign);
        try testing.expectEqual(@as(u16, 0x0040), Control.masks.trigger);
        try testing.expectEqual(@as(u16, 0), Control.masks.w1c);
        try testing.expectEqual(@as(u16, 0xFE00), Control.masks.reserved);
    }

    test "DPC status separates reasons first error and sticky indications" {
        inline for (.{
            .{ .triggered, 0x0001 },
            .{ .reason, 0x0006 },
            .{ .intr_pending, 0x0008 },
            .{ .rp_busy, 0x0010 },
            .{ .reason_ext, 0x0060 },
            .{ .first_error, 0x1F00 },
            .{ .sig_fw, 0x2000 },
        }) |case| {
            try testing.expectEqual(@as(u16, case[1]), Status.mask(.{case[0]}));
        }

        inline for (.{ Reason.uncorrectable, Reason.non_fatal, Reason.fatal, Reason.extended }, 0..) |reason, i| {
            try testing.expectEqual(@as(u2, @intCast(i)), @backingInt(reason));
        }

        try testing.expectEqual(@as(u2, 0), @backingInt(ReasonExt.pio));
        try testing.expectEqual(@as(u2, 1), @backingInt(ReasonExt.software));
        try testing.expectEqual(@as(u16, 0x1F00), Status.encode(.{}));
        try testing.expectEqual(@as(u16, 0), Status.masks.assign | Status.masks.trigger);
        try testing.expectEqual(@as(u16, 0x2009), Status.masks.w1c);
        try testing.expectEqual(@as(u16, 0xC080), Status.masks.reserved);
    }

    test "PIO error families share PCI positions defaults and access classes" {
        inline for (.{
            .{ .cfg_ur, 0 },
            .{ .cfg_ca, 1 },
            .{ .cfg_timeout, 2 },
            .{ .io_ur, 8 },
            .{ .io_ca, 9 },
            .{ .io_timeout, 10 },
            .{ .mem_ur, 16 },
            .{ .mem_ca, 17 },
            .{ .mem_timeout, 18 },
        }) |case| {
            try testing.expectEqual(@as(u32, 1) << case[1], pio.Status.mask(.{case[0]}));
            try testing.expectEqual(@as(u5, case[1]), @backingInt(@as(pio.ErrorCode, case[0])));
        }

        inline for (.{ pio.Status, pio.Mask, pio.Severity, pio.SysError, pio.Exception }) |T| {
            const sticky = T == pio.Status;

            try testing.expectEqual(@as(u32, if (T == pio.Mask) 0x0007_0707 else 0), T.encode(.{}));
            try testing.expectEqual(@as(u32, if (sticky) 0 else 0x0007_0707), T.masks.assign);
            try testing.expectEqual(@as(u32, if (sticky) 0x0007_0707 else 0), T.masks.w1c);
            try testing.expectEqual(@as(u32, 0), T.masks.trigger);
            try testing.expectEqual(@as(u32, 0xFFF8_F8F8), T.masks.reserved);
        }
    }

    test "DPC offsets keep implementation specific data separate from Flit headers" {
        try testing.expectEqual(@as(u16, 0x001D), @backingInt(id));
        try testing.expectEqualSlices(u8, &.{ 0x04, 0x06, 0x08, 0x0A }, &.{ offsets.capabilities, offsets.control, offsets.status, offsets.source_id });
        try testing.expectEqualSlices(u8, &.{ 0x0C, 0x10, 0x14, 0x18, 0x1C, 0x30 }, &.{ pio.offsets.status, pio.offsets.mask, pio.offsets.severity, pio.offsets.sys_error, pio.offsets.exception, pio.offsets.imp_spec_log });
        try testing.expectEqualSlices(u8, &.{ 0x20, 0x24, 0x28, 0x2C }, &pio.offsets.header_log);
        try testing.expectEqualSlices(u8, &.{ 0x34, 0x38, 0x3C, 0x40 }, &pio.offsets.prefix_log);
        try testing.expectEqualSlices(u8, &.{ 0x20, 0x24, 0x28, 0x2C, 0x34, 0x38, 0x3C, 0x40, 0x44, 0x48, 0x4C, 0x50, 0x54, 0x58 }, &pio.flit.offsets.header_log);
        try testing.expectEqual(@as(usize, 4), @typeInfo(pio.HeaderLog).array.len);
        try testing.expectEqual(@as(usize, 4), @typeInfo(pio.PrefixLog).array.len);
        try testing.expectEqual(@as(usize, 14), @typeInfo(pio.flit.HeaderLog).array.len);
    }
};
