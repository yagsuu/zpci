const stdx = @import("stdx");

const extended = @import("extended.zig");

const BitField = stdx.bits.BitField;
const BitFieldExt = stdx.bits.BitFieldExt;

pub const id: extended.Id = .aer;

pub const uncorrectable = struct {
    pub const Status = Register(.status);
    pub const Mask = Register(.mask);
    pub const Severity = Register(.severity);

    pub const ErrorCode = enum(u5) {
        data_link_protocol = 4,
        surprise_down = 5,
        poisoned_tlp = 12,
        flow_control_protocol = 13,
        completion_timeout = 14,
        completer_abort = 15,
        unexpected_completion = 16,
        receiver_overflow = 17,
        malformed_tlp = 18,
        ecrc = 19,
        unsupported_request = 20,
        acs_violation = 21,
        internal = 22,
        multicast_tlp_blocked = 23,
        atomic_egress_blocked = 24,
        tlp_prefix_blocked = 25,
        poisoned_tlp_egress_blocked = 26,
        dmwr_egress_blocked = 27,
        ide_check_failed = 28,
        misrouted_ide_tlp = 29,
        pcrc_check_failed = 30,
        tlp_translation_egress_blocked = 31,
        _,
    };

    pub const offsets = struct {
        pub const status: u8 = 0x04;
        pub const mask: u8 = 0x08;
        pub const severity: u8 = 0x0C;
    };

    fn Register(comptime kind: enum { status, mask, severity }) type {
        const err_field = .{ .type = bool, .write = if (kind == .status) .w1c else .assign };

        return BitFieldExt(u32, .{
            // Mask writes must force bit 0 to 1, even when updating a read word.
            .undefined_bit = .{ .type = bool, .access = .ro, .default = kind == .mask },
            .data_link_protocol = .{ .offset = 4, .type = bool, .write = err_field.write, .default = kind == .severity },
            .surprise_down = .{ .type = bool, .write = err_field.write, .default = kind == .severity },
            .poisoned_tlp = .{ .offset = 12, .type = bool, .write = err_field.write },
            .flow_control_protocol = .{ .type = bool, .write = err_field.write, .default = kind == .severity },
            .completion_timeout = err_field,
            .completer_abort = err_field,
            .unexpected_completion = err_field,
            .receiver_overflow = .{ .type = bool, .write = err_field.write, .default = kind == .severity },
            .malformed_tlp = .{ .type = bool, .write = err_field.write, .default = kind == .severity },
            .ecrc = err_field,
            .unsupported_request = err_field,
            .acs_violation = err_field,
            .internal = .{ .type = bool, .write = err_field.write, .default = kind != .status },
            .multicast_tlp_blocked = err_field,
            .atomic_egress_blocked = err_field,
            .tlp_prefix_blocked = err_field,
            .poisoned_tlp_egress_blocked = .{ .type = bool, .write = err_field.write, .default = kind == .mask },
            .dmwr_egress_blocked = err_field,
            .ide_check_failed = .{ .type = bool, .write = err_field.write, .default = kind == .severity },
            .misrouted_ide_tlp = err_field,
            .pcrc_check_failed = err_field,
            .tlp_translation_egress_blocked = err_field,
        }, .{ .unnamed = .reserved });
    }
};

pub const correctable = struct {
    pub const Status = Register(.status);
    pub const Mask = Register(.mask);

    pub const offsets = struct {
        pub const status: u8 = 0x10;
        pub const mask: u8 = 0x14;
    };

    fn Register(comptime kind: enum { status, mask }) type {
        const error_field = .{ .type = bool, .write = if (kind == .status) .w1c else .assign };

        return BitFieldExt(u32, .{
            .receiver = error_field,
            .bad_tlp = .{ .offset = 6, .type = bool, .write = error_field.write },
            .bad_dllp = error_field,
            .replay_rollover = error_field,
            .replay_timer_timeout = .{ .offset = 12, .type = bool, .write = error_field.write },
            .advisory_non_fatal = .{ .type = bool, .write = error_field.write, .default = kind == .mask },
            .internal = .{ .type = bool, .write = error_field.write, .default = kind == .mask },
            .header_log_overflow = .{ .type = bool, .write = error_field.write, .default = kind == .mask },
        }, .{ .unnamed = .reserved });
    }
};

