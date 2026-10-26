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
    try XCTUnwrap(model.outline?.rows.map(\.entry).first { $0.displayName == name })
  }
  func holdBridge(_ model: ExplorerModel) async throws -> Task<MetadataRecord, Error> {
    let session = try XCTUnwrap(model.session)
    let key = try entry("large-file", model).key
    let task = Task.detached { try session.liveMetadata(key: key) }
    try await waitUntil { session.isBusy() }
    return task
  }
  func testImmediateSelectionWhileRustBusyDiscardsObsoletePath() async throws {
    let model = try await model("metadata-delay")
    let blocker = try await holdBridge(model)
    model.select(try entry("large-file", model))
    let start = ContinuousClock.now
    model.select(try entry("zero-byte", model))
    let elapsed = start.duration(to: .now)
    XCTAssertEqual(model.selected?.displayName, "zero-byte")
    XCTAssertNil(model.selectionPath)
    XCTAssertTrue(model.session?.isBusy() == true)
    print("RESPONSIVENESS main-actor select+property publication while Rust busy: \(elapsed)")
    XCTAssertLessThan(elapsed, .milliseconds(100))
    for _ in 0..<180 {
      if let path = model.selectionPath { XCTAssertEqual(path, "zero-byte") }
      XCTAssertEqual(model.selected?.displayName, "zero-byte")
      try await Task.sleep(for: .milliseconds(10))
    }
    _ = try await blocker.value
    XCTAssertEqual(model.selectionPath, "zero-byte")
  }
  func testSelectionAndNavigationUseSavedDataWithoutLiveMetadata() async throws {
    let model = try await model("metadata-delay")
    let start = ContinuousClock.now
    model.select(try entry("large-file", model))
    try await waitUntil { model.selectionPath == "large-file" }
    let directory = try entry("small-files", model).key
    model.focus(directory)
    try await waitUntil { !model.loading }
    XCTAssertTrue(model.records!.focus.key.sameEntry(other: directory))
    let elapsed = start.duration(to: .now)
    // This real fixture sleeps one second for live metadata, but not indexed queries.
    XCTAssertLessThan(elapsed, .milliseconds(750))
    print("SAVED-ONLY selection path + directory publication: \(elapsed); not paint latency")
  }
  func testSessionReplacementDiscardsOldSelectionAndViews() async throws {
    let model = try await model("metadata-delay")
    let blocker = try await holdBridge(model)
    model.select(try entry("large-file", model))
    model.load { try ExplorerSession.fixture(scenario: "ordinary") }
    try await waitUntil {
      !model.loading && model.records?.status.root.subtreeBytes ?? 0 > (1 << 53)
    }
    _ = try await blocker.value
    try await Task.sleep(for: .milliseconds(1200))
    XCTAssertNil(model.selected)
    XCTAssertNil(model.selectionPath)
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
    XCTAssertFalse(model.outline!.rows.contains { $0.entry.displayName == "small-files" })
    model.focus(target.key)
    try await waitUntil { model.outcome?.contains("known live ancestor") == true && !model.loading }
    XCTAssertNil(model.records!.focus.parent)
    let session = model.session!
    let focus = model.records!.focus.key
    let layout = try await Task.detached {
      try session.layout(
        focus: focus,
        request: LayoutRequest(
          viewport: Rectangle(x: 0, y: 0, width: 100, height: 100), maxRectangles: 16, minArea: 20,
          maxDepth: 8))
    }.value
    let rollup = try XCTUnwrap(
      layout.tiles.first {
        if case .rollup = $0.kind { return true }
        return false
      })
    if case .rollup(let directory, _) = rollup.kind {
      model.selectAggregate(directory, bytes: rollup.bytes)
      XCTAssertNil(model.selected)
      XCTAssertFalse(model.canAct)
      XCTAssertNotNil(model.aggregateText)
    }
  }

  func testLaterFocusWinsWhileBridgeIsBusy() async throws {
    let model = try await model("metadata-delay")
    let root = model.records!.status.root.key
    let directory = try entry("small-files", model).key
    let blocker = try await holdBridge(model)
    model.focus(directory)
    model.focus(root)
    try await waitUntil { !model.loading }
    XCTAssertTrue(model.records!.focus.key.sameEntry(other: root))
    try await Task.sleep(for: .milliseconds(1200))
    XCTAssertTrue(model.records!.focus.key.sameEntry(other: root))
    _ = try await blocker.value
    XCTAssertNil(model.selectionPath)
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
    // isBusy below belongs to explicit preparation, not saved-data selection.
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
    let blocker = try await holdBridge(model)
    // Recovery clears selection synchronously, then blocks behind the real delayed metadata call.
    let recovery = Task { await model.recoverView(session) }
    try await waitUntil { model.selected == nil }
    model.focus(directory)
    await recovery.value
    _ = try await blocker.value
    try await waitUntil { !model.loading }
    XCTAssertTrue(model.records!.focus.key.sameEntry(other: directory))
  }

}
