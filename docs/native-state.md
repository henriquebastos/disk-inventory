# Native model and component states

This page specifies how the [native explorer](native-explorer.md) passes state to its views.

## Model files

`ExplorerModel` is one main-actor `@Observable` class.
[ExplorerModel.swift](../native/Explorer/ExplorerModel.swift) declares all stored state. Role
extensions hold the behavior:

| File | Role |
|---|---|
| [ExplorerModel+Session.swift](../native/Explorer/ExplorerModel+Session.swift) | Load or replace a session, managed storage, shutdown |
| [ExplorerModel+View.swift](../native/Explorer/ExplorerModel+View.swift) | Off-main view builds, resize and appearance rebuilds, recovery after a mutation |
| [ExplorerModel+Tree.swift](../native/Explorer/ExplorerModel+Tree.swift) | Tree row pages, expansion and reveal |
| [ExplorerModel+Selection.swift](../native/Explorer/ExplorerModel+Selection.swift) | Selection, map hover and click, paths, Finder |
| [ExplorerModel+Navigation.swift](../native/Explorer/ExplorerModel+Navigation.swift) | Focus, parent and history |
| [ExplorerModel+Operations.swift](../native/Explorer/ExplorerModel+Operations.swift) | Command enable rules, Trash and Delete, outcomes, Refresh Directory |
| [ExplorerModel+Input.swift](../native/Explorer/ExplorerModel+Input.swift) | Busy rules for tree and map input, tree keys, map context-menu selection |

Swift `private` does not reach other files, so the request bookkeeping is internal. The
request versions are `@ObservationIgnored`, except `viewVersion`, which model tests wait for.
Views read only published state and component states, and change the model only through
intents.

## Selection state

`selection` is one `SelectionState` value: the selected item, its tree row, its map region,
its saved path, a failed path lookup, and a selected grouped block. `clear()` drops every
field at once. Esc, focus, a session load, and recovery after Refresh, Trash or Delete call it,
so a grouped block also leaves the card. A new item selection keeps only the shown region
until its own region arrives. A failed path lookup shows "Could not read this path." on the
card and in its help tag, and Reveal in Finder stays disabled.

Any change of `selection` runs the tree and map representables again, but the map draws only
when a drawn input changes: the selection region, the hover rectangle, the picture, or the
result motion. Its `draw` reads a copy of the selected key, because AppKit draws a view again
when a model property that `draw` read changes.

- [MapDrawingModelTests.swift](../native/ExplorerModelTests/MapDrawingModelTests.swift)
  "testHostedMapDrawsOnlyWhenADrawnInputChanges": counts draws with the fixture frame sampler;
  a tree expansion and the path and reveal answers after a map click draw nothing.
- [SelectionCardTests.swift](../native/ExplorerModelTests/SelectionCardTests.swift)
  "testRefreshAndASessionLoadClearASelectedGroupedBlock" and
  "testCardSaysThePathCouldNotBeReadWhenItsLookupFails".
- [InputRulesTests.swift](../native/ExplorerModelTests/InputRulesTests.swift)
  "testSelectRowHighlightsTheClickedRowAtOnce" (`selectRow`, a tree click) and
  "testScrolledSavesTheTopRowAndRowZeroAboveTheFirstRow" (`scrolled(toRow:)`, the tree scroll
  observer).

## Component states

A component state is a plain Swift value: strings, numbers and flags, never a Rust handle such
as `EntryKey`. The model computes it from its published state. A small host view
(`ExplorerHeaderHost`, `SelectionCardHost`, `OutcomeBannerHost`, `ProgressBarHost`, and
`StatusBar`) computes it in its own body, so a change redraws only that component. A progress
tick changes only the bar: `ExplorerView` reads only whether a bar shows
(`showsProgressBar`, `showsStartScreenProgressBar`). The view renders the value and sends an
intent back; the model performs the intent with the command rules. Each view has a
`#Preview` per variant that needs no Rust session. Untested: no test counts body runs.

