import AppKit
import Vision
import XCTest

/// Checks `condition` until it holds, at most `timeout` seconds, and reports whether it held.
/// Between checks it waits 50 ms, or as long as the last check took: a check is an
/// accessibility query that the app answers on its main thread. In the dense map, queries took
/// 2 s, and checks back to back kept the app from showing a revealed row for over 8 s.
@MainActor func poll(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while true {
    let start = Date()
    if condition() { return true }
    if Date() >= deadline { return false }
    Thread.sleep(forTimeInterval: max(0.05, Date().timeIntervalSince(start)))
  }
}

extension XCUIElement {
  /// Polls `exists`. `waitForExistence` and `waitForNonExistence` check first after about one
  /// second, also when the element is already there: that cost about 270 s of a 806 s suite.
  func appears(within timeout: TimeInterval) -> Bool { poll(timeout) { exists } }
  func disappears(within timeout: TimeInterval) -> Bool { poll(timeout) { !exists } }
}

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
    locale: String = "en_US", storage: URL? = nil, appearance: String? = nil
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
    // Fixture-only appearance; the system appearance and Increase Contrast never change.
    if let appearance { app.launchEnvironment["DI_APPEARANCE"] = appearance }
    app.launch()
    XCTAssertTrue(app.staticTexts["scope-total"].appears(within: 15))
    XCTAssertEqual(app.windows.firstMatch.title, "Disk Inventory — SIMULATED")
  }
  func until(_ timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
    poll(timeout, condition)
  }
  /// Waits until the busy bar of an operation is gone: the outcome shows before the view
  /// recovers, and the bar stays until the recovery ends.
  func operationEnds(timeout: TimeInterval = 8) {
    XCTAssertTrue(app.staticTexts["scan-phase"].disappears(within: timeout), "the operation ends")
  }
  /// Waits until the map shows the picture of the fixture `appearance`.
  func mapShows(_ appearance: String) {
    let probe = app.descendants(matching: .any)["map-appearance"]
    XCTAssertTrue(probe.appears(within: 8), appearance)
    XCTAssertTrue(until { probe.label == appearance }, "\(appearance), got \(probe.label)")
  }
  func row(_ name: String) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "identifier == %@", "entry-\(name)")).firstMatch
  }
  func text(_ id: String, contains value: String, timeout: TimeInterval = 8) {
    let element = id == "selected-name" ? app.buttons[id] : app.staticTexts[id]
    XCTAssertTrue(element.appears(within: timeout))
    // Polls (`poll`): a predicate expectation samples about once a second, which made each
    // changing text cost a second. The query compares the whole value; a snapshot value can be
    // truncated.
    let match = (id == "selected-name" ? app.buttons : app.staticTexts).matching(identifier: id)
      .matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", value, value))
      .firstMatch
    if poll(timeout, { match.exists }) { return }
    screenshot("failure-\(id)")
    print("UI_STATE id=\(id) actual=\(String(describing: element.value))")
    XCTFail("\(id) must contain \(value), got \(String(describing: element.value))")
  }
  /// Waits for the outcome banner, then requires exactly `expected`: no added sentence.
  func outcome(is expected: String, timeout: TimeInterval = 8) {
    text("outcome", contains: expected, timeout: timeout)
    XCTAssertEqual(app.staticTexts["outcome"].value as? String, expected)
  }
  /// Waits until the status bar names `value`, the hovered map block. "none" waits until the
  /// status bar is empty: the pointer is off the map.
  func hovered(_ value: String, timeout: TimeInterval = 8) {
    var shown = ""
    _ = poll(timeout) {
      shown = statusPath()
      return value == "none" ? shown.isEmpty : shown.contains(value)
    }
    XCTAssertTrue(
      value == "none" ? shown.isEmpty : shown.contains(value),
      "the status bar must name \(value), got \(shown)")
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
    XCTAssertTrue(app.staticTexts["confirmation-title"].appears(within: 8))
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
    XCTAssertTrue(row("small-00").appears(within: 8))
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
    XCTAssertTrue(row("small-00").appears(within: 8))
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
    func scrolled() -> Double { Double(String(describing: scrollbar.value ?? "")) ?? -1 }
    // Scroll history stores a row, so restoration can round by less than one row. The tree
    // restores the scroll position after the selection shows.
    _ = until { abs(scrolled() - before) <= 0.02 }
    let after = scrolled()
    XCTAssertEqual(after, before, accuracy: 0.02)
    XCTAssertFalse(row("small-files").isHittable)
    screenshot("scrolled-tree-restored")
    app.outlines["entry-tree"].scroll(byDeltaX: 0, deltaY: 600)
    XCTAssertTrue(disclosure("small-files").isHittable)
    disclosure("small-files").click()
    XCTAssertTrue(row("small-00").disappears(within: 8))
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
    outcome(is: "Deleted.")
    // The outcome shows before the view recovers.
    XCTAssertTrue(row("large-file").disappears(within: 8))
    XCTAssertTrue(app.staticTexts["dirty"].appears(within: 8))
    operationEnds()
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
    outcome(is: "Moved to Trash.")
    XCTAssertTrue(row("large-file").disappears(within: 8))
  }
  func testPermanentConfirmationHasNoDefaultAndEscapeCancels() {
    launch()
    prepare("delete", target: "large-file")
    let title = app.staticTexts["confirmation-title"]
    // Return has no default button to press: the alert and the row stay.
    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    XCTAssertFalse(title.disappears(within: 2))
    XCTAssertTrue(row("large-file").exists)
    text("confirmation-title", contains: "Delete “large-file” immediately?")
    XCTAssertEqual(app.buttons["confirm-action"].title, "Delete Immediately")
    XCTAssertGreaterThanOrEqual(
      app.buttons["cancel-action"].frame.minY, app.buttons["confirm-action"].frame.maxY - 1)
    screenshot("permanent-confirmation-without-default")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(title.disappears(within: 8))
    XCTAssertTrue(row("large-file").exists)
    XCTAssertFalse(app.staticTexts["outcome"].exists)
    // A second preparation after Esc must present a new alert.
    prepare("delete", target: "large-file")
    app.buttons["confirm-action"].click()
    outcome(is: "Deleted.")
    XCTAssertTrue(row("large-file").disappears(within: 8))
  }
  /// Only the chevron opens Details. The other failure outcomes and the saved-only selection
  /// are model tests in OperationOutcomeModelTests.swift.
  func testUnknownTrashScopeIssueOpensFromTheDetailsChevron() {
    launch("trash-unknown")
    prepare("trash", target: "large-file")
    app.buttons["confirm-action"].click()
    // The unknown Trash scope is a core issue in Details, not a banner sentence.
    outcome(is: "Moved to Trash.")
    XCTAssertTrue(app.staticTexts["stale"].appears(within: 8))
    // The chevron sits below the start of the outcome text; the accessibility frame of the
    // control starts at the banner edge.
    let details = app.disclosureTriangles["issues"]
    let chevron = app.staticTexts["outcome"].frame.minX + 4.5 - details.frame.minX
    details.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: chevron, dy: details.frame.height / 2)).click()
    XCTAssertTrue(
      anyText(containing: "Trash destination scope is unknown").appears(within: 8))
    screenshot("trash-unknown-issue-details")
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
      XCTAssertTrue(app.staticTexts["fixture-locked"].appears(within: 8))
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
    XCTAssertTrue(app.staticTexts["confirmation-path"].appears(within: 8))
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
      if action == "trash" {
        XCTAssertFalse(anyText(containing: "free space").exists, "no space disclaimer")
      } else {
        text("confirmation-warning", contains: "cannot be undone")
      }
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
    XCTAssertTrue(target.appears(within: 8))
    // The label of a map target read right after launch was sometimes empty; the identifier
    // that the query matched is "map-file-" and the same name.
    let name = String(target.identifier.dropFirst("map-file-".count))
    print("DENSE target \(name) label \(target.label)")
    XCTAssertTrue(name.hasPrefix("asset-"), name)
    screenshot("dix-dense-overview")
    row("Movie.mov").click()
    target.hover()
    hovered(name)
    text("selected-name", contains: "Movie.mov")
    screenshot("dix-independent-hover")
    target.click()
    text("selected-name", contains: name)
    text("focus-name", contains: "Workspace")
    XCTAssertTrue(row(name).appears(within: 8))
    screenshot("dix-linked-reveal")
    // Disclosures stay disabled until the reveal's expansion ends.
    XCTAssertTrue(until { disclosure("Projects").isEnabled })
    disclosure("Projects").click()
    // Disclosure publishes a Rust worker result asynchronously; event delivery is not publication.
    XCTAssertTrue(row(name).disappears(within: 8))
    text("selected-name", contains: name)
    screenshot("dix-disclosure-collapsed")
    row("Tiny files").doubleClick()
    text("focus-name", contains: "Tiny files")
    screenshot("dix-tiny-directory")
    row("Notes").doubleClick()
    text("focus-name", contains: "Notes")
    let small = app.buttons["map-file-four-KiB.txt"]
    XCTAssertTrue(small.appears(within: 8))
    small.hover()
    hovered("four-KiB.txt")
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
      XCTAssertTrue(row(name).appears(within: 8))
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

  func testLocalizedStorageInTreeSelectionAndConfirmation() {
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
      // The selection lives in the card; the status bar names only the hovered block.
      XCTAssertEqual(statusPath(), "", "the pointer is on the tree")
      let tile = app.buttons["map-file-large-file"]
      XCTAssertTrue(tile.appears(within: 8))
      tile.hover()
      hovered("/Workspace/large-file")
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
    XCTAssertTrue(item.appears(within: 5), "\(menu) > \(title)")
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
    XCTAssertTrue(app.staticTexts["root-protected"].appears(within: 8))
    XCTAssertFalse(app.buttons["trash"].isEnabled)
    XCTAssertFalse(app.buttons["delete"].isEnabled)
    XCTAssertFalse(menuItem("File", "Move to Trash…").isEnabled)
    XCTAssertFalse(menuBarItem("File").menuItems["Delete Immediately…"].isEnabled)
    screenshot("file-menu-root-disabled")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [.command])
    app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [.command, .option])
    XCTAssertFalse(title.appears(within: 2))
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
    XCTAssertTrue(title.appears(within: 8))
    text("confirmation-title", contains: "Move “large-file” to the Trash?")
    // Under the alert, both shortcuts and the menu items do nothing.
    app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [.command])
    app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [.command, .option])
    XCTAssertFalse(title.disappears(within: 2))
    text("confirmation-title", contains: "Move “large-file” to the Trash?")
    XCTAssertEqual(app.sheets.count, 1)
    XCTAssertFalse(menuItem("File", "Move to Trash…").isEnabled)
    XCTAssertFalse(menuBarItem("File").menuItems["Delete Immediately…"].isEnabled)
    XCTAssertFalse(menuBarItem("File").menuItems["Refresh Directory"].isEnabled)
    screenshot("file-menu-under-trash-alert")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(title.exists)
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(title.disappears(within: 8))
    XCTAssertTrue(row("large-file").exists)
    app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [.command, .option])
    XCTAssertTrue(title.appears(within: 8))
    text("confirmation-title", contains: "Delete “large-file” immediately?")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(title.disappears(within: 8))
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
    XCTAssertFalse(title.appears(within: 2))
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
  func launchStartScreen(storage: URL, appearance: String? = nil) {
    app = XCUIApplication()
    app.launchArguments = ["--fixture-mode", "-AppleLocale", "en_US"]
    app.launchEnvironment["DI_UI_TEST"] = "1"
    app.launchEnvironment["DI_MODEL_TEST"] = "0"
    app.launchEnvironment["DI_FIXTURE_STORAGE_ROOT"] = storage.path
    if let appearance { app.launchEnvironment["DI_APPEARANCE"] = appearance }
    app.launch()
    XCTAssertTrue(app.staticTexts["fixture-locked"].appears(within: 8))
    XCTAssertEqual(app.windows.firstMatch.title, "Disk Inventory — SIMULATED")
  }
  func fileMenuTitles() -> [String] {
    menuBarItem("File").click()
    XCTAssertTrue(menuBarItem("File").menuItems["Choose Folder…"].appears(within: 5))
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
    XCTAssertTrue(reopen.appears(within: 8))
    XCTAssertEqual(reopen.label, "Reopen “Workspace”")
    XCTAssertFalse(reopen.isEnabled)
    XCTAssertFalse(app.buttons["open-snapshot"].exists)
    XCTAssertFalse(app.buttons["Open Snapshot…"].exists)
    screenshot("reopen-start-screen")
  }
  func testOldMetadataShowsReopenLastFolder() throws {
    launchStartScreen(storage: try lastFolderMetadata(rootName: nil))
    let reopen = app.buttons["reopen-last-folder"]
    XCTAssertTrue(reopen.appears(within: 8))
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
    XCTAssertTrue(reopen.appears(within: 8))
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
    continueAfterFailure = true  // Report both rows in every appearance.
    for appearance in Self.appearances {
      launch(appearance: appearance)
      row("small-files").click()
      text("selected-name", contains: "small-files")
      let image = try XCTUnwrap(NSBitmapImageRep(data: settled { XCUIScreen.main.screenshot() }))
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
          "\(appearance) \(name): size text center \(sizeCenter), name text center \(nameCenter)")
      }
      screenshot("tree-size-centered-\(appearance)")
      app.terminate()
    }
  }
  func testContextMenusOnTreeRowAndMapBlock() {
    launch()
    row("small-files").click()
    text("selected-name", contains: "small-files")
    row("large-file").rightClick()
    XCTAssertTrue(contextItem("moveToTrash").appears(within: 5))
    // The clicked row is the target, not the earlier selection.
    text("selected-name", contains: "large-file")
    XCTAssertFalse(contextItem("revealInFinder").isEnabled)
    XCTAssertTrue(contextItem("deleteImmediately").isEnabled)
    screenshot("context-menu-tree-row")
    contextItem("moveToTrash").click()
    XCTAssertTrue(app.staticTexts["confirmation-title"].appears(within: 8))
    text("confirmation-title", contains: "Move “large-file” to the Trash?")
    app.buttons["cancel-action"].click()
    XCTAssertTrue(app.staticTexts["confirmation-title"].disappears(within: 8))
    row("small-files").click()
    text("selected-name", contains: "small-files")
    let tile = app.buttons["map-file-large-file"]
    XCTAssertTrue(tile.appears(within: 8))
    tile.hover()
    hovered("large-file")
    tile.rightClick()
    XCTAssertTrue(contextItem("deleteImmediately").appears(within: 5))
    text("selected-name", contains: "large-file")
    screenshot("context-menu-map-block")
    contextItem("deleteImmediately").click()
    XCTAssertTrue(app.staticTexts["confirmation-title"].appears(within: 8))
    text("confirmation-title", contains: "Delete “large-file” immediately?")
    app.buttons["cancel-action"].click()
    XCTAssertTrue(row("large-file").exists)
  }
  func testEditUndoIsUnavailableAfterTrash() {
    launch("trash-outside")
    prepare("trash", target: "large-file")
    app.buttons["confirm-action"].click()
    text("outcome", contains: "Moved to Trash")
    XCTAssertTrue(row("large-file").disappears(within: 8))
    let undo = menuItem("Edit", "Undo")
    XCTAssertFalse(undo.isEnabled)
    screenshot("edit-menu-after-trash")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    app.typeKey("z", modifierFlags: [.command])
    XCTAssertFalse(row("large-file").appears(within: 2))
    text("outcome", contains: "Moved to Trash")
  }

  /// The four `DI_APPEARANCE` values. Contrast values change the map only: AppKit cannot
  /// create a high-contrast appearance without the system setting.
  static let appearances = ["light", "dark", "light-contrast", "dark-contrast"]
  /// The window screenshot, in pixels, with conversions from screen points.
  struct WindowPixels {
    let image: NSBitmapImageRep
    let origin: CGPoint
    let scale: CGFloat
    func rgb(_ x: Int, _ y: Int) -> [Int] {
      var pixel = [Int](repeating: 0, count: 8)
      image.getPixel(&pixel, atX: x, y: y)
      return Array(pixel.prefix(3))
    }
    func x(_ point: CGFloat) -> Int { Int(((point - origin.x) * scale).rounded(.down)) }
    func y(_ point: CGFloat) -> Int { Int(((point - origin.y) * scale).rounded(.down)) }
    /// Mean color of the 3x3 pixels around a screen point.
    func mean(_ point: CGPoint) -> [Double] {
      var sum = [0.0, 0.0, 0.0]
      for dy in -1...1 {
        for dx in -1...1 {
          for (c, v) in rgb(x(point.x) + dx, y(point.y) + dy).enumerated() { sum[c] += Double(v) }
        }
      }
      return sum.map { $0 / 9 }
    }
  }
  /// The PNG of a screenshot once two in a row are equal (at most about one second): a pixel
  /// check right after an accessibility change can otherwise read a frame still being drawn.
  func settled(_ shot: () -> XCUIScreenshot) -> Data {
    var data = shot().pngRepresentation
    for _ in 0..<10 {
      Thread.sleep(forTimeInterval: 0.1)
      let next = shot().pngRepresentation
      if next == data { break }
      data = next
    }
    return data
  }
  /// `srgb` converts the screenshot from the display profile to sRGB, so colored pixels
  /// compare with the sRGB bytes that Rust draws. Neutral grays do not need it.
  func windowPixels(srgb: Bool = false) throws -> WindowPixels {
    let window = app.windows.firstMatch
    var image = try XCTUnwrap(NSBitmapImageRep(data: settled { window.screenshot() }))
    if srgb {
      image = try XCTUnwrap(image.converting(to: .sRGB, renderingIntent: .default))
    }
    XCTAssertEqual(image.bitsPerSample, 8)
    return WindowPixels(
      image: image, origin: window.frame.origin,
      scale: CGFloat(image.pixelsWide) / window.frame.width)
  }
  /// WCAG 2 contrast ratio of two 8-bit colors.
  static func contrast(_ a: [Int], _ b: [Int]) -> Double {
    func luminance(_ c: [Int]) -> Double {
      let linear = c.map { v -> Double in
        let v = Double(v) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
      }
      return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
  }
  /// Moves the pointer off the map so that no hover outline covers it.
  func leaveMap() {
    row("zero-byte").hover()
    hovered("none")
  }
  /// Moves the pointer to the tree, so that no hover outline covers the map.
  func offMap() {
    app.outlines["entry-tree"].hover()
    hovered("none")
  }
  /// Gray levels of the aggregate hatch right of `minX`: neutral diagonal stripes, two pixels
  /// wide with a period of four, as Rust draws them on the backing grid.
  func hatchLevels(_ p: WindowPixels, minX: CGFloat) -> (light: Int, dark: Int, pixels: Int) {
    var light: [Int: Int] = [:]
    var dark: [Int: Int] = [:]
    func neutral(_ c: [Int]) -> Bool { c.max()! - c.min()! <= 8 }
    func same(_ a: [Int], _ b: [Int]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= 2 } }
    for y in 1..<(p.image.pixelsHigh - 1) {
      for x in max(0, p.x(minX))..<(p.image.pixelsWide - 4) {
        let a = p.rgb(x, y)
        guard neutral(a) else { continue }
        let b = p.rgb(x + 2, y)
        guard neutral(b), abs(a[1] - b[1]) > 8, same(a, p.rgb(x + 4, y)),
          same(a, p.rgb(x + 1, y - 1))
        else { continue }
        if a[1] > b[1] { light[a[1], default: 0] += 1 } else { dark[a[1], default: 0] += 1 }
      }
    }
    let mode = { (levels: [Int: Int]) in levels.max { $0.value < $1.value }?.key ?? -1 }
    return (mode(light), mode(dark), light.values.reduce(0, +) + dark.values.reduce(0, +))
  }
  /// Top edge of the status bar: 28 points plus the divider above it.
  func statusBarTop() -> CGFloat { app.windows.firstMatch.frame.maxY - 29 }
  /// Clicks the middle of an area of aggregate hatch on the map, which selects the grouped
  /// directory allocation.
  func clickHatch() throws { try hatchPoint()?.click() }
  /// The middle of an area of aggregate hatch on the map.
  func hatchPoint() throws -> XCUICoordinate? {
    let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "map-file-"))
    XCTAssertTrue(tiles.firstMatch.appears(within: 8), "the map shows its picture")
    let p = try windowPixels()
    let minX = app.outlines["entry-tree"].frame.maxX
    let levels = hatchLevels(p, minX: minX)
    XCTAssertGreaterThan(levels.pixels, 0, "the map shows aggregate hatch")
    func hatch(_ x: Int, _ y: Int) -> Bool {
      let c = p.rgb(x, y)
      return c.max()! - c.min()! <= 8
        && (abs(c[1] - levels.light) <= 3 || abs(c[1] - levels.dark) <= 3)
    }
    let top = p.y(app.windows.firstMatch.frame.minY + 120)
    for y in stride(from: top, to: p.image.pixelsHigh - 8, by: 2) {
      for x in stride(from: max(0, p.x(minX)) + 8, to: p.image.pixelsWide - 8, by: 2)
      where (-6...6).allSatisfy({ d in hatch(x + d, y) && hatch(x, y + d) }) {
        let window = app.windows.firstMatch
        return window.coordinate(withNormalizedOffset: .zero).withOffset(
          CGVector(
            dx: CGFloat(x) / p.scale + p.origin.x - window.frame.minX,
            dy: CGFloat(y) / p.scale + p.origin.y - window.frame.minY))
      }
    }
    XCTFail("no hatch area")
    return nil
  }
  func testAppearanceVariantsRenderMapChromeAndSheets() {
    for appearance in Self.appearances {
      launch(appearance: appearance)
      mapShows(appearance)
      let probe = app.descendants(matching: .any)["map-appearance"]
      leaveMap()
      screenshot("\(appearance)-overview")
      row("large-file").click()
      text("selected-name", contains: "large-file")
      text("selected-path", contains: "large-file")
      leaveMap()
      screenshot("\(appearance)-selection")
      let tile = app.buttons["map-file-large-file"]
      XCTAssertTrue(tile.appears(within: 8))
      tile.hover()
      hovered("large-file")
      screenshot("\(appearance)-hover")
      for action in ["trash", "delete"] {
        prepare(action, target: "large-file")
        screenshot("\(appearance)-\(action)-sheet")
        app.buttons["cancel-action"].click()
        XCTAssertTrue(app.staticTexts["confirmation-title"].disappears(within: 8))
      }
      // Each sheet and the hover keep the appearance: no rebuild with another variant.
      XCTAssertEqual(probe.label, appearance)
      app.terminate()
    }
  }
  func testTreeUsesOpaqueContentBackgroundAndSystemGrayDirectorySwatch() throws {
    continueAfterFailure = true
    for appearance in Self.appearances {
      launch(appearance: appearance)
      XCTAssertTrue(row("zero-byte").appears(within: 8))
      let p = try windowPixels()
      var expected: (background: [Double], swatch: [Double]) = ([], [])
      NSAppearance(named: appearance.hasPrefix("light") ? .aqua : .darkAqua)!
        .performAsCurrentDrawingAppearance {
          func rgb(_ color: NSColor) -> [Double] {
            let c = color.usingColorSpace(.sRGB)!
            return [c.redComponent, c.greenComponent, c.blueComponent].map { $0 * 255 }
          }
          expected = (rgb(.controlBackgroundColor), rgb(.systemGray))
        }
      // Empty tree area below the last row, and the center of an unselected directory swatch.
      let empty = CGPoint(
        x: app.outlines["entry-tree"].frame.midX, y: row("zero-byte").frame.maxY + 60)
      let name = row("small-files").frame
      let swatch = CGPoint(x: name.minX - 10.5, y: name.midY)
      let background = p.mean(empty)
      let square = p.mean(swatch)
      print("TREE \(appearance) background=\(background) swatch=\(square) expected=\(expected)")
      for c in 0..<3 {
        XCTAssertEqual(
          background[c], expected.background[c], accuracy: 4, "\(appearance) background")
        XCTAssertEqual(square[c], expected.swatch[c], accuracy: 6, "\(appearance) swatch")
      }
      screenshot("tree-inset-\(appearance)")
      app.terminate()
    }
  }
  func testMapTileBaseColorMatchesTreeSwatchOnScreen() throws {
    continueAfterFailure = true
    for appearance in ["light", "dark"] {
      launch("dix", appearance: appearance)
      let tile = app.buttons["map-file-Movie.mov"]
      XCTAssertTrue(tile.appears(within: 8))
      row("Tiny files").hover()
      let p = try windowPixels()
      let name = row("Movie.mov").frame
      let swatch = p.mean(CGPoint(x: name.minX - 10.5, y: name.midY)).map { Int($0.rounded()) }
      // The tile gradient passes through its base color, which the swatch shows.
      var nearest = Int.max
      let frame = tile.frame.insetBy(dx: 4, dy: 4)
      for y in stride(from: p.y(frame.minY), to: p.y(frame.maxY), by: 2) {
        for x in stride(from: p.x(frame.minX), to: p.x(frame.maxX), by: 2) {
          nearest = min(nearest, zip(p.rgb(x, y), swatch).map { abs($0 - $1) }.max()!)
        }
      }
      print("SRGB \(appearance) swatch=\(swatch) nearest=\(nearest)")
      XCTAssertLessThanOrEqual(nearest, 3, "\(appearance): map tile and swatch colors differ")
      screenshot("srgb-swatch-\(appearance)")
      app.terminate()
    }
  }
  /// Text contrast inside an element frame: the most common color is the background, and the
  /// 99th-percentile pixel contrast against it is the ink, so one stray pixel does not count.
  func textContrast(_ element: XCUIElement, _ p: WindowPixels) -> Double {
    var counts: [[Int]: Int] = [:]
    var colors: [[Int]] = []
    let frame = element.frame
    for y in p.y(frame.minY)..<p.y(frame.maxY) {
      for x in p.x(frame.minX)..<p.x(frame.maxX) {
        let c = p.rgb(x, y)
        counts[c, default: 0] += 1
        colors.append(c)
      }
    }
    guard let background = counts.max(by: { $0.value < $1.value })?.key else { return 0 }
    let ratios = colors.filter { $0 != background }.map { Self.contrast($0, background) }.sorted()
    guard ratios.count > 20 else { return ratios.last ?? 0 }
    return ratios[ratios.count * 99 / 100 - 1]
  }
  func staticText(_ prefix: String) -> XCUIElement {
    app.staticTexts.matching(
      NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", prefix, prefix)
    ).firstMatch
  }
  /// Any text in the app, a sheet included, that contains `part`.
  func anyText(containing part: String) -> XCUIElement {
    app.staticTexts.matching(
      NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", part, part)
    ).firstMatch
  }
  func testCaptionAndSecondaryTextMeetFourAndAHalfToOne() throws {
    continueAfterFailure = true
    let storage = try lastFolderMetadata(rootName: "/Workspace")
    for appearance in ["light", "dark"] {
      launch(appearance: appearance)
      // Measure only in the requested appearance.
      mapShows(appearance)
      leaveMap()
      func check(_ name: String, _ element: XCUIElement, _ pixels: WindowPixels) {
        XCTAssertTrue(element.exists, name)
        let ratio = textContrast(element, pixels)
        print("TEXT \(appearance) \(name) ratio=\(ratio)")
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(appearance) \(name)")
      }
      check("empty-card hint", staticText("Click to select"), try windowPixels())
      row("small-files").click()
      text("selected-path", contains: "small-files")
      leaveMap()
      let selection = try windowPixels()
      check("card caption", anyText(containing: " direct items"), selection)
      check("card path", app.staticTexts["selected-path"], selection)
      // The status bar names the hovered block.
      app.buttons["map-file-large-file"].hover()
      hovered("/Workspace/large-file")
      check("status path", app.staticTexts["status-path"], try windowPixels())
      // The card of a grouped block shows its size.
      try clickHatch()
      XCTAssertTrue(app.staticTexts["aggregate-text"].appears(within: 8), appearance)
      leaveMap()
      check("card grouped size", app.staticTexts["aggregate-text"], try windowPixels())
      screenshot("text-contrast-\(appearance)")
      app.terminate()
      launchStartScreen(storage: storage, appearance: appearance)
      XCTAssertTrue(app.buttons["reopen-last-folder"].appears(within: 8))
      let start = try windowPixels()
      check("start subtitle", staticText("Nothing is scanned"), start)
      check("last-folder caption", staticText("Last folder"), start)
      screenshot("text-contrast-start-\(appearance)")
      app.terminate()
    }
  }

  // MARK: Dogfood feedback

  /// The map area 12 points inside the padded map view: right of the tree, below the
  /// appearance probe and above the status bar.
  func mapArea() -> CGRect {
    let probe = app.descendants(matching: .any)["map-appearance"]
    let left = app.outlines["entry-tree"].frame.maxX + 12
    let top = probe.frame.minY + 12
    return CGRect(
      x: left, y: top, width: app.windows.firstMatch.frame.maxX - 12 - left,
      height: statusBarTop() - 12 - top)
  }
  /// Clicks a screen point in the window.
  func click(_ point: CGPoint, double: Bool = false) {
    let window = app.windows.firstMatch
    let target = window.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: point.x - window.frame.minX, dy: point.y - window.frame.minY))
    if double { target.doubleClick() } else { target.click() }
  }
  /// The text of the status bar; empty when it shows nothing.
  func statusPath() -> String {
    let element = app.staticTexts["status-path"]
    guard element.exists else { return "" }
    return (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
  }
  /// Rust `MapAppearance::trash` band colors (plain, then striped) at 21 gradient positions.
  static func trashBands(_ appearance: String) -> [[Double]] {
    let base: [Double] =
      appearance == "dark"
      ? [68, 72, 78]
      : appearance == "dark-contrast"
        ? [132, 136, 142]
        : [185, 190, 198]
    let stripe: Double = appearance.hasPrefix("dark") ? 255 : 0
    let alpha = appearance.hasSuffix("contrast") ? 0.30 : 0.09
    var bands: [[Double]] = []
    for step in 0...20 {
      let t = Double(step) / 20
      let (a, white) = (0.08 * (1 - t) + 0.12 * t, 255 * 0.08 * (1 - t))
      let plain = base.map { $0 * (1 - a) + white }
      bands.append(plain)
      bands.append(plain.map { $0 * (1 - alpha) + stripe * alpha })
    }
    return bands
  }
  /// Map pixels within 4 sRGB levels of a Trash band color whose neighbors 3 pixels away also
  /// match (thin seam lines of gray tiles do not), sampled every second pixel. Also returns
  /// their bounding box in screen points and the mean plain and striped band colors.
  func trashPixels(_ p: WindowPixels, map: CGRect, appearance: String) -> (
    count: Int, deep: [CGPoint], plain: [Int], striped: [Int]
  ) {
    let bands = Self.trashBands(appearance).map { $0.map { Int($0.rounded()) } }
    let low = bands.map { $0.min()! }.min()! - 4
    let high = bands.map { $0.max()! }.max()! + 4
    /// The band index within 4 levels, or nil.
    func band(_ x: Int, _ y: Int) -> Int? {
      let c = p.rgb(x, y)
      guard c.min()! >= low, c.max()! <= high, c[2] >= c[0] else { return nil }
      for (i, b) in bands.enumerated()
      where abs(c[0] - b[0]) <= 4 && abs(c[1] - b[1]) <= 4 && abs(c[2] - b[2]) <= 4 {
        return i
      }
      return nil
    }
    var (count, plain, striped) = (0, [0, 0, 0, 0], [0, 0, 0, 0])
    var matched = Set<[Int]>()
    for y in stride(from: p.y(map.minY) + 3, to: p.y(map.maxY) - 3, by: 2) {
      for x in stride(from: p.x(map.minX) + 3, to: p.x(map.maxX) - 3, by: 2) {
        guard let index = band(x, y), band(x - 3, y) != nil, band(x + 3, y) != nil,
          band(x, y - 3) != nil, band(x, y + 3) != nil
        else { continue }
        count += 1
        matched.insert([x, y])
        let c = p.rgb(x, y)
        if index % 2 == 0 {
          plain = [plain[0] + c[0], plain[1] + c[1], plain[2] + c[2], plain[3] + 1]
        } else {
          striped = [striped[0] + c[0], striped[1] + c[1], striped[2] + c[2], striped[3] + 1]
        }
      }
    }
    let mean = { (s: [Int]) in s[3] > 0 ? (0..<3).map { s[$0] / s[3] } : [] }
    // Deep points: every sampled pixel within 12 pixels also matches, so a click there lands
    // inside the striped region and not on a gray tile that shares a band color.
    let deep = matched.filter { m in
      stride(from: -12, through: 12, by: 2).allSatisfy { dy in
        stride(from: -12, through: 12, by: 2).allSatisfy { dx in
          matched.contains([m[0] + dx, m[1] + dy])
        }
      }
    }.sorted { ($0[1], $0[0]) < ($1[1], $1[0]) }.map {
      CGPoint(x: CGFloat($0[0]) / p.scale + p.origin.x, y: CGFloat($0[1]) / p.scale + p.origin.y)
    }
    return (count, deep, mean(plain), mean(striped))
  }
  /// Real clicks on a nested `.Trash`, one block at its parent's level: a click selects that
  /// `.Trash`, the hover names its path and a double click focuses it. Its stripes and colors
  /// are Rust pixel tests in src/bridge/tests/map_pixels.rs.
  func testNestedTrashBlockSelectsOnClickNamesItsPathAndFocusesOnDoubleClick() throws {
    launch("prototype-home-nested-trash", appearance: "dark")
    row("Projects").doubleClick()
    text("focus-name", contains: "Projects")
    let renders = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "map-file-Render "))
    XCTAssertTrue(renders.firstMatch.appears(within: 8), "Projects map")
    offMap()
    screenshot("nested-trash-dark-projects")
    // The stripes locate the block on screen.
    let trash = trashPixels(try windowPixels(srgb: true), map: mapArea(), appearance: "dark")
    let middle = try XCTUnwrap(
      trash.deep.count > 20 ? trash.deep[trash.deep.count / 2] : nil,
      "no Trash stripes for Projects/.Trash")
    click(middle)
    text("selected-name", contains: ".Trash")
    text("selected-path", contains: "/Users/ana/Projects/.Trash")
    hovered("/Users/ana/Projects/.Trash")
    XCTAssertEqual(statusPath(), "/Users/ana/Projects/.Trash")
    XCTAssertFalse(app.buttons["map-file-Old render 01.mov"].exists, "children are not drawn")
    screenshot("nested-trash-dark-selected")
    click(middle, double: true)
    text("focus-name", contains: ".Trash")
    XCTAssertTrue(app.buttons["map-file-Old render 01.mov"].appears(within: 8))
    screenshot("nested-trash-dark-focused")
  }
  /// Up to six of the largest file tiles with an accessibility target and a unique name,
  /// each at least 40 points wide and high.
  func largeTiles() -> [(name: String, frame: CGRect)] {
    let targets = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "map-file-"))
    var seen: [String: Int] = [:]
    var tiles: [(name: String, frame: CGRect)] = []
    for i in 0..<targets.count {
      let element = targets.element(boundBy: i)
      let name = String(element.identifier.dropFirst("map-file-".count))
      seen[name, default: 0] += 1
      if element.frame.width >= 40, element.frame.height >= 40 {
        tiles.append((name, element.frame))
      }
    }
    return Array(
      tiles.filter { seen[$0.name] == 1 }
        .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        .prefix(6))
  }
  /// Dark prototype-home against the design: tile interiors equal the CSS gradient over the
  /// kind color, and the seam darkens one backing pixel on each edge to 0.55 of the interior
  /// (the design's inset on a 2x grid). The old top/left seam at 0.775 left the map brighter.
  func testPrototypeHomeDarkMapMatchesTheDesignBrightness() throws {
    launch("prototype-home", appearance: "dark")
    XCTAssertTrue(app.buttons["map-file-Interview raw.mov"].appears(within: 8))
    offMap()
    let p = try windowPixels(srgb: true)
    // Rust `type_color`: the prototype palette by extension.
    let kinds: [String: [Double]] = [
      "mov": [79, 138, 198], "mp4": [79, 138, 198], "heic": [81, 153, 98], "jpg": [81, 153, 98],
      "png": [81, 153, 98], "m4a": [171, 109, 166], "wav": [171, 109, 166],
      "zip": [173, 124, 47], "dmg": [173, 124, 47], "app": [133, 122, 196], "o": [0, 153, 160],
      "swiftmodule": [0, 153, 160], "js": [0, 153, 160], "db": [190, 110, 82],
      "cache": [190, 110, 82], "sqlite": [138, 140, 52], "bin": [138, 140, 52],
    ]
    var edgeRatios: [Double] = []
    for (name, frame) in largeTiles() {
      let base = kinds[String(name.split(separator: ".").last!)] ?? [127, 135, 147]
      // The center sits at 0.5 along the 155-degree gradient: base plus 1.27% white.
      let expected = base.map { $0 + (255 - $0) * 0.14 * (1 - 0.5 / 0.55) }
      let center = p.mean(CGPoint(x: frame.midX, y: frame.midY))
      print(
        "BRIGHTNESS \(name) center=\(center.map { Int($0.rounded()) }) expected=\(expected.map { Int($0.rounded()) })"
      )
      for c in 0..<3 { XCTAssertEqual(center[c], expected[c], accuracy: 3, "\(name) interior") }
      let f = frame
      let (x0, y0) = (
        Int(((f.minX - p.origin.x) * p.scale - 0.5).rounded(.up)),
        Int(((f.minY - p.origin.y) * p.scale - 0.5).rounded(.up))
      )
      let (x1, y1) = (
        Int(((f.maxX - p.origin.x) * p.scale - 0.5).rounded(.up)),
        Int(((f.maxY - p.origin.y) * p.scale - 0.5).rounded(.up))
      )
      let (mx, my) = ((x0 + x1) / 2, (y0 + y1) / 2)
      for (edge, inside) in [
        ((x0, my), (x0 + 1, my)), ((mx, y0), (mx, y0 + 1)), ((x1 - 1, my), (x1 - 2, my)),
        ((mx, y1 - 1), (mx, y1 - 2)),
      ] {
        let (e, i) = (p.rgb(edge.0, edge.1), p.rgb(inside.0, inside.1))
        edgeRatios.append(Double(e.reduce(0, +)) / Double(max(1, i.reduce(0, +))))
      }
    }
    let mean = edgeRatios.reduce(0, +) / Double(max(1, edgeRatios.count))
    var whole = [0.0, 0, 0]
    var count = 0.0
    let map = mapArea()
    for y in stride(from: p.y(map.minY), to: p.y(map.maxY), by: 2) {
      for x in stride(from: p.x(map.minX), to: p.x(map.maxX), by: 2) {
        for (c, v) in p.rgb(x, y).enumerated() { whole[c] += Double(v) }
        count += 1
      }
    }
    print(
      "BRIGHTNESS edge/interior mean=\(mean) over \(edgeRatios.count) edges; whole map mean sRGB=\(whole.map { ($0 / count * 10).rounded() / 10 })"
    )
    XCTAssertGreaterThanOrEqual(edgeRatios.count, 12)
    XCTAssertEqual(mean, 0.55, accuracy: 0.04, "design seam on every edge")
    screenshot("brightness-dark")
  }
  /// Esc clears a tree or map selection: no card, no tree highlight, no dim, no status path.
  /// An open confirmation keeps its own Esc (Cancel) and the selection.
  func testEscapeClearsTheSelectionInTreeAndMap() throws {
    launch()
    let tile = app.buttons["map-file-large-file"]
    XCTAssertTrue(tile.appears(within: 8))
    offMap()
    let clear = try windowPixels()
    let probe = CGPoint(x: tile.frame.minX - 30, y: tile.frame.midY)
    row("large-file").click()
    text("selected-name", contains: "large-file")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(app.buttons["selected-name"].disappears(within: 8), "tree Esc")
    XCTAssertTrue(staticText("Nothing selected").exists)
    XCTAssertEqual(statusPath(), "")
    XCTAssertFalse(row("large-file").isSelected)
    offMap()
    let after = try windowPixels()
    XCTAssertEqual(after.mean(probe), clear.mean(probe), "no dim after Esc")
    screenshot("esc-after-tree")
    tile.click()
    text("selected-name", contains: "large-file")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(app.buttons["selected-name"].disappears(within: 8), "map Esc")
    // A confirmation sheet owns Esc: it cancels and the selection stays.
    prepare("delete", target: "large-file")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(app.staticTexts["confirmation-title"].disappears(within: 8))
    text("selected-name", contains: "large-file")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(app.buttons["selected-name"].disappears(within: 8))
    XCTAssertTrue(row("large-file").exists)
    screenshot("esc-after-map")
  }
  /// The status bar names the map block under the pointer, also while another item is
  /// selected: its complete path, or "Grouped in" and the folder path for a grouped block. With
  /// the pointer off the map it is empty; the selection lives in the card. Outcomes use the
  /// banner over the map.
  func testStatusBarShowsTheHoveredBlockAlsoWhileAnItemIsSelected() throws {
    launch()
    let tile = app.buttons["map-file-large-file"]
    XCTAssertTrue(tile.appears(within: 8))
    // The pointer stays where the last test left it, which can be over the map.
    offMap()
    XCTAssertEqual(statusPath(), "")
    XCTAssertFalse(anyText(containing: "Recorded disk usage").exists)
    // Find the grouped block before the selection dims the map.
    let hatch = try XCTUnwrap(try hatchPoint())
    row("small-files").click()
    text("selected-path", contains: "/Workspace/small-files")
    XCTAssertEqual(statusPath(), "", "a selection alone leaves the status bar empty")
    screenshot("status-bar-selected-off-map")
    tile.hover()
    hovered("/Workspace/large-file")
    XCTAssertEqual(statusPath(), "/Workspace/large-file")
    text("selected-name", contains: "small-files")
    text("selected-path", contains: "/Workspace/small-files")
    XCTAssertGreaterThanOrEqual(app.staticTexts["status-path"].frame.minY, statusBarTop() - 1)
    screenshot("status-bar-hover-while-selected")
    hatch.hover()
    hovered("Grouped in /Workspace")
    text("selected-name", contains: "small-files")
    screenshot("status-bar-hover-grouped")
    row("zero-byte").hover()
    hovered("none")
    XCTAssertEqual(statusPath(), "", "pointer off the map")
    prepare("trash", target: "large-file")
    app.buttons["confirm-action"].click()
    text("outcome", contains: "Moved to Trash")
    let outcome = app.staticTexts["outcome"]
    XCTAssertLessThan(outcome.frame.maxY, statusBarTop(), "the outcome is over the map")
    XCTAssertGreaterThan(outcome.frame.minX, app.outlines["entry-tree"].frame.maxX)
    XCTAssertFalse(statusPath().contains("Moved"))
    screenshot("status-bar-outcome-banner")
    app.buttons["dismiss-banner"].click()
    XCTAssertTrue(outcome.disappears(within: 8))
  }
  /// Refresh shows the scan's progress with the folder name, a live counter and Stop. Stop
  /// keeps the previous data and says so; a complete refresh applies the live change.
  func testRefreshShowsNamedProgressWithCounterAndStopKeepsData() throws {
    launch("prototype-home-refresh")
    row("Library").doubleClick()
    text("focus-name", contains: "Library")
    let total = app.staticTexts["scope-total"].value as? String
    app.buttons["refresh"].click()
    text("scan-phase", contains: "Refreshing “Library”…")
    XCTAssertTrue(app.staticTexts["scan-items"].appears(within: 8))
    let first = shownText("scan-items")
    var second = first
    _ = until {
      second = shownText("scan-items")
      return second != first
    }
    print("REFRESH counter \(first) -> \(second)")
    XCTAssertNotEqual(first, second, "the counter is live")
    XCTAssertTrue(app.buttons["stop-scan"].isEnabled)
    screenshot("refresh-progress")
    app.buttons["stop-scan"].click()
    text("outcome", contains: "Refresh of “Library” stopped. The previous data is unchanged.")
    XCTAssertTrue(app.staticTexts["scan-phase"].disappears(within: 8))
    XCTAssertEqual(app.staticTexts["scope-total"].value as? String, total)
    disclosure("Caches").click()
    XCTAssertTrue(row("cache 01.db").appears(within: 8))
    XCTAssertFalse(row("new cache.db").exists)
    screenshot("refresh-stopped")
    app.buttons["refresh"].click()
    outcome(is: "Refreshed “Library”.", timeout: 20)
    operationEnds()
    XCTAssertNotEqual(app.staticTexts["scope-total"].value as? String, total)
    disclosure("Caches").click()
    XCTAssertTrue(row("new cache.db").appears(within: 8))
    screenshot("refresh-complete")
  }
  /// The bar names the operation's phase and item; a bare "Working…" never shows. It reads the
  /// value directly: a predicate expectation samples about once a second, slower than a phase.
  func phase(_ value: String, timeout: TimeInterval = 6) {
    var shown = ""
    _ = poll(timeout) {
      let now = shownText("scan-phase")
      if !now.isEmpty { shown = now }
      return shown.contains(value)
    }
    XCTAssertTrue(shown.contains(value), "the phase must be \(value), got \(shown)")
    XCTAssertFalse(anyText(containing: "Working…").exists, value)
  }
  /// The value or label of a text; empty once it is gone. A snapshot of a missing element
  /// throws, where reading `value` would fail the test: the busy bar goes when its operation
  /// ends, also while a wait polls it.
  func shownText(_ id: String) -> String {
    guard let element = try? app.staticTexts[id].snapshot() else { return "" }
    return (element.value as? String) ?? element.label
  }
  /// The removed-items counter, such as "96 items".
  func items() -> (count: Int, shown: String) {
    let shown = shownText("scan-items")
    return (Int(shown.filter(\.isNumber)) ?? -1, shown)
  }
  /// `operation-slow`: each check, the Trash move and the update take 3 s, each removal 30 ms.
  func testDeleteNamesEachPhaseCountsRemovedItemsAndOffersStop() throws {
    launch("operation-slow")
    row("Library").click()
    app.buttons["delete"].click()
    phase("Checking “Library”…")
    screenshot("delete-checking")
    XCTAssertTrue(app.staticTexts["confirmation-title"].appears(within: 8))
    app.buttons["confirm-action"].click()
    phase("Deleting “Library”…", timeout: 8)
    XCTAssertTrue(app.staticTexts["scan-items"].appears(within: 4))
    let first = items()
    XCTAssertTrue(app.buttons["stop-scan"].isEnabled)
    screenshot("delete-deleting")
    var second = items()
    _ = until {
      second = items()
      return second.count > first.count
    }
    print("DELETE counter \(first.shown) -> \(second.shown)")
    XCTAssertGreaterThan(second.count, first.count, "the removed-items counter is live")
    XCTAssertNotNil(second.shown.range(of: #"^[0-9,]+ items$"#, options: .regularExpression))
    phase("Updating view…", timeout: 8)
    XCTAssertFalse(app.buttons["stop-scan"].isEnabled, "the deletion is done")
    screenshot("delete-updating")
    outcome(is: "Deleted.", timeout: 12)
    XCTAssertTrue(app.staticTexts["scan-phase"].disappears(within: 8))
    XCTAssertFalse(row("Library").exists)
    screenshot("delete-done")
    app.terminate()
    // Stop ends the walk between two entries and says how many were deleted.
    launch("operation-slow")
    row("Library").click()
    app.buttons["delete"].click()
    XCTAssertTrue(app.staticTexts["confirmation-title"].appears(within: 8))
    app.buttons["confirm-action"].click()
    phase("Deleting “Library”…", timeout: 8)
    // Stop once the walk has removed an item.
    XCTAssertTrue(until { items().count > 0 }, "the walk removes items")
    app.buttons["stop-scan"].click()
    text("outcome", contains: "Deletion stopped.", timeout: 12)
    let stopped = (app.staticTexts["outcome"].value as? String) ?? ""
    print("DELETE stopped: \(stopped)")
    XCTAssertNotNil(
      stopped.range(
        of: #"^Deletion stopped\. [0-9,]+ items? deleted\.$"#, options: .regularExpression),
      stopped)
    operationEnds()
    XCTAssertTrue(row("Library").exists, "the survivors stay")
    screenshot("delete-stopped")
  }
  func testSkippedItemsShowACountAndTheirReasonsInDetails() throws {
    launch("operation-skip")
    prepare("delete", target: "Library")
    app.buttons["confirm-action"].click()
    outcome(is: "Deleted. 3 items skipped.")
    operationEnds()
    XCTAssertTrue(row("Library").exists, "the folders of skipped items stay")
    let details = app.disclosureTriangles["issues"]
    XCTAssertTrue(details.appears(within: 8))
    let chevron = app.staticTexts["outcome"].frame.minX + 4.5 - details.frame.minX
    details.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: chevron, dy: details.frame.height / 2)).click()
    XCTAssertTrue(
      anyText(containing: "Skipped /Users/ana/Library/Caches/cache 01.db: permission denied")
        .appears(within: 8))
    XCTAssertTrue(
      anyText(containing: "cache 02.cache: not permitted, for example locked").exists)
    screenshot("delete-skipped-details")
  }
  /// The names of the tree rows whose centers lie inside the tree, from one snapshot. The table
  /// creates row views only near the visible rows.
  func visibleRows() -> Set<String> {
    guard let tree = try? app.outlines["entry-tree"].snapshot() else { return [] }
    var names: Set<String> = []
    func visit(_ element: XCUIElementSnapshot) {
      if element.identifier.hasPrefix("entry-"), element.elementType == .staticText,
        tree.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
      {
        names.insert(String(element.identifier.dropFirst("entry-".count)))
      }
      element.children.forEach(visit)
    }
    visit(tree)
    return names
  }
  /// After a Delete with skips, a plain Delete and a Trash, every sibling row stays visible in
  /// the tree; a surviving selection is revealed, never scrolled past the last row.
  func testSiblingRowsStayVisibleAfterDeleteWithSkipsDeleteAndTrash() throws {
    continueAfterFailure = true
    let siblings: Set = [
      "Movies", "Downloads", "Pictures", "Projects", "Music", ".Trash", "Documents",
    ]
    for (scenario, action, expected, survives) in [
      ("operation-skip", "delete", "Deleted. 3 items skipped.", true),
      ("operation-quick", "delete", "Deleted.", false),
      ("operation-quick", "trash", "Moved to Trash.", false),
    ] {
      launch(scenario)
      prepare(action, target: "Library")
      app.buttons["confirm-action"].click()
      outcome(is: expected)
      let want = survives ? siblings.union(["Library"]) : siblings
      let deadline = Date().addingTimeInterval(8)
      var shown = visibleRows()
      while shown != want, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
        shown = visibleRows()
      }
      screenshot("siblings-\(scenario)-\(action)")
      XCTAssertEqual(shown, want, "\(scenario) \(action): every remaining row is visible")
      if survives { text("selected-name", contains: "Library") }
      app.terminate()
    }
  }
  /// Frame sampling across repeated map clicks: the fixture-only `map-selection-gaps` probe
  /// records every drawn map frame. No frame may lose the selection dim between the old
  /// selection and the new one (the click flicker).
  func testRepeatedMapClicksNeverDrawAFrameWithoutTheSelectionDim() throws {
    launch("prototype-home", appearance: "dark")
    let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "map-file-"))
    XCTAssertTrue(tiles.firstMatch.appears(within: 8))
    let probe = app.descendants(matching: .any)["map-selection-gaps"]
    XCTAssertTrue(probe.appears(within: 8), "frame sampler")
    let count = tiles.count
    for i in 0..<40 {
      tiles.element(boundBy: (i * 7) % count).click()
      Thread.sleep(forTimeInterval: 0.15)
    }
    Thread.sleep(forTimeInterval: 0.5)
    let values = Dictionary(
      uniqueKeysWithValues: probe.label.split(separator: " ").compactMap { part in
        let pair = part.split(separator: "=")
        return pair.count == 2 ? (String(pair[0]), Int(pair[1]) ?? -1) : nil
      })
    print("FLICKER \(probe.label)")
    XCTAssertGreaterThanOrEqual(values["selections"] ?? 0, 30)
    XCTAssertEqual(values["gaps"], 0, "frames drawn without the selection dim")
    screenshot("flicker-after-clicks")
  }
  /// The header shows the scope size alone, the card shows only the item count of a directory
  /// and the size of a grouped block: no accounting notes.
  func testHeaderAndCardShowOnlySizesAndCountsWithoutAccountingNotes() throws {
    continueAfterFailure = true
    launch()
    let size = "^[0-9][0-9.,]* (bytes|KB|MB|GB|TB|PB)$"
    let total = (app.staticTexts["scope-total"].value as? String) ?? ""
    XCTAssertNotNil(total.range(of: size, options: .regularExpression), "header total \(total)")
    let hatch = try XCTUnwrap(try hatchPoint())
    row("large-file").click()
    text("selected-path", contains: "/Workspace/large-file")
    XCTAssertFalse(anyText(containing: "Recorded allocation").exists, "file card")
    XCTAssertFalse(app.staticTexts["sharing-note"].exists)
    screenshot("card-file")
    // A hard link whose allocation is counted at its other name has no sharing note.
    row("hardlink-b").click()
    text("selected-path", contains: "/Workspace/hardlink-b")
    XCTAssertFalse(app.staticTexts["sharing-note"].exists, "hard link card")
    for note in ["Shared space counted elsewhere", "Shared or unknown size"] {
      XCTAssertFalse(anyText(containing: note).exists, note)
    }
    row("small-files").click()
    text("selected-path", contains: "/Workspace/small-files")
    let count = anyText(containing: " direct items")
    XCTAssertTrue(count.appears(within: 8))
    let caption = (count.value as? String) ?? count.label
    XCTAssertNotNil(
      caption.range(of: "^[0-9][0-9,]* direct items$", options: .regularExpression), caption)
    screenshot("card-directory")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(app.staticTexts["selected-path"].disappears(within: 8))
    hatch.click()
    let grouped = app.staticTexts["aggregate-text"]
    XCTAssertTrue(grouped.appears(within: 8))
    let groupedSize = (grouped.value as? String) ?? grouped.label
    XCTAssertNotNil(
      groupedSize.range(of: size, options: .regularExpression), "grouped card \(groupedSize)")
    XCTAssertFalse(app.staticTexts["grouped-note"].exists)
    XCTAssertFalse(anyText(containing: "grouped directory allocation").exists)
    XCTAssertTrue(app.buttons["Show Directory Contents"].exists)
    screenshot("card-grouped")
  }
  /// Help tags: the Incomplete and Not saved badges stay and have no help tag; Refresh says what
  /// it does, without a snapshot note. The badges come from a refresh. In trials the first
  /// help tag in a window showed within about 2 s, but often none after one had shown, and none
  /// after the pointer rested on text without one. So each check has its own launch, and a
  /// badge is hovered once: later tries could not show its help tag.
  func testRefreshHelpTagHasNoSnapshotNoteAndBadgesHaveNoHelpTags() throws {
    continueAfterFailure = true
    for (badge, name) in [("stale", "Incomplete"), ("dirty", "Not saved")] {
      launch("unknown-allocation")
      app.buttons["refresh"].click()
      XCTAssertTrue(app.staticTexts[badge].appears(within: 8))
      text(badge, contains: name)
      XCTAssertFalse(showsHelpTag(app.staticTexts[badge], tries: 1), "\(name) badge")
      screenshot("badge-\(badge)-without-help-tag")
      app.terminate()
    }
    launch()
    let refreshHelp = try helpTagText(app.buttons["refresh"])
    print("HELP refresh \(refreshHelp)")
    XCTAssertTrue(refreshHelp.contains("Rescan the focused directory"), refreshHelp)
    for part in ["memory", "snapshot"] { XCTAssertFalse(refreshHelp.contains(part), refreshHelp) }
  }
  /// Hovers `element` up to `tries` times and reports whether a help tag appears. In trials
  /// macOS sometimes skipped a help tag, mostly after clicks, so each try first rests the
  /// pointer on two points of the tree.
  func showsHelpTag(_ element: XCUIElement, tries: Int = 3) -> Bool {
    let tag = app.helpTags.firstMatch
    for _ in 0..<tries {
      for offset in [0.3, 0.6] {
        app.outlines["entry-tree"].coordinate(
          withNormalizedOffset: CGVector(dx: offset, dy: offset)
        ).hover()
        Thread.sleep(forTimeInterval: 1)
      }
      element.hover()
      if tag.appears(within: 4) { return true }
    }
    return false
  }
  /// Hovers `element` and reads its help tag with on-device text recognition: the help tag
  /// exposes no text to accessibility.
  func helpTagText(_ element: XCUIElement) throws -> String {
    let tag = app.helpTags.firstMatch
    XCTAssertTrue(showsHelpTag(element), "help tag")
    Thread.sleep(forTimeInterval: 0.5)
    let shot = tag.screenshot()
    let attachment = XCTAttachment(screenshot: shot)
    attachment.name = "help-tag"
    attachment.lifetime = .keepAlways
    add(attachment)
    let image = try XCTUnwrap(shot.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: " ")
  }
}
