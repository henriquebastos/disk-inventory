import SwiftUI

@main struct ExplorerApp: App {
  @NSApplicationDelegateAdaptor(ExplorerDelegate.self) private var delegate
  var body: some Scene {
    Settings { EmptyView() }.commands { ExplorerMenuCommands(state: delegate.menu) }
  }
}

@MainActor
final class ExplorerDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var window: NSWindow?
  private var model: ExplorerModel?
  private var escapeMonitor: Any?
  let menu = ExplorerMenuState()
  func applicationDidFinishLaunching(_ notification: Notification) {
    let testing = ProcessInfo.processInfo.environment["DI_MODEL_TEST"] == "1"
    let model =
      testing
      ? ExplorerModel(
        arguments: ["--fixture-mode", "--scenario", "presentation"], environment: [:])
      : ExplorerModel()
    self.model = model
    menu.model = model
    // Fixture-only appearance for UI acceptance; the system setting is never changed.
    if let appearance = model.fixtureAppearance {
      NSApp.appearance = NSAppearance(named: appearance.dark ? .darkAqua : .aqua)
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1380, height: 850),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = model.windowTitle
    window.contentView = NSHostingView(
      rootView: ExplorerView(model: model).frame(minWidth: 1100, minHeight: 680))
    window.minSize = NSSize(width: 1100, height: 710)
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    if model.fixtureMode && ProcessInfo.processInfo.arguments.contains("--minimum-window") {
      window.setFrame(NSRect(origin: .zero, size: window.minSize), display: false)
    }
    window.center()
    if model.fixtureMode, let screen = NSScreen.screens.first {
      window.setFrameOrigin(
        NSPoint(x: screen.visibleFrame.minX + 30, y: screen.visibleFrame.minY + 30))
    }
    self.window = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      // AppKit calls local monitors on the main thread.
      nonisolated(unsafe) let event = event
      let handled = MainActor.assumeIsolated { self?.clearSelection(on: event) == true }
      return handled ? nil : event
    }
  }
  /// Esc clears the selection while the tree, the map or the window has the keyboard focus.
  /// The map never takes the focus, so a click on it leaves the focus where it was. An
  /// attached confirmation sheet keeps its own Esc (Cancel), and text keeps its own keys.
  func clearSelection(on event: NSEvent) -> Bool {
    guard event.keyCode == KeyCode.escape, let window, event.window === window,
      window.attachedSheet == nil,
      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
      let model, model.canClearSelection
    else { return false }
    let responder = window.firstResponder
    if !(responder is NSTableView), responder is NSText || responder is NSControl { return false }
    model.clearSelection()
    return true
  }
  func windowDidBecomeKey(_ notification: Notification) { menu.explorerWindowIsKey = true }
  func windowDidResignKey(_ notification: Notification) { menu.explorerWindowIsKey = false }
  func windowWillClose(_ notification: Notification) { model?.shutdown() }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

/// Fixture-only accessibility probe naming the appearance of the displayed map picture.
struct MapAppearanceProbe: View {
  let model: ExplorerModel
  var body: some View {
    Color.clear.frame(width: 1, height: 1).accessibilityElement()
      .accessibilityIdentifier("map-appearance")
      .accessibilityLabel(model.picture?.appearance.fixtureName ?? "none")
  }
}

/// The status bar below the map. A separate view observes the hover, so a hover redraws only
/// this line and the map overlay.
struct StatusBar: View {
  let model: ExplorerModel
  var body: some View {
    let text = model.statusText
    Text(text)
      .font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
      .toolTip(text).accessibilityIdentifier("status-path")
      .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
      .padding(.horizontal, 12)
  }
}

/// Fixture-only accessibility probe naming the last result motion for UI acceptance.
/// A separate view keeps per-tick observation out of the explorer body.
struct MotionProbe: View {
  let motion: ResultMotion
  var body: some View {
    Color.clear.frame(width: 1, height: 1).accessibilityElement()
      .accessibilityIdentifier("motion-style")
      .accessibilityLabel(motion.lastStyle.map { "\($0.rawValue) \(motion.lastTicks)" } ?? "none")
  }
}

/// Text keeps the primary label color. The secondary label color measures 3.95:1 on the
/// light window, below the 4.5:1 text minimum, so font size and weight carry the hierarchy.
struct ExplorerView: View {
  @Bindable var model: ExplorerModel
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let records = model.records {
        ExplorerHeaderHost(model: model, records: records)
        Divider()
        HSplitView {
          VStack(spacing: 0) {
            ContentsTree(model: model)
            Divider()
            SelectionCardHost(model: model)
          }.frame(minWidth: 360, idealWidth: 400, maxWidth: 480)
          VStack(alignment: .leading, spacing: 0) {
            DiagramView(model: model).padding(10).overlay(alignment: .topLeading) {
              if model.fixtureMode {
                HStack(spacing: 0) {
                  MotionProbe(motion: model.motion)
                  MapAppearanceProbe(model: model)
                }
              }
            }
            .overlay(alignment: .top) { OutcomeBannerHost(model: model) }
            Divider()
            StatusBar(model: model)
          }.frame(minWidth: 350)
        }
        .overlay(alignment: .top) {
          if model.showsProgressBar { ProgressBarHost(model: model, startScreen: false) }
        }
      } else {
        VStack(spacing: 20) {
          Image(systemName: "externaldrive").font(.system(size: 42)).foregroundStyle(.secondary)
          Text("What should we measure?").font(.title.weight(.semibold))
          Text("Nothing is scanned until you choose.")
          Button("Choose Folder…") { ExplorerCommand.chooseFolder.perform(in: model) }
            .buttonStyle(.borderedProminent).accessibilityIdentifier("create-inventory")
            .disabled(!ExplorerCommand.chooseFolder.isEnabled(in: model))
          if let last = model.lastInventory {
            VStack(alignment: .leading, spacing: 6) {
              Text("Last folder").font(.caption)
              if let path = last.rootName, !path.isEmpty {
                Text(path).lineLimit(1).truncationMode(.middle).toolTip(path)
              }
              Text(last.scannedAt.formatted(date: .abbreviated, time: .shortened)).font(
                .caption
              )
              // The folder name has at most 60 characters, so this row fits the title.
              Button {
                ExplorerCommand.reopenLastFolder.perform(in: model)
              } label: {
                Text(ExplorerCommand.reopenLastFolder.title(in: model)).lineLimit(1)
                  .truncationMode(.middle)
              }
              .accessibilityIdentifier("reopen-last-folder")
              .disabled(!ExplorerCommand.reopenLastFolder.isEnabled(in: model))
              .frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(12).frame(width: 520, alignment: .leading).background(
              .quaternary, in: RoundedRectangle(cornerRadius: 8))
          }
          if model.fixtureMode {
            Text("Fixture mode • Native access disabled").accessibilityIdentifier("fixture-locked")
          }
          if let error = model.error {
            Text("Could not open the inventory.").foregroundStyle(.red)
            DisclosureGroup("Details") { Text(error).textSelection(.enabled) }.frame(maxWidth: 460)
          }
          if model.showsStartScreenProgressBar {
            ProgressBarHost(model: model, startScreen: true).frame(maxWidth: 500)
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(ConfirmationAlert(model: model, pending: model.pending))
  }
}
