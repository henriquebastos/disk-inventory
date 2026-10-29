# Native lifecycle and result motion

The SwiftUI/AppKit [explorer](native-explorer.md) uses generated Rust sessions.
There is no Assistant, Empty Trash, full-snapshot Refresh or automatic scan.

## Managed snapshots

[ManagedInventoryStorage.swift](../native/Explorer/ManagedInventoryStorage.swift)
receives a FileManager and storage root. Production resolves the user's Application
Support location with FileManager and appends the bundle identifier. Tests inject
owned temporary roots; fixture-mode launch never resolves production storage.
Normal launch reads only small last-inventory metadata, not the inventory or source.

The user chooses only folders. The snapshot is an internal file, and no command opens
another snapshot file. Choose Folder selects an explicit root, not an output file. A
unique app-owned UUID generation is passed to no-clobber controlled creation. After
Rust saves, reopens and validates it, the app atomically replaces small JSON metadata
naming the last inventory, its scan time and its root as display text (`rootName`).
Only then does it attempt removal of the previous managed generation.
Cancellation/failure before promotion preserves the last valid metadata/snapshot.
Cleanup accepts only direct app-owned UUID generation names and never deletes the
generation currently referenced by metadata. Reopen reads the saved inventory offline
and shows its saved scan time. Local refresh/removal retains the original scan time
and shows “Not saved.”

The reopen label is `Reopen “NAME”`. NAME is the last path component of `rootName`
(`/` for the filesystem root), shortened in the middle above 60 characters. Metadata
without `rootName`, or with an empty one, shows “Reopen Last Folder.” The name is a
label only. Reopen opens the metadata filename, which must name an owned generation.

Test-only seam: in fixture mode, `DI_FIXTURE_STORAGE_ROOT` can name an existing
absolute directory that a UI test owns. The model only reads the metadata there.
Fixture mode never creates, opens, promotes or cleans up an inventory, so Choose
Folder and Reopen stay disabled. Any other value leaves fixture storage empty.
Production ignores the variable.

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
availability, including the atomic publication boundary. File > Stop Scan
(Command-Period) uses the same rule ([native-commands.md](native-commands.md)). An active filesystem call
may finish before cancellation unwinds all workers.

UI displays a spinner, cumulative items examined, the time since the scan began and truthful
traversal, accounting, saving/publication and preparing-view phases. The time counts whole
seconds in the locale's abbreviated units, such as "8 sec" or "1 min, 5 sec", and each poll
sample updates it. The start screen and the explorer show the same bar. There is no
percentage, ETA or provisional byte total. The previous presentation remains read-only until the new
session is installed. See [scan-control.md](scan-control.md) for counter semantics,
publication arbitration and core cancellation tests.
"testScanElapsedTimeCountsWholeSecondsAndOperationsShowNone" checks the time with a fixed
clock, and "testStartScreenShowsTheScanCounterTimeAndStop" checks the start-screen bar of a
real scan.

## Confirmed result motion

[ResultMotion.swift](../native/Explorer/ResultMotion.swift) retains at most one previous
bounded bitmap and one affected region. Only confirmed `removed`/`trashed` outcomes
can produce a plan. Failures, skipped or partial removals and indeterminate outcomes retain
honest diagnostics and any surviving selection, without a success ghost.
Recovery retains the bounded row slice without its obsolete tree handle. Native callbacks reject input until the new view is ready.
The model publishes the recovered selection, rows, and map together. The outcome banner floats over the map, so outcome text never resizes it.
A resize during recovery does not start its own view request. Recovery builds at the latest viewport.
Actions and the Finder path stay unavailable until recovery validates or clears the old selection.
An in-focus survivor gets a row slice around its row and a scroll request. An outside-focus survivor keeps only the summary selection.

