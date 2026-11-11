pub const type0 = @import("type0.zig");
pub const type1 = @import("type1.zig");

pub const Type0 = type0.Type0;
pub const Type1 = type1.Type1;

pub const windows = @import("windows.zig");

test {
    _ = type0.unit;
    _ = windows.unit;
    _ = type1.unit;
}
