//! Resource requirement model. Spec: docs/specs/resources/model.md.

const std = @import("std");

const bar = @import("../bar.zig");
const config = @import("../config.zig");

pub const Kind = enum(u3) {
    io,
    mmio32,
    mmio32_pref,
    mmio64,
    mmio64_pref,
};

pub const EligibleSet = packed struct(u5) {
    io: bool = false,
    mmio32: bool = false,
    mmio32_pref: bool = false,
    mmio64: bool = false,
    mmio64_pref: bool = false,

    pub fn has(self: EligibleSet, kind: Kind) bool {
        return switch (kind) {
            .io => self.io,
            .mmio32 => self.mmio32,
            .mmio32_pref => self.mmio32_pref,
            .mmio64 => self.mmio64,
            .mmio64_pref => self.mmio64_pref,
        };
    }

    comptime {
        std.debug.assert(@sizeOf(EligibleSet) == 1);
        std.debug.assert(@alignOf(EligibleSet) == 1);
        std.debug.assert(@bitSizeOf(EligibleSet) == 5);
    }
};

pub fn eligiblePools(kind: Kind) EligibleSet {
    return switch (kind) {
        .io => .{ .io = true },
        .mmio32 => .{ .mmio32 = true },
        .mmio32_pref => .{ .mmio32_pref = true, .mmio32 = true },
        .mmio64 => .{ .mmio32 = true, .mmio64 = true },
        .mmio64_pref => .{
            .mmio64_pref = true,
            .mmio32_pref = true,
            .mmio64 = true,
            .mmio32 = true,
        },
    };
}

pub const Aperture = struct {
    kind: Kind,
    base: u64,
    size: u64,

    pub fn absent(kind: Kind) Aperture {
        return .{ .kind = kind, .base = 0, .size = 0 };
    }

    pub fn range(kind: Kind, base: u64, size: u64) Aperture {
        std.debug.assert(size <= std.math.maxInt(u64) - base);
        return .{ .kind = kind, .base = base, .size = size };
    }

    pub fn isEmpty(self: Aperture) bool {
        return self.size == 0;
    }

    pub fn end(self: Aperture) u64 {
        std.debug.assert(self.size <= std.math.maxInt(u64) - self.base);
        return self.base + self.size;
    }

    pub fn contains(self: Aperture, base: u64, size: u64) bool {
        if (self.size == 0) return false;
        if (base < self.base) return false;
        if (size > std.math.maxInt(u64) - base) return false;

        return base + size <= self.end();
    }

    pub fn allocate(self: *Aperture, size: u64, alignment: u64) ?u64 {
        std.debug.assert(size > 0);
        std.debug.assert(alignment > 0);
        std.debug.assert(std.math.isPowerOfTwo(alignment));
        if (self.size == 0) return null;

        const align_mask = alignment - 1;
        const aligned_sum = std.math.add(u64, self.base, align_mask) catch return null;
        const base = aligned_sum & ~align_mask;
        const allocation_end = std.math.add(u64, base, size) catch return null;
        if (allocation_end > self.end()) return null;

        const consumed = allocation_end - self.base;
        self.base = allocation_end;
        self.size -= consumed;
        return base;
    }
};

pub const RootWindows = struct {
    io: Aperture = .absent(.io),
    mmio32: Aperture = .absent(.mmio32),
    mmio32_pref: Aperture = .absent(.mmio32_pref),
    mmio64: Aperture = .absent(.mmio64),
    mmio64_pref: Aperture = .absent(.mmio64_pref),

    pub fn get(self: RootWindows, kind: Kind) Aperture {
        return switch (kind) {
            .io => self.io,
            .mmio32 => self.mmio32,
            .mmio32_pref => self.mmio32_pref,
            .mmio64 => self.mmio64,
            .mmio64_pref => self.mmio64_pref,
        };
    }
};

/// Requirement source; embedded functions borrow their `ConfigSpace` backend.
pub const Source = union(enum) {
    endpoint_bar: bar.BarRef,
    endpoint_expansion_rom: config.Function,
    bridge_window: BridgeWindowSource,

    pub const BridgeWindow = enum(u2) {
        io,
        memory,
        prefetchable_memory,
    };

    pub const BridgeWindowSource = struct {
        function: config.Function,
        window: BridgeWindow,
    };
};

pub const Requirement = struct {
    kind: Kind,
    size: u64,
    alignment: u64,
    source: Source,

    pub fn fromBar(function: config.Function, entry: bar.Entry) ?Requirement {
        const kind, const size = switch (entry.kind) {
            .none => return null,
            .io => |io| .{ Kind.io, @as(u64, io.size) },
            .memory => |memory| .{ memoryKind(memory), memory.size },
        };

        if (size == 0) return null;
        std.debug.assert(std.math.isPowerOfTwo(size));

        return .{
            .kind = kind,
            .size = size,
            .alignment = size,
            .source = .{ .endpoint_bar = bar.BarRef.init(function, entry.index) },
        };
    }

    /// Produces a non-prefetchable MMIO32 requirement for a sized expansion ROM.
    pub fn fromExpansionRom(function: config.Function, size: u32) ?Requirement {
        if (size == 0) return null;
        std.debug.assert(std.math.isPowerOfTwo(size));

        return .{
            .kind = .mmio32,
            .size = size,
            .alignment = size,
            .source = .{ .endpoint_expansion_rom = function },
        };
    }

    /// Appends non-null BAR requirements into `out` and returns the filled prefix.
    /// Errors: `StorageExhausted` when `out` cannot hold every produced requirement.
    pub fn fromBarSlice(
        function: config.Function,
        entries: []const bar.Entry,
        out: []Requirement,
    ) error{StorageExhausted}![]Requirement {
        const required = countBarRequirements(entries);
        if (out.len < required) return error.StorageExhausted;

        var written: usize = 0;
        for (entries) |entry| {
            if (Requirement.fromBar(function, entry)) |requirement| {
                out[written] = requirement;
                written += 1;
            }
        }

        std.debug.assert(written == required);
        return out[0..written];
    }
};

pub const Assignment = struct {
    requirement: Requirement,
    pool: Kind,
    base: u64,

    /// Returns the function that owns the assigned requirement.
    pub fn function(self: Assignment) config.Function {
        return switch (self.requirement.source) {
            .endpoint_bar => |source| source.function,
            .endpoint_expansion_rom => |owner| owner,
            .bridge_window => |source| source.function,
        };
    }
};

pub const bridge_io_alignment: u64 = 0x1000;
pub const bridge_memory_alignment: u64 = 0x10_0000;

fn countBarRequirements(entries: []const bar.Entry) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (entry.kind == .none) continue;
        if (barKindSize(entry.kind) == 0) continue;

        count += 1;
    }

    return count;
}

fn memoryKind(memory: bar.Kind.Memory) Kind {
    return switch (memory.width) {
        .bits_32 => if (memory.prefetchable) .mmio32_pref else .mmio32,
        .bits_64 => if (memory.prefetchable) .mmio64_pref else .mmio64,
    };
}

fn barKindSize(kind: bar.Kind) u64 {
    return switch (kind) {
        .none => 0,
        .io => |io| io.size,
        .memory => |memory| memory.size,
    };
}
