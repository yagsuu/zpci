const Bdf = @import("pci").core.Bdf;

comptime {
    _ = Bdf.from(0, 32, 0);
}
