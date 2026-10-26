import XCTest

@testable import DiskInventory

@MainActor final class ExplorerModelTests: XCTestCase {
  func waitUntil(_ predicate: @escaping () -> Bool) async throws {
    for _ in 0..<1000 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for real bridge work")
  }
  func model(_ scenario: String) async throws -> ExplorerModel {
    let model = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", scenario], environment: [:])
    try await waitUntil { model.records != nil && !model.loading }
    return model
  }
  func entry(_ name: String, _ model: ExplorerModel) throws -> EntryRecord {
    try XCTUnwrap(model.records?.page.entries.first { $0.displayName == name })
  }
  func testImmediateSelectionWhileRustBusyDiscardsObsoleteMetadata() async throws {
    let model = try await model("metadata-delay")
    model.select(try entry("large-file", model))
    try await waitUntil { model.session?.isBusy() == true }
    let start = ContinuousClock.now
    model.select(try entry("zero-byte", model))
    let elapsed = start.duration(to: .now)
    XCTAssertEqual(model.selected?.displayName, "zero-byte")
    XCTAssertNil(model.metadata)
    XCTAssertEqual(model.metadataState, "Loading live metadata…")
    XCTAssertTrue(model.session?.isBusy() == true)
    print("RESPONSIVENESS main-actor select+property publication while Rust busy: \(elapsed)")
    XCTAssertLessThan(elapsed, .milliseconds(100))
    // Poll throughout both real calls, not just their final value: old data must never publish.
    for _ in 0..<180 {
      if let metadata = model.metadata { XCTAssertEqual(metadata.logicalBytes, 17) }
      XCTAssertEqual(model.selected?.displayName, "zero-byte")
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(model.metadata?.logicalBytes, 17)
  }
  func testSessionReplacementDiscardsOldMetadataAndViews() async throws {
    let model = try await model("metadata-delay")
    model.select(try entry("large-file", model))
    try await waitUntil { model.session?.isBusy() == true }
    model.load { try ExplorerSession.fixture(scenario: "ordinary") }
    try await waitUntil {
      !model.loading && model.records?.status.root.subtreeBytes ?? 0 > (1 << 53)
    }
    try await Task.sleep(for: .milliseconds(1200))
    XCTAssertNil(model.selected)
    XCTAssertNil(model.metadata)
    XCTAssertGreaterThan(model.records!.status.root.subtreeBytes, 1 << 53)
  }
  func testCancelPendingPreparationAndRootProtection() async throws {
    let model = try await model("metadata-delay")
    model.select(try entry("large-file", model))
    model.prepare(.trash)
    model.cancelConfirmation()
    try await Task.sleep(for: .milliseconds(2400))
    XCTAssertNil(model.pending)
    XCTAssertFalse(model.working)
    model.select(model.records!.status.root)
    XCTAssertFalse(model.canAct)
    model.prepare(.permanentlyDelete)
    XCTAssertNil(model.pending)
  }
  func testFixtureModeRejectsAbsentAndUnknownConfiguration() async throws {
    let missing = ExplorerModel(arguments: [], environment: ["DI_UI_TEST": "1"])
    XCTAssertTrue(missing.fixtureMode)
    XCTAssertNil(missing.session)
    XCTAssertNotNil(missing.error)
    let unknown = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", "no-such-fixture"], environment: [:])
    try await waitUntil { !unknown.loading }
    XCTAssertNil(unknown.session)
    XCTAssertNotNil(unknown.error)
  }
  func testStaleFocusRecoversAndRollupIsNotAnActionTarget() async throws {
    let model = try await model("presentation")
    let target = try entry("small-files", model)
    model.select(target)
    model.prepare(.permanentlyDelete)
    try await waitUntil { model.pending != nil }
    model.execute()
    try await waitUntil { !model.working && model.pending == nil }
    XCTAssertFalse(model.records!.page.entries.contains { $0.displayName == "small-files" })
    model.focus(target.key)
    try await waitUntil { model.outcome?.contains("known live ancestor") == true && !model.loading }
    XCTAssertNil(model.records!.focus.parent)
    let rollup = try XCTUnwrap(
      model.records!.layout.tiles.first {
        if case .rollup = $0.kind { return true }
        return false
      })
    if case .rollup(let directory, let count) = rollup.kind {
      model.selectRollup(directory, count: count)
      XCTAssertNil(model.selected)
      XCTAssertFalse(model.canAct)
      XCTAssertNotNil(model.rollupText)
    }
  }

  func testLaterFocusWinsWhileBridgeIsBusy() async throws {
    let model = try await model("metadata-delay")
    let root = model.records!.status.root.key
    let directory = try entry("small-files", model).key
    model.select(try entry("large-file", model))
    try await waitUntil { model.session?.isBusy() == true }
    model.focus(directory)
    model.focus(root)
    try await waitUntil { !model.loading }
    XCTAssertTrue(model.records!.focus.key.sameEntry(other: root))
    try await Task.sleep(for: .milliseconds(1200))
    XCTAssertTrue(model.records!.focus.key.sameEntry(other: root))
    XCTAssertNil(model.metadata)
  }

  func testReplacementBlocksRetainedViewActionsUntilInstallation() async throws {
    let model = try await model("presentation")
    let oldSession = try XCTUnwrap(model.session)
    let oldRoot = model.records!.status.root.key
    let oldTarget = try entry("large-file", model)
    let oldTotal = model.records!.status.root.subtreeBytes
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    model.load {
      gate.wait()
      return try ExplorerSession.fixture(scenario: "ordinary")
    }
    // Reproduce the independent old-view update that clears shared view loading.
    await model.updateView(focus: oldRoot)
    model.select(oldTarget)
    XCTAssertFalse(model.canAct, "Old view completion must not enable actions during replacement")
    let attempted = model.prepare(.permanentlyDelete)
    XCTAssertNil(attempted)
    await attempted?.value
    gate.signal()
    try await waitUntil { model.session !== oldSession && model.records != nil && !model.loading }
    XCTAssertNil(model.pending, "An old confirmation must not survive session installation")
    model.execute()
    let retainedTotal = try await Task.detached { try oldSession.status().root.subtreeBytes }.value
    XCTAssertEqual(retainedTotal, oldTotal)
    XCTAssertGreaterThan(model.records!.status.root.subtreeBytes, 1 << 53)
    XCTAssertNil(model.error)
  }

  func testReplacementCancelsPreparedPinBeforeInstallingNewSession() async throws {
    let model = try await model("presentation")
    let oldSession = try XCTUnwrap(model.session)
    model.select(try entry("large-file", model))
    await model.prepare(.trash)?.value
    let action = try XCTUnwrap(model.pending?.action)
    model.load { try ExplorerSession.fixture(scenario: "ordinary") }
    try await waitUntil { model.session !== oldSession && model.records != nil && !model.loading }
    XCTAssertNil(model.pending)
    // A retained real capability must already be consumed by cancellation, not just hidden in Swift.
    let result = await Task.detached { Result { try oldSession.execute(action: action) } }.value
    guard case .failure(BridgeError.ConsumedAction) = result else {
      return XCTFail("The old prepared pin was not cancelled: \(result)")
    }
    let status = try await Task.detached { try oldSession.status() }.value
    XCTAssertFalse(status.dirty)
  }

  func testStalePreparationCompletionCannotPublishAfterReplacement() async throws {
    let model = try await model("metadata-delay")
    let oldSession = try XCTUnwrap(model.session)
    // Assign a real saved row without starting inspector metadata: isBusy below belongs to prepare.
    model.selected = try entry("large-file", model)
    let preparation = try XCTUnwrap(model.prepare(.trash))
    try await waitUntil { oldSession.isBusy() }
    model.load { try ExplorerSession.fixture(scenario: "ordinary") }
    try await waitUntil { model.session !== oldSession && model.records != nil && !model.loading }
    await preparation.value
    XCTAssertNil(model.pending)
    XCTAssertFalse(model.working)
    let status = try await Task.detached { try oldSession.status() }.value
    XCTAssertFalse(status.dirty)
    XCTAssertGreaterThan(model.records!.status.root.subtreeBytes, 1 << 53)
  }

  func testSuspendedRecoveryDoesNotOverwriteLaterNavigation() async throws {
    let model = try await model("metadata-delay")
    let session = try XCTUnwrap(model.session)
    let directory = try entry("small-files", model).key
    model.select(try entry("large-file", model))
    try await waitUntil { session.isBusy() }
    // Recovery clears selection synchronously, then blocks behind the real delayed metadata call.
    let recovery = Task { await model.recoverView(session) }
    try await waitUntil { model.selected == nil }
    model.focus(directory)
    await recovery.value
    try await waitUntil { !model.loading }
    XCTAssertTrue(model.records!.focus.key.sameEntry(other: directory))
  }

}
