import XCTest

@testable import DiskInventory

/// The busy rules and intents of tree keys and map context menus in `ExplorerModel+Input.swift`.
@MainActor final class InputRulesTests: XCTestCase {
  let right: UInt16 = 124
  let left: UInt16 = 123
  let commandUp: UInt16 = 126
  let commandDown: UInt16 = 125
  let returnKey: UInt16 = 36

  func fixture() async throws -> ExplorerModel {
    let model = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", "presentation"], environment: [:])
    try await waitUntil { model.records != nil && !model.loading && !model.replacingSession }
    return model
  }
  func entry(_ name: String, in model: ExplorerModel) throws -> EntryRecord {
    try XCTUnwrap(model.outline?.rows.first { $0.entry.displayName == name }?.entry)
  }
  func row(_ name: String, in model: ExplorerModel) throws -> OutlineRow {
    try XCTUnwrap(model.outline?.rows.first { $0.entry.displayName == name })
  }
  /// Selects `name` as a tree click does and waits for its row.
  func select(_ name: String, in model: ExplorerModel) async throws {
    model.select(try entry(name, in: model))
    try await waitUntil { model.selectedRow != nil }
  }

  func testTreeArrowKeysExpandSelectTheFirstItemCollapseAndSelectTheParent() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    let directory = try entry("small-files", in: model)
    try await select("small-files", in: model)
    XCTAssertTrue(model.treeArrowKey(right))
    try await waitUntil { !model.treeEditing }
    XCTAssertTrue(try row("small-files", in: model).expanded)
    XCTAssertTrue(model.selected?.key.sameEntry(other: directory.key) == true)
    // Right on an expanded directory selects its first item.
    XCTAssertTrue(model.treeArrowKey(right))
    XCTAssertTrue(model.selected?.parent?.sameEntry(other: directory.key) == true)
    try await waitUntil { model.selectedRow != nil }
    // Left on an item that is not expanded selects its parent.
    XCTAssertTrue(model.treeArrowKey(left))
    try await waitUntil { model.selected?.key.sameEntry(other: directory.key) == true }
    try await waitUntil { model.selectedRow != nil }
    // Left on an expanded directory collapses it.
    XCTAssertTrue(model.treeArrowKey(left))
    try await waitUntil { !model.treeEditing }
    XCTAssertFalse(try row("small-files", in: model).expanded)
    // Right on a file is consumed and does nothing; other keys go to the table.
    try await select("large-file", in: model)
    XCTAssertTrue(model.treeArrowKey(right))
    XCTAssertFalse(model.treeEditing)
    XCTAssertEqual(model.selected?.displayName, "large-file")
    XCTAssertFalse(model.treeArrowKey(commandUp))
    // Without a selected row the table moves the selection itself.
    model.clearSelection()
    XCTAssertFalse(model.treeArrowKey(right))
  }

  func testTreeNavigationKeysFocusTheParentAndOpenTheSelectedDirectory() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    try await select("small-files", in: model)
    XCTAssertTrue(model.treeNavigationKey(commandDown))
    try await waitUntil { !model.loading && model.records?.focus.displayName == "small-files" }
    XCTAssertTrue(model.treeNavigationKey(commandUp))
    try await waitUntil { !model.loading && model.records?.focus.parent == nil }
    // Return on a file is consumed and keeps the focus.
    try await select("large-file", in: model)
    XCTAssertTrue(model.treeNavigationKey(returnKey))
    XCTAssertFalse(model.loading)
    XCTAssertNil(model.records?.focus.parent)
    XCTAssertFalse(model.treeNavigationKey(0))
  }

  /// While an operation runs or a confirmation is pending, tree keys are consumed and do
  /// nothing.
  func testTreeKeysAreConsumedWithoutActionWhileBusy() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    try await select("small-files", in: model)
    model.prepare(.trash)
    XCTAssertTrue(model.working)
    XCTAssertFalse(model.isIdle)
    for code in [right, left] { XCTAssertTrue(model.treeArrowKey(code)) }
    for code in [commandUp, commandDown, returnKey] { XCTAssertTrue(model.treeNavigationKey(code)) }
    XCTAssertFalse(model.treeEditing)
    XCTAssertFalse(model.loading)
    try await waitUntil { model.pending != nil }
    XCTAssertTrue(model.treeArrowKey(right))
    XCTAssertTrue(model.treeNavigationKey(commandDown))
    XCTAssertFalse(model.treeEditing)
    XCTAssertFalse(model.loading)
    XCTAssertNil(model.records?.focus.parent)
    model.cancelConfirmation()
    XCTAssertTrue(model.isIdle)
  }

  /// Visible disclosures follow the tree rule; new cells and `expand` ignore a pending
  /// confirmation, and only an expansion in flight blocks them.
  func testTreeInputRulesDifferForVisibleAndNewDisclosures() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    XCTAssertTrue(model.treeInteractive)
    XCTAssertTrue(model.visibleDisclosuresEnabled)
    XCTAssertTrue(model.canExpandRows)
    try await select("large-file", in: model)
    model.prepare(.trash)
    try await waitUntil { model.pending != nil }
    XCTAssertFalse(model.treeInteractive)
    XCTAssertFalse(model.visibleDisclosuresEnabled)
    XCTAssertTrue(model.canExpandRows)
    model.cancelConfirmation()
    model.expand(try entry("small-files", in: model), expanded: true)
    XCTAssertTrue(model.treeEditing)
    XCTAssertTrue(model.treeInteractive)
    XCTAssertFalse(model.visibleDisclosuresEnabled)
    XCTAssertFalse(model.canExpandRows)
    try await waitUntil { !model.treeEditing }
    XCTAssertTrue(model.canExpandRows)
  }

  func testMapContextMenuSelectsTheHoveredBlockOrItsGroup() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    XCTAssertFalse(model.selectHoveredBlockForContextMenu(), "no hover")
    let block = try XCTUnwrap(model.picture?.targets.first { $0.entry.displayName == "large-file" })
    model.hover = block
    XCTAssertTrue(model.selectHoveredBlockForContextMenu())
    XCTAssertEqual(model.selected?.displayName, "large-file")
    model.hover = DiagramSelection(
      entry: block.entry, relativePath: block.relativePath, actionable: false, rect: block.rect,
      bytes: 1234)
    XCTAssertTrue(model.selectHoveredBlockForContextMenu())
    XCTAssertNil(model.selected)
    XCTAssertTrue(model.aggregate?.sameEntry(other: block.entry.key) == true)
  }

  /// A pending confirmation blocks the map context menu but not pointer hits; a result motion
  /// blocks both.
  func testMapRulesDifferForAPendingConfirmationAndAResultMotion() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    let block = try XCTUnwrap(model.picture?.targets.first { $0.entry.displayName == "large-file" })
    XCTAssertTrue(model.acceptsMapPointer)
    XCTAssertTrue(model.canOpenMapContextMenu)
    model.select(block.entry)
    model.prepare(.trash)
    try await waitUntil { model.pending != nil }
    XCTAssertTrue(model.acceptsMapPointer)
    XCTAssertFalse(model.canOpenMapContextMenu)
    model.hover = block
    XCTAssertFalse(model.selectHoveredBlockForContextMenu())
    model.cancelConfirmation()
    model.hover = nil
    model.motion.hold(try XCTUnwrap(model.picture))
    XCTAssertFalse(model.acceptsMapPointer)
    XCTAssertFalse(model.canOpenMapContextMenu)
    // A hover during the motion is ignored.
    model.point(UInt32(block.rect.x + 1), UInt32(block.rect.y + 1))
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertNil(model.hover)
    model.motion.cancel()
    XCTAssertTrue(model.acceptsMapPointer)
  }
}
