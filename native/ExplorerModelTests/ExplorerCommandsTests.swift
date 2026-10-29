import AppKit
import SwiftUI
import XCTest

@testable import DiskInventory

@MainActor final class ExplorerCommandsTests: XCTestCase {
  func item(_ command: ExplorerCommand) -> NSMenuItem {
    let item = NSMenuItem(
      title: command.title, action: #selector(ExplorerCommandTarget.performCommand(_:)),
      keyEquivalent: "")
    item.tag = command.rawValue
    return item
  }
  func titles(_ menu: NSMenu) -> [String] {
    menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
  }
  /// Checks the command rule, the menu-bar state, the context-menu target and the card
  /// properties for one model state.
  func assertCommands(
    _ model: ExplorerModel, enabled: Set<ExplorerCommand>, _ state: String, line: UInt = #line
  ) {
    let menu = ExplorerMenuState()
    menu.model = model
    menu.explorerWindowIsKey = true
    let target = ExplorerCommandTarget(model: model)
    for command in ExplorerCommand.allCases {
      let expected = enabled.contains(command)
      XCTAssertEqual(command.isEnabled(in: model), expected, "\(state): \(command)", line: line)
      XCTAssertEqual(menu.isEnabled(command), expected, "\(state): menu \(command)", line: line)
      XCTAssertEqual(
        target.validateMenuItem(item(command)), expected, "\(state): context \(command)",
        line: line)
    }
    // Another key window (a panel or a sheet) disables every menu-bar command.
    menu.explorerWindowIsKey = false
    XCTAssertTrue(ExplorerCommand.allCases.allSatisfy { !menu.isEnabled($0) }, state, line: line)
    // The card and the start screen read the same model properties.
    XCTAssertEqual(model.canAct, enabled.contains(.moveToTrash), state, line: line)
    XCTAssertEqual(model.canAct, enabled.contains(.deleteImmediately), state, line: line)
    XCTAssertEqual(model.canRevealInFinder, enabled.contains(.revealInFinder), state, line: line)
    XCTAssertEqual(model.canRefresh, enabled.contains(.refreshDirectory), state, line: line)
    XCTAssertEqual(model.canStopScan, enabled.contains(.stopScan), state, line: line)
    XCTAssertEqual(model.canOpenInventory, enabled.contains(.chooseFolder), state, line: line)
    XCTAssertEqual(
      model.canReopenLastFolder, enabled.contains(.reopenLastFolder), state, line: line)
  }

