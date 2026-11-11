const pci = @import("pci");

const Offset = pci.core.Offset;
const Registers = pci.capabilities.standard.Registers;

export fn absoluteOffset(registers: *const Registers) void {
    _ = registers.read(Offset(u32).from(0)) catch return;
}
