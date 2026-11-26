pub const extended = @import("extended.zig");
pub const standard = @import("standard.zig");
pub const pcie = @import("pcie.zig");
pub const pm = @import("pm.zig");
pub const msi = @import("msi.zig");
pub const msix = @import("msix.zig");
pub const ari = @import("ari.zig");
pub const sriov = @import("sriov.zig");
pub const aer = @import("aer.zig");
pub const acs = @import("acs.zig");
pub const dpc = @import("dpc.zig");
pub const dsn = @import("dsn.zig");
pub const ats = @import("ats.zig");
pub const pasid = @import("pasid.zig");
pub const pri = @import("pri.zig");

test {
    _ = standard.unit;
    _ = extended.unit;
    _ = pcie.unit;
    _ = pm.unit;
    _ = msi.unit;
    _ = msix.unit;
    _ = ari.unit;
    _ = sriov.unit;
    _ = aer.unit;
    _ = acs.unit;
    _ = dpc.unit;
    _ = dsn.unit;
    _ = ats.unit;
    _ = pasid.unit;
    _ = pri.unit;
}
