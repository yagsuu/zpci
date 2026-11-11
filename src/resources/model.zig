//! Resource requirements and assignments.

const std = @import("std");

const stdx = @import("stdx");

const bar = @import("bar");
const config = @import("config");
const core = @import("core");

const Allocator = std.mem.Allocator;
const AllocError = Allocator.Error;
const Function = config.Function;
const Bar = bar.Bar;
const BarRef = bar.Ref;
const BarType = Bar.Type;
const BarMemory = Bar.Memory;
const WindowType = core.bridge.Type;
const Range = stdx.ranges.Range(u64);

pub const Type = enum(u3) {
    io,
    mmio32,
    mmio32_prefetch,
    mmio64,
    mmio64_prefetch,

    pub fn eligiblePools(self: Type) EligibleSet {
        return switch (self) {
            .io => .{ .io = true },
            .mmio32 => .{ .mmio32 = true },
            .mmio32_prefetch => .{ .mmio32_prefetch = true, .mmio32 = true },
            .mmio64 => .{ .mmio32 = true, .mmio64 = true },
            .mmio64_prefetch => .{
                .mmio64_prefetch = true,
                .mmio32_prefetch = true,
                .mmio64 = true,
                .mmio32 = true,
            },
        };
    }
};

pub const Source = union(enum) {
    bar: BarRef,
    rom: Function,
    bridge: Bridge,

    pub const Bridge = struct {
        function: Function,
        window: WindowType,
    };
};

pub const Requirement = struct {
    type: Type,
    size: u64,
    alignment: u64,
    source: Source,

    pub const Error = error{UnsizedBar};

    pub fn fromBar(function: Function, entry: Bar) Error!?Requirement {
        const resource_type, const size = switch (entry.type) {
            .none => return null,
            .io => |io| .{ Type.io, @as(u64, io.size orelse return error.UnsizedBar) },
            .memory => |memory| .{ memoryType(memory), memory.size orelse return error.UnsizedBar },
        };

        if (size == 0) {
            return null;
        }

        std.debug.assert(std.math.isPowerOfTwo(size));

        return .{
            .type = resource_type,
            .size = size,
            .alignment = size,
            .source = .{ .bar = BarRef.from(function, entry.index) },
        };
    }

    pub fn fromRom(function: Function, size: u32) ?Requirement {
        if (size == 0) {
            return null;
        }

        std.debug.assert(std.math.isPowerOfTwo(size));

        return .{
            .type = .mmio32,
            .size = size,
            .alignment = size,
            .source = .{ .rom = function },
        };
    }

    pub fn fromBars(
        allocator: Allocator,
        function: Function,
        entries: []const Bar,
    ) (Error || AllocError)![]Requirement {
        const required = try countBarRequirements(entries);
        const out = try allocator.alloc(Requirement, required);
        errdefer allocator.free(out);

        var written: usize = 0;
        for (entries) |entry| {
            if (try Requirement.fromBar(function, entry)) |requirement| {
                out[written] = requirement;
                written += 1;
            }
        }

        std.debug.assert(written == required);
        return out;
    }

    fn countBarRequirements(entries: []const Bar) Requirement.Error!usize {
        var num_requirements: usize = 0;
        for (entries) |entry| {
            if (entry.type == .none) {
                continue;
            }

            if (try barTypeSize(entry.type) == 0) {
                continue;
            }

            num_requirements += 1;
        }

        return num_requirements;
    }

    fn memoryType(memory: BarMemory) Type {
        return switch (memory.width) {
            .bits_32 => if (memory.prefetchable) .mmio32_prefetch else .mmio32,
            .bits_64 => if (memory.prefetchable) .mmio64_prefetch else .mmio64,
        };
    }

    fn barTypeSize(bar_type: BarType) Requirement.Error!u64 {
        return switch (bar_type) {
            .none => 0,
            .io => |io| io.size orelse return error.UnsizedBar,
            .memory => |memory| memory.size orelse return error.UnsizedBar,
        };
    }
};

