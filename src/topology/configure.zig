const std = @import("std");
const stdx = @import("stdx");

const cfg = @import("config");
const core = @import("core");
const capabilities = @import("capabilities");
const header = @import("header");

const tree = @import("tree.zig");
const enumeration = @import("enumerate.zig");
const topology = @import("module.zig");

const Allocator = std.mem.Allocator;
const ConfigSpace = cfg.ConfigSpace;
const Function = cfg.Function;
const SegmentId = core.SegmentId;
const HeaderFormat = core.header.Format;
const Sbdf = core.Sbdf;
const Bdf = core.Bdf;
const Node = tree.Node;
const NodeId = tree.NodeId;
const Tree = tree.Tree;
const VfReservation = tree.VfReservation;
const Pcie = capabilities.pcie.Capability;
const Ari = capabilities.ari.Capability;
const Sriov = capabilities.sriov.Capability;
const Type1 = header.Type1;
const BridgeBusRange = Type1.BusRange;
const BusRange = stdx.ranges.InclusiveRange(core.bus.Index);
const NodeList = std.ArrayList(Node);
const FunctionList = std.ArrayList(FunctionInfo);
const RouteList = std.ArrayList(Type1);

pub const Root = struct {
    segment: SegmentId,
    buses: BusRange,
};

pub const AriPolicy = enum {
    preserve,
    enable_supported,
};

pub const VfCapacity = union(enum) {
    advertised,
    none,
    limit: u16,
};

pub const Args = struct {
    config: ConfigSpace,
    roots: []const Root,
    ari: AriPolicy = .preserve,
    vfs: VfCapacity = .advertised,
};

pub const Error = enumeration.Error || Function.Error || capabilities.pcie.Error ||
    capabilities.ari.Error || capabilities.sriov.Error || error{
    InvalidValue,
    ActiveVfs,
    BusRangeExhausted,
    ProgrammingReadbackMismatch,
    ProgrammingPartial,
};

pub fn configure(allocator: Allocator, args: Args) Error!*const Tree {
    for (args.roots, 0..) |root, index| {
        if (!root.buses.isValid()) {
            return error.InvalidValue;
        }

        for (args.roots[0..index]) |previous| {
            const overlaps = root.buses.start <= previous.buses.end and
                previous.buses.start <= root.buses.end;

            if (root.segment == previous.segment and overlaps) {
                return error.InvalidValue;
            }
        }
    }

    var configurator = Configurator{ .allocator = allocator, .args = args };
    defer configurator.nodes.deinit(allocator);
    defer configurator.routes.deinit(allocator);

    return configurator.run() catch |err| {
        configurator.cleanup() catch return error.ProgrammingPartial;
        return err;
    };
}

