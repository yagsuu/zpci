//! PCI interrupt-pin byte decode. Spec: docs/specs/interrupts/pin.md.

const std = @import("std");

pub const Pin = enum(u8) {
    none = 0,
    inta = 1,
    intb = 2,
    intc = 3,
    intd = 4,

    pub const Error = error{MalformedField};

    pub fn from(encoded: u8) Error!Pin {
        return switch (encoded) {
            0 => .none,
            1 => .inta,
            2 => .intb,
            3 => .intc,
            4 => .intd,
            else => error.MalformedField,
        };
    }

    pub fn raw(self: Pin) u8 {
        return @intFromEnum(self);
    }

    comptime {
        std.debug.assert(@sizeOf(Pin) == 1);
        std.debug.assert(@intFromEnum(Pin.none) == 0);
        std.debug.assert(@intFromEnum(Pin.inta) == 1);
        std.debug.assert(@intFromEnum(Pin.intb) == 2);
        std.debug.assert(@intFromEnum(Pin.intc) == 3);
        std.debug.assert(@intFromEnum(Pin.intd) == 4);
    }
};
