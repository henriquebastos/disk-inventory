import AppKit
import SwiftUI

struct ContentsTable: NSViewRepresentable {
  var entries: [EntryRecord]
  var selected: EntryRecord?
  var onSelect: (EntryRecord) -> Void
  var onFocus: (EntryKey) -> Void
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    let table = NSTableView()
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bytes")))
    table.tableColumns[0].title = "Name"
    table.tableColumns[0].width = 170
    table.tableColumns[1].title = "Subtree bytes"
    table.tableColumns[1].width = 135
    table.rowHeight = 28
    table.usesAlternatingRowBackgroundColors = true
    table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
    table.dataSource = context.coordinator
    table.delegate = context.coordinator
    table.target = context.coordinator
    table.doubleAction = #selector(Coordinator.openDirectory)
    table.setAccessibilityIdentifier("contents-table")
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    let c = context.coordinator
    c.parent = self
    guard let table = scroll.documentView as? NSTableView else { return }
    c.updating = true
    let changed =
      c.byteCounts != entries.map(\.subtreeBytes) || c.keys.count != entries.count
      || zip(c.keys, entries).contains { !$0.sameEntry(other: $1.key) }
    if changed {
      c.keys = entries.map(\.key)
      c.byteCounts = entries.map(\.subtreeBytes)
      table.reloadData()
    }
    if let selected,
      let index = entries.firstIndex(where: { $0.key.sameEntry(other: selected.key) })
    {
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    } else {
      table.deselectAll(nil)
    }
    c.updating = false
  }
  @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var parent: ContentsTable
    var updating = false
    var keys: [EntryKey] = []
    var byteCounts: [UInt64] = []
    init(_ parent: ContentsTable) { self.parent = parent }
    func numberOfRows(in tableView: NSTableView) -> Int { parent.entries.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
      let entry = parent.entries[row]
      let name = column?.identifier.rawValue == "name"
      let text = NSTextField(
        labelWithString: name
          ? (entry.kind == .directory ? "▸ " : "") + entryName(entry)
          : entry.subtreeBytes.formatted())
      text.lineBreakMode = .byTruncatingMiddle
      text.font =
        name ? .systemFont(ofSize: 12) : .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
      text.setAccessibilityIdentifier(
        name ? "entry-\(entry.displayName)" : "bytes-\(entry.displayName)")
      text.toolTip = name ? entryName(entry) : exactBytes(entry.subtreeBytes)
      return text
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
      guard !updating, let table = notification.object as? NSTableView,
        parent.entries.indices.contains(table.selectedRow)
      else { return }
      parent.onSelect(parent.entries[table.selectedRow])
    }
    @objc func openDirectory(_ table: NSTableView) {
      guard parent.entries.indices.contains(table.clickedRow) else { return }
      let entry = parent.entries[table.clickedRow]
      if entry.kind == .directory { parent.onFocus(entry.key) }
    }
  }
}

