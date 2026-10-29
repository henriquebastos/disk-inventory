import AppKit
import XCTest

@testable import DiskInventory

/// Dogfood feedback: the status bar hover, the Trash region, Esc, the outcome banner, refresh progress and Stop,
/// and the selection region that caused the click flicker.
@MainActor final class FeedbackModelTests: XCTestCase {
  func load(_ scenario: String) async throws -> ExplorerModel {
    let model = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", scenario], environment: [:])
    try await waitUntil { model.records != nil && !model.loading && !model.replacingSession }
    return model
  }
  func row(_ model: ExplorerModel, _ name: String) throws -> OutlineRow {
    try XCTUnwrap(model.outline?.rows.first { $0.entry.displayName == name }, name)
  }

  func testSelectionRegionNeverClearsWhileTheNextRegionLoads() async throws {
    let model = try await load("presentation")
    model.select(try row(model, "large-file").entry)
    try await waitUntil { model.selection.region != nil }
    let first = try XCTUnwrap(model.selection.region)
    // A tree selection keeps the shown region until the new one arrives: no frame without dim.
    model.select(try row(model, "small-files").entry)
    XCTAssertEqual(model.selection.region?.x, first.x)
    XCTAssertEqual(model.selection.region?.width, first.width)
    try await waitUntil { model.selection.region.map { $0.width != first.width } == true }
    // A map click publishes the clicked tile's rectangle with the selection, synchronously.
    let frame = try XCTUnwrap(model.picture?.frame)
    let hit = try XCTUnwrap(try frame.hit(x: UInt32(first.x + 2), y: UInt32(first.y + 2)))
    model.select(hit.entry, region: hit.rect)
    XCTAssertEqual(model.selection.region?.x, hit.rect.x)
    XCTAssertEqual(model.selection.region?.height, hit.rect.height)
    XCTAssertEqual(model.selection.entry?.displayName, "large-file")
  }

  func testStatusTextNamesTheHoveredBlockWhileAnotherItemIsSelected() async throws {
    let model = try await load("prototype-home")
    let session = try XCTUnwrap(model.session)
    model.select(try row(model, "Movies").entry)
    try await waitUntil { model.selectedDisplayPath == "/Users/ana/Movies" }
    XCTAssertEqual(model.statusText, "", "no hover: the status bar is empty")
    let frame = try XCTUnwrap(model.picture?.frame)
    let (builds, picture) = (model.diagramBuilds, model.picture)
    let queries = session.selectionQueryCount()
    let trash = try XCTUnwrap(try frame.region(key: try row(model, ".Trash").entry.key))
    model.point(UInt32(trash.x + trash.width / 2), UInt32(trash.y + trash.height / 2))
    try await waitUntil { model.hover?.entry.displayName == ".Trash" }
    XCTAssertEqual(model.statusText, "/Users/ana/.Trash")
    let target = try XCTUnwrap(model.picture?.targets.first { $0.entry.kind == .file })
    model.point(UInt32(target.rect.x + 2), UInt32(target.rect.y + 2))
    try await waitUntil { model.hover?.entry.key.sameEntry(other: target.entry.key) == true }
    XCTAssertEqual(model.statusText, "/Users/ana/" + displayPath(target.relativePath))
    // The selection, its path, the picture and the session stay: a hover is not a selection.
    XCTAssertEqual(model.selection.entry?.displayName, "Movies")
    XCTAssertEqual(model.selectedDisplayPath, "/Users/ana/Movies")
    XCTAssertEqual(model.diagramBuilds, builds)
    XCTAssertTrue(model.picture?.frame === picture?.frame)
    XCTAssertEqual(session.selectionQueryCount(), queries, "no selection query on hover")
    // A grouped block names its folder.
    model.hover = DiagramSelection(
      entry: target.entry, relativePath: Data("Library".utf8), actionable: false,
      rect: target.rect, bytes: 1)
    XCTAssertEqual(model.statusText, "Grouped in /Users/ana/Library")
    model.clearHover()
    XCTAssertEqual(model.statusText, "", "pointer off the map")
  }

  func testTrashRegionSelectsTheTrashDirectory() async throws {
    let model = try await load("prototype-home")
    let trash = try row(model, ".Trash").entry
    let frame = try XCTUnwrap(model.picture?.frame)
    let region = try XCTUnwrap(try frame.region(key: trash.key))
    for (fx, fy) in [(0.2, 0.3), (0.5, 0.5), (0.8, 0.7)] {
      model.point(
        UInt32(region.x + region.width * fx), UInt32(region.y + region.height * fy), click: true)
      try await waitUntil { model.selection.entry?.displayName == ".Trash" }
      XCTAssertNil(model.selection.aggregate, "the Trash region is not an aggregate")
      model.clearSelection()
    }
    // A double click focuses the Trash, which then draws its files normally.
    model.point(
      UInt32(region.x + region.width / 2), UInt32(region.y + region.height / 2),
      click: true, doubleClick: true)
    try await waitUntil { model.records?.focus.displayName == ".Trash" && !model.loading }
    let inside = try XCTUnwrap(model.picture?.frame)
    let clip = try XCTUnwrap(try inside.hit(x: 4, y: 4))
    XCTAssertTrue(clip.actionable)
    XCTAssertTrue(clip.entry.displayName.hasPrefix("Old clip"))
  }

