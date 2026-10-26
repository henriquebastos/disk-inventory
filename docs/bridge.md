# 1 Generated Swift bridge

The optional `bridge` feature exposes [the session facade](../src/bridge/mod.rs)
using UniFFI **=0.32.2** proc-macro library metadata, not UDL or a handwritten ABI.
Default CLI/core builds do not enable UniFFI. `bridge-build` additionally enables
its generator CLI. The library produces rlib/staticlib; the existing CLI and
benchmark contracts are unchanged. All bridge methods are synchronous.

## 1a Build and consume

With Rust, Swift 6 and Xcode installed, choose an external artifact directory:

```sh
bash scripts/build-bridge.sh /absolute/external/bridge
bash scripts/test-bridge.sh /absolute/external/bridge
```

[Build](../scripts/build-bridge.sh) uses locked/offline Cargo, generates Swift,
header and modulemap from the release archive, then compiles/links
[the Swift smoke client](../tests/bridge-smoke.swift) in Swift 6 language mode.
[Test](../scripts/test-bridge.sh) runs default/bridge tests, formatting, strict
Clippy for default/bridge/build-tool configurations, and the executable. Fetch
locked dependencies first if unavailable locally. Generated products, compiler
caches and new owned fixtures stay in the supplied directory, outside Git.
Existing core tests retain their established self-cleaning temporary paths.

Products: `generated/disk_map_bench.swift`, `disk_map_benchFFI.h` and
`module.modulemap` (the latter two also under `generated`),
`target/release/libdisk_map_bench.a`, and `bridge-smoke`.
Compile generated Swift into the client target; include the generated directory
for the `disk_map_benchFFI` module and link the archive plus Foundation. No
installation or checked-in generated code is needed.

Generated entry points:

```swift
ExplorerSession.openSnapshot(snapshotPath: Data) throws -> ExplorerSession
ExplorerSession.create(sourceRoot: Data, snapshotPath: Data,
                       workers: UInt32) throws -> ExplorerSession
ExplorerSession.fixture(scenario: String) throws -> ExplorerSession
```

Create reuses `Inventory::create` and its worker validation/publication semantics.
It scans once, drops that inventory, then reopens/decodes the saved snapshot and
builds the native session indexes. That additional eager read/accounting/indexing
is startup cost, not a second source scan. No persistence method or automatic
save/refresh is exposed. Open pins the snapshot without validating its source.

## 1b Calls, bounds and ownership

`ExplorerSession` methods are `status()`, `children(parent:offset:limit:)`,
`selection(key:)`, `layout(focus:request:)`, `liveMetadata(key:)`,
`prepare(key:action:)`, `execute(action:)`, `refreshDirectory(key:)` (all throwing),
and nonthrowing `isBusy()`. Records are defined in
[records.rs](../src/bridge/records.rs). Byte arrays generate **Data**, u64 generates
**UInt64**, and raw paths remain authoritative; display names alone are lossy.
Errors generate `BridgeError` cases including `InvalidEntry`, `WrongSession`,
`ConsumedAction`, `PermissionDenied`, `NotFound`, `InvalidInput`, `Io`, `Internal`.

`EntryKey` is an opaque saved handle; compare with `sameEntry(other:)`. It is not
an action capability. Parent keys are returned with rows; selection does not
change focus. There is no navigation policy or full-inventory transfer. Pages
allow 1–1024 rows, layouts 1–4096 total tiles plus groups and depth at most 64.
Rollups are not actionable entries; groups are overlays, not additional usage.
Update responses transfer at most 64 issues, with an explicit `issuesOmitted`
count; individual names, paths and issue strings retain core-dependent lengths.
Work counters expose examined rows/layout children and reconciliation work.
Storage diagnostics count arena slots including tombstones, not live entries.

Status preserves original `scanPartial`/scan counters and live `dirty`/`stale`.
Update/operation records carry issues and work. Retain those diagnostics in the
client. Unknown hardlink groups can have positive raw allocation and zero
attribution: stale totals are partial, never measured zero usage. Mutation enums
preserve removed, trashed, failed, partial and indeterminate; destination scope
preserves inside/outside/unknown. Scope subtraction is not disk space reclaimed.

