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

Swift `private` does not reach other files, so the request bookkeeping is internal. Views read
only published state and component states.

## Component states

A component state is a plain Swift value: strings, numbers and flags, never a Rust handle such
as `EntryKey`. The model computes it from its published state, so reading it in a view body
observes the same properties as before. The view renders the value and sends an intent back;
the model performs the intent with the existing command rules. Each view has a `#Preview` per
variant that needs no Rust session.

| State | View | Variants |
|---|---|---|
| `SelectionCardState` | [SelectionCard.swift](../native/Explorer/SelectionCard.swift) | nothing selected (with or without Select Inventory Root), item, grouped block |
| `OutcomeBannerState` | [OutcomeBanner.swift](../native/Explorer/OutcomeBanner.swift) | error, outcome and issues; `outcomeBanner` is nil while hidden |
| `ProgressBarState` | [ProgressBar.swift](../native/Explorer/ProgressBar.swift) | operation (phase, counter, Stop), checking an item, preparing an inventory, working |
| `HeaderState` | [ExplorerHeader.swift](../native/Explorer/ExplorerHeader.swift) | menu titles and rules, Partial, Incomplete and Not saved badges, total, scan date, Refresh, breadcrumbs enabled |

The item variant holds the name, the size (directory subtree or file accounted allocation),
the direct-item count of a directory, the complete saved path (nil while it loads), root
protection and the Reveal in Finder, Move to Trash… and Delete… enable rules.

[SelectionCardTests.swift](../native/ExplorerModelTests/SelectionCardTests.swift) has one model
test per variant:

- "testCardShowsNothingSelectedWithSelectInventoryRoot": at launch and after Esc.
- "testCardShowsAFileWithItsSizeAndLoadedPath": no count, the path once loaded, and both
  removal buttons disabled while a preparation runs.
- "testCardShowsADirectoryWithItsSubtreeSizeAndDirectItems": the subtree size and the count.
- "testCardShowsTheProtectedInventoryRoot": root protection and no removal.
- "testCardShowsAGroupedBlockSizeAndOpensItsDirectory": the size and Show Directory Contents.

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
  "testBannerShowsAnOutcomeWithoutDetails", "testBannerShowsAnErrorWithItsMessageInDetails" and
  "testBannerShowsIssuesUntilDismissedAndAgainForANewIssue".
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

The rendered card (fonts, truncation and the material) stays covered by
"testHeaderAndCardShowOnlySizesAndCountsWithoutAccountingNotes" and
"testCaptionAndSecondaryTextMeetFourAndAHalfToOne" in
[ExplorerUITests.swift](../native/ExplorerTests/ExplorerUITests.swift); the rendered banner,
bar and header by the UI tests that [native-status.md](native-status.md) lists.
