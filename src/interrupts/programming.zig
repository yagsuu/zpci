//! Interrupt programming transactions.

const std = @import("std");

const core = @import("core");
const capabilities = @import("capabilities");
const memory = @import("memory");

const RelativeOffset = core.RelativeOffset;
const Registers = capabilities.standard.Registers;
const BarMemory = memory.BarMemory;

pub const Error = error{
    ProgrammingReadbackMismatch,
    ProgrammingWriteFailed,
    ProgrammingPartial,
};

pub fn ConfigTransaction(comptime capacity: usize) type {
    comptime {
        std.debug.assert(capacity > 0);
    }

    return struct {
        registers: Registers,
        entries: [capacity]Entry = undefined,
        len: usize = 0,

        const Self = @This();

        const Entry = union(enum) {
            word16: struct { offset: RelativeOffset(u16), value: u16 },
            word32: struct { offset: RelativeOffset(u32), value: u32 },
        };

        pub fn from(registers: Registers) Self {
            return .{ .registers = registers };
        }

        pub fn read(self: *Self, offset: anytype) Error!@TypeOf(offset).Int {
            return switch (@TypeOf(offset).Int) {
                u16, u32 => self.registers.read(offset) catch error.ProgrammingWriteFailed,
                else => @compileError("Configuration transactions support only u16 and u32"),
            };
        }

        pub fn write(self: *Self, offset: anytype, value: @TypeOf(offset).Int, saved: @TypeOf(offset).Int) Error!void {
            std.debug.assert(self.len < self.entries.len);

            self.registers.write(offset, value) catch return self.fail(error.ProgrammingWriteFailed);

            self.entries[self.len] = switch (@TypeOf(offset).Int) {
                u16 => .{ .word16 = .{ .offset = offset, .value = saved } },
                u32 => .{ .word32 = .{ .offset = offset, .value = saved } },
                else => @compileError("Configuration transactions support only u16 and u32"),
            };
            self.len += 1;

            const readback = self.registers.read(offset) catch return self.fail(error.ProgrammingWriteFailed);
            if (readback != value) {
                return self.fail(error.ProgrammingReadbackMismatch);
            }
        }

        fn fail(self: *Self, err: Error) Error {
            self.rollback() catch return error.ProgrammingPartial;
            return err;
        }

        fn rollback(self: *Self) Error!void {
            while (self.len > 0) {
                self.len -= 1;

                switch (self.entries[self.len]) {
                    .word16 => |entry| try self.restore(entry.offset, entry.value),
                    .word32 => |entry| try self.restore(entry.offset, entry.value),
                }
            }
        }

        fn restore(self: *Self, offset: anytype, value: @TypeOf(offset).Int) Error!void {
            self.registers.write(offset, value) catch return error.ProgrammingPartial;

            const readback = self.registers.read(offset) catch return error.ProgrammingPartial;
            if (readback != value) {
                return error.ProgrammingPartial;
            }
        }
    };
}

pub fn BarTransaction(comptime capacity: usize) type {
    comptime {
        std.debug.assert(capacity > 0);
    }

    return struct {
        memory: BarMemory,
        entries: [capacity]Entry = undefined,
        len: usize = 0,

        const Self = @This();

        const Entry = struct {
            offset: usize,
            value: u32,
        };

        pub fn from(bar_memory: BarMemory) Self {
            return .{ .memory = bar_memory };
        }

        pub fn read(self: *Self, offset: usize) Error!u32 {
            return self.memory.read32(offset) catch error.ProgrammingWriteFailed;
        }

        pub fn write(self: *Self, offset: usize, value: u32, saved: u32) Error!void {
            std.debug.assert(self.len < self.entries.len);

            self.memory.write32(offset, value) catch return self.fail(error.ProgrammingWriteFailed);

            self.entries[self.len] = .{ .offset = offset, .value = saved };
            self.len += 1;

            const readback = self.memory.read32(offset) catch return self.fail(error.ProgrammingWriteFailed);
            if (readback != value) {
                return self.fail(error.ProgrammingReadbackMismatch);
            }
        }

        fn fail(self: *Self, err: Error) Error {
            self.rollback() catch return error.ProgrammingPartial;
            return err;
        }

        fn rollback(self: *Self) Error!void {
            while (self.len > 0) {
                self.len -= 1;
                const entry = self.entries[self.len];
                self.memory.write32(entry.offset, entry.value) catch return error.ProgrammingPartial;

                const readback = self.memory.read32(entry.offset) catch return error.ProgrammingPartial;
                if (readback != entry.value) {
                    return error.ProgrammingPartial;
                }
            }
        }
    };
}
