const Offset = @import("pci").core.Offset;

comptime {
    _ = Offset(u32).from(2);
}
