//! Interrupt namespace. Spec: docs/specs/interrupts/msi.md and docs/specs/interrupts/msix.md.

pub const msi = @import("interrupts/msi.zig");
pub const msix = @import("interrupts/msix.zig");
