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
  /// How long a test watches for a change that must not happen, such as an alert that a key
  /// must not open or close. The app answers a key or a menu command within a few hundred
  /// milliseconds; nothing signals that it chose to do nothing.
  static let quietPeriod: TimeInterval = 1
  /// Reports whether `condition` holds on every check for `duration` seconds.
  func stays(_ condition: () -> Bool, for duration: TimeInterval) -> Bool {
    !poll(duration) { !condition() }
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
    XCTAssertTrue(stays({ title.exists }, for: Self.quietPeriod))
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
  /// The chevron opens Details; testSkippedItems… also clicks the word. The other failure
  /// outcomes and the saved-only selection are model tests in OperationOutcomeModelTests.swift.
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
  /// Real clicks on two rows of the latency fixture. The timing (under 750 ms with live
  /// metadata that takes 1 s) is a model test in ExplorerModelTests.swift.
  func testImmediateSavedOnlySelection() {
    launch("metadata-delay")
    row("large-file").click()
    row("zero-byte").click()
    text("selected-name", contains: "zero-byte")
    text("selected-usage", contains: "0 bytes")
    text("selected-path", contains: "zero-byte")
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
    XCTAssertTrue(stays({ !title.exists }, for: Self.quietPeriod))
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
    XCTAssertTrue(stays({ title.exists }, for: Self.quietPeriod))
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
    XCTAssertTrue(until(5) { app.windows.count + app.dialogs.count >= 2 }, "the About panel")
    XCTAssertFalse(menuItem("File", "Move to Trash…").isEnabled)
    XCTAssertFalse(menuBarItem("File").menuItems["Delete Immediately…"].isEnabled)
    screenshot("file-menu-about-panel-key")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [.command])
    app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [.command, .option])
    XCTAssertTrue(stays({ !title.exists }, for: Self.quietPeriod))
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
  /// Writes last-folder metadata with `rootName` into a new directory that the test owns.
  func lastFolderMetadata(rootName: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reopen-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let record: [String: Any] = [
      "filename": "inventory-\(UUID().uuidString).dmap",
      "scannedAt": Date().timeIntervalSinceReferenceDate, "rootName": rootName,
    ]
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
  /// The File menu and the start screen name the last folder from owned metadata; the labels
  /// for other metadata are model tests. Fixture mode only reads the metadata: Reopen stays
  /// disabled, and the directory stays unchanged.
  func testReopenNamesTheLastFolderAndFixtureStorageStaysUnchanged() throws {
    let storage = try lastFolderMetadata(rootName: "/Workspace")
    let before = try listing(storage)
    launch(storage: storage)
    // The label proves that the app read this directory.
    let titles = fileMenuTitles()
    XCTAssertEqual(
      Array(titles.prefix(2)), ["Choose Folder…", "Reopen “Workspace”"], "\(titles)")
    XCTAssertFalse(titles.contains("Open Snapshot…"), "\(titles)")
    XCTAssertFalse(titles.contains { $0.hasPrefix("Open Last") }, "\(titles)")
    XCTAssertFalse(menuBarItem("File").menuItems["Reopen “Workspace”"].isEnabled)
    screenshot("reopen-file-menu")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    app.typeKey("o", modifierFlags: [.command])
    XCTAssertEqual(app.dialogs.count, 0)
    app.terminate()
    launchStartScreen(storage: storage)
    let reopen = app.buttons["reopen-last-folder"]
    XCTAssertTrue(reopen.appears(within: 8))
    XCTAssertEqual(reopen.label, "Reopen “Workspace”")
    XCTAssertFalse(reopen.isEnabled)
    XCTAssertFalse(app.buttons["open-snapshot"].exists)
    XCTAssertFalse(app.buttons["Open Snapshot…"].exists)
    screenshot("reopen-start-screen")
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
  func inkCenter(_ element: XCUIElement, row: XCUIElement, pixels p: WindowPixels) -> CGFloat? {
    let frame = element.frame.intersection(row.frame.insetBy(dx: 0, dy: 1.5))
    let x0 = p.x(frame.minX)
    let x1 = p.x(frame.maxX - 1)
    let y0 = p.y(frame.minY)
    let y1 = p.y(frame.maxY)
    guard x0 < x1, y0 < y1 else { return nil }
    var top: Int?
    var lowest: [Int: Int] = [:]
    for y in y0..<y1 {
      // One point left of the text frame is background on every pixel row.
      let reference = p.rgb(p.x(frame.minX - 1), y)
      for x in x0..<x1 {
        let pixel = p.rgb(x, y)
        if (0..<3).contains(where: { abs(pixel[$0] - reference[$0]) > 64 }) {
          top = top ?? y
          lowest[x] = y
        }
      }
    }
    let rows = Dictionary(grouping: lowest.values, by: { $0 }).mapValues(\.count)
    guard let top, let baseline = rows.max(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key
    else { return nil }
    return CGFloat(top + baseline + 1) / 2 / p.scale + p.origin.y
  }
  func testTreeSizeTextCentersWithNameOnSelectedAndUnselectedRows() throws {
    continueAfterFailure = true  // Report both rows in every appearance.
    for appearance in Self.appearances {
      launch(appearance: appearance)
      row("small-files").click()
      text("selected-name", contains: "small-files")
      let pixels = try windowPixels()
      for (name, selected) in [("small-files", true), ("trash", false)] {
        let tableRow = app.outlines["entry-tree"].tableRows.containing(
          .staticText, identifier: "entry-\(name)"
        ).firstMatch
        XCTAssertEqual(tableRow.isSelected, selected, name)
        let size = tableRow.staticTexts["tree-size"]
        XCTAssertTrue(size.exists, name)
        let nameCenter = try XCTUnwrap(inkCenter(row(name), row: tableRow, pixels: pixels), name)
        let sizeCenter = try XCTUnwrap(inkCenter(size, row: tableRow, pixels: pixels), name)
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
    XCTAssertTrue(stays({ !row("large-file").exists }, for: Self.quietPeriod))
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
    let window = app.windows.firstMatch
    guard
      let (x, y) = Self.hatchPixel(
        p, light: levels.light, dark: levels.dark, minX: p.x(minX),
        top: p.y(window.frame.minY + 120))
    else {
      XCTFail("no hatch area")
      return nil
    }
    return window.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(
        dx: CGFloat(x) / p.scale + p.origin.x - window.frame.minX,
        dy: CGFloat(y) / p.scale + p.origin.y - window.frame.minY))
  }
  /// The first pixel, by rows from `top`, whose 13-pixel cross is all aggregate hatch: each
  /// pixel has one stripe level, the other level two pixels right, its own level four pixels
  /// right and one pixel up-right. A plain gray tile at one hatch level does not match.
  static func hatchPixel(
    _ p: WindowPixels, light: Int, dark: Int, minX: Int, top: Int
  ) -> (Int, Int)? {
    func at(_ c: [Int], _ level: Int) -> Bool { c.max()! - c.min()! <= 8 && abs(c[1] - level) <= 3 }
    func same(_ a: [Int], _ b: [Int]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= 2 } }
    func stripe(_ x: Int, _ y: Int) -> Bool {
      let (a, b) = (p.rgb(x, y), p.rgb(x + 2, y))
      return ((at(a, light) && at(b, dark)) || (at(a, dark) && at(b, light)))
        && same(a, p.rgb(x + 4, y)) && same(a, p.rgb(x + 1, y - 1))
    }
    for y in stride(from: max(top, 7), to: p.image.pixelsHigh - 8, by: 2) {
      for x in stride(from: max(0, minX) + 8, to: p.image.pixelsWide - 12, by: 2)
      where (-6...6).allSatisfy({ d in stripe(x + d, y) && stripe(x, y + d) }) {
        return (x, y)
      }
    }
    return nil
  }
  /// The hatch search on drawn pixels, without the app: a plain gray area at the light hatch
  /// level does not match; diagonal stripes of the two levels do.
  func testHatchSearchRejectsAPlainGrayAreaAndFindsStripes() throws {
    let (light, dark) = (128, 96)
    let image = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8,
        samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    func fill(_ level: (Int, Int) -> Int) {
      for y in 0..<48 {
        for x in 0..<48 {
          var pixel = [Int](repeating: level(x, y), count: 3)
          image.setPixel(&pixel, atX: x, y: y)
        }
      }
    }
    let pixels = WindowPixels(image: image, origin: .zero, scale: 1)
    fill { _, _ in light }
    XCTAssertNil(Self.hatchPixel(pixels, light: light, dark: dark, minX: 0, top: 8), "plain gray")
    // Two pixels wide with a period of four, constant along x + y, as Rust draws the hatch.
    fill { x, y in (x + y) / 2 % 2 == 0 ? light : dark }
    XCTAssertNotNil(Self.hatchPixel(pixels, light: light, dark: dark, minX: 0, top: 8), "stripes")
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
  /// The window shows the map bitmap 1:1 and the tree in system colors, in light and dark.
  /// Rust pixel tests own the map colors (src/explorer_tests.rs, src/bridge/tests/map_pixels.rs);
  /// AppearanceModelTests.swift owns the inset style and the adaptive swatch color. This test
  /// checks what only the real window shows: color management, scaling and the background.
  func testWindowShowsTheMapBitmapOneToOneAndTheTreeInSystemColors() throws {
    continueAfterFailure = true
    for appearance in ["light", "dark"] {
      launch("dix", appearance: appearance)
      let tile = app.buttons["map-file-Movie.mov"]
      XCTAssertTrue(tile.appears(within: 8))
      row("Tiny files").hover()
      let p = try windowPixels()
      // The movie row's swatch shows its file color; the tile gradient passes through it.
      let movie = row("Movie.mov").frame
      let swatch = p.mean(CGPoint(x: movie.minX - 10.5, y: movie.midY)).map { Int($0.rounded()) }
      var nearest = Int.max
      let frame = tile.frame.insetBy(dx: 4, dy: 4)
      for y in stride(from: p.y(frame.minY), to: p.y(frame.maxY), by: 2) {
        for x in stride(from: p.x(frame.minX), to: p.x(frame.maxX), by: 2) {
          nearest = min(nearest, zip(p.rgb(x, y), swatch).map { abs($0 - $1) }.max()!)
        }
      }
      print("SRGB \(appearance) swatch=\(swatch) nearest=\(nearest)")
      XCTAssertLessThanOrEqual(nearest, 3, "\(appearance): map tile and swatch colors differ")
      // Rust darkens one backing pixel on each tile edge to 0.55 of the next pixel inside. A
      // scaled or blurred bitmap would not keep that one-pixel seam.
      let srgb = try windowPixels(srgb: true)
      let f = tile.frame
      let (x0, y0) = (
        Int(((f.minX - srgb.origin.x) * srgb.scale - 0.5).rounded(.up)),
        Int(((f.minY - srgb.origin.y) * srgb.scale - 0.5).rounded(.up))
      )
      let (x1, y1) = (
        Int(((f.maxX - srgb.origin.x) * srgb.scale - 0.5).rounded(.up)),
        Int(((f.maxY - srgb.origin.y) * srgb.scale - 0.5).rounded(.up))
      )
      var ratios: [Double] = []
      for fraction in [0.25, 0.5, 0.75] {
        let x = x0 + Int(Double(x1 - x0) * fraction)
        let y = y0 + Int(Double(y1 - y0) * fraction)
        for (edge, inside) in [
          ((x0, y), (x0 + 1, y)), ((x, y0), (x, y0 + 1)), ((x1 - 1, y), (x1 - 2, y)),
          ((x, y1 - 1), (x, y1 - 2)),
        ] {
          let (e, i) = (srgb.rgb(edge.0, edge.1), srgb.rgb(inside.0, inside.1))
          ratios.append(Double(e.reduce(0, +)) / Double(max(1, i.reduce(0, +))))
        }
      }
      let seam = ratios.reduce(0, +) / Double(ratios.count)
      print("SEAM \(appearance) edge/interior mean=\(seam) \(ratios)")
      XCTAssertEqual(seam, 0.55, accuracy: 0.04, "\(appearance): the one-pixel seam")
      // The empty tree area below the last row and the center of a directory swatch.
      var expected: (background: [Double], swatch: [Double]) = ([], [])
      NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)!
        .performAsCurrentDrawingAppearance {
          func rgb(_ color: NSColor) -> [Double] {
            let c = color.usingColorSpace(.sRGB)!
            return [c.redComponent, c.greenComponent, c.blueComponent].map { $0 * 255 }
          }
          expected = (rgb(.controlBackgroundColor), rgb(.systemGray))
        }
      let rows = ["Projects", "Movie.mov", "Tiny files"].map { row($0).frame.maxY }
      let empty = CGPoint(x: app.outlines["entry-tree"].frame.midX, y: rows.max()! + 60)
      let projects = row("Projects").frame
      let background = p.mean(empty)
      let directory = p.mean(CGPoint(x: projects.minX - 10.5, y: projects.midY))
      print("TREE \(appearance) background=\(background) swatch=\(directory) expected=\(expected)")
      for c in 0..<3 {
        XCTAssertEqual(
          background[c], expected.background[c], accuracy: 4, "\(appearance) background")
        XCTAssertEqual(directory[c], expected.swatch[c], accuracy: 6, "\(appearance) swatch")
      }
      screenshot("window-colors-\(appearance)")
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

  // MARK: Map clicks, status bar, Esc and operation progress

  /// The text of the status bar; empty when it shows nothing.
  func statusPath() -> String {
    let element = app.staticTexts["status-path"]
    guard element.exists else { return "" }
    return (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
  }
  /// Real clicks on a nested `.Trash`, one block at its parent's level: a click selects that
  /// `.Trash`, the hover names its path and a double click focuses it. Its stripes and colors
  /// are Rust pixel tests in src/bridge/tests/map_pixels.rs.
  func testNestedTrashBlockSelectsOnClickNamesItsPathAndFocusesOnDoubleClick() throws {
    launch("prototype-home-nested-trash", appearance: "dark")
    row("Projects").doubleClick()
    text("focus-name", contains: "Projects")
    // The `.Trash` block is one map target, which selects the directory.
    let trash = app.buttons["map-file-.Trash"]
    XCTAssertTrue(trash.appears(within: 8), "Projects/.Trash on the Projects map")
    offMap()
    screenshot("nested-trash-dark-projects")
    trash.click()
    text("selected-name", contains: ".Trash")
    text("selected-path", contains: "/Users/ana/Projects/.Trash")
    hovered("/Users/ana/Projects/.Trash")
    XCTAssertEqual(statusPath(), "/Users/ana/Projects/.Trash")
    XCTAssertFalse(app.buttons["map-file-Old render 01.mov"].exists, "children are not drawn")
    screenshot("nested-trash-dark-selected")
    trash.doubleClick()
    text("focus-name", contains: ".Trash")
    XCTAssertTrue(app.buttons["map-file-Old render 01.mov"].appears(within: 8))
    screenshot("nested-trash-dark-focused")
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
  /// Real clicks on Delete, its confirmation and Stop, with the bar of each phase that they
  /// reach. StatusAndProgressTests.swift holds each stage of `operation-paused`: every label,
  /// counter, Stop state and outcome, also "Updating view…" and a complete Delete.
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
    // Stop once the walk has removed more items: the counter is live.
    var second = items()
    _ = until {
      second = items()
      return second.count > first.count
    }
    print("DELETE counter \(first.shown) -> \(second.shown)")
    XCTAssertGreaterThan(second.count, first.count, "the removed-items counter is live")
    XCTAssertNotNil(second.shown.range(of: #"^[0-9,]+ items?$"#, options: .regularExpression))
    app.buttons["stop-scan"].click()
    // The 3 s update stage keeps the bar, with Stop shown but disabled: the deletion is done.
    phase("Updating view…", timeout: 8)
    let stop = app.buttons["stop-scan"]
    XCTAssertTrue(until { stop.exists && !stop.isEnabled }, "Stop is disabled in the update")
    screenshot("delete-updating")
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
    // The open disclosure is taller, so both points keep their offsets from the closed frame.
    // Its accessibility frame runs from the banner edge to the end of the word "Details"; the
    // chevron sits below the start of the outcome text.
    let closed = details.frame
    let chevronX = app.staticTexts["outcome"].frame.minX + 4.5 - closed.minX
    let chevron = details.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: chevronX, dy: closed.height / 2))
    let word = details.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: closed.width - 12, dy: closed.height / 2))
    XCTAssertGreaterThan(closed.width - 12 - chevronX, 12, "the word is right of the chevron")
    let window = app.windows.firstMatch.frame
    print(
      "FRAME details \(closed.minX - window.minX) \(closed.minY - window.minY) \(closed.width) \(closed.height) chevron \(chevronX)"
    )
    chevron.click()
    XCTAssertTrue(
      anyText(containing: "Skipped /Users/ana/Library/Caches/cache 01.db: permission denied")
        .appears(within: 8))
    XCTAssertTrue(
      anyText(containing: "cache 02.cache: not permitted, for example locked").exists)
    screenshot("delete-skipped-details")
    // The word "Details" opens and closes the disclosure like its chevron.
    let reason = anyText(containing: "cache 01.db: permission denied")
    chevron.click()
    XCTAssertTrue(reason.disappears(within: 8), "the chevron closes Details")
    word.click()
    XCTAssertTrue(reason.appears(within: 8), "a click on the word opens Details")
    screenshot("delete-skipped-details-after-word-click")
    word.click()
    XCTAssertTrue(reason.disappears(within: 8), "a click on the word closes Details")
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
      var shown: Set<String> = []
      _ = until {
        shown = visibleRows()
        return shown == want
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
      // The rhythm of quick user clicks: input, not a wait.
      Thread.sleep(forTimeInterval: 0.15)
    }
    // The probe has counted the last frame once the window stops changing.
    _ = settled { app.windows.firstMatch.screenshot() }
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
  /// it does, without a snapshot note. The badges come from a refresh. A help tag shows within
  /// about 2 s. Each check has its own launch and hovers a badge once: a SwiftUI `.help` on a
  /// badge would show no help tag after the pointer rested on a spot without one (see
  /// `toolTip`), so a shared window or a second try could miss it.
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
  /// Help tags show after the pointer rested on the map, again for the same element, and after
  /// a confirmed Delete. With SwiftUI `.help`, a rest on any spot without a help tag stopped all
  /// later help tags in the window, so they seemed lost after a click on the map and a Delete.
  func testHelpTagsShowAfterARestOnTheMapAndAfterADelete() throws {
    continueAfterFailure = true
    launch()
    let tile = app.buttons["map-file-large-file"]
    XCTAssertTrue(tile.appears(within: 8))
    // A user rest, longer than the help tag delay: this is input, not a wait.
    tile.hover()
    Thread.sleep(forTimeInterval: 4)
    let window = app.windows.firstMatch.frame
    for id in ["refresh", "map-file-large-file"] {
      let f = app.descendants(matching: .any)[id].firstMatch.frame
      print("FRAME \(id) \(f.minX - window.minX) \(f.minY - window.minY) \(f.width) \(f.height)")
    }
    XCTAssertTrue(showsHelpTag(app.buttons["refresh"]), "Refresh after a rest on the map")
    screenshot("help-tag-after-map-rest")
    XCTAssertTrue(showsHelpTag(app.staticTexts["focus-name"]), "breadcrumb after Refresh")
    XCTAssertTrue(showsHelpTag(app.buttons["refresh"]), "Refresh a second time")
    prepare("delete", target: "large-file")
    app.buttons["confirm-action"].click()
    outcome(is: "Deleted.")
    operationEnds()
    XCTAssertTrue(showsHelpTag(app.staticTexts["focus-name"]), "breadcrumb after a Delete")
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
    // The help tag fades in: read it once two screenshots in a row are equal.
    let png = settled { tag.screenshot() }
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = "help-tag"
    attachment.lifetime = .keepAlways
    add(attachment)
    let image = try XCTUnwrap(
      NSImage(data: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: " ")
  }
}
