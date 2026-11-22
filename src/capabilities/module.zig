pub const extended = @import("extended.zig");
pub const standard = @import("standard.zig");
pub const pcie = @import("pcie.zig");
pub const pm = @import("pm.zig");
pub const ari = @import("ari.zig");
pub const sriov = @import("sriov.zig");
pub const aer = @import("aer.zig");
pub const acs = @import("acs.zig");
pub const dpc = @import("dpc.zig");
pub const dsn = @import("dsn.zig");

test {
    _ = standard.unit;
    _ = extended.unit;
    _ = pcie.unit;
    _ = pm.unit;
    _ = ari.unit;
    _ = sriov.unit;
    _ = aer.unit;
    _ = acs.unit;
    _ = dpc.unit;
    _ = dsn.unit;
}
