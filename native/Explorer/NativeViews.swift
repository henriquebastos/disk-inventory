import AppKit
import SwiftUI

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
    table.style = .sourceList
    let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    name.title = "Name"
    name.width = 240
    let size = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
    size.title = "Disk usage"
    size.width = 120
    table.addTableColumn(name)
    table.addTableColumn(size)
    table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
    table.delegate = context.coordinator
    table.dataSource = context.coordinator
    table.target = context.coordinator
    table.doubleAction = #selector(Coordinator.open)
    table.keyboard = { context.coordinator.key($0) }
    table.navigation = { code in
      let model = context.coordinator.model
      guard !model.loading, !model.working, !model.replacingSession, model.pending == nil else {
        return true
      }
      if code == 126 {
        model.focusParent()
        return true
      }
      if code == 125 || code == 36 || code == 76 {
        if let entry = model.selected, entry.kind == .directory { model.focus(entry.key) }
        return true
      }
      return false
    }
    scroll.contentView.postsBoundsChangedNotifications = true
    context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
    ) { [weak table, weak model] _ in
      MainActor.assumeIsolated {
        if let table, let clip = table.enclosingScrollView?.contentView {
          let top = table.convert(
            NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + clip.contentInsets.top), from: clip)
          model?.scrollRow = UInt64(max(0, table.row(at: top)))
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
    c.updating = true
    if c.offset != model.outline?.offset || c.rows !== model.outlineToken {
      c.offset = model.outline?.offset
      c.rows = model.outlineToken
      table.reloadData()
    }
    if let row = model.selectedRow, row < table.numberOfRows {
      table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      if c.revealSerial != model.revealSerial { table.scrollRowToVisible(row) }
      c.revealSerial = model.revealSerial
    } else {
      table.deselectAll(nil)
    }
    if c.scrollSerial != model.scrollSerial {
      // Save/restore the top unobscured row, accounting for AppKit's automatic header inset.
      let clip = scroll.contentView
      clip.scroll(
        to: NSPoint(
          x: clip.bounds.minX,
          y: table.rect(ofRow: model.restoredScrollRow).minY - clip.contentInsets.top))
      scroll.reflectScrolledClipView(clip)
      c.scrollSerial = model.scrollSerial
    }
    c.updating = false
  }
  @MainActor final class Table: NSTableView {
    var keyboard: ((UInt16) -> Bool)?
    var navigation: ((UInt16) -> Bool)?
    var createdCells = 0
    override func keyDown(with event: NSEvent) {
      if event.modifierFlags.contains(.command) || event.keyCode == 36 || event.keyCode == 76 {
        if navigation?(event.keyCode) == true { return }
      }
      if keyboard?(event.keyCode) != true { super.keyDown(with: event) }
    }
  }
  @MainActor final class Cell: NSTableCellView {
    let disclosure = NSButton()
    let name = NSTextField(labelWithString: "")
    var depth: UInt32 = 0
    override init(frame: NSRect) {
      super.init(frame: frame)
      addSubview(disclosure)
      addSubview(name)
      disclosure.setButtonType(.onOff)
      disclosure.bezelStyle = .disclosure
      disclosure.setAccessibilityRole(.disclosureTriangle)
      disclosure.title = ""
      name.lineBreakMode = .byTruncatingMiddle
      textField = name
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
      super.layout()
      let indent = min(CGFloat(depth) * 14, 120)
      disclosure.frame = NSRect(x: indent + 2, y: 3, width: 18, height: 20)
      name.frame = NSRect(
        x: indent + 24, y: 4, width: max(0, bounds.width - indent - 28), height: 18)
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
    init(_ model: ExplorerModel) { self.model = model }
    func numberOfRows(in tableView: NSTableView) -> Int { Int(model.outline?.total ?? 0) }
    func record(_ row: Int) -> OutlineRow? {
      guard row >= 0, let p = model.outline else { return nil }
      let at = Int64(row) - Int64(p.offset)
      guard at >= 0, at < Int64(p.rows.count) else {
        model.requestRows(UInt64(max(0, row / 128 * 128)))
        return nil
      }
      return p.rows[Int(at)]
    }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
      let name = column?.identifier.rawValue == "name"
      let id = NSUserInterfaceItemIdentifier(name ? "tree-name" : "tree-size")
      let value = record(row)
      if name {
        let cell =
          (tableView.makeView(withIdentifier: id, owner: self) as? Cell) ?? Cell(frame: .zero)
        if cell.identifier == nil { (tableView as? Table)?.createdCells += 1 }
        cell.identifier = id
        cell.depth = value?.depth ?? 0
        cell.name.stringValue = value.map { entryName($0.entry) } ?? "Loading…"
        cell.name.setAccessibilityIdentifier(
          value.map { "entry-\(entryName($0.entry))" } ?? "loading-row")
        cell.disclosure.isHidden = value?.entry.kind != .directory || value?.entry.childCount == 0
        cell.disclosure.state = value?.expanded == true ? .on : .off
        cell.disclosure.target = self
        cell.disclosure.action = #selector(toggle(_:))
        cell.disclosure.tag = row
        cell.disclosure.setAccessibilityIdentifier(
          value.map { "disclosure-\(entryName($0.entry))" } ?? "loading-disclosure")
        cell.disclosure.setAccessibilityLabel(
          value.map { ($0.expanded ? "Collapse " : "Expand ") + entryName($0.entry) } ?? "Loading")
        cell.disclosure.isEnabled =
          !model.loading && !model.working && !model.replacingSession && !model.treeEditing
        cell.needsLayout = true
        return cell
      }
      let cell =
        (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField)
        ?? NSTextField(labelWithString: "")
      cell.identifier = id
      cell.stringValue = value.map { exactBytes($0.entry.subtreeBytes) } ?? ""
      cell.lineBreakMode = .byTruncatingTail
      cell.toolTip = cell.stringValue
      return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
      let view = NSTableRowView()
      let item = record(row)
      view.setAccessibilityEnabled(true)
      view.setAccessibilityDisclosureLevel(Int(item?.depth ?? 0))
      if let item, item.entry.kind == .directory, item.entry.childCount > 0 {
        view.setAccessibilityExpanded(item.expanded)
      }
      return view
    }
    func tableViewSelectionDidChange(_ note: Notification) {
      guard !updating, let table = note.object as? NSTableView, let r = record(table.selectedRow)
      else { return }
      let selectedRow = table.selectedRow
      model.select(r.entry)
      model.selectedRow = selectedRow
    }
    @objc func toggle(_ sender: NSButton) {
      if let row = record(sender.tag) { model.expand(row.entry, expanded: !row.expanded) }
    }
    @objc func open(_ sender: NSTableView) {
      if let row = record(sender.clickedRow), row.entry.kind == .directory {
        model.focus(row.entry.key)
      }
    }
    func key(_ code: UInt16) -> Bool {
      guard code == 123 || code == 124 else { return false }
      guard !model.working, !model.loading, !model.replacingSession, model.pending == nil else {
        return true
      }
      guard let index = model.selectedRow, let row = record(index) else { return false }
      if code == 124 {
        guard row.entry.kind == .directory, row.entry.childCount > 0 else { return true }
        if !row.expanded {
          model.expand(row.entry, expanded: true)
        } else if let child = record(index + 1),
          child.entry.parent?.sameEntry(other: row.entry.key) == true
        {
          model.select(child.entry)
        }
      } else if row.expanded {
        model.expand(row.entry, expanded: false)
      } else {
        model.selectParent(row.entry)
      }
      return true
    }
  }
}

