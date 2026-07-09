//! Header namespace. Spec: docs/specs/header/*.md.

pub const common = @import("header/common.zig");
pub const type0 = @import("header/type0.zig");
pub const type1 = @import("header/type1.zig");

pub const Bist = common.Bist;
pub const BridgeControl = type1.BridgeControl;
pub const Command = common.Command;
pub const CommonHeader = common.CommonHeader;
pub const ExpansionRom = type0.ExpansionRom;
pub const Status = common.Status;
pub const Subsystem = type0.Subsystem;
pub const Type0Header = type0.Type0Header;
pub const Type1Header = type1.Type1Header;
