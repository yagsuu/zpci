const bar = @import("bar.zig");

pub const BarMemory = bar.BarMemory;

test {
    _ = bar.unit;
}
