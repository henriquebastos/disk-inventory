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

}
struct PendingConfirmation: Identifiable {
  let id = UUID()
  let action: PreparedAction
  let details: ConfirmationDetails
}

@MainActor @Observable final class ExplorerModel {
  private(set) var session: ExplorerSession?
  var records: ViewRecords?
  var picture: DiagramPicture?
  var tree: ExplorerTree?
  var outline: OutlineSlice? { didSet { outlineToken = NSObject() } }
  var outlineToken = NSObject()
  var revealSerial = 0
  var selectedRow: Int?
  var selectedRegion: Rectangle?
  var hover: DiagramSelection?
  var diagramBuilds = 0
  private var outlineVersion = 0
  private var hoverVersion = 0
  private var viewWorkerRunning = false
  private var viewRequest: ViewRequest?
  private struct ViewRequest {
    let session: ExplorerSession
    let focus: EntryKey
    let tree: ExplorerTree?
    let size: CGSize
    let sessionVersion: Int
    let viewVersion: Int
    let restore: NavigationContext?
    let done: CheckedContinuation<Void, Never>
  }
  var treeEditing = false
  private var treeWorkerRunning = false
  private enum TreeIntent {
    case rows(UInt64)
    case expand(EntryKey, Bool, UInt64, EntryKey?, Int)
    case reveal(EntryKey, Int)
  }
  private struct TreeRequest {
    let tree: ExplorerTree
    let generation: Int
    let version: Int
    let intent: TreeIntent
  }
  private var pendingRows: TreeRequest?
  private var pendingExpansion: TreeRequest?
  private var pendingReveal: TreeRequest?
  private var hitWorkerRunning = false
  private var clickVersion = 0
  private struct HitRequest {
    let frame: DiagramFrame
    let x: UInt32
    let y: UInt32
    let generation: Int
    let navigation: Int
    let version: Int
    let click: Bool
    let doubleClick: Bool
  }
  private var hoverRequest: HitRequest?
  private var clickRequest: HitRequest?
  private var regionWorkerRunning = false
  private var regionRequest: (DiagramFrame, EntryKey, Int, Int, Int)?

