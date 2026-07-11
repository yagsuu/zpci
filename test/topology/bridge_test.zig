//! Tests for docs/specs/topology/bridge.md.

const std = @import("std");

const zpci = @import("zpci");

const bridge = zpci.topology.bridge;
const config = zpci.config;
const core = zpci.core;
const testing_config = zpci.testing.config;
const tree = zpci.topology.tree;

const BusRange = bridge.BusRange;
const Function = config.Function;
const HeaderKind = config.HeaderKind;
const Node = tree.Node;
const NodeIndex = tree.NodeIndex;
const PrefetchableWindow = bridge.PrefetchableWindow;
const Sbdf = core.Sbdf;
const TestConfigSpace = testing_config.TestConfigSpace;
const Tree = tree.Tree;
const Window = bridge.Window;

const function_window_size: usize = 0x1000;
const test_sbdf = Sbdf.of(0, 0, 0, 0);

test "unit: bridge semantic records expose expected field behavior" {
    // Construct each public record so added or missing semantic fields become compile-visible.
    const range = BusRange{ .primary = 0, .secondary = 1, .subordinate = 2 };
    const window = Window{ .base = 0x1000, .limit = 0x1FFF, .enabled = true };
    const pref = PrefetchableWindow{ .base = 0x2000, .limit = 0x2FFF, .is_64bit = false, .enabled = true };

    try std.testing.expect(range.forwards(1));
    try std.testing.expect(window.contains(0x1000, 1));
    try std.testing.expect(pref.contains(0x2000, 1));
}

test "unit: BusRange reports unprogrammed and forwarded buses" {
    // Exercise reset, closed-interval boundaries, and buses adjacent to the forwarded span.
    const reset = BusRange{ .primary = 0x00, .secondary = 0x00, .subordinate = 0x00 };
    const programmed = BusRange{ .primary = 0x01, .secondary = 0x20, .subordinate = 0x2F };

    try std.testing.expect(reset.isUnprogrammed());
    try std.testing.expect(!reset.forwards(0x00));
    try std.testing.expect(!programmed.isUnprogrammed());
    try std.testing.expect(!programmed.forwards(0x1F));
    try std.testing.expect(programmed.forwards(0x20));
    try std.testing.expect(programmed.forwards(0x2F));
    try std.testing.expect(!programmed.forwards(0x30));
}

test "topology: busRangeOf reads exact type1 bus-number bytes" {
    // Back a type-1 node with config bytes and decode the three bus registers without validation policy.
    var bytes: [function_window_size]u8 = @splat(0);
    bytes[0x18] = 0x11;
    bytes[0x19] = 0x22;
    bytes[0x1A] = 0x33;
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const n = bridgeNode(&backend, null);

    const range = try bridge.busRangeOf(&n);

    try std.testing.expectEqual(@as(u8, 0x11), range.primary);
    try std.testing.expectEqual(@as(u8, 0x22), range.secondary);
    try std.testing.expectEqual(@as(u8, 0x33), range.subordinate);
}

test "topology: windowStateOf preserves disabled IO memory and prefetchable encodings" {
    // Use base-greater-than-limit encodings to ensure disabled windows still expose decoded raw bounds.
    var bytes: [function_window_size]u8 = @splat(0);
    bytes[0x1C] = 0x00;
    bytes[0x1D] = 0x00;
    store16(&bytes, 0x20, 0x2000);
    store16(&bytes, 0x22, 0x1000);
    store16(&bytes, 0x24, 0x3000);
    store16(&bytes, 0x26, 0x2000);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const n = bridgeNode(&backend, null);

    const state = try bridge.windowStateOf(&n);

    try std.testing.expectEqual(@as(u64, 0x0000), state.io.base);
    try std.testing.expectEqual(@as(u64, 0x0FFF), state.io.limit);
    try std.testing.expect(!state.io.enabled);
    try std.testing.expectEqual(@as(u64, 0x2000_0000), state.memory.base);
    try std.testing.expectEqual(@as(u64, 0x100F_FFFF), state.memory.limit);
    try std.testing.expect(!state.memory.enabled);
    try std.testing.expectEqual(@as(u64, 0x3000_0000), state.prefetchable_memory.base);
    try std.testing.expectEqual(@as(u64, 0x200F_FFFF), state.prefetchable_memory.limit);
    try std.testing.expect(!state.prefetchable_memory.is_64bit);
    try std.testing.expect(!state.prefetchable_memory.enabled);
}

