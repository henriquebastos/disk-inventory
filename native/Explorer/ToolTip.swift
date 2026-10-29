import AppKit
import SwiftUI

extension View {
  /// The help tag and the accessibility hint of a view, as `.help` sets them, from an AppKit
  /// tool tip. With SwiftUI `.help`, the explorer's hosting view showed no further help tag
  /// after the pointer rested on any spot without one, such as the map
  /// ("testHelpTagsShowAfterARestOnTheMapAndAfterADelete"). An empty text has no help tag.
  func toolTip(_ text: String) -> some View {
    background(ToolTipArea(text: text).allowsHitTesting(false))
      .accessibilityHint(Text(verbatim: text))
  }
}

/// An AppKit view behind a SwiftUI view that only carries its tool tip. Tool tips follow the
/// pointer, not hit testing, so the view takes no clicks.
struct ToolTipArea: NSViewRepresentable {
  let text: String
  final class Area: NSView {
    /// Clicks, hover and drags reach the views below.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
  }
  func makeNSView(context: Context) -> Area { Area() }
  func updateNSView(_ area: Area, context: Context) {
    let tip = text.isEmpty ? nil : text
    if area.toolTip != tip { area.toolTip = tip }
  }
}
