# `pci.core`

Canonical PCI identities, addresses, wire values, and typed configuration offsets.

## Identities and addresses

| Value | Contract |
| --- | --- |
| Scalar IDs | `from()` accepts the full backing integer domain; `raw()` returns it unchanged. Unknown IDs remain representable. |
| `VendorId.absent` | `0xFFFF`; interpreting function presence belongs to [configuration access](config.md). |
| `ClassCode` | Three bytes in wire order: programming interface, subclass, base class. Construction takes base class first and accepts all component byte values. |
| `Bdf` | 16-bit Routing ID: function bits 0–2, device bits 3–7, bus bits 8–15. |
| `Sbdf` | BDF in the low 16 bits; segment in the high 16. Presence checks use configuration reads. |
| Component domains | 256 buses, 32 devices, 8 conventional functions. ARI uses the eight device/function bits; `function.Index` remains three bits wide. |

`Bdf.from()` and `Sbdf.from()` accept width-constrained components without runtime
validation. Equality and ordering use their raw encodings. `function0()` and
`withFunction()` preserve the other components.

| Text operation | Contract |
| --- | --- |
| Format | Zero-padded lowercase `bb:dd.f` or `ssss:bb:dd.f`. |
| Parse | Exactly those widths and separators; upper/lowercase hex accepted. No whitespace, prefixes, or out-of-range components; failures return `InvalidIdentifier`. |

## Configuration offsets

| Value/operation | Contract |
| --- | --- |
| `Offset(T)` | Absolute byte position in one function's configuration space. |
| `RelativeOffset(T)` | Distinct capability-relative byte position; capability access binds and checks the absolute extent. |
| Width | Only `u8`, `u16`, `u32`; width and offset kind are part of the type. |
| `tryFrom(position)` | Requires the complete access inside 4096 bytes and alignment to `@sizeOf(T)`. Bounds errors precede alignment errors. |
| `from(position)` | Same requirements, assumed valid by the caller; invalid input is unreachable, including compile-time rejection for constant evaluation. |
| `raw()` | Byte position. |

Typed configuration APIs trust these values; callers must not forge invalid enum
encodings. A valid 4 KiB offset can still exceed a backend's supported window.
Raw offset catalogues remain scalar byte positions for direct wire access.

## Wire values

- `header.Type0` and `header.Type1` describe 64-byte wire headers with alignment 4.
  `ClassCode` has size 3 and alignment 1.
- `header.Format` preserves the seven-bit encoding, including CardBus and unknown
  values. Operational support is a separate [configuration](config.md) check.
- Canonical BAR, bridge, and capability records describe encodings. Their operational
  namespaces own access, feature checks, allocation, and programming policy.

### Register words

| Operation/metadata | Meaning |
| --- | --- |
| `from()` / `raw()` | Convert a backing word without checking PCI applicability. |
| `init()` | Construct using declared defaults for omitted fields. |
| `replace()` | Change selected ordinary assignable fields; preserve omitted fields and other raw bits. |
| Assignment, W1C, trigger, reserved masks | Distinct write/access classes. Reserved masks include only declared reserved bits. |
| `ack()` / `trigger()` | Build the selected acknowledgement or action payload where the register exposes it. |

Reserved gaps remain unnamed unless an explicit field/default is required.
Each operation defines its mixed-policy and context-dependent write payloads.

## References

- [Identities](../../src/core/ids.zig), [addresses](../../src/core/bdf.zig)
- [Typed offsets](../../src/core/offset.zig), [configuration sizes](../../src/core/config.zig)
- [Header wire values](../../src/core/header.zig), [Type 0](../../src/core/header/type0.zig), [Type 1](../../src/core/header/type1.zig)
- [Canonical BARs](../../src/core/bar.zig), [bridge windows](../../src/core/bridge.zig), [capabilities](../../src/core/capabilities/module.zig)
