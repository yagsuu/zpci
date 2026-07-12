//! Interrupt namespace. Spec: docs/specs/interrupts/*.md.

const pin = @import("interrupts/pin.zig");

pub const msi = @import("interrupts/msi.zig");
pub const msix = @import("interrupts/msix.zig");

pub const Pin = pin.Pin;
