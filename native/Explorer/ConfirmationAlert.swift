import AppKit
import SwiftUI

/// Presents `model.pending` as a native alert sheet on the explorer window.
/// A SwiftUI sheet draws `role: .destructive` gray on macOS 26; NSAlert draws
/// "Delete Immediately" red and owns Return and Esc. Each alert response calls
/// `execute` or `cancelConfirmation` once.
struct ConfirmationAlert: NSViewRepresentable {
  let model: ExplorerModel
  let pending: PendingConfirmation?

  func makeNSView(context: Context) -> NSView { NSView() }
  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.update(pending, model: model, window: view.window)
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.end() }

  @MainActor final class Coordinator {
    private var shown: (id: UUID, alert: NSAlert)?

    func update(_ pending: PendingConfirmation?, model: ExplorerModel, window: NSWindow?) {
      guard shown?.id != pending?.id else { return }
      end()
      guard let pending, let window else { return }
      let alert = Self.alert(for: pending)
      shown = (pending.id, alert)
      alert.beginSheetModal(for: window) { [weak self] response in
        // `end()` clears `shown` first, so a sheet it closes reports nothing.
        guard let self, self.shown?.id == pending.id else { return }
        self.shown = nil
        if response == .alertFirstButtonReturn {
          model.execute()
        } else {
          model.cancelConfirmation()
        }
      }
    }

    /// Closes the sheet when `pending` cleared for another reason, without a response.
    func end() {
      guard let alert = shown?.alert else { return }
      shown = nil
      alert.window.sheetParent?.endSheet(alert.window)
    }

    static func alert(for pending: PendingConfirmation) -> NSAlert {
      let alert = NSAlert()
      alert.messageText = pending.title
      alert.informativeText = pending.warning ?? ""
      let action = alert.addButton(withTitle: pending.actionTitle)
      action.hasDestructiveAction = pending.actionIsDestructive
      // NSAlert gives the first button Return. Permanent deletion has no default button.
      if !pending.actionIsDefault { action.keyEquivalent = "" }
      action.setAccessibilityIdentifier("confirm-action")
      let cancel = alert.addButton(withTitle: "Cancel")
      cancel.keyEquivalent = "\u{1b}"
      cancel.setAccessibilityIdentifier("cancel-action")
      var details = NSHostingView(rootView: ConfirmationDetailBox(pending: pending, scrolls: false))
      var size = details.fittingSize
      // A long path scrolls inside a bounded box, so the buttons stay on screen.
      if size.height > ConfirmationDetailBox.maximumHeight {
        details = NSHostingView(rootView: ConfirmationDetailBox(pending: pending, scrolls: true))
        size.height = ConfirmationDetailBox.maximumHeight
      }
      details.frame.size = size
      alert.accessoryView = details
      alert.layout()
      identifyText(in: alert.window.contentView, alert: alert)
      return alert
    }

    private static func identifyText(in view: NSView?, alert: NSAlert) {
      for child in view?.subviews ?? [] {
        if let field = child as? NSTextField, field.stringValue == alert.messageText {
          field.setAccessibilityIdentifier("confirmation-title")
        } else if let field = child as? NSTextField, !alert.informativeText.isEmpty,
          field.stringValue == alert.informativeText
        {
          field.setAccessibilityIdentifier("confirmation-warning")
        }
        identifyText(in: child, alert: alert)
      }
    }
  }
}

/// The alert accessory: scope and the full saved path, in system colors.
struct ConfirmationDetailBox: View {
  static let maximumHeight: CGFloat = 180
  let pending: PendingConfirmation
  let scrolls: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(pending.scope).font(.caption)
        .accessibilityIdentifier("confirmation-scope")
      if scrolls { ScrollView { path } } else { path }
    }.padding(10).frame(width: 380, alignment: .topLeading)
      .frame(maxHeight: .infinity, alignment: .top)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }
  private var path: some View {
    Text(displayPath(pending.details.rawPath)).font(.callout).textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("confirmation-path")
  }
}
