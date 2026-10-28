import AppKit
import XCTest

@testable import DiskInventory

/// Dogfood feedback: the root Trash region, Esc, the outcome banner, refresh progress and Stop,
/// and the selection region that caused the click flicker.
@MainActor final class FeedbackModelTests: XCTestCase {
  func wait(
    _ condition: @escaping @MainActor () -> Bool, seconds: Int = 8,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(condition(), file: file, line: line)
  }
  func load(_ scenario: String) async throws -> ExplorerModel {
    let model = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", scenario], environment: [:])
    try await wait { model.records != nil && !model.loading && !model.replacingSession }
    return model
  }
  func row(_ model: ExplorerModel, _ name: String) throws -> OutlineRow {
    try XCTUnwrap(model.outline?.rows.first { $0.entry.displayName == name }, name)
  }

  func testSelectionRegionNeverClearsWhileTheNextRegionLoads() async throws {
    let model = try await load("presentation")
    model.select(try row(model, "large-file").entry)
    try await wait { model.selectedRegion != nil }
    let first = try XCTUnwrap(model.selectedRegion)
    // A tree selection keeps the shown region until the new one arrives: no frame without dim.
    model.select(try row(model, "small-files").entry)
    XCTAssertEqual(model.selectedRegion?.x, first.x)
    XCTAssertEqual(model.selectedRegion?.width, first.width)
    try await wait { model.selectedRegion.map { $0.width != first.width } == true }
    // A map click publishes the clicked tile's rectangle with the selection, synchronously.
    let frame = try XCTUnwrap(model.picture?.frame)
    let hit = try XCTUnwrap(try frame.hit(x: UInt32(first.x + 2), y: UInt32(first.y + 2)))
    model.select(hit.entry, region: hit.rect)
    XCTAssertEqual(model.selectedRegion?.x, hit.rect.x)
    XCTAssertEqual(model.selectedRegion?.height, hit.rect.height)
    XCTAssertEqual(model.selected?.displayName, "large-file")
  }

  func testTrashRegionSelectsTheTrashDirectory() async throws {
    let model = try await load("prototype-home")
    let trash = try row(model, ".Trash").entry
    let frame = try XCTUnwrap(model.picture?.frame)
    let region = try XCTUnwrap(try frame.region(key: trash.key))
    for (fx, fy) in [(0.2, 0.3), (0.5, 0.5), (0.8, 0.7)] {
      model.point(
        UInt32(region.x + region.width * fx), UInt32(region.y + region.height * fy), click: true)
      try await wait { model.selected?.displayName == ".Trash" }
      XCTAssertNil(model.aggregate, "the Trash region is not an aggregate")
      model.clearSelection()
    }
    // A double click focuses the Trash, which then draws its files normally.
    model.point(
      UInt32(region.x + region.width / 2), UInt32(region.y + region.height / 2),
      click: true, doubleClick: true)
    try await wait { model.records?.focus.displayName == ".Trash" && !model.loading }
    let inside = try XCTUnwrap(model.picture?.frame)
    let clip = try XCTUnwrap(try inside.hit(x: 4, y: 4))
    XCTAssertTrue(clip.actionable)
    XCTAssertTrue(clip.entry.displayName.hasPrefix("Old clip"))
  }

  func testClearSelectionResetsItemRegionCardAndRowOnly() async throws {
    let model = try await load("presentation")
    model.select(try row(model, "large-file").entry)
    try await wait { model.selectedRegion != nil && model.selectionPath == "large-file" }
    let (focus, builds, tree) = (model.records?.focus.key, model.diagramBuilds, model.tree)
    XCTAssertTrue(model.canClearSelection)
    model.clearSelection()
    XCTAssertNil(model.selected)
    XCTAssertNil(model.selectedRegion)
    XCTAssertNil(model.selectedRow)
    XCTAssertNil(model.selectionPath)
    XCTAssertNil(model.selectedDisplayPath)
    XCTAssertFalse(model.canClearSelection)
    try await Task.sleep(for: .milliseconds(300))
    // A late path or region answer for the old selection does not come back.
    XCTAssertNil(model.selectedRegion)
    XCTAssertNil(model.selectionPath)
    XCTAssertTrue(model.records?.focus.key.sameEntry(other: try XCTUnwrap(focus)) == true)
    XCTAssertEqual(model.diagramBuilds, builds)
    XCTAssertTrue(model.tree === tree)
    // A grouped block selection clears too.
    model.selectAggregate(try XCTUnwrap(focus), bytes: 64)
    XCTAssertTrue(model.canClearSelection)
    model.clearSelection()
    XCTAssertNil(model.aggregate)
    XCTAssertNil(model.aggregateText)
  }