pub const Control = BitFieldExt(u32, .{
    .first_error = .{ .type = uncorrectable.ErrorCode, .access = .ro, .default = @as(uncorrectable.ErrorCode, @enumFromInt(0)) },
    .ecrc_gen_capable = .{ .type = bool, .access = .ro },
    .ecrc_gen_enable = bool,
    .ecrc_check_capable = .{ .type = bool, .access = .ro },
    .ecrc_check_enable = bool,
    .multi_header_capable = .{ .type = bool, .access = .ro },
    .multi_header_enable = bool,
    .prefix_log_present = .{ .type = bool, .access = .ro },
    .completion_timeout_log_capable = .{ .type = bool, .access = .ro },
    .header_log_size = .{ .type = u5, .access = .ro },
    .logged_tlp_flit = .{ .type = bool, .access = .ro },
    .logged_tlp_size = .{ .type = u5, .access = .ro },
}, .{ .unnamed = .reserved });

pub const root = struct {
    pub const Command = BitFieldExt(u32, .{
        .correctable_enable = bool,
        .non_fatal_enable = bool,
        .fatal_enable = bool,
    }, .{ .unnamed = .reserved });

    pub const Status = BitFieldExt(u32, .{
        .correctable_received = .{ .type = bool, .write = .w1c },
        .multi_correctable_received = .{ .type = bool, .write = .w1c },
        .uncorrectable_received = .{ .type = bool, .write = .w1c },
        .multi_uncorrectable_received = .{ .type = bool, .write = .w1c },
        .first_error_fatal = .{ .type = bool, .write = .w1c },
        .non_fatal_received = .{ .type = bool, .write = .w1c },
        .fatal_received = .{ .type = bool, .write = .w1c },
        .correctable_subclass = .{ .type = CorrectableSubclass, .access = .ro, .default = .legacy },
        .intr_message = .{ .offset = 27, .type = u5, .access = .ro },
    }, .{ .unnamed = .reserved });

    pub const SourceIds = BitField(u32, .{
        .correctable = .{ .type = u16, .access = .ro },
        .uncorrectable = .{ .type = u16, .access = .ro },
    });

    pub const CorrectableSubclass = enum(u2) {
        legacy = 0,
        sig_fw = 1,
        sig_os = 2,
        extended = 3,
    };

    pub const offsets = struct {
        pub const command: u8 = 0x2C;
        pub const status: u8 = 0x30;
        pub const source_ids: u8 = 0x34;
    };
};

pub const HeaderLog = [4]u32;
pub const PrefixLog = [4]u32;

pub const flit = struct {
    pub const HeaderLog = [14]u32;

    pub const offsets = struct {
        pub const header_log = [_]u8{
            0x1C, 0x20, 0x24, 0x28,
            0x38, 0x3C, 0x40, 0x44,
            0x48, 0x4C, 0x50, 0x54,
            0x58, 0x5C,
        };
    };
};