struct Treemap: NSViewRepresentable {
  var records: ViewRecords
  var selected: EntryRecord?
  var onSelect: (EntryRecord) -> Void
  var onFocus: (EntryKey) -> Void
  var onRollup: (EntryKey, UInt64) -> Void
  func makeNSView(context: Context) -> MapView {
    let view = MapView()
    view.setAccessibilityElement(true)
    view.setAccessibilityEnabled(true)
    view.setAccessibilityRole(.group)
    view.setAccessibilityLabel("Treemap")
    return view
  }
  func updateNSView(_ view: MapView, context: Context) {
    view.content = self
    view.updateAccessibilityHeaders()
    view.needsDisplay = true
  }
  @MainActor final class MapView: NSView {
    var content: Treemap?
    private var headerElements: [GroupHeaderElement] = []
    override var isFlipped: Bool { true }
    let colors: [NSColor] = [
      NSColor(red: 0.22, green: 0.43, blue: 0.49, alpha: 1),
      NSColor(red: 0.44, green: 0.37, blue: 0.58, alpha: 1),
      NSColor(red: 0.30, green: 0.48, blue: 0.37, alpha: 1),
      NSColor(red: 0.58, green: 0.36, blue: 0.24, alpha: 1),
    ]
    func rect(_ r: Rectangle) -> NSRect { NSRect(x: r.x, y: r.y, width: r.width, height: r.height) }
    override func draw(_ dirtyRect: NSRect) {
      NSColor.windowBackgroundColor.setFill()
      bounds.fill()
      guard let c = content else { return }
      let headers = headerRegions().map { region in
        (
          region.rect, entryName(c.records.groupEntries[region.index]),
          c.selected?.key.sameEntry(other: c.records.layout.groups[region.index].directory) == true
        )
      }
      for (i, tile) in c.records.layout.tiles.enumerated() {
        let r = rect(tile.rect)
        // Color is presentation only: siblings share their core-returned parent group.
        let group =
          c.records.layout.groups.firstIndex { group in
            tile.parent?.sameEntry(other: group.directory) == true
          } ?? 0
        colors[group % colors.count].setFill()
        r.fill()
        NSColor.white.withAlphaComponent(0.65).setStroke()
        NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let entry = c.records.tileEntries[i]
        if let key = entry?.key, c.selected?.key.sameEntry(other: key) == true {
          NSColor.selectedControlColor.setStroke()
          let border = NSBezierPath(rect: r.insetBy(dx: 2, dy: 2))
          border.lineWidth = 4
          border.stroke()
        }
        if r.width > 72 && r.height > 38 {
          let text: String
          if let entry {
            text = "\(entryName(entry))\n\(tile.bytes.formatted()) B"
          } else {
            text = "Other entries +\ndirectory allocation"
          }
          let paragraph = NSMutableParagraphStyle()
          paragraph.lineBreakMode = .byTruncatingTail
          var labelRect = r.insetBy(dx: 7, dy: 6)
          if headers.contains(where: { $0.0.intersects(labelRect) }) {
            labelRect.origin.y += 22
            labelRect.size.height = max(0, labelRect.height - 22)
          }
          (text as NSString).draw(
            in: labelRect,
            withAttributes: [
              .font: NSFont.systemFont(ofSize: 12, weight: .medium),
              .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
            ])
        }
      }
      for group in c.records.layout.groups {
        NSColor.labelColor.withAlphaComponent(0.8).setStroke()
        let border = NSBezierPath(rect: rect(group.rect).insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()
      }
      // Selection is an overlay on the core group rectangle, never additional area.
      for group in c.records.layout.groups
      where c.selected?.key.sameEntry(other: group.directory) == true {
        let r = rect(group.rect).insetBy(dx: 3, dy: 3)
        NSColor.black.setStroke()
        let border = NSBezierPath(rect: r)
        border.lineWidth = 6
        border.stroke()
        NSColor.white.setStroke()
        border.lineWidth = 3
        border.stroke()
      }
      for (r, title, selected) in headers {
        (selected ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.75)).setFill()
        r.fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        ((selected ? "Selected · " : "") + title as NSString).draw(
          in: r.insetBy(dx: 4, dy: 2),
          withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
          ])
      }
    }
    override func accessibilityChildren() -> [Any]? { headerElements }
    override func viewDidMoveToWindow() { updateAccessibilityHeaders() }
    override func layout() {
      super.layout()
      updateAccessibilityHeaders()
    }
    func updateAccessibilityHeaders() {
      guard let c = content, let window else { return }
      headerElements = headerRegions().map { region in
        let i = region.index
        let group = c.records.layout.groups[i]
        let rect = region.rect
        let element = GroupHeaderElement()
        element.setAccessibilityElement(true)
        element.setAccessibilityEnabled(true)
        element.setAccessibilityRole(.button)
        element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
        element.setAccessibilityLabel(entryName(c.records.groupEntries[i]))
        element.setAccessibilityParent(self)
        element.setAccessibilityIdentifier("group-header-\(c.records.groupEntries[i].displayName)")
        element.setAccessibilityValue(
          c.selected?.key.sameEntry(other: group.directory) == true
            ? "Selected directory region" : "Directory region")
        element.select = { c.onSelect(c.records.groupEntries[i]) }
        return element
      }
    }
    @MainActor final class GroupHeaderElement: NSAccessibilityElement {
      var select: (() -> Void)?
      override func accessibilityPerformPress() -> Bool {
        select?()
        return select != nil
      }
    }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
      headerElements.reversed().first { $0.accessibilityFrame().contains(point) } ?? self
    }
    // Labels are overlays: omit occluded headers, prioritizing the selected directory.
    // Drawing, accessibility and mouse input share the same visible header regions.
    func headerRegions() -> [(index: Int, rect: NSRect)] {
      guard let c = content else { return [] }
      var regions = c.records.layout.groups.enumerated().compactMap {
        i, group -> (index: Int, rect: NSRect)? in
        guard let rect = headerRect(group) else { return nil }
        return (i, rect)
      }
      if let selected = regions.firstIndex(where: {
        c.selected?.key.sameEntry(other: c.records.layout.groups[$0.index].directory) == true
      }) {
        regions.append(regions.remove(at: selected))
      }
      return regions.enumerated().compactMap { i, region in
        regions.dropFirst(i + 1).contains(where: { $0.rect.intersects(region.rect) }) ? nil : region
      }
    }
    func headerRect(_ group: GroupRecord) -> NSRect? {
      let r = rect(group.rect)
      guard group.depth > 0, r.width > 120, r.height > 80 else { return nil }
      return NSRect(x: r.minX + 3, y: r.minY + 3, width: min(r.width - 6, 180), height: 20)
    }
    override func mouseDown(with event: NSEvent) {
      guard let c = content else { return }
      let point = convert(event.locationInWindow, from: nil)
      for region in headerRegions().reversed() where region.rect.contains(point) {
        c.onSelect(c.records.groupEntries[region.index])
        if event.clickCount == 2 { c.onFocus(c.records.layout.groups[region.index].directory) }
        return
      }
      for (i, tile) in c.records.layout.tiles.enumerated() where rect(tile.rect).contains(point) {
        switch tile.kind {
        case .entry:
          if let entry = c.records.tileEntries[i] {
            c.onSelect(entry)
            if event.clickCount == 2 && entry.kind == .directory { c.onFocus(entry.key) }
          }
        case .rollup(let directory, let count): c.onRollup(directory, count)
        }
        break
      }
    }
  }
}
