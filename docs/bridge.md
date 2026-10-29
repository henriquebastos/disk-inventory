# 1 Generated Swift bridge

The optional `bridge` feature exposes [the session facade](../src/bridge/mod.rs)
using UniFFI **=0.32.2** proc-macro library metadata, not UDL or a handwritten ABI.
Default CLI/core builds do not enable UniFFI. `bridge-build` also enables
its generator CLI. The library produces rlib/staticlib. All bridge methods are synchronous.

## 1a Build and consume

With Rust, Swift 6 and Xcode installed, choose an external artifact directory:

```sh
bash scripts/build-bridge.sh /absolute/external/bridge
```

[Build](../scripts/build-bridge.sh) uses locked/offline Cargo (an exported
`CARGO_TARGET_DIR`, else `target` in the directory), generates Swift, header and
modulemap from the release archive, then compiles/links
[the Swift smoke client](../tests/bridge-smoke.swift) in Swift 6 language mode.
[check.sh](../scripts/check.sh) runs the bridge tests, Clippy and the smoke client
([checks.md](checks.md)). Fetch locked dependencies first if they are not local.
Generated products and compiler caches stay in the supplied directory, outside Git.

Products: `generated/disk_map_bench.swift`, `disk_map_benchFFI.h` and
`module.modulemap` (the latter two also under `generated`), `libdisk_map_bench.a`
(a copy of the release archive, made only when it changed), and `bridge-smoke`.
Compile generated Swift into the client target; include the generated directory
for the `disk_map_benchFFI` module and link the archive plus Foundation. No
installation or checked-in generated code is needed.

Generated entry points:

