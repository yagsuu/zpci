//! Read-only PCI topology enumeration. Spec: docs/specs/topology/enumerate.md.

const std = @import("std");

const bdf = @import("../core/bdf.zig");
const capabilities = @import("../capabilities.zig");
const config = @import("../config.zig");
const core = @import("../core.zig");
const header = @import("../header.zig");
const tree = @import("tree.zig");

pub const Node = tree.Node;
pub const NodeIndex = tree.NodeIndex;

pub const Error = tree.Error || config.ConfigSpace.Error;

pub const Input = struct {
    config: config.ConfigSpace,
    segments: []const config.Segment,
    nodes: []Node,
    roots: []NodeIndex,
};

const Walk = struct {
    input: Input,
    count: usize = 0,

    fn finish(self: *Walk) Error!tree.Tree {
        return tree.intoScratch(self.input.nodes[0..self.count], self.input.roots);
    }
};

/// Enumerates present functions into caller node/root scratch.
/// I/O: config reads. Order: segment, bus, device, function.
/// Lifetime: returned `Tree` aliases filled scratch prefixes.
/// Errors: `StorageExhausted` before tree assembly when scratch is short.
pub fn intoScratch(input: Input) Error!tree.Tree {
    var walk = Walk{ .input = input };

    for (input.segments) |segment| {
        try walkBus(&walk, segment, segment.bus_start, null, 0, false);
    }

    return walk.finish();
}

/// Returns a node-scratch upper bound for `segments`, capped at `tree.max_nodes`.
/// No allocation or I/O.
pub fn sizeBound(segments: []const config.Segment) usize {
    var total: usize = 0;
    for (segments) |segment| {
        const bus_count = @as(usize, segment.bus_end) - @as(usize, segment.bus_start) + 1;
        total = @min(total + bus_count * 256, tree.max_nodes);
        if (total == tree.max_nodes) break;
    }

    return total;
}

fn walkBus(
    walk: *Walk,
    segment: config.Segment,
    bus: u8,
    parent: ?NodeIndex,
    depth: u8,
    ari_mode: bool,
) Error!void {
    std.debug.assert(depth < tree.max_depth);
    if (depth >= tree.max_depth) return;

    if (ari_mode) {
        var function: u16 = 0;
        while (function < 256) : (function += 1) {
            const device: u8 = @intCast(function >> 3);
            const slot_function: u8 = @intCast(function & 0b111);
            _ = try emit(walk, segment, bus, device, slot_function, parent, depth);
        }

        return;
    }

    var device: u8 = 0;
    while (device < bdf.max_device) : (device += 1) {
        const function0 = try probe(walk, segment, bus, device, parent, depth);
        if (function0) |function| {
            if (try function.isMultifunction()) {
                var sibling: u8 = 1;
                while (sibling < bdf.max_function) : (sibling += 1) {
                    _ = try emit(walk, segment, bus, device, sibling, parent, depth);
                }
            }
        }
    }
}

fn probe(
    walk: *Walk,
    segment: config.Segment,
    bus: u8,
    device: u8,
    parent: ?NodeIndex,
    depth: u8,
) Error!?config.Function {
    const function = try emit(walk, segment, bus, device, 0, parent, depth);
    return function;
}

fn emit(
    walk: *Walk,
    segment: config.Segment,
    bus: u8,
    device: u8,
    function: u8,
    parent: ?NodeIndex,
    depth: u8,
) Error!?config.Function {
    const sbdf = sbdfFromParts(segment.segment, bus, device, function);
    const view = config.Function.validate(walk.input.config, sbdf) catch |err| switch (err) {
        error.AbsentFunction, error.BadHeaderType => return null,
        error.OutOfBounds => return error.OutOfBounds,
        error.UnsupportedAccessWidth => return error.UnsupportedAccessWidth,
        error.UnalignedAccess => return error.UnalignedAccess,
    };
    const header_kind = view.headerKind() catch |err| switch (err) {
        error.AbsentFunction, error.BadHeaderType => return null,
        error.OutOfBounds => return error.OutOfBounds,
        error.UnsupportedAccessWidth => return error.UnsupportedAccessWidth,
        error.UnalignedAccess => return error.UnalignedAccess,
    };

    if (walk.count == walk.input.nodes.len) return error.StorageExhausted;

    const my_index = walk.count;
    walk.input.nodes[my_index] = .{
        .sbdf = sbdf,
        .function = view,
        .header_kind = header_kind,
        .parent = parent,
    };
    walk.count += 1;

    if (header_kind == .type1) {
        const bridge = header.type1.View.init(view);
        const secondary_bus = try bridge.secondaryBus();
        const subordinate_bus = try bridge.subordinateBus();
        if (validSecondaryBus(bus, secondary_bus, subordinate_bus, segment)) {
            const child_ari_mode = try ariForwardingEnabled(view);
            try walkBus(walk, segment, secondary_bus, @intCast(my_index), depth + 1, child_ari_mode);
        }
    }

    return view;
}

fn sbdfFromParts(segment: core.SegmentId, bus: u8, device: u8, function: u8) core.Sbdf {
    std.debug.assert(device < bdf.max_device);
    std.debug.assert(function < bdf.max_function);

    return core.Sbdf.init(segment, core.Bdf.from(bus, device, function) catch unreachable);
}

fn validSecondaryBus(current_bus: u8, secondary_bus: u8, subordinate_bus: u8, segment: config.Segment) bool {
    if (secondary_bus == 0) return false;
    if (secondary_bus <= current_bus) return false;
    if (secondary_bus > segment.bus_end) return false;
    if (secondary_bus > subordinate_bus) return false;

    return true;
}

fn ariForwardingEnabled(function: config.Function) config.ConfigSpace.Error!bool {
    var iterator = capabilities.list.Iterator.validate(function) catch |err| switch (err) {
        error.MalformedCapability => return false,
        error.OutOfBounds => return error.OutOfBounds,
        error.UnsupportedAccessWidth => return error.UnsupportedAccessWidth,
        error.UnalignedAccess => return error.UnalignedAccess,
    };

    while (iterator.next() catch |err| switch (err) {
        error.MalformedCapability => return false,
        error.OutOfBounds => return error.OutOfBounds,
        error.UnsupportedAccessWidth => return error.UnsupportedAccessWidth,
        error.UnalignedAccess => return error.UnalignedAccess,
    }) |capability| {
        if (capability.idTag() == .pci_express) {
            const cap_offset = @as(usize, capability.offset) + capabilities.pcie.register.capabilities;
            const raw_capabilities = try function.read16(cap_offset);
            const version = raw_capabilities & 0xF;
            if (version < 2) return false;

            const device_control_2 = try function.read16(
                @as(usize, capability.offset) + capabilities.pcie.register.device.control_2,
            );
            return device_control_2 & (1 << 5) != 0;
        }
    }

    return false;
}
