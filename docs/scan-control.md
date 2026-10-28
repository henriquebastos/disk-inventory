# Controlled snapshot creation

[Inventory::create_controlled](../src/inventory.rs) adds a single-use
[ScanControl](../src/scan_control.rs) to `create(root, output, options)`. Existing
create/open/sync, CLI defaults, partial-scan policy and snapshot bytes are unchanged.
Create still requires a **new** destination: callers retaining a last valid snapshot
must choose a new owned generation, then update their last-inventory reference only
after success. This API does not replace or clean up previous generations.

## Progress and Stop

Construct the control before dispatching synchronous creation off the main thread.
Polling and cancellation use only atomics, independent of collector and session
mutexes. No callbacks, per-entry atomics, strings or FFI messages are emitted.
Uncontrolled calls allocate no control and update no progress atomics.

`items_examined` counts the root metadata observation plus received directory-entry
records, including exclusions and record-level errors, sampled at 256-record merges
and final directory batches. It is cumulative and monotonic, not accepted entries,
files only, completed directories, bytes, a percentage or an estimate of total work.
An interrupted batch may not yet be reflected. Poll approximately four times a second;
counts and phase are independent atomic observations, not an accounting transaction.

Phases:

| Phase | Meaning |
|---|---|
| Ready | Control constructed, operation not yet started; Stop is allowed |
| Scanning | Metadata traversal, including setup |
| Accounting | Hardlink attribution and subtree aggregation |
| Saving | Serialization, flush and file fsync; still cancellable |
| Stopping | Stop accepted; worker calls may still be unwinding |
| Committing | Publication won against Stop; namespace syscall may be in flight |
| Committed | Snapshot published; core create succeeded or durability work remains |
| PreparingView | Bridge reopening/validating snapshot and building indexes |
| Complete | Bridge session ready, not necessarily Swift's first frame |
| Cancelled | Workers joined, owned staging cleanup attempted; no publication |
| Failed | Failure before successful namespace publication |
| PublishedFailure | Publication succeeded, but later durability or view setup failed |

`cancel()` returns true only if Stop was accepted or already pending. Stop is
nonblocking and cannot interrupt a filesystem syscall. It is rejected from Committing
onward and in terminal states; `cancellable` is the UI's Stop-enabled flag. The client
should immediately display Stopping when Stop is accepted, not wait for the next poll.
A reused control fails validation without altering its first operation's state.

Checks surround directory/bulk syscalls, 256-record merges and allocation fallbacks.
Idle workers wake when active workers unwind; scoped threads join before cancellation
returns. Aggregation checks every 256 nodes in each pass. Saving checks every 256
records, each 64 KiB name chunk and around flush/fsync. One syscall, allocation,
path comparison or buffer operation remains non-interruptible.

An atomic compare-exchange arbitrates Stop versus commitment immediately before the
namespace operation. A winning Stop cannot publish. If commitment wins, subsequent
errors are not cancellation. After the hard-link/rename succeeds, unlinking staging
or parent fsync can fail with the destination already visible. Do not infer rollback
from an error: inspect PublishedFailure. Cleanup only attempts removal of the owned
temporary file; an I/O failure may leave that file behind.

Cancellation returns `io::ErrorKind::Interrupted` containing typed `ScanCancelled`,
not scan-error counters or `IncompleteSync`. The bridge maps only that typed error to
`BridgeError.Cancelled`; other I/O errors retain their normal classifications.

## Controlled refresh

`OperationSession::refresh_directory_controlled` and the bridge
`refresh_directory_controlled` reuse one control for an in-memory refresh of a directory.
`items_examined` counts each directory metadata request and each directory record of the live
read. Stop is checked before each request. `commit_from(Scanning)` is the same compare-exchange
as `commit`, so a winning Stop applies nothing and ends Cancelled. After the commit the update
completes; the core leaves Committed and the bridge Complete. A stopped refresh keeps the
session revision, so existing frames and trees stay valid.
"controlled_refresh_stop_keeps_views_and_completion_applies_live_changes" in
[src/bridge/tests.rs](../src/bridge/tests.rs) checks both outcomes.

## Generated Swift seam

```swift
let control = ScanControl()
// On a worker, retaining the same control:
let session = try ExplorerSession.createControlled(
    sourceRoot: sourceBytes, snapshotPath: newGenerationBytes,
    workers: 4, control: control)
// Independently on the UI thread:
let progress = control.progress() // phase, itemsExamined: UInt64, cancellable: Bool
let accepted = control.cancel()  // Bool; does not cancel a Swift Task
```

The generated `ScanPhase` cases use lower camel case (`.preparingView`,
`.publishedFailure`). Core success stays Committed; bridge success transitions
through PreparingView to Complete. Reopen is deliberately noncancellable because
publication already succeeded. Swift view construction after return is client work.

## Evidence and limits

[src/scan_control/tests.rs](../src/scan_control/tests.rs):

- "cancellation_before_and_during_collection_joins_workers_without_publication":
  before-start and first-merge Stop with 1/2/4/8 workers.
- "accounting_and_serialization_cancellation_remove_only_owned_staging": deterministic
  checkpoints in both long prepublication phases and temporary-file cleanup.
- "controlled_counts_are_monotonic_and_disabled_scans_keep_snapshot_bytes": counts,
  no-control behavior, byte-identical output and single-use protection.
- "old_destination_and_concurrent_no_clobber_survive": old bytes and publication race.
- "stop_and_commit_arbitrate_and_postpublication_errors_are_truthful": atomic race
  and modeled postpublication I/O error state (not injected real fsync failure).
- "bridge_control_polls_and_stops_independently_of_constructor": blocked collector,
  independent polling/Stop, typed bridge cancellation and no publication.

[tests/bridge-smoke.swift](../tests/bridge-smoke.swift) exercises generated control,
pre-cancellation, Complete/count conversion and too-late Stop. Uninterruptible kernel
calls, actual durability failures, hostile namespace races and crash cleanup remain
untested. Existing trusted-destination requirements still apply.