pub const offsets = struct {
    pub const control: u8 = 0x18;
    pub const header_log = [_]u8{ 0x1C, 0x20, 0x24, 0x28 };
    pub const prefix_log = [_]u8{ 0x38, 0x3C, 0x40, 0x44 };
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "uncorrectable error fields and codes match PCI bit positions" {
        inline for (.{
            .{ .data_link_protocol, 4 },
            .{ .surprise_down, 5 },
            .{ .poisoned_tlp, 12 },
            .{ .flow_control_protocol, 13 },
            .{ .completion_timeout, 14 },
            .{ .completer_abort, 15 },
            .{ .unexpected_completion, 16 },
            .{ .receiver_overflow, 17 },
            .{ .malformed_tlp, 18 },
            .{ .ecrc, 19 },
            .{ .unsupported_request, 20 },
            .{ .acs_violation, 21 },
            .{ .internal, 22 },
            .{ .multicast_tlp_blocked, 23 },
            .{ .atomic_egress_blocked, 24 },
            .{ .tlp_prefix_blocked, 25 },
            .{ .poisoned_tlp_egress_blocked, 26 },
            .{ .dmwr_egress_blocked, 27 },
            .{ .ide_check_failed, 28 },
            .{ .misrouted_ide_tlp, 29 },
            .{ .pcrc_check_failed, 30 },
            .{ .tlp_translation_egress_blocked, 31 },
        }) |case| {
            const bit = @as(u32, 1) << case[1];

            try testing.expectEqual(bit, uncorrectable.Status.mask(.{case[0]}));
            try testing.expectEqual(@as(u5, case[1]), @intFromEnum(@as(uncorrectable.ErrorCode, case[0])));
        }
    }

    test "correctable error fields match PCI bit positions" {
        inline for (.{
            .{ .receiver, 0 },
            .{ .bad_tlp, 6 },
            .{ .bad_dllp, 7 },
            .{ .replay_rollover, 8 },
            .{ .replay_timer_timeout, 12 },
            .{ .advisory_non_fatal, 13 },
            .{ .internal, 14 },
            .{ .header_log_overflow, 15 },
        }) |case| {
            const bit = @as(u32, 1) << case[1];

            try testing.expectEqual(bit, correctable.Status.mask(.{case[0]}));
        }
    }

    test "mask and severity defaults match architectural encodings" {
        try testing.expectEqual(@as(u32, 0x0440_0001), uncorrectable.Mask.encode(.{}));
        try testing.expectEqual(@as(u32, 0x1046_2030), uncorrectable.Severity.encode(.{}));
        try testing.expectEqual(@as(u32, 0x0000_E000), correctable.Mask.encode(.{}));
    }

    test "control decodes first error and distinct log capacity mode and length" {
        const control = Control.from(0xFFFC_DFFF);

        try testing.expectEqual(@as(u5, 6), control.header_log_size);
        try testing.expectEqual(@as(u5, 31), control.logged_tlp_size);
        try testing.expect(control.logged_tlp_flit);
        try testing.expectEqual(uncorrectable.ErrorCode.tlp_translation_egress_blocked, control.first_error);
    }

    test "root status decodes correctable subclasses and interrupt message number" {
        const status = root.Status.from(0xFFFF_FFFF);

        try testing.expectEqual(root.CorrectableSubclass.extended, status.correctable_subclass);
        try testing.expectEqual(@as(u5, 31), status.intr_message);

        const firmware = root.Status.from(0x80);
        try testing.expectEqual(root.CorrectableSubclass.sig_fw, firmware.correctable_subclass);

        const os = root.Status.from(0x100);
        try testing.expectEqual(root.CorrectableSubclass.sig_os, os.correctable_subclass);

        const legacy = root.Status.from(0);
        try testing.expectEqual(root.CorrectableSubclass.legacy, legacy.correctable_subclass);
    }

    test "root source IDs place correctable below uncorrectable requester ID" {
        const sources = root.SourceIds.from(0xABCD_1234);

        try testing.expectEqual(@as(u16, 0x1234), sources.correctable);
        try testing.expectEqual(@as(u16, 0xABCD), sources.uncorrectable);
    }

    test "register access masks match AER write and reserved classifications" {
        inline for (.{
            .{ uncorrectable.Status, 0, 0xFFFF_F030, 0x0000_0FCE },
            .{ uncorrectable.Mask, 0xFFFF_F030, 0, 0x0000_0FCE },
            .{ uncorrectable.Severity, 0xFFFF_F030, 0, 0x0000_0FCE },
            .{ correctable.Status, 0, 0x0000_F1C1, 0xFFFF_0E3E },
            .{ correctable.Mask, 0x0000_F1C1, 0, 0xFFFF_0E3E },
            .{ Control, 0x540, 0, 0xFF00_0000 },
            .{ root.Command, 7, 0, 0xFFFF_FFF8 },
            .{ root.Status, 0, 0x7F, 0x07FF_FE00 },
            .{ root.SourceIds, 0, 0, 0 },
        }) |case| {
            const T = case[0];

            try testing.expectEqual(@as(u32, case[1]), T.masks.assign);
            try testing.expectEqual(@as(u32, case[2]), T.masks.w1c);
            try testing.expectEqual(@as(u32, case[3]), T.masks.reserved);
        }
    }

    test "Flit header addressing skips the root register hole" {
        for (flit.offsets.header_log, 0..) |offset, i| {
            const expected = if (i < 4) 0x1C + i * 4 else 0x28 + i * 4;

            try testing.expectEqual(expected, offset);
        }

        try testing.expectEqualSlices(u8, &offsets.header_log, flit.offsets.header_log[0..4]);
        try testing.expectEqualSlices(u8, &offsets.prefix_log, flit.offsets.header_log[4..8]);
    }
};