struct DiagramView: NSViewRepresentable {
  let model: ExplorerModel
  func makeNSView(context: Context) -> MapView { MapView() }
  func updateNSView(_ view: MapView, context: Context) {
    view.model = model
    view.hoverRect = model.hover?.rect
    view.selectionRect = model.selectedRegion
    _ = model.motion.fraction
    view.updatePicture()
  }
  @MainActor final class MapView: NSView {
    var model: ExplorerModel?
    var hoverRect: Rectangle?
    var selectionRect: Rectangle?
    var image: NSImage?
    var frameObject: DiagramFrame?
    var elements: [Target] = []
    var area: NSTrackingArea?
    var drawCount = 0
    var lastDrawDuration: Duration = .zero
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
      super.init(frame: frame)
      setAccessibilityElement(false)
      setAccessibilityIdentifier("disk-map")
      setAccessibilityLabel("Disk usage map")
    }
    required init?(coder: NSCoder) { nil }
    func updatePicture() {
      if frameObject !== model?.picture?.frame {
        frameObject = model?.picture?.frame
        image = model?.picture.map {
          NSImage(
            cgImage: $0.image,
            size: NSSize(width: Int($0.bitmap.width), height: Int($0.bitmap.height)))
        }
        updateTargets()
      }
      needsDisplay = true
    }
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let area { removeTrackingArea(area) }
      area = NSTrackingArea(
        rect: bounds,
        options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
        owner: self)
      addTrackingArea(area!)
    }
    override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      reportSize()
    }
    override func viewDidMoveToWindow() {
      window?.acceptsMouseMovedEvents = true
      updateTargets()
      reportSize()
    }
    override func layout() {
      super.layout()
      updateTargets()
      reportSize()
    }
    func reportSize() {
      let scale = window?.backingScaleFactor ?? 1
      model?.resize(CGSize(width: bounds.width * scale, height: bounds.height * scale))
    }
    func rect(_ r: Rectangle) -> NSRect {
      guard let p = model?.picture else { return .zero }
      let sx = bounds.width / CGFloat(p.bitmap.width)
      let sy = bounds.height / CGFloat(p.bitmap.height)
      return NSRect(x: r.x * sx, y: r.y * sy, width: r.width * sx, height: r.height * sy)
    }
    override func draw(_ dirtyRect: NSRect) {
      let start = ContinuousClock.now
      NSColor.windowBackgroundColor.setFill()
      bounds.fill()
      if let motion = model?.motion, let previous = motion.previous, let plan = motion.plan {
        drawMotion(previous, plan: plan, fraction: motion.fraction)
      } else if let previous = model?.motion.previous {
        NSImage(cgImage: previous.image, size: bounds.size).draw(
          in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
          hints: [.interpolation: NSImageInterpolation.none.rawValue])
      } else {
        image?.draw(
          in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
          hints: [.interpolation: NSImageInterpolation.none.rawValue])
      }
      if let r = selectionRect, model?.motion.active != true {
        let shade = NSBezierPath(rect: bounds)
        shade.appendRect(rect(r))
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.28).setFill()
        shade.fill()
      }
      if let r = hoverRect, model?.motion.active != true {
        NSColor.white.withAlphaComponent(0.7).setStroke()
        NSBezierPath(rect: rect(r).insetBy(dx: 0.5, dy: 0.5)).stroke()
      }
      if let r = selectionRect, model?.motion.active != true {
        let path = NSBezierPath(rect: rect(r).insetBy(dx: 1.5, dy: 1.5))
        NSColor.black.setStroke()
        path.lineWidth = 4
        path.stroke()
        NSColor.white.setStroke()
        path.lineWidth = 2
        path.stroke()
      }
      drawCount += 1
      lastDrawDuration = start.duration(to: .now)
    }
    func drawMotion(_ previous: DiagramPicture, plan: RemovalMotionPlan, fraction: Double) {
      let old = NSImage(
        cgImage: previous.image,
        size: NSSize(width: Int(previous.bitmap.width), height: Int(previous.bitmap.height)))
      let fade = plan.style == .fade ? fraction : max(0, fraction * 2 - 1)
      old.draw(
        in: bounds, from: .zero, operation: .sourceOver, fraction: 1 - fade, respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.none.rawValue])
      if plan.style != .fade {
        let source = NSRect(
          x: plan.source.x / Double(previous.bitmap.width) * bounds.width,
          y: plan.source.y / Double(previous.bitmap.height) * bounds.height,
          width: plan.source.width / Double(previous.bitmap.width) * bounds.width,
          height: plan.source.height / Double(previous.bitmap.height) * bounds.height)
        NSColor.windowBackgroundColor.setFill()
        source.fill()
        let t = min(1, fraction * 2)
        var ghost = source.insetBy(dx: source.width * t * 0.3, dy: source.height * t * 0.3)
        if plan.style == .travel, let destination = plan.destination {
          let to = rect(destination)
          ghost.origin.x += (to.midX - source.midX) * t
          ghost.origin.y += (to.midY - source.midY) * t
        }
        // NSImage source coordinates are bottom-up, unlike the flipped native map.
        let crop = NSRect(
          x: plan.source.x, y: Double(previous.bitmap.height) - plan.source.y - plan.source.height,
          width: plan.source.width, height: plan.source.height)
        old.draw(
          in: ghost, from: crop, operation: .sourceOver, fraction: (1 - t) * (1 - fade),
          respectFlipped: true,
          hints: [.interpolation: NSImageInterpolation.none.rawValue])
      }
      image?.draw(
        in: bounds, from: .zero, operation: .sourceOver, fraction: fade, respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.none.rawValue])
    }
    func pointer(_ event: NSEvent, click: Bool) {
      guard let p = model?.picture, bounds.width > 0, bounds.height > 0 else { return }
      let at = convert(event.locationInWindow, from: nil)
      guard bounds.contains(at) else {
        model?.clearHover()
        return
      }
      let x = UInt32(at.x / bounds.width * CGFloat(p.bitmap.width))
      let y = UInt32(at.y / bounds.height * CGFloat(p.bitmap.height))
      // Tracking/move events reject clickCount with an AppKit exception.
      model?.point(x, y, click: click, doubleClick: click && event.clickCount == 2)
    }
    override func mouseMoved(with event: NSEvent) { pointer(event, click: false) }
    override func mouseEntered(with event: NSEvent) { pointer(event, click: false) }
    override func mouseDown(with event: NSEvent) { pointer(event, click: true) }
    override func mouseExited(with event: NSEvent) {
      model?.clearHover()
    }
    func updateTargets() {
      guard let model, let picture = model.picture, let window else {
        elements = []
        setAccessibilityChildren([])
        return
      }
      elements = picture.targets.map { hit in
        let frame = picture.frame
        let x = UInt32(hit.rect.x + hit.rect.width / 2)
        let y = UInt32(hit.rect.y + hit.rect.height / 2)
        // Accessibility clients may retain old targets; do not retain their frame or bitmap.
        let e = Target { [weak model, weak frame] in
          guard let model, let frame, model.picture?.frame === frame, !model.loading,
            !model.replacingSession, !model.working, !model.motion.active
          else { return false }
          model.point(x, y, click: true)
          return true
        }
        e.setAccessibilityElement(true)
        e.setAccessibilityEnabled(true)
        e.setAccessibilityParent(self)
        e.setAccessibilityRole(.button)
        e.setAccessibilityIdentifier("map-file-\(entryName(hit.entry))")
        e.setAccessibilityLabel(entryName(hit.entry))
        e.setAccessibilityFrame(window.convertToScreen(convert(rect(hit.rect), to: nil)))
        return e
      }
      setAccessibilityChildren(elements)
    }
    @MainActor final class Target: NSAccessibilityElement {
      let press: @MainActor @Sendable () -> Bool
      init(press: @escaping @MainActor @Sendable () -> Bool) {
        self.press = press
        super.init()
      }
      override func accessibilityPerformPress() -> Bool {
        let action = press
        return MainActor.assumeIsolated { action() }
      }
    }
  }
}