  func testClearSelectionResetsItemRegionCardAndRowOnly() async throws {
    let model = try await load("presentation")
    model.select(try row(model, "large-file").entry)
    try await waitUntil { model.selection.region != nil && model.selection.path == "large-file" }
    let (focus, builds, tree) = (model.records?.focus.key, model.diagramBuilds, model.tree)
    XCTAssertTrue(model.canClearSelection)
    model.clearSelection()
    XCTAssertNil(model.selection.entry)
    XCTAssertNil(model.selection.region)
    XCTAssertNil(model.selection.row)
    XCTAssertNil(model.selection.path)
    XCTAssertNil(model.selectedDisplayPath)
    XCTAssertFalse(model.canClearSelection)
    try await Task.sleep(for: .milliseconds(300))
    // A late path or region answer for the old selection does not come back.
    XCTAssertNil(model.selection.region)
    XCTAssertNil(model.selection.path)
    XCTAssertTrue(model.records?.focus.key.sameEntry(other: try XCTUnwrap(focus)) == true)
    XCTAssertEqual(model.diagramBuilds, builds)
    XCTAssertTrue(model.tree === tree)
    // A grouped block selection clears too.
    model.selectAggregate(try XCTUnwrap(focus), bytes: 64)
    XCTAssertTrue(model.canClearSelection)
    model.clearSelection()
    XCTAssertNil(model.selection.aggregate)
    XCTAssertNil(model.selection.aggregateText)
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
    try await waitUntil { model.records?.focus.displayName == "Library" && !model.loading }
    let (picture, tree, builds) = (model.picture?.frame, model.tree, model.diagramBuilds)
    let total = model.records?.focus.subtreeBytes
    XCTAssertTrue(ExplorerCommand.refreshDirectory.isEnabled(in: model))
    ExplorerCommand.refreshDirectory.perform(in: model)
    XCTAssertTrue(model.working)
    XCTAssertEqual(model.scan.label, "Refreshing “Library”…")
    // The 300 ms fixture latency per directory gives a live counter.
    try await waitUntil { (model.scan.progress?.itemsExamined ?? 0) > 0 }
    let first = try XCTUnwrap(model.scan.progress?.itemsExamined)
    try await waitUntil { (model.scan.progress?.itemsExamined ?? 0) > first }
    XCTAssertTrue(ExplorerCommand.stopScan.isEnabled(in: model))
    ExplorerCommand.stopScan.perform(in: model)
    try await waitUntil { !model.working }
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
    try await waitUntil { model.records?.focus.displayName == "Library" && !model.loading }
    model.select(try row(model, "Caches").entry)
    try await waitUntil { model.selection.region != nil }
    let total = try XCTUnwrap(model.records?.focus.subtreeBytes)
    let builds = model.diagramBuilds
    model.refresh()
    try await waitUntil({ !model.working && !model.loading }, seconds: 20)
    XCTAssertEqual(model.outcome, "Refreshed “Library”.")
    XCTAssertEqual(model.records?.focus.subtreeBytes, total + 2_000_000_000)
    XCTAssertEqual(model.diagramBuilds, builds + 1)
    XCTAssertNil(model.scan.progress)
    XCTAssertFalse(model.scan.polling)
  }

  /// Waits, off the main actor, until the paused fixture holds an operation; returns the stage.
  func held(_ session: ExplorerSession) async throws -> String {
    try await Task.detached { try session.waitForHeldFixtureStage() }.value
  }
  func contains(_ model: ExplorerModel, _ name: String) -> Bool {
    model.outline?.rows.contains { $0.entry.displayName == name } == true
  }
  /// Prepares `kind` for Library in `operation-paused` and returns at the confirmation.
  func confirmLibrary(_ kind: ActionKind) async throws -> (ExplorerModel, ExplorerSession) {
    let model = try await load("operation-paused")
    let session = try XCTUnwrap(model.session)
    model.select(try row(model, "Library").entry)
    let preparation = try XCTUnwrap(model.prepare(kind))
    // The check runs before the alert, and the bar names it.
    XCTAssertEqual(model.checking, "Library")
    XCTAssertTrue(model.working)
    let stage = try await held(session)
    XCTAssertEqual(stage, "check")
    XCTAssertNil(model.pending)
    try session.releaseFixtureStage()
    await preparation.value
    XCTAssertNil(model.checking)
    XCTAssertNotNil(model.pending)
    return (model, session)
  }

