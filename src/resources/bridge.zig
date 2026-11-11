//! Bridge windows.

const std = @import("std");

const stdx = @import("stdx");

const config = @import("config");
const core = @import("core");

const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const AllocError = Allocator.Error;
const Function = config.Function;
const Encoding = core.bridge.Encoding;
const Io = core.bridge.Io;
const Memory = core.bridge.Memory;
const WindowType = core.bridge.Type;

const Requirement = model.Requirement;
const Assignment = model.Assignment;
const Type = model.Type;

pub const Aggregate = stdx.collections.List.Static(Requirement, 3);
pub const AggregateError = AllocError || error{ResourceExhausted};
pub const Error = error{BridgeWindowUnencodable};

/// Returns bridge requirements in IO, memory, prefetchable order.
pub fn aggregate(
    allocator: Allocator,
    bridge_function: Function,
    children: []const Requirement,
) AggregateError!Aggregate {
    var result = Aggregate.init();
    var num_requirements: usize = 0;
    for (children) |child| {
        if (child.size != 0) {
            num_requirements += 1;
        }
    }

    if (num_requirements == 0) {
        return result;
    }

    const order = try allocator.alloc(usize, num_requirements);
    defer allocator.free(order);

    var next: usize = 0;
    for (children, 0..) |child, index| {
        if (child.size == 0) {
            continue;
        }

        order[next] = index;
        next += 1;
    }

    std.mem.sort(usize, order, children, childLess);

    for ([_]WindowType{ .io, .mem, .mem_prefetch }) |window_type| {
        if (try aggregateWindow(bridge_function, children, order, window_type)) |requirement| {
            result.appendAssumeCapacity(requirement);
        }
    }

    return result;
}

pub fn encode(assignment: Assignment) Error!Encoding {
    const requirement = assignment.requirement;
    std.debug.assert(requirement.source == .bridge);
    std.debug.assert(requirement.alignment > 0);
    std.debug.assert(assignment.base % requirement.alignment == 0);

    if (requirement.size == 0) {
        return Encoding.disabled(requirement.source.bridge.window);
    }

    const end = std.math.add(u64, assignment.base, requirement.size - 1) catch {
        return error.BridgeWindowUnencodable;
    };

    return Encoding.encode(requirement.source.bridge.window, assignment.base, end) catch return error.BridgeWindowUnencodable;
}

fn aggregateWindow(bridge_function: Function, children: []const Requirement, order: []const usize, window_type: WindowType) error{ResourceExhausted}!?Requirement {
    var alignment = switch (window_type) {
        .io => Io.alignment,
        .mem, .mem_prefetch => Memory.alignment,
    };
    var num_requirements: usize = 0;
    var has_prefetchable_32 = false;

    for (children) |child| {
        if (!belongsToWindow(child, window_type)) {
            continue;
        }

        std.debug.assert(child.alignment > 0);
        std.debug.assert(std.math.isPowerOfTwo(child.alignment));

        alignment = @max(alignment, child.alignment);
        num_requirements += 1;
        has_prefetchable_32 = has_prefetchable_32 or child.type == .mmio32_prefetch;
    }

    if (num_requirements == 0) {
        return null;
    }

    std.debug.assert(std.math.isPowerOfTwo(alignment));

    var cursor: u64 = 0;
    for (order) |index| {
        const child = children[index];

        if (!belongsToWindow(child, window_type)) {
            continue;
        }

        cursor = stdx.layout.alignUp(u64, cursor, child.alignment) catch return error.ResourceExhausted;
        cursor = std.math.add(u64, cursor, child.size) catch return error.ResourceExhausted;
    }

    const size = stdx.layout.alignUp(u64, cursor, alignment) catch return error.ResourceExhausted;
    std.debug.assert(size >= alignment);
    std.debug.assert(size % alignment == 0);

    return .{
        .type = aggregateType(window_type, has_prefetchable_32),
        .size = size,
        .alignment = alignment,
        .source = .{ .bridge = .{
            .function = bridge_function,
            .window = window_type,
        } },
    };
}

