const extended = @import("extended.zig");

pub const id: extended.Id = .dsn;

pub const offsets = struct {
    pub const serial_lo: u8 = 0x04;
    pub const serial_hi: u8 = 0x08;
};
