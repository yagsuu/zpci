//! Tests for docs/specs/interrupts/msix.md.

const std = @import("std");

const stdx = @import("stdx");
const zpci = @import("zpci");

const BarMemory = zpci.memory.BarMemory;
const Capability = zpci.capabilities.list.Capability;
const ConfigSpace = zpci.config.ConfigSpace;
const Function = zpci.config.Function;
const MessageControl = zpci.interrupts.msix.MessageControl;
const PbaLocation = zpci.interrupts.msix.PbaLocation;
const Sbdf = zpci.core.Sbdf;
const TableLocation = zpci.interrupts.msix.TableLocation;
const VectorControl = zpci.interrupts.msix.VectorControl;
const VectorEntry = zpci.interrupts.msix.VectorEntry;
const View = zpci.interrupts.msix.View;

const msix = zpci.interrupts.msix;
const standard = zpci.capabilities.list.standard;
const function_window_size: usize = 0x1000;
const test_sbdf = Sbdf.of(0, 0, 0, 0);
const cap_base: u8 = 0x40;
const offset = struct {
    const status: usize = 0x06;
};
const status = struct {
    const capabilities_list: u16 = 1 << 4;
};

test "layout: constants and packed words match the MSI-X wire layout" {
    // Compare public offsets and bit widths against the spec so downstream table math cannot drift.
    try std.testing.expectEqual(@as(u8, 0x11), msix.cap_id);
    try std.testing.expectEqual(@as(u8, 0x02), msix.register.message_control);
    try std.testing.expectEqual(@as(u8, 0x04), msix.register.table_offset_bir);
    try std.testing.expectEqual(@as(u8, 0x08), msix.register.pba_offset_bir);
    try std.testing.expectEqual(@as(usize, 0x0), msix.entry.message_address_lo);
    try std.testing.expectEqual(@as(usize, 0x4), msix.entry.message_address_hi);
    try std.testing.expectEqual(@as(usize, 0x8), msix.entry.message_data);
    try std.testing.expectEqual(@as(usize, 0xC), msix.entry.vector_control);
    try std.testing.expectEqual(@as(usize, 16), msix.table_entry_size);
    try std.testing.expectEqual(@as(usize, 32), msix.pba_bits_per_dword);
    try std.testing.expectEqual(@as(u16, 2048), msix.max_table_size);
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(MessageControl));
    try std.testing.expectEqual(@as(comptime_int, 16), @bitSizeOf(MessageControl));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(VectorControl));
    try std.testing.expectEqual(@as(comptime_int, 32), @bitSizeOf(VectorControl));

    const control: MessageControl = @bitCast(@as(u16, 0b11_101_00000000101));
    try std.testing.expectEqual(@as(u11, 5), control.table_size_minus_one);
    try std.testing.expectEqual(@as(u3, 0b101), control._reserved11);
    try std.testing.expect(control.function_mask);
    try std.testing.expect(control.msix_enable);

    const vector_control: VectorControl = @bitCast(@as(u32, 0xFFFF_FFFE));
    try std.testing.expect(!vector_control.masked);
    try std.testing.expectEqual(@as(u31, 0x7FFF_FFFF), vector_control._reserved1);
}

test "unit: validate decodes locations and snapshot span helpers" {
    // Validate once, then assert size, table span, PBA ceil span, and decoded offset/BIR snapshots.
    var bytes: [function_window_size]u8 = @splat(0);
    seedMsixCapability(&bytes, .{
        .table_size_minus_one = 32,
        .table_bir = 2,
        .table_offset = 0x180,
        .pba_bir = 2,
        .pba_offset = 0x280,
    });
    var backend = ConfigBackend.init(&bytes);
    const view = try validateView(&backend);

    try expectTableLocation(view.tableLocation(), 2, 0x180);
    try expectPbaLocation(view.pbaLocation(), 2, 0x280);
    try std.testing.expectEqual(@as(u16, 33), view.tableSize());
    try std.testing.expectEqual(@as(usize, 33 * msix.table_entry_size), view.tableSpanBytes());
    try std.testing.expectEqual(@as(usize, 8), view.pbaSpanBytes());
}

test "unit: validate decodes independent Table and PBA BIR values" {
    // Seed different legal BIRs to prove the two locator registers are not collapsed together.
    var bytes: [function_window_size]u8 = @splat(0);
    seedMsixCapability(&bytes, .{
        .table_size_minus_one = 0,
        .table_bir = 4,
        .table_offset = 0x1000,
        .pba_bir = 5,
        .pba_offset = 0x2000,
    });
    var backend = ConfigBackend.init(&bytes);
    const view = try validateView(&backend);

    try expectTableLocation(view.tableLocation(), 4, 0x1000);
    try expectPbaLocation(view.pbaLocation(), 5, 0x2000);
    try std.testing.expectEqual(@as(u16, 1), view.tableSize());
    try std.testing.expectEqual(@as(usize, 16), view.tableSpanBytes());
    try std.testing.expectEqual(@as(usize, 4), view.pbaSpanBytes());
}

