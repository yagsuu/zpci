const bdf = @import("bdf.zig");
const ids = @import("ids.zig");
const offset = @import("offset.zig");

pub const bar = @import("bar.zig");
pub const bridge = @import("bridge.zig");
pub const bus = bdf.bus;
pub const capabilities = @import("capabilities/module.zig");
pub const config = @import("config.zig");
pub const device = bdf.device;
pub const function = bdf.function;
pub const header = @import("header.zig");

pub const BaseClass = ids.BaseClass;
pub const Bdf = bdf.Bdf;
pub const ClassCode = ids.ClassCode;
pub const DeviceId = ids.DeviceId;
pub const Offset = offset.Offset;
pub const ProgIf = ids.ProgIf;
pub const RelativeOffset = offset.RelativeOffset;
pub const RevisionId = ids.RevisionId;
pub const Sbdf = bdf.Sbdf;
pub const SegmentId = ids.SegmentId;
pub const Subclass = ids.Subclass;
pub const VendorId = ids.VendorId;

test {
    _ = bdf.unit;
    _ = ids.unit;
    _ = header.type0.unit;
    _ = header.type1.unit;
    _ = capabilities.msi.unit;
    _ = capabilities.extended.unit;
    _ = offset.unit;
    _ = header.unit;
    _ = bridge.unit;
    _ = bar.unit;
    _ = capabilities.msix.unit;
    _ = capabilities.standard.unit;
    _ = capabilities.pcie.unit;
    _ = capabilities.pcie.device.unit;
    _ = capabilities.pcie.link.unit;
    _ = capabilities.pcie.slot.unit;
    _ = capabilities.pcie.root.unit;
}
