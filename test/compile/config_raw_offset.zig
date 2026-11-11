const pci = @import("pci");

const ConfigSpace = pci.config.ConfigSpace;
const Sbdf = pci.core.Sbdf;

export fn configRawOffset(config: *const ConfigSpace) void {
    _ = config.read(Sbdf.from(.from(0), 0, 0, 0), 0) catch return;
}
