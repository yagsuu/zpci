//! Interrupt programming transactions.

const std = @import("std");

pub const Error = error{
    ProgrammingReadbackMismatch,
    ProgrammingWriteFailed,
    ProgrammingPartial,
};

pub const Options = struct {
    capacity: usize,
    word16: bool = false,
    word32: bool = false,
};

/// Enabled widths require target offset types `Offset16` or `Offset32` and matching `readN` and `writeN` methods.
/// Restores recorded writes in reverse order; a restore failure leaves partial state.
pub fn Transaction(comptime Target: type, comptime opts: Options) type {
    comptime {
        std.debug.assert(opts.capacity > 0);
        std.debug.assert(opts.word16 or opts.word32);
    }

    return struct {
        target: Target,
        entries: [opts.capacity]Entry = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn from(target: Target) Self {
            return .{ .target = target };
        }

        pub fn read(self: *Self, comptime T: type, offset: Offset(T)) Error!T {
            return self.readTarget(T, offset) catch error.ProgrammingWriteFailed;
        }

        pub fn writeReadback(
            self: *Self,
            comptime T: type,
            offset: Offset(T),
            value: T,
            saved: T,
        ) Error!void {
            self.writeTarget(T, offset, value) catch return self.fail(error.ProgrammingWriteFailed);

            std.debug.assert(self.len < self.entries.len);
            self.entries[self.len] = switch (T) {
                u16 => .{ .word16 = .{ .offset = offset, .value = saved } },
                u32 => .{ .word32 = .{ .offset = offset, .value = saved } },
                else => unreachable,
            };
            self.len += 1;

            const readback = self.readTarget(T, offset) catch return self.fail(error.ProgrammingWriteFailed);
            if (readback != value) {
                return self.fail(error.ProgrammingReadbackMismatch);
            }
        }

        fn Offset(comptime T: type) type {
            return switch (T) {
                u16 => if (opts.word16) Offset16 else @compileError("Transaction does not support 16-bit accesses"),
                u32 => if (opts.word32) Offset32 else @compileError("Transaction does not support 32-bit accesses"),
                else => @compileError("Transaction supports only u16 and u32"),
            };
        }

        fn readTarget(self: *Self, comptime T: type, offset: Offset(T)) !T {
            return switch (T) {
                u16 => self.target.read16(offset),
                u32 => self.target.read32(offset),
                else => unreachable,
            };
        }

        fn writeTarget(self: *Self, comptime T: type, offset: Offset(T), value: T) !void {
            return switch (T) {
                u16 => self.target.write16(offset, value),
                u32 => self.target.write32(offset, value),
                else => unreachable,
            };
        }

        fn restore(self: *Self, comptime T: type, offset: Offset(T), value: T) Error!void {
            self.writeTarget(T, offset, value) catch return error.ProgrammingPartial;

            const readback = self.readTarget(T, offset) catch return error.ProgrammingPartial;
            if (readback != value) {
                return error.ProgrammingPartial;
            }
        }

        fn fail(self: *Self, err: Error) Error {
            self.rollback() catch return error.ProgrammingPartial;
            return err;
        }

        fn rollback(self: *Self) Error!void {
            while (self.len > 0) {
                self.len -= 1;
                try self.restoreEntry(self.entries[self.len]);
            }
        }

        fn restoreEntry(self: *Self, record: Entry) Error!void {
            if (opts.word16 and opts.word32) {
                switch (record) {
                    .word16 => |entry| try self.restore(u16, entry.offset, entry.value),
                    .word32 => |entry| try self.restore(u32, entry.offset, entry.value),
                }
            } else if (opts.word16) {
                switch (record) {
                    .word16 => |entry| try self.restore(u16, entry.offset, entry.value),
                }
            } else {
                switch (record) {
                    .word32 => |entry| try self.restore(u32, entry.offset, entry.value),
                }
            }
        }

        const Offset16 = if (opts.word16) Target.Offset16 else void;
        const Offset32 = if (opts.word32) Target.Offset32 else void;

        const Entry = if (opts.word16 and opts.word32)
            union(enum) {
                word16: struct {
                    offset: Offset16,
                    value: u16,
                },
                word32: struct {
                    offset: Offset32,
                    value: u32,
                },
            }
        else if (opts.word16)
            union(enum) {
                word16: struct {
                    offset: Offset16,
                    value: u16,
                },
            }
        else
            union(enum) {
                word32: struct {
                    offset: Offset32,
                    value: u32,
                },
            };
    };
}
