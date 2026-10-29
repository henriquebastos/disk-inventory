# 1 Native explorer

The [SwiftUI/AppKit app](../native/Explorer/ExplorerApp.swift) presents the
[generated Rust bridge](bridge.md). It has no WebView, domain subprocess, second
inventory, or Swift accounting/layout implementation. The CLI remains unchanged.

## 1a Build and launch

Use installed Xcode, Swift 6, XcodeGen and the locked Rust dependencies. The build
targets macOS 26, matching the installed Rust standard-library archive;
older macOS and Intel are unverified. No installation or signing identity is needed.
Choose an absolute artifact root outside the repository:

```sh
G=/absolute/external/gui
bash scripts/build-gui.sh "$G"
bash scripts/test-gui.sh "$G"
open "$G/DerivedData/Build/Products/Debug/DiskInventory.app"
```

[Build](../scripts/build-gui.sh) regenerates UniFFI and the Xcode project from
[project.yml](../native/project.yml) and builds the app and tests. actool compiles
[AppIcon.icon](../native/Explorer/AppIcon.icon) into `Assets.car` and `AppIcon.icns`;
[a check](../scripts/check-app-icon.sh) requires them and `CFBundleIconName`.
Products, bindings, caches and results go under G; macOS/Xcode keep
system-managed state elsewhere.

For native-free exploration:

```sh
open -n "$G/DerivedData/Build/Products/Debug/DiskInventory.app" \
  --args --fixture-mode --scenario dix
```

Normal launch scans nothing. Choose Folder uses a native directory panel for an
explicit root, then saves to app-managed Application Support storage. Reopen opens the
last folder's saved inventory offline. The user never opens a snapshot file. Picker
URLs use filesystem byte representations, not display paths. Scan progress, Stop, retention and tests are in
[native-lifecycle.md](native-lifecycle.md). No save panel or automatic scan is used.

## 1b Navigation and presentation

Contents is a virtual NSTableView with real disclosure buttons and outline/row
accessibility semantics. Rust owns sparse expansion state and size-descending
virtual row addressing; Swift caches one slice of at most 256 rows. Native datasource
callbacks use cached records only, scheduling missing slices asynchronously. There
are no Previous/Next pages. Right/left arrows expand/collapse or move to child/parent.
Disclosure never zooms. Map clicks reveal a descendant by expanding its ancestors;
directory double-click, Return or Open Selected Directory (Command-Down) changes both
tree and map root; Enclosing Directory (Command-Up) focuses the parent. Menus,
shortcuts and context menus are specified in [native-commands.md](native-commands.md).
Each row shows a decorative 9-point type swatch and a 44-point usage bar before the
right-aligned human-readable size. Directories use a system-gray rounded square. Other entries use a
circle in the base color of their map tile, which Rust sends as `OutlineRow.map_rgb`.
The bar shows saved subtree bytes as an integer percent of the focus total, rounded
half up. Nonzero entries keep a 2% sliver. Zero and unknown usage show an empty track.
VoiceOver ignores the swatch and the bar. The size column keeps the accessible value.
Its label has the same centered frame as the name, because a table cell fills the row.
The table uses the inset style, so its background is the opaque system content color.
Colors follow light, dark and Increase Contrast ([native-appearance.md](native-appearance.md)).

Breadcrumb navigation retains at most 64 per-directory sparse Rust tree handles,
focus/selection keys and scroll positions, never row pages or bitmap history.
Contexts survive navigation in both directions; there is no Back-stack UI. Root
breadcrumbs use the saved root basename (or `/`) with full-path help, including
ancestor and truncated-path fallback breadcrumbs. It restores context,
rebuilds obsolete trees off-main, and clamps scroll positions. Replacement and
mutation recovery discard history. Breadcrumbs retain at most 64 ancestors; deeper
paths truncate older ancestors, not the inventory root label. Tiny, zero-attribution
and shared entries remain reachable in the tree.

The map displays an immutable Rust squarified, flat-gradient bitmap with saved-name
type colors. Placement, refinement, pixel ownership, bounds and tests are
specified in [native-diagram.md](native-diagram.md). Click links selection between
tree and map; no directory header covers file pixels. The card of an unresolved aggregate
shows only its size and offers directory navigation, never file removal. The status bar,
the outcome banner, the selection dim, Esc and refresh progress are specified in
[native-status.md](native-status.md).

