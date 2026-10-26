# 1 Native explorer

The [SwiftUI/AppKit app](../native/Explorer/ExplorerApp.swift) presents the
[generated Rust bridge](bridge.md). It has no WebView, domain subprocess, second
inventory, or Swift accounting/layout implementation. The CLI remains unchanged.

## 1a Build and launch

Use installed Xcode, Swift 6, XcodeGen and the locked Rust dependencies. The local
build targets macOS 26 to match the installed Rust standard-library archive;
older macOS and Intel are unverified. No installation or signing identity is needed.
Choose an absolute artifact root outside the repository:

```sh
G=/absolute/external/gui
bash scripts/build-gui.sh "$G"
bash scripts/test-gui.sh "$G"
open "$G/DerivedData/Build/Products/Debug/DiskInventory.app"
```

[Build](../scripts/build-gui.sh) regenerates UniFFI and the Xcode project from
[project.yml](../native/project.yml), then builds the app and tests. All requested
build products, bindings, module caches and results go under G. macOS/Xcode can
also maintain their own system-managed application/automation state.

For native-free manual exploration:

```sh
open -n "$G/DerivedData/Build/Products/Debug/DiskInventory.app" \
  --args --fixture-mode --scenario presentation
```

Normal launch scans nothing. Open Snapshot reads saved data without checking its
source. Create Inventory uses native directory/save panels for an explicit root
and new snapshot destination. Existing destinations are never deleted or replaced;
core create scans once and reopens the new snapshot. Picker URLs use filesystem
byte representations, not display paths. Native chooser workflows are not covered
by automated GUI tests; the generated bridge smoke covers owned create/offline open.

## 1b Navigation and presentation

Contents is an NSTableView with 100-entry core pages, keyboard selection and visible
Previous/Next controls. It is not a locally sorted substitute for the whole directory.
Single click selects; double-click directories or Focus This Directory navigates.
Back retains at most 64 focus keys. Breadcrumbs retain at most 64 ancestors; deeper
paths truncate older ancestors, not the inventory root label. Root and focus are
separate. Tiny/zero-attribution entries remain reachable through Contents.

The AppKit treemap draws only Rust-returned rectangles: at most 160 tiles plus
groups, depth eight. Borders/related colors identify directory groups; group
labels overlay area and never add bytes. Rollups select an explanation and a
Show Directory Contents action, never a deletion target.

The inspector separates saved inventory bytes from requested live logical size,
allocation, timestamps and identity. Integer formatting never passes byte counts
through Double. After reconciliation it labels inventory values as not saved,
rather than claiming they are still original snapshot values. Partial/stale/dirty
and simulated indicators remain visible. Zero attribution is not proof of zero
usage; allocation is not guaranteed reclaimable space.

The design applies Laws of UX: Jakob to native selection/navigation and panels;
Fitts to the table alternative; Hick to two startup choices and separate action
confirmation; Common Region/Similarity to directory boundaries/colors; Doherty to
immediate local highlight, indeterminate work feedback and retaining the prior view.

## 1c Asynchronous ownership and operations

[ExplorerModel](../native/Explorer/ExplorerModel.swift) publishes selection before
running synchronous bridge calls in detached tasks. Metadata has one active and
one replaceable queued request. Session/selection/view generations reject obsolete
results; resize requests debounce 180ms. Swift retains only current bounded views,
selection, small navigation history and operation diagnostics, not the inventory.

Trash and permanent deletion prepare off-main and retain the actual PreparedAction
through a separate confirmation with fresh metadata, target path and byte-exact hex.
Cancel, window close and session replacement release pending pins. Root operations
are visibly disabled and remain protected by Rust. Executing operations cannot be
cancelled; there is no Trash-to-delete fallback or permanent-delete Undo.

Outcomes distinguish successful, failed, partial and indeterminate results, including
inside/outside/unknown Trash scope. Issues remain in an expandable session log.
Only current views/status are requested after core reconciliation; the snapshot is
not reopened, rescanned or rewritten. Invalid focus recovers to a known live ancestor.

## 1d Executable evidence

[ExplorerUITests.swift](../native/ExplorerTests/ExplorerUITests.swift) runs the compiled
app against real generated Rust sessions and stateful MemoryFileSystem scenarios:

- "testSelectionNavigationPaginationAndInspector": click versus focus, double-click,
  breadcrumbs/Back, second page, arrow-key selection and saved/live inspector.
- "testConfirmationCancelDeleteAndStaleHandleRecovery": cancellation, confirmed
  deletion, disappeared target, dirty inventory and root protection.
- "testTrashInsideAndOutside": real prepared Trash, changed views and scope totals.
- "testFailuresPartialUnknownAndMetadataError": failed/indeterminate/partial outcomes,
  survivors, stale state and unavailable live metadata.
- "testChangedTargetAndUnknownAllocation": stale target preparation and unknown
  allocations after explicit refresh.
- "testImmediateSelectionAndObsoleteMetadataDiscarded": later selection during the
  latency scenario; XCUITest timing includes automation waits, not paint latency.
- "testFixtureModeFailsClosed": absent/unknown scenarios cannot enable native pickers.

Every destructive UI flow first asserts the simulated indicator. `--fixture-mode`,
`--scenario`, or `DI_UI_TEST` locks the app into fixture-only mode; incomplete or
unknown configuration is an error, never a native fallback.

[ExplorerModelTests.swift](../native/ExplorerModelTests/ExplorerModelTests.swift):

- "testImmediateSelectionWhileRustBusyDiscardsObsoleteMetadata" measures synchronous
  publication while the real bridge is busy, polling to reject obsolete metadata.
- "testSessionReplacementDiscardsOldMetadataAndViews" and
  "testLaterFocusWinsWhileBridgeIsBusy" exercise generation boundaries.
- "testCancelPendingPreparationAndRootProtection" covers cancellation during preparation.
- "testStaleFocusRecoversAndRollupIsNotAnActionTarget" checks invalid keys and rollups.
- "testFixtureModeRejectsAbsentAndUnknownConfiguration" checks closed constructors.

Fixture isolation is tested by "presentation_and_delay_fixtures_are_isolated" in
[src/bridge/tests.rs](../src/bridge/tests.rs). The original >2^53 fixture is unchanged.

Untested limits: real Trash, native GUI picker lifecycle, hostile namespace races,
VoiceOver traversal of the drawing (the table is the accessible alternative),
light-mode/minimum-window screenshot review, large-inventory GUI paint latency,
and cancellation of executing work. XCUITest requires an unlocked interactive
console; do not change security settings to force automation.
