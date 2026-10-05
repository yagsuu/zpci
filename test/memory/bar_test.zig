//! Tests for docs/specs/memory/bar.md.

const std = @import("std");

const pci = @import("pci");

// Keep host-test backends out of the production memory namespace.
comptime {
    if (@hasDecl(pci.memory, "TestBarMemory")) {
        @compileError("pci.memory must not expose TestBarMemory; use pci.testing.memory.TestBarMemory");
    }
    if (@hasDecl(pci.memory, "FakeBarMemory")) {
        @compileError("pci.memory must not expose FakeBarMemory; use pci.testing.memory.TestBarMemory");
    }
    if (@hasDecl(pci.testing.memory, "FakeBarMemory")) {
        @compileError("pci.testing.memory must not expose FakeBarMemory; use TestBarMemory");
    }
}

test "unit: BarMemory reports the caller-owned length" {
    var backing: [16]u8 = @splat(0);
    var backend: pci.testing.memory.TestBarMemory = .{ .bytes = &backing };
    const table = backend.accessor();

    try std.testing.expectEqual(@as(usize, 16), table.len());
}

test "unit: read32 returns native integers from little-endian bytes" {
    var backing: [8]u8 = .{ 0xEF, 0xBE, 0xAD, 0xDE, 0x21, 0x00, 0x00, 0x00 };
    var backend: pci.testing.memory.TestBarMemory = .{ .bytes = &backing };
    const table = backend.accessor();

    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), try table.read32(0));
    try std.testing.expectEqual(@as(u32, 0x0000_0021), try table.read32(4));
}

test "unit: write32 encodes native integers as little-endian bytes" {
    var backing: [8]u8 = @splat(0);
    var backend: pci.testing.memory.TestBarMemory = .{ .bytes = &backing };
    const table = backend.accessor();

    try table.write32(0, 0xFEE0_0000);
    try table.write32(4, 0x0000_0021);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x00, 0x00, 0xE0, 0xFE, 0x21, 0x00, 0x00, 0x00 },
        &backing,
    );
}

test "unit: aligned dword offsets remain independent across the buffer" {
    var backing: [16]u8 = @splat(0);
    var backend: pci.testing.memory.TestBarMemory = .{ .bytes = &backing };
    const table = backend.accessor();

    const values = [_]u32{ 0xDEAD_BEEF, 0x1234_5678, 0xFEE0_0000, 0x0000_0021 };
    inline for (values, 0..) |v, i| {
        try table.write32(i * 4, v);
    }

    inline for (values, 0..) |v, i| {
        try std.testing.expectEqual(v, try table.read32(i * 4));
    }
}

test "malformed: read starting exactly at the end reports BarMemoryOutOfBounds" {
    var backing: [16]u8 = @splat(0);
    var backend: pci.testing.memory.TestBarMemory = .{ .bytes = &backing };
    const table = backend.accessor();

    try std.testing.expectError(error.BarMemoryOutOfBounds, table.read32(backing.len));
}

test "malformed: write past the region reports BarMemoryOutOfBounds and leaves storage unchanged" {
    var backing: [16]u8 = .{
        0x11, 0x22, 0x33, 0x44,
        0x55, 0x66, 0x77, 0x88,
        0x99, 0xAA, 0xBB, 0xCC,
        0xDD, 0xEE, 0xFF, 0x00,
    };
    const before = backing;
    var backend: pci.testing.memory.TestBarMemory = .{ .bytes = &backing };
    const table = backend.accessor();

    try std.testing.expectError(error.BarMemoryOutOfBounds, table.write32(backing.len, 0));
    try std.testing.expectError(
        error.BarMemoryOutOfBounds,
        table.write32(backing.len - 3, 0xAABBCCDD),
    );

    try std.testing.expectEqualSlices(u8, &before, &backing);
}

test "malformed: unaligned read of an in-region offset reports UnalignedAccess" {
    var backing: [16]u8 = @splat(0);
    var backend: pci.testing.memory.TestBarMemory = .{ .bytes = &backing };
    const table = backend.accessor();

    try std.testing.expectError(error.UnalignedAccess, table.read32(1));
    try std.testing.expectError(error.UnalignedAccess, table.read32(2));
    try std.testing.expectError(error.UnalignedAccess, table.read32(3));
}

test "malformed: unaligned write of an in-region offset reports UnalignedAccess" {
    var backing: [16]u8 = @splat(0);
    var backend: pci.testing.memory.TestBarMemory = .{ .bytes = &backing };
    const table = backend.accessor();

    try std.testing.expectError(error.UnalignedAccess, table.write32(1, 0));
    try std.testing.expectError(error.UnalignedAccess, table.write32(2, 0));
    try std.testing.expectError(error.UnalignedAccess, table.write32(3, 0));
}

test "malformed: containment beats alignment for end-of-region offsets" {
    var backing: [16]u8 = @splat(0);
    var backend: pci.testing.memory.TestBarMemory = .{ .bytes = &backing };
    const table = backend.accessor();

    try std.testing.expectError(error.BarMemoryOutOfBounds, table.read32(13));
}

test "unit: zero-length region rejects any read or write" {
    var backing: [0]u8 = .{};
    var backend: pci.testing.memory.TestBarMemory = .{ .bytes = &backing };
    const table = backend.accessor();

    try std.testing.expectEqual(@as(usize, 0), table.len());
    try std.testing.expectError(error.BarMemoryOutOfBounds, table.read32(0));
    try std.testing.expectError(error.BarMemoryOutOfBounds, table.write32(0, 0));
}

test "unit: BarMemory handle copies share the same backend context" {
    var backing: [8]u8 = @splat(0);
    var backend: pci.testing.memory.TestBarMemory = .{ .bytes = &backing };
    const table_a = backend.accessor();
    const table_b = table_a;

    try table_a.write32(0, 0xCAFE_BABE);
    try std.testing.expectEqual(@as(u32, 0xCAFE_BABE), try table_b.read32(0));
}
