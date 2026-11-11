//! Standard PCI capability-list traversal.

const stdx = @import("stdx");

const config = @import("config");
const core = @import("core");
const canonical = core.capabilities.standard;

const ConfigSpace = config.ConfigSpace;
const ConfigError = ConfigSpace.Error;
const Function = config.Function;
const Id = canonical.Id;
const Offset = core.Offset;
const RelativeOffset = core.RelativeOffset;
const VisitedSet = stdx.bits.Set(usize).Static(window.count);

pub const Error = ConfigError || error{MalformedCapability};

pub const Entry = struct {
    id: Id,
    offset: u8,
};

pub fn find(function: Function, target: Id) Error!?Entry {
    var iterator = try Iterator.tryFrom(function);
    return iterator.find(target);
}

pub const Iterator = struct {
    function: Function,
    head: ?u8,
    visited: VisitedSet,

    pub fn tryFrom(function: Function) Error!Iterator {
        const status = try function.status();
        if (!status.cap_list) {
            return Iterator.empty(function);
        }

        const raw_head = try function.capPtr();
        const head = raw_head & ~@as(u8, 0b11);
        if (head == 0) {
            return Iterator.empty(function);
        }

        return .{
            .function = function,
            .head = head,
            .visited = VisitedSet.init(),
        };
    }

    pub fn next(self: *Iterator) Error!?Entry {
        const p = self.head orelse return null;
        const position = try validateNodeOffset(p);
        const slot = @divExact(position.raw() - window.range.start, window.stride);

        if (self.visited.set(slot) catch unreachable) {
            return error.MalformedCapability;
        }

        const registers: Registers = .{ .function = self.function, .base = p };
        const id = try registers.read(offsets.id);
        const raw_next = try registers.read(offsets.next);

        if (raw_next & 0b11 != 0) {
            return error.MalformedCapability;
        }

        self.head = if (raw_next == 0) null else raw_next;

        return .{ .id = @enumFromInt(id), .offset = p };
    }

    pub fn find(self: *Iterator, target: Id) Error!?Entry {
        while (try self.next()) |capability| {
            if (capability.id == target) {
                return capability;
            }
        }

        return null;
    }

    fn empty(function: Function) Iterator {
        return .{
            .function = function,
            .head = null,
            .visited = VisitedSet.init(),
        };
    }
};

pub const Registers = struct {
    function: Function,
    base: u8,

    pub fn tryFrom(function: Function, base: u8) Error!Registers {
        _ = try validateNodeOffset(base);
        return .{ .function = function, .base = base };
    }

    pub fn read(self: Registers, relative: anytype) Error!AccessInt(@TypeOf(relative)) {
        return self.function.read(try self.resolve(relative));
    }

    pub fn write(self: Registers, relative: anytype, value: AccessInt(@TypeOf(relative))) Error!void {
        return self.function.write(try self.resolve(relative), value);
    }

    pub fn contains(self: Registers, relative: anytype) bool {
        const T = AccessInt(@TypeOf(relative));
        return @as(usize, self.base) + relative.raw() + @sizeOf(T) <= core.config.size;
    }

    fn resolve(self: Registers, relative: anytype) error{MalformedCapability}!Offset(AccessInt(@TypeOf(relative))) {
        if (!self.contains(relative)) {
            return error.MalformedCapability;
        }

        return Offset(AccessInt(@TypeOf(relative))).from(@as(usize, self.base) + relative.raw());
    }
};

pub const offsets = struct {
    pub const id = RelativeOffset(u8).from(canonical.offsets.id);
    pub const next = RelativeOffset(u8).from(canonical.offsets.next);
};

const window = canonical.window;

fn AccessInt(comptime T: type) type {
    return switch (T) {
        RelativeOffset(u8) => u8,
        RelativeOffset(u16) => u16,
        RelativeOffset(u32) => u32,
        else => @compileError("capability access requires a RelativeOffset"),
    };
}

fn validateNodeOffset(offset: u8) error{MalformedCapability}!Offset(u32) {
    if (!window.range.contains(offset)) {
        return error.MalformedCapability;
    }

    return Offset(u32).tryFrom(offset) catch return error.MalformedCapability;
}

