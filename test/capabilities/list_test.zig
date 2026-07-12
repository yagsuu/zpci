//! Tests for docs/specs/capabilities/list.md.

const std = @import("std");

const stdx = @import("stdx");
const pci = @import("pci");

const Capability = pci.capabilities.list.Capability;
const ConfigSpace = pci.config.ConfigSpace;
const Cursor = pci.capabilities.list.Cursor;
const Function = pci.config.Function;
const Id = pci.capabilities.list.Id;
const Iterator = pci.capabilities.list.Iterator;
const Sbdf = pci.core.Sbdf;
const TestConfigSpace = pci.testing.config.TestConfigSpace;

const list = pci.capabilities.list;
const standard = list.standard;
const function_window_size: usize = 0x1000;
const test_sbdf = Sbdf.of(0, 0, 0, 0);
const offset = struct {
    const status: usize = 0x06;
};
const status = struct {
    const capabilities_list: u16 = 1 << 4;
};

test "layout: standard capability window covers conventional dword slots" {
    // Compare public list constants against the conventional PCI capability range.
    try std.testing.expectEqual(@as(u8, 0x34), standard.head_offset);
    try std.testing.expectEqual(@as(u8, 0x40), standard.window.start);
    try std.testing.expectEqual(@as(u8, 0xFC), standard.window.end);
    try std.testing.expectEqual(@as(u8, 4), standard.window.step);
    try std.testing.expectEqual(@as(usize, 48), standard.window.slot_count);

    const span: usize = @as(usize, standard.window.end) - @as(usize, standard.window.start);
    const step: usize = standard.window.step;
    try std.testing.expectEqual(standard.window.slot_count, @divExact(span, step) + 1);
}

test "unit: validate returns empty traversal when status capability bit is clear" {
    // Seed a nonzero head and real node; the cleared status bit must make them unreachable.
    var bytes: [function_window_size]u8 = @splat(0);
    bytes[standard.head_offset] = standard.window.start;
    seedCapability(&bytes, standard.window.start, @intFromEnum(Id.pci_express), 0);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const function = uncheckedFunction(&backend);

    var it = try Iterator.validate(function);

    try std.testing.expectEqual(@as(?Capability, null), try it.next());
}

test "unit: validate treats a masked zero head pointer as an empty list" {
    // Enable capability traversal but set only reserved low head bits; masking must terminate.
    var bytes: [function_window_size]u8 = @splat(0);
    enableCapabilities(&bytes);
    bytes[standard.head_offset] = 0b11;
    seedCapability(&bytes, standard.window.start, @intFromEnum(Id.pci_express), 0);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const function = uncheckedFunction(&backend);

    var it = try Iterator.validate(function);

    try std.testing.expectEqual(@as(?Capability, null), try it.next());
}

test "unit: iterator yields one capability and then terminates on zero next" {
    // Seed one PCI Express capability and assert raw id, typed tag, and terminal next handling.
    var bytes: [function_window_size]u8 = @splat(0);
    seedHead(&bytes, standard.window.start);
    seedCapability(&bytes, standard.window.start, @intFromEnum(Id.pci_express), 0);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const function = uncheckedFunction(&backend);

    var it = try Iterator.validate(function);
    const cap = (try it.next()).?;

    try expectCapability(cap, @intFromEnum(Id.pci_express), standard.window.start);
    try std.testing.expectEqual(Id.pci_express, cap.idTag());
    try std.testing.expectEqual(@as(?Capability, null), try it.next());
}

test "unit: iterator walks multiple capabilities in next-pointer order" {
    // Chain unknown, MSI, and MSI-X capabilities at non-contiguous legal slots.
    var bytes: [function_window_size]u8 = @splat(0);
    seedHead(&bytes, 0x40);
    seedCapability(&bytes, 0x40, 0x09, 0x80);
    seedCapability(&bytes, 0x80, @intFromEnum(Id.msi), 0xFC);
    seedCapability(&bytes, 0xFC, @intFromEnum(Id.msi_x), 0);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const function = uncheckedFunction(&backend);

    var it = try Iterator.validate(function);
    const vendor = (try it.next()).?;
    const msi = (try it.next()).?;
    const msix = (try it.next()).?;

    try expectCapability(vendor, 0x09, 0x40);
    try std.testing.expectEqual(@as(Id, @enumFromInt(0x09)), vendor.idTag());
    try expectCapability(msi, @intFromEnum(Id.msi), 0x80);
    try std.testing.expectEqual(Id.msi, msi.idTag());
    try expectCapability(msix, @intFromEnum(Id.msi_x), 0xFC);
    try std.testing.expectEqual(Id.msi_x, msix.idTag());
    try std.testing.expectEqual(@as(?Capability, null), try it.next());
}

