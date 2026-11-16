const std = @import("std");

const pci = @import("pci");
const support = @import("support.zig");

const Function = pci.config.Function;
const Sbdf = pci.core.Sbdf;
const TestConfigSpace = pci.testing.config.TestConfigSpace;

const testing = std.testing;

const pcie_window_size = support.pcie_window_size;

const store16 = support.store16;

test "command field masks preserve unrelated live control bits" {
    const Command = pci.core.header.Command;
    var bytes: [pcie_window_size]u8 = @splat(0);
    const address = Sbdf.from(.from(0), 0, 1, 0);
    var backend = TestConfigSpace.fromSingle(address, &bytes);
    const function = Function.from(backend.config(), address);
    store16(&bytes, 0x04, 0x0547);

    const selected = Command.mask(.{ .mem_enable, .bus_master });
    const desired = Command.encode(.{ .mem_enable = false, .bus_master = true });
    const observed = Command.raw(try function.command());

    try function.setCommand(Command.from((observed & ~selected) | (desired & selected)));

    try testing.expectEqual(@as(u16, 0x0545), try function.config.read(address, Function.offsets.command));
}
