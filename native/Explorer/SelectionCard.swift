import SwiftUI

/// What the selection card below the tree shows. Plain values only, so the card renders and
/// previews without a Rust session.
enum SelectionCardState: Equatable {
  /// No selection. `canSelectRoot` shows the Select Inventory Root button.
  case nothing(canSelectRoot: Bool)
  case item(SelectionCardItem)
  /// A grouped map block: its formatted size.
  case group(size: String)
}

struct SelectionCardItem: Equatable {
  let name: String
  /// A directory shows its subtree size, a file its accounted size.
  let size: String
  /// "N direct items" for a directory, nil for a file.
  let count: String?
  /// The complete saved path; nil while it loads.
  let path: String?
  /// The inventory root has no parent and cannot be removed.
  let rootProtected: Bool
  let canRevealInFinder: Bool
  let canMoveToTrash: Bool
  let canDelete: Bool
}

/// What a card button asks the model to do.
enum SelectionCardIntent: Equatable {
  case showInList
  case command(ExplorerCommand)
  case showGroupedDirectory
  case selectRoot
}

extension ExplorerModel {
  var selectionCard: SelectionCardState {
    if let entry = selected {
      let directory = entry.kind == .directory
      return .item(
        SelectionCardItem(
          name: entryName(entry),
          size: numbers.storage(directory ? entry.subtreeBytes : entry.accountedBytes),
          count: directory ? "\(numbers.count(entry.childCount)) direct items" : nil,
          path: selectedDisplayPath, rootProtected: entry.parent == nil,
          canRevealInFinder: ExplorerCommand.revealInFinder.isEnabled(in: self),
          canMoveToTrash: ExplorerCommand.moveToTrash.isEnabled(in: self),
          canDelete: ExplorerCommand.deleteImmediately.isEnabled(in: self)))
    }
    if let aggregateText { return .group(size: aggregateText) }
    return .nothing(canSelectRoot: records?.status.root != nil)
  }
  func perform(_ intent: SelectionCardIntent) {
    switch intent {
    case .showInList: revealSelection()
    case .command(let command): command.perform(in: self)
    case .showGroupedDirectory: if let aggregate { focus(aggregate) }
    case .selectRoot: if let root = records?.status.root { select(root) }
    }
  }
}

/// The compact card below the tree: the selected item, a grouped block, or nothing.
struct SelectionCard: View {
  let state: SelectionCardState
  let send: @MainActor (SelectionCardIntent) -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      switch state {
      case .item(let item):
        HStack(alignment: .firstTextBaseline) {
          Button(item.name) { send(.showInList) }.buttonStyle(.plain)
            .font(.headline).lineLimit(1).truncationMode(.middle)
            .help("Show selected item in list").accessibilityIdentifier("selected-name")
          Spacer(minLength: 4)
          Text(item.size)
            .font(.callout.weight(.semibold)).monospacedDigit().accessibilityIdentifier(
              "selected-usage")
        }
        if let count = item.count {
          Text(count).font(.caption)
        }
        Text(item.path ?? "Loading path…")
          .font(.system(.caption, design: .monospaced))
          .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
          .help(item.path ?? "").accessibilityIdentifier("selected-path")
        HStack(spacing: 6) {
          Button("Reveal in Finder") { send(.command(.revealInFinder)) }
            .disabled(!item.canRevealInFinder)
            .accessibilityIdentifier("reveal-finder")
          Spacer(minLength: 0)
          Button("Delete…", role: .destructive) { send(.command(.deleteImmediately)) }
            .disabled(!item.canDelete)
            .accessibilityIdentifier("delete")
          Button("Move to Trash…") { send(.command(.moveToTrash)) }
            .disabled(!item.canMoveToTrash)
            .accessibilityIdentifier("trash")
        }.controlSize(.small)
        if item.rootProtected {
          Text("Inventory root is protected.").font(.caption).accessibilityIdentifier(
            "root-protected")
        }
      case .group(let size):
        Text(size).accessibilityIdentifier("aggregate-text")
        Button("Show Directory Contents") { send(.showGroupedDirectory) }
      case .nothing(let canSelectRoot):
        Text("Nothing selected").font(.headline)
        Text("Click to select. Double-click a directory to focus it.")
        if canSelectRoot {
          Button("Select Inventory Root") { send(.selectRoot) }.accessibilityIdentifier(
            "inspect-root")
        }
      }
    }.font(.callout).frame(maxWidth: .infinity, minHeight: 122, alignment: .leading)
      .padding(14).background(.bar)
  }
}

#Preview("Nothing selected") {
  SelectionCard(state: .nothing(canSelectRoot: true)) { _ in }.frame(width: 400)
}
#Preview("File") {
  SelectionCard(
    state: .item(
      SelectionCardItem(
        name: "large-file", size: "8.2 KB", count: nil, path: "/Workspace/large-file",
        rootProtected: false, canRevealInFinder: true, canMoveToTrash: true, canDelete: true))
  ) { _ in }.frame(width: 400)
}
#Preview("Directory, path loading") {
  SelectionCard(
    state: .item(
      SelectionCardItem(
        name: "small-files", size: "4.1 KB", count: "32 direct items", path: nil,
        rootProtected: false, canRevealInFinder: false, canMoveToTrash: true, canDelete: true))
  ) { _ in }.frame(width: 400)
}
#Preview("Inventory root") {
  SelectionCard(
    state: .item(
      SelectionCardItem(
        name: "Inventory root", size: "1.2 GB", count: "6 direct items", path: "/Workspace",
        rootProtected: true, canRevealInFinder: true, canMoveToTrash: false, canDelete: false))
  ) { _ in }.frame(width: 400)
}
#Preview("Grouped block") {
  SelectionCard(state: .group(size: "12 KB")) { _ in }.frame(width: 400)
}
