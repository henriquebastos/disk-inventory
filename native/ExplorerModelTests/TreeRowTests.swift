import AppKit
import XCTest

@testable import DiskInventory

/// Tree rows: `TreeRowState(row:focusTotal:numbers:)` from fixture rows, and one offscreen
/// `ContentsTree.Cell` per row state, with no table and no session.
@MainActor final class TreeRowTests: XCTestCase {
  typealias Cell = ContentsTree.Cell

  func row(
    name: String = "large-file", depth: UInt32 = 0, mapRGB: UInt32? = 0x3366CC, percent: Int = 50,
    expandable: Bool = false, expanded: Bool = false
  ) -> TreeRowState {
    TreeRowState(
      loaded: true, depth: depth, name: name, nameIdentifier: "entry-\(name)", mapRGB: mapRGB,
      percent: percent, size: "4.1 KB", expandable: expandable, expanded: expanded,
      disclosureIdentifier: "disclosure-\(name)",
      disclosureLabel: (expanded ? "Collapse " : "Expand ") + name)
  }
  /// A 360 by 26 point cell in the light appearance, laid out.
  func cell(_ state: TreeRowState) -> Cell {
    let cell = Cell(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
    cell.appearance = NSAppearance(named: .aqua)
    cell.apply(state)
    cell.layoutSubtreeIfNeeded()
    return cell
  }
  /// The cell drawn offscreen at 1x; `alpha(at:)` reads a point in view coordinates.
  func drawing(_ cell: Cell) throws -> NSBitmapImageRep {
    let bitmap = try XCTUnwrap(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
    cell.cacheDisplay(in: cell.bounds, to: bitmap)
    return bitmap
  }
  func color(_ bitmap: NSBitmapImageRep, at point: NSPoint, in cell: Cell) throws -> NSColor {
    let scale = CGFloat(bitmap.pixelsWide) / cell.bounds.width
    // Bitmap rows run top-down; the cell is not flipped.
    let x = Int(point.x * scale)
    let y = Int((cell.bounds.height - point.y) * scale)
    return try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
  }

  func testCellShowsAFileRowWithItsColorSwatchAndUsageBar() throws {
    let cell = cell(row(percent: 50))
    XCTAssertEqual(cell.name.stringValue, "large-file")
    XCTAssertEqual(cell.name.accessibilityIdentifier(), "entry-large-file")
    XCTAssertTrue(cell.disclosure.isHidden)
    XCTAssertFalse(cell.swatch.isHidden)
    XCTAssertFalse(cell.swatch.directory)
    XCTAssertFalse(cell.bar.isHidden)
    let bitmap = try drawing(cell)
    let swatch = try color(
      bitmap, at: NSPoint(x: cell.swatch.frame.midX, y: cell.swatch.frame.midY), in: cell)
    XCTAssertEqual(swatch.redComponent * 255, 0x33, accuracy: 2)
    XCTAssertEqual(swatch.greenComponent * 255, 0x66, accuracy: 2)
    XCTAssertEqual(swatch.blueComponent * 255, 0xCC, accuracy: 2)
    // Half the bar is filled: the filled ink is much more opaque than the track.
    let bar = cell.bar.frame
    let filled = try color(
      bitmap, at: NSPoint(x: bar.minX + bar.width * 0.25, y: bar.midY), in: cell)
    let track = try color(
      bitmap, at: NSPoint(x: bar.minX + bar.width * 0.75, y: bar.midY), in: cell)
    XCTAssertGreaterThan(filled.alphaComponent, 0.3, "filled \(filled)")
    XCTAssertLessThan(track.alphaComponent, 0.15, "track \(track)")
  }

  func testCellShowsACollapsedDirectoryWithItsDisclosureAndGraySquare() throws {
    let cell = cell(row(name: "small-files", mapRGB: nil, expandable: true))
    XCTAssertFalse(cell.disclosure.isHidden)
    XCTAssertEqual(cell.disclosure.state, .off)
    XCTAssertEqual(cell.disclosure.accessibilityIdentifier(), "disclosure-small-files")
    XCTAssertEqual(cell.disclosure.accessibilityLabel(), "Expand small-files")
    XCTAssertTrue(cell.swatch.directory)
    XCTAssertEqual(cell.swatch.color, ContentsTree.Swatch.directoryColor)
  }

  func testCellShowsAnExpandedDirectoryAsCollapsible() throws {
    let cell = cell(row(name: "small-files", mapRGB: nil, expandable: true, expanded: true))
    XCTAssertFalse(cell.disclosure.isHidden)
    XCTAssertEqual(cell.disclosure.state, .on)
    XCTAssertEqual(cell.disclosure.accessibilityLabel(), "Collapse small-files")
  }

  /// 14 points per level, at most 120: semantic depth stays in the state.
  func testCellIndentsByDepthUpToOneHundredTwentyPoints() throws {
    let nested = cell(row(depth: 3))
    XCTAssertEqual(nested.disclosure.frame.minX, 3 * 14 + 2)
    XCTAssertEqual(nested.swatch.frame.minX, 3 * 14 + 24)
    XCTAssertEqual(nested.name.frame.minX, 3 * 14 + 39)
    let deep = cell(row(depth: 40))
    XCTAssertEqual(deep.depth, 40)
    XCTAssertEqual(deep.disclosure.frame.minX, 122)
    XCTAssertEqual(deep.name.frame.minX, 159)
    // The bar keeps its place at the trailing edge; the name ends before it.
    XCTAssertEqual(nested.bar.frame.maxX, 356)
    XCTAssertLessThanOrEqual(nested.name.frame.maxX, nested.bar.frame.minX)
  }

  /// A reused cell that shows a row before its page arrives hides the old swatch and bar.
  func testCellShowsALoadingRowWithoutSwatchOrBarAfterReuse() throws {
    let cell = cell(row(name: "small-files", mapRGB: nil, expandable: true, expanded: true))
    cell.apply(.loading)
    cell.layoutSubtreeIfNeeded()
    XCTAssertEqual(cell.name.stringValue, "Loading…")
    XCTAssertEqual(cell.name.accessibilityIdentifier(), "loading-row")
    XCTAssertTrue(cell.swatch.isHidden)
    XCTAssertTrue(cell.bar.isHidden)
    XCTAssertTrue(cell.disclosure.isHidden)
    XCTAssertEqual(cell.disclosure.state, .off)
    XCTAssertEqual(cell.disclosure.accessibilityIdentifier(), "loading-disclosure")
    XCTAssertEqual(cell.disclosure.accessibilityLabel(), "Loading")
    XCTAssertEqual(cell.depth, 0)
  }

  /// The size label has the name's centered frame and repeats its text as the help tag.
  func testSizeCellShowsTheSizeWithTheNameFrameAndAHelpTag() throws {
    let size = ContentsTree.SizeCell(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
    size.apply(row())
    size.layoutSubtreeIfNeeded()
    XCTAssertEqual(size.label.stringValue, "4.1 KB")
    XCTAssertEqual(size.label.toolTip, "4.1 KB")
    let name = cell(row()).name.frame
    XCTAssertEqual(size.label.frame.minY, name.minY)
    XCTAssertEqual(size.label.frame.height, name.height)
    size.apply(.loading)
    XCTAssertEqual(size.label.stringValue, "")
  }

  /// Fixture rows of the focused root and an expanded directory.
  func testTreeRowStateMapsFixtureRowsAgainstTheFocusTotal() async throws {
    let model = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", "presentation"], environment: [:],
      numbers: NativeNumberFormat(locale: Locale(identifier: "en_US")))
    defer { model.shutdown() }
    try await waitUntil { model.records != nil && !model.loading && !model.replacingSession }
    let total = try XCTUnwrap(model.records?.focus.subtreeBytes)
    func state(_ name: String) throws -> TreeRowState {
      let row = try XCTUnwrap(model.outline?.rows.first { $0.entry.displayName == name })
      return TreeRowState(row: row, focusTotal: total, numbers: model.numbers)
    }
    let directory = try state("small-files")
    XCTAssertEqual(
      directory,
      TreeRowState(
        loaded: true, depth: 0, name: "small-files", nameIdentifier: "entry-small-files",
        mapRGB: nil, percent: 63, size: "8.2 KB", expandable: true, expanded: false,
        disclosureIdentifier: "disclosure-small-files", disclosureLabel: "Expand small-files"))
    let file = try state("large-file")
    XCTAssertNotNil(file.mapRGB)
    XCTAssertEqual(file.percent, 32)
    XCTAssertEqual(file.size, "4.1 KB")
    XCTAssertFalse(file.expandable)
    XCTAssertEqual(try state("zero-byte").percent, 0)
    // A directory without items has no disclosure.
    XCTAssertFalse(try state("trash").expandable)
    model.expand(
      try XCTUnwrap(model.outline?.rows.first { $0.entry.displayName == "small-files" }?.entry),
      expanded: true)
    try await waitUntil { !model.treeEditing }
    XCTAssertEqual(try state("small-files").disclosureLabel, "Collapse small-files")
    XCTAssertTrue(try state("small-files").expanded)
    XCTAssertEqual(try state("small-00").depth, 1)
    XCTAssertEqual(try state("small-00").percent, 2)
  }
}
