const accessor = @import("accessor.zig");
const ecam = @import("ecam.zig");
const function = @import("function.zig");
const pio = @import("pio.zig");
const segment = @import("segment.zig");

pub const ConfigSpace = accessor.ConfigSpace;

pub const Function = function.Function;

pub const Ecam = ecam.Ecam;
pub const Segment = segment.Segment;

pub const Pio = pio.Pio;

test {
    _ = accessor.unit;
    _ = ecam.unit;
    _ = function.unit;
    _ = pio.unit;
    _ = segment.unit;
}
