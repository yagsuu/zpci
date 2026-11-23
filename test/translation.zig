const std = @import("std");
const pci = @import("pci");

const ats = pci.core.capabilities.ats;
const pasid = pci.core.capabilities.pasid;
const pri = pci.core.capabilities.pri;

const ConfigSpace = pci.config.ConfigSpace;
const ConfigError = ConfigSpace.Error;
const Function = pci.config.Function;
const Sbdf = pci.core.Sbdf;
const AtsCapability = pci.capabilities.ats.Capability;
const PasidCapability = pci.capabilities.pasid.Capability;
const PriCapability = pci.capabilities.pri.Capability;
const TestConfigSpace = pci.testing.config.TestConfigSpace;

const testing = std.testing;

const pf = Sbdf.from(.from(0), 2, 0, 0);
const vf = Sbdf.from(.from(0), 2, 0, 1);
const vf2 = Sbdf.from(.from(0), 2, 0, 2);

const ats_base: usize = 0x100;
const pasid_base: usize = 0x120;
const pri_base: usize = 0x140;

const ConfigBackend = struct {
    bytes: [pci.core.config.extended_size]u8 = @splat(0),
    vf_bytes: [2][pci.core.config.extended_size]u8 = @splat(@splat(0)),
    pending: [3]u32 = @splat(0),
    fail_write_at: ?usize = null,

    const vtable: ConfigSpace.VTable = .{
        .read8 = read8,
        .read16 = read16,
        .read32 = read32,
        .write8 = write8,
        .write16 = write16,
        .write32 = write32,
    };

    fn from() ConfigBackend {
        var self: ConfigBackend = .{};
        store32(&self.bytes, ats_base, 0x1201_000F);
        store32(&self.bytes, pasid_base, 0x1401_001B);
        store32(&self.bytes, pri_base, 0x0001_0013);
        store16(&self.bytes, ats_base + ats.offsets.capabilities, 0x1FF);
        store16(&self.bytes, pasid_base + pasid.offsets.capabilities, 0x140E);
        store16(&self.bytes, pri_base + pri.offsets.status, 0x8100);
        store32(&self.bytes, pri_base + pri.offsets.request_capacity, 64);

        for (&self.vf_bytes) |*bytes| {
            store32(bytes, ats_base, 0x0001_000F);
        }

        return self;
    }

    fn config(self: *ConfigBackend) ConfigSpace {
        return .from(self, &vtable);
    }

    fn complete(self: *ConfigBackend, index: usize) void {
        self.pending[index] = 0;

        if (load16(&self.bytes, pri_base + pri.offsets.control) & 1 != 0) {
            return;
        }

        for (self.pending) |pending| {
            if (pending != 0) {
                return;
            }
        }

        const offset = pri_base + pri.offsets.status;
        store16(&self.bytes, offset, load16(&self.bytes, offset) | 0x100);
    }

    fn reset(self: *ConfigBackend) void {
        store16(&self.bytes, ats_base + ats.offsets.control, 0);
        store16(&self.bytes, pasid_base + pasid.offsets.control, 0);
        store16(&self.bytes, pri_base + pri.offsets.control, 0);
        store16(&self.bytes, pri_base + pri.offsets.status, 0x8100);
        store32(&self.bytes, pri_base + pri.offsets.request_allocation, 0);
        self.pending = @splat(0);

        for (&self.vf_bytes) |*bytes| {
            store16(bytes, ats_base + ats.offsets.control, 0);
        }
    }

    fn bytesFor(self: *ConfigBackend, sbdf: Sbdf) ConfigError![]u8 {
        if (sbdf.raw() == pf.raw()) {
            return &self.bytes;
        }

        if (sbdf.raw() == vf.raw()) {
            return &self.vf_bytes[0];
        }

        if (sbdf.raw() == vf2.raw()) {
            return &self.vf_bytes[1];
        }

        return error.OutOfBounds;
    }

    fn atsEnabled(self: *ConfigBackend) bool {
        if (load16(&self.bytes, ats_base + ats.offsets.control) & 0x8000 != 0) {
            return true;
        }

        for (&self.vf_bytes) |*bytes| {
            if (load16(bytes, ats_base + ats.offsets.control) & 0x8000 != 0) {
                return true;
            }
        }

        return false;
    }

    fn read8(_: *anyopaque, _: Sbdf, _: usize) ConfigError!u8 {
        return error.UnsupportedAccessWidth;
    }

    fn read16(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigError!u16 {
        const self: *ConfigBackend = @ptrCast(@alignCast(context));
        return load16(try self.bytesFor(sbdf), offset);
    }

    fn read32(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigError!u32 {
        const self: *ConfigBackend = @ptrCast(@alignCast(context));
        const bytes = try self.bytesFor(sbdf);
        return std.mem.readInt(u32, bytes[offset..][0..4], .little);
    }

    fn write8(_: *anyopaque, _: Sbdf, _: usize, _: u8) ConfigError!void {
        return error.UnsupportedAccessWidth;
    }

    fn write16(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u16) ConfigError!void {
        const self: *ConfigBackend = @ptrCast(@alignCast(context));
        const bytes = try self.bytesFor(sbdf);
        const observed = load16(bytes, offset);

        if (offset == pasid_base + pasid.offsets.control and value != observed and self.atsEnabled()) {
            return error.OutOfBounds;
        }

        if (offset == pri_base + pri.offsets.control) {
            const status_offset = pri_base + pri.offsets.status;
            var status = load16(&self.bytes, status_offset);

            if (observed & 1 == 0 and value & 1 != 0) {
                if (status & 0x100 == 0) {
                    return error.OutOfBounds;
                }

                status &= ~@as(u16, 0x103);
            }

            if (observed & 1 != 0 and value & 1 == 0) {
                status &= ~@as(u16, 0x100);
                if (std.mem.allEqual(u32, &self.pending, 0)) {
                    status |= 0x100;
                }
            }

            if (value & 3 == 2) {
                self.pending = @splat(0);
                status |= 0x100;
            }

            store16(&self.bytes, status_offset, status);
        }

        const stored = if (offset == pri_base + pri.offsets.control) value & ~@as(u16, 2) else value;
        store16(bytes, offset, stored);

        if (self.fail_write_at == offset) {
            self.fail_write_at = null;
            return error.UnsupportedAccessWidth;
        }
    }

    fn write32(context: *anyopaque, _: Sbdf, offset: usize, value: u32) ConfigError!void {
        const self: *ConfigBackend = @ptrCast(@alignCast(context));

        if (offset == pri_base + pri.offsets.request_allocation) {
            if (load16(&self.bytes, pri_base + pri.offsets.control) & 1 != 0) {
                return error.OutOfBounds;
            }
        }

        store32(&self.bytes, offset, value);
    }
};

test "Linux-style PASID ATS PRI setup leaves drain and ordering caller owned" {
    var backend = ConfigBackend.from();
    store16(&backend.bytes, pri_base + pri.offsets.status, 0x8103);

    const function = Function.from(backend.config(), pf);
    const address_translation = (try AtsCapability.find(function)).?;
    const process = (try PasidCapability.find(function)).?;
    const requests = (try PriCapability.find(function)).?;

    try process.updateControl(.{ .enable = true, .execute_enable = true, .translated_requests_enable = true });
    try testing.expectEqual(@as(u16, 0xB), load16(&backend.bytes, pasid_base + pasid.offsets.control));

    try address_translation.updateControl(.{ .stu = .from(4), .enable = true });
    try testing.expectEqual(@as(u16, 0x8004), load16(&backend.bytes, ats_base + ats.offsets.control));

    try requests.reset();
    try testing.expectEqual(@as(u16, 0), load16(&backend.bytes, pri_base + pri.offsets.control));

    try requests.setRequestAllocation(32);
    try testing.expectEqual(@as(u32, 32), try requests.requestAllocation());

    try testing.expect((try requests.status()).stopped);
    try requests.updateControl(.{ .enable = true });
    try testing.expectEqual(@as(u16, 0x8000), load16(&backend.bytes, pri_base + pri.offsets.status));

    try testing.expectError(error.OutOfBounds, process.updateControl(.{ .enable = false }));

    backend.pending[0] = 2;
    try requests.updateControl(.{ .enable = false });

    try testing.expect(!(try requests.status()).stopped);
    try testing.expectEqual(@as(u32, 2), backend.pending[0]);

    try testing.expectError(error.OutOfBounds, requests.updateControl(.{ .enable = true }));

    backend.complete(0);

    try testing.expect((try requests.status()).stopped);

    try address_translation.updateControl(.{ .enable = false });
    try process.updateControl(.{ .enable = false, .execute_enable = false, .translated_requests_enable = false });

    try testing.expectEqual(@as(u16, 0), load16(&backend.bytes, pasid_base + pasid.offsets.control));
    try testing.expectEqual(@as(u16, 4), load16(&backend.bytes, ats_base + ats.offsets.control));
}

test "reset and resume restore caller-owned translation configuration" {
    var backend = ConfigBackend.from();
    const function = Function.from(backend.config(), pf);
    const address_translation = (try AtsCapability.find(function)).?;
    const process = (try PasidCapability.find(function)).?;
    const requests = (try PriCapability.find(function)).?;

    try process.updateControl(.{ .enable = true, .execute_enable = true, .translated_requests_enable = true });
    try address_translation.updateControl(.{
        .stu = .from(4),
        .mem_attr_default = 3,
        .mem_attr_enable = true,
        .enable = true,
    });

    try requests.setRequestAllocation(24);
    try requests.updateControl(.{ .enable = true });

    const saved_process = try process.control();
    const saved_translation = try address_translation.control();
    const saved_requests = try requests.control();
    const saved_allocation = try requests.requestAllocation();

    backend.reset();

    try testing.expect(!(try process.control()).enable);
    try testing.expect(!(try address_translation.control()).enable);
    try testing.expect(!(try requests.control()).enable);
    try testing.expectEqual(@as(u32, 0), try requests.requestAllocation());

    try process.updateControl(.{
        .enable = saved_process.enable,
        .execute_enable = saved_process.execute_enable,
        .privileged_enable = saved_process.privileged_enable,
        .translated_requests_enable = saved_process.translated_requests_enable,
    });

    try address_translation.updateControl(.{
        .stu = saved_translation.stu,
        .mem_attr_default = saved_translation.mem_attr_default,
        .mem_attr_enable = saved_translation.mem_attr_enable,
        .enable = saved_translation.enable,
    });

    try requests.reset();
    try testing.expect((try requests.status()).stopped);

    try requests.setRequestAllocation(saved_allocation);
    try requests.updateControl(.{ .enable = saved_requests.enable });

    try testing.expectEqual(@as(u16, 0xB), load16(&backend.bytes, pasid_base + pasid.offsets.control));
    try testing.expectEqual(@as(u16, 0xD804), load16(&backend.bytes, ats_base + ats.offsets.control));
    try testing.expectEqual(@as(u16, 1), load16(&backend.bytes, pri_base + pri.offsets.control));
    try testing.expectEqual(@as(u32, 24), try requests.requestAllocation());
}

test "setup failures after mutation require explicit drain and ordered recovery" {
    for ([_]usize{ ats_base + ats.offsets.control, pri_base + pri.offsets.control }) |failed_offset| {
        var backend = ConfigBackend.from();
        const function = Function.from(backend.config(), pf);
        const address_translation = (try AtsCapability.find(function)).?;
        const process = (try PasidCapability.find(function)).?;
        const requests = (try PriCapability.find(function)).?;

        try process.updateControl(.{ .enable = true });
        try requests.setRequestAllocation(32);

        backend.fail_write_at = failed_offset;

        if (failed_offset == ats_base + ats.offsets.control) {
            try testing.expectError(error.UnsupportedAccessWidth, address_translation.updateControl(.{
                .stu = .from(4),
                .enable = true,
            }));
        } else {
            try address_translation.updateControl(.{ .stu = .from(4), .enable = true });
            try testing.expectError(error.UnsupportedAccessWidth, requests.updateControl(.{ .enable = true }));
        }

        try testing.expect((try process.control()).enable);
        try testing.expect((try address_translation.control()).enable);
        try testing.expectEqual(failed_offset == pri_base + pri.offsets.control, (try requests.control()).enable);
        try testing.expectEqual(@as(u32, 32), try requests.requestAllocation());
        try testing.expectError(error.OutOfBounds, process.updateControl(.{ .enable = false }));

        if ((try requests.control()).enable) {
            backend.pending[0] = 1;

            try requests.updateControl(.{ .enable = false });
            try testing.expect(!(try requests.status()).stopped);

            backend.complete(0);
            try testing.expect((try requests.status()).stopped);
        }

        try address_translation.updateControl(.{ .enable = false });
        try process.updateControl(.{ .enable = false });

        try testing.expectEqual(@as(u16, 4), load16(&backend.bytes, ats_base + ats.offsets.control));
        try testing.expectEqual(@as(u16, 0), load16(&backend.bytes, pasid_base + pasid.offsets.control));
        try testing.expect(!(try requests.control()).enable);
        try testing.expectEqual(@as(u32, 32), try requests.requestAllocation());
    }
}

test "ATS and PASID do not require the other translation capabilities" {
    var bytes: [pci.core.config.extended_size]u8 = @splat(0);
    const cases = [_]struct { id: u32, control: u16 }{
        .{ .id = 0x0001_000F, .control = 0x8000 },
        .{ .id = 0x0001_001B, .control = 1 },
    };

    for (cases) |case| {
        @memset(&bytes, 0);
        store32(&bytes, 0x100, case.id);

        var backend = TestConfigSpace.fromSingle(pf, &bytes);
        const function = Function.from(backend.config(), pf);

        if (case.id == 0x0001_000F) {
            const cap = (try AtsCapability.find(function)).?;
            try cap.updateControl(.{ .enable = true });
            try testing.expectEqual(@as(?PasidCapability, null), try PasidCapability.find(function));
        } else {
            const cap = (try PasidCapability.find(function)).?;
            try cap.updateControl(.{ .enable = true });
            try testing.expectEqual(@as(?AtsCapability, null), try AtsCapability.find(function));
        }

        try testing.expectEqual(case.control, load16(&bytes, 0x106));
        try testing.expectEqual(@as(?PriCapability, null), try PriCapability.find(function));
    }
}

test "PF recovery coordinates shared PRI state and both VF ATS enables" {
    var backend = ConfigBackend.from();
    const function = Function.from(backend.config(), pf);
    const address_translation = (try AtsCapability.find(function)).?;
    const process = (try PasidCapability.find(function)).?;
    const requests = (try PriCapability.find(function)).?;

    try address_translation.updateControl(.{ .stu = .from(4) });
    try process.updateControl(.{ .enable = true });
    try requests.setRequestAllocation(24);
    try requests.updateControl(.{ .enable = true });

    var vf_ats: [2]AtsCapability = undefined;

    for ([_]Sbdf{ vf, vf2 }, &vf_ats) |sbdf, *cap| {
        const vf_function = Function.from(backend.config(), sbdf);
        cap.* = (try AtsCapability.find(vf_function)).?;

        try cap.updateControl(.{ .enable = true });
        try testing.expectEqual(@as(?PasidCapability, null), try PasidCapability.find(vf_function));
        try testing.expectEqual(@as(?PriCapability, null), try PriCapability.find(vf_function));
    }

    try testing.expectEqual(@as(u16, 4), load16(&backend.bytes, ats_base + ats.offsets.control));
    try testing.expectEqual(@as(u16, 1), load16(&backend.bytes, pasid_base + pasid.offsets.control));
    try testing.expectEqual(@as(u32, 24), try requests.requestAllocation());

    backend.pending = .{ 0, 1, 2 };

    try requests.updateControl(.{ .enable = false });
    try testing.expect(!(try requests.status()).stopped);

    backend.complete(1);
    try testing.expect(!(try requests.status()).stopped);
    try testing.expectEqual(@as(u32, 2), backend.pending[2]);

    backend.complete(2);
    try testing.expect((try requests.status()).stopped);

    try requests.updateControl(.{ .enable = true });
    backend.pending = .{ 0, 2, 3 };

    try requests.updateControl(.{ .enable = false });
    try testing.expect(!(try requests.status()).stopped);

    try requests.reset();

    try testing.expect((try requests.status()).stopped);
    try testing.expectEqual(@as(u32, 0), backend.pending[1]);
    try testing.expectEqual(@as(u32, 0), backend.pending[2]);
    try testing.expect((try vf_ats[0].control()).enable);
    try testing.expect((try vf_ats[1].control()).enable);
    try testing.expectEqual(@as(u32, 24), try requests.requestAllocation());

    try testing.expectError(error.OutOfBounds, process.updateControl(.{ .enable = false }));

    try vf_ats[0].updateControl(.{ .enable = false });
    try testing.expectError(error.OutOfBounds, process.updateControl(.{ .enable = false }));

    try vf_ats[1].updateControl(.{ .enable = false });
    try process.updateControl(.{ .enable = false });

    try testing.expectEqual(@as(u16, 0), load16(&backend.vf_bytes[0], ats_base + ats.offsets.control));
    try testing.expectEqual(@as(u16, 0), load16(&backend.vf_bytes[1], ats_base + ats.offsets.control));
    try testing.expectEqual(@as(u16, 0), load16(&backend.bytes, pasid_base + pasid.offsets.control));
    try testing.expectEqual(@as(u16, 4), load16(&backend.bytes, ats_base + ats.offsets.control));
}

fn load16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn store16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn store32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
