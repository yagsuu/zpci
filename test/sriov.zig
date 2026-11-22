const std = @import("std");
const pci = @import("pci");

const sriov = pci.capabilities.sriov;

const ConfigSpace = pci.config.ConfigSpace;
const ConfigError = ConfigSpace.Error;
const Function = pci.config.Function;
const Sbdf = pci.core.Sbdf;
const Requirement = pci.resources.Requirement;
const AssignmentNode = pci.resources.assignment.Node;

const testing = std.testing;

const pf = Sbdf.from(.from(0), 2, 0, 7);

const ConfigBackend = struct {
    bytes: [4096]u8 = @splat(0),
    probing: [6]bool = @splat(false),
    quiet: bool = false,
    ready: bool = false,
    vf_requests: usize = 0,
    quiet_accesses: usize = 0,
    pf_command_writes: usize = 0,

    const vtable: ConfigSpace.VTable = .{
        .read8 = read8,
        .read16 = read16,
        .read32 = read32,
        .write8 = write8,
        .write16 = write16,
        .write32 = write32,
    };

    fn config(self: *ConfigBackend) ConfigSpace {
        return .from(self, &vtable);
    }

    fn access(self: *ConfigBackend, address: Sbdf, offset: usize) ConfigError!void {
        if (!address.eql(pf)) {
            self.vf_requests += 1;
            if (!self.ready or load16(&self.bytes, 0x108) & 1 == 0) {
                return error.OutOfBounds;
            }
        } else if (self.quiet and offset >= 0x100) {
            self.quiet_accesses += 1;
            return error.OutOfBounds;
        }
    }

    fn read8(context: *anyopaque, address: Sbdf, offset: usize) ConfigError!u8 {
        const self: *ConfigBackend = @ptrCast(@alignCast(context));
        try self.access(address, offset);
        return self.bytes[offset];
    }

    fn read16(context: *anyopaque, address: Sbdf, offset: usize) ConfigError!u16 {
        const self: *ConfigBackend = @ptrCast(@alignCast(context));
        try self.access(address, offset);

        if (!address.eql(pf) and offset == 0) {
            return 0x1234;
        }

        return load16(&self.bytes, offset);
    }

    fn read32(context: *anyopaque, address: Sbdf, offset: usize) ConfigError!u32 {
        const self: *ConfigBackend = @ptrCast(@alignCast(context));
        try self.access(address, offset);

        if (offset >= 0x124 and offset < 0x13C) {
            const slot = (offset - 0x124) / 4;
            if (self.probing[slot]) {
                if (slot != 0) {
                    return 0;
                }

                const page = std.mem.readInt(u32, self.bytes[0x120..0x124], .little);
                return if (page == 0x10) 0xFFFF_0000 else 0xFFFF_F000;
            }
        }

        return std.mem.readInt(u32, self.bytes[offset..][0..4], .little);
    }

    fn write8(_: *anyopaque, _: Sbdf, _: usize, _: u8) ConfigError!void {
        return error.UnsupportedAccessWidth;
    }

    fn write16(context: *anyopaque, address: Sbdf, offset: usize, value: u16) ConfigError!void {
        const self: *ConfigBackend = @ptrCast(@alignCast(context));
        try self.access(address, offset);

        if (offset == 4) {
            self.pf_command_writes += 1;
        }

        if (offset == 0x108 and load16(&self.bytes, offset) & 1 != 0 and value & 1 == 0) {
            self.quiet = true;
        }

        store16(&self.bytes, offset, value);
    }

    fn write32(context: *anyopaque, address: Sbdf, offset: usize, value: u32) ConfigError!void {
        const self: *ConfigBackend = @ptrCast(@alignCast(context));
        try self.access(address, offset);

        if (offset == 0x120) {
            for (0..6) |i| {
                store32(&self.bytes, 0x124 + i * 4, 0);
            }
        }

        if (offset >= 0x124 and offset < 0x13C) {
            const slot = (offset - 0x124) / 4;
            self.probing[slot] = value == 0xFFFF_FFFF;
            if (self.probing[slot]) {
                return;
            }
        }

        store32(&self.bytes, offset, value);
    }
};

test "VF page selection probing allocation and activation preserve explicit readiness boundaries" {
    var backend: ConfigBackend = .{};
    store16(&backend.bytes, 4, 0x0006);
    store16(&backend.bytes, 0x108, 0x0010);
    store16(&backend.bytes, 0x10E, 3);
    store16(&backend.bytes, 0x114, 2);
    store16(&backend.bytes, 0x116, 2);
    store32(&backend.bytes, 0x11C, 0x11);
    store32(&backend.bytes, 0x120, 1);
    store32(&backend.bytes, 0x124, 0xA000_0000);

    const function = Function.from(backend.config(), pf);
    const cap = try sriov.Capability.tryFrom(function, .{ .id = .sriov, .version = 1, .offset = 0x100 });

    try cap.setPageSize(.size_64k);
    const bars = cap.bars();
    const probed = try bars.probe(0);

    try testing.expectEqual(@as(u64, 0x10000), probed.type.memory.size.?);
    try testing.expectEqual(@as(u64, 0), probed.type.memory.base);

    const requirement = (try Requirement.fromVfBar(bars, probed, 3)).?;
    const requirements = [_]Requirement{requirement};
    const nodes = [_]AssignmentNode{.{ .parent = null, .type = .endpoint, .requirements = &requirements }};
    const assignments = try pci.resources.assign(testing.allocator, .{
        .nodes = &nodes,
        .roots = &.{0},
        .apertures = .{ .mmio32 = .{ .type = .mmio32, .bounds = .{ .start = 0x8000_0000, .end = 0x8003_0000 } } },
    });
    defer testing.allocator.free(assignments);

    try pci.resources.commit(assignments);
    try testing.expectEqual(@as(u32, 0x8000_0000), std.mem.readInt(u32, backend.bytes[0x124..0x128], .little));
    try testing.expectEqual(@as(u64, 0x30000), assignments[0].requirement.size);
    try testing.expectEqual(@as(u64, 0x10000), assignments[0].requirement.alignment);
    try testing.expectEqual(@as(usize, 0), backend.pf_command_writes);

    try cap.setNumVfs(3);
    const routing = try cap.routing();
    try cap.setMemoryEnabled(true);
    try cap.enable();
    try testing.expectEqual(@as(usize, 0), backend.vf_requests);

    backend.ready = true;
    const vendor = pci.core.Offset(u16).from(0);
    for (0..3) |i| {
        const vf = try routing.vf(@intCast(i));
        try testing.expectEqual(@as(u16, @intCast(0x209 + i * 2)), vf.bdf.raw());
        try testing.expectEqual(@as(u16, 0x1234), try backend.config().read(vf, vendor));
    }

    try cap.disable();
    try testing.expect(backend.quiet);
    try testing.expectEqual(@as(usize, 0), backend.quiet_accesses);
    try testing.expectEqual(@as(u16, 3), load16(&backend.bytes, 0x110));

    backend.quiet = false;
    try cap.setNumVfs(0);
    try testing.expectEqual(@as(u16, 0), load16(&backend.bytes, 0x110));
}

fn load16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn store16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn store32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