There is no inspector pane. A compact [card](../native/Explorer/SelectionCard.swift) below the tree shows the selected
name/path, its size (directory subtree or file accounted allocation),
the direct-item count of a directory, and Reveal in Finder, Move to Trash… and Delete… actions
with the same enable rules as the menu bar.
Collapsing ancestors preserves the action target; clicking the card name reveals
its row without zooming. Finder URLs use saved raw bytes, not the display string.
The card has no accounting or sharing note. Storage uses decimal KB through EB and the system locale, with at most one decimal place.
[NativeNumberFormat.swift](../native/Explorer/NativeNumberFormat.swift) reuses Foundation formatters and scales exact UInt64 values through Decimal.
[NativeNumberFormatTests.swift](../native/ExplorerModelTests/NativeNumberFormatTests.swift):
"testDecimalStorageUsesLocaleAndPreservesUnsignedRange" checks units, grouping, zero and UInt64.max in en_US and pt_BR.
"testVisibleTreeSizeUsesInjectedLocaleWithoutChangingAccounting" checks size cells against exact counts.
Counts use locale grouping and the singular for one ("1 scan error"). Confirmations omit sizes instead of implying reclaimable space. The
header shows the scope size alone; its Partial, Incomplete and Not saved badges stay. Detailed
errors stay behind a disclosure.

## 1c Asynchronous ownership and operations

[ExplorerModel](../native/Explorer/ExplorerModel.swift) and its role extensions and component
states are specified in [native-state.md](native-state.md). The model publishes selection before
running synchronous bridge calls in detached tasks. Ordinary selection and navigation
use saved data only: the GUI never calls liveMetadata. Path, bitmap, hover/click and selection-region requests are bounded/coalesced.
Tree requests serialize mutations and coalesce reads/reveals. Session/selection/view generations reject obsolete
results; resize requests debounce 180ms. A separate replacement state keeps the
retained previous view read-only until installation completes, even if an old view
request finishes first. Recovery checks navigation as well as session generation.
Busy feedback overlays the split view instead of inserting a row: preparing a new
frame must not change the viewport that requested it. Swift retains current bounded
views, selection, sparse navigation history and
operation diagnostics, not the inventory. Hover/selection never rebuild the diagram.

Trash and permanent deletion prepare off-main and keep the PreparedAction for a
separate native alert sheet. Its keys, pins and protections are specified in
[native-commands.md](native-commands.md).

The outcome banner distinguishes success, failed, partial and indeterminate results; its
texts are in [native-status.md](native-status.md). Issues remain in its session log.
Only current views/status are requested after core reconciliation; the snapshot is
not reopened, rescanned or rewritten. Invalid focus recovers to a known live ancestor. Successful removal uses bounded
result motion; failed/partial/uncertain outcomes never animate whole-target success.
Refresh Directory always refreshes the focused subtree in memory, not the selection,
with the scan's progress and Stop.

## 1d Executable evidence

[ExplorerUITests.swift](../native/ExplorerTests/ExplorerUITests.swift) runs the compiled
app against real generated Rust sessions and stateful MemoryFileSystem scenarios:

- "testDisclosureKeyboardZoomBreadcrumbAndUsage": disclosure versus zoom,
  double-click/breadcrumbs, arrow-key selection, recorded usage and restored native scroll
  position while the selected directory remains above the visible viewport.
- "testConfirmationCancelDeleteAndStaleHandleRecovery": cancellation, confirmed
  deletion, disappeared target, dirty inventory and root protection.
- "testUnknownTrashScopeIssueOpensFromTheDetailsChevron": the chevron opens Details.
- "testImmediateSavedOnlySelection": later selection during the
  latency scenario; XCUITest timing includes automation waits, not paint latency.
- "testFixtureModeFailsClosed": absent/unknown scenarios cannot enable native pickers.
- "testTreeSizeTextCentersWithNameOnSelectedAndUnselectedRows": the drawn size text and
  name share a vertical center within 1 point on a selected and an unselected row.
