import Dispatch

/// Runs a blocking call, such as a bridge call that waits on the Rust session lock, on a
/// Dispatch thread and returns its result. The Swift concurrency pool has about one thread per
/// core and adds none when a thread blocks, so calls that wait there can stop other calls from
/// starting. Dispatch adds threads when its threads block.
func blocking<T: Sendable>(
  qos: DispatchQoS.QoSClass = .default, _ work: @escaping @Sendable () throws -> T
) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global(qos: qos).async { continuation.resume(with: Result(catching: work)) }
  }
}

/// Runs a blocking call that cannot fail on a Dispatch thread; see the throwing variant.
func blocking<T: Sendable>(
  qos: DispatchQoS.QoSClass = .default, _ work: @escaping @Sendable () -> T
) async -> T {
  await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: qos).async { continuation.resume(returning: work()) }
  }
}
