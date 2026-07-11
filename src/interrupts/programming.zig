//! Interrupt programming transactions. Specs: docs/specs/interrupts/msi.md and docs/specs/interrupts/msix.md.

const std = @import("std");

pub const Error = error{
    ProgrammingReadbackMismatch,
    ProgrammingWriteFailed,
    ProgrammingPartial,
};

pub const Options = struct {
    max_entries: usize,
    word16: bool = false,
    word32: bool = false,
};

/// Builds a bounded write/read/restore transaction over a target-defined access API.
///
/// Requirements: enabled widths require matching `readN` and `writeN` target methods.
/// Capacity: `opts.max_entries` is the maximum number of writes that can be restored.
/// Effects: failed writes/readbacks restore prior writes in reverse order.
pub fn Transaction(comptime Target: type, comptime opts: Options) type {
    comptime {
        std.debug.assert(opts.max_entries > 0);
        std.debug.assert(opts.word16 or opts.word32);
    }

    return struct {
        target: Target,
        entries: [opts.max_entries]Entry = undefined,
        len: usize = 0,

        const Self = @This();

        const Entry = if (opts.word16 and opts.word32)
            union(enum) {
                word16: struct {
                    offset: usize,
                    value: u16,
                },
                word32: struct {
                    offset: usize,
                    value: u32,
                },
            }
        else if (opts.word16)
            union(enum) {
                word16: struct {
                    offset: usize,
                    value: u16,
                },
            }
        else
            union(enum) {
                word32: struct {
                    offset: usize,
                    value: u32,
                },
            };

        pub fn init(target: Target) Self {
            return .{ .target = target };
        }

        pub fn read16(self: *Self, offset: usize) Error!u16 {
            comptime if (!opts.word16) @compileError("Transaction does not support 16-bit accesses");
            return self.target.read16(offset) catch error.ProgrammingWriteFailed;
        }

        pub fn read32(self: *Self, offset: usize) Error!u32 {
            comptime if (!opts.word32) @compileError("Transaction does not support 32-bit accesses");
            return self.target.read32(offset) catch error.ProgrammingWriteFailed;
        }

        pub fn writeReadback16(self: *Self, offset: usize, value: u16, saved: u16) Error!void {
            comptime if (!opts.word16) @compileError("Transaction does not support 16-bit accesses");
            self.target.write16(offset, value) catch return self.fail(error.ProgrammingWriteFailed);
            self.record16(offset, saved);

            const readback = self.target.read16(offset) catch return self.fail(error.ProgrammingWriteFailed);
            if (readback != value) return self.fail(error.ProgrammingReadbackMismatch);
        }

        pub fn writeReadback32(self: *Self, offset: usize, value: u32, saved: u32) Error!void {
            comptime if (!opts.word32) @compileError("Transaction does not support 32-bit accesses");
            self.target.write32(offset, value) catch return self.fail(error.ProgrammingWriteFailed);
            self.record32(offset, saved);

            const readback = self.target.read32(offset) catch return self.fail(error.ProgrammingWriteFailed);
            if (readback != value) return self.fail(error.ProgrammingReadbackMismatch);
        }

        fn record16(self: *Self, offset: usize, value: u16) void {
            comptime if (!opts.word16) @compileError("Transaction does not support 16-bit accesses");
            std.debug.assert(self.len < self.entries.len);
            self.entries[self.len] = .{ .word16 = .{ .offset = offset, .value = value } };
            self.len += 1;
        }

        fn record32(self: *Self, offset: usize, value: u32) void {
            comptime if (!opts.word32) @compileError("Transaction does not support 32-bit accesses");
            std.debug.assert(self.len < self.entries.len);
            self.entries[self.len] = .{ .word32 = .{ .offset = offset, .value = value } };
            self.len += 1;
        }

        fn restore16(self: *Self, offset: usize, value: u16) Error!void {
            comptime if (!opts.word16) @compileError("Transaction does not support 16-bit accesses");
            self.target.write16(offset, value) catch return error.ProgrammingPartial;
            const readback = self.target.read16(offset) catch return error.ProgrammingPartial;
            if (readback != value) return error.ProgrammingPartial;
        }

        fn restore32(self: *Self, offset: usize, value: u32) Error!void {
            comptime if (!opts.word32) @compileError("Transaction does not support 32-bit accesses");
            self.target.write32(offset, value) catch return error.ProgrammingPartial;
            const readback = self.target.read32(offset) catch return error.ProgrammingPartial;
            if (readback != value) return error.ProgrammingPartial;
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
                    .word16 => |entry| try self.restore16(entry.offset, entry.value),
                    .word32 => |entry| try self.restore32(entry.offset, entry.value),
                }
            } else if (opts.word16) {
                switch (record) {
                    .word16 => |entry| try self.restore16(entry.offset, entry.value),
                }
            } else {
                switch (record) {
                    .word32 => |entry| try self.restore32(entry.offset, entry.value),
                }
            }
        }
    };
}
