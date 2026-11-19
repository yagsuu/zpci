const std = @import("std");

const config = @import("config");
const core = @import("core");

const extended = @import("extended.zig");

const aer = core.capabilities.aer;
const root = aer.root;
const correctable = aer.correctable;
const uncorrectable = aer.uncorrectable;

const Rel32 = core.RelativeOffset(u32);

const Function = config.Function;
const Entry = extended.Entry;
const Registers = extended.Registers;
const UncorrectableStatus = uncorrectable.Status.Word;
const UncorrectableMask = uncorrectable.Mask.Word;
const UncorrectableMaskArgs = uncorrectable.Mask.AssignArgs;
const UncorrectableSeverity = uncorrectable.Severity.Word;
const UncorrectableSeverityArgs = uncorrectable.Severity.AssignArgs;
const CorrectableStatus = correctable.Status.Word;
const CorrectableMask = correctable.Mask.Word;
const CorrectableMaskArgs = correctable.Mask.AssignArgs;
const Control = aer.Control.Word;
const ControlArgs = aer.Control.AssignArgs;
const RootCommand = root.Command.Word;
const RootCommandArgs = root.Command.AssignArgs;
const RootStatus = root.Status.Word;
const RootSourceIds = root.SourceIds.Word;
const PcieCapabilities = core.capabilities.pcie.Capabilities.Word;

pub const Error = extended.Error;
pub const LogError = Error || error{UnexpectedLogMode};

pub const Capability = struct {
    registers: Registers,

    pub fn tryFrom(function: Function, entry: Entry) Error!Capability {
        std.debug.assert(entry.id == aer.id);

        const registers = try Registers.tryFrom(function, entry.offset);
        if (!registers.contains(offsets.header_log[3])) {
            return error.MalformedCapability;
        }

        return .{ .registers = registers };
    }

    pub fn find(function: Function) Error!?Capability {
        const entry = (try extended.find(function, aer.id)) orelse return null;
        return try Capability.tryFrom(function, entry);
    }

    pub fn uncorrectableStatus(self: Capability) Error!UncorrectableStatus {
        return uncorrectable.Status.from(try self.registers.read(offsets.uncorrectable.status));
    }

    pub fn ackUncorrectableStatus(self: Capability, observed: UncorrectableStatus, comptime fields: anytype) Error!void {
        return self.registers.write(offsets.uncorrectable.status, uncorrectable.Status.ack(observed, fields));
    }

    pub fn ackFirstError(self: Capability, status: UncorrectableStatus, observed_control: Control) Error!void {
        const bit = @as(u32, 1) << @intFromEnum(observed_control.first_error);
        const selected = uncorrectable.Status.raw(status) & uncorrectable.Status.masks.w1c & bit;

        if (selected == 0) {
            return;
        }

        return self.registers.write(offsets.uncorrectable.status, selected);
    }

    pub fn uncorrectableMask(self: Capability) Error!UncorrectableMask {
        return uncorrectable.Mask.from(try self.registers.read(offsets.uncorrectable.mask));
    }

    pub fn updateUncorrectableMask(self: Capability, args: UncorrectableMaskArgs) Error!void {
        const observed = try self.uncorrectableMask();
        var updated = uncorrectable.Mask.replace(observed, args);
        updated.undefined_bit = true;

        return self.registers.write(offsets.uncorrectable.mask, uncorrectable.Mask.raw(updated));
    }

    pub fn uncorrectableSeverity(self: Capability) Error!UncorrectableSeverity {
        return uncorrectable.Severity.from(try self.registers.read(offsets.uncorrectable.severity));
    }

    pub fn updateUncorrectableSeverity(self: Capability, args: UncorrectableSeverityArgs) Error!void {
        const observed = try self.uncorrectableSeverity();
        const updated = uncorrectable.Severity.replace(observed, args);

        return self.registers.write(offsets.uncorrectable.severity, uncorrectable.Severity.raw(updated));
    }

    pub fn correctableStatus(self: Capability) Error!CorrectableStatus {
        return correctable.Status.from(try self.registers.read(offsets.correctable.status));
    }

    pub fn ackCorrectableStatus(self: Capability, observed: CorrectableStatus, comptime fields: anytype) Error!void {
        return self.registers.write(offsets.correctable.status, correctable.Status.ack(observed, fields));
    }

    pub fn correctableMask(self: Capability) Error!CorrectableMask {
        return correctable.Mask.from(try self.registers.read(offsets.correctable.mask));
    }

    pub fn updateCorrectableMask(self: Capability, args: CorrectableMaskArgs) Error!void {
        const observed = try self.correctableMask();
        const updated = correctable.Mask.replace(observed, args);

        return self.registers.write(offsets.correctable.mask, correctable.Mask.raw(updated));
    }

    pub fn control(self: Capability) Error!Control {
        return aer.Control.from(try self.registers.read(offsets.control));
    }

    pub fn updateControl(self: Capability, args: ControlArgs) Error!void {
        const observed = try self.control();
        const updated = aer.Control.replace(observed, args);

        return self.registers.write(offsets.control, aer.Control.raw(updated));
    }

    pub fn headerLog(self: Capability, args: LogArgs) LogError!?aer.HeaderLog {
        if (!try args.defaultAvailable()) {
            return null;
        }

        var words: aer.HeaderLog = undefined;
        for (&words, offsets.header_log) |*word, offset| {
            word.* = try self.registers.read(offset);
        }

        if (std.mem.allEqual(u32, &words, 0xFFFF_FFFF)) {
            return null;
        }

        return words;
    }

    pub fn prefixLog(self: Capability, args: LogArgs) LogError!?aer.PrefixLog {
        if (!try args.defaultAvailable() or !args.control.prefix_log_present) {
            return null;
        }

        if (args.pcie.flit_mode_supported and args.control.header_log_size < 8) {
            return error.MalformedCapability;
        }

        if (!self.registers.contains(offsets.prefix_log[3])) {
            return error.MalformedCapability;
        }

        var words: aer.PrefixLog = undefined;
        for (&words, offsets.prefix_log) |*word, offset| {
            word.* = try self.registers.read(offset);
        }

        return words;
    }

    pub fn rootCommand(self: Capability) Error!RootCommand {
        return root.Command.from(try self.registers.read(offsets.root.command));
    }

    pub fn updateRootCommand(self: Capability, args: RootCommandArgs) Error!void {
        const observed = try self.rootCommand();
        const updated = root.Command.replace(observed, args);

        return self.registers.write(offsets.root.command, root.Command.raw(updated));
    }

    pub fn rootStatus(self: Capability) Error!RootStatus {
        return root.Status.from(try self.registers.read(offsets.root.status));
    }

    pub fn ackRootStatus(self: Capability, observed: RootStatus, comptime fields: anytype) Error!void {
        return self.registers.write(offsets.root.status, root.Status.ack(observed, fields));
    }

    pub fn rootSourceIds(self: Capability) Error!RootSourceIds {
        return root.SourceIds.from(try self.registers.read(offsets.root.source_ids));
    }
};