test "unit: maximum table size produces maximum table and PBA spans" {
    // Exercise the u11 maximum encoding so off-by-one sizing defects change both byte spans.
    var bytes: [function_window_size]u8 = @splat(0);
    seedMsixCapability(&bytes, .{ .table_size_minus_one = 0x7FF });
    var backend = ConfigBackend.init(&bytes);
    const view = try validateView(&backend);

    try std.testing.expectEqual(@as(u16, 2048), view.tableSize());
    try std.testing.expectEqual(@as(usize, 2048 * 16), view.tableSpanBytes());
    try std.testing.expectEqual(@as(usize, 256), view.pbaSpanBytes());
}

test "malformed: validate rejects reserved Table and PBA BIR encodings" {
    // Try both reserved low-bit encodings on each locator register and require MalformedField.
    inline for (.{ @as(u3, 6), @as(u3, 7) }) |reserved_bir| {
        var table_bytes: [function_window_size]u8 = @splat(0);
        seedMsixCapability(&table_bytes, .{ .table_bir = reserved_bir, .pba_bir = 0 });
        var table_backend = ConfigBackend.init(&table_bytes);
        try std.testing.expectError(error.MalformedField, validateView(&table_backend));

        var pba_bytes: [function_window_size]u8 = @splat(0);
        seedMsixCapability(&pba_bytes, .{ .table_bir = 0, .pba_bir = reserved_bir });
        var pba_backend = ConfigBackend.init(&pba_bytes);
        try std.testing.expectError(error.MalformedField, validateView(&pba_backend));
    }
}

test "unit: find reports present, absent, and malformed traversal results" {
    // Walk real capability-list bytes to distinguish a found MSI-X capability from absence and cycles.
    var present_bytes: [function_window_size]u8 = @splat(0);
    seedHead(&present_bytes, 0x40);
    seedCapability(&present_bytes, 0x40, 0x09, 0x80);
    seedCapability(&present_bytes, 0x80, msix.cap_id, 0);
    seedMsixPayload(&present_bytes, 0x80, .{ .table_size_minus_one = 3 });
    var present_backend = ConfigBackend.init(&present_bytes);
    const present = (try View.find(functionFor(&present_backend))).?;
    try std.testing.expectEqual(@as(u8, 0x80), present.base);
    try std.testing.expectEqual(@as(u16, 4), present.tableSize());

    var no_list_bytes: [function_window_size]u8 = @splat(0);
    no_list_bytes[standard.head_offset] = cap_base;
    seedCapability(&no_list_bytes, cap_base, msix.cap_id, 0);
    seedMsixPayload(&no_list_bytes, cap_base, .{});
    var no_list_backend = ConfigBackend.init(&no_list_bytes);
    try std.testing.expectEqual(@as(?View, null), try View.find(functionFor(&no_list_backend)));

    var absent_bytes: [function_window_size]u8 = @splat(0);
    seedHead(&absent_bytes, 0x40);
    seedCapability(&absent_bytes, 0x40, @intFromEnum(zpci.capabilities.list.Id.msi), 0x44);
    seedCapability(&absent_bytes, 0x44, @intFromEnum(zpci.capabilities.list.Id.pci_express), 0);
    var absent_backend = ConfigBackend.init(&absent_bytes);
    try std.testing.expectEqual(@as(?View, null), try View.find(functionFor(&absent_backend)));

    var cycle_bytes: [function_window_size]u8 = @splat(0);
    seedHead(&cycle_bytes, 0x40);
    seedCapability(&cycle_bytes, 0x40, 0x09, 0x44);
    seedCapability(&cycle_bytes, 0x44, @intFromEnum(zpci.capabilities.list.Id.msi), 0x40);
    var cycle_backend = ConfigBackend.init(&cycle_bytes);
    try std.testing.expectError(error.MalformedCapability, View.find(functionFor(&cycle_backend)));
}

