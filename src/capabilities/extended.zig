//! PCI Express extended capability-list traversal.

const stdx = @import("stdx");

const config = @import("config");
const core = @import("core");
const extended = core.capabilities.extended;

const ConfigSpace = config.ConfigSpace;
const ConfigError = ConfigSpace.Error;
const Function = config.Function;
const Id = extended.Id;
const Header = extended.Header;
const Offset = core.Offset;
const RelativeOffset = core.RelativeOffset;
const VisitedSet = stdx.bits.Set(usize).Static(window.count);

pub const Error = ConfigError || error{MalformedCapability};

pub const Entry = struct {
    id: Id,
    version: u4,
    offset: u16,
};

pub fn find(function: Function, target: Id) Error!?Entry {
    var iterator = try Iterator.tryFrom(function);
    return iterator.find(target);
}

pub const Iterator = struct {
    function: Function,
    head: ?u16,
    visited: VisitedSet,

    pub fn tryFrom(function: Function) Error!Iterator {
        const registers = try Registers.tryFrom(function, window.range.start);
        const head = try registers.read(offsets.header);
        if (head == 0 or head == 0xFFFF_FFFF) {
            return Iterator.empty(function);
        }

        return .{
            .function = function,
            .head = window.range.start,
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
        const raw = Header.from(try registers.read(offsets.header));
        const next_offset: u16 = raw.next;

        self.head = if (next_offset == 0) null else next_offset;

        return .{
            .id = raw.id,
            .version = raw.version,
            .offset = p,
        };
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
    base: u16,

    pub fn tryFrom(function: Function, base: u16) Error!Registers {
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
        return @as(usize, self.base) + relative.raw() + @sizeOf(T) <= core.config.extended_size;
    }

    fn resolve(self: Registers, relative: anytype) error{MalformedCapability}!Offset(AccessInt(@TypeOf(relative))) {
        if (!self.contains(relative)) {
            return error.MalformedCapability;
        }

        return Offset(AccessInt(@TypeOf(relative))).from(@as(usize, self.base) + relative.raw());
    }
};

pub const offsets = struct {
    pub const header = RelativeOffset(u32).from(0);
};

const window = extended.window;

fn AccessInt(comptime T: type) type {
    return switch (T) {
        RelativeOffset(u8) => u8,
        RelativeOffset(u16) => u16,
        RelativeOffset(u32) => u32,
        else => @compileError("capability access requires a RelativeOffset"),
    };
}

fn validateNodeOffset(offset: u16) error{MalformedCapability}!Offset(u32) {
    if (!window.range.contains(offset)) {
        return error.MalformedCapability;
    }

    return Offset(u32).tryFrom(offset) catch return error.MalformedCapability;
}

pub const unit = struct {
    const std = @import("std");
    const support = @import("testing");
    const testing = std.testing;

    const pcie_window_size: usize = core.config.extended_size;

    const Sbdf = core.Sbdf;

    const TestConfigSpace = support.config.TestConfigSpace;

    const NoDwordConfig = struct {
        bytes: [pcie_window_size]u8 = @splat(0),

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

            return std.mem.readInt(u16, self.bytes[byte_offset..][0..@sizeOf(u16)], .little);
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

            std.mem.writeInt(u16, self.bytes[byte_offset..][0..@sizeOf(u16)], value, .little);
        }

        fn write32Unsupported(_: *anyopaque, _: Sbdf, _: usize, _: u32) ConfigError!void {
            return error.UnsupportedAccessWidth;
        }
    };

    test "iterator treats absent extended config and zero head as empty" {
        const heads = [_]u32{
            0xFFFF_FFFF,
            0x0000_0000,
        };

        for (heads) |head| {
            var bytes: [pcie_window_size]u8 = @splat(0xA5);
            store32(&bytes, window.range.start, head);
            const sbdf = Sbdf.from(.from(0), 0, 0, 0);
            var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
            const function = Function.from(backend.config(), sbdf);

            var it = try Iterator.tryFrom(function);

            try testing.expectEqual(@as(?Entry, null), try it.next());
            try testing.expectEqual(@as(?Entry, null), try find(function, @enumFromInt(0x0001)));
        }
    }

    test "iterator yields a single extended capability and terminates" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        storeHeader(&bytes, window.range.start, 0x0001, 3, 0);
        const sbdf = Sbdf.from(.from(0), 0, 1, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);

        var it = try Iterator.tryFrom(function);
        const cap = (try it.next()).?;

        try expectCapability(cap, .{ .id = 0x0001, .version = 3, .offset = window.range.start });

        try testing.expectEqual(@as(Id, @enumFromInt(0x0001)), cap.id);
        try testing.expectEqual(@as(?Entry, null), try it.next());
    }

    test "iterator traverses multiple extended capabilities through the end slot" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        storeHeader(&bytes, window.range.start, 0x0001, 1, 0x120);
        storeHeader(&bytes, 0x120, 0x0002, 5, window.range.end);
        storeHeader(&bytes, window.range.end, 0x0003, 15, 0);
        const sbdf = Sbdf.from(.from(0), 0, 2, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);

        var it = try Iterator.tryFrom(function);
        try expectCapability((try it.next()).?, .{ .id = 0x0001, .version = 1, .offset = window.range.start });
        try expectCapability((try it.next()).?, .{ .id = 0x0002, .version = 5, .offset = 0x120 });
        try expectCapability((try it.next()).?, .{ .id = 0x0003, .version = 15, .offset = window.range.end });

        try testing.expectEqual(@as(?Entry, null), try it.next());
    }

    test "find returns the first matching capability and null for a terminated miss" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        storeHeader(&bytes, window.range.start, 0x000A, 1, 0x108);
        storeHeader(&bytes, 0x108, 0x000B, 2, 0x110);
        storeHeader(&bytes, 0x110, 0x000C, 3, 0);
        const sbdf = Sbdf.from(.from(0), 0, 3, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);

        var it = try Iterator.tryFrom(function);
        try expectCapability((try it.find(@enumFromInt(0x000B))).?, .{ .id = 0x000B, .version = 2, .offset = 0x108 });

        try testing.expectEqual(@as(?Entry, null), try find(function, @enumFromInt(0x9999)));
    }

    test "iterator rejects next pointers outside extended capability slots" {
        const next_offsets = [_]u16{
            0x0FC,
            0x102,
        };

        for (next_offsets) |next| {
            var bytes: [pcie_window_size]u8 = @splat(0);
            storeHeader(&bytes, window.range.start, 0x000D, 1, next);
            const sbdf = Sbdf.from(.from(0), 0, 4, 0);
            var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
            const function = Function.from(backend.config(), sbdf);

            var it = try Iterator.tryFrom(function);
            try expectCapability((try it.next()).?, .{ .id = 0x000D, .version = 1, .offset = window.range.start });

            try testing.expectError(error.MalformedCapability, it.next());
        }
    }

    test "iterator detects cycles before yielding a repeated capability" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        storeHeader(&bytes, window.range.start, 0x0010, 1, 0x108);
        storeHeader(&bytes, 0x108, 0x0011, 2, window.range.start);
        const sbdf = Sbdf.from(.from(0), 0, 5, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);

        var it = try Iterator.tryFrom(function);
        try expectCapability((try it.next()).?, .{ .id = 0x0010, .version = 1, .offset = window.range.start });
        try expectCapability((try it.next()).?, .{ .id = 0x0011, .version = 2, .offset = 0x108 });

        try testing.expectError(error.MalformedCapability, it.next());
    }

    test "registers rejects bases outside extended capability slots" {
        const bases = [_]u16{
            0x0FC,
            0x1000,
            0x102,
        };

        var bytes: [pcie_window_size]u8 = @splat(0);
        const sbdf = Sbdf.from(.from(0), 0, 6, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);

        for (bases) |base| {
            try testing.expectError(error.MalformedCapability, Registers.tryFrom(function, base));
        }
    }

    test "registers reads and writes relative to an extended capability base" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        store32(&bytes, 0x130, 0xDEAD_BEEF);
        const sbdf = Sbdf.from(.from(0), 0, 7, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);

        const registers = try Registers.tryFrom(function, 0x120);

        try testing.expectEqual(@as(u32, 0xDEAD_BEEF), try registers.read(RelativeOffset(u32).from(0x10)));

        try registers.write(RelativeOffset(u16).from(0x12), 0xCAFE);
        try registers.write(RelativeOffset(u8).from(0x1F), 0x7E);

        try testing.expectEqual(@as(u16, 0xCAFE), load16(&bytes, 0x132));
        try testing.expectEqual(@as(u8, 0x7E), bytes[0x13F]);
    }

    test "registers maps rebasing beyond the configuration window to MalformedCapability" {
        var bytes: [pcie_window_size]u8 = @splat(0x5A);
        const sbdf = Sbdf.from(.from(0), 0, 8, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);

        const end = try Registers.tryFrom(function, window.range.end);

        try testing.expect(end.contains(RelativeOffset(u8).from(3)));
        try testing.expect(end.contains(RelativeOffset(u16).from(2)));
        try testing.expect(end.contains(RelativeOffset(u32).from(0)));
        try testing.expectEqual(@as(u16, 0x5A5A), try end.read(RelativeOffset(u16).from(2)));
        try testing.expectEqual(@as(u32, 0x5A5A_5A5A), try end.read(RelativeOffset(u32).from(0)));
        try testing.expectError(error.UnalignedAccess, RelativeOffset(u16).tryFrom(1));
        try testing.expectError(error.UnalignedAccess, RelativeOffset(u32).tryFrom(2));
        try testing.expect(!end.contains(RelativeOffset(u32).from(0xFFC)));
        try testing.expectError(error.MalformedCapability, end.read(RelativeOffset(u32).from(0xFFC)));

        try testing.expectEqual(@as(u8, 0x5A), try end.read(RelativeOffset(u8).from(3)));
        try testing.expectError(error.MalformedCapability, end.read(RelativeOffset(u8).from(4)));
        try testing.expectError(error.MalformedCapability, end.write(RelativeOffset(u8).from(4), 0));
        try testing.expectEqual(@as(u8, 0x5A), bytes[0xFFF]);
    }

    test "registers propagates backend width failures after prevalidation succeeds" {
        var backend = NoDwordConfig{};
        const sbdf = Sbdf.from(.from(0), 0, 9, 0);
        const function = Function.from(backend.config(), sbdf);

        const registers = try Registers.tryFrom(function, window.range.start);

        try testing.expectError(error.UnsupportedAccessWidth, registers.read(RelativeOffset(u32).from(0)));
        try testing.expectError(error.UnsupportedAccessWidth, registers.write(RelativeOffset(u32).from(0), 0));
        try testing.expect(!registers.contains(RelativeOffset(u32).from(0xFFC)));
        try testing.expectError(error.MalformedCapability, registers.read(RelativeOffset(u32).from(0xFFC)));
        try testing.expectError(error.MalformedCapability, registers.write(RelativeOffset(u32).from(0xFFC), 0));
    }

    fn expectCapability(cap: Entry, expected: struct {
        id: u16,
        version: u4,
        offset: u16,
    }) !void {
        try testing.expectEqual(expected.id, @intFromEnum(cap.id));
        try testing.expectEqual(expected.version, cap.version);
        try testing.expectEqual(expected.offset, cap.offset);
    }

    fn storeHeader(bytes: *[pcie_window_size]u8, byte_offset: u16, id: u16, version: u4, next: u16) void {
        store32(bytes, byte_offset, header(id, version, next));
    }

    fn header(id: u16, version: u4, next: u16) u32 {
        return Header.encode(.{
            .id = @as(Id, @enumFromInt(id)),
            .version = version,
            .next = @as(u12, @intCast(next)),
        });
    }

    fn store32(bytes: *[pcie_window_size]u8, byte_offset: usize, value: u32) void {
        std.mem.writeInt(u32, bytes[byte_offset..][0..@sizeOf(u32)], value, .little);
    }

    fn load16(bytes: *const [pcie_window_size]u8, byte_offset: usize) u16 {
        return std.mem.readInt(u16, bytes[byte_offset..][0..@sizeOf(u16)], .little);
    }
};
