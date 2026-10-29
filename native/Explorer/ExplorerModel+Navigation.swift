import AppKit

enum NavigationLimit {
  /// Ancestors of the focus that the breadcrumbs show; the nearest ones are kept.
  static let ancestors = 64
  /// Saved views of earlier folders; the oldest goes first.
  static let history = 64
}

extension ExplorerModel {
  func focus(_ key: EntryKey) {
    guard !working, !replacingSession else { return }
    guard requestedFocus?.sameEntry(other: key) != true else { return }
    let restore = history.first { $0.focus.sameEntry(other: key) }
    history.removeAll { $0.focus.sameEntry(other: key) }
    if let old = records?.focus.key, let tree {
      history.removeAll { $0.focus.sameEntry(other: old) }
      history.append(
        NavigationContext(
          focus: old, tree: tree, selection: selection.entry?.key, scrollRow: scrollRow))
      if history.count > NavigationLimit.history { history.removeFirst() }
    }
    motion.cancel()
    recoveryToken = nil
    requestedFocus = key
    loading = true
    viewVersion += 1
    invalidatePresentation()
    restoring = restore
    cancelConfirmation()
    pathWorker.discard()
    selectionVersion += 1
    selection.clear()
    let navigation = viewVersion
    Task { if navigation == viewVersion { await updateView(focus: key) } }
  }
  func focusParent() { if let parent = records?.focus.parent { focus(parent) } }
  func openSelectedDirectory() {
    if let entry = selection.entry, entry.kind == .directory { focus(entry.key) }
  }
  /// The tree scrolled. `row` is its top unobscured row, -1 above the first row. Focus saves
  /// it in the history, and going back restores it.
  func scrolled(toRow row: Int) { scrollRow = UInt64(max(0, row)) }
}