pub const Assignment = struct {
    requirement: Requirement,
    pool: Type,
    base: u64,

    pub fn function(self: Assignment) Function {
        return switch (self.requirement.source) {
            .bar => |source| source.function,
            .rom => |owner| owner,
            .bridge => |source| source.function,
        };
    }
};

pub const Aperture = struct {
    type: Type,
    bounds: Range,

    pub fn empty(resource_type: Type) Aperture {
        return .{
            .type = resource_type,
            .bounds = .empty(0),
        };
    }

    pub fn isEmpty(self: Aperture) bool {
        return self.bounds.isEmpty();
    }

    pub fn contains(self: Aperture, requested: Range) bool {
        if (self.isEmpty()) {
            return false;
        }

        return self.bounds.containsRange(requested);
    }

    pub fn allocate(self: *Aperture, size: u64, alignment: u64) ?u64 {
        std.debug.assert(size > 0);
        std.debug.assert(alignment > 0);
        std.debug.assert(std.math.isPowerOfTwo(alignment));

        if (self.isEmpty()) {
            return null;
        }

        const base = stdx.layout.alignUp(u64, self.bounds.start, alignment) catch return null;
        const allocation_end = std.math.add(u64, base, size) catch return null;

        if (allocation_end > self.bounds.end) {
            return null;
        }

        self.bounds.start = allocation_end;

        return base;
    }
};

pub const Apertures = struct {
    io: Aperture = .empty(.io),
    mmio32: Aperture = .empty(.mmio32),
    mmio32_prefetch: Aperture = .empty(.mmio32_prefetch),
    mmio64: Aperture = .empty(.mmio64),
    mmio64_prefetch: Aperture = .empty(.mmio64_prefetch),

    pub fn get(self: *const Apertures, resource_type: Type) Aperture {
        return switch (resource_type) {
            .io => self.io,
            .mmio32 => self.mmio32,
            .mmio32_prefetch => self.mmio32_prefetch,
            .mmio64 => self.mmio64,
            .mmio64_prefetch => self.mmio64_prefetch,
        };
    }

    pub fn getPtr(self: *Apertures, resource_type: Type) *Aperture {
        return switch (resource_type) {
            .io => &self.io,
            .mmio32 => &self.mmio32,
            .mmio32_prefetch => &self.mmio32_prefetch,
            .mmio64 => &self.mmio64,
            .mmio64_prefetch => &self.mmio64_prefetch,
        };
    }
};

pub const EligibleSet = packed struct(u5) {
    io: bool = false,
    mmio32: bool = false,
    mmio32_prefetch: bool = false,
    mmio64: bool = false,
    mmio64_prefetch: bool = false,

    pub fn has(self: EligibleSet, resource_type: Type) bool {
        return switch (resource_type) {
            .io => self.io,
            .mmio32 => self.mmio32,
            .mmio32_prefetch => self.mmio32_prefetch,
            .mmio64 => self.mmio64,
            .mmio64_prefetch => self.mmio64_prefetch,
        };
    }

    comptime {
        std.debug.assert(@sizeOf(EligibleSet) == 1);
        std.debug.assert(@alignOf(EligibleSet) == 1);
        std.debug.assert(@bitSizeOf(EligibleSet) == 5);
    }
};

