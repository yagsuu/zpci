const stdx = @import("stdx");
const extended = @import("extended.zig");

const BitFieldExt = stdx.bits.BitFieldExt;
const BitField = stdx.bits.BitField;

pub const id: extended.Id = .sriov;

pub const Capabilities = BitFieldExt(u32, .{
    .vf_migration = .{ .type = bool, .access = .ro },
    .ari_hierarchy_preserved = .{ .type = bool, .access = .ro },
    .vf_10bit_tag_requester = .{ .type = bool, .access = .ro },
    .migration_intr_message = .{ .offset = 21, .type = u11, .access = .ro },
}, .{ .unnamed = .reserved });

pub const Control = BitFieldExt(u16, .{
    .vf_enable = bool,
    .vf_migration_enable = bool,
    .vf_migration_intr_enable = bool,
    .vf_mem_enable = bool,
    .ari_hierarchy = bool,
    .vf_10bit_tag_requester_enable = bool,
    .vf_14bit_tag_requester_enable = bool,
}, .{ .unnamed = .reserved });

pub const Status = BitFieldExt(u16, .{
    .vf_migration = .{ .type = bool, .write = .w1c },
}, .{ .unnamed = .reserved });

pub const MigrationArray = BitField(u32, .{
    .bir = .{ .type = u3, .access = .ro },
    .offset_shifted = .{ .type = u29, .access = .ro },
});

pub const offsets = struct {
    pub const capabilities: u8 = 0x04;
    pub const control: u8 = 0x08;
    pub const status: u8 = 0x0A;
    pub const initial_vfs: u8 = 0x0C;
    pub const total_vfs: u8 = 0x0E;
    pub const num_vfs: u8 = 0x10;
    pub const function_dependency: u8 = 0x12;
    pub const first_vf_offset: u8 = 0x14;
    pub const vf_stride: u8 = 0x16;
    pub const vf_device_id: u8 = 0x1A;
    pub const supported_page_sizes: u8 = 0x1C;
    pub const system_page_size: u8 = 0x20;
    pub const vf_bar0: u8 = 0x24;
    pub const vf_bar1: u8 = 0x28;
    pub const vf_bar2: u8 = 0x2C;
    pub const vf_bar3: u8 = 0x30;
    pub const vf_bar4: u8 = 0x34;
    pub const vf_bar5: u8 = 0x38;
    pub const migration_array: u8 = 0x3C;
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "SR-IOV modern controls and capabilities retain architectural bit positions" {
        try testing.expectEqual(@as(u16, 0x7F), Control.masks.assign);

        const control = Control.from(0x78);
        try testing.expect(control.vf_mem_enable);
        try testing.expect(control.ari_hierarchy);
        try testing.expect(control.vf_10bit_tag_requester_enable);
        try testing.expect(control.vf_14bit_tag_requester_enable);

        const caps = Capabilities.from(0xFFE0_0007);
        try testing.expect(caps.ari_hierarchy_preserved);
        try testing.expect(caps.vf_10bit_tag_requester);
        try testing.expectEqual(@as(u11, 0x7FF), caps.migration_intr_message);
    }
};
