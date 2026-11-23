# `pci.capabilities.pcie`

Live PCIe register access, partial control updates, and explicit actions.

## Binding and applicability

Uses [standard capability access](access.md). Construction reads and retains
`version`, `type`, and `has_slot`; register reads remain live. Rebind after
structural changes.

| Register group | Applicability |
| --- | --- |
| Device | All port types. |
| Link | Endpoint, legacy endpoint, root port, upstream/downstream port, or either PCI/PCIe bridge direction. |
| Slot | Root port, downstream port, or `pci_to_pcie`; access is independent of `has_slot`. |
| Root | Root port or RCEC. |
| Version 2 registers | `version >= 2`; later versions use the same known register set. |

Version zero returns `UnsupportedRevision` at construction. Unsupported groups
return `UnsupportedRegister`; v2 revision checks precede group checks and I/O.
Register extents are checked on access.

## Control updates

- `Capability.update*Control*()` performs a partial, non-atomic read-modify-write. Omitted
  fields and other raw bits are preserved except the action bits below.
- Checks register applicability. Callers supply valid field values and establish
  feature and platform support.

| Control | Action handling |
| --- | --- |
| Device | Preserve observed BCRE only for `pcie_to_pci`; zero shared bit 15 otherwise, never replaying FLR. |
| Link | Clear retrain. |
| Slot | Clear interlock request. |

Persistent requests, including Emergency Power Reduction, follow ordinary
field-update rules.

### Validated setters

| Operation | Additional validation/effect |
| --- | --- |
| `Capability.setMaxPayloadSize()` | Known size within local advertised maximum; no hierarchy-wide check. |
| `Capability.setMaxReadRequestSize()` | Known size encoding only. |
| `Capability.setCompletionTimeout()` | v2, known encoding, advertised range for non-default values. Does not change timeout-disable. |
| `Capability.setTargetLinkSpeed()` | v2, Gen1–6 scalar encoding advertised in Supported Link Speeds; does not retrain. |

Unknown requests return `InvalidValue`; locally unsupported requests return
`UnsupportedFeature`, before a control write.

## Acknowledgements and actions

`Capability.ack*Status(observed, fields)` writes only selected W1C bits set in the supplied
observation, without rereading status. Invalid/non-W1C selectors fail compilation.
Acknowledgement can also clear a same-bit event raised after the observation.

| Action | Requirement |
| --- | --- |
| `Capability.retrainLink()` | Root port, downstream port, or `pci_to_pcie`. |
| `Capability.toggleInterlock()` | Slot-group applicability and advertised interlock. |
| `Capability.requestFlr()` | Endpoint, legacy endpoint, or RCiEP, with advertised FLR support. Preserves ordinary Device Control fields without replaying other actions. |

Actions issue requests without waiting or polling. FLR callers handle Command
decoding, bus mastering, and pending transactions. Callers own quiescing,
completion timing, path-wide choices, PF/VF policy, and synchronized updates.
Access failures follow the [shared failure contract](access.md).

## Link values

| Value | Meaning |
| --- | --- |
| `LinkSpeed.mtps()` | Mega-transfers/second for Gen1–6; unknown encodings return `MalformedField`. |
| `LinkWidth.lanes()` | Named lane count; unknown encodings return `MalformedField`. |
| `LinkSpeeds.supports()` | Bitmap membership; `gen7_plus` advertises 128 GT/s or higher. |

## References

- [Operations](../../../src/capabilities/pcie.zig)
- [Wire values](../../../src/core/capabilities/pcie.zig), [device](../../../src/core/capabilities/pcie/device.zig), [link](../../../src/core/capabilities/pcie/link.zig), [slot](../../../src/core/capabilities/pcie/slot.zig), [root](../../../src/core/capabilities/pcie/root.zig)
