pub const config = @import("config.zig");
pub const memory = @import("memory.zig");

test {
    _ = config.unit;
    _ = memory.unit;
}
