import AppKit
import SwiftUI
import XCTest

@testable import DiskInventory

@MainActor final class RedesignModelTests: XCTestCase {
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
    try await waitUntil { !model.loading && !model.replacingSession && model.records != nil }
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
      try await waitUntil {
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
    try await waitUntil { model.selection.entry?.key.sameEntry(other: target.entry.key) == true }
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
      try await waitUntil { !model.replacingSession }
      let records = try XCTUnwrap(model.records)
      XCTAssertEqual(records.breadcrumbName(records.focus), name)
      XCTAssertEqual(records.breadcrumbHelp(records.focus), source.path)
      var filesystemRoot = records.status
      filesystemRoot.rootPath = Data("/".utf8)
      let rootRecords = ViewRecords(status: filesystemRoot, focus: records.focus, ancestors: [])
      XCTAssertEqual(rootRecords.breadcrumbName(rootRecords.focus), "/")
      XCTAssertEqual(rootRecords.breadcrumbHelp(rootRecords.focus), "/")
      model.focus(try entry("same-child", in: model).key)
      try await waitUntil { !model.loading }
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
    try await waitUntil { !model.replacingSession }
    model.select(try entry("large-file", in: model))
    try await waitUntil { model.selection.rawPath != nil }
    let relative = Data("folder/name % é".utf8)
    model.selection.rawPath = relative
    var expected = model.records!.status.rootPath
    if expected.last != 47 { expected.append(47) }
    expected.append(relative)
    XCTAssertEqual(ExplorerModel.pathBytes(try XCTUnwrap(model.selectedURL)), expected)
    model.selection.path = "not-the-authoritative-path"
    XCTAssertEqual(ExplorerModel.pathBytes(try XCTUnwrap(model.selectedURL)), expected)
    model.selection.rawPath = Data([255, 97])
    // Foundation replaces invalid UTF-8; never reveal that different path.
    XCTAssertNil(model.selectedURL)
    model.selection.rawPath = Data([97, 0, 98])
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

  func testManagedStorageLifecycleReopensLastFolderOfflineAndCleansOldGeneration() async throws {
    let root = try ownedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: source.appendingPathComponent("owned.txt"))
    let storage = ManagedInventoryStorage(root: root.appendingPathComponent("support"))
    let model = ExplorerModel(arguments: [], environment: [:], storage: storage)
    model.createManaged(root: source)
    try await waitUntil { !model.replacingSession }
    XCTAssertNil(model.error)
    let first = try XCTUnwrap(model.lastInventory)
    XCTAssertNotNil(model.scanDate)
    XCTAssertEqual(first.rootName, source.path)
    XCTAssertEqual(ExplorerCommand.reopenLastFolder.title(in: model), "Reopen “source”")
    // A file outside the app's UUID generations is never cleanup's to remove.
    let foreign = root.appendingPathComponent("foreign.dmap")
    try FileManager.default.copyItem(at: storage.url(for: first), to: foreign)
    model.createManaged(root: source)
    try await waitUntil { !model.replacingSession }
    let last = try XCTUnwrap(model.lastInventory)
    XCTAssertNotEqual(first.filename, last.filename)
    XCTAssertFalse(FileManager.default.fileExists(atPath: storage.url(for: first).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.root.path).count, 2)
    XCTAssertThrowsError(try storage.discard(foreign))
    try storage.discard(storage.url(for: last))
    XCTAssertTrue(FileManager.default.fileExists(atPath: storage.url(for: last).path))
    try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("offline-source"))
    model.reopenLastFolder()
    try await waitUntil { !model.replacingSession }
    XCTAssertNil(model.error)
    XCTAssertEqual(model.scanDate, last.scannedAt)
    XCTAssertNotNil(try entry("owned.txt", in: model))
    XCTAssertFalse(model.scan.polling)
    model.shutdown()
  }

  func testLastFolderMetadataRoundTripsRootNameAndOldMetadataFallsBack() throws {
    let root = try ownedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedInventoryStorage(root: root.appendingPathComponent("support"))
    let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let generation = try storage.newGeneration()
    let published = try storage.publish(
      generation, scannedAt: date, rootName: "/Users/someone/Workspace")
    let read = try XCTUnwrap(try storage.lastInventory())
    XCTAssertEqual(read.filename, published.filename)
    XCTAssertEqual(read.scannedAt, date)
    XCTAssertEqual(read.rootName, "/Users/someone/Workspace")
    XCTAssertEqual(read.reopenTitle, "Reopen “Workspace”")
    func title(_ rootName: String?) -> String {
      ManagedInventory(filename: "inventory-x.dmap", scannedAt: date, rootName: rootName)
        .reopenTitle
    }
    // The last path component, as in the root breadcrumb. The filesystem root keeps "/".
    XCTAssertEqual(title("/Volumes/Data/Projects/"), "Reopen “Projects”")
    XCTAssertEqual(title("/"), "Reopen “/”")
    // Long names shorten in the middle at 60 characters, as in the confirmation title.
    let long = String(repeating: "very-long-folder-name-", count: 5) + "end"
    XCTAssertEqual(
      title("/Volumes/Archive/" + long),
      "Reopen “\(long.prefix(29))…\(long.suffix(30))”")
    XCTAssertEqual(title("/a/" + String(repeating: "n", count: 60)).count, 69)
    XCTAssertEqual(title(""), "Reopen Last Folder")
    XCTAssertEqual(title(nil), "Reopen Last Folder")
    // Metadata written without rootName still opens the last folder, with a generic label.
    let old = try JSONSerialization.data(withJSONObject: [
      "filename": published.filename, "scannedAt": date.timeIntervalSinceReferenceDate,
    ])
    try old.write(to: storage.root.appendingPathComponent("last-inventory.json"), options: .atomic)
    let fallback = try XCTUnwrap(try storage.lastInventory())
    XCTAssertNil(fallback.rootName)
    XCTAssertEqual(fallback.filename, published.filename)
    XCTAssertEqual(fallback.scannedAt, date)
    XCTAssertEqual(fallback.reopenTitle, "Reopen Last Folder")
  }

  func testFixtureStorageRootIsReadOnlyAndNeedsFixtureModeAndAnExistingDirectory() async throws {
    let root = try ownedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("fixture-support")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let record = ManagedInventory(
      filename: "inventory-\(UUID().uuidString).dmap", scannedAt: Date(), rootName: "/Workspace")
    try JSONEncoder().encode(record).write(
      to: support.appendingPathComponent("last-inventory.json"))
    let file = support.appendingPathComponent("last-inventory.json")
    for value in [
      nil, "", "relative/support", root.appendingPathComponent("missing").path, file.path,
    ] {
      let environment = value.map { ["DI_FIXTURE_STORAGE_ROOT": $0] } ?? [:]
      XCTAssertNil(ExplorerModel.fixtureStorage(environment), value ?? "no value")
    }
    XCTAssertEqual(
      ExplorerModel.fixtureStorage(["DI_FIXTURE_STORAGE_ROOT": support.path])?.root.path,
      support.path)
    func listing() throws -> [String] {
      try FileManager.default.contentsOfDirectory(atPath: support.path).sorted().map {
        let attributes = try FileManager.default.attributesOfItem(
          atPath: support.appendingPathComponent($0).path)
        return "\($0) \(attributes[.size] ?? 0) \(attributes[.modificationDate] ?? 0)"
      }
    }
    let before = try listing()
    let environment = ["DI_FIXTURE_STORAGE_ROOT": support.path]
    let fixture = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", "presentation"], environment: environment)
    defer { fixture.shutdown() }
    try await waitUntil {
      fixture.lastInventory != nil && fixture.records != nil && !fixture.replacingSession
    }
    XCTAssertEqual(fixture.lastInventory?.filename, record.filename)
    XCTAssertEqual(ExplorerCommand.reopenLastFolder.title(in: fixture), "Reopen “Workspace”")
    // Fixture mode only reads the metadata. It never opens, creates or cleans up.
    XCTAssertFalse(ExplorerCommand.reopenLastFolder.isEnabled(in: fixture))
    XCTAssertFalse(ExplorerCommand.chooseFolder.isEnabled(in: fixture))
    fixture.reopenLastFolder()
    fixture.createManaged(root: root)
    XCTAssertFalse(fixture.replacingSession)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(try listing(), before)
    // Without the variable, fixture mode has no storage. Production ignores the variable.
    let plain = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", "presentation"], environment: [:])
    defer { plain.shutdown() }
    let other = root.appendingPathComponent("injected")
    let injected = ManagedInventoryStorage(root: other)
    let production = ExplorerModel(arguments: [], environment: environment, storage: injected)
    defer { production.shutdown() }
    try await waitUntil { plain.records != nil && !plain.replacingSession }
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertNil(plain.lastInventory)
    XCTAssertNil(production.lastInventory)
    XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
    XCTAssertEqual(try listing(), before)
  }

  func testCancelledCreatePreservesPriorSnapshotAndFailedCreateCleansGeneration() async throws {
    let root = try ownedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let storage = ManagedInventoryStorage(root: root.appendingPathComponent("support"))
    let model = ExplorerModel(arguments: [], environment: [:], storage: storage)
    model.createManaged(root: source)
    try await waitUntil { !model.replacingSession }
    let first = try XCTUnwrap(model.lastInventory)
    let bytes = try Data(contentsOf: storage.url(for: first))
    let previousSession = model.session
    let control = ScanControl()
    XCTAssertTrue(control.cancel())  // Deterministic cancellation before constructor dispatch.
    model.createManaged(root: source, control: control)
    try await waitUntil { !model.replacingSession }
    XCTAssertEqual(control.progress().phase, .cancelled)
    XCTAssertTrue(model.error?.contains("cancelled") == true)
    XCTAssertTrue(model.session === previousSession)
    XCTAssertEqual(try storage.lastInventory()?.filename, first.filename)
    XCTAssertEqual(try Data(contentsOf: storage.url(for: first)), bytes)
    XCTAssertFalse(model.scan.polling)
    model.createManaged(root: root.appendingPathComponent("missing"))
    try await waitUntil { !model.replacingSession }
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
    try await waitUntil { !model.replacingSession }
    XCTAssertFalse(model.scan.polling)
  }

  func testBreadcrumbContextsRestoreBothDirectionsAndHiddenSelection() async throws {
    let model = try await fixture()
    let root = model.records!.focus.key
    let projects = try entry("Projects", in: model)
    model.expand(projects, expanded: true)
    try await waitUntil { !model.treeEditing }
    let child = try XCTUnwrap(model.outline?.rows.first { $0.depth == 1 }?.entry)
    model.select(child)
    try await waitUntil { model.selection.row != nil && model.selection.path != nil }
    model.expand(projects, expanded: false)
    try await waitUntil { !model.treeEditing }
    XCTAssertNil(model.selection.row)
    let tree = model.tree
    model.scrolled(toRow: 1)
    model.focus(projects.key)
    try await waitUntil { !model.loading }
    let inside = try XCTUnwrap(model.outline?.rows.first?.entry)
    model.select(inside)
    try await waitUntil { model.selection.row != nil }
    model.scrolled(toRow: 250)
    model.focus(root)
    try await waitUntil { !model.loading }
    XCTAssertTrue(model.tree === tree)
    XCTAssertTrue(model.selection.entry!.key.sameEntry(other: child.key))
    XCTAssertNil(model.selection.row)
    XCTAssertEqual(model.restoredScrollRow, 1)
    model.focus(projects.key)
    try await waitUntil { !model.loading }
    XCTAssertTrue(model.selection.entry!.key.sameEntry(other: inside.key))
    XCTAssertEqual(model.restoredScrollRow, 250)
    model.focus(root)
    try await waitUntil { !model.loading }
    model.revealSelection()
    try await waitUntil { model.selection.row != nil }
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
    try await waitUntil { !model.replacingSession }
    let record = try XCTUnwrap(model.lastInventory)
    let bytes = try Data(contentsOf: storage.url(for: record))
    model.select(try entry("nested", in: model))
    try Data([4]).write(to: source.appendingPathComponent("new-sibling"))
    model.refresh()
    try await waitUntil { !model.working }
    XCTAssertNotNil(try entry("new-sibling", in: model))
    XCTAssertTrue(model.records?.status.dirty == true)
    XCTAssertEqual(
      model.outcome, "Refreshed “\(model.records!.breadcrumbName(model.records!.focus))”.")
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
    let survivors = RemovalRecord(removed: 1, skipped: 1, reasons: ["/x: permission denied"])
    XCTAssertNil(plan(.partial(message: "survivors", stopped: false, removal: survivors)))
    XCTAssertNil(plan(.partial(message: "deletion stopped", stopped: true, removal: survivors)))
    XCTAssertNil(plan(.removedWithSkips(removal: survivors)), "the target stays")
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
    try await waitUntil { model.motion.active }
    model.load { try ExplorerSession.fixture(scenario: "ordinary") }
    XCTAssertFalse(model.motion.active)
    await animation.value
    try await waitUntil { !model.replacingSession }
    XCTAssertFalse(model.motion.active)
    XCTAssertNil(model.motion.previous)
  }

  func testSuccessfulRemovalHoldsOnlyOneOldFrameAndReplacementCancelsMotion() async throws {
    let model = try await fixture("presentation")
    model.select(try entry("large-file", in: model))
    try await waitUntil { model.selection.region != nil }
    let old = model.picture!.frame
    model.prepare(.permanentlyDelete)
    try await waitUntil { model.pending != nil }
    model.execute()
    try await waitUntil { model.motion.active }
    XCTAssertEqual(model.outcome, "Deleted.")
    XCTAssertTrue(model.motion.previous?.frame === old)
    XCTAssertTrue(model.working)
    model.point(0, 0, click: true)
    model.load { try ExplorerSession.fixture(scenario: "ordinary") }
    XCTAssertFalse(model.motion.active)
    try await waitUntil { !model.replacingSession }
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertNil(model.motion.previous)
    XCTAssertNil(model.selection.entry)
    XCTAssertNil(model.outcome)
  }

  func testConfirmationPresentationNamesItemAndAssignsAlertRoles() async throws {
    let model = try await fixture("presentation")
    defer { model.shutdown() }
    for (name, scope) in [("large-file", "File"), ("small-files", "Directory and its contents")] {
      model.select(try entry(name, in: model))
      for action in [ActionKind.trash, .permanentlyDelete] {
        model.prepare(action)
        try await waitUntil { model.pending != nil }
        let pending = try XCTUnwrap(model.pending)
        XCTAssertEqual(pending.name, name)
        XCTAssertEqual(pending.scope, scope)
        XCTAssertEqual(displayPath(pending.details.rawPath), "/Workspace/\(name)")
        // The sheet shows these texts and names what it removes, without a space disclaimer.
        let alert = ConfirmationAlert.Coordinator.alert(for: pending)
        XCTAssertEqual(alert.messageText, pending.title)
        XCTAssertEqual(alert.informativeText, pending.warning ?? "")
        XCTAssertEqual(alert.buttons.map(\.title), [pending.actionTitle, "Cancel"])
        let texts = [alert.messageText, alert.informativeText, pending.scope, pending.actionTitle]
        for sentence in [
          "Trash may not free space until emptied.", "Deleting may free less space than shown.",
          "If Trash fails",
        ] {
          XCTAssertFalse(texts.contains { $0.contains(sentence) }, "\(name): \(sentence)")
        }
        if action == .trash {
          XCTAssertEqual(pending.title, "Move “\(name)” to the Trash?")
          XCTAssertEqual(pending.actionTitle, "Move to Trash")
          XCTAssertNil(pending.warning, "no space disclaimer")
          // Return confirms the Trash; the system does not draw it red.
          XCTAssertTrue(pending.actionIsDefault)
          XCTAssertFalse(pending.actionIsDestructive)
        } else {
          XCTAssertEqual(pending.title, "Delete “\(name)” immediately?")
          XCTAssertEqual(pending.actionTitle, "Delete Immediately")
          XCTAssertEqual(
            pending.warning,
            scope == "File"
              ? "This cannot be undone."
              : "This cannot be undone. An error may leave some contents undeleted."
          )
          // No default button: Return must not delete, and Cancel is never the default.
          XCTAssertFalse(pending.actionIsDefault)
          XCTAssertTrue(pending.actionIsDestructive)
        }
        model.cancelConfirmation()
        XCTAssertNil(model.pending)
        try await waitUntil { model.canAct }
      }
    }
  }

  func testPartialRemovalPreservesSurvivingSelectionWithoutSuccessMotion() async throws {
    let model = try await fixture("partial-deletion")
    model.select(try entry("small-files", in: model))
    model.prepare(.permanentlyDelete)
    try await waitUntil { model.pending != nil }
    model.execute()
    try await waitUntil { !model.working }
    XCTAssertTrue(model.outcome?.contains("Partial") == true)
    XCTAssertEqual(model.selection.entry?.displayName, "small-files")
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
    try await waitUntil { !model.loading && !model.replacingSession && model.records != nil }
    model.select(try entry("large-file", in: model))
    try await waitUntil { model.selection.region != nil }
    model.prepare(.permanentlyDelete)
    try await waitUntil { model.pending != nil }
    model.execute()
    try await waitUntil { !model.working }
    XCTAssertEqual(model.motion.lastStyle, .fade)
    // A 200 ms clock ticks about every 16 ms; one tick would be a jump, not motion.
    XCTAssertGreaterThanOrEqual(model.motion.lastTicks, 4)
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
    let row = try XCTUnwrap(model.selection.row)
    XCTAssertGreaterThan(row, 255)
    XCTAssertGreaterThan(model.revealSerial, serial)
    XCTAssertEqual(model.restoredScrollRow, row)
    let slice = try XCTUnwrap(model.outline)
    XCTAssertLessThanOrEqual(slice.rows.count, 256)
    XCTAssertGreaterThan(slice.offset, 0)
    XCTAssertTrue(slice.rows.contains { $0.entry.key.sameEntry(other: survivor.key) })
    try await pollUntil {
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
    try await waitUntil { !model.loading }
    let serial = model.revealSerial
    await model.recoverView(session, preserving: movie.key)
    XCTAssertTrue(model.records!.focus.key.sameEntry(other: tiny.key))
    XCTAssertTrue(model.selection.entry!.key.sameEntry(other: movie.key))
    XCTAssertEqual(model.selection.rawPath, Data("Movie.mov".utf8))
    XCTAssertNil(model.selection.row)
    XCTAssertEqual(model.revealSerial, serial)
    XCTAssertEqual(model.outline?.offset, 0)
    XCTAssertFalse(model.outline!.rows.contains { $0.entry.key.sameEntry(other: movie.key) })
  }

  func testRecoveryRetainsRowsWithoutInteractiveStaleTree() async throws {
    let model = try await fixture("metadata-delay")
    let target = try entry("large-file", in: model)
    model.select(target)
    try await waitUntil { model.selection.row != nil && model.selection.rawPath != nil }
    let session = try XCTUnwrap(model.session)
    let token = model.outlineToken
    let rows = try XCTUnwrap(model.outline).total
    let blocker = Task.detached { try session.liveMetadata(key: target.key) }
    try await pollUntil { session.isBusy() }
    let recovery = Task { await model.recoverView(session, preserving: target.key) }
    try await waitUntil { model.tree == nil && model.loading }
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
    XCTAssertTrue(model.selection.entry?.key.sameEntry(other: target.key) == true)
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
    XCTAssertTrue(model.selection.entry?.key.sameEntry(other: target.key) == true)
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
      try await waitUntil {
        host.layoutSubtreeIfNeeded()
        return !model.loading && model.picture?.bitmap.height == UInt32(model.viewport.height)
          && model.viewport.height == floor(map.bounds.height * window.backingScaleFactor)
      }
      try await Task.sleep(for: .milliseconds(220))
      let bounds = map.bounds
      let viewport = model.viewport
      let builds = model.diagramBuilds
      model.select(try entry("large-file", in: model))
      try await waitUntil { model.selection.region != nil }
      model.prepare(action)
      try await waitUntil { model.pending != nil }
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
    try await waitUntil { model.selection.region != nil }
    model.prepare(.trash)
    try await waitUntil { model.pending != nil }
    model.execute()
    try await waitUntil { model.motion.plan != nil || !model.working }
    let plan = try XCTUnwrap(model.motion.plan)
    XCTAssertEqual(plan.style, .travel)
    let destination = try XCTUnwrap(plan.destination)
    XCTAssertGreaterThan(
      hypot(
        destination.x + destination.width / 2 - plan.source.x - plan.source.width / 2,
        destination.y + destination.height / 2 - plan.source.y - plan.source.height / 2), 80)
    try await waitUntil { !model.working }
    XCTAssertEqual(model.motion.lastStyle, .travel)
    XCTAssertGreaterThanOrEqual(model.motion.lastTicks, 4)
    XCTAssertEqual(model.selection.entry?.displayName, "moved")
  }

  func testInsideTrashTravelsToTheMovedTileBeyondAccessibilityTargets() async throws {
    let model = try await fixture("presentation-trash-late-target")
    model.select(try entry("large-file", in: model))
    try await waitUntil { model.selection.region != nil }
    model.prepare(.trash)
    try await waitUntil { model.pending != nil }
    model.execute()
    try await waitUntil { model.motion.plan != nil || !model.working }
    XCTAssertEqual(try XCTUnwrap(model.motion.plan).style, .travel)
    // This fixture places the destination after 128 small files, outside the 24 targets.
    XCTAssertFalse(model.picture!.targets.contains { $0.relativePath == Data("trash/moved".utf8) })
    try await waitUntil { !model.working }
    XCTAssertEqual(model.motion.lastStyle, .travel)
    XCTAssertEqual(model.selection.entry?.displayName, "moved")
  }
}
