import AppKit

/// Fixture-only frame sampler for UI acceptance. It records every drawn map frame and counts
/// a gap when a frame shows no selection dim between a frame with the dim and a frame with
/// the dim for the same newly selected item: the click flicker. Its accessibility label is
/// "gaps=G selections=S draws=D".
@MainActor final class SelectionDrawProbe: NSAccessibilityElement {
  private(set) var gaps = 0
  private(set) var selections = 0
  private(set) var draws = 0
  private var lastShown = false
  private var lastSelected: EntryKey?
  private var pendingGap: EntryKey?
  override init() {
    super.init()
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityIdentifier("map-selection-gaps")
    setAccessibilityLabel("gaps=0 selections=0 draws=0")
  }
  func record(selected: EntryKey?, shown: Bool) {
    draws += 1
    let same = { (a: EntryKey?, b: EntryKey?) in
      a.map { a in b.map { a.sameEntry(other: $0) } ?? false } ?? (b == nil)
    }
    if let selected, !same(selected, lastSelected) { selections += 1 }
    if !same(selected, pendingGap) { pendingGap = nil }
    if !shown, lastShown, selected != nil {
      pendingGap = selected
    } else if shown, pendingGap != nil {
      gaps += 1
      pendingGap = nil
    }
    lastShown = shown
    lastSelected = selected
    publish()
  }
  private func publish() {
    setAccessibilityLabel("gaps=\(gaps) selections=\(selections) draws=\(draws)")
  }
}