  func testBannerDismissHidesOutcomeErrorAndSeenIssues() async throws {
    let model = try await load("presentation")
    XCTAssertFalse(model.bannerVisible)
    model.outcome = "Moved to Trash."
    model.issues = ["one issue"]
    XCTAssertTrue(model.bannerVisible)
    model.dismissBanner()
    XCTAssertFalse(model.bannerVisible)
    XCTAssertNil(model.outcome)
    XCTAssertEqual(model.issues, ["one issue"], "the issue log stays")
    model.issues.append("a new issue")
    XCTAssertTrue(model.bannerVisible, "a new issue shows the banner again")
    model.dismissBanner()
    model.error = "Operation failed"
    XCTAssertTrue(model.bannerVisible)
    model.dismissBanner()
    XCTAssertNil(model.error)
    XCTAssertFalse(model.bannerVisible)
  }

  func testControlledRefreshNamesTheFolderCountsAndStopKeepsTheView() async throws {
    let model = try await load("prototype-home-refresh")
    model.focus(try row(model, "Library").entry.key)
    try await wait { model.records?.focus.displayName == "Library" && !model.loading }
    let (picture, tree, builds) = (model.picture?.frame, model.tree, model.diagramBuilds)
    let total = model.records?.focus.subtreeBytes
    XCTAssertTrue(ExplorerCommand.refreshDirectory.isEnabled(in: model))
    ExplorerCommand.refreshDirectory.perform(in: model)
    XCTAssertTrue(model.working)
    XCTAssertEqual(model.scan.label, "Refreshing “Library”…")
    // The 300 ms fixture latency per directory gives a live counter.
    try await wait { (model.scan.progress?.itemsExamined ?? 0) > 0 }
    let first = try XCTUnwrap(model.scan.progress?.itemsExamined)
    try await wait { (model.scan.progress?.itemsExamined ?? 0) > first }
    XCTAssertTrue(ExplorerCommand.stopScan.isEnabled(in: model))
    ExplorerCommand.stopScan.perform(in: model)
    try await wait { !model.working }
    XCTAssertEqual(model.outcome, "Refresh of “Library” stopped. The previous data is unchanged.")
    XCTAssertNil(model.error)
    XCTAssertNil(model.scan.progress)
    // No data change, so no rebuild: the same picture, tree and total.
    XCTAssertTrue(model.picture?.frame === picture)
    XCTAssertTrue(model.tree === tree)
    XCTAssertEqual(model.diagramBuilds, builds)
    XCTAssertEqual(model.records?.focus.subtreeBytes, total)
    XCTAssertFalse(model.records?.status.dirty ?? true)
    XCTAssertNotNil(try picture?.hit(x: 4, y: 4), "the old frame stays valid")
  }

  func testControlledRefreshAppliesLiveChangesAndRebuilds() async throws {
    let model = try await load("prototype-home-refresh")
    model.focus(try row(model, "Library").entry.key)
    try await wait { model.records?.focus.displayName == "Library" && !model.loading }
    model.select(try row(model, "Caches").entry)
    try await wait { model.selectedRegion != nil }
    let total = try XCTUnwrap(model.records?.focus.subtreeBytes)
    let builds = model.diagramBuilds
    model.refresh()
    try await wait({ !model.working && !model.loading }, seconds: 20)
    XCTAssertEqual(model.outcome, "Refreshed “Library” in memory. Saved snapshot unchanged.")
    XCTAssertEqual(model.records?.focus.subtreeBytes, total + 2_000_000_000)
    XCTAssertEqual(model.diagramBuilds, builds + 1)
    XCTAssertNil(model.scan.progress)
    XCTAssertFalse(model.scan.polling)
  }
}
