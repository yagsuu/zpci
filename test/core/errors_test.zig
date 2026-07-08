//! Tests for docs/specs/core/errors.md.

const std = @import("std");

const zpci = @import("zpci");

const Error = zpci.core.Error;

test "unit: every spec-named variant exists in zpci.core.Error" {
    const variants = comptime .{
        "OutOfBounds",
        "AbsentFunction",
        "BadHeaderType",
        "MalformedField",
        "MalformedCapability",
        "MalformedBar",
        "CycleDetected",
        "UnsupportedRevision",
        "UnsupportedCapability",
        "StorageExhausted",
        "ResourceExhausted",
        "BridgeWindowUnencodable",
        "BusRangeExhausted",
        "UnsupportedAccessWidth",
        "UnalignedAccess",
        "InvalidIdentifier",
        "InvalidRouting",
        "BarMemoryOutOfBounds",
        "ProgrammingReadbackMismatch",
        "ProgrammingWriteFailed",
        "ProgrammingPartial",
    };

    inline for (variants) |name| {
        const value: Error = @field(Error, name);
        try std.testing.expect(@errorName(value).len > 0);
    }
}

test "unit: zpci.Error does not fold std.mem.Allocator.Error" {
    // Spec §Allocating APIs: OutOfMemory is Allocator.Error's sole variant
    // and must not appear in the package error set.
    const info = @typeInfo(Error).error_set.?;
    inline for (info) |field| {
        try std.testing.expect(!std.mem.eql(u8, field.name, "OutOfMemory"));
    }
}
