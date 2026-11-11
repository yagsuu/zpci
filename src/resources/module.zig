const model = @import("model.zig");

pub const assignment = @import("assignment.zig");
pub const bridge = @import("bridge.zig");
pub const bus = @import("bus.zig");
pub const programming = @import("programming.zig");

pub const Aperture = model.Aperture;
pub const Assignment = model.Assignment;
pub const EligibleSet = model.EligibleSet;
pub const Type = model.Type;
pub const Requirement = model.Requirement;
pub const Apertures = model.Apertures;
pub const Source = model.Source;

pub const assign = assignment.assign;
pub const commit = programming.commit;

test {
    _ = model.unit;
    _ = assignment.unit;
    _ = bridge.unit;
    _ = bus.unit;
    _ = programming.unit;
}
