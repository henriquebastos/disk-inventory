# Native lifecycle and result motion

The SwiftUI/AppKit [explorer](native-explorer.md) uses generated Rust sessions.
There is no Assistant, Empty Trash, full-snapshot Refresh or automatic scan.

## Managed snapshots

[ManagedInventoryStorage.swift](../native/Explorer/ManagedInventoryStorage.swift)
receives a FileManager and storage root. Production resolves the user's Application
Support location with FileManager and appends the bundle identifier. Tests inject
owned temporary roots; fixture-mode launch never resolves production storage.
Normal launch reads only small last-inventory metadata, not the inventory or source.

Choose Folder selects an explicit root, not an output file. A unique app-owned UUID
generation is passed to no-clobber controlled creation. After Rust saves, reopens
and validates it, the app atomically replaces small JSON metadata naming the last
inventory and its scan time. Only then does it attempt removal of the previous
managed generation. Cancellation/failure before promotion preserves the last valid
metadata/snapshot. Cleanup accepts only direct app-owned UUID generation names and
never deletes the generation currently referenced by metadata. Imports are not
registered for retention or cleanup. Last scan's Open reads the saved inventory
offline. Imported snapshots show “Scan time unavailable,” not their file modification
time. Local refresh/removal retains the original scan time and shows “Not saved.”

The directory is trusted, not protected from hostile concurrent namespace changes.
Metadata replacement is atomic, not a crash-recovery journal or guaranteed durable
transaction. Cleanup failure or process termination can leave extra app-owned files;
no broad startup sweep deletes them. A post-publication Rust failure is reported
as publication followed by failure, never cancellation or guaranteed rollback.

## Progress and Stop

[ScanCoordinator.swift](../native/Explorer/ScanCoordinator.swift) owns an independent
Rust ScanControl and one replaceable polling task. It samples every 250 ms; replacing
or closing the session cancels polling and requests Rust cancellation. Stop calls
Rust directly and immediately displays its Stopping phase. A cancelled Swift Task
alone is never treated as filesystem cancellation. `cancellable` controls Stop
availability, including the atomic publication boundary. An active filesystem call
may finish before cancellation unwinds all workers.

UI displays a spinner, cumulative items examined and truthful traversal, accounting,
saving/publication and preparing-view phases. There is no percentage, ETA or
provisional byte total. The previous presentation remains read-only until the new
session is installed. See [scan-control.md](scan-control.md) for counter semantics,
publication arbitration and core cancellation tests.

## Confirmed result motion

[ResultMotion.swift](../native/Explorer/ResultMotion.swift) retains at most one previous
bounded bitmap and one affected region. Only confirmed `removed`/`trashed` outcomes
can produce a plan. Failures, partial removals and indeterminate outcomes retain
honest diagnostics and any surviving selection, without a success ghost.

The old bitmap stays visible but non-actionable while the new saved-data view is
prepared. In roughly 200 ms, the removed region shrinks/dissolves in place and the
layout crossfades. Travel is allowed only when the actual returned destination bytes
match the verified in-inventory relative path and an actionable visible target in
the new bounded frame. Outside, unknown or invisible destinations use in-place
motion. Reduce Motion is sampled from NSWorkspace at operation completion and uses
a fade without travel/shrink. No surviving rectangle gets its own animation object.
Session/navigation generations and explicit motion cancellation prevent stale
publication. Motion does not claim reclaimed space or undo availability.

## Executable evidence

[RedesignModelTests.swift](../native/ExplorerModelTests/RedesignModelTests.swift):

- "testFullExplorerViewSettlesMapInputNavigationAndWindowResize": complete hosted
  ExplorerView settles without repeated builds or viewport changes across three
  resize-debounce intervals; map input, navigation and actual window resize work.
- "testOfflineRootBreadcrumbNamesAndFullPathHelpRemainDistinct": two unavailable
  owned roots retain distinct basename/full-path presentation at root, ancestor and
  truncated-path fallback; a synthetic filesystem-root path renders `/`.
- "testFinderURLUsesRawBytesAndRejectsLossyFoundationConversion": saved bytes are
  authoritative; Finder is unavailable when Foundation cannot round-trip them.
- "testNoScanLaunchReadsOnlySmallManagedMetadata": no constructor, scan, poll or
  storage creation at normal startup with an injected root.
- "testManagedStorageLifecycleOfflineOpenAndImportsAreNotRetained": create,
  promotion, previous-generation cleanup, import isolation and offline last-open.
- "testCancelledCreatePreservesPriorSnapshotAndFailedCreateCleansGeneration":
  typed Rust pre-cancellation and failed creation preserve bytes, session and metadata.
- "testScanPollingStopAndReplacementCallRustControlAndEndPolling": approximately
  4 Hz sampling, Rust Stopping, replacement cancellation and no subsequent samples.
- "testBreadcrumbContextsRestoreBothDirectionsAndHiddenSelection": expansion,
  hidden selected target, top row, forward/reverse context restoration and name reveal.
- "testRefreshUsesFocusedDirectoryNotSelectedAndNeverSaves": owned sibling addition
  is found when a nested directory is selected; saved bytes/time remain unchanged.
- "testRemovalMotionOutcomesVisibleDestinationAndReduceMotion": success/failure/
  partial/uncertain policy, exact visible destination, fallback, Reduce Motion and
  stale-animation cancellation.
- "testSuccessfulRemovalHoldsOnlyOneOldFrameAndReplacementCancelsMotion": real
  fixture removal, bounded previous frame, read-only transition and replacement.
- "testPartialRemovalPreservesSurvivingSelectionWithoutSuccessMotion": actual
  partial fixture execution retains the selected directory and issue log.

[DixModelTests.swift](../native/ExplorerModelTests/DixModelTests.swift)
"testDisclosureZoomBreadcrumbAndAncestorRestoreContext" and
"testHistoryCapPayloadAndSessionAndMutationInvalidation" cover sparse-context
restoration, the 64-context cap and mutation/replacement invalidation. Existing
safety/replacement/pin and virtual-tree tests remain in the model suite.

Build with `bash scripts/build-gui.sh "$G"`, then run the existing scheme with
`xcodebuild -project "$G/project/DiskInventory.xcodeproj" -scheme DiskInventory
-configuration Debug -derivedDataPath "$G/DerivedData" BRIDGE_ROOT="$G/bridge"
CLANG_MODULE_CACHE_PATH="$G/module-cache" -destination 'platform=macOS'
-resultBundlePath "$G/ModelTests.xcresult" -only-testing:ExplorerModelTests
test-without-building`. Set TMPDIR below G. This is a hosted unit suite, not
XCUITest: its app host is explicitly in presentation-fixture mode via DI_MODEL_TEST;
DI_TEST_ROOT points below the external generated project. UI tests explicitly clear
that host override and retain their own fixture-only launch arguments.

Untested limits: real native chooser/Finder/Trash interactions, metadata crash
recovery/durability faults, Intel/older macOS, full VoiceOver and visual/compositor
motion acceptance. Hosted/offscreen tests do not replace foreground screenshots or
UI automation. Startup failure stops that validation lane; no security changes or
retries are a remedy.
