import AppKit

extension ExplorerModel {
  func focus(_ key: EntryKey) {
    guard !working, !replacingSession else { return }
    guard requestedFocus?.sameEntry(other: key) != true else { return }
    let restore = history.first { $0.focus.sameEntry(other: key) }
    history.removeAll { $0.focus.sameEntry(other: key) }
    if let old = records?.focus.key, let tree {
      history.removeAll { $0.focus.sameEntry(other: old) }
      history.append(
        NavigationContext(focus: old, tree: tree, selection: selected?.key, scrollRow: scrollRow))
      if history.count > 64 { history.removeFirst() }
    }
    motion.cancel()
    recoveryToken = nil
    requestedFocus = key
    loading = true
    viewVersion += 1
    invalidatePresentation()
    restoring = restore
    cancelConfirmation()
    pathRequest = nil
    selectionVersion += 1
    selectionRawPath = nil
    selectionPath = nil
    selected = nil
    aggregate = nil
    aggregateText = nil
    let navigation = viewVersion
    Task { if navigation == viewVersion { await updateView(focus: key) } }
  }
  func focusParent() { if let parent = records?.focus.parent { focus(parent) } }
  func openSelectedDirectory() {
    if let entry = selected, entry.kind == .directory { focus(entry.key) }
  }
  // Kept as the keyboard/test parent-navigation seam; there is no Back stack UI.
  func back() { focusParent() }
  func historyExpansionPayloadBytes() async throws -> UInt64 {
    let trees = history.map(\.tree)
    return try await Task.detached {
      try trees.reduce(UInt64(0)) {
        $0 + (try $1.rows(offset: UInt64.max, limit: 1).expansionPayloadBytes)
      }
    }.value
  }
}