  func testDeleteNamesEachPhaseCountsRemovedItemsAndOffersStop() async throws {
    let (model, session) = try await confirmLibrary(.permanentlyDelete)
    let execution = try XCTUnwrap(model.execute())
    var stage = try await held(session)
    XCTAssertEqual(stage, "check")
    model.scan.sample()
    XCTAssertEqual(model.scan.label, "Checking “Library”…")
    XCTAssertNil(model.scan.itemsText(model.numbers))
    XCTAssertTrue(model.scan.offersStop)
    XCTAssertTrue(ExplorerCommand.stopScan.isEnabled(in: model))
    try session.releaseFixtureStage()
    stage = try await held(session)
    XCTAssertEqual(stage, "remove")
    model.scan.sample()
    XCTAssertEqual(model.scan.label, "Deleting “Library”…")
    XCTAssertEqual(model.scan.itemsText(model.numbers), "5 items")
    XCTAssertTrue(ExplorerCommand.stopScan.isEnabled(in: model))
    try session.releaseFixtureStage()
    stage = try await held(session)
    XCTAssertEqual(stage, "update")
    model.scan.sample()
    XCTAssertEqual(model.scan.label, "Updating view…")
    XCTAssertNil(model.scan.itemsText(model.numbers))
    XCTAssertFalse(ExplorerCommand.stopScan.isEnabled(in: model), "the deletion is done")
    try session.releaseFixtureStage()
    await execution.value
    XCTAssertEqual(model.outcome, "Deleted.")
    XCTAssertFalse(model.working)
    XCTAssertNil(model.scan.progress)
    XCTAssertFalse(contains(model, "Library"))
  }

  func testStopDuringDeleteSaysHowManyWereDeletedAndStopBeforeChangesNothing() async throws {
    var (model, session) = try await confirmLibrary(.permanentlyDelete)
    var execution = try XCTUnwrap(model.execute())
    var stage = try await held(session)
    XCTAssertEqual(stage, "check")
    try session.releaseFixtureStage()
    stage = try await held(session)
    XCTAssertEqual(stage, "remove")
    ExplorerCommand.stopScan.perform(in: model)
    XCTAssertEqual(model.scan.label, "Stopping…")
    try session.releaseFixtureStage()
    stage = try await held(session)
    XCTAssertEqual(stage, "update")
    try session.releaseFixtureStage()
    await execution.value
    XCTAssertEqual(model.outcome, "Deletion stopped. 5 items deleted.")
    XCTAssertTrue(contains(model, "Library"), "the survivors stay")
    XCTAssertNil(model.error)
    // Stop during the check before deletion: nothing changes, so the view is not rebuilt.
    (model, session) = try await confirmLibrary(.permanentlyDelete)
    let (frame, builds) = (model.picture?.frame, model.diagramBuilds)
    let total = model.records?.focus.subtreeBytes
    execution = try XCTUnwrap(model.execute())
    stage = try await held(session)
    XCTAssertEqual(stage, "check")
    ExplorerCommand.stopScan.perform(in: model)
    try session.releaseFixtureStage()
    await execution.value
    XCTAssertEqual(model.outcome, "Deletion of “Library” stopped. Nothing was deleted.")
    XCTAssertTrue(model.picture?.frame === frame)
    XCTAssertEqual(model.diagramBuilds, builds)
    XCTAssertEqual(model.records?.focus.subtreeBytes, total)
    XCTAssertFalse(model.records?.status.dirty ?? true)
  }

  func testTrashNamesItsPhasesAndOffersNoStop() async throws {
    let (model, session) = try await confirmLibrary(.trash)
    let execution = try XCTUnwrap(model.execute())
    for stage in ["check", "trash"] {
      let held = try await held(session)
      XCTAssertEqual(held, stage)
      model.scan.sample()
      XCTAssertEqual(model.scan.label, "Moving “Library” to the Trash…")
      XCTAssertNil(model.scan.itemsText(model.numbers))
      XCTAssertFalse(model.scan.offersStop)
      XCTAssertFalse(ExplorerCommand.stopScan.isEnabled(in: model))
      try session.releaseFixtureStage()
    }
    let stage = try await held(session)
    XCTAssertEqual(stage, "update")
    model.scan.sample()
    XCTAssertEqual(model.scan.label, "Updating view…")
    try session.releaseFixtureStage()
    await execution.value
    XCTAssertEqual(model.outcome, "Moved to Trash.")
    XCTAssertFalse(contains(model, "Library"))
  }

  func testSkippedItemsReadAsDeletedWithACountAndReasonsInDetails() async throws {
    let model = try await load("operation-skip")
    model.select(try row(model, "Library").entry)
    await model.prepare(.permanentlyDelete)?.value
    await model.execute()?.value
    XCTAssertEqual(model.outcome, "Deleted. 3 items skipped.")
    XCTAssertEqual(
      model.issues,
      [
        "Skipped /Users/ana/Library/Caches/cache 01.db: permission denied",
        "Skipped /Users/ana/Library/Caches/cache 02.cache: not permitted, for example locked",
        "Skipped /Users/ana/Library/Containers/container 01.sqlite: permission denied",
      ])
    XCTAssertTrue(model.bannerVisible)
    XCTAssertTrue(contains(model, "Library"), "the folders of skipped items stay")
    XCTAssertTrue(contains(model, "Movies"), "the other rows stay")
    XCTAssertNil(model.error)
  }
}