  var selected: EntryRecord?
  var selectionPath: String?
  var loading = false
  private(set) var replacingSession = false
  var working = false
  var error: String?
  var outcome: String?
  var issues: [String] = []
  var pending: PendingConfirmation?
  var aggregate: EntryKey?
  var aggregateText: String?
  struct NavigationContext {
    let focus: EntryKey
    let tree: ExplorerTree
    let selection: EntryKey?
    let scrollRow: UInt64
  }
  var history: [NavigationContext] = []
  private var restoring: NavigationContext?
  @ObservationIgnored var scrollRow: UInt64 = 0
  var restoredScrollRow = 0
  var scrollSerial = 0
  var viewport = CGSize(width: 650, height: 520)
  var rasterReduced = false
  let fixtureMode: Bool
  private var sessionVersion = 0
  private var viewVersion = 0
  private var selectionVersion = 0
  private var actionVersion = 0
  private struct PathRequest {
    let session: ExplorerSession
    let key: EntryKey
    let selectionVersion: Int
    let sessionVersion: Int
  }
  private var pathRequest: PathRequest?
  private var pathWorkerRunning = false
  private struct ParentRequest {
    let session: ExplorerSession
    let source: EntryKey
    let parent: EntryKey
    let generation: Int
    let navigation: Int
    let selection: Int
  }
  private var parentRequest: ParentRequest?
  private var parentWorkerRunning = false
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
    invalidatePresentation()
    history.removeAll()
    restoring = nil
    pathRequest = nil
    selected = nil
    selectionPath = nil
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
        pathRequest = nil
        session = result.0
        requestedFocus = result.1.root.key
        records = nil
        selected = nil
        selectionPath = nil
        history = []
        restoring = nil
        issues = []
        outcome = nil
        await updateView(focus: result.1.root.key)
      } catch {
        if version == sessionVersion {
          let failure = String(describing: error)
          self.error = failure
          if let retained = session { await recoverView(retained) }
          if version == sessionVersion { self.error = failure }
        }
      }
      if version == sessionVersion {
        loading = false
        replacingSession = false
      }
    }
  }

  func invalidatePresentation() {
    tree = nil
    outline = nil
    selectedRow = nil
    selectedRegion = nil
    hover = nil
    outlineVersion += 1
    hoverVersion += 1
    pendingRows = nil
    pendingExpansion = nil
    pendingReveal = nil
    treeEditing = false
    hoverRequest = nil
    clickRequest = nil
    clickVersion += 1
    regionRequest = nil
    parentRequest = nil
  }
  func updateView(focus: EntryKey) async {
    guard let s = session else { return }
    viewVersion += 1
    let version = viewVersion
    let restore = restoring?.focus.sameEntry(other: focus) == true ? restoring : nil
    let reuse = restore?.tree ?? (records?.focus.key.sameEntry(other: focus) == true ? tree : nil)
    loading = true
    hover = nil
    hoverVersion += 1
    await withCheckedContinuation { done in
      viewRequest?.done.resume()
      viewRequest = ViewRequest(
        session: s, focus: focus, tree: reuse, size: viewport,
        sessionVersion: sessionVersion, viewVersion: version, restore: restore, done: done)
      guard !viewWorkerRunning else { return }
      viewWorkerRunning = true
      Task {
        while let request = viewRequest {
          viewRequest = nil
          do {
            let result = try await Task.detached(priority: .userInitiated) {
              let s = request.session
              let status = try s.status()
              let entry = try s.selection(key: request.focus).entry
              var ancestors: [EntryRecord] = []
              var parent = entry.parent
              while let key = parent, ancestors.count < 64 {
                let e = try s.selection(key: key).entry
                ancestors.insert(e, at: 0)
                parent = e.parent
              }
              var tree = try request.tree ?? s.tree(root: request.focus)
              if request.restore != nil {
                do { _ = try tree.rows(offset: UInt64.max, limit: 1) } catch {
                  tree = try s.tree(root: request.focus)
                }
              }
              let rows: OutlineSlice?
              let offset: UInt64
              if request.tree == nil || request.restore != nil {
                let position = request.restore?.scrollRow ?? 0
                let total = try tree.rows(offset: UInt64.max, limit: 1).total
                offset = min(position, total > 0 ? total - 1 : 0)
                rows = try tree.rows(offset: offset > 32 ? offset - 32 : 0, limit: 256)
              } else {
                rows = nil
                offset = 0
              }
              let selection = request.restore?.selection.flatMap { try? s.selection(key: $0) }
              let selectedRow = try selection.flatMap { try tree.visibleRow(key: $0.entry.key) }.map
              { Int($0) }
              let picture = try DiagramPicture(session: s, focus: request.focus, size: request.size)
              return (
                ViewRecords(status: status, focus: entry, ancestors: ancestors), tree, rows,
                picture, selection, offset, selectedRow
              )
            }.value
            if request.sessionVersion == sessionVersion && request.viewVersion == viewVersion {
              records = result.0
              tree = result.1
              if request.tree == nil || request.restore != nil {
                outline = result.2
                selectedRow = nil
                restoredScrollRow = Int(result.5)
                scrollRow = result.5
                scrollSerial += 1
              }
              if let selection = result.4 {
                selected = selection.entry
                selectionPath = displayPath(selection.relativePath)
                selectedRow = result.6
              }
              restoring = nil
              picture = result.3
              diagramBuilds += 1
              loading = false
              if let selected { updateSelectedRegion(selected.key) }
            }
          } catch {
            if request.sessionVersion == sessionVersion && request.viewVersion == viewVersion {
              self.error = String(describing: error)
              loading = false
              if case BridgeError.InvalidEntry = error {
                outcome =
                  "Previous view is no longer available; returning to a known live ancestor."
                Task { await recoverView(request.session) }
              }
            }
          }
          request.done.resume()
        }
        viewWorkerRunning = false
      }
    }
  }
  func requestRows(_ offset: UInt64) {
    guard let tree else { return }
    pendingRows = TreeRequest(
      tree: tree, generation: sessionVersion, version: outlineVersion, intent: .rows(offset))
    runTreeWorker()
  }
  func expand(_ entry: EntryRecord, expanded: Bool) {
    guard let tree, !loading, !working, !replacingSession, !treeEditing else { return }
    outlineVersion += 1
    treeEditing = true
    pendingExpansion = TreeRequest(
      tree: tree, generation: sessionVersion, version: outlineVersion,
      intent: .expand(entry.key, expanded, outline?.offset ?? 0, selected?.key, selectionVersion))
    runTreeWorker()
  }
  private func reveal(_ entry: EntryRecord) {
    guard let tree, records?.focus.key.sameEntry(other: entry.key) != true else {
      selectedRow = nil
      return
    }
    outlineVersion += 1
    pendingReveal = TreeRequest(
      tree: tree, generation: sessionVersion, version: outlineVersion,
      intent: .reveal(entry.key, selectionVersion))
    runTreeWorker()
  }
  private func runTreeWorker() {
    guard !treeWorkerRunning else { return }
    treeWorkerRunning = true
    Task {
      while pendingExpansion != nil || pendingReveal != nil || pendingRows != nil {
        let request: TreeRequest
        if let next = pendingExpansion {
          request = next
          pendingExpansion = nil
        } else if let next = pendingReveal {
          request = next
          pendingReveal = nil
        } else {
          request = pendingRows!
          pendingRows = nil
        }
        guard request.generation == sessionVersion, request.tree === tree else { continue }
        let isExpansion: Bool
        if case .expand = request.intent { isExpansion = true } else { isExpansion = false }
        if !isExpansion && request.version != outlineVersion { continue }
        do {
          let result = try await Task.detached {
            switch request.intent {
            case .rows(let offset):
              return (try request.tree.rows(offset: offset, limit: 256), nil as Int?)
            case .expand(let key, let expanded, let offset, let selection, _):
              let total = try request.tree.expand(key: key, expanded: expanded)
              let row = try selection.flatMap { try request.tree.visibleRow(key: $0) }.map {
                Int($0)
              }
              return (
                try request.tree.rows(
                  offset: min(offset, total > 256 ? total - 256 : 0), limit: 256), row
              )
            case .reveal(let key, _):
              let row = try request.tree.reveal(key: key)
              return (try request.tree.rows(offset: row > 32 ? row - 32 : 0, limit: 256), Int(row))
            }
          }.value
          if request.generation == sessionVersion, request.version == outlineVersion,
            request.tree === tree
          {
            outline = result.0
            switch request.intent {
            case .rows: break
            case .expand(_, _, _, _, let selectedVersion):
              if selectedVersion == selectionVersion { selectedRow = result.1 }
            case .reveal(_, let selectedVersion):
              if selectedVersion == selectionVersion {
                selectedRow = result.1
                revealSerial += 1
              }
            }
          }
        } catch {
          if request.generation == sessionVersion, request.version == outlineVersion {
            self.error = String(describing: error)
          }
        }
        if isExpansion, request.tree === tree { treeEditing = false }
      }
      treeWorkerRunning = false
    }
  }
  private func parentRequestIsCurrent(_ request: ParentRequest) -> Bool {
    !working && !loading && !replacingSession && pending == nil
      && request.session === session && request.generation == sessionVersion
      && request.navigation == viewVersion && request.selection == selectionVersion
      && selected?.key.sameEntry(other: request.source) == true
  }
  func selectParent(_ entry: EntryRecord) {
    guard let key = entry.parent, let session else { return }
    let request = ParentRequest(
      session: session, source: entry.key, parent: key,
      generation: sessionVersion, navigation: viewVersion, selection: selectionVersion)
    guard parentRequestIsCurrent(request) else { return }
    parentRequest = request
    guard !parentWorkerRunning else { return }
    parentWorkerRunning = true
    Task {
      while let request = parentRequest {
        parentRequest = nil
        guard parentRequestIsCurrent(request) else { continue }
        let result = try? await Task.detached {
          try request.session.selection(key: request.parent).entry
        }.value
        if parentRequestIsCurrent(request), let result { select(result) }
      }
      parentWorkerRunning = false
    }
  }
  private func updateSelectedRegion(_ key: EntryKey) {
    selectedRegion = nil
    guard let frame = picture?.frame else { return }
    regionRequest = (frame, key, sessionVersion, viewVersion, selectionVersion)
    guard !regionWorkerRunning else { return }
    regionWorkerRunning = true
    Task {
      while let (frame, key, generation, navigation, selection) = regionRequest {
        regionRequest = nil
        let region = try? await Task.detached { try frame.region(key: key) }.value
        if generation == sessionVersion, navigation == viewVersion, selection == selectionVersion {
          selectedRegion = region
        }
      }
      regionWorkerRunning = false
    }
  }
  func point(_ x: UInt32, _ y: UInt32, click: Bool = false, doubleClick: Bool = false) {
    guard !loading, !replacingSession, let frame = picture?.frame else { return }
    if click { clickVersion += 1 } else { hoverVersion += 1 }
    let request = HitRequest(
      frame: frame, x: x, y: y, generation: sessionVersion, navigation: viewVersion,
      version: click ? clickVersion : hoverVersion, click: click, doubleClick: doubleClick)
    if click { clickRequest = request } else { hoverRequest = request }
    guard !hitWorkerRunning else { return }
    hitWorkerRunning = true
    Task {
      while clickRequest != nil || hoverRequest != nil {
        let request: HitRequest
        if let click = clickRequest {
          request = click
          clickRequest = nil
        } else {
          request = hoverRequest!
          hoverRequest = nil
        }
        let hit = try? await Task.detached { try request.frame.hit(x: request.x, y: request.y) }
          .value
        guard request.generation == sessionVersion, request.navigation == viewVersion else {
          continue
        }
        if request.click {
          guard request.version == clickVersion, let hit else { continue }
          if hit.actionable {
            select(hit.entry)
          } else {
            selectAggregate(hit.entry.key, bytes: hit.bytes)
            if request.doubleClick { focus(hit.entry.key) }
          }
        } else if request.version == hoverVersion {
          hover = hit
        }
      }
      hitWorkerRunning = false
    }
  }
  func clearHover() {
    hoverVersion += 1
    hoverRequest = nil
    hover = nil
  }

  func select(_ entry: EntryRecord) {
    // Local highlight is published before any blocking generated call is dispatched.
    clickVersion += 1
    selected = entry
    selectedRow = nil
    aggregate = nil
    aggregateText = nil
    selectionPath = nil
    selectionVersion += 1
    reveal(entry)
    updateSelectedRegion(entry.key)
    guard let s = session else { return }
    pathRequest = PathRequest(
      session: s, key: entry.key,
      selectionVersion: selectionVersion, sessionVersion: sessionVersion)
    guard !pathWorkerRunning else { return }
    pathWorkerRunning = true
    Task {
      // At most one blocking call plus one replaceable request, even during rapid keyboard selection.
      while let request = pathRequest {
        pathRequest = nil
        let path = await Task.detached(priority: .userInitiated) {
          try? request.session.selection(key: request.key).relativePath
        }.value
        guard request.selectionVersion == selectionVersion,
          request.sessionVersion == sessionVersion
        else { continue }
        selectionPath = path.map(displayPath)
      }
      pathWorkerRunning = false
    }
  }

  func selectAggregate(_ key: EntryKey, bytes: UInt64) {
    clickVersion += 1
    pathRequest = nil
    selectionVersion += 1
    selected = nil
    selectedRow = nil
    selectedRegion = nil
    selectionPath = nil
    aggregate = key
    aggregateText =
      "\(exactBytes(bytes)) in grouped directory allocation. Open the directory for more detail."
  }

  func focus(_ key: EntryKey) {
    guard !working, !replacingSession else { return }
    let restore: NavigationContext?
    if let index = history.lastIndex(where: { $0.focus.sameEntry(other: key) }) {
      restore = history[index]
      history.removeSubrange(index...)
    } else {
      restore = nil
      if let old = records?.focus.key, let tree, !old.sameEntry(other: key),
        history.last?.focus.sameEntry(other: old) != true
      {
        history.append(
          NavigationContext(focus: old, tree: tree, selection: selected?.key, scrollRow: scrollRow))
        if history.count > 64 { history.removeFirst() }
      }
    }
    requestedFocus = key
    loading = true
    viewVersion += 1
    invalidatePresentation()
    restoring = restore
    cancelConfirmation()
    pathRequest = nil
    selectionVersion += 1
    selectionPath = nil
    selected = nil
    aggregate = nil
    aggregateText = nil
    let navigation = viewVersion
    Task { if navigation == viewVersion { await updateView(focus: key) } }
  }
  func back() { if let context = history.last { focus(context.focus) } }
  func historyExpansionPayloadBytes() async throws -> UInt64 {
    let trees = history.map(\.tree)
    return try await Task.detached {
      try trees.reduce(UInt64(0)) {
        $0 + (try $1.rows(offset: UInt64.max, limit: 1).expansionPayloadBytes)
      }
    }.value
  }
  func resize(_ proposed: CGSize) {
    guard proposed.width.isFinite, proposed.height.isFinite, proposed.width > 0, proposed.height > 0
    else { return }
    rasterReduced = proposed.width * proposed.height > 4_000_000
    let scale = min(1, sqrt(4_000_000 / (proposed.width * proposed.height)))
    let size = CGSize(
      width: min(4_000_000, max(1, floor(proposed.width * scale))),
      height: min(4_000_000, max(1, floor(proposed.height * scale))))
    guard size != viewport else { return }
    viewport = size
    resizeTask?.cancel()
    resizeTask = Task {
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled, let key = requestedFocus else { return }
      await updateView(focus: key)
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
        case .failed(let message):
          outcome = "Failed. The operation could not be completed."
          issues.append(message)
        case .partial(let message):
          outcome = "Partial removal — some contents remain."
          issues.append(message)
        case .indeterminate(let message):
          outcome = "Indeterminate — verify before retrying."
          issues.append(message)
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
      } catch {
        if generation == sessionVersion {
          let failure = "Operation failed: \(error)"
          self.error = failure
          // Execution may invalidate presentation even when fresh core validation rejects it.
          await recoverView(s)
          if generation == sessionVersion { self.error = failure }
        }
      }
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
    history.removeAll()
    restoring = nil
    invalidatePresentation()
    pathRequest = nil
    selectionVersion += 1
    selected = nil
    selectionPath = nil
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
