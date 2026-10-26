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
  @State private var showsConfirmationHex = false
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
        Divider()
        HSplitView {
          contents(records).frame(minWidth: 300, idealWidth: 330, maxWidth: 420)
          VStack(alignment: .leading, spacing: 8) {
            Text("AREA = ACCOUNTED ALLOCATION").font(.caption.weight(.semibold)).foregroundStyle(
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
              "Borders group directories; they add no bytes. Tiny and zero-attribution entries remain accessible in Contents."
            )
            .font(.caption).foregroundStyle(.secondary)
          }.padding(14).frame(minWidth: 350)
          inspector.frame(width: 290)
        }
        Divider()
        footer(records)
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
          if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
          if model.loading { ProgressView("Loading inventory…") }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .sheet(item: $model.pending, onDismiss: dismissConfirmation) { pending in
      confirmation(pending)
    }
  }
  private func dismissConfirmation() {
    model.cancelConfirmation()
    showsConfirmationHex = false
  }
  func header(_ r: ViewRecords) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Where the allocated space is").font(.title.weight(.semibold))
          Text("Inventory root: \(displayPath(r.status.rootPath))").textSelection(.enabled)
            .lineLimit(2)
          Text(exactBytes(r.status.root.subtreeBytes) + " accounted in scope").font(.headline)
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
            Text("STALE • Unknown allocations; totals incomplete").accessibilityIdentifier("stale")
          }
          if r.status.dirty {
            Text("LIVE INVENTORY CHANGED • Saved snapshot unchanged").accessibilityIdentifier(
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
        "\(model.offset + (r.page.entries.isEmpty ? 0 : 1))–\(model.offset + UInt64(r.page.entries.count)) of \(r.page.total) • Core order, not a global size ranking"
      )
      .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("page-range")
    }.padding(12)
  }
  var inspector: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Text("Inspector").font(.headline)
          if let entry = model.selected {
            Text(entryName(entry)).font(.title3.weight(.semibold)).textSelection(.enabled)
              .accessibilityIdentifier("selected-name")
            if let path = model.selectionPath {
              Text(path.isEmpty ? "/" : path).font(.caption).textSelection(.enabled)
            }
            GroupBox(
              model.records?.status.dirty == true
                ? "Reconciled inventory · not saved" : "Saved inventory"
            ) {
              VStack(alignment: .leading, spacing: 8) {
                value("Allocated (raw)", exactBytes(entry.allocatedBytes))
                value("Accounted (deduplicated)", exactBytes(entry.accountedBytes))
                value("Subtree", exactBytes(entry.subtreeBytes))
              }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Live metadata · separate from inventory") {
              VStack(alignment: .leading, spacing: 8) {
                Text(model.metadataState).font(.caption).accessibilityIdentifier("metadata-state")
                if let m = model.metadata {
                  value("Logical size", exactBytes(m.logicalBytes), id: "logical-size")
                  value("Live allocated", exactBytes(m.allocatedBytes))
                  value(
                    "Modified (Unix seconds)",
                    "\(m.modifiedSeconds).\(String(format: "%09lld", m.modifiedNanoseconds))")
                  value("Created (Unix seconds)", "\(m.createdSeconds)")
                  value("Device / inode", "\(m.device) / \(m.inode)")
                  value(
                    "Links / mode / flags", "\(m.links) / \(String(m.mode, radix: 8)) / \(m.flags)")
                }
              }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if entry.kind == .directory {
              Button("Focus This Directory") { model.focus(entry.key) }.accessibilityIdentifier(
                "focus-selected")
            }
          } else if let text = model.rollupText {
            Text(text)
            Button("Show Directory Contents") { if let key = model.rollup { model.focus(key) } }
          } else {
            Text("Select a rectangle or a contents row. Selection does not change view focus.")
              .foregroundStyle(.secondary)
            if let root = model.records?.status.root {
              Button("Inspect Inventory Root") { model.select(root) }.accessibilityIdentifier(
                "inspect-root")
            }
          }
          Text(
            "Allocation is not guaranteed reclaimable space. Zero attribution is not proof of zero usage; aliases and unknown allocations can have zero attribution."
          ).font(.caption).foregroundStyle(.secondary)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
      }
      if let entry = model.selected {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          if entry.parent == nil {
            Text("Inventory root is protected.").font(.caption).accessibilityIdentifier(
              "root-protected")
          }
          Button("Move to Trash…") { model.prepare(.trash) }.disabled(!model.canAct)
            .accessibilityIdentifier("trash")
          Button("Permanently Delete…", role: .destructive) { model.prepare(.permanentlyDelete) }
            .disabled(!model.canAct).accessibilityIdentifier("delete")
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
  func value(_ title: String, _ text: String, id: String = "") -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        .accessibilityIdentifier(id)
    }
  }
  func footer(_ r: ViewRecords) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      if let error = model.error {
        HStack {
          Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("error")
          Button("Dismiss") { model.error = nil }
        }
      }
      if let outcome = model.outcome {
        Text(outcome).textSelection(.enabled).accessibilityIdentifier("outcome")
      }
      if !model.issues.isEmpty {
        DisclosureGroup("Retained operation issues (\(model.issues.count))") {
          ScrollView {
            Text(model.issues.joined(separator: "\n")).textSelection(.enabled).frame(
              maxWidth: .infinity, alignment: .leading)
          }.frame(maxHeight: 100)
        }.accessibilityIdentifier("issues")
      }
      Text(
        "Observed scope only • Symlinks excluded • \(r.status.counters.mounts) mounts excluded • \(r.layout.tiles.count) tiles / \(r.page.entries.count) rows loaded"
      )
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
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text(displayPath(pending.details.rawPath)).font(.body.monospaced()).textSelection(
            .enabled
          )
          .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("confirmation-path")
          Toggle("Show byte-exact target path (hex)", isOn: $showsConfirmationHex)
            .toggleStyle(.checkbox).accessibilityIdentifier("show-target-hex")
          if showsConfirmationHex {
            Text(pending.details.rawPath.map { String(format: "%02x", $0) }.joined())
              .font(.caption.monospaced()).textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(
                "confirmation-hex")
          }
          Text("Fresh prepared metadata · Target identity held until confirmation or cancellation")
            .font(.caption).foregroundStyle(.secondary)
          if directory {
            Text(
              "Directory entry only, excluding contents. These sizes do not measure everything affected."
            )
            .font(.caption).accessibilityIdentifier("directory-size-scope")
          }
          value(
            directory ? "Logical size (directory entry only)" : "Logical size",
            exactBytes(pending.details.metadata.logicalBytes))
          value(
            directory ? "Allocated (directory entry only)" : "Allocated",
            exactBytes(pending.details.metadata.allocatedBytes))
          value(
            "Device / inode",
            "\(pending.details.metadata.device) / \(pending.details.metadata.inode)")
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.frame(height: 260).accessibilityIdentifier("confirmation-details")
      Text(
        permanent
          ? "This cannot be undone. A directory may be only partly removed if an error occurs."
          : "No permanent-delete fallback. Trash inside this inventory moves allocation rather than reducing scope usage."
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
}
