import SwiftUI

@main struct ExplorerApp: App {
  @NSApplicationDelegateAdaptor(ExplorerDelegate.self) private var delegate
  var body: some Scene { Settings { EmptyView() } }
}

@MainActor final class ExplorerDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var window: NSWindow?
  private var model: ExplorerModel?
  func applicationDidFinishLaunching(_ notification: Notification) {
    let model = ExplorerModel()
    self.model = model
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1380, height: 850),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = "Disk Inventory"
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
  func windowWillClose(_ notification: Notification) { model?.cancelConfirmation() }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationWillTerminate(_ notification: Notification) { model?.cancelConfirmation() }
}

struct ExplorerView: View {
  @Bindable var model: ExplorerModel
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Button("Open Snapshot…", systemImage: "folder", action: model.openSnapshot).disabled(
          model.fixtureMode || model.working || model.replacingSession
        ).accessibilityIdentifier("open-snapshot")
        Button("Create Inventory…", systemImage: "plus", action: model.createSnapshot).disabled(
          model.fixtureMode || model.working || model.replacingSession
        ).accessibilityIdentifier("create-inventory")
        Spacer()
        if model.loading || model.working || model.replacingSession {
          ProgressView().controlSize(.small)
          Text(
            model.replacingSession
              ? "Loading new inventory… Previous view is read-only." : "Working…"
          ).font(.caption)
        }
      }.padding(12).background(.bar)
      Divider()
      if let records = model.records {
        header(records)
        selectionSummary
        Divider()
        HSplitView {
          contents(records).frame(minWidth: 300, idealWidth: 330, maxWidth: 420)
          VStack(alignment: .leading, spacing: 8) {
            Text("DISK USAGE").font(.caption.weight(.semibold)).foregroundStyle(
              .secondary)
            GeometryReader { geometry in
              Treemap(
                records: records, selected: model.selected, onSelect: model.select,
                onFocus: { model.focus($0) }, onRollup: model.selectRollup
              )
              .clipped()
              .onAppear { model.resize(geometry.size) }
              .onChange(of: geometry.size) { _, size in model.resize(size) }
            }
            Text(
              "Select a block or a row. Double-click a directory to open it."
            )
            .font(.caption).foregroundStyle(.secondary)
          }.padding(14).frame(minWidth: 350)
        }
        Divider()
        footer
      } else {
        VStack(spacing: 16) {
          Image(systemName: "externaldrive").font(.system(size: 48)).foregroundStyle(.secondary)
          Text("Explore allocated storage").font(.largeTitle)
          Text(
            "Open a saved inventory, or choose an explicit root to scan.\nNothing is scanned automatically."
          ).multilineTextAlignment(.center)
          if model.fixtureMode {
            Text("Fixture mode • Native access disabled").accessibilityIdentifier("fixture-locked")
          }
          if let error = model.error {
            Text("Could not open the inventory.").foregroundStyle(.red)
            DisclosureGroup("Details") { Text(error).textSelection(.enabled) }
          }
          if model.loading { ProgressView("Loading inventory…") }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .sheet(item: $model.pending, onDismiss: model.cancelConfirmation) { pending in
      confirmation(pending)
    }
  }
  func header(_ r: ViewRecords) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Disk usage").font(.title.weight(.semibold))
          Text("Inventory root: \(displayPath(r.status.rootPath))").textSelection(.enabled)
            .lineLimit(2)
          Text(exactBytes(r.status.root.subtreeBytes) + " recorded").font(.headline)
            .accessibilityIdentifier("scope-total")
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 4) {
          if r.status.simulated {
            Text("SIMULATED • No native filesystem operations").fontWeight(.semibold)
              .accessibilityIdentifier("simulated")
          }
          if r.status.scanPartial {
            Text("PARTIAL • \(r.status.counters.errors) scan errors").accessibilityIdentifier(
              "partial")
          }
          if r.status.stale {
            Text("INCOMPLETE • Some sizes unknown").accessibilityIdentifier("stale")
          }
          if r.status.dirty {
            Text("CHANGED • Snapshot not saved").accessibilityIdentifier(
              "dirty")
          }
        }.font(.caption).foregroundStyle(.primary).padding(10).background(
          .yellow.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
      }
      HStack {
        Button("Back", systemImage: "chevron.left", action: model.back).disabled(
          model.history.isEmpty || model.working
        ).accessibilityIdentifier("back")
        Text("View focus:").foregroundStyle(.secondary)
        ScrollView(.horizontal) {
          HStack {
            ForEach(Array(r.ancestors.enumerated()), id: \.offset) { i, entry in
              Button(entryName(entry)) { model.focus(entry.key) }.accessibilityIdentifier(
                "breadcrumb-\(i)")
              Image(systemName: "chevron.right").font(.caption2)
            }
            Text(entryName(r.focus)).fontWeight(.semibold).accessibilityIdentifier("focus-name")
          }
        }.scrollIndicators(.hidden)
        Button("Refresh Directory", action: model.refresh).disabled(
          model.working || model.loading || model.replacingSession
        )
        .accessibilityIdentifier("refresh")
      }
    }.padding(16)
  }
  func contents(_ r: ViewRecords) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Contents").font(.headline)
      Text("Single click selects · Double click opens a directory").font(.caption).foregroundStyle(
        .secondary)
      ContentsTable(
        entries: r.page.entries, selected: model.selected, onSelect: model.select,
        onFocus: { model.focus($0) })
      HStack {
        Button("Previous") { model.page(model.offset >= 100 ? model.offset - 100 : 0) }.disabled(
          model.offset == 0 || model.loading)
        Spacer()
        Button("Next") { if let next = r.page.nextOffset { model.page(next) } }.disabled(
          r.page.nextOffset == nil || model.loading
        ).accessibilityIdentifier("next-page")
      }
      Text(
        "\(model.offset + (r.page.entries.isEmpty ? 0 : 1))–\(model.offset + UInt64(r.page.entries.count)) of \(r.page.total)"
      )
      .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("page-range")
    }.padding(12)
  }
  var selectionSummary: some View {
    HStack(alignment: .center, spacing: 16) {
      if let entry = model.selected {
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text(entryName(entry)).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
              .help(entryName(entry)).accessibilityIdentifier("selected-name")
            Text(
              "Recorded: "
                + exactBytes(entry.kind == .directory ? entry.subtreeBytes : entry.accountedBytes)
            )
            .accessibilityIdentifier("selected-usage")
            if entry.kind == .file && entry.accountedBytes < entry.allocatedBytes {
              Text(
                model.records?.status.stale == true
                  ? "Shared or unknown size" : "Shared space counted elsewhere"
              ).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("sharing-note")
            }
          }
          if let path = model.selectionPath {
            Text(path.isEmpty ? "/" : path).font(.caption).foregroundStyle(.secondary)
              .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
              .help(path).accessibilityIdentifier("selected-path")
          }
        }
        Spacer(minLength: 0)
        if entry.kind == .directory {
          Button("Open Directory") { model.focus(entry.key) }.accessibilityIdentifier(
            "focus-selected")
        }
        if entry.parent == nil {
          Text("Inventory root is protected.").font(.caption).accessibilityIdentifier(
            "root-protected")
        }
        Button("Move to Trash…") { model.prepare(.trash) }.disabled(!model.canAct)
          .accessibilityIdentifier("trash")
        Button("Permanently Delete…", role: .destructive) { model.prepare(.permanentlyDelete) }
          .disabled(!model.canAct).accessibilityIdentifier("delete")
      } else if let text = model.rollupText {
        Text(text).foregroundStyle(.secondary)
        Button("Show Directory Contents") { if let key = model.rollup { model.focus(key) } }
      } else {
        Text("Select a file or directory to see its size and free up space.").foregroundStyle(
          .secondary)
        Spacer()
        if let root = model.records?.status.root {
          Button("Select Inventory Root") { model.select(root) }.accessibilityIdentifier(
            "inspect-root")
        }
      }
    }.frame(height: 48).padding(.horizontal, 16)
  }
  var footer: some View {
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
      Text("Recorded disk usage · Shared space is counted once · Deleting may free less space")
        .foregroundStyle(.secondary)
    }.font(.caption).padding(12)
  }
  func confirmation(_ pending: PendingConfirmation) -> some View {
    let permanent = pending.details.action == .permanentlyDelete
    let directory = pending.details.metadata.kind == .directory
    let target = directory ? "this directory and its contents" : "this file"
    return VStack(alignment: .leading, spacing: 16) {
      Text(permanent ? "Permanently delete \(target)?" : "Move \(target) to Trash?")
        .font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("confirmation-title")
      if model.records?.status.simulated == true {
        Text("SIMULATED • Memory filesystem only").accessibilityIdentifier("confirmation-simulated")
      }
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
          .cancelAction
        ).accessibilityIdentifier("cancel-action")
        Button(
          permanent ? "Permanently Delete" : "Move to Trash", role: .destructive,
          action: model.execute
        ).accessibilityIdentifier("confirm-action")
      }
    }.padding(24).frame(width: 510)
  }
  private func confirmationPath(_ pending: PendingConfirmation) -> some View {
    Text(displayPath(pending.details.rawPath)).font(.body).textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("confirmation-path")
  }

}
