//! PCI resource namespace. Spec: docs/specs/resources/*.md.

const model = @import("resources/model.zig");

pub const assignment = @import("resources/assignment.zig");
pub const bridge = @import("resources/bridge.zig");
pub const bus = @import("resources/bus.zig");
pub const programming = @import("resources/programming.zig");

pub const Aperture = model.Aperture;
pub const Assignment = model.Assignment;
pub const EligibleSet = model.EligibleSet;
pub const Kind = model.Kind;
pub const Requirement = model.Requirement;
pub const RootWindows = model.RootWindows;
pub const Source = model.Source;

pub const bridge_io_alignment = model.bridge_io_alignment;
pub const bridge_memory_alignment = model.bridge_memory_alignment;

pub const eligiblePools = model.eligiblePools;