test "topology: windowStateOf decodes enabled 32-bit IO memory and prefetchable windows" {
    // Populate every bridge-window register group and verify byte-range alignment and inclusivity.
    var bytes: [function_window_size]u8 = @splat(0);
    bytes[0x1C] = 0x20;
    bytes[0x1D] = 0x30;
    store16(&bytes, 0x30, 0x0001);
    store16(&bytes, 0x32, 0x0001);
    store16(&bytes, 0x20, 0x8010);
    store16(&bytes, 0x22, 0x8020);
    store16(&bytes, 0x24, 0x9000);
    store16(&bytes, 0x26, 0x9010);
    store32(&bytes, 0x28, 0xFFFF_FFFF);
    store32(&bytes, 0x2C, 0xFFFF_FFFF);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const n = bridgeNode(&backend, null);

    const state = try bridge.windowStateOf(&n);

    try std.testing.expectEqual(@as(u64, 0x0001_2000), state.io.base);
    try std.testing.expectEqual(@as(u64, 0x0001_3FFF), state.io.limit);
    try std.testing.expect(state.io.enabled);
    try std.testing.expectEqual(@as(u64, 0x8010_0000), state.memory.base);
    try std.testing.expectEqual(@as(u64, 0x802F_FFFF), state.memory.limit);
    try std.testing.expect(state.memory.enabled);
    try std.testing.expectEqual(@as(u64, 0x9000_0000), state.prefetchable_memory.base);
    try std.testing.expectEqual(@as(u64, 0x901F_FFFF), state.prefetchable_memory.limit);
    try std.testing.expect(!state.prefetchable_memory.is_64bit);
    try std.testing.expect(state.prefetchable_memory.enabled);
}

test "unit: Window contains checks closed bounds zero size disabled and overflow" {
    // Probe both exact edges plus invalid ranges that cannot be represented inside the window.
    const w = Window{ .base = 0x1000, .limit = 0x1FFF, .enabled = true };
    const disabled = Window{ .base = 0x1000, .limit = 0x1FFF, .enabled = false };

    try std.testing.expect(w.contains(0x1000, 1));
    try std.testing.expect(w.contains(0x1FF0, 0x10));
    try std.testing.expect(!w.contains(0x0FFF, 1));
    try std.testing.expect(!w.contains(0x1FF0, 0x11));
    try std.testing.expect(!w.contains(0x1000, 0));
    try std.testing.expect(!w.contains(std.math.maxInt(u64), 2));
    try std.testing.expect(!disabled.contains(0x1000, 1));
}

test "unit: PrefetchableWindow contains checks closed bounds zero size disabled and overflow" {
    // Mirror the generic window boundary contract on the prefetchable-memory semantic record.
    const w = PrefetchableWindow{
        .base = 0x1_0000_0000,
        .limit = 0x1_0000_FFFF,
        .is_64bit = true,
        .enabled = true,
    };
    const disabled = PrefetchableWindow{
        .base = 0x1_0000_0000,
        .limit = 0x1_0000_FFFF,
        .is_64bit = true,
        .enabled = false,
    };

    try std.testing.expect(w.contains(0x1_0000_0000, 1));
    try std.testing.expect(w.contains(0x1_0000_F000, 0x1000));
    try std.testing.expect(!w.contains(0x0_FFFF_FFFF, 1));
    try std.testing.expect(!w.contains(0x1_0000_F000, 0x1001));
    try std.testing.expect(!w.contains(0x1_0000_0000, 0));
    try std.testing.expect(!w.contains(std.math.maxInt(u64), 2));
    try std.testing.expect(!disabled.contains(0x1_0000_0000, 1));
}

