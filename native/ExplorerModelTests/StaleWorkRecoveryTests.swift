import AppKit
import XCTest

@testable import DiskInventory

/// Blocks the main actor, so that no continuation runs, until no bridge call has run or waited
/// for 100 ms. Fails after 8 s.
@MainActor private func blockMainActorUntilBridgeIdle(_ session: ExplorerSession) {
  let deadline = Date().addingTimeInterval(8)
  var idleSince: Date?
  while Date() < deadline {
    if session.activeCallCount() > 0 {
      idleSince = nil
    } else if let since = idleSince {
      if Date().timeIntervalSince(since) > 0.1 { return }
    } else {
      idleSince = Date()
    }
    usleep(1000)
  }
  XCTFail("a bridge call still runs after 8 s")
}

@MainActor final class StaleWorkRecoveryTests: XCTestCase {
  func testRejectedExecutionRecoversCurrentPresentationWithoutRemoval() async throws {
    let m = try await fixtureModel("trash-inside")
    let s = m.session!
    m.select(try entry("large-file", in: m))
    m.prepare(.permanentlyDelete)
    try await waitUntil { m.pending != nil }
    let original = m.pending!.action
    let key = m.selection.entry!.key
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
    let trash = try entry("trash", in: m)
    let survivors = try await Task.detached {
      try s.children(parent: trash.key, offset: 0, limit: 10).entries
    }.value
    XCTAssertEqual(survivors.map(\.displayName), ["moved"])
    _ = try await Task.detached { try s.liveMetadata(key: survivors[0].key) }.value
  }
  /// A Delete, Trash or Refresh changes the Rust revision at the end of its call. The model
  /// replaces its tree only when the operation's completion runs on the main actor, so a tree
  /// request that runs in between fails with the obsolete-revision error. A direct Refresh
  /// call, which the model is not told about, makes that moment without a race.
  func testTreeAnswersOfAnObsoleteRevisionSetNoError() async throws {
    let m = try await fixtureModel("operation-skip")
    let s = m.session!
    let library = try entry("Library", in: m)
    _ = try await Task.detached { try s.refreshDirectory(key: library.key) }.value
    XCTAssertThrowsError(try m.tree!.rows(offset: 0, limit: 1), "the shown tree is obsolete")
    m.select(library)
    m.requestRows(0)
    await settled(m)
    XCTAssertNil(m.error, "the reveal and the row page of the obsolete tree are dropped")
    await m.recoverView(s)
    XCTAssertNil(m.error)
    _ = try m.tree!.rows(offset: 0, limit: 1)
  }
  /// A resize during a Delete starts a rebuild that reuses the old tree. If its build ends
  /// during the recovery's candidate lookup, it must not publish that tree again: the recovery
  /// would reuse it and fail, and the tree would stay dead. The test blocks the main actor until
  /// the build has ended, so its result runs right after the start of the recovery.
  func testRebuildStartedBeforeRecoveryDoesNotRepublishTheOldTree() async throws {
    let m = try await fixtureModel("metadata-delay")
    defer { m.shutdown() }
    let s = m.session!
    let old = try XCTUnwrap(m.tree)
    let small = try entry("small-files", in: m)
    // The revision changes and the model is not told, as at the end of a Delete.
    _ = try await Task.detached { try s.refreshDirectory(key: small.key) }.value
    let blocker = try await holdBridge(m)
    m.resize(CGSize(width: m.viewport.width + 7, height: m.viewport.height))
    // The rebuild's first call waits behind the held lock.
    try await pollUntil { s.activeCallCount() == 2 }
    blockMainActorUntilBridgeIdle(s)
    await m.recoverView(s)
    _ = try await blocker.value
    await settled(m)
    XCTAssertNil(m.error)
    XCTAssertFalse(m.tree === old, "the recovery built a new tree")
    m.expand(small, expanded: true)
    try await waitUntil { !m.treeEditing }
    m.requestRows(0)
    await settled(m)
    XCTAssertNil(m.error)
    XCTAssertTrue(
      m.outline?.rows.contains { $0.entry.displayName == "small-00" } == true,
      "the new tree expands")
  }
  func testTreeErrorOfTheCurrentRevisionShows() async throws {
    let m = try await fixtureModel("dix")
    m.expand(try entry("Movie.mov", in: m), expanded: true)
    try await waitUntil { !m.treeEditing }
    XCTAssertEqual(m.error, #"InvalidInput(message: "only directories expand")"#)
  }
  func testFailedReplacementRestoresOldTreeAndFrameWithoutClearingError() async throws {
    let m = try await fixtureModel("ordinary")
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
    m.select(try entry("large-file", in: m))
    try await waitUntil { m.selection.row != nil }
    XCTAssertTrue(m.canAct)
  }
  func testParentRequestsCoalesceActualQueriesAndDropObsoletePendingWork() async throws {
    let m = try await fixtureModel("metadata-delay")
    let s = m.session!
    let leaf = try entry("large-file", in: m)
    m.select(leaf)
    try await waitUntil { m.selection.row != nil && m.selection.path != nil }
    let blocker = try await holdBridge(m)
    let before = s.selectionQueryCount()
    m.selectParent(leaf)
    try await pollUntil { s.activeCallCount() == 2 }
    for _ in 0..<100 { m.selectParent(leaf) }
    XCTAssertEqual(s.activeCallCount(), 2)
    XCTAssertEqual(s.selectionQueryCount(), before)
    _ = try await blocker.value
    try await waitUntil { m.selection.entry?.parent == nil && m.selection.path != nil }
    await settled(m)
    let executed = s.selectionQueryCount() - before
    print(
      "PARENT_WORK repeated requests=101 actual saved selection queries=\(executed) (includes selected-path publication)"
    )
    XCTAssertLessThanOrEqual(executed, 2)
    let second = try await holdBridge(m)
    let baseline = s.selectionQueryCount()
    for _ in 0..<100 { m.selectParent(leaf) }  // Leaf is no longer the selected identity.
    _ = try await second.value
    await settled(m)
    XCTAssertEqual(s.selectionQueryCount(), baseline)
    m.select(leaf)
    try await waitUntil { m.selection.path != nil && m.selection.row != nil }
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
    XCTAssertTrue(m.selection.entry!.key.sameEntry(other: leaf.key))
  }
  func testQueuedParentDoesNotExecuteAfterSelectionOrSessionChanges() async throws {
    for replacement in [false, true] {
      let m = try await fixtureModel("metadata-delay")
      let s = m.session!
      let leaf = try entry("large-file", in: m)
      m.select(leaf)
      try await waitUntil { m.selection.row != nil && m.selection.path != nil }
      let blocker = try await holdBridge(m)
      let before = s.selectionQueryCount()
      m.selectParent(leaf)
      try await pollUntil { s.activeCallCount() == 2 }
      for _ in 0..<100 { m.selectParent(leaf) }
      if replacement {
        m.load { try ExplorerSession.fixture(scenario: "ordinary") }
      } else {
        m.select(try entry("zero-byte", in: m))
      }
      _ = try await blocker.value
      try await waitUntil {
        !m.loading && !m.replacingSession && m.selection.path != nil
          || replacement && !m.loading && !m.replacingSession
      }
      await settled(m)
      let executed = s.selectionQueryCount() - before
      print("PARENT_OBSOLETE replacement=\(replacement) old-session queries=\(executed)")
      XCTAssertEqual(executed, replacement ? 1 : 2)
      if replacement {
        XCTAssertFalse(m.session === s)
        XCTAssertNotNil(m.tree)
        XCTAssertNil(m.error)
      } else {
        XCTAssertEqual(m.selection.entry?.displayName, "zero-byte")
      }
    }
  }
  func testEmptyDirectoryRightDoesNotExpandOrSelectNextSibling() async throws {
    let m = try await fixtureModel("presentation")
    let empty = try entry("trash", in: m)
    m.select(empty)
    try await waitUntil { m.selection.row != nil }
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
    await settled(m)
    table.keyDown(with: right)
    await settled(m)
    XCTAssertEqual(m.outline!.total, total)
    XCTAssertFalse(m.outline!.rows.first { $0.entry.key.sameEntry(other: empty.key) }!.expanded)
    XCTAssertTrue(m.selection.entry!.key.sameEntry(other: empty.key))
    // Even an already-expanded empty branch, created through the real core, has no child.
    let tree = m.tree!
    _ = try tree.expand(key: empty.key, expanded: true)
    m.requestRows(0)
    try await waitUntil {
      m.outline!.rows.first { $0.entry.key.sameEntry(other: empty.key) }!.expanded
    }
    table.keyDown(with: right)
    await settled(m)
    XCTAssertTrue(m.selection.entry!.key.sameEntry(other: empty.key))
    let directory = try entry("small-files", in: m)
    m.select(directory)
    try await waitUntil { m.selection.row != nil }
    table.keyDown(with: right)
    try await waitUntil { !m.treeEditing }
    table.keyDown(with: right)
    try await waitUntil { m.selection.entry?.kind == .file }
    XCTAssertTrue(m.selection.entry!.parent!.sameEntry(other: directory.key))
  }
  func testHistorySelectionOutsideSliceRestoresVisibleRowWithoutRevealOrScroll() async throws {
    let m = try await fixtureModel("dix")
    let root = m.records!.focus.key
    let projects = try entry("Projects", in: m)
    m.expand(projects, expanded: true)
    try await waitUntil { !m.treeEditing }
    m.select(projects)
    try await waitUntil { m.selection.row != nil && m.selection.path != nil }
    let row = m.selection.row!
    m.scrolled(toRow: 1200)
    let tree = m.tree!
    let before = try tree.rows(offset: UInt64.max, limit: 1).expandedDirectories
    m.focus(projects.key)
    try await waitUntil { !m.loading }
    m.focusParent()
    try await waitUntil { !m.loading }
    XCTAssertTrue(m.records!.focus.key.sameEntry(other: root))
    XCTAssertTrue(m.tree === tree)
    XCTAssertEqual(m.restoredScrollRow, 1200)
    XCTAssertGreaterThan(m.outline!.offset, 1000)
    XCTAssertEqual(m.selection.row, row)
    XCTAssertTrue(m.selection.entry!.key.sameEntry(other: projects.key))
    XCTAssertEqual(try tree.rows(offset: UInt64.max, limit: 1).expandedDirectories, before)
    let child = try tree.rows(offset: 1, limit: 1).rows[0].entry
    m.select(child)
    try await waitUntil { m.selection.row != nil && m.selection.path != nil }
    m.scrolled(toRow: 0)
    m.expand(projects, expanded: false)
    try await waitUntil { !m.treeEditing }
    XCTAssertNil(m.selection.row)
    m.focus(projects.key)
    try await waitUntil { !m.loading }
    m.focusParent()
    try await waitUntil { !m.loading }
    XCTAssertTrue(m.selection.entry!.key.sameEntry(other: child.key))
    XCTAssertNil(m.selection.row)
    XCTAssertEqual(m.restoredScrollRow, 0)
    XCTAssertEqual(try tree.rows(offset: 0, limit: 1).expandedDirectories, 0)
  }
}
