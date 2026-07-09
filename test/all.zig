//! Default host test suite aggregate. Spec: docs/guidelines/testing.md.

comptime {
    _ = @import("config/accessor_test.zig");
    _ = @import("config/ecam_test.zig");
    _ = @import("config/space_test.zig");
    _ = @import("core/errors_test.zig");
    _ = @import("core/ids_test.zig");
    _ = @import("core/bdf_test.zig");
    _ = @import("header/common_test.zig");
    _ = @import("header/type0_test.zig");
    _ = @import("header/type1_test.zig");
    _ = @import("memory/bar_test.zig");
}
