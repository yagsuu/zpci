pub const msi = @import("msi.zig");
pub const msix = @import("msix.zig");

test {
    _ = msi.unit;
    _ = msix.unit;
}
