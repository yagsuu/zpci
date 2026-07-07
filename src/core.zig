//! Core PCI primitives. Spec: docs/specs/core/{errors,ids,bdf}.md.

const bdf = @import("core/bdf.zig");
const errors = @import("core/errors.zig");
const ids = @import("core/ids.zig");

pub const BaseClass = ids.BaseClass;
pub const Bdf = bdf.Bdf;
pub const ClassCode = ids.ClassCode;
pub const DeviceId = ids.DeviceId;
pub const Error = errors.Error;
pub const ProgIf = ids.ProgIf;
pub const RevisionId = ids.RevisionId;
pub const Sbdf = bdf.Sbdf;
pub const SegmentId = ids.SegmentId;
pub const Subclass = ids.Subclass;
pub const VendorId = ids.VendorId;
