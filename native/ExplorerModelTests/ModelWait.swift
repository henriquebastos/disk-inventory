import Foundation
import Observation
import XCTest

@testable import DiskInventory

/// Wakes one waiter once, from any thread: an Observation change or the deadline.
private final class Wake: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var fired = false
  func signal() {
    lock.lock()
    fired = true
    let waiter = continuation
    continuation = nil
    lock.unlock()
    waiter?.resume()
  }
  func wait() async {
    await withCheckedContinuation { waiter in
      lock.lock()
      if fired {
        lock.unlock()
        waiter.resume()
      } else {
        continuation = waiter
        lock.unlock()
      }
    }
  }
}

extension XCTestCase {
  /// Waits until `condition` holds. The model's background tasks publish their results to
  /// observed properties, so the condition is checked again only when one that it read changes
  /// (Observation), not on a timer. The deadline is a safety net: a condition that reads no
  /// observed state, or never holds, fails after `seconds`; other state needs `pollUntil`.
  @MainActor func waitUntil(
    _ condition: @escaping @MainActor () -> Bool, seconds: Int = 10,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while ContinuousClock.now < deadline {
      let wake = Wake()
      if withObservationTracking({ condition() }, onChange: { wake.signal() }) { return }
      let timer = Task {
        try? await Task.sleep(until: deadline)
        wake.signal()
      }
      await wake.wait()
      timer.cancel()
    }
    // Met only when the deadline wakes it: the condition reads state that Observation does not
    // track, and the wait silently took the whole safety net.
    XCTFail(
      condition()
        ? "met without an observed change; use pollUntil" : "timed out after \(seconds) s",
      file: file, line: line)
  }
  /// Polls `condition` every 5 ms. Only for state without a change signal: Rust bridge state,
  /// such as `isBusy()` while a test holds the core lock, and AppKit views that SwiftUI updates
  /// after the model, such as `numberOfRows`.
  @MainActor func pollUntil(
    _ condition: @escaping @MainActor () -> Bool, seconds: Int = 10,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(condition(), "timed out after \(seconds) s", file: file, line: line)
  }
}

extension XCTestCase {
  /// Runs `body` and fails if it does not finish within `seconds`. A stuck body is left
  /// suspended; the test does not hang.
  @MainActor func bounded(
    _ name: String, seconds: Double = 8, _ body: @escaping @MainActor () async -> Void
  ) async {
    let done = expectation(description: name)
    Task { @MainActor in
      await body()
      done.fulfill()
    }
    await fulfillment(of: [done], timeout: seconds)
  }
  /// Waits until every model worker is idle (`ExplorerModel.settled()`), at most 8 s.
  @MainActor func settled(_ model: ExplorerModel) async {
    await bounded("settled") { await model.settled() }
  }
}
