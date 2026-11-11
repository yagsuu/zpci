const Function = @import("pci").config.Function;

export fn rawOffset(function: *const Function) void {
    _ = function.read(0) catch return;
}
