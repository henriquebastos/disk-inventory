import AppKit
import SwiftUI

struct DiagramView: NSViewRepresentable {
  let model: ExplorerModel
  func makeNSView(context: Context) -> MapView { MapView() }
  func updateNSView(_ view: MapView, context: Context) {
    view.model = model
    view.hoverRect = model.hover?.rect
    view.selectionRect = model.selection.region
    view.motionFrame = model.motion.previous?.frame
    view.motionPlanned = model.motion.plan != nil
    view.motionFraction = model.motion.fraction
    view.selectedKey = model.selection.entry?.key
    view.updatePicture()
  }
  @MainActor final class MapView: NSView {
    var model: ExplorerModel? { didSet { commands.model = model } }
    let commands = ExplorerCommandTarget(model: nil)
    // The drawn inputs besides the picture. Only a changed value marks the view for display,
    // so a model update that changes none of them, such as a selection path, draws nothing.
    var hoverRect: Rectangle? { didSet { if hoverRect != oldValue { needsDisplay = true } } }
    var selectionRect: Rectangle? {
      didSet { if selectionRect != oldValue { needsDisplay = true } }
    }
    /// The frame of the result motion's previous picture.
    var motionFrame: DiagramFrame? {
      didSet { if motionFrame !== oldValue { needsDisplay = true } }
    }
    var motionPlanned = false { didSet { if motionPlanned != oldValue { needsDisplay = true } } }
    var motionFraction = 0.0 { didSet { if motionFraction != oldValue { needsDisplay = true } } }
    /// The selected item, for the frame sampler only. AppKit observes the model properties that
    /// `draw` reads and draws again when one changes. `selection` is one value, so `draw` reads
    /// this copy: a new path or tree row then draws nothing.
    var selectedKey: EntryKey?
    var image: NSImage?
    var frameObject: DiagramFrame?
    var elements: [Target] = []
    var area: NSTrackingArea?
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
        needsDisplay = true
      }
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
      drawProbe?.record(
        selected: selectedKey,
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
