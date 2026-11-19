# `pci.capabilities.aer`

Uses [extended capability access](access.md). Construction checks through the
fourth header dword; revision is unchecked. Reads remain live. Callers establish
feature support and Root Port/RCEC applicability for root registers.

## Registers

| Value/operation | Contract |
| --- | --- |
| `update*()` | Non-atomic partial read-modify-write; preserves unselected and reserved bits. Uncorrectable Mask updates force bit 0 to 1. |
| `ack*Status(observed, fields)` | Writes selected W1C bits set in the observation, without rereading. Uncorrectable bit 0 is undefined and excluded. |
| `ackFirstError(status, control)` | Writes only the defined, observed bit selected by First Error Pointer. Invalid or inactive pointers cause no write. |
| Mask | Set suppresses reporting; status still latches. Uncorrectable masks also suppress header/prefix logging and First Error Pointer updates. |
| Severity | Set selects fatal; clear selects non-fatal. |
| Root status/source IDs | Status bits 0–6 are W1C; subclass and interrupt-message fields are read-only. Source IDs are raw Requester IDs. |
| Canonical Uncorrectable Mask bit 0 | Every write must set it to 1. Construction defaults set it; `from()` and `replace()` preserve the supplied bit. Reads are undefined. |
| Revision | Flit support requires version 3; E2E prefix support requires version 2 or 3. Optional features require separate support checks. |

Acknowledgement can also clear a same-bit event raised after the observation.
Access failures follow the [shared failure contract](access.md).

## Logs

`LogArgs` supplies caller-observed PCIe capabilities, AER Control, and
Uncorrectable Status.

| Operation/value | Contract |
| --- | --- |
| `headerLog(args)` | Optional raw `HeaderLog`: four dwords. The fourth is undefined for a three-dword header; malformed captures remain unparsed. |
| `prefixLog(args)` | Optional raw `PrefixLog`: four dwords when `prefix_log_present` is set. Unused positions read zero. |
| `flit.headerLog(cap, args)` | Optional counted log, up to fourteen dwords; skips the root-register hole. Only `words[0..len]` is initialized; `slice()` exposes it. |
| `header_log_size` | Implemented capacity in dwords. |
| `logged_tlp_flit`, `logged_tlp_size` | Captured mode and dword count; interpreted only with Flit support. |
| `null` | No defined, active First Error Pointer; error without header logging; absent prefix log; zero captured length on Flit-capable hardware; or all-one header. |
| `UnexpectedLogMode` | Requested format differs from the captured mode, or Flit access lacks Flit support. |
| `MalformedCapability` | Invalid capacity/length or register extent. Checked before payload reads. |

Data-link protocol, surprise-down, flow-control protocol, and receiver-overflow
errors have no header logs. Completion-timeout logging requires
`completion_timeout_log_capable`.

Log words retain protocol byte order: byte 0 occupies bits 31–24 of the first
dword. Capture logs before acknowledgement; clearing the first error can advance
the log queue. Separate reads are not atomic.

## References

- [Operations](../../../src/capabilities/aer.zig), [wire values](../../../src/core/capabilities/aer.zig)
- [Register-word operations](../core.md#register-words)
