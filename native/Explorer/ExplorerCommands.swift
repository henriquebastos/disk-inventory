import AppKit
import SwiftUI

/// The one command source. The menu bar, the selection card and the context menus all
/// read `isEnabled(in:)` and call `perform(in:)`. Enabled states use saved model state only.
enum ExplorerCommand: Int, CaseIterable {
  case chooseFolder = 1
  case openSnapshot
  case openLastScan
  case refreshDirectory
  case stopScan
  case revealInFinder
  case moveToTrash
  case deleteImmediately
  case openSelectedDirectory
  case enclosingDirectory

  /// File menu groups, in order. Dividers separate the groups.
  static let fileMenu: [[ExplorerCommand]] = [
    [.chooseFolder, .openSnapshot, .openLastScan],
    [.refreshDirectory, .stopScan],
    [.revealInFinder, .moveToTrash, .deleteImmediately],
  ]
  static let navigateMenu: [ExplorerCommand] = [.openSelectedDirectory, .enclosingDirectory]
  /// Commands for the item under a secondary click on a tree row or a map block.
  static let contextMenu: [ExplorerCommand] = [.revealInFinder, .moveToTrash, .deleteImmediately]

  /// An ellipsis marks a command that opens a panel or a confirmation.
  var title: String {
    switch self {
    case .chooseFolder: "Choose Folder…"
    case .openSnapshot: "Open Snapshot…"
    case .openLastScan: "Open Last Scan"
    case .refreshDirectory: "Refresh Directory"
    case .stopScan: "Stop Scan"
    case .revealInFinder: "Reveal in Finder"
    case .moveToTrash: "Move to Trash…"
    case .deleteImmediately: "Delete Immediately…"
    case .openSelectedDirectory: "Open Selected Directory"
    case .enclosingDirectory: "Enclosing Directory"
    }
  }
  /// Menu-bar shortcut. Finder's MenuBar.nib gives Move to Trash Command-Delete and
  /// Delete Immediately Option-Command-Delete. Command-Period cancels an operation.
  var shortcut: KeyboardShortcut? {
    switch self {
    case .chooseFolder: KeyboardShortcut("o", modifiers: .command)
    case .stopScan: KeyboardShortcut(".", modifiers: .command)
    case .moveToTrash: KeyboardShortcut(.delete, modifiers: .command)
    case .deleteImmediately: KeyboardShortcut(.delete, modifiers: [.command, .option])
    case .openSelectedDirectory: KeyboardShortcut(.downArrow, modifiers: .command)
    case .enclosingDirectory: KeyboardShortcut(.upArrow, modifiers: .command)
    case .openSnapshot, .openLastScan, .refreshDirectory, .revealInFinder: nil
    }
  }
  var removesItem: Bool { self == .moveToTrash || self == .deleteImmediately }

  /// Every rule is false while a confirmation is pending: the alert sheet is modal on the
  /// window, but the menu bar stays live.
  @MainActor func isEnabled(in model: ExplorerModel) -> Bool {
    switch self {
    case .chooseFolder, .openSnapshot: model.canOpenInventory
    case .openLastScan: model.canOpenLastInventory
    case .refreshDirectory: model.canRefresh
    case .stopScan: model.canStopScan
    case .revealInFinder: model.canRevealInFinder
    case .moveToTrash, .deleteImmediately: model.canAct
    case .openSelectedDirectory: model.canOpenSelectedDirectory
    case .enclosingDirectory: model.canOpenEnclosingDirectory
    }
  }
  @MainActor func perform(in model: ExplorerModel) {
    guard isEnabled(in: model) else { return }
    switch self {
    case .chooseFolder: model.createSnapshot()
    case .openSnapshot: model.openSnapshot()
    case .openLastScan: model.openLastInventory()
    case .refreshDirectory: model.refresh()
    case .stopScan: model.scan.stop()
    case .revealInFinder: model.revealInFinder()
    case .moveToTrash: model.prepare(.trash)
    case .deleteImmediately: model.prepare(.permanentlyDelete)
    case .openSelectedDirectory: model.openSelectedDirectory()
    case .enclosingDirectory: model.focusParent()
    }
  }
}

/// Menu-bar state for the SwiftUI commands. SwiftUI rebuilds `NSApp.mainMenu` and drops
/// AppKit items, so the menu bar uses `.commands`, which observes this object.
@MainActor @Observable final class ExplorerMenuState {
  var model: ExplorerModel?
  /// Menu-bar commands act only while the explorer window is key. SwiftUI menu validation
  /// cannot read the first responder, and the explorer window has no editable text view, so
  /// this flag replaces the editable-text check that the context menus keep. If the explorer
  /// window gets an editable text view, Delete shortcuts must check the first responder again.
  var explorerWindowIsKey = false

  func isEnabled(_ command: ExplorerCommand) -> Bool {
    guard explorerWindowIsKey, let model else { return false }
    return command.isEnabled(in: model)
  }
  func perform(_ command: ExplorerCommand) {
    guard isEnabled(command), let model else { return }
    command.perform(in: model)
  }
}

/// File and Navigate menu-bar items. SwiftUI shows the File menu for the replaced
/// new-item group and places Navigate between View and Window.
struct ExplorerMenuCommands: Commands {
  let state: ExplorerMenuState
  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      ForEach(Array(ExplorerCommand.fileMenu.enumerated()), id: \.offset) { index, group in
        if index > 0 { Divider() }
        ForEach(group, id: \.self) { button($0) }
      }
    }
    CommandMenu("Navigate") {
      ForEach(ExplorerCommand.navigateMenu, id: \.self) { button($0) }
    }
  }
  private func button(_ command: ExplorerCommand) -> some View {
    Button(command.title) { state.perform(command) }
      .keyboardShortcut(command.shortcut)
      .disabled(!state.isEnabled(command))
  }
}

/// Context-menu target for tree rows and map blocks. `NSMenuItem.target` is weak, so the
/// tree coordinator and the map view each hold one.
@MainActor final class ExplorerCommandTarget: NSObject, NSMenuItemValidation {
  weak var model: ExplorerModel?
  init(model: ExplorerModel?) { self.model = model }

  func menu() -> NSMenu {
    let menu = NSMenu(title: "")
    for command in ExplorerCommand.contextMenu {
      let item = NSMenuItem(
        title: command.title, action: #selector(performCommand(_:)), keyEquivalent: "")
      item.tag = command.rawValue
      item.target = self
      item.identifier = NSUserInterfaceItemIdentifier("context-\(command)")
      menu.addItem(item)
    }
    return menu
  }
  /// Delete keys edit text in an editable text view, so removal waits until it loses focus.
  func validate(_ command: ExplorerCommand, firstResponder: NSResponder?) -> Bool {
    guard let model, command.isEnabled(in: model) else { return false }
    if command.removesItem, let text = firstResponder as? NSTextView, text.isEditable {
      return false
    }
    return true
  }
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let command = ExplorerCommand(rawValue: menuItem.tag) else { return false }
    return validate(command, firstResponder: NSApp.keyWindow?.firstResponder)
  }
  @objc func performCommand(_ sender: NSMenuItem) {
    guard let model, let command = ExplorerCommand(rawValue: sender.tag),
      validate(command, firstResponder: NSApp.keyWindow?.firstResponder)
    else { return }
    command.perform(in: model)
  }
}