const Configurator = struct {
    allocator: Allocator,
    args: Args,
    nodes: NodeList = .empty,
    routes: RouteList = .empty,

    fn run(self: *Configurator) Error!*const Tree {
        for (self.args.roots) |root| {
            var cursor: u16 = @as(u16, root.buses.start) + 1;
            try self.configureBus(root, root.buses.start, null, 0, null, &cursor);
        }

        return enumeration.finish(self.allocator, &self.nodes);
    }

    fn cleanup(self: *Configurator) Error!void {
        var failed = false;
        var index = self.routes.items.len;

        while (index != 0) {
            index -= 1;
            closeRoute(self.routes.items[index]) catch {
                failed = true;
            };
        }

        if (failed) {
            return error.ProgrammingPartial;
        }
    }

    fn closeRoute(bridge: Type1) Error!void {
        try bridge.disableBusRouting();

        if (try bridge.secondaryBus() != 0 or try bridge.subordinateBus() != 0) {
            return error.ProgrammingReadbackMismatch;
        }
    }

    fn probeFunction(self: *Configurator, root: Root, bus: u8, number: u8) Error!?FunctionInfo {
        const bdf = Bdf.from(bus, @intCast(number >> 3), @intCast(number & 7));
        const address = Sbdf.fromBdf(root.segment, bdf);
        const function = Function.tryFrom(self.args.config, address) catch |err| switch (err) {
            error.AbsentFunction, error.BadHeaderType => return null,
            else => |other| return other,
        };

        return try FunctionInfo.from(function);
    }

    fn scanFunctions(self: *Configurator, root: Root, bus: u8, ari: bool, functions: *FunctionList) Error!void {
        functions.clearRetainingCapacity();

        if (ari) {
            var number: u8 = 0;

            while (true) {
                const info = (try self.probeFunction(root, bus, number)) orelse {
                    if (number == 0) {
                        break;
                    }

                    return error.MalformedCapability;
                };

                try functions.append(self.allocator, info);

                const capability = info.ari orelse return error.MalformedCapability;
                const next = (try capability.capabilities()).next_function;

                if (next == 0) {
                    break;
                }

                if (next <= number) {
                    return error.MalformedCapability;
                }

                number = next;
            }
        } else {
            var device: u16 = 0;

            while (device < core.device.count) : (device += 1) {
                const first = (try self.probeFunction(root, bus, @intCast(device * core.function.count))) orelse continue;
                try functions.append(self.allocator, first);

                if (try first.function.multifunction()) {
                    var number: u16 = 1;

                    while (number < core.function.count) : (number += 1) {
                        const position: u8 = @intCast(device * core.function.count + number);

                        if (try self.probeFunction(root, bus, position)) |info| {
                            try functions.append(self.allocator, info);
                        }
                    }
                }
            }
        }

        for (functions.items) |info| {
            if (info.sriov) |capability| {
                if ((try capability.control()).vf_enable) {
                    return error.ActiveVfs;
                }
            }
        }
    }

    fn configureBus(
        self: *Configurator,
        root: Root,
        bus: u8,
        parent: ?NodeId,
        depth: u8,
        upstream: ?Function,
        cursor: *u16,
    ) Error!void {
        if (depth > topology.max_depth) {
            return error.DepthExceeded;
        }

        var functions: FunctionList = .empty;
        defer functions.deinit(self.allocator);

        var ari = false;
        var port: ?Pcie = null;

        if (upstream) |function| {
            port = try Pcie.find(function);

            if (port) |capability| {
                if (capability.version >= 2) {
                    ari = (try capability.deviceControl2()).ari_forwarding_enable;
                } else {
                    port = null;
                }
            }
        }

        try self.scanFunctions(root, bus, ari, &functions);

        if (!ari and self.args.ari == .enable_supported and functions.items.len != 0) {
            if (port) |capability| {
                const first = functions.items[0];
                const bdf = first.function.sbdf.bdf;

                if (bdf.device == 0 and bdf.function == 0 and first.ari != null) {
                    const caps = try capability.deviceCapabilities2();

                    if (caps.ari_forwarding_supported) {
                        try capability.updateDeviceControl2(.{ .ari_forwarding_enable = true });

                        if (!(try capability.deviceControl2()).ari_forwarding_enable) {
                            return error.ProgrammingReadbackMismatch;
                        }

                        ari = true;
                        try self.scanFunctions(root, bus, true, &functions);
                    }
                }
            }
        }

        for (functions.items) |info| {
            if (info.format == .type1) {
                if (depth == topology.max_depth) {
                    return error.DepthExceeded;
                }

                const bridge = Type1.from(info.function);
                try self.routes.append(self.allocator, bridge);
                try closeRoute(bridge);
            }
        }

        var group: ?u5 = null;

        for (functions.items) |*info| {
            const device = info.function.sbdf.bdf.device;
            const first = group == null or (!ari and group.? != device);

            if (info.sriov) |capability| {
                group = device;

                if (first and info.pcie.?.type != .rciep) {
                    try capability.setAriHierarchy(ari);
                }

                const total = try capability.totalVfs();
                const capacity = switch (self.args.vfs) {
                    .advertised => total,
                    .none => 0,
                    .limit => |limit| @min(limit, total),
                };

                const last = try capability.reserveBuses(capacity);
                if (last > root.buses.end) {
                    return error.BusRangeExhausted;
                }

                info.reservation = .{ .capacity = capacity, .bus_end = last };
                cursor.* = @max(cursor.*, @as(u16, last) + 1);
            }
        }

        for (functions.items) |info| {
            if (self.nodes.items.len >= tree.max_nodes) {
                return error.StorageExhausted;
            }

            const id = self.nodes.items.len;
            try self.nodes.append(self.allocator, .{
                .function = info.function,
                .format = info.format,
                .parent = parent,
                .subtree_end = id + 1,
                .vfs = info.reservation,
            });

            if (info.format == .type1) {
                if (cursor.* > root.buses.end) {
                    return error.BusRangeExhausted;
                }

                const secondary: u8 = @intCast(cursor.*);
                cursor.* += 1;

                var range: BridgeBusRange = .{
                    .primary = bus,
                    .secondary = secondary,
                    .subordinate = root.buses.end,
                };

                const bridge = Type1.from(info.function);
                try bridge.setBusRange(range);

                if (!std.meta.eql(try bridge.busRange(), range)) {
                    return error.ProgrammingReadbackMismatch;
                }

                try self.configureBus(root, secondary, NodeId.from(@intCast(id)), depth + 1, info.function, cursor);

                const last: u8 = @intCast(cursor.* - 1);
                range.subordinate = last;
                try bridge.setSubordinateBus(last);

                if (!std.meta.eql(try bridge.busRange(), range)) {
                    return error.ProgrammingReadbackMismatch;
                }

                self.nodes.items[id].bus_range = .{ .start = secondary, .end = last };
            }

            self.nodes.items[id].subtree_end = self.nodes.items.len;
        }
    }
};