test "unit: live config reads observe current Message Control without refreshing snapshots" {
    // Mutate config bytes after validate to prove status bits are live while table metadata is cached.
    var bytes: [function_window_size]u8 = @splat(0);
    seedMsixCapability(&bytes, .{
        .table_size_minus_one = 7,
        .table_bir = 1,
        .table_offset = 0x100,
        .pba_bir = 1,
        .pba_offset = 0x200,
    });
    var backend = ConfigBackend.init(&bytes);
    const view = try validateView(&backend);
    backend.resetLog();

    store16(&bytes, cap_base + msix.register.message_control, messageControlRaw(.{
        .table_size_minus_one = 0x7FF,
        .reserved = 0b010,
        .function_mask = true,
        .msix_enable = true,
    }));
    store32(&bytes, cap_base + msix.register.table_offset_bir, locationRaw(4, 0x300));
    store32(&bytes, cap_base + msix.register.pba_offset_bir, locationRaw(5, 0x400));

    const control = try view.messageControl();
    try std.testing.expectEqual(@as(u11, 0x7FF), control.table_size_minus_one);
    try std.testing.expect(try view.enabled());
    try std.testing.expect(try view.functionMasked());
    try std.testing.expectEqual(@as(usize, 3), backend.read16_count);
    try std.testing.expectEqual(@as(usize, cap_base + msix.register.message_control), backend.last_read16_offset.?);
    try std.testing.expectEqual(@as(u16, 8), view.tableSize());
    try expectTableLocation(view.tableLocation(), 1, 0x100);
    try expectPbaLocation(view.pbaLocation(), 1, 0x200);
}

test "unit: table and PBA reads reconstruct values and reject invalid bounds before I/O" {
    // Read real table/PBA bytes, then use too-small windows and out-of-range vectors to prove guards fire first.
    var bytes: [function_window_size]u8 = @splat(0);
    seedMsixCapability(&bytes, .{ .table_size_minus_one = 63 });
    var config_backend = ConfigBackend.init(&bytes);
    const view = try validateView(&config_backend);
    config_backend.resetLog();

    var table_bytes: [32]u8 = @splat(0);
    store32(&table_bytes, 16 + msix.entry.message_address_lo, 0x89AB_CDEF);
    store32(&table_bytes, 16 + msix.entry.message_address_hi, 0x0123_4567);
    store32(&table_bytes, 16 + msix.entry.message_data, 0xCAFE_BABE);
    store32(&table_bytes, 16 + msix.entry.vector_control, 0xFFFF_FFFF);
    var table_backend = BarBackend.init(&table_bytes);

    const read_entry = try view.readEntry(table_backend.accessor(), 1);
    try expectVectorEntry(read_entry, .{
        .address = 0x0123_4567_89AB_CDEF,
        .data = 0xCAFE_BABE,
        .masked = true,
    });
    try std.testing.expectEqual(@as(usize, 0), config_backend.op_count);

    var pba_bytes: [8]u8 = @splat(0);
    store32(&pba_bytes, 4, @as(u32, 1) << 5);
    var pba_backend = BarBackend.init(&pba_bytes);
    try std.testing.expect(try view.vectorPending(pba_backend.accessor(), 37));
    try std.testing.expectEqual(@as(u32, 0x0000_0020), try view.pendingDword(pba_backend.accessor(), 1));
    try std.testing.expectEqual(@as(usize, 0), config_backend.op_count);

    var short_table_bytes: [31]u8 = @splat(0);
    var short_table_backend = BarBackend.init(&short_table_bytes);
    try std.testing.expectError(error.BarMemoryOutOfBounds, view.readEntry(short_table_backend.accessor(), 1));
    try std.testing.expectEqual(@as(usize, 0), short_table_backend.op_count);

    var small_pba_bytes: [4]u8 = @splat(0);
    var small_pba_backend = BarBackend.init(&small_pba_bytes);
    try std.testing.expectError(error.InvalidRouting, view.vectorPending(small_pba_backend.accessor(), 64));
    try std.testing.expectEqual(@as(usize, 0), small_pba_backend.op_count);
    try std.testing.expectError(error.BarMemoryOutOfBounds, view.pendingDword(small_pba_backend.accessor(), 1));
    try std.testing.expectEqual(@as(usize, 0), small_pba_backend.op_count);
}