test "unit: find returns first matching capability and null when absent" {
    // Search through mixed ids using both the free helper and the stateful iterator method.
    var bytes: [function_window_size]u8 = @splat(0);
    seedHead(&bytes, 0x40);
    seedCapability(&bytes, 0x40, 0x09, 0x80);
    seedCapability(&bytes, 0x80, @intFromEnum(Id.msi), 0xC0);
    seedCapability(&bytes, 0xC0, @intFromEnum(Id.msi_x), 0);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const function = uncheckedFunction(&backend);

    const msi = (try list.find(function, Id.msi)).?;
    var it = try Iterator.validate(function);
    const msix = (try it.find(Id.msi_x)).?;

    try expectCapability(msi, @intFromEnum(Id.msi), 0x80);
    try expectCapability(msix, @intFromEnum(Id.msi_x), 0xC0);
    try std.testing.expectEqual(@as(?Capability, null), try list.find(function, Id.pci_express));
    try std.testing.expectEqual(@as(?Capability, null), try it.next());
}

test "malformed: iterator rejects an initial head outside the capability window" {
    // A below-window head must fail before any capability is reported.
    var bytes: [function_window_size]u8 = @splat(0);
    seedHead(&bytes, standard.window.start - standard.window.step);
    seedCapability(&bytes, standard.window.start, @intFromEnum(Id.pci_express), 0);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const function = uncheckedFunction(&backend);

    try expectMalformedFirstStep(function);
}

test "malformed: iterator rejects reserved bits in a next pointer before yielding node" {
    // Reserved low bits in the current node's next byte make that node malformed.
    var bytes: [function_window_size]u8 = @splat(0);
    seedHead(&bytes, standard.window.start);
    seedCapability(&bytes, standard.window.start, @intFromEnum(Id.pci_express), 0x42);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const function = uncheckedFunction(&backend);

    var it = try Iterator.validate(function);

    try std.testing.expectError(error.MalformedCapability, it.next());
}

test "malformed: iterator rejects next pointers outside the capability window" {
    // An aligned next pointer below the legal window is rejected when traversal reaches it.
    var bytes: [function_window_size]u8 = @splat(0);
    seedHead(&bytes, standard.window.start);
    seedCapability(&bytes, standard.window.start, @intFromEnum(Id.pci_express), 0x20);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const function = uncheckedFunction(&backend);

    var it = try Iterator.validate(function);
    const cap = (try it.next()).?;

    try expectCapability(cap, @intFromEnum(Id.pci_express), standard.window.start);
    try std.testing.expectError(error.MalformedCapability, it.next());
}

test "malformed: iterator detects cycles without losing already yielded nodes" {
    // A two-node loop must yield each node once and reject the revisit.
    var bytes: [function_window_size]u8 = @splat(0);
    seedHead(&bytes, 0x40);
    seedCapability(&bytes, 0x40, @intFromEnum(Id.pci_express), 0x44);
    seedCapability(&bytes, 0x44, @intFromEnum(Id.msi), 0x40);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const function = uncheckedFunction(&backend);

    var it = try Iterator.validate(function);

    try expectCapability((try it.next()).?, @intFromEnum(Id.pci_express), 0x40);
    try expectCapability((try it.next()).?, @intFromEnum(Id.msi), 0x44);
    try std.testing.expectError(error.MalformedCapability, it.next());
}

test "malformed: find reports malformed lists instead of returning absence" {
    // Searching through a cycle for an absent id must surface corruption, not null.
    var bytes: [function_window_size]u8 = @splat(0);
    seedHead(&bytes, 0x40);
    seedCapability(&bytes, 0x40, @intFromEnum(Id.msi), 0x44);
    seedCapability(&bytes, 0x44, @intFromEnum(Id.msi_x), 0x40);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const function = uncheckedFunction(&backend);

    try std.testing.expectError(error.MalformedCapability, list.find(function, Id.pci_express));
}

test "malformed: Cursor.from rejects bases outside aligned capability slots" {
    // Cursor construction validates capability-node placement without performing config I/O.
    var bytes: [function_window_size]u8 = @splat(0);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const function = uncheckedFunction(&backend);

    try std.testing.expectError(error.MalformedCapability, Cursor.from(function, standard.window.start - 1));
    try std.testing.expectError(error.MalformedCapability, Cursor.from(function, standard.window.start + 1));
}

test "unit: Cursor reads and writes relative to its capability base" {
    // Seed payload bytes and verify each access width uses base-relative little-endian offsets.
    var bytes: [function_window_size]u8 = @splat(0);
    bytes[0x40] = 0x12;
    store16(&bytes, 0x42, 0xBEEF);
    store32(&bytes, 0x44, 0xCAFE_BABE);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const function = uncheckedFunction(&backend);
    const cursor = try Cursor.from(function, 0x40);

    try std.testing.expectEqual(@as(u8, 0x12), try cursor.read8(0x00));
    try std.testing.expectEqual(@as(u16, 0xBEEF), try cursor.read16(0x02));
    try std.testing.expectEqual(@as(u32, 0xCAFE_BABE), try cursor.read32(0x04));

    try cursor.write8(0x08, 0x5A);
    try cursor.write16(0x0A, 0x1234);
    try cursor.write32(0x0C, 0xDEAD_BEEF);

    try std.testing.expectEqual(@as(u8, 0x5A), bytes[0x48]);
    try std.testing.expectEqual(@as(u16, 0x1234), load16(&bytes, 0x4A));
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), load32(&bytes, 0x4C));
}