- "testDirectoryConfirmationsKeepOnlyTargetScopeAndWarnings": both action scopes,
  named title, scope, the Delete warning, no Trash space sentence; no entry-only sizes/hex.
- "testDenseMapHoverClickRevealAndTinyDirectoryZoom": independent hover, linked
  descendant reveal without zoom, disclosure and 4/8 KiB zoom visibility. Collapse
  assertions await asynchronous row publication, not just input delivery.
- "testLongDirectoryPathAndSimpleConfirmationAtMinimumWindow": direct double-click
  from an unselected row, full long target and fixed controls at minimum window size.
- "testLocalizedStorageInTreeSelectionAndConfirmation": en_US and pt_BR storage presentation.

[OperationOutcomeModelTests.swift](../native/ExplorerModelTests/OperationOutcomeModelTests.swift)
checks Trash totals, failed, indeterminate and partial outcomes, the unknown Trash scope,
stale targets, unknown allocations, saved-only selection and the poof. Rendered motion is
untested; the fixture-only `motion-style` probe stays for manual checks.

Fixture mode shows "SIMULATED" only in the window title; other content matches production.
"testFixtureModeNamesSimulationOnlyInWindowTitle" checks the window and its confirmation.
"testOnlyFixtureWindowTitleNamesSimulation" in
[RedesignModelTests.swift](../native/ExplorerModelTests/RedesignModelTests.swift) checks the production title.
Command, shortcut and confirmation tests are listed in [native-commands.md](native-commands.md). `--fixture-mode`,
`--scenario`, or `DI_UI_TEST` locks the app into fixture-only mode; incomplete or
unknown configuration is an error, never a native fallback.

[ExplorerModelTests.swift](../native/ExplorerModelTests/ExplorerModelTests.swift):

- "testImmediateSelectionWhileRustBusyDiscardsObsoletePath" measures synchronous
  publication while a test explicitly holds the core metadata lock, rejecting obsolete paths.
- "testSessionReplacementDiscardsOldSelectionAndViews" and
  "testLaterFocusWinsWhileBridgeIsBusy" exercise generation boundaries.
- "testSelectionAndNavigationUseSavedDataWithoutLiveMetadata" checks indexed path
  and directory publication below the fixture's one-second live-metadata delay;
  this is not GUI paint timing.
- "testCancelPendingPreparationAndRootProtection" covers cancellation during preparation.
- "testStaleFocusRecoversAndRollupIsNotAnActionTarget" checks invalid keys and rollups.
- "testFixtureModeRejectsAbsentAndUnknownConfiguration" checks closed constructors.
- "testReplacementBlocksRetainedViewActionsUntilInstallation" reproduces old-view
  completion during a gated replacement; preparation is rejected without mutation.
- "testReplacementCancelsPreparedPinBeforeInstallingNewSession" checks that a
  retained real action is consumed by cancellation, not merely hidden.
- "testStalePreparationCompletionCannotPublishAfterReplacement" awaits actual
  delayed preparation completion and rejects an obsolete confirmation.
- "testSuspendedRecoveryDoesNotOverwriteLaterNavigation" overlaps recovery and
  navigation behind the real delayed metadata lock.
- "testResizeDebounceDuringDeletedSelectionRecoveryCannotRestoreStaleActions" overlaps
  the real resize debounce with delayed recovery of a deleted selection.

Fixture isolation is tested by "presentation_and_delay_fixtures_are_isolated" in
[src/bridge/tests.rs](../src/bridge/tests.rs).
"visual_details_fixture_has_nested_groups_and_long_directory_confirmation" in the
same file verifies nested groups, long paths, entry-only sizes and cancelled pins.
The original >2^53 fixture is unchanged.

Untested limits: real Trash, native GUI picker lifecycle, hostile namespace races,
full VoiceOver traversal (the tree is the exhaustive accessible alternative),
large-inventory GUI paint latency,
and cancellation of destructive executing work (unsupported). The additional native model/geometry tests
are linked from [native-diagram.md](native-diagram.md); offscreen callback tests
do not substitute for foreground input/screenshot acceptance. XCUITest requires an unlocked interactive
console; do not change security settings to force automation.
