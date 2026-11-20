const std = @import("std");

const config = @import("config");
const core = @import("core");

const extended = @import("extended.zig");

const dpc = core.capabilities.dpc;
const pio = dpc.pio;

const Rel16 = core.RelativeOffset(u16);
const Rel32 = core.RelativeOffset(u32);

const Function = config.Function;
const Entry = extended.Entry;
const Registers = extended.Registers;

const Capabilities = dpc.Capabilities.Word;
const Control = dpc.Control.Word;
const ControlArgs = dpc.Control.AssignArgs;
const Status = dpc.Status.Word;

const PioStatus = pio.Status.Word;
const PioMask = pio.Mask.Word;
const PioMaskArgs = pio.Mask.AssignArgs;
const PioSeverity = pio.Severity.Word;
const PioSeverityArgs = pio.Severity.AssignArgs;
const PioSysError = pio.SysError.Word;
const PioSysErrorArgs = pio.SysError.AssignArgs;
const PioException = pio.Exception.Word;
const PioExceptionArgs = pio.Exception.AssignArgs;

const HeaderLog = pio.HeaderLog;
const FlitHeaderLog = flit.HeaderLog;
const PcieCapabilities = core.capabilities.pcie.Capabilities.Word;

pub const Error = extended.Error || error{ UnsupportedRegister, UnsupportedFeature };
pub const LogError = Error || error{UnexpectedLogMode};

