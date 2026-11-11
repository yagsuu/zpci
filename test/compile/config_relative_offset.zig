const pci = @import("pci");

const ConfigSpace = pci.config.ConfigSpace;
const Sbdf = pci.core.Sbdf;
const RelativeOffset = pci.core.RelativeOffset;

export fn configRelativeOffset(config: *const ConfigSpace) void {
    _ = config.read(Sbdf.from(.from(0), 0, 0, 0), RelativeOffset(u32).from(0)) catch return;
}
