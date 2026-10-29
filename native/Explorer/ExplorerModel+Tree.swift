import AppKit

extension ExplorerModel {
  func requestRows(_ offset: UInt64) {
    guard let tree else { return }
    treeWorker.submit(
      TreeRequest(
        tree: tree, generation: sessionVersion, version: outlineVersion, intent: .rows(offset)),
      slot: TreeRequest.rowsSlot, serve: serveTree)
  }
  func expand(_ entry: EntryRecord, expanded: Bool) {
    guard let tree, canExpandRows else { return }
    outlineVersion += 1
    treeEditing = true
    treeWorker.submit(
      TreeRequest(
        tree: tree, generation: sessionVersion, version: outlineVersion,
        intent: .expand(entry.key, expanded, outline?.offset ?? 0, selected?.key, selectionVersion)
      ), slot: TreeRequest.expansionSlot, serve: serveTree)
  }
  func reveal(_ entry: EntryRecord) {
    guard let tree, records?.focus.key.sameEntry(other: entry.key) != true else {
      selectedRow = nil
      return
    }
    outlineVersion += 1
    treeWorker.submit(
      TreeRequest(
        tree: tree, generation: sessionVersion, version: outlineVersion,
        intent: .reveal(entry.key, selectionVersion)),
      slot: TreeRequest.revealSlot, serve: serveTree)
  }
  /// An expansion runs even when a newer reveal or page changed the outline version, and ends
  /// `treeEditing` while its tree is current.
  private func serveTree(_ request: TreeRequest) async {
    guard request.generation == sessionVersion, request.tree === tree else { return }
    let isExpansion: Bool
    if case .expand = request.intent { isExpansion = true } else { isExpansion = false }
    if !isExpansion && request.version != outlineVersion { return }
    do {
      let result = try await Task.detached {
        switch request.intent {
        case .rows(let offset):
          return (try request.tree.rows(offset: offset, limit: 256), nil as Int?)
        case .expand(let key, let expanded, let offset, let selection, _):
          let total = try request.tree.expand(key: key, expanded: expanded)
          let row = try selection.flatMap { try request.tree.visibleRow(key: $0) }.map {
            Int($0)
          }
          return (
            try request.tree.rows(
              offset: min(offset, total > 256 ? total - 256 : 0), limit: 256), row
          )
        case .reveal(let key, _):
          let row = try request.tree.reveal(key: key)
          return (try request.tree.rows(offset: row > 32 ? row - 32 : 0, limit: 256), Int(row))
        }
      }.value
      if request.generation == sessionVersion, request.version == outlineVersion,
        request.tree === tree
      {
        outline = result.0
        switch request.intent {
        case .rows: break
        case .expand(_, _, _, _, let selectedVersion):
          if selectedVersion == selectionVersion { selectedRow = result.1 }
        case .reveal(_, let selectedVersion):
          if selectedVersion == selectionVersion {
            selectedRow = result.1
            revealSerial += 1
          }
        }
      }
    } catch {
      if request.generation == sessionVersion, request.version == outlineVersion {
        self.error = String(describing: error)
      }
    }
    if isExpansion, request.tree === tree { treeEditing = false }
  }
}