pub const Capability = struct {
    registers: Registers,

    pub fn tryFrom(function: Function, entry: Entry) Error!Capability {
        std.debug.assert(entry.id == dpc.id);

        const registers = try Registers.tryFrom(function, entry.offset);
        if (!registers.contains(offsets.source_id)) {
            return error.MalformedCapability;
        }

        return .{ .registers = registers };
    }

    pub fn find(function: Function) Error!?Capability {
        const entry = (try extended.find(function, dpc.id)) orelse return null;
        return try Capability.tryFrom(function, entry);
    }

    pub fn capabilities(self: Capability) Error!Capabilities {
        return dpc.Capabilities.from(try self.registers.read(offsets.capabilities));
    }

    pub fn control(self: Capability) Error!Control {
        return dpc.Control.from(try self.registers.read(offsets.control));
    }

    pub fn updateControl(self: Capability, args: ControlArgs) Error!void {
        const observed = try self.control();
        const updated = dpc.Control.replace(observed, args);
        const raw = dpc.Control.raw(updated) & ~dpc.Control.masks.trigger;

        return self.registers.write(offsets.control, raw);
    }

    pub fn status(self: Capability) Error!Status {
        return dpc.Status.from(try self.registers.read(offsets.status));
    }

    pub fn sourceId(self: Capability) Error!u16 {
        return self.registers.read(offsets.source_id);
    }

    pub fn ackStatus(self: Capability, observed: Status, comptime fields: anytype) Error!void {
        return self.registers.write(offsets.status, dpc.Status.ack(observed, fields));
    }

    pub fn trigger(self: Capability) Error!void {
        const caps = try self.capabilities();
        if (!caps.software_trigger_supported) {
            return error.UnsupportedFeature;
        }

        const observed = try self.control();
        const raw = (dpc.Control.raw(observed) & ~dpc.Control.masks.trigger) | dpc.Control.trigger(.{.software_trigger});

        return self.registers.write(offsets.control, raw);
    }

    pub fn pioStatus(self: Capability) Error!PioStatus {
        if (!(try self.capabilities()).rp_extensions) {
            return error.UnsupportedRegister;
        }

        return pio.Status.from(try self.registers.read(offsets.pio.status));
    }

    pub fn ackPioStatus(self: Capability, observed: PioStatus, comptime fields: anytype) Error!void {
        if (!(try self.capabilities()).rp_extensions) {
            return error.UnsupportedRegister;
        }

        return self.registers.write(offsets.pio.status, pio.Status.ack(observed, fields));
    }

    pub fn ackPioFirstError(self: Capability, observed_status: Status, observed: PioStatus) Error!void {
        if (!(try self.capabilities()).rp_extensions) {
            return error.UnsupportedRegister;
        }

        const bit = @as(u32, 1) << @backingInt(observed_status.first_error);
        const selected = pio.Status.raw(observed) & pio.Status.masks.w1c & bit;

        if (selected == 0) {
            return;
        }

        return self.registers.write(offsets.pio.status, selected);
    }

    pub fn pioMask(self: Capability) Error!PioMask {
        if (!(try self.capabilities()).rp_extensions) {
            return error.UnsupportedRegister;
        }

        return pio.Mask.from(try self.registers.read(offsets.pio.mask));
    }

    pub fn updatePioMask(self: Capability, args: PioMaskArgs) Error!void {
        const observed = try self.pioMask();
        const updated = pio.Mask.replace(observed, args);

        return self.registers.write(offsets.pio.mask, pio.Mask.raw(updated));
    }

    pub fn pioSeverity(self: Capability) Error!PioSeverity {
        if (!(try self.capabilities()).rp_extensions) {
            return error.UnsupportedRegister;
        }

        return pio.Severity.from(try self.registers.read(offsets.pio.severity));
    }

    pub fn updatePioSeverity(self: Capability, args: PioSeverityArgs) Error!void {
        const observed = try self.pioSeverity();
        const updated = pio.Severity.replace(observed, args);

        return self.registers.write(offsets.pio.severity, pio.Severity.raw(updated));
    }

    pub fn pioSysError(self: Capability) Error!PioSysError {
        if (!(try self.capabilities()).rp_extensions) {
            return error.UnsupportedRegister;
        }

        return pio.SysError.from(try self.registers.read(offsets.pio.sys_error));
    }

    pub fn updatePioSysError(self: Capability, args: PioSysErrorArgs) Error!void {
        const observed = try self.pioSysError();
        const updated = pio.SysError.replace(observed, args);

        return self.registers.write(offsets.pio.sys_error, pio.SysError.raw(updated));
    }

    pub fn pioException(self: Capability) Error!PioException {
        if (!(try self.capabilities()).rp_extensions) {
            return error.UnsupportedRegister;
        }

        return pio.Exception.from(try self.registers.read(offsets.pio.exception));
    }

    pub fn updatePioException(self: Capability, args: PioExceptionArgs) Error!void {
        const observed = try self.pioException();
        const updated = pio.Exception.replace(observed, args);

        return self.registers.write(offsets.pio.exception, pio.Exception.raw(updated));
    }

    pub fn pioHeaderLog(self: Capability, args: LogArgs) LogError!?HeaderLog {
        if (!try args.available()) {
            return null;
        }

        _ = try args.logSize(.non_flit);

        if (!self.registers.contains(offsets.pio.header_log[3])) {
            return error.MalformedCapability;
        }

        var words: HeaderLog = undefined;
        for (&words, offsets.pio.header_log) |*word, offset| {
            word.* = try self.registers.read(offset);
        }

        return words;
    }

    pub fn pioPrefixLog(self: Capability, args: LogArgs) LogError!?PrefixLog {
        if (!try args.available()) {
            return null;
        }

        const size = try args.logSize(.non_flit);
        if (size <= 5) {
            return null;
        }

        const len = @min(size - 5, 4);
        if (!self.registers.contains(offsets.pio.prefix_log[len - 1])) {
            return error.MalformedCapability;
        }

        var log: PrefixLog = .{ .words = undefined, .len = @intCast(len) };
        for (log.words[0..len], offsets.pio.prefix_log[0..len]) |*word, offset| {
            word.* = try self.registers.read(offset);
        }

        return log;
    }

    pub fn pioImpSpecLog(self: Capability, args: LogArgs) LogError!?u32 {
        if (!try args.available()) {
            return null;
        }

        const size = try args.logSize(args.mode);
        if (size < 5) {
            return null;
        }

        return try self.registers.read(offsets.pio.imp_spec_log);
    }

    pub fn pioFlitHeaderLog(self: Capability, args: LogArgs) LogError!?FlitHeaderLog {
        if (!try args.available()) {
            return null;
        }

        const size = try args.logSize(.flit);
        const len = if (size == 4) size else size - 1;

        if (!self.registers.contains(flit.offsets.header_log[len - 1])) {
            return error.MalformedCapability;
        }

        var log: FlitHeaderLog = .{ .words = undefined, .len = @intCast(len) };
        for (log.words[0..len], flit.offsets.header_log[0..len]) |*word, offset| {
            word.* = try self.registers.read(offset);
        }

        return log;
    }
};

pub const LogMode = enum {
    non_flit,
    flit,
};

pub const LogArgs = struct {
    pcie: PcieCapabilities,
    capabilities: Capabilities,
    status: Status,
    pio_status: PioStatus,
    mode: LogMode,

    fn available(self: LogArgs) Error!bool {
        if (!self.capabilities.rp_extensions) {
            return error.UnsupportedRegister;
        }

        const bit = @as(u32, 1) << @backingInt(self.status.first_error);
        return pio.Status.raw(self.pio_status) & pio.Status.masks.w1c & bit != 0;
    }

    fn logSize(self: LogArgs, mode: LogMode) LogError!u5 {
        if (self.mode != mode or (mode == .flit and !self.pcie.flit_mode_supported)) {
            return error.UnexpectedLogMode;
        }

        var size: u5 = self.capabilities.pio_log_size_lo;
        if (self.pcie.flit_mode_supported and self.capabilities.pio_log_size_hi) {
            size |= 16;
        }

        if (size < 4 or size > 15) {
            return error.MalformedCapability;
        }

        return size;
    }
};