| State | View | Variants |
|---|---|---|
| `SelectionCardState` | [SelectionCard.swift](../native/Explorer/SelectionCard.swift) | nothing selected (with or without Select Inventory Root), item, grouped block |
| `OutcomeBannerState` | [OutcomeBanner.swift](../native/Explorer/OutcomeBanner.swift) | error, outcome and issues, Details open or closed; `outcomeBanner` is nil while hidden |
| `ProgressBarState` | [ProgressBar.swift](../native/Explorer/ProgressBar.swift) | operation (phase, counter, Stop), checking an item, preparing an inventory, working |
| `HeaderState` | [ExplorerHeader.swift](../native/Explorer/ExplorerHeader.swift) | menu titles and rules, Partial, Incomplete and Not saved badges, total, scan date, Refresh, breadcrumbs enabled |
| `TreeRowState` | [TreeRowState.swift](../native/Explorer/TreeRowState.swift), `Cell.apply` and `SizeCell.apply` in [TreeView.swift](../native/Explorer/TreeView.swift) | loaded row (name, depth, swatch color, usage percent, size, disclosure and accessibility ids), loading placeholder |

The item variant holds the name, the size (directory subtree or file accounted allocation),
the direct-item count of a directory, the complete saved path (nil while it loads or after a
failed lookup), root protection and the Reveal in Finder, Move to Trash… and Delete… enable rules.

[SelectionCardTests.swift](../native/ExplorerModelTests/SelectionCardTests.swift) has one model
test per variant:

- "testCardShowsNothingSelectedWithSelectInventoryRoot": at launch and after Esc.
- "testCardShowsAFileWithItsSizeAndLoadedPath": no count, the path once loaded, and both
  removal buttons disabled while a preparation runs.
- "testCardShowsADirectoryWithItsSubtreeSizeAndDirectItems": the subtree size and the count.
- "testCardNamesOneDirectItemInTheSingular": "1 direct item". The shared rule for every count
  text is in [NativeNumberFormatTests.swift](../native/ExplorerModelTests/NativeNumberFormatTests.swift)
  "testCountUsesTheSingularNounOnlyForOne".
- "testCardShowsTheProtectedInventoryRoot": root protection and no removal.
- "testCardShowsAGroupedBlockSizeAndOpensItsDirectory": the size and Show Directory Contents.

Help tags use `toolTip(_:)` in [ToolTip.swift](../native/Explorer/ToolTip.swift): an AppKit
view behind the SwiftUI view carries the tool tip and takes no clicks.
[ToolTipTests.swift](../native/ExplorerModelTests/ToolTipTests.swift) draws it offscreen:
"testToolTipFollowsItsTextTakesNoClicksAndIsEmptyWithoutText".

`progressBar` shows over the explorer while loading, working or replacing the session;
`startScreenProgressBar` shows on the start screen only while a session loads.

The header state holds no breadcrumbs. `BreadcrumbStrip` still reads the model and each button
keeps the key it was drawn with: an index sent back could name another folder if the view
changed just before the click, and dropping such clicks would change behavior. Breadcrumb names
and help come from the pure `ViewRecords.breadcrumbName` and `breadcrumbHelp`
("testOfflineRootBreadcrumbNamesAndFullPathHelpRemainDistinct").

[StatusComponentTests.swift](../native/ExplorerModelTests/StatusComponentTests.swift) has one
model test per variant:

- Banner: "testBannerIsHiddenWithoutAnErrorOutcomeOrNewIssue",
  "testBannerShowsAnOutcomeWithoutDetails", "testBannerShowsAnErrorWithItsMessageInDetails",
  "testBannerShowsIssuesUntilDismissedAndAgainForANewIssue" and
  "testBannerDetailsToggleFromOneIntentAndCloseWhenTheBannerHides" (the chevron and the word
  Details send `toggleBannerDetails`).
