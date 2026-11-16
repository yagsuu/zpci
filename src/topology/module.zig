const enumeration = @import("enumerate.zig");
const tree = @import("tree.zig");
const configuration = @import("configure.zig");

pub const max_depth: u8 = 31;

pub const Tree = tree.Tree;
pub const Node = tree.Node;
pub const NodeId = tree.NodeId;
pub const EnumerateArgs = enumeration.Args;
pub const ConfigureArgs = configuration.Args;
pub const Root = configuration.Root;
pub const AriPolicy = configuration.AriPolicy;
pub const VfCapacity = configuration.VfCapacity;
pub const VfReservation = tree.VfReservation;

pub const configure = configuration.configure;
pub const enumerate = enumeration.enumerate;

test {
    _ = tree.unit;
    _ = enumeration.unit;
    _ = configuration.unit;
}
