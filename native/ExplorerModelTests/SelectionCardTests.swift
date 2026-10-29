import XCTest

@testable import DiskInventory

/// The selection card renders `ExplorerModel.selectionCard`; one test per card variant.
@MainActor final class SelectionCardTests: XCTestCase {
  func fixture() async throws -> ExplorerModel {
    let model = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", "presentation"], environment: [:],
      numbers: NativeNumberFormat(locale: Locale(identifier: "en_US")))
    try await waitUntil { model.records != nil && !model.loading && !model.replacingSession }
    return model
  }
  func entry(_ name: String, in model: ExplorerModel) throws -> EntryRecord {
    try XCTUnwrap(model.outline?.rows.first { $0.entry.displayName == name }?.entry)
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
    try await waitUntil { model.selectionPath != nil }
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
    try await waitUntil { model.selectionPath != nil }
    XCTAssertEqual(
      model.selectionCard,
      .item(
        SelectionCardItem(
          name: "small-files", size: "8.2 KB", count: "128 direct items",
          path: "/Workspace/small-files", rootProtected: false, canRevealInFinder: false,
          canMoveToTrash: true, canDelete: true)))
  }

  func testCardShowsTheProtectedInventoryRoot() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    model.perform(.selectRoot)
    try await waitUntil { model.selectionPath != nil }
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
}