test "unit: config writes preserve reserved bits and map write/readback failures" {
    // Exercise Message Control RMW commits through config bytes, including preserved bits and failure mapping.
    var bytes: [function_window_size]u8 = @splat(0);
    seedMsixCapability(&bytes, .{
        .table_size_minus_one = 0x123,
        .reserved = 0b101,
        .function_mask = true,
        .msix_enable = false,
    });
    var backend = ConfigBackend.init(&bytes);
    const view = try validateView(&backend);
    backend.resetLog();

    try view.enable();
    try expectMessageControlRaw(&bytes, .{
        .table_size_minus_one = 0x123,
        .reserved = 0b101,
        .function_mask = true,
        .msix_enable = true,
    });
    try std.testing.expectEqual(@as(usize, 1), backend.write16_count);

    try view.disable();
    try expectMessageControlRaw(&bytes, .{
        .table_size_minus_one = 0x123,
        .reserved = 0b101,
        .function_mask = true,
        .msix_enable = false,
    });

    try view.setFunctionMask(false);
    try expectMessageControlRaw(&bytes, .{
        .table_size_minus_one = 0x123,
        .reserved = 0b101,
        .function_mask = false,
        .msix_enable = false,
    });

    store16(&bytes, cap_base + msix.register.message_control, messageControlRaw(.{ .msix_enable = false }));
    backend.resetLog();
    backend.fail_next_write16 = true;
    try std.testing.expectError(error.ProgrammingWriteFailed, view.enable());
    try std.testing.expectEqual(@as(usize, 1), backend.write16_count);
    try expectMessageControlRaw(&bytes, .{ .msix_enable = false });

    backend.resetLog();
    backend.corrupt_readback16 = messageControlRaw(.{ .msix_enable = false });
    try std.testing.expectError(error.ProgrammingReadbackMismatch, view.enable());
    try expectMessageControlRaw(&bytes, .{ .msix_enable = true });
}

test "unit: programEntry self-masks, preserves reserved bits, and writes fields in order" {
    // Program vector 1 and assert the observable write/readback sequence around the self-mask window.
    var bytes: [function_window_size]u8 = @splat(0);
    seedMsixCapability(&bytes, .{ .table_size_minus_one = 3, .msix_enable = true });
    var config_backend = ConfigBackend.init(&bytes);
    const view = try validateView(&config_backend);
    config_backend.resetLog();

    var table_bytes: [64]u8 = @splat(0);
    seedEntry(&table_bytes, 1, .{
        .address = 0x1111_2222_3333_4444,
        .data = 0x5555_AAAA,
        .vector_control = 0xA5A5_A5A4,
    });
    var table_backend = BarBackend.init(&table_bytes);

    try view.programEntry(table_backend.accessor(), 1, .{
        .address = 0x0123_4567_89AB_CDEF,
        .data = 0xCAFE_BABE,
        .masked = false,
    });

    try std.testing.expectEqual(@as(usize, 0), config_backend.op_count);
    try expectDword(&table_bytes, 16 + msix.entry.message_address_lo, 0x89AB_CDEF);
    try expectDword(&table_bytes, 16 + msix.entry.message_address_hi, 0x0123_4567);
    try expectDword(&table_bytes, 16 + msix.entry.message_data, 0xCAFE_BABE);
    try expectDword(&table_bytes, 16 + msix.entry.vector_control, 0xA5A5_A5A4);
    try expectBarOp(table_backend.ops[4], .write, 16 + msix.entry.vector_control, 0xA5A5_A5A5);
    try expectBarOp(table_backend.ops[6], .write, 16 + msix.entry.message_address_lo, 0x89AB_CDEF);
    try expectBarOp(table_backend.ops[8], .write, 16 + msix.entry.message_address_hi, 0x0123_4567);
    try expectBarOp(table_backend.ops[10], .write, 16 + msix.entry.message_data, 0xCAFE_BABE);
    try expectBarOp(table_backend.ops[12], .write, 16 + msix.entry.vector_control, 0xA5A5_A5A4);
}

test "failure: programEntry save read failures issue no writes" {
    // Fail the first save read and assert the programming error is returned without touching table bytes.
    var bytes: [function_window_size]u8 = @splat(0);
    seedMsixCapability(&bytes, .{ .table_size_minus_one = 1 });
    var config_backend = ConfigBackend.init(&bytes);
    const view = try validateView(&config_backend);

    var table_bytes: [32]u8 = @splat(0x5A);
    const before = table_bytes;
    var table_backend = BarBackend.init(&table_bytes);
    table_backend.fail_read_index = 0;

    try std.testing.expectError(error.ProgrammingWriteFailed, view.programEntry(
        table_backend.accessor(),
        0,
        .{ .address = 0, .data = 0, .masked = false },
    ));
    try std.testing.expectEqual(@as(usize, 0), table_backend.write_count);
    try std.testing.expectEqualSlices(u8, &before, &table_bytes);
}