The old bitmap stays visible but non-actionable while the new saved-data view is
prepared. In roughly 200 ms, the removed region shrinks/dissolves in place and the
layout crossfades. Travel is allowed only when the actual returned destination bytes
match the verified in-inventory relative path and a visible region in the new frame.
An inside-Trash move keeps the saved key. The model queries the saved selection
and the new frame region for that key. The 24 accessibility targets do not cover
all visible destinations. Outside, unknown or invisible destinations use in-place
motion. The model reads Reduce Motion from NSWorkspace at operation completion.
Reduce Motion uses a fade without translation or scaling.
In fixture mode only, `DI_REDUCE_MOTION=1` also selects the fade.
UI tests use this override and never change the system setting.
No surviving rectangle gets its own animation object.
Session/navigation generations and explicit motion cancellation prevent stale
publication. Motion does not claim reclaimed space or undo availability.

## Executable evidence

[ExplorerLifecycleTests.swift](../native/ExplorerModelTests/ExplorerLifecycleTests.swift):

- "testFullExplorerViewSettlesMapInputNavigationAndWindowResize": complete hosted
  ExplorerView settles without repeated builds or viewport changes for longer than two
  resize-debounce intervals; map input, navigation and actual window resize work.
- "testOfflineRootBreadcrumbNamesAndFullPathHelpRemainDistinct": two unavailable
  owned roots retain distinct basename/full-path presentation at root, ancestor and
  truncated-path fallback; a synthetic filesystem-root path renders `/`.
- "testFinderURLUsesRawBytesAndRejectsLossyFoundationConversion": saved bytes are
  authoritative; Finder is unavailable when Foundation cannot round-trip them.
- "testNoScanLaunchReadsOnlySmallManagedMetadata": no constructor, scan, poll or
  storage creation at normal startup with an injected root.
- "testManagedStorageLifecycleReopensLastFolderOfflineAndCleansOldGeneration": create,
  promotion, the reopen label, previous-generation cleanup, a foreign file that cleanup
  rejects, and offline reopen.
- "testLastFolderMetadataRoundTripsRootNameAndOldMetadataFallsBack": `rootName` round
  trip, `/`, 60-character middle shortening, and metadata without or with an empty name.
- "testFixtureStorageRootIsReadOnlyAndNeedsFixtureModeAndAnExistingDirectory": the
  seam accepts only an existing absolute directory, reads only, and production ignores it.
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
- "testRecoveryRetainsRowsWithoutInteractiveStaleTree": retained display rows, blocked input, and replacement of the obsolete handle.
- "testRecoveryPublishesBoundedSliceAndScrollForLateSurvivor": a survivor beyond row 255 gets its row slice and scroll request.
- "testRecoveryKeepsOutsideFocusSurvivorWithoutFalseTreeRow": an outside-focus survivor stays selected without a tree row.
- "testRemovalOutcomeKeepsHostedMapViewportAndTreeRowsStable": full hosted removal preserves rows and map geometry across debounce intervals.
- "testInsideTrashTravelsBetweenMateriallyDistinctRegions": separate visible endpoints.
- "testInsideTrashTravelsToTheMovedTileBeyondAccessibilityTargets": a simulated inside-Trash
  move selects travel to a destination tile outside the accessibility targets.
- "testFixtureReduceMotionOverrideIsIgnoredOutsideFixtureMode": the override needs
  fixture mode and produces a fade for a real removal.

[TreeAndMapNavigationTests.swift](../native/ExplorerModelTests/TreeAndMapNavigationTests.swift)
"testDisclosureZoomBreadcrumbAndAncestorRestoreContext" and
"testHistoryCapPayloadAndSessionAndMutationInvalidation" cover sparse-context
restoration, the 64-context cap and mutation/replacement invalidation.

Run the model tests with `scripts/check.sh model-only` ([checks.md](checks.md)). This is a
hosted unit suite, not XCUITest: its app host is explicitly in presentation-fixture mode via DI_MODEL_TEST;
DI_TEST_ROOT points below the external generated project. UI tests explicitly clear
that host override and retain their own fixture-only launch arguments.

Untested limits: real native chooser/Finder/Trash interactions, metadata crash
recovery/durability faults, Intel/older macOS and full VoiceOver.
Model tests check which motion style a removal chooses. No test reads the fixture-only
`motion-style` probe or verifies compositor output.
Manual frame-by-frame review must verify travel, poof, fade, and the final state.
Hosted/offscreen tests do not replace foreground screenshots or UI automation. Startup failure stops that validation lane; no security changes or
retries are a remedy.
