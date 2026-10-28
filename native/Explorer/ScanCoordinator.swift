import Foundation
import Observation

@MainActor @Observable final class ScanCoordinator {
  private(set) var progress: ScanProgress?
  private(set) var polling = false
  private(set) var samples = 0
  /// The focused folder name while a refresh runs; nil for a scan of a new folder.
  private(set) var refreshing: String?
  private var control: ScanControl?
  private var pollTask: Task<Void, Never>?
  private var version = 0

  func begin(_ control: ScanControl, refreshing: String? = nil) {
    stopPolling(cancelScan: true)
    self.control = control
    self.refreshing = refreshing
    progress = control.progress()
    polling = true
    let generation = version
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let self, generation == self.version else { return }
        self.progress = control.progress()
        self.samples += 1
      }
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
  }
  var label: String {
    guard let progress else { return "Preparing view…" }
    if let refreshing {
      switch progress.phase {
      case .ready, .scanning: return "Refreshing “\(refreshing)”…"
      case .stopping: return "Stopping…"
      case .cancelled: return "Refresh stopped"
      case .failed, .publishedFailure: return "Refresh failed"
      case .accounting, .saving, .committing, .committed, .preparingView, .complete:
        return "Updating “\(refreshing)”…"
      }
    }
    switch progress.phase {
    case .ready, .scanning: return "Examining items…"
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
