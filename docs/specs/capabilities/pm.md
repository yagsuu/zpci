# `pci.capabilities.pm`

PMCSR control, power-state requests, and PME acknowledgement.

## Access

Uses [standard capability access](access.md). Construction checks the mandatory
extent through Control and retains the raw revision, including unknown values;
reads remain live. Optional bytes are checked when accessed.

| Operation/value | Contract |
| --- | --- |
| `updateControl()` | Mechanical partial update of ordinary controls; no state/support checks. Write payload excludes W1C, read-only, and reserved bits. |
| `bridgeSupport()` | Requires a live Type 1 header; otherwise `UnsupportedRegister`. |
| `data()` | Raw selected data byte; zero is valid. |
| Power state | PMCSR targets: D0, D1, D2, D3hot. PME support categories also include D3cold. |

## `setPowerState()`

| Request | Validation |
| --- | --- |
| D0 | Any current state. |
| D1/D2 | Advertised support; current state no deeper than requested. |
| D3hot | Any current state. |

Unsupported D1/D2 returns `UnsupportedFeature`; a shallower non-D0 request returns
`InvalidTransition`, without a write. Accepted requests preserve other ordinary
controls and write the PME Status bit as zero. Callers handle intermediate
transitions, timing, readback, resets, and device restoration.

## `ackPmeStatus(observed)`

- False observed PME: no I/O.
- True observed PME: reread Control, preserve its current ordinary fields, and
  acknowledge the event.

Callers serialize these non-atomic updates. Acknowledgement cannot distinguish a
later event on the same bit. Access failures follow the [shared contract](access.md).

## References

- [Operations](../../../src/capabilities/pm.zig), [wire values](../../../src/core/capabilities/pm.zig)
- [PCI Bus Power Management Interface Specification 1.2](https://lekensteyn.nl/files/docs/PCI_Power_Management_12.pdf)