The session mutex serializes all saved reads and live operations. Dispatch calls,
including constructors, off the main thread. `isBusy()` reads an independent
atomic count of queued/running calls without acquiring that mutex; retain the
last visible records while busy. Constructors have no handle to poll until they
return, so callers own their loading indicator. There are no callbacks or async
Rust methods. Generated handles are Sendable; this does not make calls nonblocking.

`prepare` returns a Rust-owned `PreparedAction` retaining the actual core pin.
`details()` returns fresh confirmation metadata, action, key and raw path.
`cancel()` drops the pin; dropping the last action reference also releases it.
`execute` consumes once even on a same-session validation error. Cross-session
attempts reject without consuming. Cancellation cannot abort an already claimed
execution. Native safety/namespace-race limits remain those in
[operations.md](operations.md).

```swift
// Run inside a worker/task, not directly in a main-thread event handler.
let session = try ExplorerSession.fixture(scenario: "ordinary")
let root = try session.status().root.key
let page = try session.children(parent: root, offset: 0, limit: 100)
let selected = try session.selection(key: page.entries[0].key) // saved only
let live = try session.liveMetadata(key: selected.entry.key)   // explicit I/O
let pending = try session.prepare(key: selected.entry.key, action: .trash)
let confirmation = pending.details() // present before an explicit decision
try pending.cancel()                // or execute(action:) after confirmation
```

## 1c Native-free scenarios and evidence

The explicit fixture constructor always uses the stateful `MemoryFileSystem`
with real Rust explorer/layout/accounting/operations. Unknown names fail closed;
no path instantiates the native adapter. `status().simulated` remains true.
Discover entries through bounded queries: `small-files/small-00` through
`small-15`, `large-file` (2^53+123 allocated bytes), `zero-byte`, `hardlink-a`,
`hardlink-b`, `trash`, and raw bytes `raw-` followed by FF.

| Scenario | Behavior/target |
|---|---|
| `presentation` | Balanced 4096-byte large file and 128 small children for native UI pagination |
| `metadata-delay` | Presentation inventory; only large-file MemoryFileSystem metadata sleeps one second |
| `ordinary`, `trash-outside` | Trash moves to `/simulated-outside/moved` |
| `trash-inside` | Moves to `trash/moved` within scope |
| `metadata-failure` | `large-file` metadata denied; selection still works |
| `permission-failure` | `small-files` enumeration denied; removal fails unchanged |
| `changed-target` | Live `large-file` identity differs from saved |
| `partial-deletion` | Removing `small-files` fails after one unlink; enumeration denied |
| `trash-unknown`, `trash-missing` | Unknown scope or missing returned destination |
| `trash-failure` | Guaranteed unchanged failed Trash |
| `unknown-allocation` | Refresh root adds conflicting `unknown-a`/`unknown-b`; unattributed/stale |

[src/bridge/tests.rs](../src/bridge/tests.rs) names the invariants:

- "presentation_and_delay_fixtures_are_isolated": original scenarios unchanged; delay default-off.
- "saved_views_are_bounded_native_free_and_byte_exact": zero adapter calls for views.
- "confirmation_pins_cancel_drop_replay_and_cross_session_are_real": pin lifecycle.
- "changed_after_prepare_consumes_action_without_mutating_replacement": stale target.
- "concurrent_execution_consumes_one_confirmation_exactly_once": serialized execution.
- "busy_poll_does_not_take_the_session_lock": independent busy access.
- "fixture_trash_scopes_failures_and_partial_updates_survive_conversion": outcomes.
- "fixture_errors_fail_closed_and_unknown_allocation_stays_explicit": uncertainty.
- "native_snapshot_open_never_requires_the_recorded_source": partial offline snapshot.
- "update_issue_transfer_has_an_explicit_bound": diagnostic truncation count.
- "invalid_bridge_requests_return_typed_errors_without_source_calls": input validation.

The Swift smoke exercises these generated conversions and operation flows, plus
one explicitly owned one-file create followed by unavailable-source open. It
never requests native Trash or permanent deletion. Native GUI/XCUITest behavior
is documented in [native-explorer.md](native-explorer.md). Native Trash, hostile
namespace races, non-macOS and Intel linking remain untested here.
