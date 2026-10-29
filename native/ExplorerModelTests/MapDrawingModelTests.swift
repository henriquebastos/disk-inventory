import AppKit
import XCTest

@testable import DiskInventory

/// The map view's own drawing (hover outline, selection dim and ring) over the Rust bitmap,
/// drawn offscreen at 2x into an sRGB bitmap: component picture tests without a window.
@MainActor final class MapDrawingModelTests: XCTestCase {
  /// Top-down sRGB pixels of a drawing at 2 pixels per point.
  struct Drawing {
    let bytes: [UInt8]
    let width: Int
    func rgb(_ x: Int, _ y: Int) -> [Int] {
      let at = (y * width + x) * 4
      return [Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2])]
    }
    /// Pixel index of a point coordinate.
    func px(_ point: CGFloat) -> Int { Int((point * 2).rounded(.down)) }
    /// Mean color of the 3x3 pixels around a point.
    func mean(_ point: CGPoint) -> [Double] {
      var sum = [0.0, 0.0, 0.0]
      for dy in -1...1 {
        for dx in -1...1 {
          for (c, v) in rgb(px(point.x) + dx, px(point.y) + dy).enumerated() { sum[c] += Double(v) }
        }
      }
      return sum.map { $0 / 9 }
    }
  }
  /// A 1000 x 700-point map view over a 2000 x 1400-pixel picture of `scenario` in the fixture
  /// `appearance`.
  func mapView(_ scenario: String, appearance: String) async throws -> DiagramView.MapView {
    let model = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", scenario],
      environment: ["DI_APPEARANCE": appearance])
    try await waitUntil { model.records != nil && !model.loading && !model.replacingSession }
    model.resize(CGSize(width: 2000, height: 1400))
    try await waitUntil {
      model.picture?.bitmap.width == 2000 && model.picture?.bitmap.height == 1400
        && !model.loading
    }
    XCTAssertEqual(model.picture?.appearance.fixtureName, appearance)
    let view = DiagramView.MapView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
    view.model = model
    view.updatePicture()
    return view
  }
  func draw(_ view: DiagramView.MapView, appearance: String) throws -> Drawing {
    let (width, height) = (Int(view.bounds.width) * 2, Int(view.bounds.height) * 2)
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    // The map view is flipped: point y runs down, like the bitmap rows.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 2, y: -2)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    try XCTUnwrap(NSAppearance(named: appearance.hasPrefix("dark") ? .darkAqua : .aqua))
      .performAsCurrentDrawingAppearance { view.draw(view.bounds) }
    NSGraphicsContext.restoreGraphicsState()
    let data = try XCTUnwrap(context.data)
    return Drawing(
      bytes: Array(
        UnsafeBufferPointer(
          start: data.assumingMemoryBound(to: UInt8.self),
          count: width * height * 4)),
      width: width)
  }
  /// WCAG 2 contrast ratio of two 8-bit colors.
  static func contrast(_ a: [Int], _ b: [Int]) -> Double {
    func luminance(_ c: [Int]) -> Double {
      let linear = c.map { v -> Double in
        let v = Double(v) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
      }
      return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
  }
  /// Contrast of the seam pixel against the next pixel inside the tile on the left, top, right
  /// and bottom edge, each the minimum over three points; the seam is the first or second
  /// pixel inside the edge.
  func edgeContrasts(_ tile: CGRect, _ d: Drawing) -> [Double] {
    func first(_ point: CGFloat) -> Int { Int((point * 2 - 0.5).rounded(.up)) }
    let (x0, y0, x1, y1) = (first(tile.minX), first(tile.minY), first(tile.maxX), first(tile.maxY))
    return (0..<4).map { side in
      [0.25, 0.5, 0.75].map { fraction -> Double in
        let x = x0 + Int(Double(x1 - x0) * fraction)
        let y = y0 + Int(Double(y1 - y0) * fraction)
        let pairs: [((Int, Int), (Int, Int))] =
          switch side {
          case 0: [((x0, y), (x0 + 1, y)), ((x0 + 1, y), (x0 + 2, y))]
          case 1: [((x, y0), (x, y0 + 1)), ((x, y0 + 1), (x, y0 + 2))]
          case 2: [((x1 - 1, y), (x1 - 2, y)), ((x1 - 2, y), (x1 - 3, y))]
          default: [((x, y1 - 1), (x, y1 - 2)), ((x, y1 - 2), (x, y1 - 3))]
          }
        return pairs.map { Self.contrast(d.rgb($0.0.0, $0.0.1), d.rgb($0.1.0, $0.1.1)) }.max()!
      }.min()!
    }
  }

  /// Increase Contrast: an opaque 2-point hover outline, black (the label color) in light and
  /// white in dark. Without Increase Contrast: the 1-point white outline at 70% opacity.
  func testHoverStrokeFollowsAppearanceAndIsOpaqueTwoPointsWithIncreasedContrast() async throws {
    for appearance in ["light", "dark", "light-contrast", "dark-contrast"] {
      let view = try await mapView("presentation", appearance: appearance)
      let target = try XCTUnwrap(
        view.model?.picture?.targets.first { $0.entry.displayName == "large-file" })
      view.hoverRect = target.rect
      let d = try draw(view, appearance: appearance)
      let tile = view.rect(target.rect)
      // Pixels from the left and the top edge. With 2 points (4 pixels), the first three are
      // fully covered and the sixth is inside the tile.
      let (left, top) = (Int((tile.minX * 2).rounded(.up)), Int((tile.minY * 2).rounded(.up)))
      let (midX, midY) = (d.px(tile.midX), d.px(tile.midY))
      let edge = (0..<3).map { d.rgb(left + $0, midY) } + (0..<3).map { d.rgb(midX, top + $0) }
      let inside = [d.rgb(left + 5, midY), d.rgb(midX, top + 5)]
      for (pixel, interior) in zip([edge[0], edge[3]], inside) {
        switch appearance {
        case "light-contrast":
          XCTAssertLessThanOrEqual(pixel.max()!, 10, "\(appearance): opaque black \(pixel)")
        case "dark-contrast":
          XCTAssertGreaterThanOrEqual(pixel.min()!, 250, "\(appearance): opaque white \(pixel)")
        default:
          // White at 70% over the tile: lighter than the tile, but not opaque white.
          XCTAssertGreaterThan(pixel.min()!, interior.max()!, "\(appearance): white outline")
          XCTAssertLessThan(pixel.min()!, 250, "\(appearance): 70% opacity \(pixel)")
        }
      }
      if appearance.hasSuffix("contrast") {
        for pixel in edge {
          XCTAssertLessThanOrEqual(
            zip(pixel, edge[0]).map { abs($0 - $1) }.max()!, 3, "\(appearance): solid 2 points")
        }
        for pixel in inside {
          XCTAssertGreaterThan(
            zip(pixel, edge[0]).map { abs($0 - $1) }.max()!, 40, "\(appearance): 2 points wide")
        }
      }
    }
  }

  /// The selection dims the rest of the map by 12% black (the design uses 28%). Every
  /// unselected seam stays visible, and the selected block keeps its white ring.
  func testSelectionDimIsLightAndKeepsUnselectedSeamsVisible() async throws {
    for appearance in ["dark", "light"] {
      let view = try await mapView("prototype-home", appearance: appearance)
      let picture = try XCTUnwrap(view.model?.picture)
      // Up to six of the largest tiles with a unique name, each at least 40 points.
      let names = Dictionary(grouping: picture.targets, by: \.entry.displayName)
      typealias Tile = (name: String, frame: CGRect)
      let all: [Tile] = picture.targets.map { ($0.entry.displayName, view.rect($0.rect)) }
      let large = all.filter { (tile: Tile) -> Bool in
        names[tile.name]?.count == 1 && tile.frame.width >= 40 && tile.frame.height >= 40
      }
      let area = { (tile: Tile) -> CGFloat in tile.frame.width * tile.frame.height }
      let tiles = large.sorted { area($0) > area($1) }.prefix(6)
      XCTAssertGreaterThanOrEqual(tiles.count, 3, appearance)
      let (selected, others) = (tiles.first!, tiles.dropFirst())
      let before = try draw(view, appearance: appearance)
      view.selectionRect = picture.targets.first { $0.entry.displayName == selected.name }?.rect
      let after = try draw(view, appearance: appearance)
      var factors: [Double] = []
      var seams = 99.0
      for other in others {
        let point = CGPoint(x: other.frame.midX, y: other.frame.midY)
        let (a, b) = (after.mean(point), before.mean(point))
        factors.append((0..<3).map { a[$0] / b[$0] }.reduce(0, +) / 3)
        seams = min(seams, edgeContrasts(other.frame, after).min()!)
      }
      let dim = factors.reduce(0, +) / Double(factors.count)
      // The ring: 2 points of white centered 1.5 points inside the selected block's edge.
      let ring = after.mean(CGPoint(x: selected.frame.midX, y: selected.frame.minY + 1.5))
      XCTAssertEqual(dim, 0.88, accuracy: 0.03, "\(appearance): 12% dim")
      XCTAssertGreaterThanOrEqual(seams, 1.8, "\(appearance): unselected seams stay visible")
      XCTAssertGreaterThan(ring.min()!, 235, "\(appearance): white selection ring")
    }
  }
}
