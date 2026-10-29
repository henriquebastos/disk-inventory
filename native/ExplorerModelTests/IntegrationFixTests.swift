import AppKit
import XCTest

@testable import DiskInventory

@MainActor final class IntegrationFixTests: XCTestCase {
  func load(_ scenario: String) async throws -> ExplorerModel {
    let m = ExplorerModel(arguments: ["--fixture-mode", "--scenario", scenario], environment: [:])
    try await waitUntil { !m.loading && !m.replacingSession && m.records != nil }
    return m
  }
  func entry(_ name: String, _ m: ExplorerModel) throws -> EntryRecord {
    try XCTUnwrap(m.outline?.rows.first { $0.entry.displayName == name }?.entry)
  }
  func block(_ m: ExplorerModel) async throws -> Task<MetadataRecord, Error> {
    let s = m.session!
    let key = try entry("large-file", m).key
    try await pollUntil { !s.isBusy() }
    let task = Task.detached { try s.liveMetadata(key: key) }
    try await pollUntil { s.isBusy() }
    return task
  }
  func testRejectedExecutionRecoversCurrentPresentationWithoutRemoval() async throws {
    let m = try await load("trash-inside")
    let s = m.session!
    m.select(try entry("large-file", m))
    m.prepare(.permanentlyDelete)
    try await waitUntil { m.pending != nil }
    let original = m.pending!.action
    let key = m.selected!.key
    // A second real capability moves the target inside the memory inventory after preparation.
    let moved = try await Task.detached {
      let action = try s.prepare(key: key, action: .trash)
      return try s.execute(action: action)
    }.value
    guard case .trashed = moved.mutation else {
      return XCTFail("fixture must actually move the target")
    }
    await m.recoverView(s)
    let validTree = try XCTUnwrap(m.tree)
    let validFrame = try XCTUnwrap(m.picture?.frame)
    _ = try validTree.rows(offset: 0, limit: 1)
    _ = try validFrame.hit(x: 0, y: 0)
    let total = m.records!.status.root.subtreeBytes
    m.execute()
    try await waitUntil { !m.working }
    XCTAssertTrue(m.error?.contains("Operation failed") == true)
    XCTAssertThrowsError(try s.execute(action: original))  // Pin consumed exactly once.
    XCTAssertThrowsError(try validTree.rows(offset: 0, limit: 1))
    let tree = try XCTUnwrap(m.tree)
    XCTAssertFalse(tree === validTree)
    _ = try tree.rows(offset: 0, limit: 1)
    _ = try m.picture!.frame.hit(x: 0, y: 0)
    XCTAssertEqual(m.records!.status.root.subtreeBytes, total)
    let trash = try entry("trash", m)
    let survivors = try await Task.detached {
      try s.children(parent: trash.key, offset: 0, limit: 10).entries
    }.value
    XCTAssertEqual(survivors.map(\.displayName), ["moved"])
    _ = try await Task.detached { try s.liveMetadata(key: survivors[0].key) }.value
  }
  func testFailedReplacementRestoresOldTreeAndFrameWithoutClearingError() async throws {
    let m = try await load("ordinary")
    let old = m.session!
    let focus = m.records!.focus.key
    m.load { throw CocoaError(.fileReadCorruptFile) }
    XCTAssertTrue(m.replacingSession)
    XCTAssertFalse(m.canAct)
    try await waitUntil { !m.replacingSession && !m.loading }
    XCTAssertTrue(m.session === old)
    XCTAssertNotNil(m.error)
    XCTAssertTrue(m.records!.focus.key.sameEntry(other: focus))
    let tree = try XCTUnwrap(m.tree)
    _ = try tree.rows(offset: 0, limit: 256)
    _ = try m.picture!.frame.hit(x: 0, y: 0)
    m.select(try entry("large-file", m))
    try await waitUntil { m.selectedRow != nil }
    XCTAssertTrue(m.canAct)
  }
  func testParentRequestsCoalesceActualQueriesAndDropObsoletePendingWork() async throws {
    let m = try await load("metadata-delay")
    let s = m.session!
    let leaf = try entry("large-file", m)
    m.select(leaf)
    try await waitUntil { m.selectedRow != nil && m.selectionPath != nil }
    let blocker = try await block(m)
    let before = s.selectionQueryCount()
    m.selectParent(leaf)
    try await pollUntil { s.activeCallCount() == 2 }
    for _ in 0..<100 { m.selectParent(leaf) }
    XCTAssertEqual(s.activeCallCount(), 2)
    XCTAssertEqual(s.selectionQueryCount(), before)
    _ = try await blocker.value
    try await waitUntil { m.selected?.parent == nil && m.selectionPath != nil }
    try await Task.sleep(for: .milliseconds(80))
    let executed = s.selectionQueryCount() - before
    print(
      "PARENT_WORK repeated requests=101 actual saved selection queries=\(executed) (includes selected-path publication)"
    )
    XCTAssertLessThanOrEqual(executed, 2)
    let second = try await block(m)
    let baseline = s.selectionQueryCount()
    for _ in 0..<100 { m.selectParent(leaf) }  // Leaf is no longer the selected identity.
    _ = try await second.value
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(s.selectionQueryCount(), baseline)
    m.select(leaf)
    try await waitUntil { m.selectionPath != nil && m.selectedRow != nil }
    let idle = s.selectionQueryCount()
    let coordinator = ContentsTree.Coordinator(m)
    m.working = true
    for _ in 0..<100 {
      XCTAssertTrue(coordinator.key(123))
      m.selectParent(leaf)
    }
    await Task.yield()
    XCTAssertEqual(s.selectionQueryCount(), idle)
    m.working = false
    XCTAssertTrue(m.selected!.key.sameEntry(other: leaf.key))
  }
  func testQueuedParentDoesNotExecuteAfterSelectionOrSessionChanges() async throws {
    for replacement in [false, true] {
      let m = try await load("metadata-delay")
      let s = m.session!
      let leaf = try entry("large-file", m)
      m.select(leaf)
      try await waitUntil { m.selectedRow != nil && m.selectionPath != nil }
      let blocker = try await block(m)
      let before = s.selectionQueryCount()
      m.selectParent(leaf)
      try await pollUntil { s.activeCallCount() == 2 }
      for _ in 0..<100 { m.selectParent(leaf) }
      if replacement {
        m.load { try ExplorerSession.fixture(scenario: "ordinary") }
      } else {
        m.select(try entry("zero-byte", m))
      }
      _ = try await blocker.value
      try await waitUntil {
        !m.loading && !m.replacingSession && m.selectionPath != nil
          || replacement && !m.loading && !m.replacingSession
      }
      try await Task.sleep(for: .milliseconds(100))
      let executed = s.selectionQueryCount() - before
      print("PARENT_OBSOLETE replacement=\(replacement) old-session queries=\(executed)")
      XCTAssertEqual(executed, replacement ? 1 : 2)
      if replacement {
        XCTAssertFalse(m.session === s)
        XCTAssertNotNil(m.tree)
        XCTAssertNil(m.error)
      } else {
        XCTAssertEqual(m.selected?.displayName, "zero-byte")
      }
    }
  }
  func testEmptyDirectoryRightDoesNotExpandOrSelectNextSibling() async throws {
    let m = try await load("presentation")
    let empty = try entry("trash", m)
    m.select(empty)
    try await waitUntil { m.selectedRow != nil }
    let coordinator = ContentsTree.Coordinator(m)
    let table = ContentsTree.Table(frame: .zero)
    table.keyboard = { code in
      let handled = coordinator.key(code)
      XCTAssertTrue(handled)
      return handled
    }
    let arrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
    let right = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: arrow, charactersIgnoringModifiers: arrow, isARepeat: false,
        keyCode: 124))
    let total = m.outline!.total
    table.keyDown(with: right)
    try await Task.sleep(for: .milliseconds(30))
    table.keyDown(with: right)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(m.outline!.total, total)
    XCTAssertFalse(m.outline!.rows.first { $0.entry.key.sameEntry(other: empty.key) }!.expanded)
    XCTAssertTrue(m.selected!.key.sameEntry(other: empty.key))
    // Even an already-expanded empty branch, created through the real core, has no child.
    let tree = m.tree!
    _ = try tree.expand(key: empty.key, expanded: true)
    m.requestRows(0)
    try await waitUntil {
      m.outline!.rows.first { $0.entry.key.sameEntry(other: empty.key) }!.expanded
    }
    table.keyDown(with: right)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(m.selected!.key.sameEntry(other: empty.key))
    let directory = try entry("small-files", m)
    m.select(directory)
    try await waitUntil { m.selectedRow != nil }
    table.keyDown(with: right)
    try await waitUntil { !m.treeEditing }
    table.keyDown(with: right)
    try await waitUntil { m.selected?.kind == .file }
    XCTAssertTrue(m.selected!.parent!.sameEntry(other: directory.key))
  }
  func testHistorySelectionOutsideSliceRestoresVisibleRowWithoutRevealOrScroll() async throws {
    let m = try await load("dix")
    let root = m.records!.focus.key
    let projects = try entry("Projects", m)
    m.expand(projects, expanded: true)
    try await waitUntil { !m.treeEditing }
    m.select(projects)
    try await waitUntil { m.selectedRow != nil && m.selectionPath != nil }
    let row = m.selectedRow!
    m.scrollRow = 1200
    let tree = m.tree!
    let before = try tree.rows(offset: UInt64.max, limit: 1).expandedDirectories
    m.focus(projects.key)
    try await waitUntil { !m.loading }
    m.back()
    try await waitUntil { !m.loading }
    XCTAssertTrue(m.records!.focus.key.sameEntry(other: root))
    XCTAssertTrue(m.tree === tree)
    XCTAssertEqual(m.restoredScrollRow, 1200)
    XCTAssertGreaterThan(m.outline!.offset, 1000)
    XCTAssertEqual(m.selectedRow, row)
    XCTAssertTrue(m.selected!.key.sameEntry(other: projects.key))
    XCTAssertEqual(try tree.rows(offset: UInt64.max, limit: 1).expandedDirectories, before)
    let child = try tree.rows(offset: 1, limit: 1).rows[0].entry
    m.select(child)
    try await waitUntil { m.selectedRow != nil && m.selectionPath != nil }
    m.scrollRow = 0
    m.expand(projects, expanded: false)
    try await waitUntil { !m.treeEditing }
    XCTAssertNil(m.selectedRow)
    m.focus(projects.key)
    try await waitUntil { !m.loading }
    m.back()
    try await waitUntil { !m.loading }
    XCTAssertTrue(m.selected!.key.sameEntry(other: child.key))
    XCTAssertNil(m.selectedRow)
    XCTAssertEqual(m.restoredScrollRow, 0)
    XCTAssertEqual(try tree.rows(offset: 0, limit: 1).expandedDirectories, 0)
  }
}