- Busy bar: "testProgressBarShowsPreparingInventoryWhileTheSessionLoads",
  "testProgressBarShowsWorkingWhileANavigationBuildsItsView",
  "testProgressBarNamesTheItemThatAPreparationChecks",
  "testProgressBarShowsARefreshPhaseCounterAndStop" and
  "testProgressBarShowsATrashWithoutStopOrCounter".
- Header: "testHeaderShowsTheSavedTotalWithoutBadgesForAFixture",
  "testHeaderDisablesBreadcrumbsAndRefreshWhileAPreparationRuns",
  "testHeaderShowsNotSavedAfterADelete",
  "testHeaderShowsIncompleteAfterARefreshWithUnknownAllocation" and
  "testHeaderShowsPartialScanErrorsAndTheDateOfAManagedScan", which scans an owned folder with
  a mode-000 directory and skips if the process can still read it.

The tree coordinator builds a `TreeRowState` for each visible row when the table asks for its
cells, from the cached row page, and keeps none; disclosure targets and the enable rule stay in
the coordinator. [TreeRowTests.swift](../native/ExplorerModelTests/TreeRowTests.swift) maps
fixture rows ("testTreeRowStateMapsFixtureRowsAgainstTheFocusTotal") and draws one offscreen
cell per state, with no table or session: "testCellShowsAFileRowWithItsColorSwatchAndUsageBar",
"testCellShowsACollapsedDirectoryWithItsDisclosureAndGraySquare",
"testCellShowsAnExpandedDirectoryAsCollapsible",
"testCellIndentsByDepthUpToOneHundredTwentyPoints",
"testCellShowsALoadingRowWithoutSwatchOrBarAfterReuse" and
"testSizeCellShowsTheSizeWithTheNameFrameAndAHelpTag". The on-screen alignment, selection and
background checks stay in "testTreeSizeTextCentersWithNameOnSelectedAndUnselectedRows" and
"testWindowShowsTheMapBitmapOneToOneAndTheTreeInSystemColors".

The rendered card (fonts, truncation and the material) stays covered by
"testHeaderAndCardShowOnlySizesAndCountsWithoutAccountingNotes" and
"testCaptionAndSecondaryTextMeetFourAndAHalfToOne" in
[ExplorerUITests.swift](../native/ExplorerTests/ExplorerUITests.swift); the rendered banner,
bar and header by the UI tests that [native-status.md](native-status.md) lists.

## Busy rules

Tree and map views ask named model rules instead of checking busy flags themselves. The rules
differ on purpose, and each keeps the exact condition that its input had:

| Rule | Condition | Used by |
|---|---|---|
| `isIdle` | no load, operation, session replacement or pending confirmation | tree keys, parent selection, Navigate commands |
| `treeInteractive` | `isIdle` and a tree handle | row selection, double-click, disclosure clicks, row context menu |
| `visibleDisclosuresEnabled` | `treeInteractive` and no expansion in flight | disclosures of visible rows |
| `canExpandRows` | no load, operation, replacement or expansion in flight | disclosures of new cells, `expand` |
| `acceptsMapPointer` | no load, operation, replacement or result motion | map hover, click and accessibility press |
| `canOpenMapContextMenu` | `acceptsMapPointer` and no pending confirmation | map block context menu |

The tree's Left and Right keys (`treeArrowKey`), Command-Up, Command-Down, Return and Enter
(`treeNavigationKey`) and the map block context menu (`selectHoveredBlockForContextMenu`) are
model intents: a view passes the key or the click, and the intent checks its rule. A busy tree
consumes its keys without acting. The view keeps only geometry, such as whether a secondary
click falls inside the hovered block.

[InputRulesTests.swift](../native/ExplorerModelTests/InputRulesTests.swift):

- "testTreeArrowKeysExpandSelectTheFirstItemCollapseAndSelectTheParent" and
  "testTreeNavigationKeysFocusTheParentAndOpenTheSelectedDirectory": the key decisions.
