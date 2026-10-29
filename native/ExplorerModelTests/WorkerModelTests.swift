import XCTest

@testable import DiskInventory

/// The model's latest-wins workers drop answers for an obsolete request. The fixture holds the
/// Rust session lock, so each request waits until the test releases it.
@MainActor final class WorkerModelTests: XCTestCase {
  func fixture() async throws -> ExplorerModel {
    let model = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", "metadata-delay"], environment: [:])
    try await waitUntil { model.records != nil && !model.loading && !model.replacingSession }
    return model
  }
  func entry(_ name: String, in model: ExplorerModel) throws -> EntryRecord {
    try XCTUnwrap(model.outline?.rows.first { $0.entry.displayName == name }?.entry)
  }
  /// Holds the session lock for about one second with a live metadata read.
  func holdBridge(_ model: ExplorerModel) async throws -> Task<MetadataRecord, Error> {
    let session = try XCTUnwrap(model.session)
    let key = try entry("large-file", in: model).key
    let task = Task.detached { try session.liveMetadata(key: key) }
    try await pollUntil { session.isBusy() }
    return task
  }

  /// Esc while a region query waits: the running answer is dropped and the waiting one is
  /// discarded, so no region comes back.
  func testObsoleteRegionAnswersDoNotReturnAfterClearSelection() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    let session = try XCTUnwrap(model.session)
    let blocker = try await holdBridge(model)
    model.select(try entry("large-file", in: model))
    // The path, region and tree reveal queries of the first selection wait on the lock.
    try await pollUntil { session.activeCallCount() == 4 }
    model.select(try entry("small-files", in: model))
    model.clearSelection()
    XCTAssertNil(model.selectedRegion)
    _ = try await blocker.value
    await settled(model)
    XCTAssertNil(model.selectedRegion)
    XCTAssertNil(model.selected)
  }

  /// A map point inside a fixture block that `point` hit-tests.
  func center(_ name: String, in model: ExplorerModel) throws -> (UInt32, UInt32) {
    let target = try XCTUnwrap(model.picture?.targets.first { $0.entry.displayName == name })
    return (
      UInt32(target.rect.x + target.rect.width / 2), UInt32(target.rect.y + target.rect.height / 2)
    )
  }
  /// Starts a hit test that waits on the held lock.
  func pointWhileHeld(
    _ model: ExplorerModel, _ name: String, click: Bool = false
  ) async throws -> Task<MetadataRecord, Error> {
    let session = try XCTUnwrap(model.session)
    let blocker = try await holdBridge(model)
    let (x, y) = try center(name, in: model)
    model.point(x, y, click: click)
    try await pollUntil { session.activeCallCount() == 2 }
    return blocker
  }

  /// The pointer leaves the map while a hover hit test waits: no hover comes back.
  func testObsoleteHoverAnswersDoNotReturnAfterThePointerLeaves() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    let blocker = try await pointWhileHeld(model, "large-file")
    // A second hover waits behind the first.
    let (x, y) = try center("large-file", in: model)
    model.point(x, y)
    model.clearHover()
    _ = try await blocker.value
    await settled(model)
    XCTAssertNil(model.hover)
  }

  /// Esc while a click hit test waits: the click does not select afterwards.
  func testObsoleteClickAnswersDoNotSelectAfterClearSelection() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    model.select(try entry("zero-byte", in: model))
    await settled(model)
    let blocker = try await pointWhileHeld(model, "large-file", click: true)
    model.clearSelection()
    _ = try await blocker.value
    await settled(model)
    XCTAssertNil(model.selected)
  }

  /// A map rebuild while a click hit test waits: the click belongs to the old picture.
  func testClickAnswersDoNotSelectAfterTheViewIsRebuilt() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    let root = try XCTUnwrap(model.records?.status.root.key)
    let blocker = try await pointWhileHeld(model, "large-file", click: true)
    let rebuilding = Task { await model.updateView(focus: root) }
    try await waitUntil { model.loading }
    _ = try await blocker.value
    await rebuilding.value
    await settled(model)
    XCTAssertNil(model.selected)
  }

  /// A result motion starts while a hover hit test waits: the hover is not shown.
  func testHoverAnswersDoNotReturnDuringAResultMotion() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    let blocker = try await pointWhileHeld(model, "large-file")
    model.motion.hold(try XCTUnwrap(model.picture))
    _ = try await blocker.value
    await settled(model)
    XCTAssertNil(model.hover)
    model.motion.cancel()
  }
}