test "topology: windowStateOf reconstructs 64-bit prefetchable windows" {
    // Set both low-register 64-bit indicators and verify upper dwords participate in decoded bounds.
    var bytes: [function_window_size]u8 = @splat(0);
    store16(&bytes, 0x24, 0x0011);
    store16(&bytes, 0x26, 0x0021);
    store32(&bytes, 0x28, 0x0000_0004);
    store32(&bytes, 0x2C, 0x0000_0005);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const n = bridgeNode(&backend, null);

    const state = try bridge.windowStateOf(&n);
    const pref = state.prefetchable_memory;

    try std.testing.expectEqual(@as(u64, 0x0000_0004_0010_0000), pref.base);
    try std.testing.expectEqual(@as(u64, 0x0000_0005_002F_FFFF), pref.limit);
    try std.testing.expect(pref.is_64bit);
    try std.testing.expect(pref.enabled);
    try std.testing.expect(pref.contains(0x0000_0004_0010_0000, 1));
    try std.testing.expect(pref.contains(0x0000_0005_0020_0000, 0x0010_0000));
    try std.testing.expect(!pref.contains(0x0000_0005_0020_0000, 0x0010_0001));
}

test "topology: pathTo returns root-first chain through parent links" {
    // Build a borrowed tree view so the helper walks the same parent-link shape used by topology iterators.
    var bytes: [function_window_size]u8 = @splat(0);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const nodes = [_]Node{
        bridgeNode(&backend, null),
        bridgeNode(&backend, 0),
        endpointNode(&backend, 1),
    };
    const roots = [_]NodeIndex{0};
    const t = Tree{ .nodes = &nodes, .roots = &roots };
    var scratch: [3]NodeIndex = undefined;

    const path = try bridge.pathTo(&t, 2, &scratch);

    try std.testing.expectEqualSlices(NodeIndex, &.{ 0, 1, 2 }, path);
    try std.testing.expect(@intFromPtr(path.ptr) == @intFromPtr(&scratch[0]));
}

test "failure: pathTo reports StorageExhausted without touching scratch" {
    // Make the ancestor chain longer than scratch and use sentinels to prove the upfront guard is non-mutating.
    var bytes: [function_window_size]u8 = @splat(0);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    var nodes = [_]Node{
        bridgeNode(&backend, null),
        bridgeNode(&backend, 0),
        endpointNode(&backend, 1),
    };
    const roots = [_]NodeIndex{0};
    const t = Tree{ .nodes = &nodes, .roots = &roots };
    var scratch = [_]NodeIndex{ 0xAAAA, 0xBBBB };

    try std.testing.expectError(error.StorageExhausted, bridge.pathTo(&t, 2, &scratch));
    try std.testing.expectEqualSlices(NodeIndex, &.{ 0xAAAA, 0xBBBB }, &scratch);
}

fn bridgeNode(backend: *TestConfigSpace, parent: ?NodeIndex) Node {
    return node(backend, .type1, parent);
}

fn endpointNode(backend: *TestConfigSpace, parent: ?NodeIndex) Node {
    return node(backend, .type0, parent);
}

fn node(backend: *TestConfigSpace, header_kind: HeaderKind, parent: ?NodeIndex) Node {
    return .{
        .sbdf = test_sbdf,
        .function = Function.unchecked(backend.configSpace(), test_sbdf),
        .header_kind = header_kind,
        .parent = parent,
    };
}

fn store16(bytes: *[function_window_size]u8, offset: usize, value: u16) void {
    std.debug.assert(offset + 2 <= bytes.len);
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}

fn store32(bytes: *[function_window_size]u8, offset: usize, value: u32) void {
    std.debug.assert(offset + 4 <= bytes.len);
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
}
