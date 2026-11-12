pub const extended = @import("extended.zig");
pub const standard = @import("standard.zig");
pub const pcie = @import("pcie.zig");
pub const pm = @import("pm.zig");

test {
    _ = standard.unit;
    _ = extended.unit;
    _ = pcie.unit;
    _ = pm.unit;
}