pub const LogArgs = struct {
    pcie: PcieCapabilities,
    control: Control,
    status: UncorrectableStatus,

    fn hasError(self: LogArgs) bool {
        const bit = @as(u32, 1) << @intFromEnum(self.control.first_error);
        return uncorrectable.Status.raw(self.status) & uncorrectable.Status.masks.w1c & bit != 0;
    }

    fn hasLog(self: LogArgs) bool {
        if (!self.hasError()) {
            return false;
        }

        return switch (self.control.first_error) {
            .data_link_protocol,
            .surprise_down,
            .flow_control_protocol,
            .receiver_overflow,
            => false,
            .completion_timeout => self.control.completion_timeout_log_capable,
            else => true,
        };
    }

    fn defaultAvailable(self: LogArgs) LogError!bool {
        if (!self.hasLog()) {
            return false;
        }

        if (self.pcie.flit_mode_supported) {
            if (self.control.logged_tlp_flit) {
                return error.UnexpectedLogMode;
            }

            if (self.control.logged_tlp_size == 0) {
                return false;
            }

            if (self.control.header_log_size < 4 or self.control.logged_tlp_size > self.control.header_log_size) {
                return error.MalformedCapability;
            }
        }

        return true;
    }
};

pub const flit = struct {
    pub const HeaderLog = struct {
        words: aer.flit.HeaderLog,
        len: u4,

        pub fn slice(self: *const HeaderLog) []const u32 {
            return self.words[0..self.len];
        }
    };

    pub fn headerLog(cap: Capability, args: LogArgs) LogError!?HeaderLog {
        if (!args.hasLog()) {
            return null;
        }

        if (!args.pcie.flit_mode_supported or !args.control.logged_tlp_flit) {
            return error.UnexpectedLogMode;
        }

        const len = args.control.logged_tlp_size;
        if (len == 0) {
            return null;
        }

        if (args.control.header_log_size < 4 or len > args.control.header_log_size or len > flit.offsets.header_log.len) {
            return error.MalformedCapability;
        }

        if (!cap.registers.contains(flit.offsets.header_log[len - 1])) {
            return error.MalformedCapability;
        }

        var log: HeaderLog = .{ .words = undefined, .len = @intCast(len) };
        for (log.words[0..len], flit.offsets.header_log[0..len]) |*word, offset| {
            word.* = try cap.registers.read(offset);
        }

        if (std.mem.allEqual(u32, log.slice(), 0xFFFF_FFFF)) {
            return null;
        }

        return log;
    }

    pub const offsets = struct {
        pub const header_log = values: {
            var values: [aer.flit.offsets.header_log.len]Rel32 = undefined;
            for (&values, aer.flit.offsets.header_log) |*value, offset| {
                value.* = .from(offset);
            }

            break :values values;
        };
    };
};

