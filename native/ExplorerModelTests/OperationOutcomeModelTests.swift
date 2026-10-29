import XCTest

@testable import DiskInventory

/// Operation outcomes, totals and selection state of the failure and Trash fixtures, checked on
/// the model that the banner, header and card show. The UI tests keep only the real input.
@MainActor final class OperationOutcomeModelTests: XCTestCase {
  func load(_ scenario: String) async throws -> ExplorerModel {
    let model = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", scenario], environment: [:])
    try await waitUntil { model.records != nil && !model.loading && !model.replacingSession }
    return model
  }
  func entry(_ name: String, in model: ExplorerModel) throws -> EntryRecord {
    try XCTUnwrap(model.outline?.rows.first { $0.entry.displayName == name }?.entry, name)
  }
  func shows(_ name: String, in model: ExplorerModel) -> Bool {
    model.outline?.rows.contains { $0.entry.displayName == name } == true
  }
  /// Selects `target`, confirms `action` and waits until the view is current again.
  func run(_ action: ActionKind, on target: String, in model: ExplorerModel) async throws {
    model.select(try entry(target, in: model))
    try await waitUntil { model.canAct }
    model.prepare(action)
    try await waitUntil { model.pending != nil }
    model.execute()
    try await waitUntil { !model.working && !model.loading }
  }

  func testFailedIndeterminatePartialAndUnknownScopeOutcomes() async throws {
    for (scenario, target, action, expected) in [
      ("trash-failure", "large-file", ActionKind.trash, "Failed"),
      ("trash-unknown", "large-file", .trash, "Moved to Trash."),
      ("trash-missing", "large-file", .trash, "Indeterminate"),
      ("permission-failure", "large-file", .permanentlyDelete, "Failed"),
      ("partial-deletion", "small-files", .permanentlyDelete, "Partial"),
    ] {
      let model = try await load(scenario)
      defer { model.shutdown() }
      try await run(action, on: target, in: model)
      let outcome = model.outcome ?? ""
      XCTAssertTrue(outcome.contains(expected), "\(scenario): \(outcome)")
      if scenario == "trash-unknown" {
        // The unknown Trash scope is a core issue in Details, not a banner sentence.
        XCTAssertEqual(outcome, expected)
        XCTAssertTrue(model.records?.status.stale == true, "Incomplete badge")
        XCTAssertTrue(
          model.issues.contains { $0.contains("Trash destination scope is unknown") },
          "\(model.issues)")
      }
      if scenario == "partial-deletion" {
        XCTAssertTrue(shows("small-files", in: model), "the survivor stays")
        XCTAssertTrue(model.records?.status.stale == true, "Incomplete badge")
      }
    }
  }

  func testSelectionUsesSavedDataWhenLiveMetadataFails() async throws {
    let model = try await load("metadata-failure")
    defer { model.shutdown() }
    model.select(try entry("large-file", in: model))
    try await waitUntil { model.selectedDisplayPath?.contains("large-file") == true }
    XCTAssertEqual(model.selected?.displayName, "large-file")
    XCTAssertTrue(model.canAct, "Delete stays available")
    XCTAssertNil(model.error)
  }

  func testTrashInsideKeepsTheTotalAndTrashOutsideLowersIt() async throws {
    for scenario in ["trash-inside", "trash-outside"] {
      let model = try await load(scenario)
      defer { model.shutdown() }
      let before = try XCTUnwrap(model.records?.status.root.subtreeBytes)
      try await run(.trash, on: "large-file", in: model)
      // The banner names the outcome only; the inventory totals show where the space went.
      XCTAssertEqual(model.outcome, "Moved to Trash.", scenario)
      XCTAssertFalse(
        ([model.outcome ?? ""] + model.issues).contains { $0.contains("this inventory") }, scenario)
      XCTAssertFalse(shows("large-file", in: model), scenario)
      let after = try XCTUnwrap(model.records?.status.root.subtreeBytes)
      if scenario == "trash-inside" {
        XCTAssertEqual(model.numbers.storage(after), model.numbers.storage(before))
        model.focus(try entry("trash", in: model).key)
        try await waitUntil { model.records?.focus.displayName == "trash" && !model.loading }
        XCTAssertTrue(shows("moved", in: model))
      } else {
        XCTAssertNotEqual(model.numbers.storage(after), model.numbers.storage(before))
      }
    }
  }

  func testChangedTargetFailsPreparationAndRefreshMarksUnknownAllocationIncomplete() async throws {
    let changed = try await load("changed-target")
    changed.select(try entry("large-file", in: changed))
    try await waitUntil { changed.canAct }
    changed.prepare(.permanentlyDelete)
    try await waitUntil { !changed.working }
    // The banner shows "Could not complete the request." for an error; no alert opens.
    XCTAssertTrue(changed.error?.hasPrefix("Preparation failed") == true, "\(changed.error ?? "")")
    XCTAssertNil(changed.pending)
    changed.shutdown()
    let model = try await load("unknown-allocation")
    defer { model.shutdown() }
    model.refresh()
    try await waitUntil { !model.working && !model.loading }
    XCTAssertTrue(model.records?.status.stale == true, "Incomplete badge")
    model.select(try entry("unknown-a", in: model))
    try await waitUntil { model.selectedDisplayPath?.contains("unknown-a") == true }
    XCTAssertEqual(model.selected?.displayName, "unknown-a")
  }

  /// A plain Delete plays the poof for at least four clock ticks: motion, not a jump.
  func testDeletePlaysThePoofForAtLeastFourTicks() async throws {
    let model = try await load("presentation")
    defer { model.shutdown() }
    model.select(try entry("large-file", in: model))
    try await waitUntil { model.selectedRegion != nil }
    model.prepare(.permanentlyDelete)
    try await waitUntil { model.pending != nil }
    model.execute()
    try await waitUntil { !model.working }
    XCTAssertEqual(model.outcome, "Deleted.")
    XCTAssertTrue(model.records?.status.dirty == true, "Not saved badge")
    XCTAssertEqual(model.motion.lastStyle, .poof)
    XCTAssertGreaterThanOrEqual(model.motion.lastTicks, 4)
  }
}