  func testMenusFollowMenuBarOrderAndFinderShortcuts() throws {
    XCTAssertEqual(
      ExplorerCommand.fileMenu.map { $0.map(\.title) },
      [
        ["Choose Folder…", "Reopen Last Folder"],
        ["Refresh Directory", "Stop Scan"],
        ["Reveal in Finder", "Move to Trash…", "Delete Immediately…"],
      ])
    XCTAssertEqual(
      ExplorerCommand.navigateMenu.map(\.title), ["Open Selected Directory", "Enclosing Directory"])
    // Every command is in the menu bar exactly once; the card has no command of its own.
    let menuBar = ExplorerCommand.fileMenu.flatMap { $0 } + ExplorerCommand.navigateMenu
    XCTAssertEqual(menuBar.count, ExplorerCommand.allCases.count)
    XCTAssertEqual(Set(menuBar), Set(ExplorerCommand.allCases))
    // Finder's MenuBar.nib: Move to Trash is Command-Delete and Delete Immediately is
    // Option-Command-Delete, key 0x08. Command-Period cancels an operation.
    XCTAssertEqual(KeyEquivalent.delete.character, "\u{8}")
    let shortcuts: [ExplorerCommand: (Character, EventModifiers)] = [
      .chooseFolder: ("o", .command),
      .stopScan: (".", .command),
      .moveToTrash: ("\u{8}", .command),
      .deleteImmediately: ("\u{8}", [.command, .option]),
      .openSelectedDirectory: (KeyEquivalent.downArrow.character, .command),
      .enclosingDirectory: (KeyEquivalent.upArrow.character, .command),
    ]
    for command in ExplorerCommand.allCases {
      XCTAssertEqual(command.shortcut?.key.character, shortcuts[command]?.0, command.title)
      XCTAssertEqual(command.shortcut?.modifiers, shortcuts[command]?.1, command.title)
    }
    // An ellipsis marks exactly the commands that open a panel or a confirmation.
    for command in ExplorerCommand.allCases {
      XCTAssertEqual(
        command.title.hasSuffix("…"),
        [.chooseFolder, .moveToTrash, .deleteImmediately].contains(command),
        command.title)
    }
    // Context menus offer the selected-item commands without menu-bar shortcuts.
    let target = ExplorerCommandTarget(model: nil)
    let context = target.menu()
    XCTAssertEqual(titles(context), ["Reveal in Finder", "Move to Trash…", "Delete Immediately…"])
    XCTAssertEqual(
      context.items.map { $0.identifier?.rawValue },
      ["context-revealInFinder", "context-moveToTrash", "context-deleteImmediately"])
    for item in context.items {
      XCTAssertTrue(item.target === target)
      XCTAssertEqual(item.action, #selector(ExplorerCommandTarget.performCommand(_:)))
      XCTAssertEqual(item.keyEquivalent, "")
      XCTAssertEqual(ExplorerCommand(rawValue: item.tag)?.title, item.title)
      // Without a model, nothing is enabled.
      XCTAssertFalse(target.validateMenuItem(item))
    }
  }

  func testMenuValidationMatchesCardStateForEveryCommand() async throws {
    let model = try await fixtureModel("presentation")
    defer { model.shutdown() }
    let target = ExplorerCommandTarget(model: model)
    // Fixture mode never opens native panels, and Finder URLs are fixture-locked.
    assertCommands(model, enabled: [.refreshDirectory], "no selection")
    model.select(model.records!.status.root)
    assertCommands(model, enabled: [.refreshDirectory, .openSelectedDirectory], "root")
    let file = try entry("large-file", in: model)
    model.select(file)
    assertCommands(
      model, enabled: [.refreshDirectory, .moveToTrash, .deleteImmediately], "file")
    let directory = try entry("small-files", in: model)
    model.select(directory)
    assertCommands(
      model,
      enabled: [.refreshDirectory, .moveToTrash, .deleteImmediately, .openSelectedDirectory],
      "directory")
    ExplorerCommand.openSelectedDirectory.perform(in: model)
    try await waitUntil { !model.loading && model.records?.focus.displayName == "small-files" }
    assertCommands(model, enabled: [.refreshDirectory, .enclosingDirectory], "focused")
    ExplorerCommand.enclosingDirectory.perform(in: model)
    try await waitUntil { !model.loading && model.records?.focus.parent == nil }
    model.select(try entry("large-file", in: model))
    // Delete edits text in an editable text view; a read-only text view does not take it.
    let editable = NSTextView()
    let readOnly = NSTextView()
    readOnly.isEditable = false
    for command in ExplorerCommand.allCases {
      let removes = command == .moveToTrash || command == .deleteImmediately
      XCTAssertEqual(
        target.validate(command, firstResponder: editable),
        command.isEnabled(in: model) && !removes, "editable text: \(command)")
      XCTAssertEqual(
        target.validate(command, firstResponder: readOnly), command.isEnabled(in: model),
        "read-only text: \(command)")
    }
    ExplorerCommand.moveToTrash.perform(in: model)
    XCTAssertTrue(model.working)
    assertCommands(model, enabled: [], "working")
    try await waitUntil { model.pending != nil }
    // The alert sheet is modal on the window only; the live menu bar must not act under it.
    model.scan.begin(ScanControl())
    assertCommands(model, enabled: [], "pending confirmation")
    model.scan.stopPolling(cancelScan: true)
    model.cancelConfirmation()
    try await waitUntil { model.canAct }
    model.scan.begin(ScanControl())
    assertCommands(
      model,
      enabled: [.refreshDirectory, .moveToTrash, .deleteImmediately, .stopScan],
      "cancellable scan")
    model.scan.stopPolling(cancelScan: true)

    let root = try XCTUnwrap(ProcessInfo.processInfo.environment["DI_TEST_ROOT"])
    let support = URL(fileURLWithPath: root).appendingPathComponent(
      "native-commands-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: support) }
    let storage = ManagedInventoryStorage(root: support)
    let offline = ExplorerModel(arguments: [], environment: [:], storage: storage)
    defer { offline.shutdown() }
    assertCommands(offline, enabled: [.chooseFolder], "start")
    _ = try storage.newGeneration()
    let record = ManagedInventory(
      filename: "inventory-\(UUID().uuidString).dmap", scannedAt: Date(), rootName: "/r")
    try JSONEncoder().encode(record).write(
      to: support.appendingPathComponent("last-inventory.json"))
    let later = ExplorerModel(arguments: [], environment: [:], storage: storage)
    defer { later.shutdown() }
    try await waitUntil { later.lastInventory != nil }
    assertCommands(later, enabled: [.chooseFolder, .reopenLastFolder], "start with last folder")
  }

  func testReopenLastFolderNamesTheFolderAndNoSnapshotImportExists() async throws {
    // The user chooses only folders. No command opens an arbitrary snapshot file.
    XCTAssertEqual(
      ExplorerCommand.allCases.map(\.title),
      [
        "Choose Folder…", "Reopen Last Folder", "Refresh Directory", "Stop Scan",
        "Reveal in Finder", "Move to Trash…", "Delete Immediately…", "Open Selected Directory",
        "Enclosing Directory",
      ])
    let root = try XCTUnwrap(ProcessInfo.processInfo.environment["DI_TEST_ROOT"])
    let support = URL(fileURLWithPath: root).appendingPathComponent(
      "native-reopen-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: support) }
    let storage = ManagedInventoryStorage(root: support)
    let empty = ExplorerModel(arguments: [], environment: [:], storage: storage)
    defer { empty.shutdown() }
    // The metadata read at launch has no completion signal; it finds no file.
    try await stays({ empty.lastInventory == nil }, for: quietPeriod)
    XCTAssertEqual(ExplorerCommand.reopenLastFolder.title(in: empty), "Reopen Last Folder")
    XCTAssertFalse(ExplorerCommand.reopenLastFolder.isEnabled(in: empty))

    _ = try storage.newGeneration()
    let record = ManagedInventory(
      filename: "inventory-\(UUID().uuidString).dmap", scannedAt: Date(),
      rootName: "/Users/someone/Workspace")
    try JSONEncoder().encode(record).write(
      to: support.appendingPathComponent("last-inventory.json"))
    let named = ExplorerModel(arguments: [], environment: [:], storage: storage)
    defer { named.shutdown() }
    try await waitUntil { named.lastInventory != nil }
    XCTAssertEqual(ExplorerCommand.reopenLastFolder.title(in: named), "Reopen “Workspace”")
    XCTAssertTrue(ExplorerCommand.reopenLastFolder.isEnabled(in: named))
    // The name is a label only. The reopened file comes from the owned generation name.
    XCTAssertEqual(storage.url(for: named.lastInventory!).lastPathComponent, record.filename)
    // Other commands keep their fixed titles.
    for command in ExplorerCommand.allCases where command != .reopenLastFolder {
      XCTAssertEqual(command.title(in: named), command.title)
    }
  }

  func testMenuTrashAndStopUseModelPathsWithoutLiveMetadata() async throws {
    let model = try await fixtureModel("metadata-delay")
    defer { model.shutdown() }
    let target = ExplorerCommandTarget(model: model)
    let menu = ExplorerMenuState()
    menu.model = model
    menu.explorerWindowIsKey = true
    let session = try XCTUnwrap(model.session)
    let file = try entry("large-file", in: model)
    model.select(file)
    // A live-metadata call holds the core lock for one second; validation must not wait.
    let blocker = try await holdBridge(model)
    let start = ContinuousClock.now
    for command in ExplorerCommand.allCases {
      _ = menu.isEnabled(command)
      _ = target.validateMenuItem(item(command))
    }
    XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
    XCTAssertTrue(menu.isEnabled(.moveToTrash))
    XCTAssertTrue(target.validateMenuItem(item(.moveToTrash)))
    XCTAssertTrue(session.isBusy())
    _ = try await blocker.value

    // Command-Delete runs the menu-bar command.
    menu.perform(.moveToTrash)
    try await waitUntil { model.pending != nil }
    let pending = try XCTUnwrap(model.pending)
    XCTAssertEqual(pending.details.action, .trash)
    XCTAssertEqual(pending.name, "large-file")
    // Shortcuts and menus under the alert cannot replace it or start a second preparation.
    menu.perform(.moveToTrash)
    menu.perform(.deleteImmediately)
    target.performCommand(item(.moveToTrash))
    target.performCommand(item(.deleteImmediately))
    XCTAssertFalse(model.working)
    try await stays({ model.pending?.id == pending.id && !model.working }, for: quietPeriod)
    model.cancelConfirmation()
    try await waitUntil { model.canAct }
    // The context menu prepares through the same model path.
    target.performCommand(item(.deleteImmediately))
    try await waitUntil { model.pending != nil }
    XCTAssertEqual(model.pending?.details.action, .permanentlyDelete)
    let permanent = try XCTUnwrap(model.pending?.action)
    model.cancelConfirmation()
    // Replacement awaits pin cancellation, so both retained capabilities must be consumed.
    model.load { try ExplorerSession.fixture(scenario: "presentation") }
    try await waitUntil { model.session !== session && model.records != nil && !model.loading }
    for action in [pending.action, permanent] {
      let result = await Task.detached { Result { try session.execute(action: action) } }.value
      guard case .failure(BridgeError.ConsumedAction) = result else {
        return XCTFail("The menu-prepared pin was not cancelled: \(result)")
      }
    }
    let status = try await Task.detached { try session.status() }.value
    XCTAssertFalse(status.dirty)

    let control = ScanControl()
    model.scan.begin(control)
    XCTAssertTrue(menu.isEnabled(.stopScan))
    // Command-Period runs the menu-bar Stop Scan, which asks Rust to stop.
    menu.perform(.stopScan)
    XCTAssertEqual(control.progress().phase, .stopping)
    XCTAssertEqual(model.scan.progress?.phase, .stopping)
    XCTAssertFalse(menu.isEnabled(.stopScan))
    model.scan.stopPolling(cancelScan: true)
  }

  func testContextMenusSelectClickedRowAndHoveredBlock() async throws {
    let model = try await fixtureModel("presentation")
    defer { model.shutdown() }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
      if let match = view as? T { return match }
      return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }
    func rightClick(at point: NSPoint) throws -> NSEvent {
      try XCTUnwrap(
        NSEvent.mouseEvent(
          with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1))
    }
    func assertContext(_ menu: NSMenu?, enabled: Set<ExplorerCommand>, line: UInt = #line) throws {
      let menu = try XCTUnwrap(menu, line: line)
      XCTAssertEqual(
        titles(menu), ["Reveal in Finder", "Move to Trash…", "Delete Immediately…"], line: line)
      for item in menu.items {
        let command = try XCTUnwrap(ExplorerCommand(rawValue: item.tag))
        let target = try XCTUnwrap(item.target as? ExplorerCommandTarget, line: line)
        XCTAssertEqual(target.validateMenuItem(item), enabled.contains(command), line: line)
      }
    }
    let tree = NSHostingView(rootView: ContentsTree(model: model))
    window.contentView = tree
    tree.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let table = try XCTUnwrap(find(ContentsTree.Table.self, in: tree))
    model.select(try entry("small-files", in: model))
    let file = try entry("large-file", in: model)
    let row = try XCTUnwrap(
      model.outline?.rows.firstIndex { $0.entry.key.sameEntry(other: file.key) })
    let rect = table.rect(ofRow: row)
    let menu = table.menu(
      for: try rightClick(at: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)))
    // The clicked row becomes the selection, so the commands act on that row.
    XCTAssertTrue(model.selection.entry?.key.sameEntry(other: file.key) == true)
    XCTAssertEqual(model.selection.row, row)
    try assertContext(menu, enabled: [.moveToTrash, .deleteImmediately])
    model.prepare(.trash)
    try await waitUntil { model.pending != nil }
    XCTAssertEqual(model.pending?.name, "large-file")
    // Under the alert, a secondary click shows nothing and keeps the target.
    let other = try XCTUnwrap(
      model.outline?.rows.firstIndex { $0.entry.displayName == "small-files" })
    let otherRect = table.rect(ofRow: other)
    XCTAssertNil(
      table.menu(
        for: try rightClick(
          at: table.convert(NSPoint(x: otherRect.midX, y: otherRect.midY), to: nil))))
    XCTAssertTrue(model.selection.entry?.key.sameEntry(other: file.key) == true)
    model.cancelConfirmation()
    try await waitUntil { model.canAct }
    let directory = try entry("small-files", in: model)
    model.select(directory)

    let host = NSHostingView(rootView: DiagramView(model: model))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let map = try XCTUnwrap(find(DiagramView.MapView.self, in: host))
    // The layout resized the map; wait for that debounced rebuild.
    await bounded("rebuild") { _ = await model.rebuildTask?.value }
    try await waitUntil {
      !model.loading && model.picture?.bitmap.width == UInt32(model.viewport.width)
    }
    let block = try XCTUnwrap(model.picture?.targets.first { $0.entry.displayName == "large-file" })
    let blockRect = map.rect(block.rect)
    let center = map.convert(NSPoint(x: blockRect.midX, y: blockRect.midY), to: nil)
    // No hover result for the point yet: no menu, and the selection stays.
    XCTAssertNil(map.menu(for: try rightClick(at: center)))
    XCTAssertTrue(model.selection.entry?.key.sameEntry(other: directory.key) == true)
    map.mouseMoved(
      with: try XCTUnwrap(
        NSEvent.mouseEvent(
          with: .mouseMoved, location: center, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0,
          pressure: 0)))
    try await waitUntil { model.hover?.entry.key.sameEntry(other: block.entry.key) == true }
    let hovered = try XCTUnwrap(model.hover)
    try assertContext(
      map.menu(for: try rightClick(at: center)), enabled: [.moveToTrash, .deleteImmediately])
    XCTAssertTrue(model.selection.entry?.key.sameEntry(other: hovered.entry.key) == true)
    // A point in another block, outside the hovered rectangle, shows no menu.
    let elsewhere = try XCTUnwrap(
      model.picture?.targets.first { !$0.entry.key.sameEntry(other: block.entry.key) })
    let elsewhereRect = map.rect(elsewhere.rect)
    XCTAssertFalse(blockRect.contains(NSPoint(x: elsewhereRect.midX, y: elsewhereRect.midY)))
    XCTAssertNil(
      map.menu(
        for: try rightClick(
          at: map.convert(NSPoint(x: elsewhereRect.midX, y: elsewhereRect.midY), to: nil))))
    XCTAssertTrue(model.selection.entry?.key.sameEntry(other: hovered.entry.key) == true)
    // A grouped block selects the aggregate, which disables every item command.
    model.hover = DiagramSelection(
      entry: hovered.entry, relativePath: hovered.relativePath, actionable: false,
      rect: hovered.rect, bytes: hovered.bytes)
    try assertContext(map.menu(for: try rightClick(at: center)), enabled: [])
    XCTAssertNil(model.selection.entry)
    XCTAssertTrue(model.selection.aggregate?.sameEntry(other: hovered.entry.key) == true)
    // The inventory root stays protected.
    let root = model.records!.status.root
    model.hover = DiagramSelection(
      entry: root, relativePath: Data(), actionable: true, rect: hovered.rect, bytes: 0)
    try assertContext(map.menu(for: try rightClick(at: center)), enabled: [])
    XCTAssertTrue(model.selection.entry?.key.sameEntry(other: root.key) == true)
  }
}
