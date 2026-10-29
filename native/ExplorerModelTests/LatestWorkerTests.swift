import XCTest

@testable import DiskInventory

/// Holds one served request until the test opens it.
@MainActor private final class Gate {
  private var release: CheckedContinuation<Void, Never>?
  private var entered: CheckedContinuation<Void, Never>?
  private(set) var held = false
  func hold() async {
    held = true
    entered?.resume()
    entered = nil
    await withCheckedContinuation { release = $0 }
    held = false
  }
  func untilHeld() async {
    guard !held else { return }
    await withCheckedContinuation { entered = $0 }
  }
  func open() {
    release?.resume()
    release = nil
  }
}

private final class Owner {}

/// `LatestWorker` alone, with plain strings: no model and no Rust.
@MainActor final class LatestWorkerTests: XCTestCase {
  /// Records each served request and holds `"held"` at the gate.
  private var served: [String] = []
  private lazy var gate = Gate()
  private func serve(_ request: String) async {
    served.append(request)
    if request == "held" { await gate.hold() }
  }

  func testSubmitReplacesTheWaitingRequestOfItsSlot() async {
    let worker = LatestWorker<String>()
    await bounded("replace") {
      XCTAssertNil(worker.submit("held", serve: self.serve))
      await self.gate.untilHeld()
      XCTAssertNil(worker.submit("first", serve: self.serve))
      XCTAssertEqual(worker.submit("second", serve: self.serve), "first")
      self.gate.open()
      await worker.settled()
    }
    XCTAssertEqual(served, ["held", "second"])
  }

  func testLowerSlotIsServedFirst() async {
    let worker = LatestWorker<String>(slots: 2)
    await bounded("priority") {
      worker.submit("held", serve: self.serve)
      await self.gate.untilHeld()
      worker.submit("hover", slot: 1, serve: self.serve)
      worker.submit("click", slot: 0, serve: self.serve)
      self.gate.open()
      await worker.settled()
    }
    XCTAssertEqual(served, ["held", "click", "hover"])
  }

  func testDiscardDropsOnlyTheWaitingRequest() async {
    let worker = LatestWorker<String>(slots: 2)
    await bounded("discard") {
      worker.submit("held", serve: self.serve)
      await self.gate.untilHeld()
      worker.submit("click", slot: 0, serve: self.serve)
      worker.submit("hover", slot: 1, serve: self.serve)
      worker.discard(slot: 1)
      self.gate.open()
      await worker.settled()
      worker.submit("held", serve: self.serve)
      await self.gate.untilHeld()
      worker.submit("click", slot: 0, serve: self.serve)
      worker.submit("hover", slot: 1, serve: self.serve)
      worker.discardAll()
      self.gate.open()
      await worker.settled()
    }
    // The running request always finishes.
    XCTAssertEqual(served, ["held", "click", "held"])
  }

  func testIsIdleOnlyWhenNotServingAndNothingWaiting() async {
    let worker = LatestWorker<String>()
    XCTAssertTrue(worker.isIdle)
    await bounded("idle") {
      worker.submit("held", serve: self.serve)
      XCTAssertFalse(worker.isIdle, "submitted, not started")
      await self.gate.untilHeld()
      XCTAssertFalse(worker.isIdle, "serving")
      self.gate.open()
      await worker.settled()
      XCTAssertTrue(worker.isIdle)
    }
  }

  func testSettledReturnsAtOnceWhenIdle() async {
    let worker = LatestWorker<String>()
    await bounded("idle settled") { await worker.settled() }
    XCTAssertEqual(served, [])
  }

  /// Work that a served request submits to its own worker is part of the same settle.
  func testSettledIncludesARequestSubmittedDuringServe() async {
    let worker = LatestWorker<String>()
    var served: [String] = []
    func serve(_ request: String) async {
      served.append(request)
      await Task.yield()
      if request == "first" { worker.submit("follow-up", serve: serve) }
    }
    await bounded("follow-up") {
      worker.submit("first", serve: serve)
      await worker.settled()
    }
    XCTAssertEqual(served, ["first", "follow-up"])
    XCTAssertTrue(worker.isIdle)
  }

  /// An idle worker keeps no serve closure, so it does not retain the owner that the closure
  /// captures.
  func testIdleWorkerDoesNotRetainItsServeClosure() async {
    let worker = LatestWorker<String>()
    weak var released: Owner?
    await bounded("release") {
      let owner = Owner()
      released = owner
      worker.submit("only") { _ in _ = owner }
      await worker.settled()
    }
    XCTAssertNil(released)
  }
}
