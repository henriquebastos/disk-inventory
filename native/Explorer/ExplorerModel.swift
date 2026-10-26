import AppKit
import Observation

func displayPath(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
func exactBytes(_ value: UInt64) -> String {
  "\(value.formatted(.number.grouping(.automatic))) bytes"
}
func entryName(_ entry: EntryRecord) -> String {
  entry.displayName.isEmpty ? "Inventory root" : entry.displayName
}

struct ViewRecords: Sendable {
  let status: SessionStatus
  let focus: EntryRecord
  let ancestors: [EntryRecord]
  let page: ChildrenRecord
  let layout: LayoutRecord
  let tileEntries: [EntryRecord?]
  let groupEntries: [EntryRecord]
}
struct PendingConfirmation: Identifiable {
  let id = UUID()
  let action: PreparedAction
  let details: ConfirmationDetails
}

@MainActor @Observable final class ExplorerModel {
  private(set) var session: ExplorerSession?
  var records: ViewRecords?
  var selected: EntryRecord?
  var selectionPath: String?
  var metadata: MetadataRecord?
  var metadataState = "Select an entry"
  var loading = false
  private(set) var replacingSession = false
  var working = false
  var error: String?
  var outcome: String?
  var issues: [String] = []
  var pending: PendingConfirmation?
  var rollup: EntryKey?
  var rollupText: String?
  var offset: UInt64 = 0
  var history: [EntryKey] = []
  var viewport = CGSize(width: 650, height: 520)
  let fixtureMode: Bool
  private var sessionVersion = 0
  private var viewVersion = 0
  private var selectionVersion = 0
  private var actionVersion = 0
  private struct MetadataRequest {
    let session: ExplorerSession
    let key: EntryKey
    let selectionVersion: Int
    let sessionVersion: Int
  }
  private var metadataRequest: MetadataRequest?
  private var metadataWorkerRunning = false
  private var preparing = false
  private var cancellationTask: Task<Void, Never>?
  private var requestedFocus: EntryKey?
  private var resizeTask: Task<Void, Never>?

  init(
    arguments: [String] = ProcessInfo.processInfo.arguments,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    fixtureMode =
      arguments.contains("--fixture-mode") || arguments.contains("--scenario")
      || environment["DI_UI_TEST"] != nil
    if fixtureMode {
      guard arguments.contains("--fixture-mode"), let i = arguments.firstIndex(of: "--scenario"),
        arguments.indices.contains(i + 1)
      else {
        error = "Fixture mode locked: an explicit scenario is required. Native access disabled."
        return
      }
      let scenario = arguments[i + 1]
      load { try ExplorerSession.fixture(scenario: scenario) }
    }
  }

  func load(_ constructor: @escaping @Sendable () throws -> ExplorerSession) {
    cancelConfirmation()
    metadataRequest = nil
    selected = nil
    metadata = nil
    metadataState = "Select an entry"
    sessionVersion += 1
    viewVersion += 1
    selectionVersion += 1
    let version = sessionVersion
    replacingSession = true
    loading = true
    error = nil
    let cancellation = cancellationTask
    Task {
      await cancellation?.value
      do {
        let result = try await Task.detached(priority: .userInitiated) {
          let s = try constructor()
          return (s, try s.status())
        }.value
        guard version == sessionVersion else { return }
        if fixtureMode && !result.1.simulated { throw CocoaError(.fileReadNoPermission) }
        // No confirmation or late preparation from the retained picture may cross this install.
        cancelConfirmation()
        await cancellationTask?.value
        guard version == sessionVersion else { return }
        // Also invalidate old-session work started while its previous view remained visible.
        viewVersion += 1
        selectionVersion += 1
        metadataRequest = nil
        session = result.0
        requestedFocus = result.1.root.key
        records = nil
        selected = nil
        metadata = nil
        history = []
        issues = []
        outcome = nil
        offset = 0
        await updateView(focus: result.1.root.key)
      } catch { if version == sessionVersion { self.error = String(describing: error) } }
      if version == sessionVersion {
        loading = false
        replacingSession = false
      }
    }
  }

  func updateView(focus: EntryKey, pageOffset: UInt64 = 0) async {
    guard let s = session else { return }
    viewVersion += 1
    let version = viewVersion
    let generation = sessionVersion
    let size = viewport
    loading = true
    do {
      let result = try await Task.detached(priority: .userInitiated) {
        let status = try s.status()
        let entry = try s.selection(key: focus).entry
        var ancestors: [EntryRecord] = []
        var parent = entry.parent
        while let key = parent, ancestors.count < 64 {
          let e = try s.selection(key: key).entry
          ancestors.insert(e, at: 0)
          parent = e.parent
        }
        let page = try s.children(parent: focus, offset: pageOffset, limit: 100)
        let layout = try s.layout(
          focus: focus,
          request: LayoutRequest(
            viewport: Rectangle(x: 0, y: 0, width: max(1, size.width), height: max(1, size.height)),
            maxRectangles: 160, minArea: 180, maxDepth: 8))
        let entries = try layout.tiles.map { tile -> EntryRecord? in
          if case .entry(let key) = tile.kind { return try s.selection(key: key).entry }
          return nil
        }
        let groups = try layout.groups.map { try s.selection(key: $0.directory).entry }
        return ViewRecords(
          status: status, focus: entry, ancestors: ancestors,
          page: page, layout: layout, tileEntries: entries, groupEntries: groups)
      }.value
      guard version == viewVersion, generation == sessionVersion else { return }
      records = result
      offset = pageOffset
      loading = false
    } catch {
      guard version == viewVersion, generation == sessionVersion else { return }
      self.error = String(describing: error)
      loading = false
      if case BridgeError.InvalidEntry = error {
        outcome = "Previous view is no longer available; returning to a known live ancestor."
        await recoverView(s)
      }
    }
  }

  func select(_ entry: EntryRecord) {
    // Local highlight is published before any blocking generated call is dispatched.
    selected = entry
    rollup = nil
    rollupText = nil
    metadata = nil
    selectionPath = nil
    metadataState = "Loading live metadata…"
    selectionVersion += 1
    guard let s = session else { return }
    metadataRequest = MetadataRequest(
      session: s, key: entry.key,
      selectionVersion: selectionVersion, sessionVersion: sessionVersion)
    guard !metadataWorkerRunning else { return }
    metadataWorkerRunning = true
    Task {
      // At most one blocking call plus one replaceable request, even during rapid keyboard selection.
      while let request = metadataRequest {
        metadataRequest = nil
        let result = await Task.detached(priority: .userInitiated) {
          let path = try? request.session.selection(key: request.key).relativePath
          let live = Result { try request.session.liveMetadata(key: request.key) }
          return (path, live)
        }.value
        guard request.selectionVersion == selectionVersion,
          request.sessionVersion == sessionVersion
        else { continue }
        selectionPath = result.0.map(displayPath)
        switch result.1 {
        case .success(let m):
          metadata = m
          metadataState = "Live metadata (on demand)"
        case .failure(let e): metadataState = "Live metadata unavailable: \(e)"
        }
      }
      metadataWorkerRunning = false
    }
  }

  func selectRollup(_ key: EntryKey, count: UInt64) {
    metadataRequest = nil
    selectionVersion += 1
    selected = nil
    metadata = nil
    rollup = key
    rollupText =
      "Rollup: \(count) smaller entries plus directory allocation. Not a file or an action target."
  }

  func focus(_ key: EntryKey, remember: Bool = true) {
    guard !working else { return }
    requestedFocus = key
    loading = true
    viewVersion += 1
    offset = 0
    cancelConfirmation()
    metadataRequest = nil
    selectionVersion += 1
    metadata = nil
    metadataState = "Select an entry"
    selected = nil
    rollup = nil
    rollupText = nil
    if remember, let old = records?.focus.key {
      history.append(old)
      if history.count > 64 { history.removeFirst() }
    }
    Task { await updateView(focus: key) }
  }
  func back() { if let key = history.popLast() { focus(key, remember: false) } }
  func page(_ offset: UInt64) {
    guard let key = records?.focus.key else { return }
    Task { await updateView(focus: key, pageOffset: offset) }
  }
  func resize(_ size: CGSize) {
    guard size.width > 0, size.height > 0, size != viewport else { return }
    viewport = size
    resizeTask?.cancel()
    resizeTask = Task {
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled, let key = requestedFocus else { return }
      await updateView(focus: key, pageOffset: offset)
    }
  }
  var canAct: Bool {
    selected?.parent != nil && !working && !loading && !replacingSession && pending == nil
  }
  @discardableResult
  func prepare(_ kind: ActionKind) -> Task<Void, Never>? {
    guard canAct, let entry = selected, let s = session else { return nil }
    preparing = true
    working = true
    actionVersion += 1
    let version = actionVersion
    let generation = sessionVersion
    return Task {
      do {
        let action = try await Task.detached(priority: .userInitiated) {
          let action = try s.prepare(key: entry.key, action: kind)
          return (action, action.details())
        }.value
        guard version == actionVersion, generation == sessionVersion else {
          _ = try? await Task.detached { try action.0.cancel() }.value
          return
        }
        pending = PendingConfirmation(action: action.0, details: action.1)
      } catch { if version == actionVersion { self.error = "Preparation failed: \(error)" } }
      if version == actionVersion {
        working = false
        preparing = false
      }
    }
  }
  func cancelConfirmation() {
    actionVersion += 1
    if let action = pending?.action {
      cancellationTask = Task.detached { _ = try? action.cancel() }
    }
    pending = nil
    if preparing {
      preparing = false
      working = false
    }
    // Executing work cannot be cancelled; its captured session remains alive.
  }
  func execute() {
    guard !replacingSession, let confirmation = pending, let s = session else { return }
    pending = nil
    working = true
    let generation = sessionVersion
    Task {
      do {
        let result = try await Task.detached(priority: .userInitiated) {
          try s.execute(action: confirmation.action)
        }.value
        guard generation == sessionVersion else { return }
        switch result.mutation {
        case .removed: outcome = "Permanently deleted. No Undo is available."
        case .trashed: outcome = "Moved to Trash."
        case .failed(let message): outcome = "Failed — \(message)"
        case .partial(let message): outcome = "Partial removal — survivors remain. \(message)"
        case .indeterminate(let message):
          outcome = "Indeterminate — verify before retrying. \(message)"
        }
        if let scope = result.scope {
          switch scope {
          case .inside:
            outcome! += " Trash is inside this inventory: allocation moved, not reclaimed."
          case .outside:
            outcome! += " Trash is outside this inventory; disk space is not necessarily reclaimed."
          case .unknown: outcome! += " Trash destination scope is unknown."
          }
        }
        retainIssues(result.update)
        await recoverView(s)
      } catch { if generation == sessionVersion { self.error = "Operation failed: \(error)" } }
      if generation == sessionVersion { working = false }
    }
  }
  func retainIssues(_ update: UpdateRecord) {
    issues.append(contentsOf: update.issues)
    if update.issuesOmitted > 0 {
      issues.append("\(update.issuesOmitted) additional issues omitted by core")
    }
  }
  func recoverView(_ s: ExplorerSession) async {
    let generation = sessionVersion
    let navigation = viewVersion
    metadataRequest = nil
    selectionVersion += 1
    selected = nil
    metadata = nil
    metadataState = "Select an entry"
    let candidates =
      ([records?.focus].compactMap { $0 } + (records?.ancestors.reversed() ?? [].reversed())).map(
        \.key)
    let key = await Task.detached { () -> EntryKey? in
      for key in candidates { if (try? s.selection(key: key)) != nil { return key } }
      return try? s.status().root.key
    }.value
    guard generation == sessionVersion, navigation == viewVersion else { return }
    if let key {
      requestedFocus = key
      await updateView(focus: key)
    }
  }
  func refresh() {
    guard !working, !replacingSession, let s = session, let key = records?.focus.key else { return }
    working = true
    let generation = sessionVersion
    Task {
      do {
        let update = try await Task.detached(priority: .userInitiated) {
          try s.refreshDirectory(key: key)
        }.value
        guard generation == sessionVersion else { return }
        retainIssues(update)
        outcome = "Directory refreshed in memory. Saved snapshot unchanged."
        await recoverView(s)
      } catch { if generation == sessionVersion { self.error = "Refresh failed: \(error)" } }
      if generation == sessionVersion { working = false }
    }
  }
  func openSnapshot() {
    guard !fixtureMode, !working, !replacingSession else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Open saved inventory without scanning its source."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let path = Self.pathBytes(url)
    load { try ExplorerSession.openSnapshot(snapshotPath: path) }
  }
  func createSnapshot() {
    guard !fixtureMode, !working, !replacingSession else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.message = "Choose the explicit inventory root. This scope will be scanned once."
    guard panel.runModal() == .OK, let root = panel.url else { return }
    let save = NSSavePanel()
    save.nameFieldStringValue = "Inventory.dmap"
    save.message =
      "Choose a NEW snapshot file. Existing files cannot be replaced. Creation scans, then reopens the saved inventory."
    guard save.runModal() == .OK, let destination = save.url else { return }
    let source = Self.pathBytes(root)
    let output = Self.pathBytes(destination)
    load { try ExplorerSession.create(sourceRoot: source, snapshotPath: output, workers: 4) }
  }
  static func pathBytes(_ url: URL) -> Data {
    url.withUnsafeFileSystemRepresentation { pointer in
      guard let pointer else { return Data() }
      return Data(bytes: pointer, count: strlen(pointer))
    }
  }
}
