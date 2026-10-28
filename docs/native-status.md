# Native status bar, outcomes, selection and refresh

This page specifies the parts of the [native explorer](native-explorer.md) window that report
state: the status bar below the map, the outcome banner, the selection dim, Esc and the
progress of Refresh Directory. The code is in
[ExplorerApp.swift](../native/Explorer/ExplorerApp.swift),
[ExplorerModel.swift](../native/Explorer/ExplorerModel.swift),
[NativeViews.swift](../native/Explorer/NativeViews.swift) and
[ScanCoordinator.swift](../native/Explorer/ScanCoordinator.swift).

## Status bar

The status bar is one line, 28 points high, below the map. It names the map block under the
pointer, also while another item is selected: the saved root path and the saved relative path,
in a monospaced caption. A grouped block shows "Grouped in" and the complete folder path. A
striped `.Trash` block shows the path of that `.Trash`. When the pointer is not over the map,
the status bar is empty. The selection lives in the card below the tree. A long path truncates
in the middle; the help tag and the accessibility label keep the full text.

The path comes from the hover hit: the core builds it from the saved inventory, with no
filesystem metadata and no scan. `StatusBar` in [ExplorerApp.swift](../native/Explorer/ExplorerApp.swift)
is its own view, so a hover redraws only that line and the map overlay. A hover does not
rebuild the map or change its picture, so it needs no throttle.

The former footer messages moved:

| Message | Now |
|---|---|
| Error line and Dismiss | Outcome banner |
| Operation and refresh outcomes | Outcome banner |
| Details: error text and core issues | Outcome banner, Details disclosure |
| Hovered path and size | Status bar, the path only |
| "Recorded disk usage · Shared space is counted once · Deleting may free less space" | Removed. The card, the header and the confirmations have no space or accounting sentence. |
| "Some map detail is grouped or reduced at this scale…" | Removed. The card of a grouped block shows its size. |

## Outcome banner

The banner floats over the top of the map, at most 440 points wide. It shows the error line
(`error`), the outcome text (`outcome`) and a Details disclosure with the error text and the
session issue log (`issues`). The banner hit-tests only its own frame, so the rest of the map
takes clicks. It does not resize the map, also during result motion.

A success says only what happened: "Deleted.", "Moved to Trash." or "Refreshed “Library”.". It
names no Trash scope and no saved-snapshot state; the totals and the Not saved badge show
those. An unknown Trash scope is a core issue in Details. Failed, partial and indeterminate
results keep their own text. Of the header badges, only Partial has a help tag (the scan error
count); Incomplete and Not saved have none.

The banner stays until Dismiss, until a new outcome replaces the old one, or until a new folder
opens. Dismiss clears the error and the outcome and marks the current issues as seen. The issue
log stays; a new issue shows the banner again.

## Selection dim and selection region

Outside the selected region, the map gets 12% black. The design uses 28%. On the real runner,
the minimum unselected seam contrast in `prototype-home` is 2.21:1 without a selection,
2.01:1 at 12% and 1.78:1 at 28%, in dark and in light. The selected block keeps a white
2-point ring with a black outer ring.

The selected region publishes with the selection, never after a frame without it:

- A map click selects the hit tile and uses the hit rectangle as the region at once.
- A tree or keyboard selection keeps the shown region until the region of the new item arrives
  from the current frame.
- A map rebuild computes the region of the shown selection with the new picture and publishes
  both together.

Before this rule, `select` cleared the region first and asked the session-locked
`DiagramFrame.region` for the new one. When a display refresh came between the two, AppKit drew
the whole map without the dim for 10 to 42 ms, about one click in three. That was the click
flicker.

In fixture mode only, `MapView` exposes the frame sampler `map-selection-gaps` as an
accessibility element. It counts drawn frames that lose the dim between two frames with the dim
for the same new selection. Its label is "gaps=G selections=S draws=D".

## Esc

Esc clears the selection when the tree, the map or the window has the keyboard focus. The map
never takes the focus, so a click on it leaves the focus where it was. Esc clears the selected
item, its region and dim, the card, the tree highlight and a grouped-block selection. Focus, expansion, scroll position, saved data and the map picture stay.