pub const PrefixLog = struct {
    words: pio.PrefixLog,
    len: u3,

    pub fn slice(self: *const PrefixLog) []const u32 {
        return self.words[0..self.len];
    }
};

pub const flit = struct {
    pub const HeaderLog = struct {
        words: pio.flit.HeaderLog,
        len: u4,

        pub fn slice(self: *const FlitHeaderLog) []const u32 {
            return self.words[0..self.len];
        }
    };

    pub const offsets = struct {
        pub const header_log = values: {
            var values: [pio.flit.offsets.header_log.len]Rel32 = undefined;
            for (&values, pio.flit.offsets.header_log) |*value, offset| {
                value.* = .from(offset);
            }

            break :values values;
        };
    };
};

pub const offsets = struct {
    pub const capabilities = Rel16.from(dpc.offsets.capabilities);
    pub const control = Rel16.from(dpc.offsets.control);
    pub const status = Rel16.from(dpc.offsets.status);
    pub const source_id = Rel16.from(dpc.offsets.source_id);

    pub const pio = struct {
        pub const status = Rel32.from(dpc.pio.offsets.status);
        pub const mask = Rel32.from(dpc.pio.offsets.mask);
        pub const severity = Rel32.from(dpc.pio.offsets.severity);
        pub const sys_error = Rel32.from(dpc.pio.offsets.sys_error);
        pub const exception = Rel32.from(dpc.pio.offsets.exception);
        pub const imp_spec_log = Rel32.from(dpc.pio.offsets.imp_spec_log);

        pub const header_log = values: {
            var values: [dpc.pio.offsets.header_log.len]Rel32 = undefined;
            for (&values, dpc.pio.offsets.header_log) |*value, offset| {
                value.* = .from(offset);
            }

            break :values values;
        };

        pub const prefix_log = values: {
            var values: [dpc.pio.offsets.prefix_log.len]Rel32 = undefined;
            for (&values, dpc.pio.offsets.prefix_log) |*value, offset| {
                value.* = .from(offset);
            }

            break :values values;
        };
    };
};

