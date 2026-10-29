import Foundation
import Observation

@MainActor @Observable final class ScanCoordinator {
  private(set) var progress: ScanProgress?
  private(set) var polling = false
  private(set) var samples = 0
  /// The focused folder name while a refresh runs; nil for a scan of a new folder.
  private(set) var refreshing: String?
  /// The Trash or Delete that runs, and the name of its item.
  private(set) var operation: (kind: ActionKind, name: String)?
  private var control: ScanControl?
  private var pollTask: Task<Void, Never>?
  private var version = 0

  func begin(
    _ control: ScanControl, refreshing: String? = nil,
    operation: (kind: ActionKind, name: String)? = nil
  ) {
    stopPolling(cancelScan: true)
    self.control = control
    self.refreshing = refreshing
    self.operation = operation
    progress = control.progress()
    polling = true
    let generation = version
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let self, generation == self.version else { return }
        self.sample()
        self.samples += 1
      }
    }
  }
  /// Reads the control now; the poll does this four times a second.
  func sample() {
    guard let control else { return }
    progress = control.progress()
  }
  /// Only a scan, a refresh and a permanent deletion offer Stop; Trash cannot stop.
  var offersStop: Bool { operation?.kind != .trash }
  /// The counter beside the phase: items examined by a scan or a refresh, items removed by a
  /// deletion. Trash and the update after an operation have none.
  func itemsText(_ numbers: NativeNumberFormat) -> String? {
    guard let progress else { return nil }
    switch operation?.kind {
    case nil: return "\(numbers.count(progress.itemsExamined)) items examined"
    case .trash: return nil
    case .permanentlyDelete:
      guard progress.phase == .removing || progress.phase == .stopping else { return nil }
      return "\(numbers.count(progress.itemsExamined)) items"
    }
  }
  func stop() {
    guard let control else { return }
    _ = control.cancel()
    progress = control.progress()
  }
  func stopPolling(cancelScan: Bool) {
    if cancelScan { _ = control?.cancel() }
    version += 1
    pollTask?.cancel()
    pollTask = nil
    polling = false
    control = nil
    progress = nil
    refreshing = nil
    operation = nil
  }
  var label: String {
    guard let progress else { return "Preparing view…" }
    if let operation {
      let name = operation.name
      switch progress.phase {
      case .ready, .scanning: return "Checking “\(name)”…"
      case .removing: return "Deleting “\(name)”…"
      case .stopping: return "Stopping…"
      case .accounting, .saving, .committing:
        return operation.kind == .trash ? "Moving “\(name)” to the Trash…" : "Deleting “\(name)”…"
      case .committed, .preparingView, .complete, .cancelled, .failed, .publishedFailure:
        return "Updating view…"
      }
    }
    if let refreshing {
      switch progress.phase {
      case .ready, .scanning, .removing: return "Refreshing “\(refreshing)”…"
      case .stopping: return "Stopping…"
      case .cancelled: return "Refresh stopped"
      case .failed, .publishedFailure: return "Refresh failed"
      case .accounting, .saving, .committing, .committed, .preparingView, .complete:
        return "Updating “\(refreshing)”…"
      }
    }
    switch progress.phase {
    case .ready, .scanning, .removing: return "Examining items…"
    case .accounting: return "Accounting for shared storage…"
    case .saving: return "Saving inventory…"
    case .stopping: return "Stopping…"
    case .committing, .committed: return "Publishing inventory…"
    case .preparingView, .complete: return "Preparing view…"
    case .cancelled: return "Scan cancelled"
    case .failed: return "Scan failed"
    case .publishedFailure: return "Inventory published; preparation failed"
    }
  }
}
