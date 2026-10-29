import AppKit
import SwiftUI
import XCTest

@testable import DiskInventory

@MainActor final class AppearanceModelTests: XCTestCase {
  func load(_ scenario: String = "presentation", environment: [String: String] = [:])
    async throws -> ExplorerModel
  {
    let model = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", scenario], environment: environment)
    try await waitUntil { model.records != nil && !model.loading && !model.replacingSession }
    return model
  }
  func ownedStorage() throws -> (URL, ManagedInventoryStorage) {
    let base = try XCTUnwrap(
      ProcessInfo.processInfo.environment["DI_TEST_ROOT"],
      "Tests require an explicit external artifact root")
    let root = URL(fileURLWithPath: base).appendingPathComponent(
      "appearance-\(UUID().uuidString)")
    return (root, ManagedInventoryStorage(root: root.appendingPathComponent("support")))
  }

  func testDiagramPictureIsSRGBAndCarriesAppearance() async throws {
    let model = try await load()
    let session = try XCTUnwrap(model.session)
    let focus = try XCTUnwrap(model.records?.focus.key)
    XCTAssertEqual(model.picture?.image.colorSpace?.name, CGColorSpace.sRGB)
    for appearance in [
      MapAppearance.light, .dark, .lightIncreasedContrast, .darkIncreasedContrast,
    ] {
      let picture = try DiagramPicture(
        session: session, focus: focus, size: CGSize(width: 64, height: 48),
        appearance: appearance)
      XCTAssertEqual(picture.appearance, appearance)
      XCTAssertEqual(picture.image.colorSpace?.name, CGColorSpace.sRGB)
      XCTAssertEqual(picture.image.width, 64)
    }
  }

  func testMapAppearanceMapsSystemAppearanceNames() throws {
    let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
    let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
    XCTAssertEqual(MapAppearance(aqua), .light)
    XCTAssertEqual(MapAppearance(dark), .dark)
    // Real Increase Contrast can keep the plain names; the workspace flag still applies.
    XCTAssertEqual(MapAppearance(aqua, increaseContrast: true), .lightIncreasedContrast)
    XCTAssertEqual(MapAppearance(dark, increaseContrast: true), .darkIncreasedContrast)
    for (name, appearance) in [
      ("light", MapAppearance.light), ("dark", .dark),
      ("light-contrast", .lightIncreasedContrast), ("dark-contrast", .darkIncreasedContrast),
    ] {
      XCTAssertEqual(MapAppearance(fixtureName: name), appearance)
      XCTAssertEqual(appearance.fixtureName, name)
      XCTAssertEqual(appearance.increasedContrast, name.hasSuffix("contrast"))
      XCTAssertEqual(appearance.dark, name.hasPrefix("dark"))
    }
    XCTAssertNil(MapAppearance(fixtureName: "high-contrast"))
    XCTAssertNil(MapAppearance(fixtureName: ""))
  }

