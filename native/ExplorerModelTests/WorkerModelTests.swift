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
}
