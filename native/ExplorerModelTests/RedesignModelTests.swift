import AppKit
import SwiftUI
import XCTest

@testable import DiskInventory

@MainActor final class RedesignModelTests: XCTestCase {
  func wait(_ predicate: @escaping () -> Bool) async throws {
    for _ in 0..<1000 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for redesign state")
  }
  func ownedRoot() throws -> URL {
    let base = try XCTUnwrap(
      ProcessInfo.processInfo.environment["DI_TEST_ROOT"],
      "Tests require an explicit external artifact root")
    let url = URL(fileURLWithPath: base).resolvingSymlinksInPath().appendingPathComponent(
      "native-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let canonical = try XCTUnwrap(realpath(url.path, nil))
    defer { free(canonical) }
    return URL(fileURLWithPath: String(cString: canonical))
  }
  func fixture(_ scenario: String = "dix") async throws -> ExplorerModel {
    let model = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", scenario], environment: [:])
    try await wait { !model.loading && !model.replacingSession && model.records != nil }
    return model
  }
  func entry(_ name: String, in model: ExplorerModel) throws -> EntryRecord {
    try XCTUnwrap(model.outline?.rows.first { $0.entry.displayName == name }?.entry)
  }

  func testFullExplorerViewSettlesMapInputNavigationAndWindowResize() async throws {
    let model = try await fixture("dix")
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: ExplorerView(model: model))
    window.contentView = host
    defer {
      model.shutdown()
      window.close()
    }
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    func map(in view: NSView) -> DiagramView.MapView? {
      if let map = view as? DiagramView.MapView { return map }
      return view.subviews.compactMap { map(in: $0) }.first
    }
    let map = try XCTUnwrap(map(in: host))
    func assertSettled() async throws {
      try await wait {
        host.layoutSubtreeIfNeeded()
        let scale = window.backingScaleFactor
        return !model.loading && !model.replacingSession
          && model.picture?.bitmap.width == UInt32(map.bounds.width * scale)
          && model.picture?.bitmap.height == UInt32(map.bounds.height * scale)
      }
      let viewport = model.viewport
      let bounds = map.bounds
      let builds = model.diagramBuilds
      // Each sample exceeds the real 180 ms resize debounce. Busy chrome must not resize the map.
      for _ in 0..<3 {
        try await Task.sleep(for: .milliseconds(220))
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.viewport, viewport)
        XCTAssertEqual(map.bounds, bounds)
        XCTAssertEqual(model.diagramBuilds, builds)
      }
    }
    try await assertSettled()
    let target = try XCTUnwrap(model.picture?.targets.first { $0.actionable })
    let rect = map.rect(target.rect)
    let point = map.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    let click = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    )
    map.mouseDown(with: click)
    try await wait { model.selected?.key.sameEntry(other: target.entry.key) == true }
    let tiny = try entry("Tiny files", in: model)
    model.focus(tiny.key)
    try await assertSettled()
    XCTAssertTrue(model.records!.focus.key.sameEntry(other: tiny.key))
    let before = model.viewport
    window.setContentSize(NSSize(width: 1400, height: 880))
    host.layoutSubtreeIfNeeded()
    try await assertSettled()
    XCTAssertNotEqual(model.viewport, before)
  }

  func testOfflineRootBreadcrumbNamesAndFullPathHelpRemainDistinct() async throws {
    let root = try ownedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ExplorerModel(
      arguments: [], environment: [:],
      storage: ManagedInventoryStorage(root: root.appendingPathComponent("support")))
    defer { model.shutdown() }
    for name in ["First saved root", "Second saved root"] {
      let source = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(
        at: source.appendingPathComponent("same-child"), withIntermediateDirectories: true)
      let snapshot = root.appendingPathComponent(name + ".dmap")
      let sourceBytes = ExplorerModel.pathBytes(source)
      let snapshotBytes = ExplorerModel.pathBytes(snapshot)
      _ = try await Task.detached {
        try ExplorerSession.create(sourceRoot: sourceBytes, snapshotPath: snapshotBytes, workers: 1)
      }.value
      try FileManager.default.moveItem(
        at: source, to: root.appendingPathComponent(name + "-unavailable"))
      model.load { try ExplorerSession.openSnapshot(snapshotPath: snapshotBytes) }
      try await wait { !model.replacingSession }
      let records = try XCTUnwrap(model.records)
      XCTAssertEqual(records.breadcrumbName(records.focus), name)
      XCTAssertEqual(records.breadcrumbHelp(records.focus), source.path)
      var filesystemRoot = records.status
      filesystemRoot.rootPath = Data("/".utf8)
      let rootRecords = ViewRecords(status: filesystemRoot, focus: records.focus, ancestors: [])
      XCTAssertEqual(rootRecords.breadcrumbName(rootRecords.focus), "/")
      XCTAssertEqual(rootRecords.breadcrumbHelp(rootRecords.focus), "/")
      model.focus(try entry("same-child", in: model).key)
      try await wait { !model.loading }
      let nested = try XCTUnwrap(model.records)
      let ancestor = try XCTUnwrap(nested.ancestors.first)
      XCTAssertEqual(nested.breadcrumbName(ancestor), name)
      XCTAssertEqual(nested.breadcrumbHelp(ancestor), source.path)
      // The deep-path fallback uses the same saved root presentation even without root in ancestors.
      let truncated = ViewRecords(status: nested.status, focus: nested.focus, ancestors: [])
      XCTAssertEqual(truncated.breadcrumbName(truncated.status.root), name)
      XCTAssertEqual(truncated.breadcrumbHelp(truncated.status.root), source.path)
    }
  }

  func testFinderURLUsesRawBytesAndRejectsLossyFoundationConversion() async throws {
    let root = try ownedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ExplorerModel(
      arguments: [], environment: [:], storage: ManagedInventoryStorage(root: root))
    model.load { try ExplorerSession.fixture(scenario: "presentation") }
    try await wait { !model.replacingSession }
    model.select(try entry("large-file", in: model))
    try await wait { model.selectionRawPath != nil }
    let relative = Data("folder/name % é".utf8)
    model.selectionRawPath = relative
    var expected = model.records!.status.rootPath
    if expected.last != 47 { expected.append(47) }
    expected.append(relative)
    XCTAssertEqual(ExplorerModel.pathBytes(try XCTUnwrap(model.selectedURL)), expected)
    model.selectionPath = "not-the-authoritative-path"
    XCTAssertEqual(ExplorerModel.pathBytes(try XCTUnwrap(model.selectedURL)), expected)
    model.selectionRawPath = Data([255, 97])
    // Foundation replaces invalid UTF-8; never reveal that different path.
    XCTAssertNil(model.selectedURL)
    model.selectionRawPath = Data([97, 0, 98])
    XCTAssertNil(model.selectedURL)
    model.shutdown()
  }

  func testOnlyFixtureWindowTitleNamesSimulation() throws {
    let root = try ownedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedInventoryStorage(root: root.appendingPathComponent("support"))
    let production = ExplorerModel(arguments: [], environment: [:], storage: storage)
    XCTAssertEqual(production.windowTitle, "Disk Inventory")
    production.shutdown()
    let fixture = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", "presentation"], environment: [:])
    XCTAssertEqual(fixture.windowTitle, "Disk Inventory — SIMULATED")
    fixture.shutdown()
  }

  func testNoScanLaunchReadsOnlySmallManagedMetadata() async throws {
    let root = try ownedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedInventoryStorage(root: root.appendingPathComponent("support"))
    let model = ExplorerModel(arguments: [], environment: [:], storage: storage)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertNil(model.session)
    XCTAssertNil(model.records)
    XCTAssertNil(model.lastInventory)
    XCTAssertFalse(model.loading)
    XCTAssertFalse(model.scan.polling)
    XCTAssertFalse(FileManager.default.fileExists(atPath: storage.root.path))
    model.shutdown()
  }

  func testManagedStorageLifecycleOfflineOpenAndImportsAreNotRetained() async throws {
    let root = try ownedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: source.appendingPathComponent("owned.txt"))
    let storage = ManagedInventoryStorage(root: root.appendingPathComponent("support"))
    let model = ExplorerModel(arguments: [], environment: [:], storage: storage)
    model.createManaged(root: source)
    try await wait { !model.replacingSession }
    XCTAssertNil(model.error)
    let first = try XCTUnwrap(model.lastInventory)
    XCTAssertNotNil(model.scanDate)
    let imported = root.appendingPathComponent("import.dmap")
    try FileManager.default.copyItem(at: storage.url(for: first), to: imported)
    model.load { try ExplorerSession.openSnapshot(snapshotPath: ExplorerModel.pathBytes(imported)) }
    try await wait { !model.replacingSession }
    XCTAssertNil(model.scanDate)  // Import time is not a scan date.
    XCTAssertEqual(try storage.lastInventory()?.filename, first.filename)
    model.createManaged(root: source)
    try await wait { !model.replacingSession }
    let last = try XCTUnwrap(model.lastInventory)
    XCTAssertNotEqual(first.filename, last.filename)
    XCTAssertFalse(FileManager.default.fileExists(atPath: storage.url(for: first).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.root.path).count, 2)
    XCTAssertThrowsError(try storage.discard(imported))
    try storage.discard(storage.url(for: last))
    XCTAssertTrue(FileManager.default.fileExists(atPath: storage.url(for: last).path))
    try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("offline-source"))
    model.openLastInventory()
    try await wait { !model.replacingSession }
    XCTAssertNil(model.error)
    XCTAssertEqual(model.scanDate, last.scannedAt)
    XCTAssertNotNil(try entry("owned.txt", in: model))
    XCTAssertFalse(model.scan.polling)
    model.shutdown()
  }

  func testCancelledCreatePreservesPriorSnapshotAndFailedCreateCleansGeneration() async throws {
    let root = try ownedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let storage = ManagedInventoryStorage(root: root.appendingPathComponent("support"))
    let model = ExplorerModel(arguments: [], environment: [:], storage: storage)
    model.createManaged(root: source)
    try await wait { !model.replacingSession }
    let first = try XCTUnwrap(model.lastInventory)
    let bytes = try Data(contentsOf: storage.url(for: first))
    let previousSession = model.session
    let control = ScanControl()
    XCTAssertTrue(control.cancel())  // Deterministic cancellation before constructor dispatch.
    model.createManaged(root: source, control: control)
    try await wait { !model.replacingSession }
    XCTAssertEqual(control.progress().phase, .cancelled)
    XCTAssertTrue(model.error?.contains("cancelled") == true)
    XCTAssertTrue(model.session === previousSession)
    XCTAssertEqual(try storage.lastInventory()?.filename, first.filename)
    XCTAssertEqual(try Data(contentsOf: storage.url(for: first)), bytes)
    XCTAssertFalse(model.scan.polling)
    model.createManaged(root: root.appendingPathComponent("missing"))
    try await wait { !model.replacingSession }
    XCTAssertNotNil(model.error)
    XCTAssertEqual(try Data(contentsOf: storage.url(for: first)), bytes)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.root.path).count, 2)
    model.shutdown()
  }

  func testScanPollingStopAndReplacementCallRustControlAndEndPolling() async throws {
    let poll = ScanCoordinator()
    let first = ScanControl()
    poll.begin(first)
    try await Task.sleep(for: .milliseconds(570))
    XCTAssertTrue((1...3).contains(poll.samples))
    poll.stop()
    XCTAssertEqual(first.progress().phase, .stopping)
    XCTAssertEqual(poll.progress?.phase, .stopping)
    XCTAssertFalse(poll.progress?.cancellable ?? true)
    let second = ScanControl()
    poll.begin(second)
    let third = ScanControl()
    poll.begin(third)
    XCTAssertEqual(second.progress().phase, .stopping)
    poll.stopPolling(cancelScan: true)
    let count = poll.samples
    try await Task.sleep(for: .milliseconds(550))
    XCTAssertEqual(third.progress().phase, .stopping)
    XCTAssertFalse(poll.polling)
    XCTAssertNil(poll.progress)
    XCTAssertEqual(poll.samples, count)

    let model = try await fixture("presentation")
    let control = ScanControl()
    model.scan.begin(control)
    model.load { try ExplorerSession.fixture(scenario: "ordinary") }
    XCTAssertEqual(control.progress().phase, .stopping)
    try await wait { !model.replacingSession }
    XCTAssertFalse(model.scan.polling)
  }

  func testBreadcrumbContextsRestoreBothDirectionsAndHiddenSelection() async throws {
    let model = try await fixture()
    let root = model.records!.focus.key
    let projects = try entry("Projects", in: model)
    model.expand(projects, expanded: true)
    try await wait { !model.treeEditing }
    let child = try XCTUnwrap(model.outline?.rows.first { $0.depth == 1 }?.entry)
    model.select(child)
    try await wait { model.selectedRow != nil && model.selectionPath != nil }
    model.expand(projects, expanded: false)
    try await wait { !model.treeEditing }
    XCTAssertNil(model.selectedRow)
    let tree = model.tree
    model.scrollRow = 1
    model.focus(projects.key)
    try await wait { !model.loading }
    let inside = try XCTUnwrap(model.outline?.rows.first?.entry)
    model.select(inside)
    try await wait { model.selectedRow != nil }
    model.scrollRow = 250
    model.focus(root)
    try await wait { !model.loading }
    XCTAssertTrue(model.tree === tree)
    XCTAssertTrue(model.selected!.key.sameEntry(other: child.key))
    XCTAssertNil(model.selectedRow)
    XCTAssertEqual(model.restoredScrollRow, 1)
    model.focus(projects.key)
    try await wait { !model.loading }
    XCTAssertTrue(model.selected!.key.sameEntry(other: inside.key))
    XCTAssertEqual(model.restoredScrollRow, 250)
    model.focus(root)
    try await wait { !model.loading }
    model.revealSelection()
    try await wait { model.selectedRow != nil }
    XCTAssertTrue(model.records!.focus.key.sameEntry(other: root))
    XCTAssertLessThanOrEqual(model.outline!.rows.count, 256)
    XCTAssertLessThanOrEqual(model.history.count, 64)
  }

  func testRefreshUsesFocusedDirectoryNotSelectedAndNeverSaves() async throws {
    let root = try ownedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let nested = source.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let storage = ManagedInventoryStorage(root: root.appendingPathComponent("support"))
    let model = ExplorerModel(arguments: [], environment: [:], storage: storage)
    model.createManaged(root: source)
    try await wait { !model.replacingSession }
    let record = try XCTUnwrap(model.lastInventory)
    let bytes = try Data(contentsOf: storage.url(for: record))
    model.select(try entry("nested", in: model))
    try Data([4]).write(to: source.appendingPathComponent("new-sibling"))
    model.refresh()
    try await wait { !model.working }
    XCTAssertNotNil(try entry("new-sibling", in: model))
    XCTAssertTrue(model.records?.status.dirty == true)
    XCTAssertTrue(model.outcome?.contains("in memory") == true)
    XCTAssertEqual(try Data(contentsOf: storage.url(for: record)), bytes)
    XCTAssertEqual(model.scanDate, record.scannedAt)
    model.shutdown()
  }

  func testRemovalMotionOutcomesVisibleDestinationAndReduceMotion() async throws {
    let model = try await fixture("presentation")
    let target = try XCTUnwrap(model.picture?.targets.first)
    let root = model.records!.status.rootPath
    var destination = root
    if destination.last != 47 { destination.append(47) }
    destination.append(target.relativePath)
    func plan(
      _ mutation: MutationOutcome, _ scope: TrashScope? = nil, reduced: Bool = false,
      visible: Bool = true
    ) -> RemovalMotionPlan? {
      RemovalMotionPlan.make(
        mutation: mutation, scope: scope, source: target.rect, rootPath: root,
        visibleTargets: visible ? [target] : [], reduceMotion: reduced)
    }
    XCTAssertEqual(plan(.removed)?.style, .poof)
    XCTAssertEqual(plan(.removed, reduced: true)?.style, .fade)
    XCTAssertNil(plan(.failed(message: "failure")))
    XCTAssertNil(plan(.partial(message: "survivors")))
    XCTAssertNil(plan(.indeterminate(message: "unknown")))
    XCTAssertEqual(plan(.trashed(destination: destination), .outside)?.style, .poof)
    XCTAssertEqual(plan(.trashed(destination: destination), .unknown)?.style, .poof)
    let inside = TrashScope.inside(relativePath: target.relativePath)
    XCTAssertEqual(plan(.trashed(destination: destination), inside)?.style, .travel)
    XCTAssertEqual(plan(.trashed(destination: Data("/wrong".utf8)), inside)?.style, .poof)
    XCTAssertEqual(plan(.trashed(destination: destination), inside, visible: false)?.style, .poof)
    XCTAssertEqual(plan(.trashed(destination: destination), inside, reduced: true)?.style, .fade)
    let previous = model.picture!
    let motionPlan = try XCTUnwrap(plan(.removed))
    let animation = Task { await model.motion.play(previous: previous, plan: motionPlan) }
    try await wait { model.motion.active }
    model.load { try ExplorerSession.fixture(scenario: "ordinary") }
    XCTAssertFalse(model.motion.active)
    await animation.value
    try await wait { !model.replacingSession }
    XCTAssertFalse(model.motion.active)
    XCTAssertNil(model.motion.previous)
  }

  func testSuccessfulRemovalHoldsOnlyOneOldFrameAndReplacementCancelsMotion() async throws {
    let model = try await fixture("presentation")
    model.select(try entry("large-file", in: model))
    try await wait { model.selectedRegion != nil }
    let old = model.picture!.frame
    model.prepare(.permanentlyDelete)
    try await wait { model.pending != nil }
    model.execute()
    try await wait { model.motion.active }
    XCTAssertTrue(model.outcome?.contains("Permanently deleted") == true)
    XCTAssertTrue(model.motion.previous?.frame === old)
    XCTAssertTrue(model.working)
    model.point(0, 0, click: true)
    model.load { try ExplorerSession.fixture(scenario: "ordinary") }
    XCTAssertFalse(model.motion.active)
    try await wait { !model.replacingSession }
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertNil(model.motion.previous)
    XCTAssertNil(model.selected)
    XCTAssertNil(model.outcome)
  }

  func testPartialRemovalPreservesSurvivingSelectionWithoutSuccessMotion() async throws {
    let model = try await fixture("partial-deletion")
    model.select(try entry("small-files", in: model))
    model.prepare(.permanentlyDelete)
    try await wait { model.pending != nil }
    model.execute()
    try await wait { !model.working }
    XCTAssertTrue(model.outcome?.contains("Partial") == true)
    XCTAssertEqual(model.selected?.displayName, "small-files")
    XCTAssertFalse(model.motion.active)
    XCTAssertFalse(model.issues.isEmpty)
  }

  func testFixtureReduceMotionOverrideIsIgnoredOutsideFixtureMode() async throws {
    let root = try ownedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedInventoryStorage(root: root.appendingPathComponent("support"))
    let native = ExplorerModel(
      arguments: [], environment: ["DI_REDUCE_MOTION": "1"], storage: storage)
    XCTAssertFalse(native.fixtureMode)
    XCTAssertFalse(native.fixtureReduceMotion)
    native.shutdown()
    let ordinary = try await fixture("presentation")
    XCTAssertFalse(ordinary.fixtureReduceMotion)
    let disabled = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", "presentation"],
      environment: ["DI_REDUCE_MOTION": "0"])
    XCTAssertFalse(disabled.fixtureReduceMotion)
    let model = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", "presentation"],
      environment: ["DI_REDUCE_MOTION": "1"])
    XCTAssertTrue(model.fixtureReduceMotion)
    XCTAssertTrue(model.reduceMotion)
    try await wait { !model.loading && !model.replacingSession && model.records != nil }
    model.select(try entry("large-file", in: model))
    try await wait { model.selectedRegion != nil }
    model.prepare(.permanentlyDelete)
    try await wait { model.pending != nil }
    model.execute()
    try await wait { !model.working }
    XCTAssertEqual(model.motion.lastStyle, .fade)
    XCTAssertGreaterThan(model.motion.lastTicks, 1)
  }

  func testRecoveryPublishesBoundedSliceAndScrollForLateSurvivor() async throws {
    let model = try await fixture("dix")
    let session = try XCTUnwrap(model.session)
    let projects = try entry("Projects", in: model)
    let survivor = try await Task.detached {
      try session.children(parent: projects.key, offset: 1000, limit: 1).entries[0]
    }.value
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: ContentsTree(model: model))
    window.contentView = host
    defer {
      model.shutdown()
      window.close()
    }
    host.layoutSubtreeIfNeeded()
    func table(in view: NSView) -> ContentsTree.Table? {
      if let table = view as? ContentsTree.Table { return table }
      return view.subviews.compactMap { table(in: $0) }.first
    }
    let table = try XCTUnwrap(table(in: host))
    let serial = model.revealSerial
    await model.recoverView(session, preserving: survivor.key)
    let row = try XCTUnwrap(model.selectedRow)
    XCTAssertGreaterThan(row, 255)
    XCTAssertGreaterThan(model.revealSerial, serial)
    XCTAssertEqual(model.restoredScrollRow, row)
    let slice = try XCTUnwrap(model.outline)
    XCTAssertLessThanOrEqual(slice.rows.count, 256)
    XCTAssertGreaterThan(slice.offset, 0)
    XCTAssertTrue(slice.rows.contains { $0.entry.key.sameEntry(other: survivor.key) })
    try await wait {
      host.layoutSubtreeIfNeeded()
      return table.selectedRow == row && table.visibleRect.intersects(table.rect(ofRow: row))
    }
    let cell = try XCTUnwrap(
      table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ContentsTree.Cell)
    XCTAssertEqual(cell.name.stringValue, survivor.displayName)
    XCTAssertTrue(model.canAct)
  }

  func testRecoveryKeepsOutsideFocusSurvivorWithoutFalseTreeRow() async throws {
    let model = try await fixture("dix")
    let session = try XCTUnwrap(model.session)
    let movie = try entry("Movie.mov", in: model)
    let tiny = try entry("Tiny files", in: model)
    model.focus(tiny.key)
    try await wait { !model.loading }
    let serial = model.revealSerial
    await model.recoverView(session, preserving: movie.key)
    XCTAssertTrue(model.records!.focus.key.sameEntry(other: tiny.key))
    XCTAssertTrue(model.selected!.key.sameEntry(other: movie.key))
    XCTAssertEqual(model.selectionRawPath, Data("Movie.mov".utf8))
    XCTAssertNil(model.selectedRow)
    XCTAssertEqual(model.revealSerial, serial)
    XCTAssertEqual(model.outline?.offset, 0)
    XCTAssertFalse(model.outline!.rows.contains { $0.entry.key.sameEntry(other: movie.key) })
  }

  func testRecoveryRetainsRowsWithoutInteractiveStaleTree() async throws {
    let model = try await fixture("metadata-delay")
    let target = try entry("large-file", in: model)
    model.select(target)
    try await wait { model.selectedRow != nil && model.selectionRawPath != nil }
    let session = try XCTUnwrap(model.session)
    let token = model.outlineToken
    let rows = try XCTUnwrap(model.outline).total
    let blocker = Task.detached { try session.liveMetadata(key: target.key) }
    try await wait { session.isBusy() }
    let recovery = Task { await model.recoverView(session, preserving: target.key) }
    try await wait { model.tree == nil && model.loading }
    XCTAssertTrue(model.outlineToken === token)
    XCTAssertEqual(model.outline?.total, rows)
    XCTAssertFalse(model.canAct)
    let coordinator = ContentsTree.Coordinator(model)
    let table = ContentsTree.Table()
    table.dataSource = coordinator
    table.delegate = coordinator
    table.reloadData()
    XCTAssertEqual(table.numberOfRows, Int(rows))
    XCTAssertFalse(coordinator.tableView(table, shouldSelectRow: 0))
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    coordinator.tableViewSelectionDidChange(
      Notification(name: NSTableView.selectionDidChangeNotification, object: table))
    XCTAssertTrue(model.selected?.key.sameEntry(other: target.key) == true)
    let disclosure = NSButton()
    disclosure.tag = 0
    coordinator.toggle(disclosure)
    XCTAssertFalse(model.treeEditing)
    XCTAssertTrue(coordinator.key(124))
    model.prepare(.trash)
    XCTAssertNil(model.pending)
    _ = try await blocker.value
    await recovery.value
    XCTAssertNotNil(model.tree)
    XCTAssertFalse(model.outlineToken === token)
    XCTAssertTrue(model.selected?.key.sameEntry(other: target.key) == true)
  }

  func testRemovalOutcomeKeepsHostedMapViewportAndTreeRowsStable() async throws {
    for action in [ActionKind.trash, .permanentlyDelete] {
      let model = try await fixture("presentation-trash-inside")
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let host = NSHostingView(rootView: ExplorerView(model: model))
      window.contentView = host
      defer {
        model.shutdown()
        window.close()
      }
      func map(in view: NSView) -> DiagramView.MapView? {
        if let map = view as? DiagramView.MapView { return map }
        return view.subviews.compactMap { map(in: $0) }.first
      }
      host.layoutSubtreeIfNeeded()
      let map = try XCTUnwrap(map(in: host))
      try await wait {
        host.layoutSubtreeIfNeeded()
        return !model.loading && model.picture?.bitmap.height == UInt32(model.viewport.height)
          && model.viewport.height == floor(map.bounds.height * window.backingScaleFactor)
      }
      try await Task.sleep(for: .milliseconds(220))
      let bounds = map.bounds
      let viewport = model.viewport
      let builds = model.diagramBuilds
      model.select(try entry("large-file", in: model))
      try await wait { model.selectedRegion != nil }
      model.prepare(action)
      try await wait { model.pending != nil }
      model.execute()
      while model.working {
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(map.bounds, bounds)
        XCTAssertEqual(model.viewport, viewport)
        XCTAssertGreaterThan(model.outline?.total ?? 0, 0)
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertNotNil(model.outcome)
      for _ in 0..<3 {
        try await Task.sleep(for: .milliseconds(220))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(map.bounds, bounds)
        XCTAssertEqual(model.viewport, viewport)
        XCTAssertEqual(model.diagramBuilds, builds + 1)
      }
    }
  }

  func testInsideTrashTravelsBetweenMateriallyDistinctRegions() async throws {
    let model = try await fixture("presentation-trash-inside")
    model.select(try entry("large-file", in: model))
    try await wait { model.selectedRegion != nil }
    model.prepare(.trash)
    try await wait { model.pending != nil }
    model.execute()
    try await wait { model.motion.plan != nil || !model.working }
    let plan = try XCTUnwrap(model.motion.plan)
    XCTAssertEqual(plan.style, .travel)
    let destination = try XCTUnwrap(plan.destination)
    XCTAssertGreaterThan(
      hypot(
        destination.x + destination.width / 2 - plan.source.x - plan.source.width / 2,
        destination.y + destination.height / 2 - plan.source.y - plan.source.height / 2), 80)
    try await wait { !model.working }
    XCTAssertEqual(model.motion.lastStyle, .travel)
    XCTAssertEqual(model.selected?.displayName, "moved")
  }

  func testInsideTrashTravelsToTheMovedTileBeyondAccessibilityTargets() async throws {
    let model = try await fixture("presentation-trash-late-target")
    model.select(try entry("large-file", in: model))
    try await wait { model.selectedRegion != nil }
    model.prepare(.trash)
    try await wait { model.pending != nil }
    model.execute()
    try await wait { model.motion.plan != nil || !model.working }
    XCTAssertEqual(try XCTUnwrap(model.motion.plan).style, .travel)
    // This fixture places the destination after 128 small files, outside the 24 targets.
    XCTAssertFalse(model.picture!.targets.contains { $0.relativePath == Data("trash/moved".utf8) })
    try await wait { !model.working }
    XCTAssertEqual(model.motion.lastStyle, .travel)
    XCTAssertEqual(model.selected?.displayName, "moved")
  }
}
