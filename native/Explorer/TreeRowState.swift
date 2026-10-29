/// What one tree row shows in its name and size cells. Plain values only, so a cell renders
/// without a table or a Rust session. The table builds one per visible row on demand.
struct TreeRowState: Equatable {
  /// False for a row whose page has not arrived: "Loading…", without swatch or bar.
  let loaded: Bool
  let depth: UInt32
  let name: String
  let nameIdentifier: String
  /// The map's file base color as 0xRRGGBB; nil draws the neutral directory square.
  let mapRGB: UInt32?
  /// The usage bar width as a percent of the focus total.
  let percent: Int
  let size: String
  /// Only a directory with items has a disclosure triangle and an accessibility expanded state.
  let expandable: Bool
  let expanded: Bool
  let disclosureIdentifier: String
  let disclosureLabel: String

  static let loading = TreeRowState(
    loaded: false, depth: 0, name: "Loading…", nameIdentifier: "loading-row", mapRGB: nil,
    percent: 0, size: "", expandable: false, expanded: false,
    disclosureIdentifier: "loading-disclosure", disclosureLabel: "Loading")
}

extension TreeRowState {
  /// A loaded row; `focusTotal` is the subtree size of the focused directory.
  @MainActor init(row: OutlineRow, focusTotal: UInt64, numbers: NativeNumberFormat) {
    let name = entryName(row.entry)
    self.init(
      loaded: true, depth: row.depth, name: name, nameIdentifier: "entry-\(name)",
      mapRGB: row.mapRgb, percent: usageBarPercent(row.entry.subtreeBytes, of: focusTotal),
      size: numbers.storage(row.entry.subtreeBytes),
      expandable: row.entry.kind == .directory && row.entry.childCount > 0,
      expanded: row.expanded, disclosureIdentifier: "disclosure-\(name)",
      disclosureLabel: (row.expanded ? "Collapse " : "Expand ") + name)
  }
}