pub const offsets = struct {
    pub const control = Rel32.from(aer.offsets.control);

    pub const header_log = values: {
        var values: [aer.offsets.header_log.len]Rel32 = undefined;
        for (&values, aer.offsets.header_log) |*value, offset| {
            value.* = .from(offset);
        }

        break :values values;
    };

    pub const prefix_log = values: {
        var values: [aer.offsets.prefix_log.len]Rel32 = undefined;
        for (&values, aer.offsets.prefix_log) |*value, offset| {
            value.* = .from(offset);
        }

        break :values values;
    };

    pub const uncorrectable = struct {
        pub const status = Rel32.from(aer.uncorrectable.offsets.status);
        pub const mask = Rel32.from(aer.uncorrectable.offsets.mask);
        pub const severity = Rel32.from(aer.uncorrectable.offsets.severity);
    };

    pub const correctable = struct {
        pub const status = Rel32.from(aer.correctable.offsets.status);
        pub const mask = Rel32.from(aer.correctable.offsets.mask);
    };

    pub const root = struct {
        pub const command = Rel32.from(aer.root.offsets.command);
        pub const status = Rel32.from(aer.root.offsets.status);
        pub const source_ids = Rel32.from(aer.root.offsets.source_ids);
    };
};

pub const unit = struct {
    const testing = std.testing;

    const ConfigSpace = config.ConfigSpace;
    const ConfigError = ConfigSpace.Error;
    const Sbdf = core.Sbdf;

    const address = Sbdf.from(.from(0), 2, 3, 0);
    const base = 0x100;
    const log_args: LogArgs = .{
        .pcie = .{},
        .control = .{ .first_error = .malformed_tlp },
        .status = .{ .malformed_tlp = true },
    };

    const ErrorRecord = struct {
        control: Control,
        header: aer.HeaderLog,
    };

    const ConfigBackend = struct {
        bytes: [core.config.extended_size]u8 = @splat(0),
        reads: usize = 0,
        writes: usize = 0,
        fail_read: bool = false,
        fail_write: bool = false,
        last_offset: usize = 0,
        last_value: u32 = 0,
        read_offsets: [32]usize = undefined,
        fail_offset: ?usize = null,
        records: []const ErrorRecord = &.{},
        record_index: usize = 0,

        const vtable: ConfigSpace.VTable = .{
            .read8 = read8,
            .read16 = read16,
            .read32 = read32,
            .write8 = write8,
            .write16 = write16,
            .write32 = write32,
        };

        fn config(self: *ConfigBackend) ConfigSpace {
            return ConfigSpace.from(@ptrCast(self), &vtable);
        }

        fn capability(self: *ConfigBackend) Error!Capability {
            return Capability.tryFrom(Function.from(self.config(), address), .{
                .id = aer.id,
                .version = 3,
                .offset = base,
            });
        }

        fn seedRecords(self: *ConfigBackend, records: []const ErrorRecord) void {
            self.records = records;
            self.record_index = 0;

            var status: u32 = 0;
            for (records) |record| {
                status |= @as(u32, 1) << @intFromEnum(record.control.first_error);
            }

            store32(&self.bytes, 0x104, status);
            self.loadRecord();
        }

        fn loadRecord(self: *ConfigBackend) void {
            if (self.record_index == self.records.len) {
                store32(&self.bytes, 0x118, 0);
                return;
            }

            const record = self.records[self.record_index];
            store32(&self.bytes, 0x118, aer.Control.raw(record.control));

            for (record.header, 0..) |word, i| {
                store32(&self.bytes, 0x11C + i * 4, word);
            }
        }

        fn read8(_: *anyopaque, _: Sbdf, _: usize) ConfigError!u8 {
            return error.UnsupportedAccessWidth;
        }

        fn read16(_: *anyopaque, _: Sbdf, _: usize) ConfigError!u16 {
            return error.UnsupportedAccessWidth;
        }

        fn write8(_: *anyopaque, _: Sbdf, _: usize, _: u8) ConfigError!void {
            return error.UnsupportedAccessWidth;
        }

        fn write16(_: *anyopaque, _: Sbdf, _: usize, _: u16) ConfigError!void {
            return error.UnsupportedAccessWidth;
        }

        fn read32(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigError!u32 {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            std.debug.assert(address.eql(sbdf));
            self.read_offsets[self.reads] = offset;
            self.reads += 1;

            if (self.fail_read or self.fail_offset == offset) {
                return error.UnsupportedAccessWidth;
            }

            return std.mem.readInt(u32, self.bytes[offset..][0..4], .little);
        }

        fn write32(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u32) ConfigError!void {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            std.debug.assert(address.eql(sbdf));
            self.writes += 1;

            if (self.fail_write) {
                return error.UnsupportedAccessWidth;
            }

            self.last_offset = offset;
            self.last_value = value;

            if (offset == 0x104 and self.record_index < self.records.len) {
                const status = std.mem.readInt(u32, self.bytes[0x104..0x108], .little);
                store32(&self.bytes, 0x104, status & ~value);

                const record = self.records[self.record_index];
                const bit = @as(u32, 1) << @intFromEnum(record.control.first_error);

                if (value & bit != 0) {
                    self.record_index += 1;
                    self.loadRecord();
                }
            }
        }
    };

    test "AER discovery distinguishes absence and rebases live register reads" {
        var backend: ConfigBackend = .{};
        const function = Function.from(backend.config(), address);

        try testing.expectEqual(@as(?Capability, null), try Capability.find(function));

        store32(&backend.bytes, base, 0x0003_0001);
        store32(&backend.bytes, 0x104, 1 << 14);
        store32(&backend.bytes, 0x108, 1 << 20);
        store32(&backend.bytes, 0x10C, 1 << 18);
        store32(&backend.bytes, 0x110, 1 << 6);
        store32(&backend.bytes, 0x114, 1 << 7);
        store32(&backend.bytes, 0x118, 1 << 6);
        store32(&backend.bytes, 0x12C, 4);
        store32(&backend.bytes, 0x130, 1 << 6);
        store32(&backend.bytes, 0x134, 0xABCD_1234);

        const cap = (try Capability.find(function)).?;

        try testing.expect((try cap.uncorrectableStatus()).completion_timeout);
        try testing.expect((try cap.uncorrectableMask()).unsupported_request);
        try testing.expect((try cap.uncorrectableSeverity()).malformed_tlp);
        try testing.expect((try cap.correctableStatus()).bad_tlp);
        try testing.expect((try cap.correctableMask()).bad_dllp);
        try testing.expect((try cap.control()).ecrc_gen_enable);
        try testing.expect((try cap.rootCommand()).fatal_enable);
        try testing.expect((try cap.rootStatus()).fatal_received);

        const sources = try cap.rootSourceIds();
        try testing.expectEqual(@as(u16, 0x1234), sources.correctable);
        try testing.expectEqual(@as(u16, 0xABCD), sources.uncorrectable);

        store32(&backend.bytes, 0x104, 0);
        try testing.expect(!(try cap.uncorrectableStatus()).completion_timeout);
    }

    test "AER updates preserve observed fields and force uncorrectable mask bit zero" {
        var backend: ConfigBackend = .{};
        const cap = try backend.capability();

        store32(&backend.bytes, 0x108, 0x8000_0FCE);
        try cap.updateUncorrectableMask(.{ .completion_timeout = true });
        try testing.expectEqual(@as(u32, 0x8000_4FCF), backend.last_value);
        try testing.expectEqual(@as(usize, 0x108), backend.last_offset);

        store32(&backend.bytes, 0x108, 0);
        try cap.updateUncorrectableMask(.{});
        try testing.expectEqual(@as(u32, 1), backend.last_value);

        store32(&backend.bytes, 0x10C, 0x8000_0001);
        try cap.updateUncorrectableSeverity(.{ .completion_timeout = true });
        try testing.expectEqual(@as(u32, 0x8000_4001), backend.last_value);
        try testing.expectEqual(@as(usize, 0x10C), backend.last_offset);

        store32(&backend.bytes, 0x114, 0x8000_0040);
        try cap.updateCorrectableMask(.{ .bad_tlp = false, .bad_dllp = true });
        try testing.expectEqual(@as(u32, 0x8000_0080), backend.last_value);
        try testing.expectEqual(@as(usize, 0x114), backend.last_offset);

        store32(&backend.bytes, 0x118, 0x8000_00BF);
        try cap.updateControl(.{ .ecrc_gen_enable = true });
        try testing.expectEqual(@as(u32, 0x8000_00FF), backend.last_value);
        try testing.expectEqual(@as(usize, 0x118), backend.last_offset);

        store32(&backend.bytes, 0x12C, 0x8000_0001);
        try cap.updateRootCommand(.{ .correctable_enable = false, .fatal_enable = true });
        try testing.expectEqual(@as(u32, 0x8000_0004), backend.last_value);
        try testing.expectEqual(@as(usize, 0x12C), backend.last_offset);

        try testing.expectEqual(@as(usize, 6), backend.reads);
        try testing.expectEqual(@as(usize, 6), backend.writes);
    }

    test "AER acknowledgements write selected observations without rereading status" {
        var backend: ConfigBackend = .{ .fail_read = true };
        const cap = try backend.capability();

        try cap.ackUncorrectableStatus(uncorrectable.Status.from(0xFFFF_FFFF), .{.completion_timeout});
        try testing.expectEqual(@as(u32, 0x4000), backend.last_value);
        try testing.expectEqual(@as(usize, 0x104), backend.last_offset);

        try cap.ackCorrectableStatus(correctable.Status.from(0x40), .{ .bad_tlp, .bad_dllp });
        try testing.expectEqual(@as(u32, 0x40), backend.last_value);
        try testing.expectEqual(@as(usize, 0x110), backend.last_offset);

        try cap.ackRootStatus(root.Status.from(0xFFFF_FFFF), .{ .first_error_fatal, .fatal_received });
        try testing.expectEqual(@as(u32, 0x50), backend.last_value);
        try testing.expectEqual(@as(usize, 0x130), backend.last_offset);

        try testing.expectEqual(@as(usize, 0), backend.reads);
        try testing.expectEqual(@as(usize, 3), backend.writes);
    }

    test "AER rejects truncated common registers and bounds root accesses separately" {
        var backend: ConfigBackend = .{};
        const function = Function.from(backend.config(), address);

        for ([_]u16{ 0xFC, 0x102, 0xFD8 }) |offset| {
            try testing.expectError(error.MalformedCapability, Capability.tryFrom(function, .{
                .id = aer.id,
                .version = 1,
                .offset = offset,
            }));
        }

        const cap = try Capability.tryFrom(function, .{ .id = aer.id, .version = 1, .offset = 0xFD4 });
        try testing.expectError(error.MalformedCapability, cap.rootCommand());
        try testing.expectError(error.MalformedCapability, cap.rootStatus());
        try testing.expectError(error.MalformedCapability, cap.rootSourceIds());
        try testing.expectEqual(@as(usize, 0), backend.reads);
    }

    test "AER propagates backend failures without write retries or readback" {
        var backend: ConfigBackend = .{ .fail_read = true };
        const cap = try backend.capability();

        try testing.expectError(error.UnsupportedAccessWidth, cap.updateUncorrectableMask(.{ .completion_timeout = true }));
        try testing.expectEqual(@as(usize, 0), backend.writes);

        backend.fail_read = false;
        backend.fail_write = true;

        try testing.expectError(error.UnsupportedAccessWidth, cap.updateUncorrectableMask(.{ .completion_timeout = true }));
        try testing.expectEqual(@as(usize, 2), backend.reads);
        try testing.expectEqual(@as(usize, 1), backend.writes);

        try testing.expectError(error.UnsupportedAccessWidth, cap.ackRootStatus(root.Status.from(1), .{.correctable_received}));
        try testing.expectEqual(@as(usize, 2), backend.reads);
        try testing.expectEqual(@as(usize, 2), backend.writes);
    }

    test "default header logs preserve raw malformed and three dword captures" {
        for ([_]u32{ 0x9000_0001, 0x0000_0001 }) |first| {
            var backend: ConfigBackend = .{};
            const cap = try backend.capability();

            store32(&backend.bytes, 0x11C, first);
            store32(&backend.bytes, 0x120, 0x1122_3344);
            store32(&backend.bytes, 0x124, 0x5566_7788);
            store32(&backend.bytes, 0x128, 0xDEAD_BEEF);

            var args = log_args;
            args.control.logged_tlp_flit = true;

            const log = (try cap.headerLog(args)).?;
            try testing.expectEqualSlices(u32, &.{ first, 0x1122_3344, 0x5566_7788, 0xDEAD_BEEF }, &log);
            try testing.expectEqualSlices(usize, &.{ 0x11C, 0x120, 0x124, 0x128 }, backend.read_offsets[0..backend.reads]);
            try testing.expectEqual(@as(usize, 0), backend.writes);
        }
    }

    test "log validity excludes undefined first error indices and shared header overflow" {
        var backend: ConfigBackend = .{ .fail_read = true };
        const cap = try backend.capability();
        var args = log_args;
        args.status = uncorrectable.Status.from(0xFFFF_FFFF);

        for ([_]u5{ 0, 1, 11 }) |index| {
            args.control.first_error = @enumFromInt(index);
            try testing.expectEqual(@as(?aer.HeaderLog, null), try cap.headerLog(args));
            try testing.expectEqual(@as(?flit.HeaderLog, null), try flit.headerLog(cap, args));
        }

        args = log_args;
        args.status.malformed_tlp = false;
        try testing.expectEqual(@as(?aer.HeaderLog, null), try cap.headerLog(args));
        try testing.expectEqual(@as(usize, 0), backend.reads);

        backend.fail_read = false;
        for ([_]usize{ 0x11C, 0x120, 0x124, 0x128 }) |offset| {
            store32(&backend.bytes, offset, 0xFFFF_FFFF);
        }

        args = log_args;
        try testing.expectEqual(@as(?aer.HeaderLog, null), try cap.headerLog(args));
        try testing.expectEqual(@as(?aer.PrefixLog, null), try cap.prefixLog(args));
        try testing.expectEqualSlices(usize, &.{ 0x11C, 0x120, 0x124, 0x128 }, backend.read_offsets[0..backend.reads]);
    }

    test "prefix logs read the separate prefix bank only when present" {
        var backend: ConfigBackend = .{};
        const cap = try backend.capability();

        try testing.expectEqual(@as(?aer.PrefixLog, null), try cap.prefixLog(log_args));
        try testing.expectEqual(@as(usize, 0), backend.reads);

        store32(&backend.bytes, 0x11C, 0x9000_0001);
        store32(&backend.bytes, 0x138, 0x9100_1234);
        store32(&backend.bytes, 0x13C, 0x9200_5678);

        var args = log_args;
        args.control.prefix_log_present = true;

        const log = (try cap.prefixLog(args)).?;
        try testing.expectEqualSlices(u32, &.{ 0x9100_1234, 0x9200_5678, 0, 0 }, &log);
        try testing.expectEqualSlices(usize, &.{
            0x138, 0x13C, 0x140, 0x144,
        }, backend.read_offsets[0..backend.reads]);
        try testing.expectEqual(@as(usize, 0), backend.writes);
    }

    test "Flit logs read only the captured words and skip root registers" {
        for ([_]u5{ 4, 6, 14 }) |len| {
            var backend: ConfigBackend = .{};
            const cap = try backend.capability();
            var expected: [14]u32 = undefined;

            for (expected[0..len], 0..) |*word, i| {
                const offset = if (i < 4) 0x11C + i * 4 else 0x128 + i * 4;
                word.* = @as(u32, @intCast(i)) + 1;
                store32(&backend.bytes, offset, word.*);
            }

            var args = log_args;
            args.pcie.flit_mode_supported = true;
            args.control.logged_tlp_flit = true;
            args.control.header_log_size = len;
            args.control.logged_tlp_size = len;

            const log = (try flit.headerLog(cap, args)).?;
            try testing.expectEqualSlices(u32, expected[0..len], log.slice());
            try testing.expectEqual(@as(usize, len), backend.reads);

            for (backend.read_offsets[0..backend.reads], 0..) |offset, i| {
                const expected_offset = if (i < 4) 0x11C + i * 4 else 0x128 + i * 4;
                try testing.expectEqual(expected_offset, offset);
            }

            try testing.expectEqual(@as(usize, 0), backend.writes);
        }
    }

    test "log mode size and configuration bounds fail before payload reads" {
        var backend: ConfigBackend = .{ .fail_read = true };
        const cap = try backend.capability();
        var args = log_args;

        try testing.expectError(error.UnexpectedLogMode, flit.headerLog(cap, args));

        args.pcie.flit_mode_supported = true;
        args.control.logged_tlp_flit = true;
        args.control.header_log_size = 14;
        args.control.logged_tlp_size = 6;
        try testing.expectError(error.UnexpectedLogMode, cap.headerLog(args));
        try testing.expectError(error.UnexpectedLogMode, cap.prefixLog(args));

        for ([_][2]u5{ .{ 4, 6 }, .{ 14, 15 }, .{ 3, 3 } }) |sizes| {
            args.control.header_log_size = sizes[0];
            args.control.logged_tlp_size = sizes[1];
            try testing.expectError(error.MalformedCapability, flit.headerLog(cap, args));
        }

        args.control.header_log_size = 4;
        args.control.logged_tlp_size = 4;
        args.control.logged_tlp_flit = false;
        args.control.prefix_log_present = true;
        try testing.expectError(error.MalformedCapability, cap.prefixLog(args));

        args.control.logged_tlp_size = 6;
        try testing.expectError(error.MalformedCapability, cap.headerLog(args));

        const near_end = try Capability.tryFrom(Function.from(backend.config(), address), .{
            .id = aer.id,
            .version = 3,
            .offset = 0xFD4,
        });

        args = log_args;
        args.control.prefix_log_present = true;
        try testing.expectError(error.MalformedCapability, near_end.prefixLog(args));

        args.pcie.flit_mode_supported = true;
        args.control.logged_tlp_flit = true;
        args.control.header_log_size = 14;
        args.control.logged_tlp_size = 6;
        try testing.expectError(error.MalformedCapability, flit.headerLog(near_end, args));
        try testing.expectEqual(@as(usize, 0), backend.reads);
    }

    test "zero captured length reports unavailable logs without payload reads" {
        var backend: ConfigBackend = .{ .fail_read = true };
        const cap = try backend.capability();
        var args = log_args;
        args.pcie.flit_mode_supported = true;
        args.control.header_log_size = 14;

        try testing.expectEqual(@as(?aer.HeaderLog, null), try cap.headerLog(args));

        args.control.logged_tlp_flit = true;
        try testing.expectEqual(@as(?flit.HeaderLog, null), try flit.headerLog(cap, args));
        try testing.expectEqual(@as(usize, 0), backend.reads);
    }

    test "log readers propagate payload failures without retries or writes" {
        var backend: ConfigBackend = .{ .fail_offset = 0x124 };
        const cap = try backend.capability();

        try testing.expectError(error.UnsupportedAccessWidth, cap.headerLog(log_args));
        try testing.expectEqual(@as(usize, 3), backend.reads);

        backend.reads = 0;
        backend.fail_offset = 0x13C;
        var args = log_args;
        args.control.prefix_log_present = true;

        try testing.expectError(error.UnsupportedAccessWidth, cap.prefixLog(args));
        try testing.expectEqual(@as(usize, 2), backend.reads);

        backend.reads = 0;
        args.pcie.flit_mode_supported = true;
        args.control.logged_tlp_flit = true;
        args.control.header_log_size = 14;
        args.control.logged_tlp_size = 6;

        try testing.expectError(error.UnsupportedAccessWidth, flit.headerLog(cap, args));
        try testing.expectEqual(@as(usize, 6), backend.reads);
        try testing.expectEqual(@as(usize, 0), backend.writes);
    }

    test "first error acknowledgement ignores invalid observations and propagates write failures" {
        var backend: ConfigBackend = .{ .fail_read = true };
        const cap = try backend.capability();

        for ([_]u5{ 0, 1, 11 }) |index| {
            var control: Control = .{};
            control.first_error = @enumFromInt(index);

            try cap.ackFirstError(uncorrectable.Status.from(0xFFFF_FFFF), control);
        }

        try cap.ackFirstError(.{}, .{ .first_error = .malformed_tlp });
        try testing.expectEqual(@as(usize, 0), backend.writes);

        backend.fail_write = true;
        try testing.expectError(error.UnsupportedAccessWidth, cap.ackFirstError(
            .{ .malformed_tlp = true },
            .{ .first_error = .malformed_tlp },
        ));
        try testing.expectEqual(@as(usize, 1), backend.writes);
        try testing.expectEqual(@as(usize, 0), backend.reads);
    }

    test "firmware drains recorded errors one at a time without discarding the next header" {
        const records = [_]ErrorRecord{
            .{
                .control = .{
                    .first_error = .completion_timeout,
                    .completion_timeout_log_capable = true,
                    .multi_header_enable = true,
                },
                .header = .{ 0x2000_0001, 0x1122_3344, 0x5566_7788, 0 },
            },
            .{
                .control = .{ .first_error = .malformed_tlp, .multi_header_enable = true },
                .header = .{ 0x9000_0001, 0xAABB_CCDD, 0x1234_5678, 0xFFFF_FFFF },
            },
        };

        var backend: ConfigBackend = .{};
        backend.seedRecords(&records);

        const cap = try backend.capability();

        for (records, 0..) |record, i| {
            const status = try cap.uncorrectableStatus();
            const control = try cap.control();
            const args: LogArgs = .{ .pcie = .{}, .control = control, .status = status };

            try testing.expectEqual(record.control.first_error, control.first_error);

            const header = (try cap.headerLog(args)).?;
            try testing.expectEqualSlices(u32, &record.header, &header);

            const reads = backend.reads;
            backend.fail_read = true;

            try cap.ackFirstError(status, control);
            try testing.expectEqual(@as(u32, 1) << @intFromEnum(record.control.first_error), backend.last_value);
            try testing.expectEqual(@as(usize, 0x104), backend.last_offset);
            try testing.expectEqual(reads, backend.reads);

            backend.fail_read = false;

            if (i == 0) {
                const pending = try cap.uncorrectableStatus();
                try testing.expect(pending.malformed_tlp);
                try testing.expect(!pending.completion_timeout);
            }
        }

        const status = try cap.uncorrectableStatus();
        const control = try cap.control();

        try testing.expectEqual(@as(u32, 0), uncorrectable.Status.raw(status));
        try testing.expectEqual(@as(?aer.HeaderLog, null), try cap.headerLog(.{
            .pcie = .{},
            .control = control,
            .status = status,
        }));
        try testing.expectEqual(@as(usize, 2), backend.writes);
    }

    test "errors without header logging do not read any log bank" {
        var backend: ConfigBackend = .{ .fail_read = true };
        const cap = try backend.capability();

        for ([_]uncorrectable.ErrorCode{
            .data_link_protocol,
            .surprise_down,
            .flow_control_protocol,
            .receiver_overflow,
            .completion_timeout,
        }) |code| {
            var args = log_args;
            args.control.first_error = code;
            args.control.prefix_log_present = true;
            args.status = uncorrectable.Status.from(@as(u32, 1) << @intFromEnum(code));

            try testing.expectEqual(@as(?aer.HeaderLog, null), try cap.headerLog(args));
            try testing.expectEqual(@as(?aer.PrefixLog, null), try cap.prefixLog(args));

            args.pcie.flit_mode_supported = true;
            args.control.logged_tlp_flit = true;
            args.control.header_log_size = 14;
            args.control.logged_tlp_size = 6;

            try testing.expectEqual(@as(?flit.HeaderLog, null), try flit.headerLog(cap, args));
        }

        try testing.expectEqual(@as(usize, 0), backend.reads);
        try testing.expectEqual(@as(usize, 0), backend.writes);
    }

    test "completion timeout logs are readable when recording support is advertised" {
        var backend: ConfigBackend = .{};
        const cap = try backend.capability();

        store32(&backend.bytes, 0x11C, 0x2000_0001);
        store32(&backend.bytes, 0x120, 0x1122_3344);
        store32(&backend.bytes, 0x124, 0x5566_7788);
        store32(&backend.bytes, 0x138, 0x9100_1234);
        store32(&backend.bytes, 0x13C, 0x9200_5678);

        var args = log_args;
        args.status = .{ .completion_timeout = true };
        args.control.first_error = .completion_timeout;
        args.control.completion_timeout_log_capable = true;
        args.control.prefix_log_present = true;

        const header = (try cap.headerLog(args)).?;
        try testing.expectEqualSlices(u32, &.{ 0x2000_0001, 0x1122_3344, 0x5566_7788, 0 }, &header);

        const prefix = (try cap.prefixLog(args)).?;
        try testing.expectEqualSlices(u32, &.{ 0x9100_1234, 0x9200_5678, 0, 0 }, &prefix);

        args.pcie.flit_mode_supported = true;
        args.control.logged_tlp_flit = true;
        args.control.header_log_size = 14;
        args.control.logged_tlp_size = 6;

        const flit_header = (try flit.headerLog(cap, args)).?;
        try testing.expectEqualSlices(u32, &.{
            0x2000_0001, 0x1122_3344, 0x5566_7788, 0, 0x9100_1234, 0x9200_5678,
        }, flit_header.slice());
        try testing.expectEqual(@as(usize, 0), backend.writes);
    }

    fn store32(bytes: []u8, offset: usize, value: u32) void {
        std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
    }
};
