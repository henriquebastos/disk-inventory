import AppKit
import SwiftUI
import XCTest

@testable import DiskInventory

/// `toolTip(_:)` drawn offscreen: the AppKit view behind the SwiftUI view carries the text, takes
/// no clicks and is no accessibility element. The help tag itself is the UI test
/// "testHelpTagsShowAfterARestOnTheMapAndAfterADelete".
@MainActor final class ToolTipTests: XCTestCase {
  func area(in view: NSView) -> ToolTipArea.Area? {
    if let area = view as? ToolTipArea.Area { return area }
    return view.subviews.lazy.compactMap { self.area(in: $0) }.first
  }

  func testToolTipFollowsItsTextTakesNoClicksAndIsEmptyWithoutText() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    func label(_ help: String) -> AnyView {
      AnyView(Text("Refresh Directory").toolTip(help).frame(width: 200, height: 40))
    }
    let host = NSHostingView(rootView: label("Rescan the focused directory and descendants."))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let tip = try XCTUnwrap(area(in: host), "an AppKit view carries the tool tip")
    XCTAssertEqual(tip.toolTip, "Rescan the focused directory and descendants.")
    XCTAssertGreaterThan(tip.bounds.width, 100, "the tool tip covers its view")
    XCTAssertNil(tip.hitTest(NSPoint(x: tip.frame.midX, y: tip.frame.midY)), "no clicks")
    XCTAssertFalse(tip.isAccessibilityElement())
    host.rootView = label("/Workspace/large-file")
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(area(in: host)?.toolTip, "/Workspace/large-file", "a new text")
    host.rootView = label("")
    host.layoutSubtreeIfNeeded()
    XCTAssertNil(area(in: host)?.toolTip, "an empty text has no tool tip")
  }
}
