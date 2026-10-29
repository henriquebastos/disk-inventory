/// A worker that tests and the model can wait for.
@MainActor protocol Settling: AnyObject {
  var isIdle: Bool { get }
  func settled() async
}

/// Serves requests one at a time on the main actor. A new request replaces the waiting request
/// of its slot, and a lower slot index is served first. `serve` awaits its own detached Rust
/// call, so a worker runs at most one blocking call plus one waiting request per slot.
@MainActor final class LatestWorker<Request>: Settling {
  private var waiting: [Request?]
  /// Kept only while the loop runs, so an idle worker does not retain its owner.
  private var serve: (@MainActor (Request) async -> Void)?
  private var settling: [CheckedContinuation<Void, Never>] = []

  init(slots: Int = 1) { waiting = Array(repeating: nil, count: slots) }

  /// Not serving and nothing waiting.
  var isIdle: Bool { serve == nil }

  /// Replaces the waiting request of `slot` and starts serving if idle. `serve` is the same
  /// function for every request of a worker. Returns the replaced waiting request.
  @discardableResult
  func submit(
    _ request: Request, slot: Int = 0, serve: @escaping @MainActor (Request) async -> Void
  ) -> Request? {
    let replaced = waiting[slot]
    waiting[slot] = request
    guard self.serve == nil else { return replaced }
    self.serve = serve
    Task {
      while let next = takeNext() { await serve(next) }
      self.serve = nil
      let waiters = settling
      settling = []
      for waiter in waiters { waiter.resume() }
    }
    return replaced
  }
  func discard(slot: Int = 0) { waiting[slot] = nil }
  func discardAll() { waiting = Array(repeating: nil, count: waiting.count) }
  /// Returns once the worker is idle, at once if it already is.
  func settled() async {
    guard !isIdle else { return }
    await withCheckedContinuation { settling.append($0) }
  }
  private func takeNext() -> Request? {
    guard let slot = waiting.firstIndex(where: { $0 != nil }) else { return nil }
    defer { waiting[slot] = nil }
    return waiting[slot]
  }
}