- "testTreeKeysAreConsumedWithoutActionWhileBusy": an operation and a pending confirmation.
- "testTreeInputRulesDifferForVisibleAndNewDisclosures" and
  "testMapRulesDifferForAPendingConfirmationAndAResultMotion": where the rules differ.
- "testMapContextMenuSelectsTheHoveredBlockOrItsGroup": item and group selection.

The real secondary clicks stay in "testContextMenusSelectClickedRowAndHoveredBlock" and
"testContextMenusOnTreeRowAndMapBlock"; real keys in
"testDisclosureKeyboardZoomBreadcrumbAndUsage".

## Workers

[LatestWorker.swift](../native/Explorer/LatestWorker.swift) serves one request at a time on the
main actor. A new request replaces the waiting request of its slot, and a lower slot is served
first. The serve function awaits its own detached Rust call and checks the model's versions
before it publishes. It is held only while the worker runs, so an idle worker retains no
model. The view build, the selection path, the selection region, Left-arrow parent selection,
map hit tests and the tree use one each (`viewWorker`, `pathWorker`, `regionWorker`,
`parentWorker`, `hitWorker`, `treeWorker`). A waiting click is served before a waiting hover; a
waiting expansion before a reveal, and a reveal before a row page. An expansion runs even when
a newer request changed the outline version. A replaced view request resumes its caller at
once; a served one resumes it after publishing, or after dropping an obsolete result. A view
request that a load or focus made obsolete while it waited builds nothing.
[WorkerModelTests.swift](../native/ExplorerModelTests/WorkerModelTests.swift) holds the Rust
lock while requests wait: "testObsoleteRegionAnswersDoNotReturnAfterClearSelection",
"testObsoleteHoverAnswersDoNotReturnAfterThePointerLeaves",
"testObsoleteClickAnswersDoNotSelectAfterClearSelection",
"testClickAnswersDoNotSelectAfterTheViewIsRebuilt" and
"testHoverAnswersDoNotReturnDuringAResultMotion",
"testWaitingExpansionRunsBeforeALaterRevealAndEndsTheEdit",
"testObsoleteRevealDoesNotPublishAfterAnExpansion", "testRevealAfterClearSelectionSelectsNoRow"
"testRowPageAskedAfterARevealIsServedAfterIt",
"testReplacedViewRequestsResumeTheirCallersOnceAndEarly" and
"testObsoleteWaitingViewRequestBuildsNothingAfterALoad".

`ExplorerModel.settled()` returns once every worker is idle at the same moment. It does not wait
for session loads, operations, the rebuild debounce, the motion clock or AppKit; tests wait
for those with `waitUntil` or `pollUntil`. Tests call it through `settled(_:)` in
[ModelWait.swift](../native/ExplorerModelTests/ModelWait.swift), which fails after 8 s instead of
hanging. "testSessionReplacementDiscardsOldSelectionAndViews",
"testParentRequestsCoalesceActualQueriesAndDropObsoletePendingWork" and
"testQueuedParentDoesNotExecuteAfterSelectionOrSessionChanges",
"testStaleHoverRevealAndFrameCannotPublishAcrossSessionReplacement" and
"testMapRulesDifferForAPendingConfirmationAndAResultMotion" use it in place of fixed sleeps.

[LatestWorkerTests.swift](../native/ExplorerModelTests/LatestWorkerTests.swift) tests the worker
alone: "testSubmitReplacesTheWaitingRequestOfItsSlot", "testLowerSlotIsServedFirst",
"testDiscardDropsOnlyTheWaitingRequest", "testIsIdleOnlyWhenNotServingAndNothingWaiting",
"testSettledReturnsAtOnceWhenIdle", "testSettledIncludesARequestSubmittedDuringServe" and
"testIdleWorkerDoesNotRetainItsServeClosure".
