# 1 Native commands

The [native explorer](native-explorer.md) has one command source:
[ExplorerCommands.swift](../native/Explorer/ExplorerCommands.swift). Each
`ExplorerCommand` has a title, an optional shortcut, `isEnabled(in:)` and
`perform(in:)`. The menu bar, the selection card, the toolbar, the start screen and
the context menus all use these two functions. `perform(in:)` checks `isEnabled(in:)`
again and then calls one existing
[ExplorerModel](../native/Explorer/ExplorerModel.swift) function, such as
`prepare`, `refresh`, `focusParent` or `scan.stop`. It copies no logic.

Each enable rule is one `ExplorerModel` property (`canAct`, `canRefresh`,
`canStopScan`, `canRevealInFinder` and others). The rules read saved state only. They
never call live metadata and never start a scan. Every rule is false while a
confirmation is pending, because the alert sheet is modal on the window but the menu
bar stays live. Fixture mode disables Choose Folder… and Reopen. Fixture mode also
disables Reveal in Finder, because fixtures have no Finder URL.

## 1a Menu bar

| Menu | Item | Shortcut |
|---|---|---|
| File | Choose Folder… | Command-O |
| File | Reopen “NAME” | none |
| File | Refresh Directory | none |
| File | Stop Scan | Command-Period |
| File | Reveal in Finder | none |
| File | Move to Trash… | Command-Delete |
| File | Delete Immediately… | Option-Command-Delete |
| Navigate | Open Selected Directory | Command-Down |
| Navigate | Enclosing Directory | Command-Up |

Reopen names the last folder. `title(in:)` gives the menu bar, the start screen and the
header menu the same label. [native-lifecycle.md](native-lifecycle.md) gives the name
rule. There is no command to open a snapshot file. Dividers separate the open, scan
and item groups. SwiftUI adds Close below them. An
ellipsis marks a command that opens a panel or a confirmation. The two Delete
shortcuts are the keys in Finder's own File menu. Return in the tree also opens the
selected directory. The system Edit menu stays. The app registers no Undo action, so
Undo stays unavailable after Move to Trash and after permanent deletion.

[ExplorerApp.swift](../native/Explorer/ExplorerApp.swift) builds the menu bar with
SwiftUI `.commands` on the Settings scene. SwiftUI rebuilds `NSApp.mainMenu`: it
removed an AppKit Navigate menu less than one second after launch. A replaced
new-item group gives the File menu. `CommandMenu("Navigate")` puts Navigate between
View and Window.

`ExplorerMenuState` enables a menu-bar command only while the explorer window is key.
SwiftUI menu validation cannot read the first responder, and the explorer window has
no editable text view. This key-window flag therefore replaces the first-responder
check that the context menus keep. Another key window, such as the About panel or an
open panel, disables every menu-bar command. If the explorer window gets an editable
text view, the Delete shortcuts need the first-responder check again.

## 1b Context menus

A secondary click on a tree row or a map block shows Reveal in Finder, Move to Trash…
and Delete Immediately…. The items have no shortcuts. The menu always acts on the
clicked item, because the click selects that item first:

- Tree row: the click selects the clicked cached row through `selectRowIndexes`,
  which reaches the normal selection path. An uncached row shows no menu.
- Map block: the map uses the published hover only when its rectangle holds the
  pointer. It never runs a hit test on the main thread, because a hit test takes the
  session lock. An actionable block becomes the selection. A grouped block selects
  its aggregate, which disables every item. Without a matching hover, no menu shows.

No context menu shows while a confirmation is pending or the view is loading or busy.
The map also shows none while result motion runs. `ExplorerCommandTarget` validates the items. Move to Trash…
and Delete Immediately… are disabled when the first responder is an editable text view,
because Delete then edits text. The inventory root keeps both removals disabled.
Reveal in Finder can stay disabled until the selected path loads.

## 1c Confirmations

