import SwiftUI

/// What the header above the tree and the map shows, apart from the breadcrumbs. Plain values
/// only, so the header renders and previews without a Rust session.
struct HeaderState: Equatable {
  let reopenTitle: String
  let canChooseFolder: Bool
  let canReopenLastFolder: Bool
  /// Breadcrumbs stay disabled while an operation runs or a new session replaces this one.
  let breadcrumbsEnabled: Bool
  /// The help of the Partial badge, "N scan errors"; nil without the badge.
  let partialScanErrors: String?
  /// The Incomplete badge.
  let stale: Bool
  /// The Not saved badge.
  let dirty: Bool
  /// The saved size of the inventory root.
  let total: String
  /// "Scanned" and the date of a managed scan; nil for a fixture.
  let scanDate: String?
  let canRefresh: Bool
}

extension ExplorerModel {
  /// Nil without a view.
  var header: HeaderState? {
    guard let status = records?.status else { return nil }
    return HeaderState(
      reopenTitle: ExplorerCommand.reopenLastFolder.title(in: self),
      canChooseFolder: ExplorerCommand.chooseFolder.isEnabled(in: self),
      canReopenLastFolder: ExplorerCommand.reopenLastFolder.isEnabled(in: self),
      breadcrumbsEnabled: !(working || replacingSession),
      partialScanErrors: status.scanPartial
        ? numbers.count(status.counters.errors, one: "scan error", other: "scan errors") : nil,
      stale: status.stale, dirty: status.dirty, total: numbers.storage(status.root.subtreeBytes),
      scanDate: scanDate.map { "Scanned " + $0.formatted(date: .abbreviated, time: .shortened) },
      canRefresh: ExplorerCommand.refreshDirectory.isEnabled(in: self))
  }
}

/// The header: the inventory menu, the breadcrumbs, the badges, the total and Refresh.
struct ExplorerHeader<Breadcrumbs: View>: View {
  let state: HeaderState
  /// Runs a menu or Refresh command; `perform(in:)` checks its rule again.
  let send: @MainActor (ExplorerCommand) -> Void
  @ViewBuilder let breadcrumbs: Breadcrumbs
  var body: some View {
    HStack(spacing: 12) {
      Menu {
        Button("Choose Folder…") { send(.chooseFolder) }
          .accessibilityIdentifier("create-inventory")
        Button(state.reopenTitle) { send(.reopenLastFolder) }
          .disabled(!state.canReopenLastFolder)
      } label: {
        Image(systemName: "externaldrive")
      }
      .disabled(!state.canChooseFolder)
      .toolTip("Inventory")
      ScrollView(.horizontal) { breadcrumbs }.scrollIndicators(.hidden).disabled(
        !state.breadcrumbsEnabled)
      HStack(spacing: 5) {
        if let errors = state.partialScanErrors {
          badge("Partial", id: "partial").toolTip(errors)
        }
        if state.stale { badge("Incomplete", id: "stale") }
        if state.dirty { badge("Not saved", id: "dirty") }
      }
      VStack(alignment: .trailing, spacing: 2) {
        Text(state.total).font(
          .callout.weight(.semibold)
        )
        .monospacedDigit().accessibilityIdentifier("scope-total")
        if let scanDate = state.scanDate {
          Text(scanDate).font(.caption).accessibilityIdentifier("scan-date")
        }
      }.fixedSize()
      Button("Refresh Directory", systemImage: "arrow.clockwise") {
        send(.refreshDirectory)
      }
      .disabled(!state.canRefresh)
      .accessibilityIdentifier("refresh").toolTip(
        "Rescan the focused directory and descendants."
      )
    }.padding(.horizontal, 12).padding(.vertical, 10).background(.bar)
  }
  func badge(_ title: String, id: String) -> some View {
    Text(title).font(.caption.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 3)
      .background(.quaternary, in: Capsule()).accessibilityIdentifier(id)
  }
}

/// The breadcrumbs of the focused directory. Each button keeps the key it was drawn with, so
/// a click focuses the directory that the user saw; the header state holds no Rust handle.
struct BreadcrumbStrip: View {
  let model: ExplorerModel
  let records: ViewRecords
  var body: some View {
    let r = records
    HStack(spacing: 4) {
      if r.ancestors.first?.key.sameEntry(other: r.status.root.key) != true,
        r.focus.parent != nil
      {
        Button(r.breadcrumbName(r.status.root)) { model.focus(r.status.root.key) }
          .toolTip(r.breadcrumbHelp(r.status.root)).accessibilityIdentifier("breadcrumb-root")
        Text("…")
      }
      ForEach(Array(r.ancestors.enumerated()), id: \.offset) { i, entry in
        Button(r.breadcrumbName(entry)) { model.focus(entry.key) }.toolTip(r.breadcrumbHelp(entry))
          .accessibilityIdentifier(
            "breadcrumb-\(i)")
        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
      }
      Text(r.breadcrumbName(r.focus)).toolTip(r.breadcrumbHelp(r.focus)).fontWeight(.semibold)
        .accessibilityIdentifier("focus-name")
    }.buttonStyle(.plain)
  }
}

#Preview("Saved scan") {
  ExplorerHeader(
    state: HeaderState(
      reopenTitle: "Reopen “Workspace”", canChooseFolder: true, canReopenLastFolder: true,
      breadcrumbsEnabled: true, partialScanErrors: nil, stale: false, dirty: false,
      total: "1.2 GB", scanDate: "Scanned Oct 29, 2026 at 2:00 AM", canRefresh: true),
    send: { _ in }
  ) { Text("Workspace").fontWeight(.semibold) }.frame(width: 900)
}
#Preview("Partial, incomplete, not saved") {
  ExplorerHeader(
    state: HeaderState(
      reopenTitle: "Reopen Last Folder", canChooseFolder: true, canReopenLastFolder: false,
      breadcrumbsEnabled: true, partialScanErrors: "3 scan errors", stale: true, dirty: true,
      total: "640 MB", scanDate: nil, canRefresh: true),
    send: { _ in }
  ) { Text("Workspace").fontWeight(.semibold) }.frame(width: 900)
}
#Preview("Operation running") {
  ExplorerHeader(
    state: HeaderState(
      reopenTitle: "Reopen Last Folder", canChooseFolder: false, canReopenLastFolder: false,
      breadcrumbsEnabled: false, partialScanErrors: nil, stale: false, dirty: true,
      total: "640 MB", scanDate: nil, canRefresh: false),
    send: { _ in }
  ) { Text("Workspace").fontWeight(.semibold) }.frame(width: 900)
}
