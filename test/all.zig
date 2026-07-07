//! Default host test suite aggregate. Spec: docs/guidelines/testing.md.

comptime {
    _ = @import("core/errors_test.zig");
    _ = @import("core/ids_test.zig");
    _ = @import("core/bdf_test.zig");
    _ = @import("memory/bar_test.zig");
}
