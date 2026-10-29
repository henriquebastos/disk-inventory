import SwiftUI

/// What the busy bar shows. Plain values only, so the bar renders and previews without a Rust
/// session.
enum ProgressBarState: Equatable {
  /// A scan, Refresh Directory, Trash or Delete with Rust progress: its phase, its item counter
  /// and, except for Trash, a Stop button.
  case operation(phase: String, items: String?, offersStop: Bool, canStop: Bool)
  /// A Trash or Delete preparation checks this item before its confirmation opens.
  case checking(name: String)
  /// A new session is loading; the previous view stays read-only.
  case preparingInventory
  case working
}

extension ExplorerModel {
  /// The bar over the explorer split view shows while loading, working or replacing the session.
  var showsProgressBar: Bool { loading || working || replacingSession }
  /// The bar on the start screen shows while a session loads. No operation runs without one.
  var showsStartScreenProgressBar: Bool { loading || replacingSession }
  var progressBar: ProgressBarState? { showsProgressBar ? progressBarContent : nil }
  var startScreenProgressBar: ProgressBarState? {
    showsStartScreenProgressBar ? progressBarContent : nil
  }
  private var progressBarContent: ProgressBarState {
    if scan.progress != nil {
      return .operation(
        phase: scan.label, items: scan.itemsText(numbers), offersStop: scan.offersStop,
        canStop: ExplorerCommand.stopScan.isEnabled(in: self))
    }
    if let checking { return .checking(name: checking) }
    return replacingSession ? .preparingInventory : .working
  }
}

/// Computes the bar state in its own body. The state reads the scan progress, so a progress
/// tick redraws only the bar, not the explorer around it.
struct ProgressBarHost: View {
  let model: ExplorerModel
  /// The start-screen bar, which shows only while a session loads.
  let startScreen: Bool
  var body: some View {
    if let state = startScreen ? model.startScreenProgressBar : model.progressBar {
      ProgressBar(state: state) { ExplorerCommand.stopScan.perform(in: model) }
    }
  }
}

struct ProgressBar: View {
  let state: ProgressBarState
  let stop: @MainActor () -> Void
  var body: some View {
    HStack(spacing: 10) {
      ProgressView().controlSize(.small)
      switch state {
      case .operation(let phase, let items, let offersStop, let canStop):
        Text(phase).accessibilityIdentifier("scan-phase")
        if let items {
          Text(items).monospacedDigit().accessibilityIdentifier("scan-items")
        }
        Spacer()
        if offersStop {
          Button("Stop") { stop() }
            .disabled(!canStop)
            .accessibilityIdentifier("stop-scan")
        }
      case .checking(let name):
        Text("Checking “\(name)”…").accessibilityIdentifier("scan-phase")
        Spacer()
      case .preparingInventory:
        Text("Preparing inventory… Previous view is read-only.")
        Spacer()
      case .working:
        Text("Working…")
        Spacer()
      }
    }.font(.callout).padding(12).background(.bar)
  }
}

#Preview("Delete") {
  ProgressBar(
    state: .operation(
      phase: "Deleting “small-files”…", items: "12 items", offersStop: true, canStop: true)
  ) {}.frame(width: 600)
}
#Preview("Trash") {
  ProgressBar(
    state: .operation(
      phase: "Moving “large-file” to the Trash…", items: nil, offersStop: false, canStop: false)
  ) {}.frame(width: 600)
}
#Preview("Checking") {
  ProgressBar(state: .checking(name: "large-file")) {}.frame(width: 600)
}
#Preview("Preparing inventory") {
  ProgressBar(state: .preparingInventory) {}.frame(width: 600)
}
#Preview("Working") {
  ProgressBar(state: .working) {}.frame(width: 600)
}
