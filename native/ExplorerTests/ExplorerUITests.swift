import AppKit
import XCTest

@MainActor final class ExplorerUITests: XCTestCase {
  var app: XCUIApplication!
  /// Directories that a test owns. Teardown deletes them.
  var ownedDirectories: [URL] = []
  override func setUpWithError() throws { continueAfterFailure = false }
  override func tearDownWithError() throws {
    for directory in ownedDirectories { try? FileManager.default.removeItem(at: directory) }
  }
  func launch(
    _ scenario: String = "presentation", minimumWindow: Bool = false, reduceMotion: Bool = false,
    locale: String = "en_US", storage: URL? = nil
  ) {
    app = XCUIApplication()
    app.launchArguments = ["--fixture-mode", "--scenario", scenario, "-AppleLocale", locale]
    if minimumWindow { app.launchArguments.append("--minimum-window") }
    app.launchEnvironment["DI_UI_TEST"] = "1"
    app.launchEnvironment["DI_MODEL_TEST"] = "0"
    // Fixture-only override; the system Reduce Motion setting is never changed.
    if reduceMotion { app.launchEnvironment["DI_REDUCE_MOTION"] = "1" }
    // Fixture-only, read-only metadata root that the test owns.
    if let storage { app.launchEnvironment["DI_FIXTURE_STORAGE_ROOT"] = storage.path }
    app.launch()
    XCTAssertTrue(app.staticTexts["scope-total"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.windows.firstMatch.title, "Disk Inventory — SIMULATED")
  }
  func row(_ name: String) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "identifier == %@", "entry-\(name)")).firstMatch
  }
  func text(_ id: String, contains value: String, timeout: TimeInterval = 8) {
    let element = id == "selected-name" ? app.buttons[id] : app.staticTexts[id]
    XCTAssertTrue(element.waitForExistence(timeout: timeout))
    let predicate = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", value, value)
    let result = XCTWaiter.wait(
      for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
    if result != .completed {
      screenshot("failure-\(id)")
      print("UI_STATE id=\(id) actual=\(String(describing: element.value))")
    }
    XCTAssertEqual(result, .completed, "\(id) must contain \(value)")
  }
  func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  func prepare(_ action: String, target: String) {
    XCTAssertEqual(app.windows.firstMatch.title, "Disk Inventory — SIMULATED")
    row(target).click()
    app.buttons[action].click()
    XCTAssertTrue(app.staticTexts["confirmation-title"].waitForExistence(timeout: 8))
    text("confirmation-path", contains: target)
  }
  func disclosure(_ name: String) -> XCUIElement {
    app.descendants(matching: .disclosureTriangle).matching(identifier: "disclosure-\(name)")
      .firstMatch
  }
  func testDisclosureKeyboardZoomBreadcrumbAndUsage() throws {
    launch()
    row("small-files").click()
    disclosure("small-files").click()
    text("focus-name", contains: "Workspace")
    XCTAssertTrue(row("small-00").waitForExistence(timeout: 8))
    row("small-00").click()
    app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
    text("selected-name", contains: "small-01")
    text("selected-usage", contains: "64 bytes")
    app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
    text("selected-name", contains: "small-files")
    screenshot("expanded-tree-linked-selection")
    row("small-files").doubleClick()
    text("focus-name", contains: "small-files")
    app.buttons["breadcrumb-0"].click()
    text("focus-name", contains: "Workspace")
    XCTAssertTrue(row("small-00").waitForExistence(timeout: 8))
    text("selected-name", contains: "small-files")
    screenshot("restored-tree-context")
    app.outlines["entry-tree"].scroll(byDeltaX: 0, deltaY: -600)
    let scrollbar = app.scrollBars.firstMatch
    let before = try XCTUnwrap(Double(String(describing: try XCTUnwrap(scrollbar.value))))
    XCTAssertGreaterThan(before, 0.1)
    XCTAssertFalse(row("small-files").isHittable)
    screenshot("scrolled-tree-before-zoom")
    app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [.command])
    text("focus-name", contains: "small-files")
    app.buttons["breadcrumb-0"].click()
    text("focus-name", contains: "Workspace")
    text("selected-name", contains: "small-files")
    let after = try XCTUnwrap(Double(String(describing: try XCTUnwrap(scrollbar.value))))
    // Scroll history stores a row, so restoration can round by less than one row.
    XCTAssertEqual(after, before, accuracy: 0.02)
    XCTAssertFalse(row("small-files").isHittable)
    screenshot("scrolled-tree-restored")
    app.outlines["entry-tree"].scroll(byDeltaX: 0, deltaY: 600)
    XCTAssertTrue(disclosure("small-files").isHittable)
    disclosure("small-files").click()
    XCTAssertTrue(row("small-00").waitForNonExistence(timeout: 8))
    row("large-file").click()
    text("selected-usage", contains: "4.1 KB")
    screenshot("balanced-overview")
  }
  func testConfirmationCancelDeleteAndStaleHandleRecovery() {
    launch()
    prepare("delete", target: "large-file")
    screenshot("permanent-confirmation")
    app.buttons["cancel-action"].click()
    XCTAssertTrue(row("large-file").exists)
    prepare("delete", target: "large-file")
    app.buttons["confirm-action"].click()
    text("outcome", contains: "Permanently deleted")
    XCTAssertFalse(row("large-file").exists)
    XCTAssertTrue(app.staticTexts["dirty"].exists)
    app.buttons["inspect-root"].click()
    XCTAssertTrue(app.staticTexts["root-protected"].exists)
    XCTAssertFalse(app.buttons["delete"].isEnabled)
    screenshot("deleted-live-inventory")
  }
  func testTrashConfirmationReturnConfirmsWithCancelBelowAction() {
    launch("trash-outside")
    prepare("trash", target: "large-file")
    let cancel = app.buttons["cancel-action"]
    let action = app.buttons["confirm-action"]
    XCTAssertEqual(action.title, "Move to Trash")
    // The macOS alert stacks its buttons: the default on top, Cancel at the bottom.
    XCTAssertGreaterThanOrEqual(cancel.frame.minY, action.frame.maxY - 1)
    XCTAssertEqual(cancel.frame.midX, action.frame.midX, accuracy: 2)
    text("confirmation-title", contains: "Move “large-file” to the Trash?")
    screenshot("trash-confirmation-default-action")
    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    text("outcome", contains: "Moved to Trash")
    XCTAssertTrue(row("large-file").waitForNonExistence(timeout: 8))
  }
  func testPermanentConfirmationHasNoDefaultAndEscapeCancels() {
    launch()
    prepare("delete", target: "large-file")
    let title = app.staticTexts["confirmation-title"]
    // Return has no default button to press: the alert and the row stay.
    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    XCTAssertFalse(title.waitForNonExistence(timeout: 2))
    XCTAssertTrue(row("large-file").exists)
    text("confirmation-title", contains: "Delete “large-file” immediately?")
    XCTAssertEqual(app.buttons["confirm-action"].title, "Delete Immediately")
    XCTAssertGreaterThanOrEqual(
      app.buttons["cancel-action"].frame.minY, app.buttons["confirm-action"].frame.maxY - 1)
    screenshot("permanent-confirmation-without-default")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(title.waitForNonExistence(timeout: 8))
    XCTAssertTrue(row("large-file").exists)
    XCTAssertFalse(app.staticTexts["outcome"].exists)
    // A second preparation after Esc must present a new alert.
    prepare("delete", target: "large-file")
    app.buttons["confirm-action"].click()
    text("outcome", contains: "Permanently deleted")
    XCTAssertTrue(row("large-file").waitForNonExistence(timeout: 8))
  }
  func testTrashInsideAndOutside() {
    for scenario in ["trash-inside", "trash-outside"] {
      launch(scenario)
      let before = app.staticTexts["scope-total"].value as? String
      prepare("trash", target: "large-file")
      screenshot("\(scenario)-confirmation")
      app.buttons["confirm-action"].click()
      text(
        "outcome",
        contains: scenario == "trash-inside" ? "inside this inventory" : "outside this inventory")
      XCTAssertFalse(row("large-file").exists)
      let after = app.staticTexts["scope-total"].value as? String
      if scenario == "trash-inside" {
        XCTAssertEqual(before, after)
      } else {
        XCTAssertNotEqual(before, after)
      }
      if scenario == "trash-inside" {
        row("trash").doubleClick()
        XCTAssertTrue(row("moved").waitForExistence(timeout: 8))
      }
      screenshot(scenario)
      app.terminate()
    }
  }
  func testFailuresPartialUnknownAndSavedOnlySelection() {
    for (scenario, target, action, expected) in [
      ("trash-failure", "large-file", "trash", "Failed"),
      ("trash-unknown", "large-file", "trash", "unknown"),
      ("trash-missing", "large-file", "trash", "Indeterminate"),
      ("permission-failure", "large-file", "delete", "Failed"),
      ("partial-deletion", "small-files", "delete", "Partial"),
    ] {
      launch(scenario)
      prepare(action, target: target)
      app.buttons["confirm-action"].click()
      text("outcome", contains: expected)
      if scenario == "partial-deletion" {
        XCTAssertTrue(row("small-files").exists)
        XCTAssertTrue(app.staticTexts["stale"].exists)
        screenshot("partial-survivors")
      }
      app.terminate()
    }
    launch("metadata-failure")
    row("large-file").click()
    text("selected-path", contains: "large-file")
    XCTAssertFalse(app.staticTexts["metadata-state"].exists)
    XCTAssertTrue(app.buttons["delete"].isEnabled)
    text("selected-name", contains: "large-file")
    screenshot("saved-only-selection")
  }
  func testChangedTargetAndUnknownAllocation() {
    launch("changed-target")
    row("large-file").click()
    app.buttons["delete"].click()
    text("error", contains: "Could not complete")
    XCTAssertFalse(app.buttons["confirm-action"].exists)
    app.terminate()
    launch("unknown-allocation")
    app.buttons["refresh"].click()
    XCTAssertTrue(app.staticTexts["stale"].waitForExistence(timeout: 8))
    XCTAssertTrue(row("unknown-a").exists)
    row("unknown-a").click()
    text("sharing-note", contains: "Shared or unknown")
    screenshot("unknown-allocation")
  }
  func testImmediateSavedOnlySelection() {
    launch("metadata-delay")
    row("large-file").click()
    let start = Date()
    row("zero-byte").click()
    text("selected-name", contains: "zero-byte")
    let elapsed = Date().timeIntervalSince(start)
    print("RESPONSIVENESS XCUITest click+AX selected-name assertion: \(elapsed) seconds")
    text("selected-usage", contains: "0 bytes")
    text("selected-path", contains: "zero-byte")
    XCTAssertFalse(app.staticTexts["metadata-state"].exists)
    text("selected-name", contains: "zero-byte")
    screenshot("responsive-later-selection")
  }
  func testFixtureModeFailsClosed() {
    for arguments in [["--fixture-mode"], ["--fixture-mode", "--scenario", "unknown"]] {
      app = XCUIApplication()
      app.launchArguments = arguments
      app.launchEnvironment["DI_UI_TEST"] = "1"
      app.launchEnvironment["DI_MODEL_TEST"] = "0"
      app.launch()
      XCTAssertTrue(app.staticTexts["fixture-locked"].waitForExistence(timeout: 8))
      XCTAssertFalse(app.buttons["open-snapshot"].exists)
      XCTAssertFalse(app.buttons["create-inventory"].isEnabled)
      XCTAssertEqual(app.dialogs.count, 0)
      XCTAssertFalse(app.staticTexts["scope-total"].exists)
      XCTAssertEqual(app.windows.firstMatch.title, "Disk Inventory — SIMULATED")
      screenshot("fail-closed")
      app.terminate()
    }
  }
  func testFixtureModeNamesSimulationOnlyInWindowTitle() throws {
    launch()
    row("large-file").click()
    app.buttons["delete"].click()
    XCTAssertTrue(app.staticTexts["confirmation-path"].waitForExistence(timeout: 8))
    // Walk the window, including its confirmation sheet. Only the window title and its
    // title-bar text element are exempt.
    let window = try app.windows.firstMatch.snapshot()
    var marked: [String] = []
    var identifiers: Set<String> = []
    func visit(_ element: XCUIElementSnapshot, isWindow: Bool) {
      identifiers.insert(element.identifier)
      let value = element.value as? String ?? ""
      let texts = isWindow ? [value] : [element.label, element.title, value]
      for text in texts
      where text != window.title && text.range(of: "simulat", options: .caseInsensitive) != nil {
        marked.append("\(element.elementType.rawValue) \(element.identifier): \(text)")
      }
      for child in element.children { visit(child, isWindow: false) }
    }
    XCTAssertEqual(window.title, "Disk Inventory — SIMULATED")
    visit(window, isWindow: true)
    XCTAssertTrue(identifiers.isSuperset(of: ["confirmation-path", "scope-total", "focus-name"]))
    XCTAssertEqual(marked, [])
    screenshot("simulation-title-only-confirmation")
    app.buttons["cancel-action"].click()
  }
  func testDirectoryConfirmationsKeepOnlyTargetScopeAndWarnings() {
    launch()
    row("small-files").click()
    text("selected-usage", contains: "8.2 KB")
    for action in ["trash", "delete"] {
      prepare(action, target: "small-files")
      text("confirmation-title", contains: "“small-files”")
      text("confirmation-scope", contains: "Directory and its contents")
      XCTAssertLessThan(
        app.staticTexts["confirmation-scope"].frame.maxY,
        app.staticTexts["confirmation-path"].frame.minY + 1)
      text(
        "confirmation-warning",
        contains: action == "trash" ? "Trash may not free space until emptied." : "cannot be undone"
      )
      XCTAssertFalse(
        app.staticTexts.matching(
          NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "If Trash fails", "If Trash fails")
        ).firstMatch.exists)
      XCTAssertFalse(app.staticTexts["directory-size-scope"].exists)
      XCTAssertFalse(app.staticTexts["confirmation-hex"].exists)
      XCTAssertFalse(app.staticTexts["Device / inode"].exists)
      XCTAssertTrue(app.buttons["cancel-action"].isHittable)
      XCTAssertTrue(app.buttons["confirm-action"].isHittable)
      screenshot("directory-\(action)-confirmation")
      app.buttons["cancel-action"].click()
      XCTAssertTrue(row("small-files").exists)
    }
  }

  func testDenseMapHoverClickRevealAndTinyDirectoryZoom() {
    launch("dix")
    let target = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "map-file-asset-")
    ).firstMatch
    XCTAssertTrue(target.waitForExistence(timeout: 8))
    let name = target.label
    screenshot("dix-dense-overview")
    row("Movie.mov").click()
    target.hover()
    text("hover-name", contains: name)
    text("selected-name", contains: "Movie.mov")
    screenshot("dix-independent-hover")
    target.click()
    text("selected-name", contains: name)
    text("focus-name", contains: "Workspace")
    XCTAssertTrue(row(name).waitForExistence(timeout: 8))
    screenshot("dix-linked-reveal")
    XCTAssertTrue(disclosure("Projects").isEnabled)
    disclosure("Projects").click()
    // Disclosure publishes a Rust worker result asynchronously; event delivery is not publication.
    XCTAssertTrue(row(name).waitForNonExistence(timeout: 8))
    text("selected-name", contains: name)
    screenshot("dix-disclosure-collapsed")
    row("Tiny files").doubleClick()
    text("focus-name", contains: "Tiny files")
    screenshot("dix-tiny-directory")
    row("Notes").doubleClick()
    text("focus-name", contains: "Notes")
    let small = app.buttons["map-file-four-KiB.txt"]
    XCTAssertTrue(small.waitForExistence(timeout: 8))
    small.hover()
    text("hover-name", contains: "four-KiB.txt")
    small.click()
    text("selected-name", contains: "four-KiB.txt")
    text("selected-usage", contains: "4.1 KB")
    XCTAssertTrue(row("empty.txt").exists)
    screenshot("dix-tiny-zoom")
    app.buttons["breadcrumb-1"].click()
    text("focus-name", contains: "Tiny files")
    screenshot("dix-back-context")
  }

  func testLongDirectoryPathAndSimpleConfirmationAtMinimumWindow() {
    launch("visual-details", minimumWindow: true)
    XCTAssertEqual(app.windows.firstMatch.frame.width, 1100, accuracy: 1)
    // AppKit adds the current titlebar/border to the minimum 680-point content height.
    XCTAssertEqual(app.windows.firstMatch.frame.height, 712, accuracy: 1)
    row("long-path").doubleClick()
    for i in 0..<3 {
      let name = "segment-\(i)-" + String(repeating: "long-name-", count: 18)
      XCTAssertTrue(row(name).waitForExistence(timeout: 8))
      row(name).doubleClick()
    }
    prepare("delete", target: "target-directory")
    text("confirmation-title", contains: "Delete “target-directory” immediately?")
    text("confirmation-scope", contains: "Directory and its contents")
    let details = app.windows.firstMatch
    let path = app.staticTexts["confirmation-path"]
    XCTAssertLessThan(app.staticTexts["confirmation-scope"].frame.maxY, path.frame.minY + 1)
    XCTAssertGreaterThanOrEqual(path.frame.minY, details.frame.minY - 2)
    XCTAssertLessThanOrEqual(path.frame.maxY, details.frame.maxY + 2)
    XCTAssertFalse(app.checkBoxes["show-target-hex"].exists)
    XCTAssertFalse(app.staticTexts["confirmation-hex"].exists)
    text("confirmation-warning", contains: "cannot be undone")
    XCTAssertTrue(app.buttons["cancel-action"].isHittable)
    XCTAssertTrue(app.buttons["confirm-action"].isHittable)
    screenshot("minimum-window-long-path-confirmation")
    app.buttons["cancel-action"].click()
    XCTAssertTrue(row("target-directory").exists)
  }

  func testLocalizedStorageInTreeSelectionFooterAndConfirmation() {
    for (locale, amount, total) in [
      ("en_US", "4.1 KB", "13 KB"), ("pt_BR", "4,1 KB", "13 KB"),
    ] {
      launch(locale: locale)
      row("large-file").click()
      text("selected-usage", contains: amount)
      text("scope-total", contains: total)
      XCTAssertGreaterThanOrEqual(
        app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", amount, amount))
          .count,
        2)
      let tile = app.buttons["map-file-large-file"]
      XCTAssertTrue(tile.waitForExistence(timeout: 8))
      tile.hover()
      text("hover-name", contains: amount)
      prepare("delete", target: "large-file")
      text("confirmation-path", contains: "large-file")
      text("confirmation-warning", contains: "cannot be undone")
      XCTAssertFalse(app.staticTexts["4,096 bytes"].exists)
      screenshot("localized-storage-\(locale)")
      app.buttons["cancel-action"].click()
      app.terminate()
    }
  }

  func menuBarItem(_ title: String) -> XCUIElement { app.menuBars.menuBarItems[title] }
  /// Opens a menu-bar menu and returns its item; the caller closes the menu with Esc.
  func menuItem(_ menu: String, _ title: String) -> XCUIElement {
    menuBarItem(menu).click()
    let item = menuBarItem(menu).menuItems[title]
    XCTAssertTrue(item.waitForExistence(timeout: 5), "\(menu) > \(title)")
    return item
  }
  func contextItem(_ title: String) -> XCUIElement {
    app.menuItems.matching(NSPredicate(format: "identifier == %@", "context-\(title)")).firstMatch
  }
  func testFileMenuCommandsMatchCardAndShortcuts() {
    launch()
    // Fixture mode keeps the native panels closed in the menu as on the start screen.
    XCTAssertFalse(menuItem("File", "Choose Folder…").isEnabled)
    XCTAssertFalse(menuBarItem("File").menuItems["Reopen Last Folder"].isEnabled)
    XCTAssertTrue(menuBarItem("File").menuItems["Refresh Directory"].isEnabled)
    XCTAssertFalse(menuBarItem("File").menuItems["Stop Scan"].isEnabled)
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    // The protected root disables both removals in the card, the menu and the shortcuts.
    let title = app.staticTexts["confirmation-title"]
    app.buttons["inspect-root"].click()
    XCTAssertTrue(app.staticTexts["root-protected"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.buttons["trash"].isEnabled)
    XCTAssertFalse(app.buttons["delete"].isEnabled)
    XCTAssertFalse(menuItem("File", "Move to Trash…").isEnabled)
    XCTAssertFalse(menuBarItem("File").menuItems["Delete Immediately…"].isEnabled)
    screenshot("file-menu-root-disabled")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [.command])
    app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [.command, .option])
    XCTAssertFalse(title.waitForExistence(timeout: 2))
    // A new selection refreshes the menu: no stale root state.
    row("large-file").click()
    text("selected-name", contains: "large-file")
    XCTAssertTrue(app.buttons["trash"].isEnabled)
    XCTAssertFalse(app.buttons["reveal-finder"].isEnabled)
    XCTAssertFalse(menuItem("File", "Reveal in Finder").isEnabled)
    XCTAssertTrue(menuBarItem("File").menuItems["Move to Trash…"].isEnabled)
    XCTAssertTrue(menuBarItem("File").menuItems["Delete Immediately…"].isEnabled)
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [.command])
    XCTAssertTrue(title.waitForExistence(timeout: 8))
    text("confirmation-title", contains: "Move “large-file” to the Trash?")
    // Under the alert, both shortcuts and the menu items do nothing.
    app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [.command])
    app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [.command, .option])
    XCTAssertFalse(title.waitForNonExistence(timeout: 2))
    text("confirmation-title", contains: "Move “large-file” to the Trash?")
    XCTAssertEqual(app.sheets.count, 1)
    XCTAssertFalse(menuItem("File", "Move to Trash…").isEnabled)
    XCTAssertFalse(menuBarItem("File").menuItems["Delete Immediately…"].isEnabled)
    XCTAssertFalse(menuBarItem("File").menuItems["Refresh Directory"].isEnabled)
    screenshot("file-menu-under-trash-alert")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(title.exists)
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(title.waitForNonExistence(timeout: 8))
    XCTAssertTrue(row("large-file").exists)
    app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [.command, .option])
    XCTAssertTrue(title.waitForExistence(timeout: 8))
    text("confirmation-title", contains: "Delete “large-file” immediately?")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(title.waitForNonExistence(timeout: 8))
    XCTAssertTrue(row("large-file").exists)
    // Another key window (the standard About panel) disables the explorer commands.
    // Index 0 is the Apple menu; index 1 is this app's menu.
    let appMenu = app.menuBars.menuBarItems.element(boundBy: 1)
    appMenu.click()
    appMenu.menuItems["orderFrontStandardAboutPanel:"].click()
    let deadline = Date().addingTimeInterval(5)
    while app.windows.count + app.dialogs.count < 2, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.1)
    }
    XCTAssertGreaterThanOrEqual(app.windows.count + app.dialogs.count, 2)
    XCTAssertFalse(menuItem("File", "Move to Trash…").isEnabled)
    XCTAssertFalse(menuBarItem("File").menuItems["Delete Immediately…"].isEnabled)
    screenshot("file-menu-about-panel-key")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [.command])
    app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [.command, .option])
    XCTAssertFalse(title.waitForExistence(timeout: 2))
    XCTAssertTrue(row("large-file").exists)
  }
  func testNavigateMenuPrecedesWindowMenu() {
    launch()
    let titles = app.menuBars.menuBarItems.allElementsBoundByIndex.map(\.title)
    let navigate = titles.firstIndex(of: "Navigate")
    XCTAssertNotNil(navigate, "\(titles)")
    XCTAssertTrue(titles.contains("File"), "\(titles)")
    XCTAssertEqual(navigate.map { titles.index(after: $0) }, titles.firstIndex(of: "Window"))
    XCTAssertLessThan(navigate ?? .max, titles.firstIndex(of: "Help") ?? -1, "\(titles)")
    XCTAssertLessThan(titles.firstIndex(of: "File") ?? .max, navigate ?? -1, "\(titles)")
  }
  /// Writes last-folder metadata into a new directory that the test owns. A nil `rootName`
  /// writes metadata without the field.
  func lastFolderMetadata(rootName: String?) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reopen-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var record: [String: Any] = [
      "filename": "inventory-\(UUID().uuidString).dmap",
      "scannedAt": Date().timeIntervalSinceReferenceDate,
    ]
    if let rootName { record["rootName"] = rootName }
    try JSONSerialization.data(withJSONObject: record).write(
      to: directory.appendingPathComponent("last-inventory.json"))
    ownedDirectories.append(directory)
    return directory
  }
  /// Names, sizes and modification dates of the files in `directory`.
  func listing(_ directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted().map {
      let attributes = try FileManager.default.attributesOfItem(
        atPath: directory.appendingPathComponent($0).path)
      return "\($0) \(attributes[.size] ?? 0) \(attributes[.modificationDate] ?? 0)"
    }
  }
  /// The fail-closed fixture start screen: no scenario, native access disabled.
  func launchStartScreen(storage: URL) {
    app = XCUIApplication()
    app.launchArguments = ["--fixture-mode", "-AppleLocale", "en_US"]
    app.launchEnvironment["DI_UI_TEST"] = "1"
    app.launchEnvironment["DI_MODEL_TEST"] = "0"
    app.launchEnvironment["DI_FIXTURE_STORAGE_ROOT"] = storage.path
    app.launch()
    XCTAssertTrue(app.staticTexts["fixture-locked"].waitForExistence(timeout: 8))
    XCTAssertEqual(app.windows.firstMatch.title, "Disk Inventory — SIMULATED")
  }
  func fileMenuTitles() -> [String] {
    menuBarItem("File").click()
    XCTAssertTrue(menuBarItem("File").menuItems["Choose Folder…"].waitForExistence(timeout: 5))
    return menuBarItem("File").menuItems.allElementsBoundByIndex.map(\.title)
  }
  func testFileMenuShowsReopenWorkspaceAndNoOpenSnapshot() throws {
    launch(storage: try lastFolderMetadata(rootName: "/Workspace"))
    let titles = fileMenuTitles()
    XCTAssertEqual(
      Array(titles.prefix(2)), ["Choose Folder…", "Reopen “Workspace”"], "\(titles)")
    XCTAssertFalse(titles.contains("Open Snapshot…"), "\(titles)")
    XCTAssertFalse(titles.contains { $0.hasPrefix("Open Last") }, "\(titles)")
    // Fixture mode only reads the metadata. Reopen stays disabled.
    XCTAssertFalse(menuBarItem("File").menuItems["Reopen “Workspace”"].isEnabled)
    screenshot("reopen-file-menu")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
  }
  func testStartScreenShowsReopenWorkspace() throws {
    launchStartScreen(storage: try lastFolderMetadata(rootName: "/Workspace"))
    let reopen = app.buttons["reopen-last-folder"]
    XCTAssertTrue(reopen.waitForExistence(timeout: 8))
    XCTAssertEqual(reopen.label, "Reopen “Workspace”")
    XCTAssertFalse(reopen.isEnabled)
    XCTAssertFalse(app.buttons["open-snapshot"].exists)
    XCTAssertFalse(app.buttons["Open Snapshot…"].exists)
    screenshot("reopen-start-screen")
  }
  func testOldMetadataShowsReopenLastFolder() throws {
    launchStartScreen(storage: try lastFolderMetadata(rootName: nil))
    let reopen = app.buttons["reopen-last-folder"]
    XCTAssertTrue(reopen.waitForExistence(timeout: 8))
    XCTAssertEqual(reopen.label, "Reopen Last Folder")
    let titles = fileMenuTitles()
    XCTAssertEqual(
      Array(titles.prefix(2)), ["Choose Folder…", "Reopen Last Folder"], "\(titles)")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    screenshot("reopen-start-screen-old-metadata")
  }
  func testFixtureStorageDirectoryStaysUnchanged() throws {
    let storage = try lastFolderMetadata(rootName: "/Workspace")
    let before = try listing(storage)
    launch(storage: storage)
    // The label proves that the app read this directory.
    XCTAssertTrue(menuItem("File", "Reopen “Workspace”").exists)
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    app.typeKey("o", modifierFlags: [.command])
    XCTAssertEqual(app.dialogs.count, 0)
    app.terminate()
    launchStartScreen(storage: storage)
    let reopen = app.buttons["reopen-last-folder"]
    XCTAssertTrue(reopen.waitForExistence(timeout: 8))
    XCTAssertEqual(reopen.label, "Reopen “Workspace”")
    reopen.click()
    app.typeKey("o", modifierFlags: [.command])
    XCTAssertEqual(app.dialogs.count, 0)
    XCTAssertTrue(app.staticTexts["fixture-locked"].exists)
    app.terminate()
    XCTAssertEqual(try listing(storage), before)
  }
  /// Vertical center of the text drawn inside `element` and `row`, in screen points. The ink
  /// runs from its top pixel row down to the baseline: the most common lowest ink row of the
  /// pixel columns, so a descender does not move the center.
  func inkCenter(_ element: XCUIElement, row: XCUIElement, image: NSBitmapImageRep) -> CGFloat? {
    let screen = NSScreen.screens.first?.frame ?? .zero
    let scale = CGFloat(image.pixelsWide) / screen.width
    let frame = element.frame.intersection(row.frame.insetBy(dx: 0, dy: 1.5))
    let x0 = Int(frame.minX * scale)
    let x1 = Int((frame.maxX - 1) * scale)
    let y0 = Int(frame.minY * scale)
    let y1 = Int(frame.maxY * scale)
    guard x0 < x1, y0 < y1 else { return nil }
    var pixel = [Int](repeating: 0, count: 8)
    var reference = [Int](repeating: 0, count: 8)
    var top: Int?
    var lowest: [Int: Int] = [:]
    for y in y0..<y1 {
      // One point left of the text frame is background on every pixel row.
      image.getPixel(&reference, atX: x0 - Int(scale), y: y)
      for x in x0..<x1 {
        image.getPixel(&pixel, atX: x, y: y)
        if (0..<3).contains(where: { abs(pixel[$0] - reference[$0]) > 64 }) {
          top = top ?? y
          lowest[x] = y
        }
      }
    }
    let rows = Dictionary(grouping: lowest.values, by: { $0 }).mapValues(\.count)
    guard let top, let baseline = rows.max(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key
    else { return nil }
    return CGFloat(top + baseline + 1) / 2 / scale
  }
  func testTreeSizeTextCentersWithNameOnSelectedAndUnselectedRows() throws {
    launch()
    continueAfterFailure = true  // Report both rows.
    row("small-files").click()
    text("selected-name", contains: "small-files")
    let image = try XCTUnwrap(
      NSBitmapImageRep(data: XCUIScreen.main.screenshot().pngRepresentation))
    XCTAssertEqual(image.bitsPerSample, 8)
    for (name, selected) in [("small-files", true), ("trash", false)] {
      let tableRow = app.outlines["entry-tree"].tableRows.containing(
        .staticText, identifier: "entry-\(name)"
      ).firstMatch
      XCTAssertEqual(tableRow.isSelected, selected, name)
      let size = tableRow.staticTexts["tree-size"]
      XCTAssertTrue(size.exists, name)
      let nameCenter = try XCTUnwrap(inkCenter(row(name), row: tableRow, image: image), name)
      let sizeCenter = try XCTUnwrap(inkCenter(size, row: tableRow, image: image), name)
      XCTAssertEqual(
        sizeCenter, nameCenter, accuracy: 1,
        "\(name): size text center \(sizeCenter), name text center \(nameCenter)")
    }
    screenshot("tree-size-centered")
  }
  func testContextMenusOnTreeRowAndMapBlock() {
    launch()
    row("small-files").click()
    text("selected-name", contains: "small-files")
    row("large-file").rightClick()
    XCTAssertTrue(contextItem("moveToTrash").waitForExistence(timeout: 5))
    // The clicked row is the target, not the earlier selection.
    text("selected-name", contains: "large-file")
    XCTAssertFalse(contextItem("revealInFinder").isEnabled)
    XCTAssertTrue(contextItem("deleteImmediately").isEnabled)
    screenshot("context-menu-tree-row")
    contextItem("moveToTrash").click()
    XCTAssertTrue(app.staticTexts["confirmation-title"].waitForExistence(timeout: 8))
    text("confirmation-title", contains: "Move “large-file” to the Trash?")
    app.buttons["cancel-action"].click()
    XCTAssertTrue(app.staticTexts["confirmation-title"].waitForNonExistence(timeout: 8))
    row("small-files").click()
    text("selected-name", contains: "small-files")
    let tile = app.buttons["map-file-large-file"]
    XCTAssertTrue(tile.waitForExistence(timeout: 8))
    tile.hover()
    text("hover-name", contains: "large-file")
    tile.rightClick()
    XCTAssertTrue(contextItem("deleteImmediately").waitForExistence(timeout: 5))
    text("selected-name", contains: "large-file")
    screenshot("context-menu-map-block")
    contextItem("deleteImmediately").click()
    XCTAssertTrue(app.staticTexts["confirmation-title"].waitForExistence(timeout: 8))
    text("confirmation-title", contains: "Delete “large-file” immediately?")
    app.buttons["cancel-action"].click()
    XCTAssertTrue(row("large-file").exists)
  }
  func testEditUndoIsUnavailableAfterTrash() {
    launch("trash-outside")
    prepare("trash", target: "large-file")
    app.buttons["confirm-action"].click()
    text("outcome", contains: "Moved to Trash")
    XCTAssertTrue(row("large-file").waitForNonExistence(timeout: 8))
    let undo = menuItem("Edit", "Undo")
    XCTAssertFalse(undo.isEnabled)
    screenshot("edit-menu-after-trash")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    app.typeKey("z", modifierFlags: [.command])
    XCTAssertFalse(row("large-file").waitForExistence(timeout: 2))
    text("outcome", contains: "Moved to Trash")
  }

  func testResultMotionStylesTravelPoofAndReduceMotionFade() throws {
    for (scenario, action, reduceMotion, style) in [
      ("presentation-trash-inside", "trash", false, "travel"),
      ("presentation", "delete", false, "poof"),
      ("presentation-trash-inside", "trash", true, "fade"),
    ] {
      launch(scenario, reduceMotion: reduceMotion)
      let probe = app.descendants(matching: .any)["motion-style"]
      XCTAssertTrue(probe.waitForExistence(timeout: 8))
      XCTAssertEqual(probe.label, "none")
      prepare(action, target: "large-file")
      // Frame extraction aligns the screen recording with this wall-clock mark.
      print("MOTION_CONFIRM \(scenario) \(style) \(Date().timeIntervalSince1970)")
      app.buttons["confirm-action"].click()
      text("outcome", contains: action == "trash" ? "Moved to Trash" : "Permanently deleted")
      XCTAssertTrue(row("large-file").waitForNonExistence(timeout: 8))
      XCTAssertTrue(app.staticTexts["dirty"].waitForExistence(timeout: 8))
      let ran = NSPredicate(format: "label BEGINSWITH %@", style + " ")
      XCTAssertEqual(
        XCTWaiter.wait(
          for: [XCTNSPredicateExpectation(predicate: ran, object: probe)], timeout: 8),
        .completed, "\(scenario) must run \(style), got \(probe.label)")
      // A 200 ms clock sampled about every 16 ms; one tick would be a jump, not motion.
      let ticks = Int(probe.label.split(separator: " ").last ?? "") ?? 0
      XCTAssertGreaterThanOrEqual(ticks, 4, "\(scenario) \(style) ticks")
      screenshot("motion-\(scenario)-\(style)-final")
      app.terminate()
    }
  }

}
