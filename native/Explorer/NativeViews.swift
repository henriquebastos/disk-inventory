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
    if let row = model.selectedRow, row < table.numberOfRows {
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
      if event.modifierFlags.contains(.command) || event.keyCode == 36 || event.keyCode == 76 {
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
      let selectedRow = table.selectedRow
      model.select(r.entry)
      model.selectedRow = selectedRow
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
      if model.selected?.key.sameEntry(other: record.entry.key) != true {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      }
      guard model.selected?.key.sameEntry(other: record.entry.key) == true else { return nil }
      return commands.menu()
    }
    func key(_ code: UInt16) -> Bool { model.treeArrowKey(code) }
  }
}

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
    var model: ExplorerModel? { didSet { commands.model = model } }
    let commands = ExplorerCommandTarget(model: nil)
    var hoverRect: Rectangle?
    var selectionRect: Rectangle?
    var image: NSImage?
    var frameObject: DiagramFrame?
    var elements: [Target] = []
    var area: NSTrackingArea?
    var drawCount = 0
    var lastDrawDuration: Duration = .zero
    /// Black over the map outside the selection. The design uses 28%; at 12% every
    /// unselected seam keeps at least 1.97:1 against its own tile (28%: 1.71:1).
    static let selectionDim: CGFloat = 0.12
    /// Fixture-only frame sampler; nil outside fixture mode.
    var drawProbe: SelectionDrawProbe?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
      super.init(frame: frame)
      setAccessibilityElement(false)
      setAccessibilityIdentifier("disk-map")
      setAccessibilityLabel("Disk usage map")
      NSWorkspace.shared.notificationCenter.addObserver(
        self, selector: #selector(accessibilityDisplayOptionsChanged),
        name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
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
      reportAppearance()
    }
    override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      reportAppearance()
    }
    @objc nonisolated func accessibilityDisplayOptionsChanged(_ notification: Notification) {
      Task { @MainActor [weak self] in self?.reportAppearance() }
    }
    func reportAppearance() {
      guard let model else { return }
      model.mapAppearanceChanged(model.mapAppearance(for: effectiveAppearance))
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
        NSColor.black.withAlphaComponent(Self.selectionDim).setFill()
        shade.fill()
      }
      if let r = hoverRect, model?.motion.active != true {
        if let appearance = model?.picture?.appearance, appearance.increasedContrast {
          // Increase Contrast: an opaque 2-point outline inside the block. Light uses the
          // label color (black), which stands out on the light hatch; dark uses white.
          (appearance.dark ? NSColor.white : NSColor.labelColor.withAlphaComponent(1)).setStroke()
          let path = NSBezierPath(rect: rect(r).insetBy(dx: 1, dy: 1))
          path.lineWidth = 2
          path.stroke()
        } else {
          NSColor.white.withAlphaComponent(0.7).setStroke()
          NSBezierPath(rect: rect(r).insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
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
      drawProbe?.record(
        selected: model?.selected?.key,
        shown: selectionRect != nil && model?.motion.active != true)
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
    /// A secondary click inside the hovered block's rectangle; the model selects the block.
    override func menu(for event: NSEvent) -> NSMenu? {
      guard let model, let hover = model.hover,
        rect(hover.rect).contains(convert(event.locationInWindow, from: nil)),
        model.selectHoveredBlockForContextMenu()
      else { return nil }
      return commands.menu()
    }
    func updateTargets() {
      if drawProbe == nil, model?.fixtureMode == true {
        drawProbe = SelectionDrawProbe()
        drawProbe?.setAccessibilityParent(self)
      }
      if let drawProbe, let window {
        drawProbe.setAccessibilityFrame(
          window.convertToScreen(convert(NSRect(x: 0, y: 0, width: 2, height: 2), to: nil)))
      }
      let probe: [NSAccessibilityElement] = drawProbe.map { [$0] } ?? []
      guard let model, let picture = model.picture, let window else {
        elements = []
        setAccessibilityChildren(probe)
        return
      }
      elements = picture.targets.map { hit in
        let frame = picture.frame
        let x = UInt32(hit.rect.x + hit.rect.width / 2)
        let y = UInt32(hit.rect.y + hit.rect.height / 2)
        // Accessibility clients may retain old targets; do not retain their frame or bitmap.
        let e = Target { [weak model, weak frame] in
          guard let model, let frame, model.picture?.frame === frame, model.acceptsMapPointer
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
      setAccessibilityChildren(elements + probe)
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
