//! Tests for docs/specs/interrupts/pin.md.

const std = @import("std");

const pci = @import("pci");

const Pin = pci.interrupts.Pin;

test "layout: Pin keeps the PCI interrupt-pin byte encoding" {
    // Pins enum storage and raw values so header view decode can cross the wire/semantic boundary directly.
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Pin));
    try std.testing.expectEqual(@as(u8, 0), Pin.none.raw());
    try std.testing.expectEqual(@as(u8, 1), Pin.inta.raw());
    try std.testing.expectEqual(@as(u8, 2), Pin.intb.raw());
    try std.testing.expectEqual(@as(u8, 3), Pin.intc.raw());
    try std.testing.expectEqual(@as(u8, 4), Pin.intd.raw());
}

test "unit: Pin.from decodes every valid interrupt-pin byte" {
    // Decodes the full valid domain, including the no-INTx value and all four legacy pins.
    try std.testing.expectEqual(Pin.none, try Pin.from(0));
    try std.testing.expectEqual(Pin.inta, try Pin.from(1));
    try std.testing.expectEqual(Pin.intb, try Pin.from(2));
    try std.testing.expectEqual(Pin.intc, try Pin.from(3));
    try std.testing.expectEqual(Pin.intd, try Pin.from(4));
}

test "malformed: Pin.from rejects reserved interrupt-pin bytes" {
    // Checks the first invalid byte and the byte-sized upper bound.
    try std.testing.expectError(error.MalformedField, Pin.from(5));
    try std.testing.expectError(error.MalformedField, Pin.from(0xFF));
}

test "unit: Pin.from round-trips encoded values" {
    // Round-trips each semantic value through its raw byte to guard the inverse contract.
    inline for (.{ Pin.none, Pin.inta, Pin.intb, Pin.intc, Pin.intd }) |pin| {
        try std.testing.expectEqual(pin, try Pin.from(pin.raw()));
    }
}
