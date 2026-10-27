import SwiftUI

@main struct ExplorerApp: App {
  @NSApplicationDelegateAdaptor(ExplorerDelegate.self) private var delegate
  var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class ExplorerDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
  NSMenuItemValidation
{
  private var window: NSWindow?
  private var model: ExplorerModel?
  func applicationDidFinishLaunching(_ notification: Notification) {
    let testing = ProcessInfo.processInfo.environment["DI_MODEL_TEST"] == "1"
    let model =
      testing
      ? ExplorerModel(
        arguments: ["--fixture-mode", "--scenario", "presentation"], environment: [:])
      : ExplorerModel()
    self.model = model
    installNavigationMenu()
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
  }
  private func installNavigationMenu() {
    let main = NSApp.mainMenu ?? NSMenu()
    let navigation = NSMenu(title: "Navigate")
    for (title, action, key) in [
      ("Open Selected Directory", #selector(openSelectedDirectory), NSDownArrowFunctionKey),
      ("Enclosing Directory", #selector(openEnclosingDirectory), NSUpArrowFunctionKey),
    ] {
      let item = NSMenuItem(
        title: title, action: action, keyEquivalent: String(UnicodeScalar(key)!))
      item.keyEquivalentModifierMask = .command
      item.target = self
      navigation.addItem(item)
    }
    let item = NSMenuItem(title: "Navigate", action: nil, keyEquivalent: "")
    item.submenu = navigation
    main.addItem(item)
    NSApp.mainMenu = main
  }
  @objc private func openSelectedDirectory() {
    if let entry = model?.selected, entry.kind == .directory { model?.focus(entry.key) }
  }
  @objc private func openEnclosingDirectory() { model?.focusParent() }
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let model, !model.working, !model.loading, !model.replacingSession, model.pending == nil
    else {
      return false
    }
    return menuItem.action == #selector(openSelectedDirectory)
      ? model.selected?.kind == .directory : model.records?.focus.parent != nil
  }
  func windowWillClose(_ notification: Notification) { model?.shutdown() }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
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

struct ExplorerView: View {
  @Bindable var model: ExplorerModel
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let records = model.records {
        header(records)
        Divider()
        HSplitView {
          VStack(spacing: 0) {
            ContentsTree(model: model)
            Divider()
            selectionSummary
          }.frame(minWidth: 360, idealWidth: 400, maxWidth: 480)
          VStack(alignment: .leading, spacing: 0) {
            DiagramView(model: model).padding(10).overlay(alignment: .topLeading) {
              if model.fixtureMode { MotionProbe(motion: model.motion) }
            }
            Divider()
            footer
          }.frame(minWidth: 350)
        }
        .overlay(alignment: .top) {
          if model.loading || model.working || model.replacingSession { progress }
        }
      } else {
        VStack(spacing: 20) {
          Image(systemName: "externaldrive").font(.system(size: 42)).foregroundStyle(.secondary)
          Text("What should we measure?").font(.title.weight(.semibold))
          Text("Nothing is scanned until you choose.").foregroundStyle(.secondary)
          HStack {
            Button("Choose Folder…", action: model.createSnapshot)
              .buttonStyle(.borderedProminent).accessibilityIdentifier("create-inventory")
            Button("Open Snapshot…", action: model.openSnapshot).accessibilityIdentifier(
              "open-snapshot")
          }.disabled(model.fixtureMode || model.replacingSession)
          if let last = model.lastInventory {
            VStack(alignment: .leading, spacing: 6) {
              Text("Last scan").font(.caption).foregroundStyle(.secondary)
              HStack {
                VStack(alignment: .leading) {
                  Text(last.rootName).lineLimit(1).truncationMode(.middle).help(last.rootName)
                  Text(last.scannedAt.formatted(date: .abbreviated, time: .shortened)).font(
                    .caption
                  ).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open", action: model.openLastInventory).accessibilityIdentifier("open-last")
                  .disabled(model.replacingSession || model.fixtureMode)
              }
            }.padding(12).frame(width: 420).background(
              .quaternary, in: RoundedRectangle(cornerRadius: 8))
          }
          if model.fixtureMode {
            Text("Fixture mode • Native access disabled").accessibilityIdentifier("fixture-locked")
          }
          if let error = model.error {
            Text("Could not open the inventory.").foregroundStyle(.red)
            DisclosureGroup("Details") { Text(error).textSelection(.enabled) }.frame(maxWidth: 460)
          }
          if model.loading || model.replacingSession { progress.frame(maxWidth: 500) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .sheet(item: $model.pending, onDismiss: model.cancelConfirmation) { pending in
      confirmation(pending)
    }
  }
  var progress: some View {
    HStack(spacing: 10) {
      ProgressView().controlSize(.small)
      if let sample = model.scan.progress {
        Text(model.scan.label).accessibilityIdentifier("scan-phase")
        Text("\(model.numbers.count(sample.itemsExamined)) items examined").monospacedDigit()
          .foregroundStyle(.secondary).accessibilityIdentifier("scan-items")
        Spacer()
        Button("Stop", action: model.scan.stop).disabled(!sample.cancellable)
          .accessibilityIdentifier("stop-scan")
      } else {
        Text(
          model.replacingSession ? "Preparing inventory… Previous view is read-only." : "Working…")
        Spacer()
      }
    }.font(.callout).padding(12).background(.bar)
  }
  func header(_ r: ViewRecords) -> some View {
    HStack(spacing: 12) {
      Menu {
        Button("Open Snapshot…", action: model.openSnapshot).accessibilityIdentifier(
          "open-snapshot")
        Button("Choose Folder…", action: model.createSnapshot).accessibilityIdentifier(
          "create-inventory")
        Button("Open Last Scan", action: model.openLastInventory).disabled(
          model.lastInventory == nil)
      } label: {
        Image(systemName: "externaldrive")
      }
      .disabled(model.fixtureMode || model.working || model.replacingSession)
      .help("Inventory")
      ScrollView(.horizontal) {
        HStack(spacing: 4) {
          if r.ancestors.first?.key.sameEntry(other: r.status.root.key) != true,
            r.focus.parent != nil
          {
            Button(r.breadcrumbName(r.status.root)) { model.focus(r.status.root.key) }
              .help(r.breadcrumbHelp(r.status.root)).accessibilityIdentifier("breadcrumb-root")
            Text("…").foregroundStyle(.secondary)
          }
          ForEach(Array(r.ancestors.enumerated()), id: \.offset) { i, entry in
            Button(r.breadcrumbName(entry)) { model.focus(entry.key) }.help(r.breadcrumbHelp(entry))
              .accessibilityIdentifier(
                "breadcrumb-\(i)")
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
          }
          Text(r.breadcrumbName(r.focus)).help(r.breadcrumbHelp(r.focus)).fontWeight(.semibold)
            .accessibilityIdentifier("focus-name")
        }.buttonStyle(.plain)
      }.scrollIndicators(.hidden).disabled(model.working || model.replacingSession)
      HStack(spacing: 5) {
        if r.status.scanPartial {
          badge("Partial", id: "partial").help(
            "\(model.numbers.count(r.status.counters.errors)) scan errors")
        }
        if r.status.stale { badge("Incomplete", id: "stale").help("Some sizes are unknown") }
        if r.status.dirty {
          badge("Not saved", id: "dirty").help("Live changes differ from the saved snapshot")
        }
      }
      VStack(alignment: .trailing, spacing: 2) {
        Text(model.numbers.storage(r.status.root.subtreeBytes) + " recorded").font(
          .callout.weight(.semibold)
        )
        .monospacedDigit().accessibilityIdentifier("scope-total")
        Text(
          model.scanDate.map { "Scanned " + $0.formatted(date: .abbreviated, time: .shortened) }
            ?? "Scan time unavailable"
        )
        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("scan-date")
      }.fixedSize()
      Button("Refresh Directory", systemImage: "arrow.clockwise", action: model.refresh)
        .disabled(model.working || model.loading || model.replacingSession)
        .accessibilityIdentifier("refresh").help(
          "Rescan the focused directory and descendants in memory; the saved snapshot is unchanged."
        )
    }.padding(.horizontal, 12).padding(.vertical, 10).background(.bar)
  }
  func badge(_ title: String, id: String) -> some View {
    Text(title).font(.caption.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 3)
      .background(.quaternary, in: Capsule()).accessibilityIdentifier(id)
  }
  var selectionSummary: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let entry = model.selected {
        HStack(alignment: .firstTextBaseline) {
          Button(entryName(entry), action: model.revealSelection).buttonStyle(.plain)
            .font(.headline).lineLimit(1).truncationMode(.middle)
            .help("Show selected item in list").accessibilityIdentifier("selected-name")
          Spacer(minLength: 4)
          Text(
            model.numbers.storage(
              entry.kind == .directory ? entry.subtreeBytes : entry.accountedBytes)
          )
          .font(.callout.weight(.semibold)).monospacedDigit().accessibilityIdentifier(
            "selected-usage")
        }
        HStack {
          Text(
            entry.kind == .directory
              ? "\(model.numbers.count(entry.childCount)) direct items · Recorded allocation"
              : "Recorded allocation")
          if entry.kind == .file && entry.accountedBytes < entry.allocatedBytes {
            Text(
              model.records?.status.stale == true
                ? "Shared or unknown size" : "Shared space counted elsewhere"
            )
            .accessibilityIdentifier("sharing-note")
          }
        }.font(.caption).foregroundStyle(.secondary).lineLimit(2)
        Text(model.selectedDisplayPath ?? "Loading path…")
          .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
          .help(model.selectedDisplayPath ?? "").accessibilityIdentifier("selected-path")
        HStack(spacing: 6) {
          Button("Reveal in Finder", action: model.revealInFinder)
            .disabled(model.selectedURL == nil || model.working || model.replacingSession)
            .accessibilityIdentifier("reveal-finder")
          Spacer(minLength: 0)
          Button("Delete…", role: .destructive) { model.prepare(.permanentlyDelete) }
            .disabled(!model.canAct).accessibilityIdentifier("delete")
          Button("Move to Trash") { model.prepare(.trash) }.disabled(!model.canAct)
            .accessibilityIdentifier("trash")
        }.controlSize(.small)
        if entry.parent == nil {
          Text("Inventory root is protected.").font(.caption).accessibilityIdentifier(
            "root-protected")
        }
      } else if let text = model.aggregateText {
        Text(text).foregroundStyle(.secondary)
        Button("Show Directory Contents") { if let key = model.aggregate { model.focus(key) } }
      } else {
        Text("Nothing selected").font(.headline)
        Text("Click to select. Double-click a directory to focus it.").foregroundStyle(.secondary)
        if let root = model.records?.status.root {
          Button("Select Inventory Root") { model.select(root) }.accessibilityIdentifier(
            "inspect-root")
        }
      }
    }.font(.callout).frame(maxWidth: .infinity, minHeight: 122, alignment: .leading)
      .padding(14).background(.bar)
  }
  var footer: some View {
    // Outcome and diagnostic publication must not resize the map during result motion.
    ScrollView {
      VStack(alignment: .leading, spacing: 5) {
        if model.error != nil {
          HStack {
            Text("Could not complete the request.").foregroundStyle(.red).accessibilityIdentifier(
              "error")
            Button("Dismiss") { model.error = nil }
          }
        }
        if let outcome = model.outcome {
          Text(outcome).textSelection(.enabled).accessibilityIdentifier("outcome")
        }
        if model.error != nil || !model.issues.isEmpty {
          DisclosureGroup("Details") {
            ScrollView {
              if let error = model.error {
                Text(error).textSelection(.enabled).accessibilityIdentifier("error-details")
              }
              Text(model.issues.joined(separator: "\n")).textSelection(.enabled).frame(
                maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 100)
          }.accessibilityIdentifier("issues")
        }
        Text(
          model.hover.map {
            ($0.actionable ? "" : "Grouped in ")
              + ($0.relativePath.isEmpty ? entryName($0.entry) : displayPath($0.relativePath))
              + " · "
              + model.numbers.storage($0.bytes)
          } ?? "Recorded disk usage · Shared space is counted once · Deleting may free less space"
        )
        .lineLimit(1).frame(height: 18).accessibilityIdentifier("hover-name")
        if let p = model.picture, p.bitmap.aggregatePixels > 0 || model.rasterReduced {
          Text(
            "Some map detail is grouped or reduced at this scale; zoom or expand the tree to see more."
          )
          .foregroundStyle(.secondary)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.frame(height: 100).font(.caption).padding(12)
  }
  func confirmation(_ pending: PendingConfirmation) -> some View {
    let permanent = pending.details.action == .permanentlyDelete
    let directory = pending.details.metadata.kind == .directory
    let target = directory ? "this directory and its contents" : "this file"
    return VStack(alignment: .leading, spacing: 16) {
      Text(permanent ? "Permanently delete \(target)?" : "Move \(target) to Trash?")
        .font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("confirmation-title")
      ViewThatFits(in: .vertical) {
        confirmationPath(pending)
        ScrollView { confirmationPath(pending) }
      }.frame(maxHeight: 260)
      Text(
        permanent
          ? (directory
            ? "This cannot be undone. An error may leave some contents undeleted."
            : "This cannot be undone.")
          : "Trash may not free space until emptied. If Trash fails, nothing will be permanently deleted."
      ).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("confirmation-warning")
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: model.cancelConfirmation).keyboardShortcut(
          .defaultAction
        ).accessibilityIdentifier("cancel-action")
        Button(
          permanent ? "Permanently Delete" : "Move to Trash", role: .destructive,
          action: model.execute
        ).accessibilityIdentifier("confirm-action")
      }
    }.padding(24).frame(width: 510).onExitCommand(perform: model.cancelConfirmation)
  }
  private func confirmationPath(_ pending: PendingConfirmation) -> some View {
    Text(displayPath(pending.details.rawPath)).font(.body).textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("confirmation-path")
  }

}