```swift
ExplorerSession.openSnapshot(snapshotPath: Data) throws -> ExplorerSession
ExplorerSession.create(sourceRoot: Data, snapshotPath: Data,
                       workers: UInt32) throws -> ExplorerSession
ExplorerSession.createControlled(sourceRoot: Data, snapshotPath: Data,
    workers: UInt32, control: ScanControl) throws -> ExplorerSession
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
`prepare(key:action:)`, `execute(action:)`, `executeControlled(action:control:)`,
`refreshDirectory(key:)`, `refreshDirectoryControlled(key:control:)` (all throwing),
and nonthrowing `isBusy()`, `activeCallCount()`, `selectionQueryCount()`. Records are defined in
[records.rs](../src/bridge/records.rs). Byte arrays generate **Data**, u64 generates
**UInt64**, and raw paths remain authoritative; display names alone are lossy.
Errors generate `BridgeError` cases including `InvalidEntry`, `WrongSession`,
`ConsumedAction`, `Cancelled`, `PermissionDenied`, `NotFound`, `InvalidInput`, `Io`, `Internal`.

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
preserve removed, removed with skips, trashed, failed, partial (with `stopped`) and
indeterminate; removals carry a `RemovalRecord` of counts and at most 16 reasons. Scope
is inside/outside/unknown; its subtraction is not disk space reclaimed.

The session mutex serializes all saved reads and live operations. Dispatch calls,
including constructors, off the main thread. `isBusy()` reads an independent
atomic count of queued/running calls without acquiring that mutex; retain the
last visible records while busy. For controlled creation, construct `ScanControl()`
before dispatch; `progress()` and `cancel()` never acquire session locks. See the
[phase/publication contract](scan-control.md) for exact semantics and tests. Other
constructors have no progress handle. `activeCallCount()` exposes that
queued/running count. `selectionQueryCount()` counts saved-selection calls actually
entered under the backend lock, including invalid keys, not merely dispatched work.
These atomic diagnostics are not lock barriers. "presentation_and_delay_fixtures_are_isolated"
in [src/bridge/tests.rs](../src/bridge/tests.rs) and the parent-request tests in
[StaleWorkRecoveryTests.swift](../native/ExplorerModelTests/StaleWorkRecoveryTests.swift)
check them. There are no callbacks or async Rust methods; Sendable handles still block.

`prepare` returns a Rust-owned `PreparedAction` retaining the actual core pin.
`details()` returns fresh confirmation metadata, action, key and raw path.
`cancel()` drops the pin; dropping the last action reference also releases it.
`execute` consumes once even on a same-session validation error. Cross-session
attempts reject without consuming. `executeControlled` reports phases and removed items
through a `ScanControl`; only deletion stops. Native safety/namespace-race limits remain
those in [operations.md](operations.md).

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

The scenarios of the explicit fixture constructor are listed in [fixtures.md](fixtures.md).
[src/bridge/tests.rs](../src/bridge/tests.rs) names the invariants:

- "presentation_and_delay_fixtures_are_isolated": only `metadata-delay` delays metadata.
- "visual_details_fixture_has_nested_groups_and_long_directory_confirmation": nested groups,
  long target paths, directory-entry-only sizes and pin release on cancellation.
- "saved_views_are_bounded_native_free_and_byte_exact": zero adapter calls for views.
- "confirmation_pins_cancel_drop_replay_and_cross_session_are_real": pin lifecycle.
- "changed_after_prepare_consumes_action_without_mutating_replacement": stale target.
- "concurrent_execution_consumes_one_confirmation_exactly_once": serialized execution.
- "busy_poll_does_not_take_the_session_lock": independent busy access.
- "fixture_trash_scopes_failures_and_partial_updates_survive_conversion": outcomes.
- "fixture_errors_fail_closed_and_unknown_allocation_stays_explicit": uncertainty.
- "presentation_trash_inside_moves_a_visible_tile_to_a_visible_destination": the moved
  entry keeps its key and has a materially separated actionable region in the new frame.
- "presentation_trash_late_target_has_a_region_outside_accessibility_targets": a separate fixture covers bounded-target omissions.
- "native_snapshot_open_never_requires_the_recorded_source": partial offline snapshot.
- "update_issue_transfer_has_an_explicit_bound": diagnostic truncation count.
- "invalid_bridge_requests_return_typed_errors_without_source_calls": input validation.
- "paused_operation_fixture_holds_each_stage_counts_removals_and_stops" and
  "operation_fixtures_trash_quickly_and_skip_with_reasons": phases, counts, Stop, skips.

[prototype_parity_tests.rs](../src/bridge/fixture/prototype_parity_tests.rs) checks
`prototype-home`. The fixture ports the prototype's seed-11 Park-Miller generator
(`s * 16807 % 2147483647`, weights `r^2.4 + 0.015`, JavaScript rounding) in call order.

- "prototype_home_fixture_rebuilds_the_prototype_tree_exactly": 542 entries, 516 files,
  236,900,003,996 bytes, and a path-and-size checksum equal to the prototype's own `data()`.
- "prototype_home_extensions_get_the_prototype_kind_colors": every file gets its kind color.

"prototype_home_map_shows_every_kind_color_and_presentation_stays_gray" in
[map_pixels.rs](../src/bridge/tests/map_pixels.rs) measures all eight colored kinds on the
`prototype-home` map, and a gray `presentation` map, in light and dark.

The Swift smoke exercises these conversions and operation flows, plus one owned
one-file create followed by unavailable-source open, never native Trash or deletion. Native GUI/XCUITest behavior
is documented in [native-explorer.md](native-explorer.md). Native Trash, hostile
namespace races, non-macOS and Intel linking are untested here.

## Native presentation views

`ExplorerSession.tree` returns a sparse `ExplorerTree` with bounded `rows`, `expand`
and `reveal`, plus read-only `visible_row` (Swift `visibleRow`) for a selected
key's optional position without opening collapsed ancestors.
Each `OutlineRow` includes optional `map_rgb` (Swift `mapRgb`), packed as `0xRRGGBB`.
Files use the map's base type color, folder rule included. Directories have no color value.
"outline_swatch_colors_match_map_file_tiles_and_directories_have_none" in
[src/bridge/tests.rs](../src/bridge/tests.rs) checks this field.
`diagram` takes a `MapAppearance` (light, dark, light or dark Increase Contrast; a mirror
of the core enum) and returns an immutable `DiagramFrame` with flat sRGB RGBA `bitmap`,
owner `hit`, selection `region` and bounded accessibility `targets`. Neither view
is an action capability. Execution/refresh revisions reject obsolete queries.
Bounds, payload-versus-RSS distinctions and exact tests are specified in
[native-diagram.md](native-diagram.md).
