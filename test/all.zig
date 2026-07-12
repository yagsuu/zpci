//! Default host test suite aggregate. Spec: docs/guidelines/testing.md.

comptime {
    _ = @import("bar_test.zig");
    _ = @import("capabilities/extended_test.zig");
    _ = @import("capabilities/list_test.zig");
    _ = @import("capabilities/pcie_test.zig");
    _ = @import("config/accessor_test.zig");
    _ = @import("config/ecam_test.zig");
    _ = @import("config/space_test.zig");
    _ = @import("interrupts/msi_test.zig");
    _ = @import("interrupts/msix_test.zig");
    _ = @import("core/errors_test.zig");
    _ = @import("core/ids_test.zig");
    _ = @import("core/bdf_test.zig");
    _ = @import("header/common_test.zig");
    _ = @import("header/type0_test.zig");
    _ = @import("header/type1_test.zig");
    _ = @import("memory/bar_test.zig");
    _ = @import("resources/model_test.zig");
    _ = @import("resources/assignment_test.zig");
    _ = @import("resources/bridge_test.zig");
    _ = @import("resources/bus_test.zig");
    _ = @import("resources/programming_test.zig");
    _ = @import("topology/enumerate_test.zig");
    _ = @import("topology/tree_test.zig");
    _ = @import("topology/bridge_test.zig");
}