fn belongsToWindow(requirement: Requirement, window_type: WindowType) bool {
    if (requirement.size == 0) {
        return false;
    }

    return switch (window_type) {
        .io => requirement.type == .io,
        .mem => requirement.type == .mmio32 or requirement.type == .mmio64,
        .mem_prefetch => requirement.type == .mmio32_prefetch or requirement.type == .mmio64_prefetch,
    };
}

fn childLess(children: []const Requirement, left_index: usize, right_index: usize) bool {
    const left = children[left_index];
    const right = children[right_index];

    if (left.alignment != right.alignment) {
        return left.alignment > right.alignment;
    }

    if (left.size != right.size) {
        return left.size > right.size;
    }

    return left_index < right_index;
}

fn aggregateType(window_type: WindowType, has_prefetchable_32: bool) Type {
    return switch (window_type) {
        .io => .io,
        .mem => .mmio32,
        .mem_prefetch => if (has_prefetchable_32) .mmio32_prefetch else .mmio64_prefetch,
    };
}

pub const unit = struct {
    const testing = std.testing;

    var fake_context: u8 = 0;

    const FailingAllocator = testing.FailingAllocator;

    const ConfigSpace = config.ConfigSpace;
    const ConfigError = ConfigSpace.Error;

    const Offset = core.Offset;
    const Sbdf = core.Sbdf;

    const RequirementShape = struct {
        type: Type,
        size: u64,
        alignment: u64,
    };

    const fake_vtable: ConfigSpace.VTable = .{
        .read8 = fakeRead8,
        .read16 = fakeRead16,
        .read32 = fakeRead32,
        .write8 = fakeWrite8,
        .write16 = fakeWrite16,
        .write32 = fakeWrite32,
    };

    test "aggregate maps mixed child widths to ordered bridge requirements" {
        const function = testFunction(1);
        const children = [_]Requirement{
            childRequirement(function, .{ .type = .mmio64_prefetch, .size = 0x20_0000, .alignment = 0x20_0000 }),
            childRequirement(function, .{ .type = .io, .size = 0x1000, .alignment = 0x1000 }),
            childRequirement(function, .{ .type = .mmio64, .size = 0x20_0000, .alignment = 0x20_0000 }),
            childRequirement(function, .{ .type = .mmio32_prefetch, .size = 0x10_0000, .alignment = 0x10_0000 }),
            childRequirement(function, .{ .type = .mmio32, .size = 0x10_0000, .alignment = 0x10_0000 }),
        };
        const original = children;

        const result = try aggregate(testing.allocator, function, &children);
        const windows = result.asSlice();

        try testing.expectEqual(@as(usize, 3), windows.len);
        try expectBridgeRequirement(function, windows[0], .io, .io, 0x1000, Io.alignment);
        try expectBridgeRequirement(function, windows[1], .mem, .mmio32, 0x40_0000, 0x20_0000);
        try expectBridgeRequirement(function, windows[2], .mem_prefetch, .mmio32_prefetch, 0x40_0000, 0x20_0000);
        try expectIoEncoding(
            try encode(.{ .requirement = windows[0], .pool = .io, .base = 0 }),
            .{ .base_lo = 0, .limit_lo = 0, .base_hi = 0, .limit_hi = 0 },
        );
        try expectMemoryEncoding(
            try encode(.{ .requirement = windows[1], .pool = .mmio32, .base = 0 }),
            .{ .base = 0, .limit = 0x30 },
        );
        try expectPrefetchable32Encoding(
            try encode(.{ .requirement = windows[2], .pool = .mmio32_prefetch, .base = 0 }),
            .{ .base_lo = 0, .limit_lo = 0x30 },
        );

        for (original, children) |expected, actual| {
            try expectSameRequirement(.{ .expected = expected, .actual = actual });
        }
    }

    test "aggregate keeps all-64-bit prefetchable bucket 64-bit" {
        const function = testFunction(2);
        const children = [_]Requirement{
            childRequirement(function, .{ .type = .mmio64_prefetch, .size = 0x10_0000, .alignment = 0x10_0000 }),
            childRequirement(function, .{ .type = .mmio64_prefetch, .size = 0x20_0000, .alignment = 0x20_0000 }),
        };
        const result = try aggregate(testing.allocator, function, &children);
        const windows = result.asSlice();

        try testing.expectEqual(@as(usize, 1), windows.len);
        try expectBridgeRequirement(function, windows[0], .mem_prefetch, .mmio64_prefetch, 0x40_0000, 0x20_0000);
        try expectPrefetchable64Encoding(
            try encode(.{
                .requirement = windows[0],
                .pool = .mmio64_prefetch,
                .base = 0x1_0000_0000,
            }),
            .{ .base_lo = 1, .limit_lo = 0x31, .base_hi = 1, .limit_hi = 1 },
        );
    }

    test "aggregate reports allocator failure and releases workspace" {
        const function = testFunction(3);
        const children = [_]Requirement{
            childRequirement(function, .{ .type = .mmio32, .size = 0x10_0000, .alignment = 0x10_0000 }),
        };

        var failing = FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        try testing.expectError(error.OutOfMemory, aggregate(failing.allocator(), function, &children));

        var tracking = FailingAllocator.init(testing.allocator, .{});
        const result = try aggregate(tracking.allocator(), function, &children);

        try expectBridgeRequirement(function, result.asSlice()[0], .mem, .mmio32, 0x10_0000, Memory.alignment);
        try testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
        try expectSameRequirement(.{
            .expected = childRequirement(function, .{ .type = .mmio32, .size = 0x10_0000, .alignment = 0x10_0000 }),
            .actual = children[0],
        });
    }

    test "aggregate ignores zero-sized children and preserves child requirements" {
        const function = testFunction(4);
        const children = [_]Requirement{
            childRequirement(function, .{ .type = .io, .size = 0x1000, .alignment = 0x1000 }),
            childRequirement(function, .{ .type = .io, .size = 0x10_0000, .alignment = 0x10_0000 }),
            childRequirement(function, .{ .type = .mmio32_prefetch, .size = 0, .alignment = 0 }),
            childRequirement(function, .{ .type = .io, .size = 0x4000, .alignment = 0x4000 }),
        };
        const original = children;

        const result = try aggregate(testing.allocator, function, &children);
        const windows = result.asSlice();

        try testing.expectEqual(@as(usize, 1), windows.len);
        try expectBridgeRequirement(function, windows[0], .io, .io, 0x20_0000, 0x10_0000);
        try expectIoEncoding(
            try encode(.{ .requirement = windows[0], .pool = .io, .base = 0 }),
            .{ .base_lo = 1, .limit_lo = 0xF1, .base_hi = 0, .limit_hi = 0x1F },
        );

        for (original, children) |expected, actual| {
            try expectSameRequirement(.{ .expected = expected, .actual = actual });
        }
    }

    test "aggregate raises bridge granularity above tiny child alignment" {
        const function = testFunction(5);
        const children = [_]Requirement{childRequirement(function, .{ .type = .io, .size = 0x200, .alignment = 0x200 })};

        const result = try aggregate(testing.allocator, function, &children);
        const windows = result.asSlice();

        try expectBridgeRequirement(function, windows[0], .io, .io, Io.alignment, Io.alignment);
    }

    test "aggregate needs no allocator workspace for empty or zero-sized children" {
        const function = testFunction(6);
        const children = [_]Requirement{childRequirement(function, .{ .type = .mmio32, .size = 0, .alignment = 0 })};
        var failing = FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });

        const zero_result = try aggregate(failing.allocator(), function, &children);
        try testing.expectEqual(@as(usize, 0), zero_result.asSlice().len);

        const empty_result = try aggregate(failing.allocator(), function, &.{});
        try testing.expectEqual(@as(usize, 0), empty_result.asSlice().len);
    }

    test "aggregate reports child size addition overflow and releases workspace" {
        const function = testFunction(8);
        const children = [_]Requirement{
            childRequirement(function, .{ .type = .mmio32, .size = @as(u64, 1) << 63, .alignment = 1 }),
            childRequirement(function, .{ .type = .mmio32, .size = @as(u64, 1) << 63, .alignment = 1 }),
        };
        var tracking = FailingAllocator.init(testing.allocator, .{});

        try testing.expectError(error.ResourceExhausted, aggregate(tracking.allocator(), function, &children));
        try testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
    }

    test "aggregate reports child alignment overflow and releases workspace" {
        const function = testFunction(9);
        const children = [_]Requirement{
            childRequirement(function, .{ .type = .mmio32, .size = std.math.maxInt(u64) - 0x7FF, .alignment = 0x2000 }),
            childRequirement(function, .{ .type = .mmio32, .size = 1, .alignment = 0x1000 }),
        };
        var tracking = FailingAllocator.init(testing.allocator, .{});

        try testing.expectError(error.ResourceExhausted, aggregate(tracking.allocator(), function, &children));
        try testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
    }

    test "aggregate reports final window granularity overflow and releases workspace" {
        const function = testFunction(10);
        const children = [_]Requirement{
            childRequirement(function, .{ .type = .mmio32, .size = std.math.maxInt(u64), .alignment = 1 }),
        };
        var tracking = FailingAllocator.init(testing.allocator, .{});

        try testing.expectError(error.ResourceExhausted, aggregate(tracking.allocator(), function, &children));
        try testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
    }

    test "aggregate accepts the largest representable memory window" {
        const function = testFunction(12);
        const size = std.math.maxInt(u64) - (Memory.alignment - 1);
        const children = [_]Requirement{
            childRequirement(function, .{ .type = .mmio32, .size = size, .alignment = 1 }),
        };

        const result = try aggregate(testing.allocator, function, &children);

        try testing.expectEqual(@as(usize, 1), result.asSlice().len);
        try expectBridgeRequirement(function, result.asSlice()[0], .mem, .mmio32, size, Memory.alignment);
    }

    test "encode emits canonical disabled encodings for zero-sized windows" {
        const function = testFunction(7);

        try expectIoEncoding(
            try encode(windowAssignment(function, .io, .io, 0, 0, Io.alignment)),
            .{ .base_lo = 0xF0, .limit_lo = 0, .base_hi = 0, .limit_hi = 0 },
        );
        try expectMemoryEncoding(
            try encode(windowAssignment(function, .mem, .mmio32, 0, 0, Memory.alignment)),
            .{ .base = 0xFFF0, .limit = 0 },
        );
        try expectPrefetchable32Encoding(
            try encode(windowAssignment(
                function,
                .mem_prefetch,
                .mmio32_prefetch,
                0,
                0,
                Memory.alignment,
            )),
            .{ .base_lo = 0xFFF0, .limit_lo = 0 },
        );
    }

    test "encode reports BridgeWindowUnencodable for overflowing placements" {
        const function = testFunction(11);

        try testing.expectError(
            error.BridgeWindowUnencodable,
            encode(
                windowAssignment(
                    function,
                    .mem_prefetch,
                    .mmio64_prefetch,
                    0xFFFF_FFFF_FFF0_0000,
                    0x20_0000,
                    Memory.alignment,
                ),
            ),
        );
    }

    fn testFunction(device: u5) Function {
        const config_space = ConfigSpace.from(@ptrCast(&fake_context), &fake_vtable);
        return Function.from(config_space, Sbdf.from(.from(0), 0, device, 0));
    }

    fn fakeRead8(_: *anyopaque, _: Sbdf, _: usize) ConfigError!u8 {
        return 0;
    }

    fn fakeRead16(_: *anyopaque, _: Sbdf, _: usize) ConfigError!u16 {
        return 0;
    }

    fn fakeRead32(_: *anyopaque, _: Sbdf, _: usize) ConfigError!u32 {
        return 0;
    }

    fn fakeWrite8(_: *anyopaque, _: Sbdf, _: usize, _: u8) ConfigError!void {}

    fn fakeWrite16(_: *anyopaque, _: Sbdf, _: usize, _: u16) ConfigError!void {}

    fn fakeWrite32(_: *anyopaque, _: Sbdf, _: usize, _: u32) ConfigError!void {}

    fn childRequirement(function: Function, shape: RequirementShape) Requirement {
        return .{
            .type = shape.type,
            .size = shape.size,
            .alignment = shape.alignment,
            .source = .{ .rom = function },
        };
    }

    fn windowAssignment(
        function: Function,
        window: WindowType,
        resource_type: Type,
        base: u64,
        size: u64,
        alignment: u64,
    ) Assignment {
        return .{
            .requirement = .{
                .type = resource_type,
                .size = size,
                .alignment = alignment,
                .source = .{ .bridge = .{ .function = function, .window = window } },
            },
            .pool = resource_type,
            .base = base,
        };
    }

    fn expectBridgeRequirement(
        function: Function,
        actual: Requirement,
        window: WindowType,
        resource_type: Type,
        size: u64,
        alignment: u64,
    ) !void {
        try testing.expectEqual(resource_type, actual.type);
        try testing.expectEqual(size, actual.size);
        try testing.expectEqual(alignment, actual.alignment);

        switch (actual.source) {
            .bridge => |source| {
                try testing.expectEqual(window, source.window);
                try testing.expect(function.eql(source.function));
            },
            else => return error.TestExpectedEqual,
        }
    }

    fn expectSameRequirement(options: struct { expected: Requirement, actual: Requirement }) !void {
        try testing.expectEqual(options.expected.type, options.actual.type);
        try testing.expectEqual(options.expected.size, options.actual.size);
        try testing.expectEqual(options.expected.alignment, options.actual.alignment);
        try testing.expectEqual(std.meta.activeTag(options.expected.source), std.meta.activeTag(options.actual.source));

        switch (options.expected.source) {
            .rom => |function| {
                try testing.expect(function.eql(options.actual.source.rom));
            },
            .bridge => |source| {
                try testing.expectEqual(source.window, options.actual.source.bridge.window);
                try testing.expect(source.function.eql(options.actual.source.bridge.function));
            },
            .bar => |bar| {
                try testing.expectEqual(bar.index, options.actual.source.bar.index);
                try testing.expect(bar.function.eql(options.actual.source.bar.function));
            },
        }
    }

    fn expectIoEncoding(actual: Encoding, expected: Io) !void {
        switch (actual) {
            .io => |io| {
                try testing.expectEqual(expected.base_lo, io.base_lo);
                try testing.expectEqual(expected.limit_lo, io.limit_lo);
                try testing.expectEqual(expected.base_hi, io.base_hi);
                try testing.expectEqual(expected.limit_hi, io.limit_hi);
            },
            else => return error.TestExpectedEqual,
        }
    }

    fn expectMemoryEncoding(actual: Encoding, expected: Memory) !void {
        switch (actual) {
            .mem => |memory| {
                try testing.expectEqual(expected.base, memory.base);
                try testing.expectEqual(expected.limit, memory.limit);
            },
            else => return error.TestExpectedEqual,
        }
    }

    fn expectPrefetchable32Encoding(actual: Encoding, expected: Memory.Prefetch32) !void {
        switch (actual) {
            .mem_prefetch_32 => |prefetchable| {
                try testing.expectEqual(expected.base_lo, prefetchable.base_lo);
                try testing.expectEqual(expected.limit_lo, prefetchable.limit_lo);
            },
            else => return error.TestExpectedEqual,
        }
    }

    fn expectPrefetchable64Encoding(actual: Encoding, expected: Memory.Prefetch64) !void {
        switch (actual) {
            .mem_prefetch_64 => |prefetchable| {
                try testing.expectEqual(expected.base_lo, prefetchable.base_lo);
                try testing.expectEqual(expected.limit_lo, prefetchable.limit_lo);
                try testing.expectEqual(expected.base_hi, prefetchable.base_hi);
                try testing.expectEqual(expected.limit_hi, prefetchable.limit_hi);
            },
            else => return error.TestExpectedEqual,
        }
    }
};