  func testFixtureAppearanceOverrideIsIgnoredOutsideFixtureMode() throws {
    let (root, storage) = try ownedStorage()
    defer { try? FileManager.default.removeItem(at: root) }
    let production = ExplorerModel(
      arguments: [], environment: ["DI_APPEARANCE": "light-contrast"], storage: storage)
    XCTAssertNil(production.fixtureAppearance)
    let system = MapAppearance(
      NSApplication.shared.effectiveAppearance,
      increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    XCTAssertEqual(production.mapAppearance, system)
    let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
    XCTAssertEqual(
      production.mapAppearance(for: aqua),
      NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        ? .lightIncreasedContrast : .light)
    production.shutdown()
    XCTAssertFalse(FileManager.default.fileExists(atPath: storage.root.path))
    let fixture = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", "presentation"],
      environment: ["DI_APPEARANCE": "light-contrast"])
    XCTAssertEqual(fixture.fixtureAppearance, .lightIncreasedContrast)
    XCTAssertEqual(fixture.mapAppearance, .lightIncreasedContrast)
    // The override wins over the view appearance.
    XCTAssertEqual(
      fixture.mapAppearance(for: try XCTUnwrap(NSAppearance(named: .darkAqua))),
      .lightIncreasedContrast)
    fixture.shutdown()
    let unknown = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", "presentation"],
      environment: ["DI_APPEARANCE": "sepia"])
    XCTAssertNil(unknown.fixtureAppearance)
    unknown.shutdown()
  }

  func testAppearanceChangeRebuildsOnlyTheMapFromSavedData() async throws {
    // This fixture sleeps one second for live metadata, but not for saved queries.
    let model = try await load("metadata-delay")
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = DiagramView.MapView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    view.model = model
    // The window reports the view size first; let that resize rebuild finish.
    window.contentView = view
    try await waitUntil {
      model.picture.map { CGFloat($0.bitmap.width) == model.viewport.width } == true
        && !model.loading
    }
    try await Task.sleep(for: .milliseconds(300))
    let large = try XCTUnwrap(model.outline?.rows.first { $0.entry.displayName == "large-file" })
    model.select(large.entry)
    // The selected row comes with the tree reveal, which replaces the outline slice.
    try await waitUntil {
      model.selectionPath == "large-file" && model.selectedRegion != nil
        && model.selectedRow != nil
    }
    let session = try XCTUnwrap(model.session)
    let tree = try XCTUnwrap(model.tree)
    let rows = model.outlineToken
    let builds = model.diagramBuilds
    let before = try XCTUnwrap(model.picture)
    let other: NSAppearance.Name = before.appearance.dark ? .aqua : .darkAqua
    let expected = model.mapAppearance(for: try XCTUnwrap(NSAppearance(named: other)))
    XCTAssertNotEqual(expected, before.appearance)
    let start = ContinuousClock.now
    // AppKit calls viewDidChangeEffectiveAppearance, as for a system appearance change.
    view.appearance = NSAppearance(named: other)
    XCTAssertEqual(model.mapAppearance, expected)
    try await waitUntil { model.picture?.appearance == expected && !model.loading }
    let elapsed = start.duration(to: .now)
    print("APPEARANCE rebuild after debounce: \(elapsed)")
    XCTAssertLessThan(elapsed, .milliseconds(900))
    XCTAssertEqual(model.diagramBuilds, builds + 1)
    XCTAssertTrue(model.session === session)
    XCTAssertTrue(model.tree === tree)
    XCTAssertTrue(model.outlineToken === rows)
    XCTAssertFalse(model.scan.polling)
    XCTAssertNil(model.scan.progress)
    XCTAssertEqual(model.selected?.displayName, "large-file")
    XCTAssertEqual(model.selectionPath, "large-file")
    try await waitUntil { model.selectedRegion != nil }
    XCTAssertEqual(model.picture?.bitmap.width, before.bitmap.width)
    // The same appearance again, and the workspace notification, build nothing new.
    view.appearance = NSAppearance(named: other)
    NSWorkspace.shared.notificationCenter.post(
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(model.diagramBuilds, builds + 1)
  }

  func testTreeUsesInsetContentStyleAndAdaptiveDirectorySwatch() async throws {
    let model = try await load("dix")
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: ContentsTree(model: model))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    func table(in view: NSView) -> ContentsTree.Table? {
      if let table = view as? ContentsTree.Table { return table }
      return view.subviews.compactMap { table(in: $0) }.first
    }
    let table = try XCTUnwrap(table(in: host))
    XCTAssertEqual(table.style, .inset)
    XCTAssertEqual(table.effectiveStyle, .inset)
    func cell(_ name: String) throws -> ContentsTree.Cell {
      let row = try XCTUnwrap(model.outline?.rows.firstIndex { $0.entry.displayName == name })
      let cell = try XCTUnwrap(
        table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ContentsTree.Cell)
      cell.layoutSubtreeIfNeeded()
      return cell
    }
    let projects = try cell("Projects")
    XCTAssertTrue(projects.swatch.directory)
    XCTAssertTrue(projects.swatch.color == NSColor.systemGray)
    func srgb(_ name: NSAppearance.Name) throws -> [CGFloat] {
      var components: [CGFloat] = []
      try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
        let c = projects.swatch.color.usingColorSpace(.sRGB)!
        components = [c.redComponent, c.greenComponent, c.blueComponent]
      }
      return components
    }
    // The old fixed gray was 0x7a7a7f in every appearance.
    XCTAssertNotEqual(try srgb(.aqua).map { ($0 * 255).rounded() }, [0x7a, 0x7a, 0x7f])
    XCTAssertNotEqual(try srgb(.darkAqua).map { ($0 * 255).rounded() }, [0x7a, 0x7a, 0x7f])
    // The inset style keeps the disclosure, swatch, name and bar order inside the cell.
    for item in [projects, try cell("Movie.mov")] {
      XCTAssertGreaterThan(item.bounds.width, 0)
      XCTAssertLessThanOrEqual(item.disclosure.frame.maxX, item.swatch.frame.minX)
      XCTAssertLessThanOrEqual(item.swatch.frame.maxX, item.name.frame.minX)
      XCTAssertLessThanOrEqual(item.name.frame.maxX, item.bar.frame.minX)
      XCTAssertLessThanOrEqual(item.bar.frame.maxX, item.bounds.width)
      XCTAssertEqual(item.swatch.frame.midY, item.name.frame.midY, accuracy: 0.5)
    }
  }
}
