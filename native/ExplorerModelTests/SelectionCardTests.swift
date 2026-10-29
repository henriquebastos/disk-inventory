import XCTest

@testable import DiskInventory

/// The selection card renders `ExplorerModel.selectionCard`; one test per card variant.
@MainActor final class SelectionCardTests: XCTestCase {
  /// A model of `scenario` that formats numbers for en_US.
  func fixture(_ scenario: String = "presentation") async throws -> ExplorerModel {
    try await fixtureModel(
      scenario, numbers: NativeNumberFormat(locale: Locale(identifier: "en_US")))
  }

  func testCardShowsNothingSelectedWithSelectInventoryRoot() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    XCTAssertEqual(model.selectionCard, .nothing(canSelectRoot: true))
    model.select(try entry("large-file", in: model))
    model.clearSelection()
    XCTAssertEqual(model.selectionCard, .nothing(canSelectRoot: true), "after Esc")
  }

  /// A file shows its accounted size and no item count; the path shows once it loads.
  func testCardShowsAFileWithItsSizeAndLoadedPath() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    model.select(try entry("large-file", in: model))
    let loading = SelectionCardItem(
      name: "large-file", size: "4.1 KB", count: nil, path: nil, rootProtected: false,
      canRevealInFinder: false, canMoveToTrash: true, canDelete: true)
    XCTAssertEqual(model.selectionCard, .item(loading))
    try await waitUntil { model.selection.path != nil }
    XCTAssertEqual(
      model.selectionCard,
      .item(
        SelectionCardItem(
          name: "large-file", size: "4.1 KB", count: nil, path: "/Workspace/large-file",
          rootProtected: false, canRevealInFinder: false, canMoveToTrash: true, canDelete: true)))
    // A pending preparation disables both removal buttons.
    model.perform(.command(.moveToTrash))
    guard case .item(let preparing) = model.selectionCard else {
      return XCTFail("\(model.selectionCard)")
    }
    XCTAssertFalse(preparing.canMoveToTrash)
    XCTAssertFalse(preparing.canDelete)
    try await waitUntil { model.pending != nil }
    model.cancelConfirmation()
  }

  /// A directory shows its subtree size, not its own allocation, and its direct item count.
  func testCardShowsADirectoryWithItsSubtreeSizeAndDirectItems() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    model.select(try entry("small-files", in: model))
    try await waitUntil { model.selection.path != nil }
    XCTAssertEqual(
      model.selectionCard,
      .item(
        SelectionCardItem(
          name: "small-files", size: "8.2 KB", count: "128 direct items",
          path: "/Workspace/small-files", rootProtected: false, canRevealInFinder: false,
          canMoveToTrash: true, canDelete: true)))
  }

  /// "long-path" holds one directory.
  func testCardNamesOneDirectItemInTheSingular() async throws {
    let model = try await fixture("visual-details")
    defer { model.shutdown() }
    model.select(try entry("long-path", in: model))
    guard case .item(let card) = model.selectionCard else {
      return XCTFail("\(model.selectionCard)")
    }
    XCTAssertEqual(card.count, "1 direct item")
  }

  func testCardShowsTheProtectedInventoryRoot() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    model.perform(.selectRoot)
    try await waitUntil { model.selection.path != nil }
    guard case .item(let root) = model.selectionCard else {
      return XCTFail("\(model.selectionCard)")
    }
    XCTAssertEqual(root.name, "Inventory root")
    XCTAssertEqual(root.path, "/Workspace")
    XCTAssertTrue(root.rootProtected)
    XCTAssertFalse(root.canMoveToTrash)
    XCTAssertFalse(root.canDelete)
  }

  /// A grouped map block shows its size; its button focuses the grouped directory.
  func testCardShowsAGroupedBlockSizeAndOpensItsDirectory() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    let directory = try entry("small-files", in: model)
    model.selectAggregate(directory.key, bytes: 1_234)
    XCTAssertEqual(model.selectionCard, .group(size: "1.2 KB"))
    model.perform(.showGroupedDirectory)
    try await waitUntil { !model.loading && model.records?.focus.displayName == "small-files" }
    XCTAssertEqual(model.selectionCard, .nothing(canSelectRoot: true))
  }

  /// A failed path lookup says so on the card and in its help tag, instead of "Loading path…"
  /// for good. An entry of another session makes the lookup fail.
  func testCardSaysThePathCouldNotBeReadWhenItsLookupFails() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    let other = try await fixture("ordinary")
    defer { other.shutdown() }
    model.select(try entry("large-file", in: other))
    await settled(model)
    guard case .item(let failed) = model.selectionCard else {
      return XCTFail("\(model.selectionCard)")
    }
    XCTAssertNil(failed.path)
    XCTAssertTrue(failed.pathUnavailable)
    XCTAssertEqual(failed.pathText, "Could not read this path.")
    XCTAssertEqual(failed.pathHelp, "Could not read this path.")
    // The next selection loads its path again.
    model.select(try entry("large-file", in: model))
    guard case .item(let loading) = model.selectionCard else {
      return XCTFail("\(model.selectionCard)")
    }
    XCTAssertEqual(loading.pathText, "Loading path…")
    XCTAssertEqual(loading.pathHelp, "")
    try await waitUntil { model.selection.path != nil }
    guard case .item(let loaded) = model.selectionCard else {
      return XCTFail("\(model.selectionCard)")
    }
    XCTAssertFalse(loaded.pathUnavailable)
    XCTAssertEqual(loaded.pathText, "/Workspace/large-file")
  }

  /// One clear drops every field of a selection: a Refresh and a new session also remove a
  /// selected grouped block from the card, as they remove a selected item.
  func testRefreshAndASessionLoadClearASelectedGroupedBlock() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    let directory = try entry("small-files", in: model)
    model.selectAggregate(directory.key, bytes: 4096)
    XCTAssertEqual(model.selectionCard, .group(size: "4.1 KB"))
    model.refresh()
    try await waitUntil { !model.working && !model.loading }
    XCTAssertEqual(model.selectionCard, .nothing(canSelectRoot: true), "after Refresh")
    XCTAssertNil(model.selection.aggregate)
    model.selectAggregate(directory.key, bytes: 4096)
    model.load { try ExplorerSession.fixture(scenario: "ordinary") }
    try await waitUntil { model.records != nil && !model.loading && !model.replacingSession }
    XCTAssertEqual(model.selectionCard, .nothing(canSelectRoot: true), "after a new session")
    XCTAssertNil(model.selection.aggregate)
  }
}
