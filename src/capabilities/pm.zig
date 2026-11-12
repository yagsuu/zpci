const std = @import("std");

const config = @import("config");
const core = @import("core");
const pm = core.capabilities.pm;

const standard = @import("standard.zig");

const Function = config.Function;
const Entry = standard.Entry;
const CapabilityError = standard.Error;
const Registers = standard.Registers;
const RelativeOffset = core.RelativeOffset;
const HeaderType = core.header.Type;

const Capabilities = pm.Capabilities.Word;
const Control = pm.Control.Word;
const ControlArgs = pm.Control.AssignArgs;
const BridgeSupport = pm.BridgeSupport.Word;
const State = pm.State;

pub const Error = CapabilityError || error{UnsupportedRegister};

pub const StateError = CapabilityError || error{
    UnsupportedFeature,
    InvalidTransition,
};

pub const Capability = struct {
    registers: Registers,
    version: u3,

    pub fn tryFrom(function: Function, cap: Entry) CapabilityError!Capability {
        std.debug.assert(cap.id == pm.id);

        const registers = try Registers.tryFrom(function, cap.offset);
        if (!registers.contains(offsets.control)) {
            return error.MalformedCapability;
        }

        const caps = pm.Capabilities.from(try registers.read(offsets.capabilities));

        return .{ .registers = registers, .version = caps.version };
    }

    pub fn find(function: Function) CapabilityError!?Capability {
        const cap = (try standard.find(function, pm.id)) orelse return null;
        return try Capability.tryFrom(function, cap);
    }

    pub fn capabilities(self: Capability) CapabilityError!Capabilities {
        return pm.Capabilities.from(try self.registers.read(offsets.capabilities));
    }

    pub fn control(self: Capability) CapabilityError!Control {
        return pm.Control.from(try self.registers.read(offsets.control));
    }

    pub fn updateControl(self: Capability, args: ControlArgs) CapabilityError!void {
        const observed = try self.control();
        const updated = pm.Control.replace(observed, args);
        const raw = pm.Control.raw(updated) & pm.Control.masks.assign;

        return self.registers.write(offsets.control, raw);
    }

    pub fn setPowerState(self: Capability, state: State) StateError!void {
        if (state == .d1 or state == .d2) {
            const caps = try self.capabilities();
            if (state == .d1 and !caps.d1_supported) {
                return error.UnsupportedFeature;
            }

            if (state == .d2 and !caps.d2_supported) {
                return error.UnsupportedFeature;
            }
        }

        const observed = try self.control();
        if (state != .d0 and @intFromEnum(state) < @intFromEnum(observed.state)) {
            return error.InvalidTransition;
        }

        const updated = pm.Control.replace(observed, .{ .state = state });
        const raw = pm.Control.raw(updated) & pm.Control.masks.assign;

        return self.registers.write(offsets.control, raw);
    }

    pub fn ackPmeStatus(self: Capability, observed: Control) CapabilityError!void {
        if (!observed.pme_status) {
            return;
        }

        const current = try self.control();
        const raw = (pm.Control.raw(current) & pm.Control.masks.assign) |
            pm.Control.ack(observed, .{.pme_status});

        return self.registers.write(offsets.control, raw);
    }

    pub fn bridgeSupport(self: Capability) Error!BridgeSupport {
        const header_type = HeaderType.from(try self.registers.function.typeByte());
        if (header_type.format != .type1) {
            return error.UnsupportedRegister;
        }

        return pm.BridgeSupport.from(try self.registers.read(offsets.bridge_support));
    }

    pub fn data(self: Capability) CapabilityError!u8 {
        return self.registers.read(offsets.data);
    }
};

pub const offsets = struct {
    pub const capabilities = RelativeOffset(u16).from(pm.offsets.capabilities);
    pub const control = RelativeOffset(u16).from(pm.offsets.control);
    pub const bridge_support = RelativeOffset(u8).from(pm.offsets.bridge_support);
    pub const data = RelativeOffset(u8).from(pm.offsets.data);
};

