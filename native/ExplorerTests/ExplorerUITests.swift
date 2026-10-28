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
  /// Waits until the fixture-only `map-hover` probe names `value` ("none" without a hover).
  /// The status bar shows only the selected path, so the hover has no visible text.
  func hovered(_ value: String, timeout: TimeInterval = 8) {
    let probe = app.descendants(matching: .any)["map-hover"]
    XCTAssertTrue(probe.waitForExistence(timeout: timeout))
    let predicate = NSPredicate(format: "label CONTAINS %@", value)
    let result = XCTWaiter.wait(
      for: [XCTNSPredicateExpectation(predicate: predicate, object: probe)], timeout: timeout)
    XCTAssertEqual(result, .completed, "hover must name \(value), got \(probe.label)")
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
    hovered(name)
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
      let tile = app.buttons["map-file-large-file"]
      XCTAssertTrue(tile.waitForExistence(timeout: 8))
      tile.hover()
      hovered("large-file")
      // The status bar shows the selected path, not a localized amount.
      text("status-path", contains: "/Workspace/large-file")
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
  func launchStartScreen(storage: URL, appearance: String? = nil) {
    app = XCUIApplication()
    app.launchArguments = ["--fixture-mode", "-AppleLocale", "en_US"]
    app.launchEnvironment["DI_UI_TEST"] = "1"
    app.launchEnvironment["DI_MODEL_TEST"] = "0"
    app.launchEnvironment["DI_FIXTURE_STORAGE_ROOT"] = storage.path
    if let appearance { app.launchEnvironment["DI_APPEARANCE"] = appearance }
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
    continueAfterFailure = true  // Report both rows in every appearance.
    for appearance in Self.appearances {
      launch(appearance: appearance)
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
    hovered("large-file")
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
  /// `srgb` converts the screenshot from the display profile to sRGB, so colored pixels
  /// compare with the sRGB bytes that Rust draws. Neutral grays do not need it.
  func windowPixels(srgb: Bool = false) throws -> WindowPixels {
    let window = app.windows.firstMatch
    var image = try XCTUnwrap(NSBitmapImageRep(data: window.screenshot().pngRepresentation))
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
  /// Moves the pointer to the tree. Without the hover probe (an older product) it waits a
  /// fixed second, so a measurement still runs and fails on the measured property.
  func offMap() {
    app.outlines["entry-tree"].hover()
    if app.descendants(matching: .any)["map-hover"].waitForExistence(timeout: 2) {
      hovered("none")
    } else {
      Thread.sleep(forTimeInterval: 1)
    }
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
  func clickHatch() throws {
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
        window.coordinate(withNormalizedOffset: .zero).withOffset(
          CGVector(
            dx: CGFloat(x) / p.scale + p.origin.x - window.frame.minX,
            dy: CGFloat(y) / p.scale + p.origin.y - window.frame.minY)
        ).click()
        return
      }
    }
    XCTFail("no hatch area to click")
  }
  func testAppearanceVariantsRenderMapChromeAndSheets() {
    for appearance in Self.appearances {
      launch(appearance: appearance)
      let probe = app.descendants(matching: .any)["map-appearance"]
      XCTAssertTrue(probe.waitForExistence(timeout: 8), appearance)
      XCTAssertEqual(probe.label, appearance)
      leaveMap()
      screenshot("\(appearance)-overview")
      row("large-file").click()
      text("selected-name", contains: "large-file")
      text("selected-path", contains: "large-file")
      screenshot("\(appearance)-selection")
      let tile = app.buttons["map-file-large-file"]
      XCTAssertTrue(tile.waitForExistence(timeout: 8))
      tile.hover()
      hovered("large-file")
      screenshot("\(appearance)-hover")
      for action in ["trash", "delete"] {
        prepare(action, target: "large-file")
        screenshot("\(appearance)-\(action)-sheet")
        app.buttons["cancel-action"].click()
        XCTAssertTrue(app.staticTexts["confirmation-title"].waitForNonExistence(timeout: 8))
      }
      // Each sheet and the hover keep the appearance: no rebuild with another variant.
      XCTAssertEqual(probe.label, appearance)
      app.terminate()
    }
  }
  func testMapHatchFollowsAppearance() throws {
    continueAfterFailure = true  // Report every appearance.
    for appearance in Self.appearances {
      launch(appearance: appearance)
      XCTAssertTrue(app.buttons["map-file-large-file"].waitForExistence(timeout: 8))
      leaveMap()
      let hatch = hatchLevels(
        try windowPixels(), minX: app.outlines["entry-tree"].frame.maxX)
      let ratio = Self.contrast(
        [hatch.light, hatch.light, hatch.light], [hatch.dark, hatch.dark, hatch.dark])
      print(
        "HATCH \(appearance) light=\(hatch.light) dark=\(hatch.dark) ratio=\(ratio) pixels=\(hatch.pixels)"
      )
      XCTAssertGreaterThan(hatch.pixels, 500, appearance)
      if appearance.hasPrefix("light") {
        XCTAssertGreaterThan(hatch.dark, 140, "\(appearance): light hatch on a light window")
      } else {
        XCTAssertLessThan(hatch.light, 110, "\(appearance): dark hatch on a dark window")
      }
      if appearance.hasSuffix("contrast") {
        XCTAssertGreaterThan(ratio, 2.3, "\(appearance): stronger hatch stripes")
      } else {
        XCTAssertLessThan(ratio, 1.5, appearance)
      }
      screenshot("hatch-\(appearance)")
      app.terminate()
    }
  }
  /// Contrast of the top seam of a map tile against the next pixel row inside the tile, at
  /// three columns. The seam is the row above two matching interior rows.
  func seamContrast(_ tile: XCUIElement, _ p: WindowPixels) -> Double? {
    var ratios: [Double] = []
    for fraction in [0.25, 0.5, 0.75] {
      let x = p.x(tile.frame.minX + tile.frame.width * fraction)
      let top = p.y(tile.frame.minY)
      for y in (top - 3)...(top + 3) {
        let (seam, inside, next) = (p.rgb(x, y), p.rgb(x, y + 1), p.rgb(x, y + 2))
        if zip(inside, next).allSatisfy({ abs($0 - $1) <= 3 }),
          zip(seam, inside).contains(where: { abs($0 - $1) > 3 })
        {
          ratios.append(Self.contrast(seam, inside))
          break
        }
      }
    }
    return ratios.count == 3 ? ratios.min() : nil
  }
  func testIncreasedContrastDarkensMapSeams() throws {
    continueAfterFailure = true
    for appearance in Self.appearances {
      launch(appearance: appearance)
      let tile = app.buttons["map-file-large-file"]
      XCTAssertTrue(tile.waitForExistence(timeout: 8))
      leaveMap()
      let ratio = try XCTUnwrap(seamContrast(tile, try windowPixels()), appearance)
      print("SEAM \(appearance) ratio=\(ratio)")
      if appearance.hasSuffix("contrast") {
        XCTAssertGreaterThanOrEqual(ratio, 3.0, "\(appearance) seam")
      } else {
        // The ordinary seam is the design's inset (x0.55); Increase Contrast is stronger.
        XCTAssertGreaterThanOrEqual(ratio, 1.8, "\(appearance) seam")
        XCTAssertLessThan(ratio, 3.0, "\(appearance) seam")
      }
      screenshot("seam-\(appearance)")
      app.terminate()
    }
  }
  /// Increase Contrast: an opaque 2-point hover outline, black (the label color) in light and
  /// white in dark. Without Increase Contrast: the 1-point white outline at 70% opacity.
  func testHoverStrokeFollowsAppearanceAndIsOpaqueTwoPointsWithIncreasedContrast() throws {
    continueAfterFailure = true
    for appearance in Self.appearances {
      launch(appearance: appearance)
      let tile = app.buttons["map-file-large-file"]
      XCTAssertTrue(tile.waitForExistence(timeout: 8))
      tile.hover()
      hovered("large-file")
      screenshot("hover-stroke-\(appearance)")
      let p = try windowPixels()
      // Backing pixels from the left and the top edge. With 2 points (4 backing pixels), the
      // first three are fully covered and the sixth is inside the tile.
      let left = Int(((tile.frame.minX - p.origin.x) * p.scale).rounded(.up))
      let top = Int(((tile.frame.minY - p.origin.y) * p.scale).rounded(.up))
      let midX = p.x(tile.frame.midX)
      let midY = p.y(tile.frame.midY)
      let edge =
        (0..<3).map { p.rgb(left + $0, midY) } + (0..<3).map { p.rgb(midX, top + $0) }
      let inside = [p.rgb(left + 5, midY), p.rgb(midX, top + 5)]
      print("HOVER \(appearance) edge=\(edge) inside=\(inside)")
      for (pixel, interior) in zip([edge[0], edge[3]], inside) {
        switch appearance {
        case "light-contrast":
          XCTAssertLessThanOrEqual(pixel.max()!, 10, "\(appearance): opaque black \(pixel)")
        case "dark-contrast":
          XCTAssertGreaterThanOrEqual(pixel.min()!, 250, "\(appearance): opaque white \(pixel)")
        default:
          // White at 70% over the tile: lighter than the tile, but not opaque white.
          XCTAssertGreaterThan(pixel.min()!, interior.max()!, "\(appearance): white outline")
          XCTAssertLessThan(pixel.min()!, 250, "\(appearance): 70% opacity \(pixel)")
        }
      }
      if appearance.hasSuffix("contrast") {
        for pixel in edge {
          XCTAssertLessThanOrEqual(
            zip(pixel, edge[0]).map { abs($0 - $1) }.max()!, 3, "\(appearance): solid 2 points")
        }
        for pixel in inside {
          XCTAssertGreaterThan(
            zip(pixel, edge[0]).map { abs($0 - $1) }.max()!, 40, "\(appearance): 2 points wide")
        }
      }
      app.terminate()
    }
  }
  /// Map pixels by type color: for each colored kind of the prototype palette, the share of
  /// sampled map pixels whose hue is nearest to that kind. Gray pixels count as neutral.
  func kindShares(_ p: WindowPixels, map frame: CGRect) -> (
    shares: [String: Double], neutral: Double
  ) {
    let kinds: [(String, [Int])] = [
      ("video", [79, 138, 198]), ("image", [81, 153, 98]), ("audio", [171, 109, 166]),
      ("archive", [173, 124, 47]), ("app", [133, 122, 196]), ("code", [0, 153, 160]),
      ("cache", [190, 110, 82]), ("data", [138, 140, 52]),
    ]
    // The tint, the shade and the seam mix with white or black, which keeps the HSV hue.
    func hue(_ c: [Int]) -> (hue: Double, saturation: Double) {
      let (r, g, b) = (Double(c[0]), Double(c[1]), Double(c[2]))
      let high = max(r, g, b)
      let span = high - min(r, g, b)
      guard span > 0 else { return (0, 0) }
      let h: Double =
        high == r ? (g - b) / span : high == g ? 2 + (b - r) / span : 4 + (r - g) / span
      return ((h * 60 + 360).truncatingRemainder(dividingBy: 360), span / high)
    }
    let kindHues = kinds.map { ($0.0, hue($0.1).hue) }
    var counts: [String: Int] = [:]
    var (neutral, total) = (0, 0)
    for y in stride(from: p.y(frame.minY) + 2, to: p.y(frame.maxY) - 2, by: 3) {
      for x in stride(from: p.x(frame.minX) + 2, to: p.x(frame.maxX) - 2, by: 3) {
        total += 1
        let pixel = hue(p.rgb(x, y))
        guard pixel.saturation > 0.25 else {
          neutral += 1
          continue
        }
        var nearest = (kind: "", distance: 360.0)
        for (kind, kindHue) in kindHues {
          let d = abs(kindHue - pixel.hue)
          if min(d, 360 - d) < nearest.distance { nearest = (kind, min(d, 360 - d)) }
        }
        counts[nearest.kind, default: 0] += 1
      }
    }
    return (
      counts.mapValues { Double($0) / Double(total) }, Double(neutral) / Double(max(total, 1))
    )
  }
  /// `prototype-home` rebuilds the prototype's data with real extensions, so the map shows
  /// every colored kind of the palette. `presentation` stays unchanged: files without an
  /// extension draw a gray map.
  func testPrototypeHomeMapShowsEveryKindColorAndPresentationStaysGray() throws {
    continueAfterFailure = true
    for (scenario, appearance) in [
      ("prototype-home", "dark"), ("prototype-home", "light"), ("presentation", "dark"),
      ("presentation", "light"),
    ] {
      launch(scenario, appearance: appearance)
      let probe = app.descendants(matching: .any)["map-appearance"]
      guard probe.waitForExistence(timeout: 8) else {
        XCTFail("\(scenario) \(appearance): no map")
        app.terminate()
        continue
      }
      XCTAssertEqual(probe.label, appearance)
      let largest = scenario == "presentation" ? "large-file" : "Interview raw.mov"
      XCTAssertTrue(app.buttons["map-file-\(largest)"].waitForExistence(timeout: 8))
      row(scenario == "presentation" ? "zero-byte" : "Documents").hover()
      hovered("none")
      screenshot("\(scenario)-\(appearance)")
      // The map view is not an accessibility element. Its padded area starts at the probe,
      // right of the tree, and ends above the status bar; 20 points inside that area is map.
      let left = app.outlines["entry-tree"].frame.maxX + 20
      let top = probe.frame.minY + 20
      let map = CGRect(
        x: left, y: top, width: app.windows.firstMatch.frame.maxX - 20 - left,
        height: statusBarTop() - 20 - top)
      let result = kindShares(try windowPixels(), map: map)
      let report = result.shares.sorted { $0.key < $1.key }
        .map { "\($0.key)=\(String(format: "%.3f", $0.value))" }.joined(separator: " ")
      print(
        "KINDS \(scenario) \(appearance) map=\(map) neutral=\(String(format: "%.3f", result.neutral)) \(report)"
      )
      let shown = result.shares.filter { $0.value >= 0.005 }.keys.sorted()
      if scenario == "prototype-home" {
        XCTAssertEqual(
          shown, ["app", "archive", "audio", "cache", "code", "data", "image", "video"],
          "\(appearance): every colored kind covers at least 0.5% of the map")
        XCTAssertGreaterThanOrEqual(result.neutral, 0.005, "\(appearance): gray documents")
      } else {
        XCTAssertEqual(shown, [], "\(appearance): presentation files have no extension")
      }
      app.terminate()
    }
  }
  func testTreeUsesOpaqueContentBackgroundAndSystemGrayDirectorySwatch() throws {
    continueAfterFailure = true
    for appearance in Self.appearances {
      launch(appearance: appearance)
      XCTAssertTrue(row("zero-byte").waitForExistence(timeout: 8))
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
      XCTAssertTrue(tile.waitForExistence(timeout: 8))
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
  func testCaptionAndSecondaryTextMeetFourAndAHalfToOne() throws {
    continueAfterFailure = true
    let storage = try lastFolderMetadata(rootName: "/Workspace")
    for appearance in ["light", "dark"] {
      launch(appearance: appearance)
      // Measure only in the requested appearance.
      let probe = app.descendants(matching: .any)["map-appearance"]
      XCTAssertTrue(probe.waitForExistence(timeout: 8), appearance)
      if probe.exists { XCTAssertEqual(probe.label, appearance) }
      leaveMap()
      func check(_ name: String, _ element: XCUIElement, _ pixels: WindowPixels) {
        XCTAssertTrue(element.exists, name)
        let ratio = textContrast(element, pixels)
        print("TEXT \(appearance) \(name) ratio=\(ratio)")
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(appearance) \(name)")
      }
      check("empty-card hint", staticText("Click to select"), try windowPixels())
      row("large-file").click()
      text("selected-path", contains: "large-file")
      leaveMap()
      let selection = try windowPixels()
      check("card caption", staticText("Recorded allocation"), selection)
      check("card path", app.staticTexts["selected-path"], selection)
      check("status path", app.staticTexts["status-path"], selection)
      // The grouped-detail note moved from the footer to the card of a grouped block.
      try clickHatch()
      XCTAssertTrue(app.staticTexts["grouped-note"].waitForExistence(timeout: 8), appearance)
      leaveMap()
      check("card grouped note", app.staticTexts["grouped-note"], try windowPixels())
      screenshot("text-contrast-\(appearance)")
      app.terminate()
      launchStartScreen(storage: storage, appearance: appearance)
      XCTAssertTrue(app.buttons["reopen-last-folder"].waitForExistence(timeout: 8))
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
  /// The root `.Trash` is one striped region with the design's TRASH fill that selects the
  /// Trash directory. Focused, the Trash shows its files with type colors.
  func testRootTrashShowsTrashStripesAndSelectsTheTrashUntilFocused() throws {
    continueAfterFailure = true
    for appearance in Self.appearances {
      launch("prototype-home", appearance: appearance)
      let probe = app.descendants(matching: .any)["map-appearance"]
      XCTAssertTrue(probe.waitForExistence(timeout: 8))
      offMap()
      screenshot("trash-\(appearance)-home")
      let trash = trashPixels(try windowPixels(srgb: true), map: mapArea(), appearance: appearance)
      let ratio =
        trash.plain.isEmpty || trash.striped.isEmpty
        ? 0 : Self.contrast(trash.plain, trash.striped)
      print(
        "TRASH \(appearance) pixels=\(trash.count) deep=\(trash.deep.count) plain=\(trash.plain) striped=\(trash.striped) ratio=\(ratio)"
      )
      guard trash.count > 500, trash.deep.count > 20 else {
        XCTFail("\(appearance): no Trash stripes on the home map")
        app.terminate()
        continue
      }
      XCTAssertGreaterThan(
        ratio, appearance.hasSuffix("contrast") ? 1.4 : 1.1, "\(appearance): visible stripes")
      // One hit region: every point selects the Trash directory, not a file inside it.
      let deep = trash.deep
      for point in [deep[0], deep[deep.count / 2], deep[deep.count - 1]] {
        click(point)
        text("selected-name", contains: ".Trash")
        XCTAssertEqual(statusPath(), "/Users/ana/.Trash", appearance)
      }
      screenshot("trash-\(appearance)-selected")
      click(deep[deep.count / 2], double: true)
      text("focus-name", contains: ".Trash")
      XCTAssertTrue(app.buttons["map-file-Old clip 01.mov"].waitForExistence(timeout: 8))
      offMap()
      let pixels = try windowPixels(srgb: true)
      let inside = trashPixels(pixels, map: mapArea(), appearance: appearance)
      let video = kindShares(pixels, map: mapArea()).shares["video"] ?? 0
      print(
        "TRASH \(appearance) focused pixels=\(inside.count) deep=\(inside.deep.count) video=\(video)"
      )
      XCTAssertEqual(inside.deep.count, 0, "\(appearance): focused Trash has no striped region")
      XCTAssertGreaterThan(video, 0.3, "\(appearance): focused Trash shows video colors")
      screenshot("trash-\(appearance)-focused")
      app.terminate()
    }
  }
  /// Contrast of the seam pixel against the next pixel inside the same tile on the left, top,
  /// right and bottom edge, each the minimum over three points along the edge. The seam is the
  /// first or second backing pixel inside the edge (the larger contrast counts), so the seam
  /// of a neighbor outside the tile never counts.
  func edgeContrasts(_ tile: CGRect, _ p: WindowPixels) -> [Double] {
    func first(_ point: CGFloat, _ origin: CGFloat) -> Int {
      Int(((point - origin) * p.scale - 0.5).rounded(.up))
    }
    let (x0, y0) = (first(tile.minX, p.origin.x), first(tile.minY, p.origin.y))
    let (x1, y1) = (first(tile.maxX, p.origin.x), first(tile.maxY, p.origin.y))
    var sides: [Double] = []
    for side in 0..<4 {
      var ratios: [Double] = []
      for fraction in [0.25, 0.5, 0.75] {
        let x = x0 + Int(Double(x1 - x0) * fraction)
        let y = y0 + Int(Double(y1 - y0) * fraction)
        let pairs: [((Int, Int), (Int, Int))] =
          switch side {
          case 0: [((x0, y), (x0 + 1, y)), ((x0 + 1, y), (x0 + 2, y))]
          case 1: [((x, y0), (x, y0 + 1)), ((x, y0 + 1), (x, y0 + 2))]
          case 2: [((x1 - 1, y), (x1 - 2, y)), ((x1 - 2, y), (x1 - 3, y))]
          default: [((x, y1 - 1), (x, y1 - 2)), ((x, y1 - 2), (x, y1 - 3))]
          }
        ratios.append(
          pairs.map { Self.contrast(p.rgb($0.0.0, $0.0.1), p.rgb($0.1.0, $0.1.1)) }.max()!)
      }
      sides.append(ratios.min()!)
    }
    return sides
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
  /// Every tile has the design's seam on all four sides: one backing pixel at x0.55
  /// (the 0.5-point inset at 45% black). Increase Contrast keeps at least 3:1 on each side.
  func testMapTilesHaveTheDesignSeamOnAllFourSides() throws {
    continueAfterFailure = true
    for appearance in Self.appearances {
      launch("prototype-home", appearance: appearance)
      XCTAssertTrue(app.buttons["map-file-Interview raw.mov"].waitForExistence(timeout: 8))
      offMap()
      let p = try windowPixels()
      var minimum = [Double](repeating: 99, count: 4)
      var measured = 0
      for (name, frame) in largeTiles() {
        measured += 1
        let sides = edgeContrasts(frame, p)
        print("SEAMS \(appearance) \(name) left/top/right/bottom=\(sides)")
        minimum = zip(minimum, sides).map { min($0, $1) }
      }
      XCTAssertGreaterThanOrEqual(measured, 3, appearance)
      print("SEAMS \(appearance) minimum left/top/right/bottom=\(minimum)")
      let floor = appearance.hasSuffix("contrast") ? 3.0 : 1.8
      for (side, ratio) in zip(["left", "top", "right", "bottom"], minimum) {
        XCTAssertGreaterThanOrEqual(ratio, floor, "\(appearance) \(side) seam")
      }
      screenshot("seams-\(appearance)")
      app.terminate()
    }
  }
  /// Dark prototype-home against the design: tile interiors equal the CSS gradient over the
  /// kind color, and the seam darkens one backing pixel on each edge to 0.55 of the interior
  /// (the design's inset on a 2x grid). The old top/left seam at 0.775 left the map brighter.
  func testPrototypeHomeDarkMapMatchesTheDesignBrightness() throws {
    launch("prototype-home", appearance: "dark")
    XCTAssertTrue(app.buttons["map-file-Interview raw.mov"].waitForExistence(timeout: 8))
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
  /// The selection dims the rest of the map by 12% black (the design uses 28%). Every
  /// unselected seam stays visible, and the selected block keeps its white ring.
  func testSelectionDimIsLightAndKeepsUnselectedSeamsVisible() throws {
    continueAfterFailure = true
    for appearance in ["dark", "light"] {
      launch("prototype-home", appearance: appearance)
      XCTAssertTrue(app.buttons["map-file-Interview raw.mov"].waitForExistence(timeout: 8))
      let tiles = largeTiles()
      guard tiles.count >= 3 else {
        XCTFail("\(appearance): large tiles \(tiles.map(\.name))")
        app.terminate()
        continue
      }
      let (selected, others) = (tiles[0], tiles.dropFirst())
      offMap()
      let before = try windowPixels(srgb: true)
      app.buttons["map-file-\(selected.name)"].click()
      text("selected-name", contains: selected.name)
      offMap()
      let after = try windowPixels(srgb: true)
      var factors: [Double] = []
      var (seamsBefore, seamsAfter) = (99.0, 99.0)
      for other in others {
        let point = CGPoint(x: other.frame.midX, y: other.frame.midY)
        let (a, b) = (after.mean(point), before.mean(point))
        factors.append((0..<3).map { a[$0] / b[$0] }.reduce(0, +) / 3)
        seamsBefore = min(seamsBefore, edgeContrasts(other.frame, before).min()!)
        seamsAfter = min(seamsAfter, edgeContrasts(other.frame, after).min()!)
      }
      let dim = factors.reduce(0, +) / Double(factors.count)
      // The ring: 2 points of white centered 1.5 points inside the selected block's edge.
      let ring = after.mean(CGPoint(x: selected.frame.midX, y: selected.frame.minY + 1.5))
      print(
        "DIM \(appearance) factor=\(dim) per-tile=\(factors) seam-minimum-before=\(seamsBefore) seam-minimum-after=\(seamsAfter) ring=\(ring)"
      )
      XCTAssertEqual(dim, 0.88, accuracy: 0.03, "\(appearance): 12% dim")
      XCTAssertGreaterThanOrEqual(seamsAfter, 1.8, "\(appearance): unselected seams stay visible")
      XCTAssertGreaterThan(ring.min()!, 235, "\(appearance): white selection ring")
      screenshot("selection-dim-\(appearance)")
      app.terminate()
    }
  }
  /// Esc clears a tree or map selection: no card, no tree highlight, no dim, no status path.
  /// An open confirmation keeps its own Esc (Cancel) and the selection.
  func testEscapeClearsTheSelectionInTreeAndMap() throws {
    launch()
    let tile = app.buttons["map-file-large-file"]
    XCTAssertTrue(tile.waitForExistence(timeout: 8))
    offMap()
    let clear = try windowPixels()
    let probe = CGPoint(x: tile.frame.minX - 30, y: tile.frame.midY)
    row("large-file").click()
    text("selected-name", contains: "large-file")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(app.buttons["selected-name"].waitForNonExistence(timeout: 8), "tree Esc")
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
    XCTAssertTrue(app.buttons["selected-name"].waitForNonExistence(timeout: 8), "map Esc")
    // A confirmation sheet owns Esc: it cancels and the selection stays.
    prepare("delete", target: "large-file")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(app.staticTexts["confirmation-title"].waitForNonExistence(timeout: 8))
    text("selected-name", contains: "large-file")
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(app.buttons["selected-name"].waitForNonExistence(timeout: 8))
    XCTAssertTrue(row("large-file").exists)
    screenshot("esc-after-map")
  }
  /// The status bar shows only the complete path of the selected item. Hover text, the old
  /// default text and outcomes are gone from it; outcomes use the banner over the map.
  func testStatusBarShowsOnlyTheSelectedItemPath() throws {
    launch()
    let tile = app.buttons["map-file-large-file"]
    XCTAssertTrue(tile.waitForExistence(timeout: 8))
    XCTAssertEqual(statusPath(), "")
    XCTAssertEqual(
      app.staticTexts.matching(
        NSPredicate(
          format: "value CONTAINS %@ OR label CONTAINS %@", "Recorded disk usage",
          "Recorded disk usage")
      ).count, 0)
    tile.hover()
    hovered("large-file")
    XCTAssertEqual(statusPath(), "", "no hover text")
    row("large-file").click()
    text("status-path", contains: "/Workspace/large-file")
    XCTAssertEqual(statusPath(), "/Workspace/large-file")
    XCTAssertGreaterThanOrEqual(app.staticTexts["status-path"].frame.minY, statusBarTop() - 1)
    screenshot("status-bar-selected")
    // Deletion keeps the less-space warning in its confirmation.
    prepare("delete", target: "zero-byte")
    text("confirmation-warning", contains: "Deleting may free less space than shown.")
    app.buttons["cancel-action"].click()
    XCTAssertTrue(app.staticTexts["confirmation-title"].waitForNonExistence(timeout: 8))
    prepare("trash", target: "large-file")
    text("confirmation-warning", contains: "Trash may not free space until emptied.")
    app.buttons["confirm-action"].click()
    text("outcome", contains: "Moved to Trash")
    let outcome = app.staticTexts["outcome"]
    XCTAssertLessThan(outcome.frame.maxY, statusBarTop(), "the outcome is over the map")
    XCTAssertGreaterThan(outcome.frame.minX, app.outlines["entry-tree"].frame.maxX)
    XCTAssertFalse(statusPath().contains("Moved"))
    screenshot("status-bar-outcome-banner")
    app.buttons["dismiss-banner"].click()
    XCTAssertTrue(outcome.waitForNonExistence(timeout: 8))
    screenshot("status-bar-after-dismiss")
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
    let items = app.staticTexts["scan-items"]
    XCTAssertTrue(items.waitForExistence(timeout: 8))
    let first = (items.value as? String) ?? items.label
    Thread.sleep(forTimeInterval: 1.2)
    let second = (items.value as? String) ?? items.label
    print("REFRESH counter \(first) -> \(second)")
    XCTAssertNotEqual(first, second, "the counter is live")
    XCTAssertTrue(app.buttons["stop-scan"].isEnabled)
    screenshot("refresh-progress")
    app.buttons["stop-scan"].click()
    text("outcome", contains: "Refresh of “Library” stopped. The previous data is unchanged.")
    XCTAssertTrue(app.staticTexts["scan-phase"].waitForNonExistence(timeout: 8))
    XCTAssertEqual(app.staticTexts["scope-total"].value as? String, total)
    disclosure("Caches").click()
    XCTAssertTrue(row("cache 01.db").waitForExistence(timeout: 8))
    XCTAssertFalse(row("new cache.db").exists)
    screenshot("refresh-stopped")
    app.buttons["refresh"].click()
    text(
      "outcome", contains: "Refreshed “Library” in memory. Saved snapshot unchanged.", timeout: 20)
    XCTAssertNotEqual(app.staticTexts["scope-total"].value as? String, total)
    disclosure("Caches").click()
    XCTAssertTrue(row("new cache.db").waitForExistence(timeout: 8))
    screenshot("refresh-complete")
  }
  /// Frame sampling across repeated map clicks: the fixture-only `map-selection-gaps` probe
  /// records every drawn map frame. No frame may lose the selection dim between the old
  /// selection and the new one (the click flicker).
  func testRepeatedMapClicksNeverDrawAFrameWithoutTheSelectionDim() throws {
    launch("prototype-home", appearance: "dark")
    let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "map-file-"))
    XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 8))
    let probe = app.descendants(matching: .any)["map-selection-gaps"]
    XCTAssertTrue(probe.waitForExistence(timeout: 8), "frame sampler")
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
}