An attached confirmation sheet keeps its own Esc, which is Cancel; the selection stays. Esc
does nothing while a scan, a refresh, an operation or a view rebuild runs, or while result
motion plays. A text view keeps its own keys. Stop Scan keeps Command-Period. There is no menu
item for Esc: the menus have no selection-clearing command, and Esc is not a menu key
equivalent on macOS.

## Refresh progress and Stop

Refresh Directory uses the scan's progress presentation: the busy bar over the split view with
the phase text, the live "N items examined" counter and Stop. The phase text names the focused
folder: "Refreshing “Library”…", "Stopping…", then "Updating “Library”…" while the view rebuilds.
Stop and the Stop Scan menu item stop a refresh like a scan.

`ExplorerSession.refreshDirectoryControlled` takes a `ScanControl`. The core reads the live
subtree first, counts each directory metadata request and each directory record, and checks
Stop before each request. It then commits with the same compare-exchange that arbitrates Stop in
a scan, and applies the read to the in-memory inventory. Stop before the commit returns
`BridgeError.Cancelled` and changes nothing. The banner then says "Refresh of “Library” stopped.
The previous data is unchanged." The map, the tree and their frames stay valid; no rebuild runs.
After the commit Stop is rejected, the update completes, and the banner says "Refreshed
“Library”.". The details are in
[operations.md](operations.md) and [scan-control.md](scan-control.md).

Refresh covers the focused subtree, in memory only. Navigation never scans.

## Executable evidence

UI tests in [ExplorerUITests.swift](../native/ExplorerTests/ExplorerUITests.swift), on the
real runner:

- "testStatusBarShowsTheHoveredBlockAlsoWhileAnItemIsSelected": empty with the pointer off the
  map, also with a selection; the hovered file path while another item is selected; "Grouped
  in" for a grouped block; no old default text; the outcome in the banner over the map; Dismiss.
- "testNestedTrashIsStripedAtItsParentLevelAndColoredWhenFocused" includes the status bar path
  of a hovered `.Trash` block.
- "testSelectionDimIsLightAndKeepsUnselectedSeamsVisible": the 0.88 dim factor, seams of at
  least 1.8:1 after selection, and the white ring, in dark and light.
- "testRepeatedMapClicksNeverDrawAFrameWithoutTheSelectionDim": 40 map clicks, zero gaps.
- "testEscapeClearsTheSelectionInTreeAndMap": Esc after a tree and a map selection, no dim
  after Esc, and the sheet's Esc priority.
- "testRefreshShowsNamedProgressWithCounterAndStopKeepsData": the named phase, a rising
  counter, Stop with unchanged data, then a complete refresh with the new file.
- "testHeaderAndCardShowOnlySizesAndCountsWithoutAccountingNotes": the header size alone; file,
  hard-link, directory and grouped cards without accounting or sharing notes.
- "testRefreshHelpTagHasNoSnapshotNoteAndBadgesHaveNoHelpTags": the Incomplete and Not saved
  badges have no help tag; the Refresh help tag, read by on-device text recognition, is
  "Rescan the focused directory and descendants." Help tags appear unreliably after the first
  one in a window, so each check has its own launch.

Model tests in [FeedbackModelTests.swift](../native/ExplorerModelTests/FeedbackModelTests.swift):
"testStatusTextNamesTheHoveredBlockWhileAnotherItemIsSelected" (the selection, the picture and
the session selection-query count stay during a hover),
"testSelectionRegionNeverClearsWhileTheNextRegionLoads",
"testClearSelectionResetsItemRegionCardAndRowOnly",
"testBannerDismissHidesOutcomeErrorAndSeenIssues",
"testControlledRefreshNamesTheFolderCountsAndStopKeepsTheView",
"testControlledRefreshAppliesLiveChangesAndRebuilds" and
"testTrashRegionSelectsTheTrashDirectory".

The `prototype-home-refresh` fixture in [fixture.rs](../src/bridge/fixture.rs) adds 300 ms to
each directory metadata request and one live file, `Library/Caches/new cache.db`.

Untested: Esc with full keyboard access on a focused button, and Stop during a real native
refresh. The frame sampler counts drawn frames, not compositor output.