test "malformed: Cursor maps containment and alignment failures to MalformedCapability" {
    // Requests that escape the conventional 256-byte window or break width alignment never reach storage.
    var bytes: [function_window_size]u8 = @splat(0xA5);
    const before = bytes;
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const function = uncheckedFunction(&backend);
    const cursor = try Cursor.from(function, 0xFC);

    try std.testing.expectError(error.MalformedCapability, cursor.read8(0x04));
    try std.testing.expectError(error.MalformedCapability, cursor.write8(0x04, 0));
    try std.testing.expectError(error.MalformedCapability, cursor.read16(0x01));
    try std.testing.expectError(error.MalformedCapability, cursor.write16(0x01, 0));
    try std.testing.expectError(error.MalformedCapability, cursor.read32(0x01));
    try std.testing.expectError(error.MalformedCapability, cursor.write32(0x01, 0));
    try std.testing.expectEqualSlices(u8, &before, &bytes);
}

test "malformed: Cursor propagates backend errors after its own validation passes" {
    // A dword access at an aligned, contained offset must expose the backend width failure unchanged.
    var backend = NoDwordConfig{};
    const function = Function.unchecked(backend.configSpace(), backend.sbdf);
    const cursor = try Cursor.from(function, standard.window.start);

    try std.testing.expectError(error.UnsupportedAccessWidth, cursor.read32(0x00));
    try std.testing.expectError(error.UnsupportedAccessWidth, cursor.write32(0x00, 0));

    try cursor.write16(0x02, 0x55AA);
    try std.testing.expectEqual(@as(u16, 0x55AA), try cursor.read16(0x02));
}

const NoDwordConfig = struct {
    bytes: [function_window_size]u8 = @splat(0),
    sbdf: Sbdf = test_sbdf,

    fn configSpace(self: *NoDwordConfig) ConfigSpace {
        return ConfigSpace.init(@ptrCast(self), &vtable);
    }

    const vtable: ConfigSpace.VTable = .{
        .read8 = read8,
        .read16 = read16,
        .read32 = read32Unsupported,
        .write8 = write8,
        .write16 = write16,
        .write32 = write32Unsupported,
    };

    fn read8(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigSpace.Error!u8 {
        _ = sbdf;
        const self: *NoDwordConfig = @ptrCast(@alignCast(context));
        return self.bytes[byte_offset];
    }

    fn read16(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigSpace.Error!u16 {
        _ = sbdf;
        const self: *NoDwordConfig = @ptrCast(@alignCast(context));
        return load16(&self.bytes, byte_offset);
    }

    fn read32Unsupported(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigSpace.Error!u32 {
        _ = context;
        _ = sbdf;
        _ = byte_offset;
        return error.UnsupportedAccessWidth;
    }

    fn write8(context: *anyopaque, sbdf: Sbdf, byte_offset: usize, value: u8) ConfigSpace.Error!void {
        _ = sbdf;
        const self: *NoDwordConfig = @ptrCast(@alignCast(context));
        self.bytes[byte_offset] = value;
    }

    fn write16(context: *anyopaque, sbdf: Sbdf, byte_offset: usize, value: u16) ConfigSpace.Error!void {
        _ = sbdf;
        const self: *NoDwordConfig = @ptrCast(@alignCast(context));
        store16(&self.bytes, byte_offset, value);
    }

    fn write32Unsupported(context: *anyopaque, sbdf: Sbdf, byte_offset: usize, value: u32) ConfigSpace.Error!void {
        _ = context;
        _ = sbdf;
        _ = byte_offset;
        _ = value;
        return error.UnsupportedAccessWidth;
    }
};

fn uncheckedFunction(backend: *TestConfigSpace) Function {
    return Function.unchecked(backend.configSpace(), test_sbdf);
}

fn enableCapabilities(bytes: *[function_window_size]u8) void {
    store16(bytes, offset.status, status.capabilities_list);
}

fn seedHead(bytes: *[function_window_size]u8, head: u8) void {
    enableCapabilities(bytes);
    bytes[standard.head_offset] = head;
}

fn seedCapability(bytes: *[function_window_size]u8, base: u8, id: u8, next: u8) void {
    bytes[base] = id;
    bytes[@as(usize, base) + 1] = next;
}

fn expectCapability(cap: Capability, id: u8, cap_offset: u8) !void {
    try std.testing.expectEqual(id, cap.id);
    try std.testing.expectEqual(cap_offset, cap.offset);
}

fn expectMalformedFirstStep(function: Function) !void {
    var it = Iterator.validate(function) catch |err| {
        try std.testing.expectEqual(error.MalformedCapability, err);
        return;
    };

    try std.testing.expectError(error.MalformedCapability, it.next());
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