pub const unit = struct {
    const std = @import("std");
    const support = @import("testing");
    const testing = std.testing;

    const head_offset = core.header.type0.offsets.cap_ptr;
    const pcie_window_size: usize = core.config.extended_size;
    const test_sbdf = Sbdf.from(.from(0), 0, 0, 0);

    const Sbdf = core.Sbdf;

    const TestConfigSpace = support.config.TestConfigSpace;

    const NoDwordConfig = struct {
        bytes: [pcie_window_size]u8 = @splat(0),
        sbdf: Sbdf = test_sbdf,

        fn config(self: *NoDwordConfig) ConfigSpace {
            return ConfigSpace.from(@ptrCast(self), &vtable);
        }

        const vtable: ConfigSpace.VTable = .{
            .read8 = read8,
            .read16 = read16,
            .read32 = read32Unsupported,
            .write8 = write8,
            .write16 = write16,
            .write32 = write32Unsupported,
        };

        fn read8(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigError!u8 {
            const self: *NoDwordConfig = @ptrCast(@alignCast(context));
            return self.bytes[byte_offset];
        }

        fn read16(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigError!u16 {
            const self: *NoDwordConfig = @ptrCast(@alignCast(context));
            return load16(&self.bytes, byte_offset);
        }

        fn read32Unsupported(_: *anyopaque, _: Sbdf, _: usize) ConfigError!u32 {
            return error.UnsupportedAccessWidth;
        }

        fn write8(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u8) ConfigError!void {
            const self: *NoDwordConfig = @ptrCast(@alignCast(context));
            self.bytes[byte_offset] = value;
        }

        fn write16(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u16) ConfigError!void {
            const self: *NoDwordConfig = @ptrCast(@alignCast(context));
            store16(&self.bytes, byte_offset, value);
        }

        fn write32Unsupported(_: *anyopaque, _: Sbdf, _: usize, _: u32) ConfigError!void {
            return error.UnsupportedAccessWidth;
        }
    };

    const offset = struct {
        const status: usize = 0x06;
    };

    const status = struct {
        const cap_list: u16 = 1 << 4;
    };

    test "tryFrom returns empty traversal when status capability bit is clear" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        bytes[head_offset] = window.range.start;
        seedCapability(&bytes, window.range.start, @intFromEnum(Id.pcie), 0);
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const function = makeFunction(&backend);

        var it = try Iterator.tryFrom(function);

        try testing.expectEqual(@as(?Entry, null), try it.next());
    }

    test "tryFrom treats a masked zero head pointer as an empty list" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        enableCapabilities(&bytes);
        bytes[head_offset] = 0b11;
        seedCapability(&bytes, window.range.start, @intFromEnum(Id.pcie), 0);
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const function = makeFunction(&backend);

        var it = try Iterator.tryFrom(function);

        try testing.expectEqual(@as(?Entry, null), try it.next());
    }

    test "iterator yields one capability and then terminates on zero next" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedHead(&bytes, window.range.start);
        seedCapability(&bytes, window.range.start, @intFromEnum(Id.pcie), 0);
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const function = makeFunction(&backend);

        var it = try Iterator.tryFrom(function);
        const cap = (try it.next()).?;

        try expectCapability(cap, @intFromEnum(Id.pcie), window.range.start);

        try testing.expectEqual(Id.pcie, cap.id);
        try testing.expectEqual(@as(?Entry, null), try it.next());
    }

    test "iterator walks multiple capabilities in next-pointer order" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedHead(&bytes, 0x40);
        seedCapability(&bytes, 0x40, 0x09, 0x80);
        seedCapability(&bytes, 0x80, @intFromEnum(Id.msi), 0xFC);
        seedCapability(&bytes, 0xFC, @intFromEnum(Id.msix), 0);
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const function = makeFunction(&backend);

        var it = try Iterator.tryFrom(function);
        const vendor = (try it.next()).?;
        const msi = (try it.next()).?;
        const msix = (try it.next()).?;

        try expectCapability(vendor, 0x09, 0x40);

        try testing.expectEqual(@as(Id, @enumFromInt(0x09)), vendor.id);
        try expectCapability(msi, @intFromEnum(Id.msi), 0x80);

        try testing.expectEqual(Id.msi, msi.id);
        try expectCapability(msix, @intFromEnum(Id.msix), 0xFC);

        try testing.expectEqual(Id.msix, msix.id);
        try testing.expectEqual(@as(?Entry, null), try it.next());
    }

    test "find returns first matching capability and null when absent" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedHead(&bytes, 0x40);
        seedCapability(&bytes, 0x40, 0x09, 0x80);
        seedCapability(&bytes, 0x80, @intFromEnum(Id.msi), 0xC0);
        seedCapability(&bytes, 0xC0, @intFromEnum(Id.msix), 0);
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const function = makeFunction(&backend);

        const msi = (try find(function, Id.msi)).?;
        var it = try Iterator.tryFrom(function);
        const msix = (try it.find(Id.msix)).?;

        try expectCapability(msi, @intFromEnum(Id.msi), 0x80);
        try expectCapability(msix, @intFromEnum(Id.msix), 0xC0);

        try testing.expectEqual(@as(?Entry, null), try find(function, Id.pcie));
        try testing.expectEqual(@as(?Entry, null), try it.next());
    }

    test "iterator rejects an initial head outside the capability window" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedHead(&bytes, window.range.start - window.stride);
        seedCapability(&bytes, window.range.start, @intFromEnum(Id.pcie), 0);
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const function = makeFunction(&backend);

        try expectMalformedFirstStep(function);
    }

    test "iterator rejects reserved bits in a next pointer before yielding node" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedHead(&bytes, window.range.start);
        seedCapability(&bytes, window.range.start, @intFromEnum(Id.pcie), 0x42);
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const function = makeFunction(&backend);

        var it = try Iterator.tryFrom(function);

        try testing.expectError(error.MalformedCapability, it.next());
    }

    test "iterator rejects next pointers outside the capability window" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedHead(&bytes, window.range.start);
        seedCapability(&bytes, window.range.start, @intFromEnum(Id.pcie), 0x20);
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const function = makeFunction(&backend);

        var it = try Iterator.tryFrom(function);
        const cap = (try it.next()).?;

        try expectCapability(cap, @intFromEnum(Id.pcie), window.range.start);

        try testing.expectError(error.MalformedCapability, it.next());
    }

    test "iterator detects cycles without losing already yielded nodes" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedHead(&bytes, 0x40);
        seedCapability(&bytes, 0x40, @intFromEnum(Id.pcie), 0x44);
        seedCapability(&bytes, 0x44, @intFromEnum(Id.msi), 0x40);
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const function = makeFunction(&backend);

        var it = try Iterator.tryFrom(function);
        try expectCapability((try it.next()).?, @intFromEnum(Id.pcie), 0x40);
        try expectCapability((try it.next()).?, @intFromEnum(Id.msi), 0x44);

        try testing.expectError(error.MalformedCapability, it.next());
    }

    test "find reports malformed lists instead of returning absence" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedHead(&bytes, 0x40);
        seedCapability(&bytes, 0x40, @intFromEnum(Id.msi), 0x44);
        seedCapability(&bytes, 0x44, @intFromEnum(Id.msix), 0x40);
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const function = makeFunction(&backend);

        try testing.expectError(error.MalformedCapability, find(function, Id.pcie));
    }

    test "Registers.tryFrom rejects bases outside aligned capability slots" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const function = makeFunction(&backend);

        try testing.expectError(error.MalformedCapability, Registers.tryFrom(function, window.range.start - 1));
        try testing.expectError(error.MalformedCapability, Registers.tryFrom(function, window.range.start + 1));
    }

    test "Registers reads and writes relative to its capability base" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        bytes[0x40] = 0x12;
        store16(&bytes, 0x42, 0xBEEF);
        store32(&bytes, 0x44, 0xCAFE_BABE);
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const function = makeFunction(&backend);
        const registers = try Registers.tryFrom(function, 0x40);

        try testing.expectEqual(@as(u8, 0x12), try registers.read(RelativeOffset(u8).from(0x00)));
        try testing.expectEqual(@as(u16, 0xBEEF), try registers.read(RelativeOffset(u16).from(0x02)));
        try testing.expectEqual(@as(u32, 0xCAFE_BABE), try registers.read(RelativeOffset(u32).from(0x04)));

        try registers.write(RelativeOffset(u8).from(0x08), 0x5A);
        try registers.write(RelativeOffset(u16).from(0x0A), 0x1234);
        try registers.write(RelativeOffset(u32).from(0x0C), 0xDEAD_BEEF);

        try testing.expectEqual(@as(u8, 0x5A), bytes[0x48]);
        try testing.expectEqual(@as(u16, 0x1234), load16(&bytes, 0x4A));
        try testing.expectEqual(@as(u32, 0xDEAD_BEEF), load32(&bytes, 0x4C));
    }

    test "Registers maps rebasing beyond the configuration window to MalformedCapability" {
        var bytes: [pcie_window_size]u8 = @splat(0xA5);
        const before = bytes;
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const function = makeFunction(&backend);
        const registers = try Registers.tryFrom(function, 0xFC);

        try testing.expect(registers.contains(RelativeOffset(u8).from(3)));
        try testing.expect(registers.contains(RelativeOffset(u16).from(2)));
        try testing.expect(registers.contains(RelativeOffset(u32).from(0)));
        try testing.expectEqual(@as(u8, 0xA5), try registers.read(RelativeOffset(u8).from(3)));
        try testing.expectEqual(@as(u16, 0xA5A5), try registers.read(RelativeOffset(u16).from(2)));
        try testing.expectEqual(@as(u32, 0xA5A5_A5A5), try registers.read(RelativeOffset(u32).from(0)));
        try testing.expectError(error.UnalignedAccess, RelativeOffset(u16).tryFrom(1));
        try testing.expectError(error.UnalignedAccess, RelativeOffset(u32).tryFrom(2));
        try testing.expectError(error.MalformedCapability, registers.read(RelativeOffset(u8).from(0x04)));
        try testing.expectError(error.MalformedCapability, registers.write(RelativeOffset(u8).from(0x04), 0));
        try testing.expect(!registers.contains(RelativeOffset(u32).from(0xFFC)));
        try testing.expectError(error.MalformedCapability, registers.read(RelativeOffset(u32).from(0xFFC)));
        try testing.expectEqualSlices(u8, &before, &bytes);
    }

    test "Registers propagates backend errors after its own validation passes" {
        var backend = NoDwordConfig{};
        const function = Function.from(backend.config(), backend.sbdf);
        const registers = try Registers.tryFrom(function, window.range.start);

        try testing.expectError(error.UnsupportedAccessWidth, registers.read(RelativeOffset(u32).from(0x00)));
        try testing.expectError(error.UnsupportedAccessWidth, registers.write(RelativeOffset(u32).from(0x00), 0));
        try testing.expect(!registers.contains(RelativeOffset(u32).from(0xFFC)));
        try testing.expectError(error.MalformedCapability, registers.read(RelativeOffset(u32).from(0xFFC)));
        try testing.expectError(error.MalformedCapability, registers.write(RelativeOffset(u32).from(0xFFC), 0));

        try registers.write(RelativeOffset(u16).from(0x02), 0x55AA);

        try testing.expectEqual(@as(u16, 0x55AA), try registers.read(RelativeOffset(u16).from(0x02)));
    }

    fn makeFunction(backend: *TestConfigSpace) Function {
        return Function.from(backend.config(), test_sbdf);
    }

    fn enableCapabilities(bytes: *[pcie_window_size]u8) void {
        store16(bytes, offset.status, status.cap_list);
    }

    fn seedHead(bytes: *[pcie_window_size]u8, head: u8) void {
        enableCapabilities(bytes);
        bytes[head_offset] = head;
    }

    fn seedCapability(bytes: *[pcie_window_size]u8, base: u8, id: u8, next: u8) void {
        store16(bytes, base, core.capabilities.standard.Header.encode(.{
            .id = @as(Id, @enumFromInt(id)),
            .next = next,
        }));
    }

    fn expectCapability(cap: Entry, id: u8, cap_offset: u8) !void {
        try testing.expectEqual(id, @intFromEnum(cap.id));
        try testing.expectEqual(cap_offset, cap.offset);
    }

    fn expectMalformedFirstStep(function: Function) !void {
        var it = Iterator.tryFrom(function) catch |err| {
            try testing.expectEqual(error.MalformedCapability, err);
            return;
        };

        try testing.expectError(error.MalformedCapability, it.next());
    }

    fn store16(bytes: []u8, byte_offset: usize, value: u16) void {
        std.mem.writeInt(u16, bytes[byte_offset..][0..@sizeOf(u16)], value, .little);
    }

    fn store32(bytes: []u8, byte_offset: usize, value: u32) void {
        std.mem.writeInt(u32, bytes[byte_offset..][0..@sizeOf(u32)], value, .little);
    }

    fn load16(bytes: []const u8, byte_offset: usize) u16 {
        return std.mem.readInt(u16, bytes[byte_offset..][0..@sizeOf(u16)], .little);
    }

    fn load32(bytes: []const u8, byte_offset: usize) u32 {
        return std.mem.readInt(u32, bytes[byte_offset..][0..@sizeOf(u32)], .little);
    }
};