pub const unit = struct {
    const testing = std.testing;

    const window_size = core.config.size;
    const base: u8 = 0x80;
    const test_sbdf = core.Sbdf.from(core.SegmentId.from(0), 0, 0, 0);
    const test_entry: Entry = .{ .id = .pm, .offset = base };

    const ConfigSpace = config.ConfigSpace;
    const ConfigError = ConfigSpace.Error;
    const Sbdf = core.Sbdf;
    const HeaderStatus = core.header.Status;
    const Pm = Capability;

    const ConfigBackend = struct {
        bytes: *[window_size]u8,
        read_count: usize = 0,
        write_count: usize = 0,
        last_write: u16 = 0,
        fail_read: ?usize = null,
        fail_write: bool = false,

        fn config(self: *ConfigBackend) ConfigSpace {
            return ConfigSpace.from(self, &vtable);
        }

        fn function(self: *ConfigBackend) Function {
            return Function.from(self.config(), test_sbdf);
        }

        const vtable: ConfigSpace.VTable = .{
            .read8 = read8,
            .read16 = read16,
            .read32 = read32,
            .write8 = write8Unsupported,
            .write16 = write16,
            .write32 = write32Unsupported,
        };

        fn read8(context: *anyopaque, _: Sbdf, offset: usize) ConfigError!u8 {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            self.read_count += 1;

            if (self.fail_read == offset) {
                return error.UnsupportedAccessWidth;
            }

            return self.bytes[offset];
        }

        fn read16(context: *anyopaque, _: Sbdf, offset: usize) ConfigError!u16 {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            self.read_count += 1;

            if (self.fail_read == offset) {
                return error.UnsupportedAccessWidth;
            }

            return std.mem.readInt(u16, self.bytes[offset..][0..2], .little);
        }

        fn read32(context: *anyopaque, _: Sbdf, offset: usize) ConfigError!u32 {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            self.read_count += 1;

            if (self.fail_read == offset) {
                return error.UnsupportedAccessWidth;
            }

            return std.mem.readInt(u32, self.bytes[offset..][0..4], .little);
        }

        fn write8Unsupported(_: *anyopaque, _: Sbdf, _: usize, _: u8) ConfigError!void {
            return error.UnsupportedAccessWidth;
        }

        fn write16(context: *anyopaque, _: Sbdf, offset: usize, value: u16) ConfigError!void {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            self.write_count += 1;
            self.last_write = value;

            if (self.fail_write) {
                return error.UnsupportedAccessWidth;
            }

            if (offset == base + pm.offsets.control) {
                const previous = std.mem.readInt(u16, self.bytes[offset..][0..2], .little);
                const next = (previous & ~pm.Control.masks.assign & ~(value & pm.Control.masks.w1c)) |
                    (value & pm.Control.masks.assign);

                store16(self.bytes, offset, next);
                return;
            }

            store16(self.bytes, offset, value);
        }

        fn write32Unsupported(_: *anyopaque, _: Sbdf, _: usize, _: u32) ConfigError!void {
            return error.UnsupportedAccessWidth;
        }
    };

    test "PM discovery preserves unknown revision metadata and reads capabilities live" {
        for ([_]u3{ 0, 1, 2, 3, 7 }) |version| {
            var bytes: [window_size]u8 = @splat(0);
            seed(&bytes, version);

            var backend = ConfigBackend{ .bytes = &bytes };
            const cap = (try Pm.find(backend.function())).?;

            try testing.expectEqual(version, cap.version);

            store16(&bytes, base + pm.offsets.capabilities, 1 << 9);
            const current = try cap.capabilities();

            try testing.expect(current.d1_supported);
            try testing.expectEqual(@as(u3, 0), current.version);
            try testing.expectEqual(version, cap.version);
        }
    }

    test "PM discovery distinguishes absence and malformed traversal" {
        var bytes: [window_size]u8 = @splat(0);

        var backend = ConfigBackend{ .bytes = &bytes };
        try testing.expectEqual(@as(?Pm, null), try Pm.find(backend.function()));

        seed(&bytes, 3);
        bytes[core.header.offsets.cap_ptr] = 0x20;
        try testing.expectError(error.MalformedCapability, Pm.find(backend.function()));
    }

    test "PM construction rejects malformed and truncated capabilities before I/O" {
        var bytes: [window_size]u8 = @splat(0);

        var backend = ConfigBackend{ .bytes = &bytes };

        try testing.expectError(error.MalformedCapability, Pm.tryFrom(backend.function(), .{ .id = .pm, .offset = 0x20 }));
        try testing.expectError(error.MalformedCapability, Pm.tryFrom(backend.function(), .{ .id = .pm, .offset = 0x81 }));
        try testing.expectError(error.MalformedCapability, Pm.tryFrom(backend.function(), .{ .id = .pm, .offset = 0xFC }));
        try testing.expectEqual(@as(usize, 0), backend.read_count);
        try testing.expectEqual(@as(usize, 0), backend.write_count);
    }

    test "mechanical control updates preserve unselected controls without acknowledging PME" {
        var bytes: [window_size]u8 = @splat(0);
        seed(&bytes, 3);
        store16(&bytes, base + pm.offsets.control, 0xF1FB);

        var backend = ConfigBackend{ .bytes = &bytes };
        const cap = try Pm.tryFrom(backend.function(), test_entry);

        try cap.updateControl(.{ .pme_enable = false, .data_select = .dissipated_d2 });

        try testing.expectEqual(@as(u16, 0xECFB), std.mem.readInt(u16, bytes[0x84..0x86], .little));
        try testing.expectEqual(@as(u16, 0x0C03), backend.last_write);
        try testing.expectEqual(@as(usize, 2), backend.read_count);
        try testing.expectEqual(@as(usize, 1), backend.write_count);
    }

    test "PME acknowledgement preserves current controls rather than the stale observation" {
        var bytes: [window_size]u8 = @splat(0);
        seed(&bytes, 3);
        store16(&bytes, base + pm.offsets.control, 0x8303);

        var backend = ConfigBackend{ .bytes = &bytes };
        const cap = try Pm.tryFrom(backend.function(), test_entry);
        const observed = try cap.control();

        store16(&bytes, base + pm.offsets.control, 0xEC0A);
        try cap.ackPmeStatus(observed);

        try testing.expectEqual(@as(u16, 0x6C0A), std.mem.readInt(u16, bytes[0x84..0x86], .little));
        try testing.expectEqual(@as(u16, 0x8C02), backend.last_write);
        try testing.expectEqual(@as(usize, 3), backend.read_count);
        try testing.expectEqual(@as(usize, 1), backend.write_count);
    }

    test "an absent observed PME performs no I/O and cannot acknowledge a later event" {
        var bytes: [window_size]u8 = @splat(0);
        seed(&bytes, 3);
        store16(&bytes, base + pm.offsets.control, 0x0101);

        var backend = ConfigBackend{ .bytes = &bytes };
        const cap = try Pm.tryFrom(backend.function(), test_entry);
        const observed = try cap.control();

        store16(&bytes, base + pm.offsets.control, 0x8101);
        try cap.ackPmeStatus(observed);

        try testing.expectEqual(@as(u16, 0x8101), std.mem.readInt(u16, bytes[0x84..0x86], .little));
        try testing.expectEqual(@as(usize, 2), backend.read_count);
        try testing.expectEqual(@as(usize, 0), backend.write_count);
    }

    test "power-state requests validate the transition matrix without readback or automatic intermediate states" {
        for (0..4) |current| {
            for (0..4) |requested| {
                var bytes: [window_size]u8 = @splat(0);
                seed(&bytes, 3);
                store16(&bytes, base + pm.offsets.capabilities, 3 | (1 << 9) | (1 << 10));
                store16(&bytes, base + pm.offsets.control, 0xF1F8 | @as(u16, @intCast(current)));

                var backend = ConfigBackend{ .bytes = &bytes };
                const cap = try Pm.tryFrom(backend.function(), test_entry);
                const state: State = @enumFromInt(requested);

                if (requested != 0 and requested < current) {
                    try testing.expectError(error.InvalidTransition, cap.setPowerState(state));
                    try testing.expectEqual(@as(usize, 0), backend.write_count);
                    const expected = 0xF1F8 | @as(u16, @intCast(current));
                    try testing.expectEqual(expected, std.mem.readInt(u16, bytes[0x84..0x86], .little));
                } else {
                    try cap.setPowerState(state);

                    const expected = 0xF1F8 | @as(u16, @intCast(requested));
                    const payload = 0x1100 | @as(u16, @intCast(requested));

                    try testing.expectEqual(expected, std.mem.readInt(u16, bytes[0x84..0x86], .little));
                    try testing.expectEqual(payload, backend.last_write);
                    try testing.expectEqual(@as(usize, 1), backend.write_count);
                }

                const expected_reads: usize = if (requested == 1 or requested == 2) 3 else 2;
                try testing.expectEqual(expected_reads, backend.read_count);
            }
        }
    }

    test "optional-state validation is separate from mechanical control updates" {
        var bytes: [window_size]u8 = @splat(0);
        seed(&bytes, 3);
        store16(&bytes, base + pm.offsets.control, 0x8100);

        var backend = ConfigBackend{ .bytes = &bytes };
        const cap = try Pm.tryFrom(backend.function(), test_entry);

        try testing.expectError(error.UnsupportedFeature, cap.setPowerState(.d1));
        try testing.expectError(error.UnsupportedFeature, cap.setPowerState(.d2));
        try testing.expectEqual(@as(usize, 0), backend.write_count);
        try testing.expectEqual(@as(usize, 3), backend.read_count);

        try cap.updateControl(.{ .state = .d2 });
        try testing.expectEqual(@as(u16, 0x8102), std.mem.readInt(u16, bytes[0x84..0x86], .little));
    }

    test "bridge reporting requires a type-one header while optional data remains raw" {
        var bytes: [window_size]u8 = @splat(0);
        seed(&bytes, 3);
        bytes[base + pm.offsets.bridge_support] = 0xC0;

        var backend = ConfigBackend{ .bytes = &bytes };
        const cap = try Pm.tryFrom(backend.function(), test_entry);

        try testing.expectError(error.UnsupportedRegister, cap.bridgeSupport());
        try testing.expectEqual(@as(usize, 2), backend.read_count);

        bytes[core.header.offsets.type] = 1;
        const bridge = try cap.bridgeSupport();

        try testing.expect(bridge.bus_control_enabled);
        try testing.expectEqual(pm.SecondaryState.clock_stopped, bridge.secondary_state);
        try testing.expectEqual(@as(u8, 0), try cap.data());

        bytes[base + pm.offsets.data] = 0x57;
        try testing.expectEqual(@as(u8, 0x57), try cap.data());
    }

    test "PM read and write errors propagate without retries rollback or zero-data fallback" {
        var bytes: [window_size]u8 = @splat(0);
        seed(&bytes, 3);
        store16(&bytes, base + pm.offsets.control, 0x8100);

        var backend = ConfigBackend{ .bytes = &bytes, .fail_read = base + pm.offsets.capabilities };

        try testing.expectError(error.UnsupportedAccessWidth, Pm.tryFrom(backend.function(), test_entry));

        backend.fail_read = null;
        const cap = try Pm.tryFrom(backend.function(), test_entry);
        backend.fail_read = base + pm.offsets.control;

        try testing.expectError(error.UnsupportedAccessWidth, cap.updateControl(.{ .pme_enable = false }));
        try testing.expectError(error.UnsupportedAccessWidth, cap.setPowerState(.d0));
        try testing.expectError(error.UnsupportedAccessWidth, cap.ackPmeStatus(.{ .pme_status = true }));
        try testing.expectEqual(@as(usize, 0), backend.write_count);

        backend.fail_read = base + pm.offsets.data;
        try testing.expectError(error.UnsupportedAccessWidth, cap.data());

        backend.fail_read = null;
        backend.fail_write = true;

        try testing.expectError(error.UnsupportedAccessWidth, cap.updateControl(.{ .pme_enable = false }));
        try testing.expectError(error.UnsupportedAccessWidth, cap.setPowerState(.d3hot));
        try testing.expectError(error.UnsupportedAccessWidth, cap.ackPmeStatus(.{ .pme_status = true }));
        try testing.expectEqual(@as(usize, 3), backend.write_count);
        try testing.expectEqual(@as(u16, 0x8100), std.mem.readInt(u16, bytes[0x84..0x86], .little));
    }

    fn seed(bytes: *[window_size]u8, version: u3) void {
        store16(bytes, core.header.offsets.status, HeaderStatus.mask(.cap_list));
        bytes[core.header.offsets.cap_ptr] = base;
        bytes[base] = @intFromEnum(pm.id);
        store16(bytes, base + pm.offsets.capabilities, version);
    }

    fn store16(bytes: *[window_size]u8, offset: usize, value: u16) void {
        std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
    }
};
