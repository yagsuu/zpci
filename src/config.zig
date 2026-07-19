//! Config-space namespace. Spec: docs/specs/config/*.md.

const accessor = @import("config/accessor.zig");
const ecam = @import("config/ecam.zig");
const pio = @import("config/pio.zig");
const space = @import("config/space.zig");

pub const ConfigSpace = accessor.ConfigSpace;

pub const Function = space.Function;
pub const HeaderKind = space.HeaderKind;

pub const Ecam = ecam.Ecam;
pub const Segment = ecam.Segment;

pub const Pio = pio.Pio;

pub const pci_window_size = space.pci_window_size;
pub const pcie_window_size = space.pcie_window_size;