const FunctionInfo = struct {
    function: Function,
    format: HeaderFormat,
    pcie: ?Pcie = null,
    ari: ?Ari = null,
    sriov: ?Sriov = null,
    reservation: ?VfReservation = null,

    fn from(function: Function) Error!FunctionInfo {
        var info: FunctionInfo = .{
            .function = function,
            .format = try function.format(),
            .pcie = try Pcie.find(function),
        };

        if (info.pcie != null) {
            info.ari = try Ari.find(function);
            info.sriov = try Sriov.find(function);
        }

        return info;
    }
};

pub const unit = struct {
    const testing = std.testing;

    const ConfigError = ConfigSpace.Error;

    const window_size = core.config.extended_size;

    const Physical = struct {
        parent: ?usize = null,
        segment: SegmentId = .from(0),
        root_bus: u8 = 0,
        number: u8 = 0,
        bytes: [window_size]u8 = @splat(0),

        fn init(parent: ?usize, number: u8, bridge: bool) Physical {
            var result = Physical{ .parent = parent, .number = number };
            result.bytes[0] = 0x34;
            result.bytes[1] = 0x12;
            result.bytes[0x0e] = if (bridge) 1 else 0;
            return result;
        }
    };

    const Graph = struct {
        devices: []Physical,
        reject_routes: bool = false,
        fail_write_offset: ?usize = null,
        fail_once: bool = false,
        conventional_only: bool = false,
        reads: usize = 0,
        writes: usize = 0,

        fn config(self: *Graph) ConfigSpace {
            return ConfigSpace.from(self, &vtable);
        }

        fn reachable(self: *Graph, index: usize, bus: u8) bool {
            const physical = &self.devices[index];
            const parent = physical.parent orelse return physical.root_bus == bus;
            const bridge = &self.devices[parent];
            const secondary = bridge.bytes[0x19];

            if (secondary == 0 or secondary != bus or bridge.bytes[0x1a] < bus) {
                return false;
            }

            if (!self.reachable(parent, bridge.bytes[0x18])) {
                return false;
            }

            var ancestor = bridge.parent;

            while (ancestor) |id| {
                const upper = &self.devices[id];
                if (upper.bytes[0x19] == 0 or upper.bytes[0x19] > bus or upper.bytes[0x1a] < bus) {
                    return false;
                }

                ancestor = upper.parent;
            }

            return true;
        }

        fn bytes(self: *Graph, address: Sbdf) ?[]u8 {
            for (self.devices, 0..) |*physical, index| {
                if (physical.segment != address.segment) {
                    continue;
                }

                const number = @as(u8, address.bdf.device) * core.function.count + address.bdf.function;

                if (physical.parent) |parent| {
                    const bridge = &self.devices[parent];
                    const port_type = core.capabilities.pcie.Capabilities.from(
                        std.mem.readInt(u16, bridge.bytes[0x42..0x44], .little),
                    ).type;
                    const downstream = port_type == .root_port or port_type == .downstream;

                    if (downstream and number > 7 and bridge.bytes[0x68] & 0x20 == 0) {
                        continue;
                    }
                }

                if (number == physical.number and self.reachable(index, address.bdf.bus)) {
                    return &physical.bytes;
                }
            }
            return null;
        }

        fn read(comptime T: type, context: *anyopaque, address: Sbdf, offset: usize) ConfigError!T {
            const self: *Graph = @ptrCast(@alignCast(context));

            self.reads += 1;

            if (self.conventional_only and offset >= 256) {
                return error.OutOfBounds;
            }

            const data = self.bytes(address) orelse return std.math.maxInt(T);
            return std.mem.readInt(T, data[offset..][0..@sizeOf(T)], .little);
        }

        fn write(comptime T: type, context: *anyopaque, address: Sbdf, offset: usize, value: T) ConfigError!void {
            const self: *Graph = @ptrCast(@alignCast(context));
            const data = self.bytes(address) orelse return error.OutOfBounds;

            self.writes += 1;

            if (self.fail_write_offset == offset) {
                if (self.fail_once) {
                    self.fail_write_offset = null;
                }

                return error.OutOfBounds;
            }

            if (self.reject_routes and offset == 0x19 and value != 0) {
                return;
            }

            std.mem.writeInt(T, data[offset..][0..@sizeOf(T)], value, .little);

            if (offset == 0x130 and value != 0) {
                std.mem.writeInt(u16, data[0x134..][0..2], if (value == 1) 0x200 else 0x100, .little);
                std.mem.writeInt(u16, data[0x136..][0..2], 1, .little);
            }
        }

        fn read8(context: *anyopaque, address: Sbdf, offset: usize) ConfigError!u8 {
            return read(u8, context, address, offset);
        }

        fn read16(context: *anyopaque, address: Sbdf, offset: usize) ConfigError!u16 {
            return read(u16, context, address, offset);
        }

        fn read32(context: *anyopaque, address: Sbdf, offset: usize) ConfigError!u32 {
            return read(u32, context, address, offset);
        }

        fn write8(context: *anyopaque, address: Sbdf, offset: usize, value: u8) ConfigError!void {
            return write(u8, context, address, offset, value);
        }

        fn write16(context: *anyopaque, address: Sbdf, offset: usize, value: u16) ConfigError!void {
            return write(u16, context, address, offset, value);
        }

        fn write32(context: *anyopaque, address: Sbdf, offset: usize, value: u32) ConfigError!void {
            return write(u32, context, address, offset, value);
        }

        const vtable: ConfigSpace.VTable = .{
            .read8 = read8,
            .read16 = read16,
            .read32 = read32,
            .write8 = write8,
            .write16 = write16,
            .write32 = write32,
        };
    };

    test "cold traversal follows programmed nested and sibling physical routes" {
        var devices = [_]Physical{
            Physical.init(null, 0, true),
            Physical.init(0, 0, true),
            Physical.init(1, 0, false),
            Physical.init(null, 8, true),
            Physical.init(3, 0, false),
        };
        devices[0].root_bus = 7;
        devices[3].root_bus = 7;
        devices[0].bytes[0x19] = 99;
        devices[0].bytes[0x1a] = 110;
        devices[3].bytes[0x19] = 99;
        devices[3].bytes[0x1a] = 110;

        var graph = Graph{ .devices = &devices };
        const result = try configure(testing.allocator, .{
            .config = graph.config(),
            .roots = &.{.{ .segment = .from(0), .buses = .of(7, 20) }},
        });
        defer result.deinit(testing.allocator);

        try testing.expectEqual(@as(usize, 5), result.size);

        for ([_]u8{ 7, 8, 9, 7, 10 }, result.nodes()) |expected, node| {
            try testing.expectEqual(expected, node.function.sbdf.bdf.bus);
        }

        try testing.expectEqual(@as(u8, 9), devices[0].bytes[0x1a]);
        try testing.expectEqual(@as(u8, 10), devices[3].bytes[0x1a]);
    }

    test "rejected route writes close all discovered routes" {
        var devices = [_]Physical{Physical.init(null, 0, true)};
        var graph = Graph{ .devices = &devices, .reject_routes = true };

        try testing.expectError(error.ProgrammingReadbackMismatch, configure(testing.allocator, .{
            .config = graph.config(),
            .roots = &.{.{ .segment = .from(0), .buses = .of(0, 255) }},
        }));
        try testing.expectEqual(@as(u8, 0), devices[0].bytes[0x19]);
        try testing.expectEqual(@as(u8, 0), devices[0].bytes[0x1a]);
    }

    test "overlapping roots fail before configuration access" {
        var devices: [0]Physical = .{};
        var graph = Graph{ .devices = &devices };

        try testing.expectError(error.InvalidValue, configure(testing.allocator, .{
            .config = graph.config(),
            .roots = &.{
                .{ .segment = .from(0), .buses = .of(1, 8) },
                .{ .segment = .from(0), .buses = .of(8, 9) },
            },
        }));
        try testing.expectEqual(@as(usize, 0), graph.reads);
        try testing.expectEqual(@as(usize, 0), graph.writes);
    }

    test "ARI PF chain and variable VF geometry reserve before sibling bridges" {
        var devices = [_]Physical{
            Physical.init(null, 0, true),
            Physical.init(0, 0, false),
            Physical.init(0, 16, false),
            Physical.init(null, 8, true),
            Physical.init(3, 0, false),
        };
        express(&devices[0], 4);
        pf(&devices[1], 16);
        pf(&devices[2], 0);
        express(&devices[3], 4);

        var graph = Graph{ .devices = &devices };
        const result = try configure(testing.allocator, .{
            .config = graph.config(),
            .roots = &.{.{ .segment = .from(0), .buses = .of(0, 20) }},
            .ari = .enable_supported,
        });
        defer result.deinit(testing.allocator);

        try testing.expectEqual(@as(usize, 5), result.size);
        try testing.expectEqual(@as(u8, 4), devices[3].bytes[0x19]);
        try testing.expectEqual(@as(u8, 0x10), devices[1].bytes[0x128]);
        try testing.expectEqual(@as(u8, 0), devices[2].bytes[0x128]);
        try testing.expectEqual(@as(u8, 0), devices[1].bytes[0x130]);
        try testing.expectEqual(@as(u8, 3), result.nodes()[1].vfs.?.bus_end);
    }

    test "newly visible active PF rejects hierarchy mutation" {
        var devices = [_]Physical{
            Physical.init(null, 0, true),
            Physical.init(0, 0, false),
            Physical.init(0, 16, false),
        };
        express(&devices[0], 4);
        pf(&devices[1], 16);
        pf(&devices[2], 0);
        devices[2].bytes[0x128] = 1;

        var graph = Graph{ .devices = &devices };

        try testing.expectError(error.ActiveVfs, configure(testing.allocator, .{
            .config = graph.config(),
            .roots = &.{.{ .segment = .from(0), .buses = .of(0, 20) }},
            .ari = .enable_supported,
        }));
        try testing.expectEqual(@as(u8, 0), devices[1].bytes[0x128]);
        try testing.expectEqual(@as(u8, 0), devices[0].bytes[0x19]);
    }

    test "bus 255 is usable and exhaustion closes ancestors" {
        var devices = [_]Physical{ Physical.init(null, 0, true), Physical.init(0, 0, false) };
        devices[0].root_bus = 254;
        var graph = Graph{ .devices = &devices };

        const result = try configure(testing.allocator, .{
            .config = graph.config(),
            .roots = &.{.{ .segment = .from(0), .buses = .of(254, 255) }},
        });
        defer result.deinit(testing.allocator);

        try testing.expectEqual(@as(u8, 255), result.nodes()[1].function.sbdf.bdf.bus);

        devices[1].bytes[0x0e] = 1;

        try testing.expectError(error.BusRangeExhausted, configure(testing.allocator, .{
            .config = graph.config(),
            .roots = &.{.{ .segment = .from(0), .buses = .of(254, 255) }},
        }));
        try testing.expectEqual(@as(u8, 0), devices[0].bytes[0x19]);
        try testing.expectEqual(@as(u8, 0), devices[1].bytes[0x19]);
    }

    test "all allocation failures including final tree storage close child routes" {
        try testing.checkAllAllocationFailures(testing.allocator, allocationCase, .{});
    }

    test "ARI rejects a missing linked PF and closes the upstream route" {
        var devices = [_]Physical{ Physical.init(null, 0, true), Physical.init(0, 0, false) };
        express(&devices[0], 4);
        pf(&devices[1], 16);

        var graph = Graph{ .devices = &devices };

        try testing.expectError(error.MalformedCapability, configure(testing.allocator, .{
            .config = graph.config(),
            .roots = &.{.{ .segment = .from(0), .buses = .of(0, 20) }},
            .ari = .enable_supported,
        }));
        try testing.expectEqual(@as(u8, 0), devices[0].bytes[0x19]);
    }

    test "disjoint roots retain independent nonzero allocation cursors" {
        var devices = [_]Physical{
            Physical.init(null, 0, true),
            Physical.init(0, 0, false),
            Physical.init(null, 0, true),
            Physical.init(2, 0, false),
        };
        devices[0].root_bus = 20;
        devices[2].root_bus = 40;

        var graph = Graph{ .devices = &devices };
        const result = try configure(testing.allocator, .{
            .config = graph.config(),
            .roots = &.{
                .{ .segment = .from(0), .buses = .of(20, 29) },
                .{ .segment = .from(0), .buses = .of(40, 49) },
            },
        });
        defer result.deinit(testing.allocator);

        try testing.expectEqual(@as(usize, 4), result.size);
        try testing.expectEqual(@as(u8, 21), devices[0].bytes[0x19]);
        try testing.expectEqual(@as(u8, 41), devices[2].bytes[0x19]);
    }

    test "RCiEP leaves hierarchy control unchanged and VF none normalizes NumVFs" {
        var devices = [_]Physical{Physical.init(null, 0, false)};
        pf(&devices[0], 0);
        express(&devices[0], 9);
        devices[0].bytes[0x128] = 0x10;
        devices[0].bytes[0x130] = 2;

        var graph = Graph{ .devices = &devices };
        const result = try configure(testing.allocator, .{
            .config = graph.config(),
            .roots = &.{.{ .segment = .from(0), .buses = .of(0, 0) }},
            .vfs = .none,
        });
        defer result.deinit(testing.allocator);

        try testing.expectEqual(@as(u8, 0x10), devices[0].bytes[0x128]);
        try testing.expectEqual(@as(u8, 0), devices[0].bytes[0x130]);
        try testing.expectEqual(@as(u16, 0), result.nodes()[0].vfs.?.capacity);
    }

    test "visible active PF prevents forwarding change" {
        var devices = [_]Physical{ Physical.init(null, 0, true), Physical.init(0, 0, false) };
        express(&devices[0], 4);
        pf(&devices[1], 0);
        devices[1].bytes[0x128] = 1;

        var graph = Graph{ .devices = &devices };
        try testing.expectError(error.ActiveVfs, configure(testing.allocator, .{
            .config = graph.config(),
            .roots = &.{.{ .segment = .from(0), .buses = .of(0, 20) }},
            .ari = .enable_supported,
        }));
        try testing.expectEqual(@as(u8, 0), devices[0].bytes[0x68]);
        try testing.expectEqual(@as(u8, 1), devices[1].bytes[0x128]);
    }

    test "conventional-only backend needs no extended configuration access" {
        var devices = [_]Physical{ Physical.init(null, 0, true), Physical.init(0, 0, false) };
        var graph = Graph{ .devices = &devices, .conventional_only = true };

        const result = try configure(testing.allocator, .{
            .config = graph.config(),
            .roots = &.{.{ .segment = .from(0), .buses = .of(0, 1) }},
        });
        defer result.deinit(testing.allocator);

        try testing.expectEqual(@as(usize, 2), result.size);
    }

    test "write failures preserve the original error when cleanup succeeds" {
        var devices = [_]Physical{Physical.init(null, 0, true)};
        var graph = Graph{ .devices = &devices, .fail_write_offset = 0x1a, .fail_once = true };

        try testing.expectError(error.OutOfBounds, configure(testing.allocator, .{
            .config = graph.config(),
            .roots = &.{.{ .segment = .from(0), .buses = .of(0, 1) }},
        }));
        try testing.expectEqual(@as(u8, 0), devices[0].bytes[0x19]);
        try testing.expectEqual(@as(u8, 0), devices[0].bytes[0x1a]);
    }

    test "cleanup write failure takes ProgrammingPartial precedence" {
        var devices = [_]Physical{Physical.init(null, 0, true)};
        var graph = Graph{ .devices = &devices, .fail_write_offset = 0x19 };

        try testing.expectError(error.ProgrammingPartial, configure(testing.allocator, .{
            .config = graph.config(),
            .roots = &.{.{ .segment = .from(0), .buses = .of(0, 1) }},
        }));
    }

    test "classic routing updates only lowest PF in each device group" {
        var devices = [_]Physical{ Physical.init(null, 0, false), Physical.init(null, 1, false), Physical.init(null, 8, false) };
        for (&devices) |*device| {
            pf(device, 200);
            device.bytes[0x128] = 0x10;
        }

        devices[0].bytes[0x0e] = 0x80;

        var graph = Graph{ .devices = &devices };
        const result = try configure(testing.allocator, .{
            .config = graph.config(),
            .roots = &.{.{ .segment = .from(0), .buses = .of(0, 0) }},
            .vfs = .none,
        });
        defer result.deinit(testing.allocator);

        try testing.expectEqual(@as(usize, 3), result.size);
        try testing.expectEqual(@as(u8, 0), devices[0].bytes[0x128]);
        try testing.expectEqual(@as(u8, 0x10), devices[1].bytes[0x128]);
        try testing.expectEqual(@as(u8, 0), devices[2].bytes[0x128]);
    }

    test "independent segments can configure the same bus numbers" {
        var devices = [_]Physical{
            Physical.init(null, 0, true),
            Physical.init(0, 0, false),
            Physical.init(null, 0, true),
            Physical.init(2, 0, false),
        };
        devices[0].segment = .from(1);
        devices[1].segment = .from(1);

        var graph = Graph{ .devices = &devices };
        const result = try configure(testing.allocator, .{
            .config = graph.config(),
            .roots = &.{
                .{ .segment = .from(1), .buses = .of(0, 1) },
                .{ .segment = .from(0), .buses = .of(0, 1) },
            },
        });
        defer result.deinit(testing.allocator);

        try testing.expectEqual(@as(usize, 4), result.size);
        try testing.expectEqualSlices(NodeId, &.{ .from(2), .from(0) }, result.roots);
        try testing.expectEqual(@as(u8, 1), result.nodes()[1].function.sbdf.bdf.bus);
        try testing.expectEqual(@as(u8, 1), result.nodes()[3].function.sbdf.bdf.bus);
        try testing.expectEqual(SegmentId.from(1), result.nodes()[1].function.sbdf.segment);
        try testing.expectEqual(SegmentId.from(0), result.nodes()[3].function.sbdf.segment);
    }

    test "preserved ARI routing rejects a non-increasing PF chain" {
        var devices = [_]Physical{
            Physical.init(null, 0, true),
            Physical.init(0, 0, false),
            Physical.init(0, 16, false),
        };
        express(&devices[0], 4);
        devices[0].bytes[0x68] = 0x20;
        pf(&devices[1], 16);
        pf(&devices[2], 16);

        var graph = Graph{ .devices = &devices };

        try testing.expectError(error.MalformedCapability, configure(testing.allocator, .{
            .config = graph.config(),
            .roots = &.{.{ .segment = .from(0), .buses = .of(0, 4) }},
        }));
        try testing.expectEqual(@as(u8, 0), devices[0].bytes[0x19]);
        try testing.expectEqual(@as(u8, 0x20), devices[0].bytes[0x68]);
    }

    test "VF capacity limits retain count-dependent bus reservations" {
        var devices = [_]Physical{
            Physical.init(null, 0, true),
            Physical.init(0, 0, false),
        };
        express(&devices[0], 4);
        pf(&devices[1], 0);

        var graph = Graph{ .devices = &devices };
        const result = try configure(testing.allocator, .{
            .config = graph.config(),
            .roots = &.{.{ .segment = .from(0), .buses = .of(0, 3) }},
            .vfs = .{ .limit = 1 },
        });
        defer result.deinit(testing.allocator);

        const reservation = result.nodes()[1].vfs.?;
        try testing.expectEqual(@as(u16, 1), reservation.capacity);
        try testing.expectEqual(@as(u8, 3), reservation.bus_end);
        try testing.expectEqual(@as(u8, 3), devices[0].bytes[0x1a]);
        try testing.expectEqual(@as(u8, 0), devices[1].bytes[0x130]);
    }

    test "insufficient VF bus capacity clears NumVFs and closes the parent route" {
        var devices = [_]Physical{
            Physical.init(null, 0, true),
            Physical.init(0, 0, false),
        };
        express(&devices[0], 4);
        pf(&devices[1], 0);

        var graph = Graph{ .devices = &devices };

        try testing.expectError(error.BusRangeExhausted, configure(testing.allocator, .{
            .config = graph.config(),
            .roots = &.{.{ .segment = .from(0), .buses = .of(0, 2) }},
        }));
        try testing.expectEqual(@as(u8, 0), devices[0].bytes[0x19]);
        try testing.expectEqual(@as(u8, 0), devices[1].bytes[0x130]);
    }

    fn allocationCase(allocator: Allocator) !void {
        var devices = [_]Physical{ Physical.init(null, 0, true), Physical.init(0, 0, true), Physical.init(1, 0, false) };
        var graph = Graph{ .devices = &devices };
        const result = configure(allocator, .{
            .config = graph.config(),
            .roots = &.{.{ .segment = .from(0), .buses = .of(0, 20) }},
        }) catch |err| {
            try testing.expectEqual(@as(u8, 0), devices[0].bytes[0x19]);
            try testing.expectEqual(@as(u8, 0), devices[1].bytes[0x19]);

            return err;
        };

        result.deinit(allocator);
    }

    fn store(comptime T: type, physical: *Physical, offset: usize, value: T) void {
        std.mem.writeInt(T, physical.bytes[offset..][0..@sizeOf(T)], value, .little);
    }

    fn express(physical: *Physical, kind: u4) void {
        store(u16, physical, 6, 0x10);
        physical.bytes[0x34] = 0x40;
        physical.bytes[0x40] = 0x10;
        store(u16, physical, 0x42, @as(u16, kind) << 4 | 2);
        store(u32, physical, 0x64, if (kind == 4 or kind == 6) 0x20 else 0);
    }

    fn pf(physical: *Physical, next: u8) void {
        express(physical, 0);
        store(u32, physical, 0x100, 0x1201_000e);
        store(u16, physical, 0x104, @as(u16, next) << 8);
        store(u32, physical, 0x120, 0x0001_0010);
        store(u16, physical, 0x12e, 2);
        store(u16, physical, 0x134, 0x100);
        store(u16, physical, 0x136, 1);
    }
};
