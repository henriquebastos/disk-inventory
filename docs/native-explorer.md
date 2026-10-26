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
Single click selects; double-click directories or Open Directory navigates.
Back retains at most 64 focus keys. Breadcrumbs retain at most 64 ancestors; deeper
paths truncate older ancestors, not the inventory root label. Root and focus are
separate. Tiny/zero-attribution entries remain reachable through Contents.

The AppKit treemap draws only Rust-returned rectangles: at most 160 tiles plus
groups, depth eight. Borders/related colors identify directory groups; group
labels overlay area and never add bytes. Selected groups have an outline and an
accented “Selected” header, without changing geometry. Occluded headers are omitted,
with selection taking precedence; visible headers share drawing, mouse and
accessibility hit regions. Rollups select an explanation and a
Show Directory Contents action, never a deletion target.

There is no inspector pane. A compact strip shows the selected name/path, one
recorded usage measure (directory subtree or file accounted allocation), and
Open Directory/Trash/Delete actions. Sharing or unknown-size caveats appear when
needed. Integer formatting never passes byte counts through Double. Partial,
incomplete, changed and simulated indicators remain visible. Recorded usage is
not guaranteed reclaimable space; detailed errors stay behind a disclosure.

The design applies Laws of UX: Jakob to native selection/navigation and panels;
Fitts to the table alternative; Hick to two startup choices and separate action
confirmation; Common Region/Similarity to directory boundaries/colors; Doherty to
immediate local highlight, indeterminate work feedback and retaining the prior view.

## 1c Asynchronous ownership and operations

[ExplorerModel](../native/Explorer/ExplorerModel.swift) publishes selection before
running synchronous bridge calls in detached tasks. Ordinary selection and navigation
use saved data only: the GUI never calls liveMetadata. Selected-path lookup has one
active and one replaceable queued request. Session/selection/view generations reject obsolete
results; resize requests debounce 180ms. A separate replacement state keeps the
retained previous view read-only until installation completes, even if an old view
request finishes first. Recovery checks navigation as well as session generation.
Swift retains only current bounded views,
selection, small navigation history and operation diagnostics, not the inventory.

Trash and permanent deletion prepare off-main and retain the actual PreparedAction
through a separate confirmation. Rust still validates fresh metadata, raw paths and
identity pins internally. Presentation shows only the target, directory-and-contents
scope, relevant warnings and Cancel/named-action buttons, not hex or low-level
metadata. Short confirmations fit their content; long paths can scroll within a
bounded region while warnings and buttons remain outside it.
Cancel, window close and session replacement release pending pins; replacement
awaits cancellation before installing a new session. Root operations
are visibly disabled and remain protected by Rust. Executing operations cannot be
cancelled; there is no Trash-to-delete fallback or permanent-delete Undo.

Outcomes distinguish successful, failed, partial and indeterminate results, including
inside/outside/unknown Trash scope. Issues remain in an expandable session log.
Only current views/status are requested after core reconciliation; the snapshot is
not reopened, rescanned or rewritten. Invalid focus recovers to a known live ancestor.

## 1d Executable evidence

[ExplorerUITests.swift](../native/ExplorerTests/ExplorerUITests.swift) runs the compiled
app against real generated Rust sessions and stateful MemoryFileSystem scenarios:

- "testSelectionNavigationPaginationAndUsage": click versus focus, double-click,
  breadcrumbs/Back, second page, arrow-key selection and recorded usage.
- "testConfirmationCancelDeleteAndStaleHandleRecovery": cancellation, confirmed
  deletion, disappeared target, dirty inventory and root protection.
- "testTrashInsideAndOutside": real prepared Trash, changed views and scope totals.
- "testFailuresPartialUnknownAndSavedOnlySelection": failed/indeterminate/partial outcomes,
  survivors, incomplete state and selection despite unavailable live metadata.
- "testChangedTargetAndUnknownAllocation": stale target preparation and unknown
  allocations after explicit refresh.
- "testImmediateSavedOnlySelection": later selection during the
  latency scenario; XCUITest timing includes automation waits, not paint latency.
- "testFixtureModeFailsClosed": absent/unknown scenarios cannot enable native pickers.
- "testDirectoryConfirmationsKeepOnlyTargetScopeAndWarnings": both action scopes,
  explicit warnings, cancellation, and absence of misleading entry-only sizes/hex.
- "testGroupHeaderSelectionIsVisibleWithoutChangingFocus": root-child and nested
  group feedback, summary synchronization and double-click navigation.
- "testLongDirectoryPathAndSimpleConfirmationAtMinimumWindow": direct double-click
  from an unselected row, full long target and fixed controls at minimum window size.

Every destructive UI flow first asserts the simulated indicator. `--fixture-mode`,
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

Fixture isolation is tested by "presentation_and_delay_fixtures_are_isolated" in
[src/bridge/tests.rs](../src/bridge/tests.rs).
"visual_details_fixture_has_nested_groups_and_long_directory_confirmation" in the
same file verifies nested groups, long paths, entry-only sizes and cancelled pins.
The original >2^53 fixture is unchanged.

Untested limits: real Trash, native GUI picker lifecycle, hostile namespace races,
VoiceOver traversal of the drawing (the table is the accessible alternative),
light-mode screenshot review, large-inventory GUI paint latency,
and cancellation of executing work. XCUITest requires an unlocked interactive
console; do not change security settings to force automation.
