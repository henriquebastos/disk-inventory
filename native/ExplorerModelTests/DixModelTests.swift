import AppKit
import Darwin
import SwiftUI
import XCTest

@testable import DiskInventory

@MainActor final class DixModelTests: XCTestCase {
  func load(_ scenario: String = "dix") async throws -> ExplorerModel {
    let model = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", scenario], environment: [:])
    try await waitUntil { model.records != nil && !model.loading && !model.replacingSession }
    return model
  }
  func entry(_ name: String, _ model: ExplorerModel) throws -> EntryRecord {
    try XCTUnwrap(model.outline?.rows.first { $0.entry.displayName == name }?.entry)
  }
  func center(_ hit: DiagramSelection) -> (UInt32, UInt32) {
    (UInt32(hit.rect.x + hit.rect.width / 2), UInt32(hit.rect.y + hit.rect.height / 2))
  }
  func testHoverLeavesPreparedSelectionUntouchedAndClickRevealsWithoutZoom() async throws {
    let model = try await load()
    let root = model.records!.focus.key
    let movie = try entry("Movie.mov", model)
    let target = try XCTUnwrap(
      model.picture?.targets.first { $0.entry.displayName.hasPrefix("asset-") })
    model.select(movie)
    try await waitUntil { model.selection.row != nil }
    model.prepare(.permanentlyDelete)
    try await waitUntil { model.pending != nil }
    let capability = model.pending!.action
    let builds = model.diagramBuilds
    let (x, y) = center(target)
    let start = ContinuousClock.now
    model.point(x, y)
    try await waitUntil { model.hover?.entry.key.sameEntry(other: target.entry.key) == true }
    print("DIX hover async publication=\(start.duration(to:.now)); not paint latency")
    XCTAssertTrue(model.selection.entry!.key.sameEntry(other: movie.key))
    XCTAssertTrue(model.pending?.action === capability)
    XCTAssertEqual(model.diagramBuilds, builds)
    model.cancelConfirmation()
    model.point(x, y, click: true)
    try await waitUntil {
      model.selection.entry?.key.sameEntry(other: target.entry.key) == true
        && model.selection.row != nil
    }
    XCTAssertTrue(model.records!.focus.key.sameEntry(other: root))
    XCTAssertEqual(model.outline!.total, 2003)
    XCTAssertTrue(
      model.outline!.rows.contains {
        $0.entry.key.sameEntry(other: target.entry.key) && $0.depth == 1
      })
    XCTAssertEqual(model.diagramBuilds, builds)
  }
  func testDisclosureZoomBreadcrumbAndAncestorRestoreContext() async throws {
    let model = try await load()
    let root = model.records!.focus.key
    let projects = try entry("Projects", model)
    let tiny = try entry("Tiny files", model)
    model.expand(projects, expanded: true)
    try await waitUntil { !model.treeEditing && model.outline!.total == 2003 }
    XCTAssertTrue(model.records!.focus.key.sameEntry(other: root))
    model.scrolled(toRow: 1200)
    let original = model.tree
    model.focus(tiny.key)
    try await waitUntil { !model.loading }
    let notes = try entry("Notes", model)
    model.focus(notes.key)
    try await waitUntil { !model.loading }
    let small = try entry("four-KiB.txt", model)
    let rect = try XCTUnwrap(try model.picture!.frame.region(key: small.key))
    XCTAssertGreaterThan(rect.width * rect.height, 1000)
    model.focusParent()
    try await waitUntil { !model.loading }
    XCTAssertTrue(model.records!.focus.key.sameEntry(other: tiny.key))
    model.focus(root)
    try await waitUntil { !model.loading }
    XCTAssertTrue(model.tree === original)
    XCTAssertEqual(model.outline!.total, 2003)
    XCTAssertEqual(model.restoredScrollRow, 1200)
    XCTAssertLessThanOrEqual(model.outline!.rows.count, 256)
    XCTAssertEqual(model.history.count, 2)  // Both visited descendant contexts remain restorable.
  }
  func testHistoryCapPayloadAndSessionAndMutationInvalidation() async throws {
    let model = try await load("dix-deep")
    for _ in 0..<70 {
      let child = try XCTUnwrap(model.outline?.rows.first { $0.entry.kind == .directory }?.entry)
      let leaf = try XCTUnwrap(model.picture?.targets.first)
      model.select(leaf.entry)
      try await waitUntil { model.selection.row != nil }
      model.focus(child.key)
      try await waitUntil { !model.loading }
    }
    XCTAssertEqual(model.history.count, 64)
    let trees = model.history.map(\.tree)
    let payload = try await Task.detached {
      try trees.reduce(UInt64(0)) {
        $0 + (try $1.rows(offset: UInt64.max, limit: 1).expansionPayloadBytes)
      }
    }.value
    XCTAssertLessThan(payload, 2 * 1024 * 1024)
    print(
      "DIX64-context expansion payload=\(payload) bytes; excludes allocator and shared inventory")
    model.load { try ExplorerSession.fixture(scenario: "dix") }
    try await waitUntil { !model.replacingSession && !model.loading }
    XCTAssertTrue(model.history.isEmpty)
    let tiny = try entry("Tiny files", model)
    model.focus(tiny.key)
    try await waitUntil { !model.loading }
    let notes = try entry("Notes", model)
    model.focus(notes.key)
    try await waitUntil { !model.loading }
    let oldFrame = model.picture!.frame
    model.select(try entry("four-KiB.txt", model))
    model.prepare(.permanentlyDelete)
    try await waitUntil { model.pending != nil }
    model.execute()
    try await waitUntil { !model.working }
    XCTAssertTrue(model.history.isEmpty)
    XCTAssertFalse(model.outline!.rows.contains { $0.entry.displayName == "four-KiB.txt" })
    XCTAssertThrowsError(try oldFrame.hit(x: 0, y: 0))
  }
  func testStaleHoverRevealAndFrameCannotPublishAcrossSessionReplacement() async throws {
    let model = try await load("metadata-delay")
    let old = model.session!
    let movie = try entry("large-file", model)
    let target = try XCTUnwrap(model.picture?.targets.first)
    let blocked = Task.detached { try old.liveMetadata(key: movie.key) }
    try await pollUntil { old.isBusy() }
    model.select(target.entry)
    let (x, y) = center(target)
    model.point(x, y)
    let rebuilding = Task { await model.updateView(focus: movie.parent!) }
    model.load { try ExplorerSession.fixture(scenario: "ordinary") }
    try await waitUntil { !model.replacingSession && !model.loading }
    _ = try await blocked.value
    await rebuilding.value
    await settled(model)
    XCTAssertFalse(model.session === old)
    XCTAssertNotNil(model.tree)
    XCTAssertNil(model.error)
    XCTAssertNil(model.hover)
    XCTAssertNil(model.selection.entry)
    XCTAssertNil(model.selection.row)
    XCTAssertTrue(model.history.isEmpty)
    XCTAssertNotNil(try entry("large-file", model))
  }
  func testNativeHundredThousandRowsAreVirtual() async throws {
    var before = rusage()
    getrusage(RUSAGE_SELF, &before)
    let start = ContinuousClock.now
    let model = try await load("dix-wide")
    let loadTime = start.duration(to: .now)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: ContentsTree(model: model))
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    func table(in view: NSView) -> ContentsTree.Table? {
      if let t = view as? ContentsTree.Table { return t }
      return view.subviews.compactMap { table(in: $0) }.first
    }
    let table = try XCTUnwrap(table(in: host))
    let projects = try entry("Projects", model)
    let expanded = ContinuousClock.now
    model.expand(projects, expanded: true)
    try await pollUntil { !model.treeEditing && table.numberOfRows == 100003 }
    table.scrollRowToVisible(99999)
    try await waitUntil { (model.outline?.offset ?? 0) > 99000 }
    XCTAssertLessThanOrEqual(model.outline!.rows.count, 256)
    XCTAssertLessThan(table.createdCells, 128)
    XCTAssertLessThan(model.outline!.visits, 1024)
    let expansionTime = expanded.duration(to: .now)
    var after = rusage()
    getrusage(RUSAGE_SELF, &after)
    let bitmap = model.picture!.bitmap
    print(
      "DIX100k load+publication=\(loadTime) expand+AppKit rows+tail=\(expansionTime) cells=\(table.createdCells) rows=\(model.outline!.rows.count) peakRSS=\(after.ru_maxrss) baselinePeak=\(before.ru_maxrss) coreRetainedPayload=\(bitmap.retainedPayloadBytes) surfacePayload=\(bitmap.surfacePayloadBytes) transferRGBA=\(bitmap.rgba.count) tiles=\(bitmap.tiles) visits=\(bitmap.childVisits); not compositor latency"
    )
  }
  func testNativeDatasourceCallbacksUseCachedRowsWhileBridgeIsBusy() async throws {
    let model = try await load("metadata-delay")
    let session = model.session!
    let key = try entry("large-file", model).key
    let table = ContentsTree.Table(frame: .zero)
    let datasource = ContentsTree.Coordinator(model)
    table.dataSource = datasource
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
    // A valid empty tail slice forces the callback to schedule, not synchronously fetch, row zero.
    model.outline = try model.tree!.rows(offset: model.outline!.total, limit: 256)
    let total = Int(model.outline!.total)
    try await withThrowingTaskGroup(of: MetadataRecord.self) { group in
      group.addTask { try session.liveMetadata(key: key) }
      try await pollUntil { session.isBusy() }
      let callback = ContinuousClock.now
      XCTAssertEqual(datasource.numberOfRows(in: table), total)
      _ = datasource.tableView(table, viewFor: table.tableColumns[0], row: 0)
      let elapsed = callback.duration(to: .now)
      XCTAssertTrue(session.isBusy(), "cached callback must not wait for the locked bridge")
      XCTAssertLessThan(elapsed, .milliseconds(100))
      print("CACHED_DATASOURCE callback=\(elapsed) while same-session metadata fixture is busy")
      _ = try await group.next()
    }  // Structured task scope also joins the blocking call on a thrown assertion/setup error.
  }
  func testDownsampledPointerMatchesRustOwnerAndAppKitDrawUsesCachedImage() async throws {
    var baseline = rusage()
    getrusage(RUSAGE_SELF, &baseline)
    let model = try await load()
    model.resize(CGSize(width: 8000, height: 4000))
    try await waitUntil { model.picture!.bitmap.width > 2000 && !model.loading }
    let picture = model.picture!
    let target = try XCTUnwrap(picture.targets.first)
    XCTAssertLessThanOrEqual(Int(picture.bitmap.width) * Int(picture.bitmap.height), 4_000_000)
    let view = DiagramView.MapView(frame: NSRect(x: 0, y: 0, width: 1000, height: 500))
    view.model = model
    view.updatePicture()
    let bounds = view.rect(target.rect)
    let point = view.convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
    let event = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    view.pointer(event, click: false)
    try await waitUntil { model.hover?.entry.key.sameEntry(other: target.entry.key) == true }
    let builds = model.diagramBuilds
    let rep = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 500, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let drawStart = ContinuousClock.now
    view.draw(view.bounds)
    let drawDuration = drawStart.duration(to: .now)
    NSGraphicsContext.restoreGraphicsState()
    XCTAssertEqual(view.drawProbe?.draws, 1)
    XCTAssertEqual(model.diagramBuilds, builds)
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    print(
      "DIX max-raster RGBA=\(picture.bitmap.rgba.count) coreRetainedPayload=\(picture.bitmap.retainedPayloadBytes) baselinePeakRSS=\(baseline.ru_maxrss) peakRSS=\(usage.ru_maxrss); includes real bridge transfer, CGImage and offscreen draw"
    )
    print(
      "DIX AppKit offscreen draw=\(drawDuration); scaled raster=\(picture.bitmap.width)x\(picture.bitmap.height); not display completion"
    )
  }
  func testOffscreenAppKitTrackingKeyboardAndDisclosureCallbacks() async throws {
    let model = try await load("presentation")
    let root = model.records!.focus.key
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: ContentsTree(model: model))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    func table(in v: NSView) -> ContentsTree.Table? {
      if let t = v as? ContentsTree.Table { return t }
      return v.subviews.compactMap { table(in: $0) }.first
    }
    let table = try XCTUnwrap(table(in: host))
    let coordinator = try XCTUnwrap(table.delegate as? ContentsTree.Coordinator)
    let parent = try entry("small-files", model)
    let parentRow = try XCTUnwrap(
      model.outline?.rows.firstIndex { $0.entry.key.sameEntry(other: parent.key) })
    let initial = table.numberOfRows
    func disclosure() -> NSButton {
      (coordinator.tableView(table, viewFor: table.tableColumns[0], row: parentRow)
        as! ContentsTree.Cell).disclosure
    }
    disclosure().performClick(nil)
    try await pollUntil { table.numberOfRows == initial + 128 && !model.treeEditing }
    XCTAssertTrue(model.records!.focus.key.sameEntry(other: root))
    let parentView = try XCTUnwrap(coordinator.tableView(table, rowViewForRow: parentRow))
    XCTAssertTrue(parentView.isAccessibilityEnabled())
    XCTAssertTrue(parentView.isAccessibilityExpanded())
    XCTAssertEqual(parentView.accessibilityDisclosureLevel(), 0)
    table.selectRowIndexes(IndexSet(integer: parentRow + 1), byExtendingSelection: false)
    try await waitUntil { model.selection.row == parentRow + 1 }
    func key(_ code: UInt16) throws {
      let e = try XCTUnwrap(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil,
          characters: String(UnicodeScalar(code == 125 ? 0xf701 : 0xf702)!),
          charactersIgnoringModifiers: String(UnicodeScalar(code == 125 ? 0xf701 : 0xf702)!),
          isARepeat: false, keyCode: code))
      table.keyDown(with: e)
    }
    try key(125)
    try await waitUntil { model.selection.entry?.displayName == "small-01" }
    try key(123)
    try await waitUntil {
      model.selection.entry?.displayName == "small-files" && model.selection.row == parentRow
    }
    model.focus(parent.key)
    try await waitUntil { !model.loading }
    model.focusParent()
    try await pollUntil { !model.loading && table.numberOfRows == initial + 128 }
    XCTAssertTrue(disclosure().isEnabled)
    disclosure().performClick(nil)
    try await pollUntil { table.numberOfRows == initial && !model.treeEditing }
    let mapHost = NSHostingView(rootView: DiagramView(model: model))
    window.contentView = mapHost
    mapHost.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    func map(in v: NSView) -> DiagramView.MapView? {
      if let m = v as? DiagramView.MapView { return m }
      return v.subviews.compactMap { map(in: $0) }.first
    }
    let view = try XCTUnwrap(map(in: mapHost))
    try await Task.sleep(for: .milliseconds(250))
    try await waitUntil { !model.loading }
    let target = try XCTUnwrap(model.picture?.targets.first)
    let rect = view.rect(target.rect)
    let location = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    let entered = try XCTUnwrap(
      NSEvent.enterExitEvent(
        with: .mouseEntered, location: location, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 1,
        userData: nil))
    view.mouseEntered(with: entered)
    try await waitUntil { model.hover?.entry.key.sameEntry(other: target.entry.key) == true }
    XCTAssertTrue(model.selection.entry?.key.sameEntry(other: parent.key) == true)
    view.mouseExited(with: entered)
    XCTAssertNil(model.hover)
    let moved = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 0, pressure: 0)
    )
    view.mouseMoved(with: moved)
    try await waitUntil { model.hover?.entry.key.sameEntry(other: target.entry.key) == true }

  }

  func testHistoryRestoresNativeTopRowRatherThanOnlyMakingItVisible() async throws {
    let model = try await load("presentation")
    let root = model.records!.focus.key
    let directory = try entry("small-files", model)
    model.expand(directory, expanded: true)
    try await waitUntil { !model.treeEditing }
    model.select(directory)
    try await waitUntil { model.selection.row != nil }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: ContentsTree(model: model))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    func table(in view: NSView) -> ContentsTree.Table? {
      if let table = view as? ContentsTree.Table { return table }
      return view.subviews.compactMap { table(in: $0) }.first
    }
    let table = try XCTUnwrap(table(in: host))
    let scroll = try XCTUnwrap(table.enclosingScrollView)
    let coordinator = try XCTUnwrap(table.delegate as? ContentsTree.Coordinator)
    let total = table.numberOfRows
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
    scroll.reflectScrolledClipView(scroll.contentView)
    try await waitUntil { model.scrollRow > 20 }
    let savedRow = model.scrollRow
    model.focus(directory.key)
    try await pollUntil { !model.loading && table.numberOfRows == Int(directory.childCount) }
    model.focusParent()
    try await pollUntil {
      !model.loading && table.numberOfRows == total
        && coordinator.scrollSerial == model.scrollSerial
    }
    XCTAssertTrue(model.records!.focus.key.sameEntry(other: root))
    XCTAssertEqual(model.restoredScrollRow, Int(savedRow))
    let expected = table.rect(ofRow: Int(savedRow)).minY
    let top = scroll.contentView.bounds.minY + scroll.contentView.contentInsets.top
    print("NATIVE_SCROLL savedRow=\(savedRow) expectedTop=\(expected) actualTop=\(top)")
    XCTAssertEqual(top, expected, accuracy: 0.5)
    XCTAssertEqual(model.scrollRow, savedRow)
    XCTAssertTrue(model.selection.entry!.key.sameEntry(other: directory.key))
    XCTAssertFalse(table.visibleRect.intersects(table.rect(ofRow: 0)))
  }

  func testShortTreeRestoreKeepsFirstRowBelowNativeHeader() async throws {
    let model = try await load()
    let tiny = try entry("Tiny files", model)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: ContentsTree(model: model))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    func table(in view: NSView) -> ContentsTree.Table? {
      if let table = view as? ContentsTree.Table { return table }
      return view.subviews.compactMap { table(in: $0) }.first
    }
    let table = try XCTUnwrap(table(in: host))
    let scroll = try XCTUnwrap(table.enclosingScrollView)
    let coordinator = try XCTUnwrap(table.delegate as? ContentsTree.Coordinator)
    model.focus(tiny.key)
    try await pollUntil {
      !model.loading && table.numberOfRows == 1 && coordinator.scrollSerial == model.scrollSerial
    }
    host.layoutSubtreeIfNeeded()
    let cell = try XCTUnwrap(
      table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ContentsTree.Cell)
    let header = try XCTUnwrap(table.headerView)
    let labelRect = scroll.convert(cell.name.bounds, from: cell.name)
    let headerRect = scroll.convert(header.bounds, from: header)
    print(
      "SHORT_TREE label=\(labelRect) header=\(headerRect) inset=\(scroll.contentView.contentInsets.top)"
    )
    XCTAssertEqual(cell.name.stringValue, "Notes")
    XCTAssertFalse(labelRect.intersects(headerRect))
    XCTAssertGreaterThanOrEqual(labelRect.minY, headerRect.maxY)
  }

  func testHistoryRebuildsAfterExternalRevisionChange() async throws {
    let model = try await load()
    let root = model.records!.focus.key
    let old = model.tree
    let tiny = try entry("Tiny files", model)
    model.focus(tiny.key)
    try await waitUntil { !model.loading }
    let session = model.session!
    _ = try await Task.detached { try session.refreshDirectory(key: root) }.value
    model.focusParent()
    try await waitUntil { !model.loading }
    XCTAssertTrue(model.records!.focus.key.sameEntry(other: root))
    XCTAssertFalse(model.tree === old)
    XCTAssertEqual(model.outline!.total, 3)
    XCTAssertNil(model.error)
  }

  func testAggregatePixelExplainsRecordedBytesWithoutCreatingAnActionTarget() async throws {
    let model = try await load()
    let total = model.records!.focus.subtreeBytes
    model.resize(CGSize(width: 1, height: 1))
    try await waitUntil { model.picture?.bitmap.width == 1 && !model.loading }
    model.point(0, 0, click: true)
    try await waitUntil { model.selection.aggregate != nil }
    XCTAssertNil(model.selection.entry)
    XCTAssertFalse(model.canAct)
    XCTAssertEqual(model.selection.aggregateText, model.numbers.storage(total))
    XCTAssertNil(model.prepare(.permanentlyDelete))
    XCTAssertNil(model.pending)
  }

  func testAccessibilityTargetsDoNotRetainObsoleteFrames() async throws {
    let model = try await load()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = DiagramView.MapView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    view.model = model
    window.contentView = view
    view.viewDidChangeBackingProperties()
    try await waitUntil {
      model.picture!.bitmap.width == UInt32(600 * window.backingScaleFactor) && !model.loading
    }
    view.updatePicture()
    weak var obsolete = model.picture?.frame
    let oldTarget = try XCTUnwrap(view.elements.first)
    window.setContentSize(NSSize(width: 500, height: 400))
    view.layoutSubtreeIfNeeded()
    view.viewDidChangeBackingProperties()
    try await waitUntil {
      model.picture!.bitmap.width == UInt32(500 * window.backingScaleFactor) && !model.loading
    }
    view.updatePicture()
    try await waitUntil { obsolete == nil }
    XCTAssertFalse(oldTarget.accessibilityPerformPress())
    XCTAssertNil(model.selection.entry)
  }

  private func assertSelectedRow(
    _ model: ExplorerModel, matches key: EntryKey, expected: Int? = nil,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let row = try XCTUnwrap(model.selection.row, file: file, line: line)
    if let expected { XCTAssertEqual(row, expected, file: file, line: line) }
    let tree = try XCTUnwrap(model.tree)
    let actual = try await Task.detached {
      try tree.rows(offset: UInt64(row), limit: 1).rows.first?.entry.key
    }.value
    XCTAssertTrue(actual?.sameEntry(other: key) == true, file: file, line: line)
    XCTAssertTrue(model.selection.entry?.key.sameEntry(other: key) == true, file: file, line: line)
  }
  func testDisclosurePreservesUnaffectedMovieSelection() async throws {
    let model = try await load()
    let movie = try entry("Movie.mov", model)
    let tiny = try entry("Tiny files", model)
    model.select(movie)
    try await waitUntil { model.selection.row != nil }
    let original = model.selection.row!
    let builds = model.diagramBuilds
    for expanded in [true, false] {
      model.expand(tiny, expanded: expanded)
      try await waitUntil { !model.treeEditing }
      try await assertSelectedRow(model, matches: movie.key, expected: original)
      XCTAssertTrue(model.canAct)
    }
    XCTAssertEqual(model.diagramBuilds, builds)
  }
  func testDisclosureRecomputesMovieRowAfterPrecedingSiblingChanges() async throws {
    let model = try await load()
    let movie = try entry("Movie.mov", model)
    let projects = try entry("Projects", model)
    model.select(movie)
    try await waitUntil { model.selection.row != nil }
    let original = model.selection.row!
    model.expand(projects, expanded: true)
    try await waitUntil { !model.treeEditing }
    try await assertSelectedRow(model, matches: movie.key, expected: original + 2000)
    model.expand(projects, expanded: false)
    try await waitUntil { !model.treeEditing }
    try await assertSelectedRow(model, matches: movie.key, expected: original)
  }
  func testDisclosureHidesSelectedDescendantWithoutReopeningOrRetargeting() async throws {
    let model = try await load()
    let projects = try entry("Projects", model)
    let tiny = try entry("Tiny files", model)
    let leaf = try XCTUnwrap(
      model.picture?.targets.first { $0.entry.displayName.hasPrefix("asset-") })
    model.select(leaf.entry)
    try await waitUntil { model.selection.row != nil }
    model.expand(projects, expanded: false)
    try await waitUntil { !model.treeEditing }
    XCTAssertEqual(model.outline!.total, 3)
    XCTAssertNil(model.selection.row)
    XCTAssertTrue(model.selection.entry!.key.sameEntry(other: leaf.entry.key))
    XCTAssertFalse(model.outline!.rows.first { $0.entry.displayName == "Projects" }!.expanded)
    model.expand(tiny, expanded: true)
    try await waitUntil { !model.treeEditing }
    XCTAssertEqual(model.outline!.total, 4)
    XCTAssertNil(model.selection.row)
    XCTAssertTrue(model.selection.entry!.key.sameEntry(other: leaf.entry.key))
    model.expand(projects, expanded: true)
    try await waitUntil { !model.treeEditing }
    try await assertSelectedRow(model, matches: leaf.entry.key)
  }
  func testDisclosureResultsRejectNewerSelectionSessionAndMutation() async throws {
    for change in ["selection", "session", "mutation"] {
      let model = try await load("metadata-delay")
      let session = model.session!
      let oldTree = model.tree!
      let directory = try entry("small-files", model)
      let delayed = try entry("large-file", model)
      let root = model.records!.focus
      model.select(directory)
      try await waitUntil { model.selection.row != nil }
      let blocker = Task.detached { try session.liveMetadata(key: delayed.key) }
      try await pollUntil { session.isBusy() }
      model.expand(directory, expanded: true)
      // Let the real tree worker queue behind the fixture's metadata lock.
      await Task.yield()
      switch change {
      case "selection": model.select(root)  // Root selection does not request a reveal.
      case "session": model.load { try ExplorerSession.fixture(scenario: "ordinary") }
      default: model.refresh()
      }
      _ = try await blocker.value
      try await waitUntil {
        !model.treeEditing && !model.replacingSession && !model.working && !model.loading
      }
      XCTAssertNil(model.selection.row, change)
      if change == "selection" {
        XCTAssertTrue(model.selection.entry?.key.sameEntry(other: root.key) == true)
        XCTAssertFalse(model.canAct)
      } else {
        XCTAssertNil(model.selection.entry, change)
        XCTAssertFalse(model.tree === oldTree, change)
        XCTAssertNotNil(model.tree, change)
        XCTAssertNil(model.error, change)
        if change == "session" { XCTAssertFalse(model.session === session) }
      }
      if change == "mutation" { XCTAssertThrowsError(try oldTree.rows(offset: 0, limit: 1)) }
    }
  }

  func testUsageBarPercentRoundsHalfUpKeepsSliverAndEmptiesZeroOrUnknown() {
    XCTAssertEqual(usageBarPercent(0, of: 1000), 0)
    XCTAssertEqual(usageBarPercent(5, of: 0), 0)
    XCTAssertEqual(usageBarPercent(1, of: 1000), 2)
    XCTAssertEqual(usageBarPercent(24, of: 1000), 2)
    XCTAssertEqual(usageBarPercent(25, of: 1000), 3)
    XCTAssertEqual(usageBarPercent(334, of: 1000), 33)
    XCTAssertEqual(usageBarPercent(335, of: 1000), 34)
    XCTAssertEqual(usageBarPercent(1000, of: 1000), 100)
    XCTAssertEqual(usageBarPercent(3000, of: 1000), 100)
    XCTAssertEqual(usageBarPercent(.max, of: .max), 100)
    XCTAssertEqual(usageBarPercent(.max / 2, of: .max), 50)
    // 2^60 + 1 bytes of 2^61 + 2: exactly 50%, beyond Double's integer precision.
    XCTAssertEqual(usageBarPercent(1 << 60 + 1, of: 1 << 61 + 2), 50)
    // 33.5% exactly, then one byte less; Double would round both counts to 67 * 2^53.
    XCTAssertEqual(usageBarPercent(67 << 53, of: 200 << 53), 34)
    XCTAssertEqual(usageBarPercent(67 << 53 - 1, of: 200 << 53), 33)
  }

  func testTreeRowsDrawMapSwatchesAndFocusRelativeUsageBars() async throws {
    let model = try await load()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: ContentsTree(model: model))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    func table(in view: NSView) -> ContentsTree.Table? {
      if let table = view as? ContentsTree.Table { return table }
      return view.subviews.compactMap { table(in: $0) }.first
    }
    let table = try XCTUnwrap(table(in: host))
    model.expand(try entry("Tiny files", model), expanded: true)
    try await pollUntil { !model.treeEditing && table.numberOfRows == 4 }
    // Expansion reloads rows after the initial host layout. Lay out the current row views.
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    func cell(_ name: String) throws -> ContentsTree.Cell {
      let row = try XCTUnwrap(model.outline?.rows.firstIndex { $0.entry.displayName == name })
      return try XCTUnwrap(
        table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ContentsTree.Cell)
    }
    func rgb(_ color: NSColor) -> UInt32 {
      let c = color.usingColorSpace(.sRGB)!
      return UInt32((c.redComponent * 255).rounded()) << 16
        | UInt32((c.greenComponent * 255).rounded()) << 8
        | UInt32((c.blueComponent * 255).rounded())
    }
    // Same base colors as Rust's map file tiles (blue video); directories use system gray.
    let movie = try cell("Movie.mov")
    XCTAssertFalse(movie.swatch.directory)
    XCTAssertEqual(rgb(movie.swatch.color), 0x4f8ac6)
    for name in ["Projects", "Tiny files", "Notes"] {
      XCTAssertTrue(try cell(name).swatch.directory, name)
      XCTAssertTrue(try cell(name).swatch.color == NSColor.systemGray, name)
    }
    // 67,108,864 and 69,636,096 of 136,769,536 focus bytes; 20,480 bytes keep the sliver.
    XCTAssertEqual(movie.bar.percent, 49)
    XCTAssertEqual(try cell("Projects").bar.percent, 51)
    XCTAssertEqual(try cell("Tiny files").bar.percent, 2)
    XCTAssertEqual(try cell("Notes").bar.percent, 2)
    XCTAssertFalse(movie.swatch.isAccessibilityElement())
    XCTAssertFalse(movie.bar.isAccessibilityElement())
    XCTAssertFalse(movie.bar.emphasized)
    movie.backgroundStyle = .emphasized
    XCTAssertTrue(movie.bar.emphasized)
    // Row publication can create this cell after the host's initial layout pass.
    table.layoutSubtreeIfNeeded()
    movie.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(movie.bounds.width, 0)
    XCTAssertGreaterThan(movie.bar.frame.width, 0)
    XCTAssertLessThanOrEqual(movie.name.frame.maxX, movie.bar.frame.minX)
    XCTAssertLessThanOrEqual(movie.bar.frame.maxX, movie.bounds.width)
    let focus = model.records!.focus
    XCTAssertEqual(focus.subtreeBytes, 136_769_536)
  }

  func testUnknownAllocationRowKeepsAnEmptyUsageBar() async throws {
    let model = try await load("unknown-allocation")
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: ContentsTree(model: model))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    model.refresh()
    try await waitUntil { model.records?.status.stale == true && !model.working }
    func table(in view: NSView) -> ContentsTree.Table? {
      if let table = view as? ContentsTree.Table { return table }
      return view.subviews.compactMap { table(in: $0) }.first
    }
    let table = try XCTUnwrap(table(in: host))
    host.layoutSubtreeIfNeeded()
    let row = try XCTUnwrap(model.outline?.rows.firstIndex { $0.entry.displayName == "unknown-a" })
    let unknown = model.outline!.rows[row].entry
    XCTAssertEqual(unknown.subtreeBytes, 0)
    XCTAssertGreaterThan(unknown.allocatedBytes, 0)
    let cell = try XCTUnwrap(
      table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ContentsTree.Cell)
    XCTAssertEqual(cell.bar.percent, 0)
    XCTAssertFalse(cell.swatch.directory)
  }
}
