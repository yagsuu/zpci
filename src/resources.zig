//! PCI resource namespace. Spec: docs/specs/resources/*.md.

pub const model = @import("resources/model.zig");
pub const assignment = @import("resources/assignment.zig");
pub const bridge = @import("resources/bridge.zig");
pub const bus = @import("resources/bus.zig");
pub const programming = @import("resources/programming.zig");
