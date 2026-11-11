const pci = @import("pci");

const Bdf = pci.core.Bdf;
const Sbdf = pci.core.Sbdf;
const SegmentId = pci.core.SegmentId;
const Offset = pci.core.Offset;
const ConfigSpace = pci.config.ConfigSpace;
const Function = pci.config.Function;
const header = pci.core.header;

comptime {
    for (.{ u8, u16, u32 }) |T| {
        _ = Offset(T).from(0);
        _ = Offset(T).tryFrom(0) catch unreachable;
    }

    _ = Bdf.from(255, 31, 7);
    _ = Sbdf.from(SegmentId.from(65535), 255, 31, 7);
}

export fn typedConfig(
    config: *const ConfigSpace,
    function: *const Function,
    memory: *[pci.core.config.extended_size]u8,
    position: usize,
    segment: u16,
    bus: u8,
    device: u8,
    function_number: u8,
) bool {
    if (device > 31 or function_number > 7) {
        return false;
    }

    const bdf = Bdf.from(bus, @intCast(device), @intCast(function_number));
    const sbdf = Sbdf.from(SegmentId.from(segment), bus, bdf.device, bdf.function);
    const bound = Function.from(config.*, Sbdf.fromBdf(sbdf.segment, bdf));

    inline for (.{ u8, u16, u32 }) |T| {
        const checked = Offset(T).tryFrom(position) catch return false;
        const trusted = Offset(T).from(checked.raw());
        const value = config.read(sbdf, trusted) catch return false;
        config.write(sbdf, checked, value) catch return false;
        const function_value = function.read(checked) catch return false;
        bound.write(trusted, function_value) catch return false;
    }

    memory[header.type0.offsets.command] = memory[header.type0.offsets.status];
    memory[header.type0.offsets.bar(0)] = memory[header.type1.offsets.secondary_bus];
    return true;
}
