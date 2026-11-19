pub const extended = @import("extended.zig");
pub const standard = @import("standard.zig");
pub const pcie = @import("pcie.zig");
pub const pm = @import("pm.zig");
pub const ari = @import("ari.zig");
pub const sriov = @import("sriov.zig");
pub const aer = @import("aer.zig");

test {
    _ = standard.unit;
    _ = extended.unit;
    _ = pcie.unit;
    _ = pm.unit;
    _ = ari.unit;
    _ = sriov.unit;
    _ = aer.unit;
}