pub const unit = struct {
    const testing = std.testing;

    const ConfigSpace = config.ConfigSpace;
    const ConfigError = ConfigSpace.Error;
    const Sbdf = core.Sbdf;

    const address = Sbdf.from(.from(0), 2, 3, 0);
    const log_args: LogArgs = .{
        .pcie = .{},
        .capabilities = .{ .rp_extensions = true, .pio_log_size_lo = 9 },
        .status = .{ .first_error = .mem_timeout },
        .pio_status = .{ .mem_timeout = true },
        .mode = .non_flit,
    };

    const Write = struct {
        offset: usize,
        value: u32,
    };

    const ConfigBackend = struct {
        bytes: [core.config.extended_size]u8 = @splat(0),
        base: u16 = 0x100,
        reads: [64]usize = undefined,
        read_count: usize = 0,
        writes: [16]Write = undefined,
        write_count: usize = 0,
        write_attempts: usize = 0,
        fail_read_at: ?usize = null,
        fail_write_at: ?usize = null,
        link_active: bool = false,
        unsafe_release: bool = false,

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

        fn capability(self: *ConfigBackend, position: u16) Error!Capability {
            self.base = position;
            return Capability.tryFrom(Function.from(self.config(), address), .{
                .id = dpc.id,
                .version = 1,
                .offset = position,
            });
        }

        fn read8(_: *anyopaque, _: Sbdf, _: usize) ConfigError!u8 {
            return error.UnsupportedAccessWidth;
        }

        fn write8(_: *anyopaque, _: Sbdf, _: usize, _: u8) ConfigError!void {
            return error.UnsupportedAccessWidth;
        }

        fn read16(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigError!u16 {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            std.debug.assert(address.eql(sbdf));

            self.reads[self.read_count] = offset;
            self.read_count += 1;

            if (self.fail_read_at == offset) {
                return error.UnsupportedAccessWidth;
            }

            return std.mem.readInt(u16, self.bytes[offset..][0..2], .little);
        }

        fn read32(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigError!u32 {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            std.debug.assert(address.eql(sbdf));

            self.reads[self.read_count] = offset;
            self.read_count += 1;

            if (self.fail_read_at == offset) {
                return error.UnsupportedAccessWidth;
            }

            return std.mem.readInt(u32, self.bytes[offset..][0..4], .little);
        }

        fn write16(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u16) ConfigError!void {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            std.debug.assert(address.eql(sbdf));
            self.write_attempts += 1;

            if (self.fail_write_at == offset) {
                return error.UnsupportedAccessWidth;
            }

            self.writes[self.write_count] = .{ .offset = offset, .value = value };
            self.write_count += 1;

            const status_offset = @as(usize, self.base) + 8;
            if (offset == status_offset) {
                const status = std.mem.readInt(u16, self.bytes[status_offset..][0..2], .little);
                if (value & 1 != 0 and (self.link_active or status & 0x10 != 0)) {
                    self.unsafe_release = true;
                }

                store16(&self.bytes, offset, status & ~(value & 0x2009));
            } else if (offset == @as(usize, self.base) + 6) {
                store16(&self.bytes, offset, value & ~@as(u16, 0x40));

                var status = std.mem.readInt(u16, self.bytes[status_offset..][0..2], .little);
                if (value & 0x40 != 0 and value & 3 != 0 and status & 1 == 0) {
                    status = (status & ~@as(u16, 0x67)) | 0x27;
                    if (value & 8 != 0) {
                        status |= 8;
                    }

                    store16(&self.bytes, status_offset, status);
                }
            } else {
                store16(&self.bytes, offset, value);
            }
        }

        fn write32(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u32) ConfigError!void {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            std.debug.assert(address.eql(sbdf));
            self.write_attempts += 1;

            if (self.fail_write_at == offset) {
                return error.UnsupportedAccessWidth;
            }

            self.writes[self.write_count] = .{ .offset = offset, .value = value };
            self.write_count += 1;

            if (offset == @as(usize, self.base) + 0x0C) {
                const status = std.mem.readInt(u32, self.bytes[offset..][0..4], .little);
                store32(&self.bytes, offset, status & ~(value & 0x0007_0707));

                const status_offset = @as(usize, self.base) + 8;
                const dpc_status = std.mem.readInt(u16, self.bytes[status_offset..][0..2], .little);
                const bit = @as(u32, 1) << @as(u5, @truncate(dpc_status >> 8));

                if (value & bit != 0) {
                    store16(&self.bytes, status_offset, dpc_status | 0x1F00);
                }
            } else {
                store32(&self.bytes, offset, value);
            }
        }
    };

    test "DPC discovery rebases live 16 bit registers" {
        var backend: ConfigBackend = .{ .base = 0x180 };
        const function = Function.from(backend.config(), address);

        try testing.expectEqual(@as(?Capability, null), try Capability.find(function));

        store32(&backend.bytes, 0x100, 0x1801_000E);
        store32(&backend.bytes, 0x180, 0x0001_001D);
        store16(&backend.bytes, 0x184, 0x00A5);
        store16(&backend.bytes, 0x186, 1);
        store16(&backend.bytes, 0x188, 0x200B);
        store16(&backend.bytes, 0x18A, 0x11AF);

        const cap = (try Capability.find(function)).?;
        const caps = try cap.capabilities();

        try testing.expectEqual(@as(u5, 5), caps.intr_message);
        try testing.expect(caps.rp_extensions);
        try testing.expectEqual(dpc.TriggerMode.fatal, (try cap.control()).trigger_mode);
        try testing.expectEqual(dpc.Reason.non_fatal, (try cap.status()).reason);
        try testing.expectEqual(@as(u16, 0x11AF), try cap.sourceId());

        store16(&backend.bytes, 0x186, 2);
        try testing.expectEqual(dpc.TriggerMode.non_fatal, (try cap.control()).trigger_mode);
    }

    test "DPC updates preserve controls without triggering containment" {
        var backend: ConfigBackend = .{};
        const cap = try backend.capability(0x100);
        store16(&backend.bytes, 0x104, 0x80);
        store16(&backend.bytes, 0x106, 0xFE01);
        store16(&backend.bytes, 0x108, 0x1F00);

        try cap.updateControl(.{ .intr_enable = true });
        try testing.expectEqual(@as(u32, 0xFE09), backend.writes[0].value);
        try testing.expectEqual(@as(usize, 0x106), backend.writes[0].offset);
        try testing.expect(!(try cap.status()).triggered);

        try cap.trigger();
        try testing.expectEqual(@as(u32, 0xFE49), backend.writes[1].value);

        const status = try cap.status();

        try testing.expect(status.triggered);
        try testing.expect(status.intr_pending);
        try testing.expectEqual(dpc.Reason.extended, status.reason);
        try testing.expectEqual(dpc.ReasonExt.software, status.reason_ext);
        try testing.expectEqual(@as(u16, 0xFE09), dpc.Control.raw(try cap.control()));

        store16(&backend.bytes, 0x104, 0);
        const reads = backend.read_count;

        try testing.expectError(error.UnsupportedFeature, cap.trigger());
        try testing.expectEqual(reads + 1, backend.read_count);
        try testing.expectEqual(@as(usize, 2), backend.write_count);
    }

    test "software trigger while disabled preserves the pending event without containment" {
        var backend: ConfigBackend = .{};
        const cap = try backend.capability(0x100);
        store16(&backend.bytes, 0x104, 0x80);
        store16(&backend.bytes, 0x106, 0x011C);
        store16(&backend.bytes, 0x108, 0x1F08);

        try cap.trigger();

        try testing.expectEqual(@as(usize, 1), backend.write_count);
        try testing.expectEqual(@as(usize, 0x106), backend.writes[0].offset);
        try testing.expectEqual(@as(u32, 0x015C), backend.writes[0].value);
        try testing.expectEqual(@as(u16, 0x011C), dpc.Control.raw(try cap.control()));
        try testing.expectEqual(@as(u16, 0x1F08), dpc.Status.raw(try cap.status()));
    }

    test "software trigger while contained preserves the PIO event and captured request" {
        var backend: ConfigBackend = .{};
        const cap = try backend.capability(0x100);
        store16(&backend.bytes, 0x104, 0x04A0);
        store16(&backend.bytes, 0x106, 0x000A);
        store16(&backend.bytes, 0x108, 0x121F);
        store32(&backend.bytes, 0x10C, 0x0004_0000);
        store32(&backend.bytes, 0x120, 0x2000_0001);
        store32(&backend.bytes, 0x124, 0x1122_3344);
        store32(&backend.bytes, 0x128, 0x5566_7788);
        store32(&backend.bytes, 0x12C, 0xDEAD_BEEF);

        try cap.trigger();

        try testing.expectEqual(@as(usize, 1), backend.write_count);
        try testing.expectEqual(@as(usize, 0x106), backend.writes[0].offset);
        try testing.expectEqual(@as(u32, 0x004A), backend.writes[0].value);
        try testing.expectEqual(@as(u16, 0x000A), dpc.Control.raw(try cap.control()));

        const status = try cap.status();
        const pio_status = try cap.pioStatus();

        try testing.expectEqual(@as(u16, 0x121F), dpc.Status.raw(status));
        try testing.expectEqual(@as(u32, 0x0004_0000), pio.Status.raw(pio_status));

        const header = (try cap.pioHeaderLog(.{
            .pcie = .{},
            .capabilities = try cap.capabilities(),
            .status = status,
            .pio_status = pio_status,
            .mode = .non_flit,
        })).?;

        try testing.expectEqualSlices(u32, &.{ 0x2000_0001, 0x1122_3344, 0x5566_7788, 0xDEAD_BEEF }, &header);
    }

    test "firmware acknowledges the interrupt before releasing an inactive contained link" {
        var backend: ConfigBackend = .{ .link_active = true };
        const cap = try backend.capability(0x100);
        store16(&backend.bytes, 0x108, 0x2019);

        const observed = try cap.status();
        const reads = backend.read_count;

        try cap.ackStatus(observed, .{.intr_pending});
        try testing.expectEqual(reads, backend.read_count);
        try testing.expectEqual(@as(u32, 8), backend.writes[0].value);

        const contained = try cap.status();
        try testing.expect(contained.triggered);
        try testing.expect(contained.rp_busy);
        try testing.expect(contained.sig_fw);
        try testing.expect(!contained.intr_pending);

        backend.link_active = false;
        store16(&backend.bytes, 0x108, 0x2001);

        const inactive = try cap.status();
        try cap.ackStatus(inactive, .{.triggered});
        try testing.expectEqual(@as(u32, 1), backend.writes[1].value);

        const released = try cap.status();
        try testing.expect(!released.triggered);
        try testing.expect(released.sig_fw);
        try testing.expect(!backend.unsafe_release);

        try cap.ackStatus(released, .{.sig_fw});
        try testing.expectEqual(@as(u32, 0x2000), backend.writes[2].value);
    }

    test "DPC binding checks the base extent without requiring root port extensions" {
        var backend: ConfigBackend = .{};

        for ([_]u16{ 0xFC, 0x102, 0xFF8 }) |position| {
            try testing.expectError(error.MalformedCapability, backend.capability(position));
        }

        const cap = try backend.capability(0xFF4);
        try testing.expectError(error.UnsupportedRegister, cap.pioStatus());
        try testing.expectEqualSlices(usize, &.{0xFF8}, backend.reads[0..backend.read_count]);

        store16(&backend.bytes, 0xFF8, 0x20);
        try testing.expectError(error.MalformedCapability, cap.pioStatus());
        try testing.expectEqual(@as(usize, 2), backend.read_count);
        try testing.expectEqual(@as(usize, 0), backend.write_count);
    }

    test "DPC root PIO controls preserve unrelated and reserved bits" {
        var backend: ConfigBackend = .{};
        const cap = try backend.capability(0x100);
        store16(&backend.bytes, 0x104, 0x20);
        store32(&backend.bytes, 0x10C, 0x0007_0707);
        store32(&backend.bytes, 0x110, 0xFFFF_FFFF);
        store32(&backend.bytes, 0x114, 0xFFF8_F8F8);
        store32(&backend.bytes, 0x118, 0xFFF8_F8F8);
        store32(&backend.bytes, 0x11C, 0xFFF8_F8F8);

        try testing.expect((try cap.pioStatus()).cfg_timeout);

        try cap.updatePioMask(.{ .cfg_ur = false, .mem_timeout = false });
        try testing.expectEqual(@as(u32, 0xFFFB_FFFE), backend.writes[0].value);
        try testing.expectEqual(@as(usize, 0x110), backend.writes[0].offset);
        try testing.expect(!(try cap.pioMask()).mem_timeout);

        try cap.updatePioSeverity(.{ .mem_timeout = true });
        try testing.expectEqual(@as(u32, 0xFFFC_F8F8), backend.writes[1].value);
        try testing.expectEqual(@as(usize, 0x114), backend.writes[1].offset);
        try testing.expect((try cap.pioSeverity()).mem_timeout);

        try cap.updatePioSysError(.{ .cfg_timeout = true });
        try testing.expectEqual(@as(u32, 0xFFF8_F8FC), backend.writes[2].value);
        try testing.expectEqual(@as(usize, 0x118), backend.writes[2].offset);
        try testing.expect((try cap.pioSysError()).cfg_timeout);

        try cap.updatePioException(.{ .io_ca = true });
        try testing.expectEqual(@as(u32, 0xFFF8_FAF8), backend.writes[3].value);
        try testing.expectEqual(@as(usize, 0x11C), backend.writes[3].offset);
        try testing.expect((try cap.pioException()).io_ca);
    }

    test "PIO acknowledgement invalidates the first error without clearing other observations" {
        var backend: ConfigBackend = .{};
        const cap = try backend.capability(0x100);
        store16(&backend.bytes, 0x104, 0x20);
        store16(&backend.bytes, 0x108, 0x0900);
        store32(&backend.bytes, 0x10C, 0x0004_0201);

        const status = try cap.status();
        const observed = try cap.pioStatus();
        const reads = backend.read_count;
        backend.fail_read_at = 0x10C;

        try cap.ackPioFirstError(status, observed);
        try testing.expectEqual(@as(u32, 0x200), backend.writes[0].value);
        try testing.expectEqual(@as(usize, 0x10C), backend.writes[0].offset);
        try testing.expectEqual(reads + 1, backend.read_count);
        try testing.expectEqual(@as(u32, 0x0004_0001), std.mem.readInt(u32, backend.bytes[0x10C..0x110], .little));
        try testing.expectEqual(@as(u16, 0x1F00), std.mem.readInt(u16, backend.bytes[0x108..0x10A], .little));

        try cap.ackPioStatus(observed, .{ .cfg_ur, .mem_timeout });
        try testing.expectEqual(@as(u32, 0x0004_0001), backend.writes[1].value);
        try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, backend.bytes[0x10C..0x110], .little));

        for ([_]u5{ 7, 31 }) |index| {
            var invalid = status;
            invalid.first_error = @fromBackingInt(@intCast(index));
            try cap.ackPioFirstError(invalid, pio.Status.from(0xFFFF_FFFF));
        }

        try cap.ackPioFirstError(status, .{});
        try testing.expectEqual(@as(usize, 2), backend.write_count);
    }

    test "advisory PIO captures expose only the allocated default log banks" {
        for ([_]u4{ 4, 5, 6, 8, 9, 15 }) |size| {
            var backend: ConfigBackend = .{};
            const cap = try backend.capability(0x100);
            store32(&backend.bytes, 0x120, 0x9000_0001);
            store32(&backend.bytes, 0x124, 0x1122_3344);
            store32(&backend.bytes, 0x128, 0x5566_7788);
            store32(&backend.bytes, 0x12C, 0xDEAD_BEEF);

            for (0..4) |i| {
                store32(&backend.bytes, 0x134 + i * 4, @intCast(i + 1));
            }

            var args = log_args;
            args.capabilities.pio_log_size_lo = size;
            args.capabilities.pio_log_size_hi = true;

            const header = (try cap.pioHeaderLog(args)).?;
            try testing.expectEqualSlices(u32, &.{ 0x9000_0001, 0x1122_3344, 0x5566_7788, 0xDEAD_BEEF }, &header);
            try testing.expectEqualSlices(usize, &.{ 0x120, 0x124, 0x128, 0x12C }, backend.reads[0..backend.read_count]);

            backend.read_count = 0;
            const imp_spec = try cap.pioImpSpecLog(args);

            if (size == 4) {
                try testing.expectEqual(@as(?u32, null), imp_spec);
                try testing.expectEqual(@as(usize, 0), backend.read_count);
            } else {
                try testing.expectEqual(@as(?u32, 0), imp_spec);
                try testing.expectEqualSlices(usize, &.{0x130}, backend.reads[0..backend.read_count]);
            }

            backend.read_count = 0;

            const prefix = try cap.pioPrefixLog(args);
            if (size <= 5) {
                try testing.expectEqual(@as(?PrefixLog, null), prefix);
                try testing.expectEqual(@as(usize, 0), backend.read_count);
            } else {
                const expected = [_]u32{ 1, 2, 3, 4 };
                const len = @min(@as(usize, size) - 5, 4);
                const log = prefix.?;

                try testing.expectEqualSlices(u32, expected[0..len], log.slice());
                try testing.expectEqual(len, backend.read_count);

                for (backend.reads[0..backend.read_count], 0..) |offset, i| {
                    try testing.expectEqual(0x134 + i * 4, offset);
                }
            }

            try testing.expectEqual(@as(usize, 0), backend.write_count);
        }
    }

    test "PIO Flit storage uses advertised capacity and skips the implementation specific word" {
        for ([_]u4{ 4, 5, 6, 9, 15 }) |size| {
            var backend: ConfigBackend = .{};
            const cap = try backend.capability(0x100);
            const len = if (size == 4) size else size - 1;
            var expected: [14]u32 = undefined;

            for (expected[0..len], 0..) |*word, i| {
                const offset = if (i < 4) 0x120 + i * 4 else 0x124 + i * 4;
                word.* = @intCast(i + 1);
                store32(&backend.bytes, offset, word.*);
            }

            store32(&backend.bytes, 0x130, 0xDEAD_BEEF);

            var args = log_args;
            args.pcie.flit_mode_supported = true;
            args.mode = .flit;
            args.capabilities.pio_log_size_lo = size;

            const log = (try cap.pioFlitHeaderLog(args)).?;

            try testing.expectEqualSlices(u32, expected[0..len], log.slice());
            try testing.expectEqual(@as(usize, len), backend.read_count);

            for (backend.reads[0..backend.read_count], 0..) |offset, i| {
                const expected_offset = if (i < 4) 0x120 + i * 4 else 0x124 + i * 4;
                try testing.expectEqual(expected_offset, offset);
            }

            if (size >= 5) {
                try testing.expectEqual(@as(?u32, 0xDEAD_BEEF), try cap.pioImpSpecLog(args));
            }
        }
    }

    test "PIO diagnostics require root extensions and a defined pending first error" {
        var backend: ConfigBackend = .{ .fail_read_at = 0x120 };
        const cap = try backend.capability(0x100);
        var args = log_args;
        args.pio_status = pio.Status.from(0xFFFF_FFFF);

        for ([_]u5{ 7, 31 }) |index| {
            args.status.first_error = @fromBackingInt(@intCast(index));

            try testing.expectEqual(@as(?HeaderLog, null), try cap.pioHeaderLog(args));
            try testing.expectEqual(@as(?PrefixLog, null), try cap.pioPrefixLog(args));
            try testing.expectEqual(@as(?u32, null), try cap.pioImpSpecLog(args));
            try testing.expectEqual(@as(?FlitHeaderLog, null), try cap.pioFlitHeaderLog(args));
        }

        args = log_args;
        args.pio_status.mem_timeout = false;

        try testing.expectEqual(@as(?HeaderLog, null), try cap.pioHeaderLog(args));

        args.capabilities.rp_extensions = false;
        try testing.expectError(error.UnsupportedRegister, cap.pioHeaderLog(args));
        try testing.expectError(error.UnsupportedRegister, cap.pioPrefixLog(args));
        try testing.expectError(error.UnsupportedRegister, cap.pioImpSpecLog(args));
        try testing.expectError(error.UnsupportedRegister, cap.pioFlitHeaderLog(args));
        try testing.expectEqual(@as(usize, 0), backend.read_count);
    }

    test "PIO mode size and complete log extents are checked before payload reads" {
        var backend: ConfigBackend = .{};
        const cap = try backend.capability(0x100);
        var args = log_args;

        try testing.expectError(error.UnexpectedLogMode, cap.pioFlitHeaderLog(args));

        args.mode = .flit;

        try testing.expectError(error.UnexpectedLogMode, cap.pioHeaderLog(args));
        try testing.expectError(error.UnexpectedLogMode, cap.pioPrefixLog(args));
        try testing.expectError(error.UnexpectedLogMode, cap.pioFlitHeaderLog(args));

        args.pcie.flit_mode_supported = true;

        for ([_]u5{ 0, 3, 16, 31 }) |size| {
            args.capabilities.pio_log_size_lo = @truncate(size);
            args.capabilities.pio_log_size_hi = size >= 16;
            try testing.expectError(error.MalformedCapability, cap.pioFlitHeaderLog(args));
        }

        const near_end = try backend.capability(0xFC8);
        args = log_args;
        args.capabilities.pio_log_size_lo = 7;

        try testing.expectError(error.MalformedCapability, near_end.pioPrefixLog(args));

        args.pcie.flit_mode_supported = true;
        args.mode = .flit;

        try testing.expectError(error.MalformedCapability, near_end.pioFlitHeaderLog(args));
        try testing.expectEqual(@as(usize, 0), backend.read_count);

        store32(&backend.bytes, 0xFFC, 0x1234_5678);
        args.capabilities.pio_log_size_lo = 6;
        args.mode = .non_flit;

        const prefix = (try near_end.pioPrefixLog(args)).?;

        try testing.expectEqualSlices(u32, &.{0x1234_5678}, prefix.slice());
        try testing.expectEqualSlices(usize, &.{0xFFC}, backend.reads[0..backend.read_count]);

        const truncated = try backend.capability(0xFF4);
        backend.read_count = 0;

        try testing.expectError(error.MalformedCapability, truncated.pioHeaderLog(args));
        try testing.expectEqual(@as(usize, 0), backend.read_count);
    }

    test "DPC propagates backend failures without retries or implicit acknowledgements" {
        var backend: ConfigBackend = .{ .fail_read_at = 0x104 };
        const cap = try backend.capability(0x100);

        try testing.expectError(error.UnsupportedAccessWidth, cap.trigger());
        try testing.expectEqual(@as(usize, 0), backend.write_attempts);

        store16(&backend.bytes, 0x104, 0xA0);
        backend.fail_read_at = 0x106;

        try testing.expectError(error.UnsupportedAccessWidth, cap.updateControl(.{ .intr_enable = true }));
        try testing.expectEqual(@as(usize, 0), backend.write_attempts);

        backend.fail_read_at = 0x110;

        try testing.expectError(error.UnsupportedAccessWidth, cap.updatePioMask(.{ .cfg_ur = false }));
        try testing.expectEqual(@as(usize, 0), backend.write_attempts);

        backend.fail_read_at = null;
        backend.fail_write_at = 0x106;

        try testing.expectError(error.UnsupportedAccessWidth, cap.trigger());
        try testing.expectEqual(@as(usize, 1), backend.write_attempts);

        backend.fail_write_at = 0x108;
        backend.fail_read_at = 0x108;

        try testing.expectError(error.UnsupportedAccessWidth, cap.ackStatus(.{ .intr_pending = true }, .{.intr_pending}));
        try testing.expectEqual(@as(usize, 2), backend.write_attempts);

        backend.fail_read_at = null;
        backend.fail_write_at = 0x10C;

        try testing.expectError(error.UnsupportedAccessWidth, cap.ackPioFirstError(.{ .first_error = .cfg_ur }, .{ .cfg_ur = true }));
        try testing.expectEqual(@as(usize, 3), backend.write_attempts);
        try testing.expectEqual(@as(usize, 0), backend.write_count);
    }

    test "PIO payload read failures stop at the failing word without writes" {
        var backend: ConfigBackend = .{ .fail_read_at = 0x128 };
        const cap = try backend.capability(0x100);

        try testing.expectError(error.UnsupportedAccessWidth, cap.pioHeaderLog(log_args));
        try testing.expectEqualSlices(usize, &.{ 0x120, 0x124, 0x128 }, backend.reads[0..backend.read_count]);

        backend.read_count = 0;
        backend.fail_read_at = 0x138;

        try testing.expectError(error.UnsupportedAccessWidth, cap.pioPrefixLog(log_args));
        try testing.expectEqualSlices(usize, &.{ 0x134, 0x138 }, backend.reads[0..backend.read_count]);

        backend.read_count = 0;
        backend.fail_read_at = 0x130;

        try testing.expectError(error.UnsupportedAccessWidth, cap.pioImpSpecLog(log_args));
        try testing.expectEqualSlices(usize, &.{0x130}, backend.reads[0..backend.read_count]);

        backend.read_count = 0;
        backend.fail_read_at = 0x138;

        var args = log_args;
        args.pcie.flit_mode_supported = true;
        args.mode = .flit;

        try testing.expectError(error.UnsupportedAccessWidth, cap.pioFlitHeaderLog(args));
        try testing.expectEqualSlices(usize, &.{ 0x120, 0x124, 0x128, 0x12C, 0x134, 0x138 }, backend.reads[0..backend.read_count]);
        try testing.expectEqual(@as(usize, 0), backend.write_count);
    }

    fn store16(bytes: []u8, offset: usize, value: u16) void {
        std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
    }

    fn store32(bytes: []u8, offset: usize, value: u32) void {
        std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
    }
};
