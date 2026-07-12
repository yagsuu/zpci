//! Config function view. Spec: docs/specs/config/space.md.

const accessor = @import("accessor.zig");
const core = @import("../core.zig");

const ConfigSpace = accessor.ConfigSpace;

pub const function_window_size: usize = accessor.function_window_size;

pub const HeaderKind = enum {
    type0,
    type1,
};

const offset = struct {
    const vendor_id: usize = 0x00;
    const device_id: usize = 0x02;
    const revision_id: usize = 0x08;
    const prog_if: usize = 0x09;
    const subclass: usize = 0x0A;
    const base_class: usize = 0x0B;
    const header_type: usize = 0x0E;
};

const header = struct {
    const layout_mask: u8 = 0x7F;
    const multifunction_mask: u8 = 0x80;
};

/// Borrowed view over one PCI configuration-space function.
///
/// Non-allocating; copies share the same `ConfigSpace` backend context. A
/// value returned by `validate` records only a point-in-time presence/header
/// check. Later reads observe live backend state.
pub const Function = struct {
    config: ConfigSpace,
    sbdf: core.Sbdf,

    pub const Error = ConfigSpace.Error || error{
        AbsentFunction,
        BadHeaderType,
    };

    /// Validates Vendor ID presence and supported type-0/type-1 header kind.
    pub fn validate(config: ConfigSpace, sbdf: core.Sbdf) Error!Function {
        const vendor = core.VendorId.from(try config.read16(sbdf, offset.vendor_id));
        if (vendor.isAbsent()) return error.AbsentFunction;

        _ = try headerKindFromByte(try config.read8(sbdf, offset.header_type));

        return .{ .config = config, .sbdf = sbdf };
    }

    /// Constructs without I/O; establishes no presence or header-kind invariant.
    pub fn unchecked(config: ConfigSpace, sbdf: core.Sbdf) Function {
        return .{ .config = config, .sbdf = sbdf };
    }

    /// Returns true when both handles target the same backend and SBDF.
    pub fn eq(self: Function, other: Function) bool {
        const same_context = self.config.context == other.config.context;
        const same_vtable = self.config.vtable == other.config.vtable;
        const same_sbdf = self.sbdf.eql(other.sbdf);

        return same_context and same_vtable and same_sbdf;
    }

    pub fn read8(self: Function, byte_offset: usize) ConfigSpace.Error!u8 {
        return self.config.read8(self.sbdf, byte_offset);
    }

    pub fn read16(self: Function, byte_offset: usize) ConfigSpace.Error!u16 {
        return self.config.read16(self.sbdf, byte_offset);
    }

    pub fn read32(self: Function, byte_offset: usize) ConfigSpace.Error!u32 {
        return self.config.read32(self.sbdf, byte_offset);
    }

    pub fn write8(self: Function, byte_offset: usize, value: u8) ConfigSpace.Error!void {
        return self.config.write8(self.sbdf, byte_offset, value);
    }

    pub fn write16(self: Function, byte_offset: usize, value: u16) ConfigSpace.Error!void {
        return self.config.write16(self.sbdf, byte_offset, value);
    }

    pub fn write32(self: Function, byte_offset: usize, value: u32) ConfigSpace.Error!void {
        return self.config.write32(self.sbdf, byte_offset, value);
    }

    pub fn vendorId(self: Function) ConfigSpace.Error!core.VendorId {
        return core.VendorId.from(try self.read16(offset.vendor_id));
    }

    pub fn deviceId(self: Function) ConfigSpace.Error!core.DeviceId {
        return core.DeviceId.from(try self.read16(offset.device_id));
    }

    pub fn revisionId(self: Function) ConfigSpace.Error!core.RevisionId {
        return core.RevisionId.from(try self.read8(offset.revision_id));
    }

    pub fn classCode(self: Function) ConfigSpace.Error!core.ClassCode {
        const pif = try self.read8(offset.prog_if);
        const sub = try self.read8(offset.subclass);
        const base = try self.read8(offset.base_class);

        return core.ClassCode.from(base, sub, pif);
    }

    pub fn headerKind(self: Function) Error!HeaderKind {
        return headerKindFromByte(try self.read8(offset.header_type));
    }

    pub fn isMultifunction(self: Function) ConfigSpace.Error!bool {
        const header_type = try self.read8(offset.header_type);
        return header_type & header.multifunction_mask != 0;
    }
};

fn headerKindFromByte(header_type: u8) error{BadHeaderType}!HeaderKind {
    return switch (header_type & header.layout_mask) {
        0x00 => .type0,
        0x01 => .type1,
        else => error.BadHeaderType,
    };
}
