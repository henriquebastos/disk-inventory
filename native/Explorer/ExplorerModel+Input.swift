import AppKit

/// Busy rules for tree and map input, named once. They differ on purpose: each keeps the exact
/// condition of the input that uses it. Views ask a rule or call an intent; the intents and the
/// actions they call check their own rule again.
extension ExplorerModel {
  /// No load, operation, session replacement or pending confirmation: tree keys, parent
  /// selection and the Navigate commands.
  var isIdle: Bool { !working && !loading && !replacingSession && pending == nil }
  /// Tree row selection, double-click, disclosure clicks and the row context menu.
  var treeInteractive: Bool { tree != nil && isIdle }
  /// The disclosure triangles of visible rows, updated with the tree.
  var visibleDisclosuresEnabled: Bool { treeInteractive && !treeEditing }
  /// The disclosure triangles of newly made cells, and `expand`. Unlike visible rows, this
  /// does not check the tree handle or a pending confirmation.
  var canExpandRows: Bool { !loading && !working && !replacingSession && !treeEditing }
  /// Map hover, click and accessibility press. A result motion blocks them; this does not check
  /// a pending confirmation.
  var acceptsMapPointer: Bool { !loading && !working && !motion.active && !replacingSession }
  /// The context menu of a map block: also no pending confirmation.
  var canOpenMapContextMenu: Bool { pending == nil && acceptsMapPointer }

  /// The cached row at a table row index. A row outside the cached page requests its page and
  /// is nil until the page arrives.
  func outlineRow(at row: Int) -> OutlineRow? {
    guard row >= 0, let p = outline else { return nil }
    let at = Int64(row) - Int64(p.offset)
    guard at >= 0, at < Int64(p.rows.count) else {
      requestRows(UInt64(max(0, row / 128 * 128)))
      return nil
    }
    return p.rows[Int(at)]
  }
  /// Command-Up focuses the parent; Command-Down, Return and Enter open the selected
  /// directory. Returns whether the key is consumed: always while busy, so the table does
  /// nothing either.
  func treeNavigationKey(_ code: UInt16) -> Bool {
    guard isIdle else { return true }
    if code == 126 {
      focusParent()
      return true
    }
    if code == 125 || code == 36 || code == 76 {
      openSelectedDirectory()
      return true
    }
    return false
  }
  /// Right expands the selected directory, then selects its first item; Left collapses it, or
  /// selects the parent. Returns whether the key is consumed: always while busy; not without
  /// a selected cached row, so the table moves the selection itself.
  func treeArrowKey(_ code: UInt16) -> Bool {
    guard code == 123 || code == 124 else { return false }
    guard isIdle else { return true }
    guard let index = selectedRow, let row = outlineRow(at: index) else { return false }
    if code == 124 {
      guard row.entry.kind == .directory, row.entry.childCount > 0 else { return true }
      if !row.expanded {
        expand(row.entry, expanded: true)
      } else if let child = outlineRow(at: index + 1),
        child.entry.parent?.sameEntry(other: row.entry.key) == true
      {
        select(child.entry)
      }
    } else if row.expanded {
      expand(row.entry, expanded: false)
    } else {
      selectParent(row.entry)
    }
    return true
  }
  /// A secondary click on the hovered map block selects it, or the group of a grouped block,
  /// which disables every item command. Uses the published hover, never a main-thread hit
  /// test, which would take the session lock. False shows no menu.
  func selectHoveredBlockForContextMenu() -> Bool {
    guard let hover, canOpenMapContextMenu else { return false }
    if !hover.actionable {
      selectAggregate(hover.entry.key, bytes: hover.bytes)
    } else if selected?.key.sameEntry(other: hover.entry.key) != true {
      select(hover.entry)
    }
    return true
  }
}
