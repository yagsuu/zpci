# `pci.capabilities.dpc`

## Capability

Applies to Root Ports and Switch Downstream Ports. Callers establish role and
feature applicability for mechanical updates.

| API | Contract |
| --- | --- |
| `Capability.tryFrom()` | Checks through Source ID; optional RP PIO storage is checked on access. Revision unchecked. |
| `Capability.capabilities()`, `Capability.control()`, `Capability.status()` | Live register reads. |
| `Capability.updateControl()` | Non-atomic partial read-modify-write; preserves unselected/reserved bits and excludes Software Trigger. |
| `Capability.sourceId()` | Raw Requester ID; meaningful only with Trigger set and reason `fatal` or `non_fatal`. |

## Containment

| API/value | Contract |
| --- | --- |
| Trigger mode `fatal` | Local unmasked uncorrectable errors or received ERR_FATAL. `non_fatal` additionally includes received ERR_NONFATAL. |
| `Capability.trigger()` | Requires advertised Software Trigger support; otherwise `UnsupportedFeature`. Writes the action without waiting. Hardware ignores it when disabled or already triggered. |
| `Capability.ackStatus(observed, fields)` | Writes selected, observed W1C bits without rereading. `intr_pending` acknowledges the interrupt; `triggered` releases containment; `sig_fw` clears firmware signaling status. |

Before clearing `triggered`, callers establish DLL Link Active clear and RP Busy
clear where RP Extensions apply. Callers handle recovery, timeouts, and
post-reset configuration readiness.

## Root Port PIO

Register methods check live RP Extensions support; absent support returns
`UnsupportedRegister`.

| API/value | Contract |
| --- | --- |
| `Capability.updatePio*()` | Non-atomic partial read-modify-write; preserves unselected and reserved bits. |
| `Capability.ackPioStatus(observed, fields)` | Writes selected, observed W1C bits; no PIO Status reread. |
| `Capability.ackPioFirstError(status, observed)` | Writes only the defined, pending bit selected by First Error Pointer. Invalid/inactive pointers cause no write. |
| Mask | Set suppresses logging/containment; status still latches. |
| Severity | Set selects uncorrectable/containment; clear selects advisory. |
| SysError | Set enables system-error signaling for an unmasked error. |
| Exception | Set permits a synchronous exception even when masked or advisory. |

## Logs

`LogArgs` supplies observed DPC capabilities/status, PIO Status, PCIe Flit
support, and caller-known log mode. Logs can be valid with Trigger clear.

| API/value | Contract |
| --- | --- |
| `Capability.pioHeaderLog(args)` | Optional raw four-dword outgoing Request header. |
| `Capability.pioPrefixLog(args)` | Optional allocated prefix storage, up to four dwords. `PrefixLog.slice()` exposes initialized words. |
| `Capability.pioImpSpecLog(args)` | Optional implementation-specific word, separate from header storage. |
| `Capability.pioFlitHeaderLog(args)` | Optional allocated header storage, up to fourteen dwords; skips the implementation-specific word. `flit.HeaderLog.slice()` exposes initialized words. |
| Allocation | Total log size 4–15 dwords. Size 4 contains the base header; size 5 adds the implementation-specific word. Later words extend Flit headers or allocate up to four prefixes. High size bit applies only with Flit support. |
| `null` | No defined, pending First Error Pointer; or the requested optional bank is unallocated. |
| `UnsupportedRegister` | Observed capabilities lack RP Extensions. |
| `UnexpectedLogMode` | Requested format differs from supplied mode, or Flit access lacks Flit support. |
| `MalformedCapability` | Invalid allocation or incomplete register extent; checked before payload reads. |

Counts describe allocated storage. Only `words[0..len]` is initialized in counted
results. Clearing the pointed PIO status bit invalidates the First Error Pointer.
Separate reads are not atomic.

## Failures

Access failures follow the [shared contract](access.md). No retries, rollback, or
implicit acknowledgements.

## References

- [Operations](../../../src/capabilities/dpc.zig), [wire values](../../../src/core/capabilities/dpc.zig)