test "failure: programEntry rolls back a readback mismatch to the saved entry" {
    // Corrupt the address-low readback and require reverse-order restores to recover the saved dwords.
    var bytes: [function_window_size]u8 = @splat(0);
    seedMsixCapability(&bytes, .{ .table_size_minus_one = 1 });
    var config_backend = ConfigBackend.init(&bytes);
    const view = try validateView(&config_backend);

    var table_bytes: [32]u8 = @splat(0);
    seedEntry(&table_bytes, 0, .{
        .address = 0xAAAA_BBBB_CCCC_DDDD,
        .data = 0xEEEE_FFFF,
        .vector_control = 0x1357_2468,
    });
    const before = table_bytes;
    var table_backend = BarBackend.init(&table_bytes);
    table_backend.corrupt_read_index = 5;
    table_backend.corrupt_value = 0;

    try std.testing.expectError(error.ProgrammingReadbackMismatch, view.programEntry(
        table_backend.accessor(),
        0,
        .{ .address = 0x0123_4567_89AB_CDEF, .data = 0xCAFE_BABE, .masked = false },
    ));
    try std.testing.expectEqualSlices(u8, &before, &table_bytes);
    try expectBarOp(table_backend.ops[8], .write, msix.entry.message_address_lo, 0xCCCC_DDDD);
    try expectBarOp(table_backend.ops[10], .write, msix.entry.vector_control, 0x1357_2468);
}

test "unit: programEntries handles empty input, upfront bounds, and failure boundaries" {
    // Drive a three-entry batch and fail entry 1 so entry 0 commits, entry 1 rolls back, and entry 2 is untouched.
    var bytes: [function_window_size]u8 = @splat(0);
    seedMsixCapability(&bytes, .{ .table_size_minus_one = 2 });
    var config_backend = ConfigBackend.init(&bytes);
    const view = try validateView(&config_backend);

    var empty_table_bytes: [48]u8 = @splat(0);
    var empty_backend = BarBackend.init(&empty_table_bytes);
    try view.programEntries(empty_backend.accessor(), 1, &.{});
    try std.testing.expectEqual(@as(usize, 0), empty_backend.op_count);

    try std.testing.expectError(error.InvalidRouting, view.programEntries(
        empty_backend.accessor(),
        2,
        &.{ .{ .address = 0, .data = 0, .masked = false }, .{ .address = 1, .data = 1, .masked = true } },
    ));
    try std.testing.expectEqual(@as(usize, 0), empty_backend.op_count);

    var short_table_bytes: [47]u8 = @splat(0);
    var short_backend = BarBackend.init(&short_table_bytes);
    try std.testing.expectError(error.BarMemoryOutOfBounds, view.programEntries(
        short_backend.accessor(),
        0,
        &.{ .{ .address = 0, .data = 0, .masked = false }, .{ .address = 1, .data = 1, .masked = true }, .{ .address = 2, .data = 2, .masked = false } },
    ));
    try std.testing.expectEqual(@as(usize, 0), short_backend.op_count);

    var table_bytes: [48]u8 = @splat(0);
    seedEntry(&table_bytes, 0, .{ .address = 0x10, .data = 0x10, .vector_control = 0x8000_0000 });
    seedEntry(&table_bytes, 1, .{ .address = 0x20, .data = 0x20, .vector_control = 0x4000_0001 });
    seedEntry(&table_bytes, 2, .{ .address = 0x30, .data = 0x30, .vector_control = 0x2000_0000 });
    const entry1_before = table_bytes[16..32].*;
    const entry2_before = table_bytes[32..48].*;
    var table_backend = BarBackend.init(&table_bytes);
    table_backend.corrupt_read_index = 14;
    table_backend.corrupt_value = 0;
    const entries = [_]VectorEntry{
        .{ .address = 0xAAAA_BBBB_CCCC_DDDD, .data = 0x1111_1111, .masked = false },
        .{ .address = 0x0123_4567_89AB_CDEF, .data = 0x2222_2222, .masked = true },
        .{ .address = 0x9999_AAAA_BBBB_CCCC, .data = 0x3333_3333, .masked = false },
    };

    try std.testing.expectError(error.ProgrammingReadbackMismatch, view.programEntries(
        table_backend.accessor(),
        0,
        &entries,
    ));
    try expectDword(&table_bytes, msix.entry.message_address_lo, 0xCCCC_DDDD);
    try expectDword(&table_bytes, msix.entry.message_address_hi, 0xAAAA_BBBB);
    try expectDword(&table_bytes, msix.entry.message_data, 0x1111_1111);
    try expectDword(&table_bytes, msix.entry.vector_control, 0x8000_0000);
    try std.testing.expectEqualSlices(u8, &entry1_before, table_bytes[16..32]);
    try std.testing.expectEqualSlices(u8, &entry2_before, table_bytes[32..48]);
}

