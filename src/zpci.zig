//! Public zpci package facade. Spec: docs/specs/index.md §Facade structure.

pub const bar = @import("bar.zig");
pub const capabilities = @import("capabilities.zig");
pub const config = @import("config.zig");
pub const core = @import("core.zig");
pub const header = @import("header.zig");
pub const memory = @import("memory.zig");
pub const testing = @import("testing.zig");
