import XCTest

@MainActor final class ExplorerUITests: XCTestCase {
  var app: XCUIApplication!
  override func setUpWithError() throws { continueAfterFailure = false }
  func launch(_ scenario: String = "presentation", minimumWindow: Bool = false) {
    app = XCUIApplication()
    app.launchArguments = ["--fixture-mode", "--scenario", scenario, "-AppleLocale", "en_US"]
    if minimumWindow { app.launchArguments.append("--minimum-window") }
    app.launchEnvironment["DI_UI_TEST"] = "1"
    app.launch()
    XCTAssertTrue(app.staticTexts["simulated"].waitForExistence(timeout: 15))
  }
  func row(_ name: String) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "identifier == %@", "entry-\(name)")).firstMatch
  }
  func text(_ id: String, contains value: String, timeout: TimeInterval = 8) {
    let element = app.staticTexts[id]
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
    XCTAssertTrue(app.staticTexts["simulated"].exists)
    row(target).click()
    app.buttons[action].click()
    XCTAssertTrue(app.staticTexts["confirmation-simulated"].waitForExistence(timeout: 8))
    text("confirmation-path", contains: target)
  }
  func disclosure(_ name: String) -> XCUIElement {
    app.descendants(matching: .disclosureTriangle).matching(identifier: "disclosure-\(name)")
      .firstMatch
  }
  func testDisclosureKeyboardZoomBackAndUsage() throws {
    launch()
    row("small-files").click()
    disclosure("small-files").click()
    text("focus-name", contains: "Inventory root")
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
    app.buttons["back"].click()
    text("focus-name", contains: "Inventory root")
    XCTAssertTrue(row("small-00").waitForExistence(timeout: 8))
    text("selected-name", contains: "small-files")
    screenshot("restored-tree-context")
    app.outlines["entry-tree"].scroll(byDeltaX: 0, deltaY: -600)
    let scrollbar = app.scrollBars.firstMatch
    let before = try XCTUnwrap(Double(String(describing: try XCTUnwrap(scrollbar.value))))
    XCTAssertGreaterThan(before, 0.1)
    XCTAssertFalse(row("small-files").isHittable)
    screenshot("scrolled-tree-before-zoom")
    app.buttons["focus-selected"].click()
    text("focus-name", contains: "small-files")
    app.buttons["back"].click()
    text("focus-name", contains: "Inventory root")
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
    text("selected-usage", contains: "4,096 bytes")
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
      app.launch()
      XCTAssertTrue(app.staticTexts["fixture-locked"].waitForExistence(timeout: 8))
      XCTAssertFalse(app.buttons["open-snapshot"].isEnabled)
      XCTAssertFalse(app.buttons["create-inventory"].isEnabled)
      XCTAssertEqual(app.dialogs.count, 0)
      XCTAssertFalse(app.staticTexts["simulated"].exists)
      screenshot("fail-closed")
      app.terminate()
    }
  }
  func testDirectoryConfirmationsKeepOnlyTargetScopeAndWarnings() {
    launch()
    row("small-files").click()
    text("selected-usage", contains: "8,212 bytes")
    for action in ["trash", "delete"] {
      prepare(action, target: "small-files")
      text("confirmation-title", contains: "directory and its contents")
      text(
        "confirmation-warning",
        contains: action == "trash" ? "nothing will be permanently deleted" : "cannot be undone")
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
    text("focus-name", contains: "Inventory root")
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
    text("selected-usage", contains: "4,096 bytes")
    XCTAssertTrue(row("empty.txt").exists)
    screenshot("dix-tiny-zoom")
    app.buttons["back"].click()
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
    text("confirmation-title", contains: "directory and its contents")
    let details = app.windows.firstMatch
    let path = app.staticTexts["confirmation-path"]
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

}
