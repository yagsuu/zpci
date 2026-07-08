//! Config-space namespace. Spec: docs/specs/config/{accessor,space}.md.

const accessor = @import("config/accessor.zig");
const space = @import("config/space.zig");

pub const ConfigSpace = accessor.ConfigSpace;
pub const Function = space.Function;
pub const HeaderKind = space.HeaderKind;