test "unit: setVectorMask preserves reserved bits and rolls back readback mismatch" {
    // Toggle only Vector Control.masked, then force a mismatch and require restored pre-state bytes.
    var bytes: [function_window_size]u8 = @splat(0);
    seedMsixCapability(&bytes, .{ .table_size_minus_one = 1 });
    var config_backend = ConfigBackend.init(&bytes);
    const view = try validateView(&config_backend);
    config_backend.resetLog();

    var table_bytes: [32]u8 = @splat(0);
    seedEntry(&table_bytes, 1, .{
        .address = 0x1111_2222_3333_4444,
        .data = 0x5555_6666,
        .vector_control = 0xFFFF_FFFE,
    });
    var table_backend = BarBackend.init(&table_bytes);

    try view.setVectorMask(table_backend.accessor(), 1, true);
    try expectDword(&table_bytes, 16 + msix.entry.message_address_lo, 0x3333_4444);
    try expectDword(&table_bytes, 16 + msix.entry.message_address_hi, 0x1111_2222);
    try expectDword(&table_bytes, 16 + msix.entry.message_data, 0x5555_6666);
    try expectDword(&table_bytes, 16 + msix.entry.vector_control, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(usize, 0), config_backend.op_count);

    seedEntry(&table_bytes, 1, .{
        .address = 0x1111_2222_3333_4444,
        .data = 0x5555_6666,
        .vector_control = 0xABCD_EF01,
    });
    const before = table_bytes;
    table_backend.resetLog();
    table_backend.corrupt_read_index = 1;
    table_backend.corrupt_value = 0;
    try std.testing.expectError(error.ProgrammingReadbackMismatch, view.setVectorMask(
        table_backend.accessor(),
        1,
        false,
    ));
    try std.testing.expectEqualSlices(u8, &before, &table_bytes);
}

test "integration: cross-BIR callers can use distinct BAR memories without cross-touching" {
    // Use separate table and PBA fakes to prove each operation reaches only the accessor the caller supplied.
    var bytes: [function_window_size]u8 = @splat(0);
    seedMsixCapability(&bytes, .{
        .table_size_minus_one = 0,
        .table_bir = 4,
        .table_offset = 0x1000,
        .pba_bir = 5,
        .pba_offset = 0x2000,
    });
    var config_backend = ConfigBackend.init(&bytes);
    const view = try validateView(&config_backend);

    var table_bytes: [16]u8 = @splat(0);
    seedEntry(&table_bytes, 0, .{ .address = 0, .data = 0, .vector_control = 0xAAAA_AAAA });
    var table_backend = BarBackend.init(&table_bytes);
    var pba_bytes: [4]u8 = @splat(0);
    store32(&pba_bytes, 0, 0x8000_0001);
    var pba_backend = BarBackend.init(&pba_bytes);

    try view.programEntry(table_backend.accessor(), 0, .{
        .address = 0xFEE0_0000,
        .data = 0x45,
        .masked = false,
    });
    try std.testing.expect(table_backend.op_count > 0);
    try std.testing.expectEqual(@as(usize, 0), pba_backend.op_count);

    try std.testing.expectEqual(@as(u32, 0x8000_0001), try view.pendingDword(pba_backend.accessor(), 0));
    try std.testing.expectEqual(@as(usize, 1), pba_backend.op_count);

    pba_backend.resetLog();
    try std.testing.expectError(error.BarMemoryOutOfBounds, view.programEntry(
        pba_backend.accessor(),
        0,
        .{ .address = 0, .data = 0, .masked = false },
    ));
    try std.testing.expectEqual(@as(usize, 0), pba_backend.op_count);
}

