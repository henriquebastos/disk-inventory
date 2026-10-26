import XCTest

@MainActor final class ExplorerUITests: XCTestCase {
  var app: XCUIApplication!
  override func setUpWithError() throws { continueAfterFailure = false }
  func launch(_ scenario: String = "presentation") {
    app = XCUIApplication()
    app.launchArguments = ["--fixture-mode", "--scenario", scenario, "-AppleLocale", "en_US"]
    app.launchEnvironment["DI_UI_TEST"] = "1"
    app.launch()
    XCTAssertTrue(app.staticTexts["simulated"].waitForExistence(timeout: 15))
  }
  func row(_ name: String) -> XCUIElement { app.staticTexts["entry-\(name)"] }
  func text(_ id: String, contains value: String, timeout: TimeInterval = 8) {
    let element = app.staticTexts[id]
    XCTAssertTrue(element.waitForExistence(timeout: timeout))
    let predicate = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", value, value)
    expectation(for: predicate, evaluatedWith: element)
    waitForExpectations(timeout: timeout)
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
  func testSelectionNavigationPaginationAndInspector() {
    launch()
    row("small-files").click()
    text("selected-name", contains: "small-files")
    text("focus-name", contains: "Inventory root")
    row("small-files").doubleClick()
    text("focus-name", contains: "small-files")
    text("page-range", contains: "of 128")
    app.buttons["next-page"].click()
    text("page-range", contains: "101–128")
    row("small-72").click()
    text("selected-name", contains: "small-72")
    app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
    text("selected-name", contains: "small-73")
    text("logical-size", contains: "81 bytes")
    screenshot("tiny-entry-inspector")
    app.buttons["breadcrumb-0"].click()
    text("focus-name", contains: "Inventory root")
    app.buttons["back"].click()
    text("focus-name", contains: "small-files")
    app.buttons["breadcrumb-0"].click()
    row("large-file").click()
    text("logical-size", contains: "4,113 bytes")
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
  func testFailuresPartialUnknownAndMetadataError() {
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
    text("metadata-state", contains: "unavailable")
    text("selected-name", contains: "large-file")
    screenshot("metadata-unavailable")
  }
  func testChangedTargetAndUnknownAllocation() {
    launch("changed-target")
    row("large-file").click()
    app.buttons["delete"].click()
    text("error", contains: "Preparation failed")
    XCTAssertFalse(app.buttons["confirm-action"].exists)
    app.terminate()
    launch("unknown-allocation")
    app.buttons["refresh"].click()
    XCTAssertTrue(app.staticTexts["stale"].waitForExistence(timeout: 8))
    XCTAssertTrue(row("unknown-a").exists)
    screenshot("unknown-allocation")
  }
  func testImmediateSelectionAndObsoleteMetadataDiscarded() {
    launch("metadata-delay")
    row("large-file").click()
    let start = Date()
    row("zero-byte").click()
    text("selected-name", contains: "zero-byte")
    let elapsed = Date().timeIntervalSince(start)
    print("RESPONSIVENESS XCUITest click+AX selected-name assertion: \(elapsed) seconds")
    text("logical-size", contains: "17 bytes")
    // The delayed old request completes first; its 4113-byte response must never replace this selection.
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
}
