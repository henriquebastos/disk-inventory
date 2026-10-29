import AppKit
import SwiftUI

/// Tree usage-bar width as a percent of the focus total, rounded half up without
/// floating point. Nonzero entries keep a 2% sliver; zero or unknown usage stays empty.
func usageBarPercent(_ bytes: UInt64, of total: UInt64) -> Int {
  guard bytes > 0, total > 0 else { return 0 }
  let rounded = (UInt128(bytes) * 100 + UInt128(total / 2)) / UInt128(total)
  return Int(min(100, max(2, rounded)))
}

struct ContentsTree: NSViewRepresentable {
  let model: ExplorerModel
  func makeCoordinator() -> Coordinator { Coordinator(model) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    let table = Table()
    table.setAccessibilityIdentifier("entry-tree")
    table.setAccessibilityRole(.outline)
    table.rowHeight = 26
    table.usesAlternatingRowBackgroundColors = false
    // A content outline: the inset style draws the opaque system content background.
    table.style = .inset
    let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    name.title = "Name"
    name.width = 240
    let size = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
    size.title = "Disk usage"
    size.headerCell.alignment = .right
    size.width = 120
    table.addTableColumn(name)
    table.addTableColumn(size)
    table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
    table.delegate = context.coordinator
    table.dataSource = context.coordinator
    table.target = context.coordinator
    table.doubleAction = #selector(Coordinator.open)
    table.keyboard = { context.coordinator.key($0) }
    table.contextMenu = { [unowned table] row in context.coordinator.contextMenu(table, row: row) }
    table.navigation = { context.coordinator.model.treeNavigationKey($0) }
    scroll.contentView.postsBoundsChangedNotifications = true
    context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
    ) { [weak table, weak model] _ in
      MainActor.assumeIsolated {
        if let table, let clip = table.enclosingScrollView?.contentView {
          let top = table.convert(
            NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + clip.contentInsets.top), from: clip)
          model?.scrolled(toRow: table.row(at: top))
        }
      }
    }
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    return scroll
  }
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    if let observer = coordinator.scrollObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    coordinator.scrollObserver = nil
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let table = scroll.documentView as? Table else { return }
    let c = context.coordinator
    c.model = model
    c.commands.model = model
    c.updating = true
    table.enumerateAvailableRowViews { rowView, _ in
      (rowView.view(atColumn: 0) as? Cell)?.disclosure.isEnabled = model.visibleDisclosuresEnabled
    }
    if c.offset != model.outline?.offset || c.rows !== model.outlineToken {
      c.offset = model.outline?.offset
      c.rows = model.outlineToken
      table.reloadData()
    }
    if let row = model.selection.row, row < table.numberOfRows {
      table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      if c.revealSerial != model.revealSerial { table.scrollRowToVisible(row) }
      c.revealSerial = model.revealSerial
    } else {
      table.deselectAll(nil)
    }
    if c.scrollSerial != model.scrollSerial {
      // Save/restore the top unobscured row, accounting for AppKit's automatic header inset.
      // `scroll(to:)` does not clamp: a restored row near the end, such as a surviving
      // selection that became the last row, would scroll every other row out of view. So the
      // origin stops where the last row meets the bottom, or at the first row.
      let clip = scroll.contentView
      let first = table.rect(ofRow: 0).minY - clip.contentInsets.top
      let bottom = max(first, table.frame.height - clip.bounds.height)
      let top = table.rect(ofRow: model.restoredScrollRow).minY - clip.contentInsets.top
      clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(top, bottom)))
      scroll.reflectScrolledClipView(clip)
      c.scrollSerial = model.scrollSerial
    }
    c.updating = false
  }
  @MainActor final class Table: NSTableView {
    var keyboard: ((UInt16) -> Bool)?
    var navigation: ((UInt16) -> Bool)?
    var contextMenu: ((Int) -> NSMenu?)?
    var createdCells = 0
    override func menu(for event: NSEvent) -> NSMenu? {
      contextMenu?(row(at: convert(event.locationInWindow, from: nil)))
    }
    override func keyDown(with event: NSEvent) {
      if event.modifierFlags.contains(.command) || event.keyCode == KeyCode.returnKey
        || event.keyCode == KeyCode.enter
      {
        if navigation?(event.keyCode) == true { return }
      }
      if keyboard?(event.keyCode) != true { super.keyDown(with: event) }
    }
  }
  /// Decorative type swatch: the map's file base color, or a neutral directory square.
  @MainActor final class Swatch: NSView {
    /// Adapts to light, dark and Increase Contrast when drawn.
    static let directoryColor = NSColor.systemGray
    private(set) var color = Swatch.directoryColor
    private(set) var directory = true
    func show(mapRGB: UInt32?) {
      directory = mapRGB == nil
      color =
        mapRGB.map {
          NSColor(
            srgbRed: CGFloat($0 >> 16 & 0xff) / 255, green: CGFloat($0 >> 8 & 0xff) / 255,
            blue: CGFloat($0 & 0xff) / 255, alpha: 1)
        } ?? Swatch.directoryColor
      needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
      color.setFill()
      let radius = directory ? 2 : bounds.width / 2
      NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
  }
  /// Decorative usage bar; the size column carries the accessible amount.
  @MainActor final class UsageBar: NSView {
    var percent = 0 { didSet { if percent != oldValue { needsDisplay = true } } }
    var emphasized = false { didSet { if emphasized != oldValue { needsDisplay = true } } }
    override func draw(_ dirtyRect: NSRect) {
      let ink: NSColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
      ink.withAlphaComponent(0.07).setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
      guard percent > 0 else { return }
      ink.withAlphaComponent(emphasized ? 0.85 : 0.35).setFill()
      let fill = NSRect(
        x: 0, y: 0, width: bounds.width * CGFloat(percent) / 100, height: bounds.height)
      NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
    }
  }
  @MainActor final class Cell: NSTableCellView {
    let disclosure = NSButton()
    let swatch = Swatch()
    let name = NSTextField(labelWithString: "")
    let bar = UsageBar()
    var depth: UInt32 = 0
    override var backgroundStyle: NSView.BackgroundStyle {
      didSet { bar.emphasized = backgroundStyle == .emphasized }
    }
    override init(frame: NSRect) {
      super.init(frame: frame)
      addSubview(disclosure)
      addSubview(swatch)
      addSubview(name)
      addSubview(bar)
      swatch.setAccessibilityElement(false)
      bar.setAccessibilityElement(false)
      disclosure.setButtonType(.onOff)
      disclosure.bezelStyle = .disclosure
      disclosure.setAccessibilityRole(.disclosureTriangle)
      disclosure.title = ""
      name.lineBreakMode = .byTruncatingMiddle
      textField = name
    }
    required init?(coder: NSCoder) { nil }
    /// Shows one row. A row that has not loaded keeps its hidden swatch and bar untouched.
    func apply(_ state: TreeRowState) {
      depth = state.depth
      swatch.isHidden = !state.loaded
      bar.isHidden = !state.loaded
      if state.loaded {
        swatch.show(mapRGB: state.mapRGB)
        bar.percent = state.percent
      }
      name.stringValue = state.name
      name.setAccessibilityIdentifier(state.nameIdentifier)
      disclosure.isHidden = !state.expandable
      disclosure.state = state.expanded ? .on : .off
      disclosure.setAccessibilityIdentifier(state.disclosureIdentifier)
      disclosure.setAccessibilityLabel(state.disclosureLabel)
      needsLayout = true
    }
    override func layout() {
      super.layout()
      let indent = min(CGFloat(depth) * 14, 120)
      disclosure.frame = NSRect(x: indent + 2, y: 3, width: 18, height: 20)
      swatch.frame = NSRect(x: indent + 24, y: 8.5, width: 9, height: 9)
      bar.frame = NSRect(x: max(indent + 39, bounds.width - 48), y: 11, width: 44, height: 4)
      name.frame = NSRect(
        x: indent + 39, y: 4, width: max(0, bar.frame.minX - indent - 45), height: 18)
    }
  }
  /// Disk-usage cell. The table stretches a cell to the row height and a label draws its text
  /// at the top, so the label gets the same centered frame as the name in `Cell`.
  @MainActor final class SizeCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
      super.init(frame: frame)
      addSubview(label)
      label.alignment = .right
      label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
      label.lineBreakMode = .byTruncatingTail
      label.setAccessibilityIdentifier("tree-size")
      textField = label
    }
    required init?(coder: NSCoder) { nil }
    func apply(_ state: TreeRowState) {
      label.stringValue = state.size
      label.toolTip = state.size
    }
    override func layout() {
      super.layout()
      label.frame = NSRect(x: 0, y: 4, width: bounds.width, height: 18)
    }
  }
  @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var model: ExplorerModel
    var updating = false
    var offset: UInt64?
    var rows: NSObject?
    var revealSerial = 0
    var scrollSerial = 0
    var scrollObserver: NSObjectProtocol?
    let commands: ExplorerCommandTarget
    init(_ model: ExplorerModel) {
      self.model = model
      commands = ExplorerCommandTarget(model: model)
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
      model.treeInteractive
    }
    func numberOfRows(in tableView: NSTableView) -> Int { Int(model.outline?.total ?? 0) }
    func record(_ row: Int) -> OutlineRow? { model.outlineRow(at: row) }
    func rowState(_ row: Int) -> TreeRowState {
      guard let value = record(row) else { return .loading }
      return TreeRowState(
        row: value, focusTotal: model.records?.focus.subtreeBytes ?? 0, numbers: model.numbers)
    }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
      let name = column?.identifier.rawValue == "name"
      let id = NSUserInterfaceItemIdentifier(name ? "tree-name" : "tree-size")
      let state = rowState(row)
      if name {
        let cell =
          (tableView.makeView(withIdentifier: id, owner: self) as? Cell) ?? Cell(frame: .zero)
        if cell.identifier == nil { (tableView as? Table)?.createdCells += 1 }
        cell.identifier = id
        cell.apply(state)
        cell.disclosure.target = self
        cell.disclosure.action = #selector(toggle(_:))
        cell.disclosure.tag = row
        cell.disclosure.isEnabled = model.canExpandRows
        return cell
      }
      let cell =
        (tableView.makeView(withIdentifier: id, owner: self) as? SizeCell) ?? SizeCell(frame: .zero)
      cell.identifier = id
      cell.apply(state)
      return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
      let view = NSTableRowView()
      let state = rowState(row)
      view.setAccessibilityEnabled(true)
      view.setAccessibilityDisclosureLevel(Int(state.depth))
      if state.expandable { view.setAccessibilityExpanded(state.expanded) }
      return view
    }
    func tableViewSelectionDidChange(_ note: Notification) {
      guard model.treeInteractive, !updating, let table = note.object as? NSTableView,
        let r = record(table.selectedRow)
      else { return }
      model.selectRow(table.selectedRow, entry: r.entry)
    }
    @objc func toggle(_ sender: NSButton) {
      guard model.treeInteractive else { return }
      if let row = record(sender.tag) { model.expand(row.entry, expanded: !row.expanded) }
    }
    @objc func open(_ sender: NSTableView) {
      guard model.treeInteractive else { return }
      if let row = record(sender.clickedRow), row.entry.kind == .directory {
        model.focus(row.entry.key)
      }
    }
    /// A secondary click selects the clicked cached row first, so the menu acts on that row.
    func contextMenu(_ table: NSTableView, row: Int) -> NSMenu? {
      guard model.treeInteractive, let record = record(row) else { return nil }
      if model.selection.entry?.key.sameEntry(other: record.entry.key) != true {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      }
      guard model.selection.entry?.key.sameEntry(other: record.entry.key) == true else {
        return nil
      }
      return commands.menu()
    }
    func key(_ code: UInt16) -> Bool { model.treeArrowKey(code) }
  }
}
