//! Tests for docs/specs/core/errors.md.

const std = @import("std");

const zpci = @import("zpci");

const Error = zpci.core.Error;

test "contract: zpci.core.Error is the exact public category set" {
    // Compare the public error-set names and count so missing variants or accidental extras fail.
    const expected = comptime .{
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
    const actual = @typeInfo(Error).error_set.?;

    try std.testing.expectEqual(@as(usize, expected.len), actual.len);

    inline for (expected) |name| {
        var found = false;
        inline for (actual) |field| {
            found = found or std.mem.eql(u8, field.name, name);
        }

        try std.testing.expect(found);
    }
}