Trash and permanent deletion prepare off-main and retain the PreparedAction through
a separate confirmation: an NSAlert sheet
([ConfirmationAlert.swift](../native/Explorer/ConfirmationAlert.swift)). SwiftUI drew
destructive buttons gray. The title names the item (`Move “NAME” to the Trash?`,
`Delete “NAME” immediately?`). Long names shorten in the middle. A box shows the
scope and the full path, and it scrolls when the path is long.

The buttons stack: the action on top, Cancel below. Esc cancels, and Cancel is never
the default. Return confirms only Trash. Delete Immediately is red. Under the alert,
every command is disabled, so no shortcut or menu opens a second confirmation. Rust
revalidates fresh metadata, raw paths and identity pins. Cancel, window close and
session replacement release pending pins. Replacement awaits cancellation before it
installs a new session. Root operations are disabled and Rust also protects them.
Executing operations cannot be cancelled. There is no Trash-to-delete fallback and
no permanent-delete Undo.

## 1d Executable evidence

[ExplorerCommandsTests.swift](../native/ExplorerModelTests/ExplorerCommandsTests.swift):

- "testMenusFollowMenuBarOrderAndFinderShortcuts": menu groups and order, ellipses,
  the Finder Delete shortcuts, Command-O, Command-Period and the context-menu items.
- "testMenuValidationMatchesCardStateForEveryCommand": every command in the menu bar,
  the context target and the card properties for no selection, root, file, directory,
  focus, working, pending confirmation and cancellable scan states. It also checks the
  key-window flag and the editable-text check.
- "testMenuTrashAndStopUseModelPathsWithoutLiveMetadata": validation while a live
  metadata call holds the core lock, menu Trash and context Delete preparation, no
  second preparation under the alert, consumed pins and Rust Stopping.
- "testContextMenusSelectClickedRowAndHoveredBlock": synthetic secondary clicks on a
  row and a map block, the hover rule, grouped blocks and the root.
- "testReopenLastFolderNamesTheFolderAndNoSnapshotImportExists": the full command
  list, the generic and the named reopen title, and its enable rule.

[ExplorerUITests.swift](../native/ExplorerTests/ExplorerUITests.swift):

- "testFileMenuShowsReopenWorkspaceAndNoOpenSnapshot": owned test metadata gives a
  disabled Reopen “Workspace” after Choose Folder…, and no Open Snapshot….
- "testStartScreenShowsReopenWorkspace": the fixture start screen shows Reopen
  “Workspace” and no Open Snapshot… button.
- "testOldMetadataShowsReopenLastFolder": metadata without a name gives Reopen Last
  Folder on the start screen and in the File menu.
- "testFixtureStorageDirectoryStaysUnchanged": after both fixture windows read the
  metadata, and after Command-O and a click on Reopen, the names, sizes and dates of
  the owned directory are unchanged.
- "testFileMenuCommandsMatchCardAndShortcuts": fixture-disabled panels, root then
  file state with no stale menu, Command-Delete and Option-Command-Delete, no second
  alert, and disabled commands while the About panel is key.
- "testNavigateMenuPrecedesWindowMenu": File exists and Navigate sits before Window.
- "testContextMenusOnTreeRowAndMapBlock": both context menus act on the clicked item.
- "testEditUndoIsUnavailableAfterTrash": Undo stays disabled and Command-Z does nothing.
- "testTrashConfirmationReturnConfirmsWithCancelBelowAction": Return trashes.
- "testPermanentConfirmationHasNoDefaultAndEscapeCancels": Return does nothing, Esc
  cancels, then deletion succeeds.

"testConfirmationPresentationNamesItemAndAssignsAlertRoles" in
[RedesignModelTests.swift](../native/ExplorerModelTests/RedesignModelTests.swift)
checks confirmation text and button roles.

Untested limits: the header menu in the GUI (fixture mode disables it), Command-Period
during a live scan in the GUI (fixture mode cannot
scan; the model test covers Stop Scan), an enabled Reveal in Finder (fixtures have no
Finder URL), the native open panel as a key window, and VoiceOver reading the menus.
