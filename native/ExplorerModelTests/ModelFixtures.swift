import Foundation
import XCTest

@testable import DiskInventory

extension XCTestCase {
  /// A fixture-mode model of the Rust fixture `scenario`, once its first view is published.
  /// The macOS Reduce Motion setting is off unless `systemReduceMotion` says otherwise, so the
  /// result does not depend on the host.
  @MainActor func fixtureModel(
    _ scenario: String, environment: [String: String] = [:], numbers: NativeNumberFormat = .system,
    systemReduceMotion: Bool = false, file: StaticString = #filePath, line: UInt = #line
  ) async throws -> ExplorerModel {
    let model = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", scenario], environment: environment,
      numbers: numbers, systemReduceMotion: { systemReduceMotion })
    try await waitUntil(
      { model.records != nil && !model.loading && !model.replacingSession }, file: file,
      line: line)
    return model
  }
  /// The entry of the loaded tree row named `name`.
  @MainActor func entry(
    _ name: String, in model: ExplorerModel, file: StaticString = #filePath, line: UInt = #line
  ) throws -> EntryRecord {
    try XCTUnwrap(
      model.outline?.rows.first { $0.entry.displayName == name }?.entry, name, file: file,
      line: line)
  }
  /// Holds the session's Rust lock with a live metadata read of `large-file`, which the
  /// `metadata-delay` fixture makes last about one second, and returns that read. It first
  /// waits until every model worker is idle and no call holds the lock, so `isBusy()`
  /// afterwards means this read. A session load or an operation that starts in between could
  /// also hold the lock: they are not workers, so call this only while none runs.
  @MainActor func holdBridge(
    _ model: ExplorerModel, file: StaticString = #filePath, line: UInt = #line
  ) async throws -> Task<MetadataRecord, Error> {
    let session = try XCTUnwrap(model.session, file: file, line: line)
    let key = try entry("large-file", in: model, file: file, line: line).key
    await settled(model)
    try await pollUntil({ !session.isBusy() }, file: file, line: line)
    let task = Task { try await blocking { try session.liveMetadata(key: key) } }
    try await pollUntil({ session.isBusy() }, file: file, line: line)
    return task
  }
}