pub const unit = struct {
    const support = @import("testing");

    const testing = std.testing;

    const pcie_window_size = core.config.extended_size;

    const FixedBufferAllocator = std.heap.FixedBufferAllocator;
    const FailingAllocator = testing.FailingAllocator;

    const Sbdf = core.Sbdf;

    const BarWidth = Bar.Memory.Width;

    const TestConfigSpace = support.config.TestConfigSpace;

    const ExpectedEligible = struct {
        io: bool = false,
        mmio32: bool = false,
        mmio32_prefetch: bool = false,
        mmio64: bool = false,
        mmio64_prefetch: bool = false,
    };

    const ExpectedBarRequirement = struct {
        type: Type,
        size: u64,
        index: usize,
    };

    test "eligiblePools implements the resource-type truth table" {
        const cases = [_]struct {
            name: []const u8,
            type: Type,
            expected: ExpectedEligible,
        }{
            .{ .name = "io", .type = .io, .expected = .{ .io = true } },
            .{ .name = "mmio32", .type = .mmio32, .expected = .{ .mmio32 = true } },
            .{
                .name = "mmio32 prefetchable",
                .type = .mmio32_prefetch,
                .expected = .{ .mmio32 = true, .mmio32_prefetch = true },
            },
            .{
                .name = "mmio64",
                .type = .mmio64,
                .expected = .{ .mmio32 = true, .mmio64 = true },
            },
            .{
                .name = "mmio64 prefetchable",
                .type = .mmio64_prefetch,
                .expected = .{
                    .mmio32 = true,
                    .mmio32_prefetch = true,
                    .mmio64 = true,
                    .mmio64_prefetch = true,
                },
            },
        };

        for (cases) |case| {
            errdefer std.debug.print("case: {s}\n", .{case.name});

            try expectEligible(case.type.eligiblePools(), case.expected);
        }
    }

    test "Aperture empty and range expose half-open containment" {
        const empty = Aperture.empty(.io);

        try testing.expect(empty.isEmpty());
        try testing.expectEqual(@as(u64, 0), empty.bounds.end);
        try testing.expect(!empty.contains(.of(0, 0)));

        const window = Aperture{ .type = .mmio32, .bounds = .of(0x1000, 0x4000) };

        try testing.expect(!window.isEmpty());
        try testing.expectEqual(@as(u64, 0x4000), window.bounds.end);
        try testing.expect(window.contains(.of(0x1000, 0x1000)));
        try testing.expect(window.contains(.of(0x1000, 0x1001)));
        try testing.expect(window.contains(.of(0x3000, 0x4000)));
        try testing.expect(window.contains(.of(0x4000, 0x4000)));
        try testing.expect(!window.contains(.of(0x4000, 0x4001)));
        try testing.expect(!window.contains(.of(0x0FFF, 0x1000)));
        try testing.expect(!window.contains(.of(0x3001, 0x4001)));
    }

    test "Aperture allocate consumes alignment padding and consecutive ranges" {
        var window = Aperture{ .type = .mmio32_prefetch, .bounds = .of(0x1001, 0x4000) };

        try testing.expectEqual(@as(?u64, 0x2000), window.allocate(0x800, 0x1000));
        try testing.expectEqual(Type.mmio32_prefetch, window.type);
        try testing.expectEqual(@as(u64, 0x2800), window.bounds.start);
        try testing.expectEqual(@as(u64, 0x1800), window.bounds.len());

        try testing.expectEqual(@as(?u64, 0x2800), window.allocate(0x1800, 0x800));
        try testing.expectEqual(@as(u64, 0x4000), window.bounds.start);
        try testing.expectEqual(@as(u64, 0), window.bounds.len());
        try testing.expect(window.isEmpty());
    }

    test "Aperture allocate failure leaves the aperture unchanged" {
        var empty = Aperture.empty(.io);

        try testing.expectEqual(@as(?u64, null), empty.allocate(1, 1));
        try testing.expectEqual(@as(u64, 0), empty.bounds.start);
        try testing.expectEqual(@as(u64, 0), empty.bounds.len());

        var too_small = Aperture{ .type = .mmio32, .bounds = .of(0x1000, 0x1100) };

        try testing.expectEqual(@as(?u64, null), too_small.allocate(0x101, 1));
        try testing.expectEqual(@as(u64, 0x1000), too_small.bounds.start);
        try testing.expectEqual(@as(u64, 0x100), too_small.bounds.len());

        const max = std.math.maxInt(u64);
        var alignment_overflow = Aperture{ .type = .mmio64, .bounds = try Range.fromStartLen(max - 0x7F, 0x7F) };

        try testing.expectEqual(@as(?u64, null), alignment_overflow.allocate(1, 0x100));
        try testing.expectEqual(max - 0x7F, alignment_overflow.bounds.start);
        try testing.expectEqual(@as(u64, 0x7F), alignment_overflow.bounds.len());

        var end_overflow = Aperture{ .type = .mmio64_prefetch, .bounds = try Range.fromStartLen(max - 0x100, 0x100) };

        try testing.expectEqual(@as(?u64, null), end_overflow.allocate(0x200, 1));
        try testing.expectEqual(max - 0x100, end_overflow.bounds.start);
        try testing.expectEqual(@as(u64, 0x100), end_overflow.bounds.len());
    }

    test "Apertures.get selects the aperture for each resource type" {
        const apertures = Apertures{
            .io = .{ .type = .io, .bounds = .of(0x0010, 0x0020) },
            .mmio32 = .{ .type = .mmio32, .bounds = .of(0x1000, 0x1020) },
            .mmio32_prefetch = .{ .type = .mmio32_prefetch, .bounds = .of(0x2000, 0x2030) },
            .mmio64 = .{ .type = .mmio64, .bounds = .of(0x1_0000_0000, 0x1_0000_0040) },
            .mmio64_prefetch = .{ .type = .mmio64_prefetch, .bounds = .of(0x2_0000_0000, 0x2_0000_0050) },
        };
        const cases = [_]struct {
            type: Type,
            base: u64,
            size: u64,
        }{
            .{ .type = .io, .base = 0x0010, .size = 0x10 },
            .{ .type = .mmio32, .base = 0x1000, .size = 0x20 },
            .{ .type = .mmio32_prefetch, .base = 0x2000, .size = 0x30 },
            .{ .type = .mmio64, .base = 0x1_0000_0000, .size = 0x40 },
            .{ .type = .mmio64_prefetch, .base = 0x2_0000_0000, .size = 0x50 },
        };

        for (cases) |case| {
            const aperture = apertures.get(case.type);

            try testing.expectEqual(case.type, aperture.type);
            try testing.expectEqual(case.base, aperture.bounds.start);
            try testing.expectEqual(case.size, aperture.bounds.len());
        }
    }

    test "Requirement.fromBar drops absent and zero-sized BARs" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        const sbdf = Sbdf.from(.from(0), 0, 1, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);

        try testing.expectEqual(@as(?Requirement, null), try Requirement.fromBar(function, noneBar(0)));
        try testing.expectEqual(@as(?Requirement, null), try Requirement.fromBar(function, ioBar(1, 0)));
        try testing.expectEqual(
            @as(?Requirement, null),
            try Requirement.fromBar(function, memoryBar(2, 0, .bits_32, false)),
        );
    }

    test "Requirement.fromBar rejects unsized IO and memory BARs" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        const sbdf = Sbdf.from(.from(0), 0, 1, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);
        const entries = [_]Bar{
            ioBar(0, null),
            memoryBar(1, null, .bits_32, false),
            memoryBar(2, null, .bits_64, true),
        };

        for (entries) |entry| {
            try testing.expectError(error.UnsizedBar, Requirement.fromBar(function, entry));
        }
    }

    test "Requirement.fromBar maps IO and memory BAR variants" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        const sbdf = Sbdf.from(.from(0), 0, 2, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);
        const cases = [_]struct {
            name: []const u8,
            entry: Bar,
            expected: ExpectedBarRequirement,
        }{
            .{
                .name = "io",
                .entry = ioBar(0, 0x100),
                .expected = .{ .type = .io, .size = 0x100, .index = 0 },
            },
            .{
                .name = "32-bit non-prefetchable memory",
                .entry = memoryBar(1, 0x1000, .bits_32, false),
                .expected = .{ .type = .mmio32, .size = 0x1000, .index = 1 },
            },
            .{
                .name = "32-bit prefetchable memory",
                .entry = memoryBar(2, 0x2000, .bits_32, true),
                .expected = .{ .type = .mmio32_prefetch, .size = 0x2000, .index = 2 },
            },
            .{
                .name = "64-bit non-prefetchable memory",
                .entry = memoryBar(3, 0x4000, .bits_64, false),
                .expected = .{ .type = .mmio64, .size = 0x4000, .index = 3 },
            },
            .{
                .name = "64-bit prefetchable memory",
                .entry = memoryBar(4, 0x8000, .bits_64, true),
                .expected = .{ .type = .mmio64_prefetch, .size = 0x8000, .index = 4 },
            },
        };

        for (cases) |case| {
            errdefer std.debug.print("case: {s}\n", .{case.name});

            try expectBarRequirement(function, (try Requirement.fromBar(function, case.entry)).?, case.expected);
        }
    }

    test "Requirement.fromRom maps nonzero ROM size to MMIO32" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        const sbdf = Sbdf.from(.from(0), 0, 3, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);

        try testing.expectEqual(@as(?Requirement, null), Requirement.fromRom(function, 0));

        const requirement = Requirement.fromRom(function, 0x20_0000).?;

        try testing.expectEqual(Type.mmio32, requirement.type);
        try testing.expectEqual(@as(u64, 0x20_0000), requirement.size);
        try testing.expectEqual(@as(u64, 0x20_0000), requirement.alignment);
        switch (requirement.source) {
            .rom => |source_function| try testing.expect(function.eql(source_function)),
            else => return error.TestExpectedEqual,
        }
    }

    test "Requirement.fromBars preserves BAR order and filters absent and zero-sized BARs" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        const sbdf = Sbdf.from(.from(0), 0, 4, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);
        const entries = [_]Bar{
            noneBar(0),
            ioBar(1, 0x100),
            memoryBar(2, 0x2000, .bits_64, false),
            memoryBar(4, 0, .bits_32, true),
            memoryBar(5, 0x1000, .bits_32, true),
        };

        const written = try Requirement.fromBars(testing.allocator, function, &entries);
        defer testing.allocator.free(written);

        try testing.expectEqual(@as(usize, 3), written.len);
        try expectBarRequirement(function, written[0], .{ .type = .io, .size = 0x100, .index = 1 });
        try expectBarRequirement(function, written[1], .{ .type = .mmio64, .size = 0x2000, .index = 2 });
        try expectBarRequirement(function, written[2], .{ .type = .mmio32_prefetch, .size = 0x1000, .index = 5 });
    }

    test "Requirement.fromBars returns empty allocations for empty and filtered entries" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        const sbdf = Sbdf.from(.from(0), 0, 4, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);
        const cases = [_][]const Bar{
            &.{},
            &.{noneBar(0)},
            &.{ioBar(0, 0)},
            &.{memoryBar(0, 0, .bits_32, false)},
            &.{memoryBar(0, 0, .bits_64, true)},
            &.{ noneBar(0), ioBar(1, 0), memoryBar(2, 0, .bits_64, false) },
        };

        for (cases) |entries| {
            const requirements = try Requirement.fromBars(testing.allocator, function, entries);
            defer testing.allocator.free(requirements);

            try testing.expectEqual(@as(usize, 0), requirements.len);
        }
    }

    test "Requirement.fromBars fits exact fixed storage and reports exhaustion" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        const sbdf = Sbdf.from(.from(0), 0, 4, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);
        const entries = [_]Bar{
            noneBar(0),
            ioBar(1, 0x100),
            memoryBar(2, 0x2000, .bits_64, false),
            memoryBar(4, 0, .bits_32, true),
            memoryBar(5, 0x1000, .bits_32, true),
        };

        var storage: [3 * @sizeOf(Requirement)]u8 align(@alignOf(Requirement)) = undefined;
        var fba = FixedBufferAllocator.init(&storage);
        const allocator = fba.allocator();
        const requirements = try Requirement.fromBars(allocator, function, &entries);
        defer allocator.free(requirements);

        try testing.expectEqual(@as(usize, 3), requirements.len);
        try expectBarRequirement(function, requirements[0], .{ .type = .io, .size = 0x100, .index = 1 });
        try expectBarRequirement(function, requirements[1], .{ .type = .mmio64, .size = 0x2000, .index = 2 });
        try expectBarRequirement(function, requirements[2], .{ .type = .mmio32_prefetch, .size = 0x1000, .index = 5 });

        try testing.expectError(error.OutOfMemory, Requirement.fromBars(allocator, function, &entries));

        var short_storage: [3 * @sizeOf(Requirement) - 1]u8 align(@alignOf(Requirement)) = undefined;
        var short_fba = FixedBufferAllocator.init(&short_storage);
        try testing.expectError(error.OutOfMemory, Requirement.fromBars(short_fba.allocator(), function, &entries));
    }

    test "Requirement.fromBars rejects late unsized BARs before allocating" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        const sbdf = Sbdf.from(.from(0), 0, 4, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);
        const unknown = [_]Bar{
            ioBar(4, null),
            memoryBar(4, null, .bits_32, false),
            memoryBar(4, null, .bits_64, true),
        };

        for (unknown) |entry| {
            const entries = [_]Bar{
                noneBar(0),
                ioBar(1, 0),
                memoryBar(2, 0, .bits_32, false),
                ioBar(3, 0x100),
                entry,
            };
            var failing = FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });

            try testing.expectError(error.UnsizedBar, Requirement.fromBars(failing.allocator(), function, &entries));
            try testing.expectEqual(@as(usize, 0), failing.alloc_index);
            try testing.expect(!failing.has_induced_failure);
        }
    }

    test "Assignment function returns the owner for every source type" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        const sbdf = Sbdf.from(.from(0), 0, 5, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const function = Function.from(backend.config(), sbdf);
        const assignments = [_]Assignment{
            .{
                .requirement = (try Requirement.fromBar(function, ioBar(0, 0x100))).?,
                .pool = .io,
                .base = 0x1000,
            },
            .{
                .requirement = Requirement.fromRom(function, 0x2000).?,
                .pool = .mmio32,
                .base = 0x8000_0000,
            },
            .{
                .requirement = .{
                    .type = .mmio64,
                    .size = 0x10_0000,
                    .alignment = 0x10_0000,
                    .source = .{
                        .bridge = .{
                            .function = function,
                            .window = .mem,
                        },
                    },
                },
                .pool = .mmio64,
                .base = 0x1_0000_0000,
            },
        };

        for (assignments) |assignment| {
            try testing.expect(function.eql(assignment.function()));
        }
    }

    fn expectEligible(actual: EligibleSet, expected: ExpectedEligible) !void {
        try testing.expectEqual(expected.io, actual.has(.io));
        try testing.expectEqual(expected.mmio32, actual.has(.mmio32));
        try testing.expectEqual(expected.mmio32_prefetch, actual.has(.mmio32_prefetch));
        try testing.expectEqual(expected.mmio64, actual.has(.mmio64));
        try testing.expectEqual(expected.mmio64_prefetch, actual.has(.mmio64_prefetch));
    }

    fn expectBarRequirement(function: Function, requirement: Requirement, expected: ExpectedBarRequirement) !void {
        try testing.expectEqual(expected.type, requirement.type);
        try testing.expectEqual(expected.size, requirement.size);
        try testing.expectEqual(expected.size, requirement.alignment);

        switch (requirement.source) {
            .bar => |source| {
                try testing.expectEqual(expected.index, source.index);
                try testing.expect(function.eql(source.function));
            },
            else => return error.TestExpectedEqual,
        }
    }

    fn noneBar(index: usize) Bar {
        return .{
            .index = index,
            .type = .none,
        };
    }

    fn ioBar(index: usize, size: ?u32) Bar {
        return .{
            .index = index,
            .type = .{ .io = .{ .base = 0x0000_C000, .size = size } },
        };
    }

    fn memoryBar(index: usize, size: ?u64, width: BarWidth, prefetchable: bool) Bar {
        return .{
            .index = index,
            .type = .{
                .memory = .{
                    .base = 0x8000_0000,
                    .size = size,
                    .width = width,
                    .prefetchable = prefetchable,
                },
            },
        };
    }
};
