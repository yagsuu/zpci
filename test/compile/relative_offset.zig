const pci = @import("pci");

const RelativeOffset = pci.core.RelativeOffset;
const Function = pci.config.Function;

export fn relativeOffset(function: *const Function) void {
    _ = function.read(RelativeOffset(u32).from(0)) catch return;
}
