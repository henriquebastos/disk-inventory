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
}