const ConfigBackend = struct {
    bytes: []u8,
    op_count: usize = 0,
    read16_count: usize = 0,
    write16_count: usize = 0,
    last_read16_offset: ?usize = null,
    fail_next_write16: bool = false,
    corrupt_readback16: ?u16 = null,

    fn init(bytes: []u8) ConfigBackend {
        std.debug.assert(bytes.len == function_window_size);
        return .{ .bytes = bytes };
    }

    fn configSpace(self: *ConfigBackend) ConfigSpace {
        return ConfigSpace.init(@ptrCast(self), &vtable);
    }

    fn resetLog(self: *ConfigBackend) void {
        self.op_count = 0;
        self.read16_count = 0;
        self.write16_count = 0;
        self.last_read16_offset = null;
        self.fail_next_write16 = false;
        self.corrupt_readback16 = null;
    }

    const vtable: ConfigSpace.VTable = .{
        .read8 = read8,
        .read16 = read16,
        .read32 = read32,
        .write8 = write8,
        .write16 = write16,
        .write32 = write32,
    };

    fn read8(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigSpace.Error!u8 {
        _ = sbdf;
        const self: *ConfigBackend = @ptrCast(@alignCast(context));
        self.op_count += 1;
        return self.bytes[byte_offset];
    }

    fn read16(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigSpace.Error!u16 {
        _ = sbdf;
        const self: *ConfigBackend = @ptrCast(@alignCast(context));
        self.op_count += 1;
        self.read16_count += 1;
        self.last_read16_offset = byte_offset;
        if (self.corrupt_readback16) |value| {
            if (self.write16_count > 0) {
                self.corrupt_readback16 = null;
                return value;
            }
        }

        return load16(self.bytes, byte_offset);
    }

    fn read32(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigSpace.Error!u32 {
        _ = sbdf;
        const self: *ConfigBackend = @ptrCast(@alignCast(context));
        self.op_count += 1;
        return load32(self.bytes, byte_offset);
    }

    fn write8(context: *anyopaque, sbdf: Sbdf, byte_offset: usize, value: u8) ConfigSpace.Error!void {
        _ = sbdf;
        const self: *ConfigBackend = @ptrCast(@alignCast(context));
        self.op_count += 1;
        self.bytes[byte_offset] = value;
    }

    fn write16(context: *anyopaque, sbdf: Sbdf, byte_offset: usize, value: u16) ConfigSpace.Error!void {
        _ = sbdf;
        const self: *ConfigBackend = @ptrCast(@alignCast(context));
        self.op_count += 1;
        self.write16_count += 1;
        if (self.fail_next_write16) {
            self.fail_next_write16 = false;
            return error.UnsupportedAccessWidth;
        }

        store16(self.bytes, byte_offset, value);
    }

    fn write32(context: *anyopaque, sbdf: Sbdf, byte_offset: usize, value: u32) ConfigSpace.Error!void {
        _ = sbdf;
        const self: *ConfigBackend = @ptrCast(@alignCast(context));
        self.op_count += 1;
        store32(self.bytes, byte_offset, value);
    }
};

const BarOp = struct {
    kind: Kind,
    offset: usize,
    value: u32,

    const Kind = enum { read, write };
};

const BarBackend = struct {
    bytes: []u8,
    ops: [128]BarOp = undefined,
    op_count: usize = 0,
    read_count: usize = 0,
    write_count: usize = 0,
    fail_read_index: ?usize = null,
    fail_write_index: ?usize = null,
    corrupt_read_index: ?usize = null,
    corrupt_value: u32 = 0,

    fn init(bytes: []u8) BarBackend {
        return .{ .bytes = bytes };
    }

    fn accessor(self: *BarBackend) BarMemory {
        return BarMemory.init(@ptrCast(self), &vtable, self.bytes.len);
    }

    fn resetLog(self: *BarBackend) void {
        self.op_count = 0;
        self.read_count = 0;
        self.write_count = 0;
        self.fail_read_index = null;
        self.fail_write_index = null;
        self.corrupt_read_index = null;
        self.corrupt_value = 0;
    }

    fn append(self: *BarBackend, op: BarOp) void {
        std.debug.assert(self.op_count < self.ops.len);
        self.ops[self.op_count] = op;
        self.op_count += 1;
    }

    const vtable: BarMemory.VTable = .{
        .read32 = read32,
        .write32 = write32,
    };

    fn read32(context: *anyopaque, byte_offset: usize) BarMemory.Error!u32 {
        const self: *BarBackend = @ptrCast(@alignCast(context));
        const index = self.read_count;
        self.read_count += 1;
        if (self.fail_read_index == index) {
            self.append(.{ .kind = .read, .offset = byte_offset, .value = 0 });
            return error.BarMemoryOutOfBounds;
        }

        const value = if (self.corrupt_read_index == index)
            self.corrupt_value
        else
            load32(self.bytes, byte_offset);
        self.append(.{ .kind = .read, .offset = byte_offset, .value = value });
        return value;
    }

    fn write32(context: *anyopaque, byte_offset: usize, value: u32) BarMemory.Error!void {
        const self: *BarBackend = @ptrCast(@alignCast(context));
        const index = self.write_count;
        self.write_count += 1;
        self.append(.{ .kind = .write, .offset = byte_offset, .value = value });
        if (self.fail_write_index == index) return error.BarMemoryOutOfBounds;

        store32(self.bytes, byte_offset, value);
    }
};

fn functionFor(backend: *ConfigBackend) Function {
    return Function.unchecked(backend.configSpace(), test_sbdf);
}

fn validateView(backend: *ConfigBackend) !View {
    return View.validate(functionFor(backend), .{ .id = msix.cap_id, .offset = cap_base });
}

fn seedMsixCapability(bytes: []u8, options: MsixSeed) void {
    seedHead(bytes, cap_base);
    seedCapability(bytes, cap_base, msix.cap_id, 0);
    seedMsixPayload(bytes, cap_base, options);
}

fn seedMsixPayload(bytes: []u8, base: u8, options: MsixSeed) void {
    store16(bytes, @as(usize, base) + msix.register.message_control, messageControlRaw(options));
    store32(bytes, @as(usize, base) + msix.register.table_offset_bir, locationRaw(
        options.table_bir,
        options.table_offset,
    ));
    store32(bytes, @as(usize, base) + msix.register.pba_offset_bir, locationRaw(
        options.pba_bir,
        options.pba_offset,
    ));
}

const MsixSeed = struct {
    table_size_minus_one: u11 = 0,
    reserved: u3 = 0,
    function_mask: bool = false,
    msix_enable: bool = false,
    table_bir: u3 = 0,
    table_offset: u32 = 0,
    pba_bir: u3 = 0,
    pba_offset: u32 = 0,
};

fn seedHead(bytes: []u8, head: u8) void {
    store16(bytes, offset.status, status.capabilities_list);
    bytes[standard.head_offset] = head;
}

fn seedCapability(bytes: []u8, base: u8, id: u8, next: u8) void {
    bytes[base] = id;
    bytes[@as(usize, base) + 1] = next;
}

fn seedEntry(bytes: []u8, index: usize, fields: struct {
    address: u64,
    data: u32,
    vector_control: u32,
}) void {
    const base = index * msix.table_entry_size;
    store32(bytes, base + msix.entry.message_address_lo, @truncate(fields.address));
    store32(bytes, base + msix.entry.message_address_hi, @truncate(fields.address >> 32));
    store32(bytes, base + msix.entry.message_data, fields.data);
    store32(bytes, base + msix.entry.vector_control, fields.vector_control);
}

fn messageControlRaw(options: MsixSeed) u16 {
    var raw = @as(u16, options.table_size_minus_one);
    raw |= @as(u16, options.reserved) << 11;
    if (options.function_mask) raw |= @as(u16, 1) << 14;
    if (options.msix_enable) raw |= @as(u16, 1) << 15;
    return raw;
}

fn locationRaw(bir: u3, base_offset: u32) u32 {
    return (base_offset & ~@as(u32, 0b111)) | @as(u32, bir);
}

fn expectTableLocation(actual: TableLocation, bir: u3, base_offset: u32) !void {
    try std.testing.expectEqual(bir, actual.bir);
    try std.testing.expectEqual(base_offset, actual.offset);
}

fn expectPbaLocation(actual: PbaLocation, bir: u3, base_offset: u32) !void {
    try std.testing.expectEqual(bir, actual.bir);
    try std.testing.expectEqual(base_offset, actual.offset);
}

fn expectVectorEntry(actual: VectorEntry, expected: VectorEntry) !void {
    try std.testing.expectEqual(expected.address, actual.address);
    try std.testing.expectEqual(expected.data, actual.data);
    try std.testing.expectEqual(expected.masked, actual.masked);
}

fn expectMessageControlRaw(bytes: []const u8, expected: MsixSeed) !void {
    try std.testing.expectEqual(
        messageControlRaw(expected),
        load16(bytes, cap_base + msix.register.message_control),
    );
}

fn expectDword(bytes: []const u8, byte_offset: usize, expected: u32) !void {
    try std.testing.expectEqual(expected, load32(bytes, byte_offset));
}

fn expectBarOp(actual: BarOp, kind: BarOp.Kind, byte_offset: usize, value: u32) !void {
    try std.testing.expectEqual(kind, actual.kind);
    try std.testing.expectEqual(byte_offset, actual.offset);
    try std.testing.expectEqual(value, actual.value);
}

fn store16(bytes: []u8, byte_offset: usize, value: u16) void {
    const encoded = stdx.layout.Le(u16).fromNative(value);
    stdx.bytes.store(stdx.layout.Le(u16), bytes, byte_offset, encoded) catch |err| switch (err) {
        error.EndOfStream => unreachable,
    };
}

fn store32(bytes: []u8, byte_offset: usize, value: u32) void {
    const encoded = stdx.layout.Le(u32).fromNative(value);
    stdx.bytes.store(stdx.layout.Le(u32), bytes, byte_offset, encoded) catch |err| switch (err) {
        error.EndOfStream => unreachable,
    };
}

fn load16(bytes: []const u8, byte_offset: usize) u16 {
    const wrapped = stdx.bytes.load(stdx.layout.Le(u16), bytes, byte_offset) catch |err| switch (err) {
        error.EndOfStream => unreachable,
    };
    return wrapped.native();
}

fn load32(bytes: []const u8, byte_offset: usize) u32 {
    const wrapped = stdx.bytes.load(stdx.layout.Le(u32), bytes, byte_offset) catch |err| switch (err) {
        error.EndOfStream => unreachable,
    };
    return wrapped.native();
}
