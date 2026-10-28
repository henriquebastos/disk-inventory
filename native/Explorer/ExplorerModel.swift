import AppKit
import Observation

func displayPath(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
func entryName(_ entry: EntryRecord) -> String {
  entry.displayName.isEmpty ? "Inventory root" : entry.displayName
}
/// Shortens a name over 60 characters in the middle, so a title stays near two lines.
func middleTruncated(_ name: String) -> String {
  name.count > 60 ? "\(name.prefix(29))…\(name.suffix(30))" : name
}

struct ViewRecords: Sendable {
  let status: SessionStatus
  let focus: EntryRecord
  let ancestors: [EntryRecord]

  func breadcrumbName(_ entry: EntryRecord) -> String {
    guard entry.key.sameEntry(other: status.root.key) else { return entryName(entry) }
    return status.rootPath.split(separator: 47).last.map { String(decoding: $0, as: UTF8.self) }
      ?? "/"
  }
  func breadcrumbHelp(_ entry: EntryRecord) -> String {
    entry.key.sameEntry(other: status.root.key) ? displayPath(status.rootPath) : entryName(entry)
  }
}
struct PendingConfirmation: Identifiable {
  let id = UUID()
  let action: PreparedAction
  let details: ConfirmationDetails
  let name: String
  var permanent: Bool { details.action == .permanentlyDelete }
  var directory: Bool { details.metadata.kind == .directory }
  var title: String {
    // Keep the alert title near two lines; the detail box shows the full path.
    let shown = middleTruncated(name)
    return permanent ? "Delete “\(shown)” immediately?" : "Move “\(shown)” to the Trash?"
  }
  var scope: String { directory ? "Directory and its contents" : "File" }
  /// The Trash sheet has no warning: its title and its button name the Trash.
  var warning: String? {
    guard permanent else { return nil }
    return directory
      ? "This cannot be undone. An error may leave some contents undeleted."
      : "This cannot be undone."
  }
  var actionTitle: String { permanent ? "Delete Immediately" : "Move to Trash" }
  /// Return confirms a Trash. Permanent deletion has no default button.
  var actionIsDefault: Bool { !permanent }
  var actionIsDestructive: Bool { permanent }
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
  private var recoveryToken: UUID?
  private struct ViewRequest {
    let session: ExplorerSession
    let focus: EntryKey
    let tree: ExplorerTree?
    let size: CGSize
    let appearance: MapAppearance
    let sessionVersion: Int
    let viewVersion: Int
    let restore: NavigationContext?
    let recovery: Bool
    let selection: EntryKey?
    /// The selection shown now. Its region publishes with the new picture, so a rebuild
    /// never draws one frame without the selection dim.
    let shownSelection: EntryKey?
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
  var selectionRawPath: Data?
  let numbers: NativeNumberFormat
  let scan = ScanCoordinator()
  let motion = ResultMotion()
  private let storage: ManagedInventoryStorage?
  var lastInventory: ManagedInventory?
  var scanDate: Date?
  /// UI acceptance override from DI_REDUCE_MOTION=1, honored only in fixture mode.
  let fixtureReduceMotion: Bool
  var reduceMotion: Bool {
    fixtureReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }
  /// UI acceptance override from DI_APPEARANCE, honored only in fixture mode. AppKit cannot
  /// create a high-contrast appearance, so a contrast value changes the map, not the chrome.
  let fixtureAppearance: MapAppearance?
  /// The appearance of the next map build. Hatch and seam colors depend on it.
  private(set) var mapAppearance: MapAppearance
  var loading = false
  private(set) var replacingSession = false
  var working = false
  var error: String?
  var outcome: String?
  /// The session issue log. The outcome banner shows it until dismissed; new issues show it again.
  var issues: [String] = [] { didSet { if issues.isEmpty { dismissedIssues = 0 } } }
  private(set) var dismissedIssues = 0
  /// The outcome banner over the map: errors, operation outcomes and new issues.
  var bannerVisible: Bool { error != nil || outcome != nil || issues.count > dismissedIssues }
  func dismissBanner() {
    error = nil
    outcome = nil
    dismissedIssues = issues.count
  }
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
  /// Fixture mode marks only the window title; the content matches production.
  var windowTitle: String { fixtureMode ? "Disk Inventory — SIMULATED" : "Disk Inventory" }
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
  private var rebuildTask: Task<Void, Never>?

  init(
    arguments: [String] = ProcessInfo.processInfo.arguments,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    storage: ManagedInventoryStorage? = nil,
    numbers: NativeNumberFormat = .system
  ) {
    self.numbers = numbers
    fixtureMode =
      arguments.contains("--fixture-mode") || arguments.contains("--scenario")
      || environment["DI_UI_TEST"] != nil
    fixtureReduceMotion = fixtureMode && environment["DI_REDUCE_MOTION"] == "1"
    fixtureAppearance =
      fixtureMode ? environment["DI_APPEARANCE"].flatMap(MapAppearance.init(fixtureName:)) : nil
    mapAppearance =
      fixtureAppearance
      ?? MapAppearance(
        NSApplication.shared.effectiveAppearance,
        increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    self.storage =
      storage
      ?? (fixtureMode
        ? Self.fixtureStorage(environment) : try? ManagedInventoryStorage.applicationSupport())
    if let storage = self.storage {
      Task {
        let version = sessionVersion
        do {
          let last = try await Task.detached { try storage.lastInventory() }.value
          if version == sessionVersion { lastInventory = last }
        } catch { self.error = "Could not read last inventory metadata: \(error)" }
      }
    }
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

  /// Test-only metadata root for fixture UI tests: DI_FIXTURE_STORAGE_ROOT must name an
  /// existing absolute directory. Fixture mode only reads it: it never creates, opens or
  /// cleans up an inventory there. Production never calls this.
  static func fixtureStorage(_ environment: [String: String]) -> ManagedInventoryStorage? {
    guard let path = environment["DI_FIXTURE_STORAGE_ROOT"], path.hasPrefix("/") else {
      return nil
    }
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &directory),
      directory.boolValue
    else { return nil }
    return ManagedInventoryStorage(root: URL(fileURLWithPath: path, isDirectory: true))
  }

  func load(
    scanControl: ScanControl? = nil, generation: URL? = nil, scanDate: Date? = nil,
    _ constructor: @escaping @Sendable () throws -> ExplorerSession
  ) {
    scan.stopPolling(cancelScan: true)
    motion.cancel()
    recoveryToken = nil
    if let scanControl { scan.begin(scanControl) }
    cancelConfirmation()
    invalidatePresentation()
    history.removeAll()
    restoring = nil
    pathRequest = nil
    selected = nil
    selectionRawPath = nil
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
        guard version == sessionVersion else {
          if let generation, let storage {
            try? await Task.detached { try storage.discard(generation) }.value
          }
          return
        }
        var installedDate = scanDate
        if let generation, let storage {
          let date = Date()
          let rootName = displayPath(result.1.rootPath)
          let record = try await Task.detached {
            try storage.publish(generation, scannedAt: date, rootName: rootName)
          }.value
          lastInventory = record
          installedDate = date
        }
        if fixtureMode && !result.1.simulated { throw CocoaError(.fileReadNoPermission) }
        // No confirmation or late preparation from the retained picture may cross this install.
        cancelConfirmation()
        await cancellationTask?.value
        guard version == sessionVersion else { return }
        // Also invalidate old-session work started while its previous view remained visible.
        viewVersion += 1
        selectionVersion += 1
        pathRequest = nil
        self.scanDate = installedDate
        session = result.0
        working = false
        requestedFocus = result.1.root.key
        records = nil
        selected = nil
        selectionRawPath = nil
        selectionPath = nil
        history = []
        restoring = nil
        issues = []
        outcome = nil
        await updateView(focus: result.1.root.key)
      } catch {
        if let generation, let storage {
          try? await Task.detached { try storage.discard(generation) }.value
        }
        if version == sessionVersion {
          let failure: String
          if case BridgeError.Cancelled = error {
            failure = "Scan cancelled. The previous saved inventory is unchanged."
          } else if scanControl?.progress().phase == .publishedFailure {
            failure =
              "The scan published a generation but could not finish preparing it. Last managed inventory unchanged. \(error)"
          } else {
            failure = String(describing: error)
          }
          self.error = failure
          if let retained = session { await recoverView(retained) }
          if version == sessionVersion { self.error = failure }
        }
      }
      if version == sessionVersion {
        loading = false
        replacingSession = false
        scan.stopPolling(cancelScan: false)
      }
    }
  }

  func invalidatePresentation(retainingRows: Bool = false) {
    tree = nil
    // Retain only the bounded display slice, never the obsolete tree query handle.
    if !retainingRows {
      outline = nil
      selectedRow = nil
    }
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
  func updateView(focus: EntryKey, recovery: Bool = false, preserving selection: EntryKey? = nil)
    async
  {
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
        session: s, focus: focus, tree: reuse, size: viewport, appearance: mapAppearance,
        sessionVersion: sessionVersion, viewVersion: version, restore: restore,
        recovery: recovery, selection: selection, shownSelection: selected?.key, done: done)
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
              var offset: UInt64
              if request.recovery {
                rows = nil
                offset = 0
              } else if request.tree == nil || request.restore != nil {
                let position = request.restore?.scrollRow ?? 0
                let total = try tree.rows(offset: UInt64.max, limit: 1).total
                offset = min(position, total > 0 ? total - 1 : 0)
                rows = try tree.rows(offset: offset > 32 ? offset - 32 : 0, limit: 256)
              } else {
                rows = nil
                offset = 0
              }
              let selection = (request.recovery ? request.selection : request.restore?.selection)
                .flatMap { try? s.selection(key: $0) }
              if request.recovery, let selection {
                // A surviving inside-Trash target can be outside the recovered focus.
                _ = try? tree.reveal(key: selection.entry.key)
              }
              let selectedRow = try selection.flatMap { try tree.visibleRow(key: $0.entry.key) }.map
              { Int($0) }
              if request.recovery, let selectedRow { offset = UInt64(selectedRow) }
              let picture = try DiagramPicture(
                session: s, focus: request.focus, size: request.size,
                appearance: request.appearance)
              let regionKey = selection?.entry.key ?? request.shownSelection
              let region = regionKey.flatMap { try? picture.frame.region(key: $0) }
              let publishedRows =
                request.recovery
                ? try tree.rows(offset: offset > 32 ? offset - 32 : 0, limit: 256) : rows
              return (
                ViewRecords(status: status, focus: entry, ancestors: ancestors), tree,
                publishedRows,
                picture, selection, offset, selectedRow, (regionKey, region)
              )
            }.value
            if request.sessionVersion == sessionVersion && request.viewVersion == viewVersion {
              records = result.0
              tree = result.1
              if request.recovery || request.tree == nil || request.restore != nil {
                outline = result.2
                selectedRow = nil
                restoredScrollRow = Int(result.5)
                scrollRow = result.5
                scrollSerial += 1
              }
              if request.recovery {
                selected = nil
                selectionRawPath = nil
                selectionPath = nil
              }
              if let selection = result.4 {
                selected = selection.entry
                selectionRawPath = selection.relativePath
                selectionPath = displayPath(selection.relativePath)
                selectedRow = result.6
                if request.recovery, result.6 != nil { revealSerial += 1 }
              }
              restoring = nil
              picture = result.3
              diagramBuilds += 1
              loading = false
              if let selected {
                // The region came with the picture when the selection is the same entry.
                if let key = result.7.0, key.sameEntry(other: selected.key) {
                  selectedRegion = result.7.1
                } else {
                  updateSelectedRegion(selected.key)
                }
              } else {
                selectedRegion = nil
              }
            }
          } catch {
            if request.sessionVersion == sessionVersion && request.viewVersion == viewVersion {
              self.error = String(describing: error)
              loading = false
              if request.recovery {
                selected = nil
                selectedRow = nil
                selectionRawPath = nil
                selectionPath = nil
              }
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
  /// The shown region stays until the new one arrives. Clearing it first drew the map
  /// without the selection dim for one to three frames whenever a display refresh fell
  /// between the click and the session-locked region query: the click flicker.
  private func updateSelectedRegion(_ key: EntryKey) {
    guard let frame = picture?.frame else {
      selectedRegion = nil
      return
    }
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
    guard !loading, !working, !motion.active, !replacingSession, let frame = picture?.frame else {
      return
    }
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
        guard request.generation == sessionVersion, request.navigation == viewVersion,
          !working, !loading, !replacingSession, !motion.active
        else {
          continue
        }
        if request.click {
          guard request.version == clickVersion, let hit else { continue }
          if hit.actionable {
            // An actionable hit is one tile, so its rectangle is the selection region.
            select(hit.entry, region: hit.rect)
            if request.doubleClick, hit.entry.kind == .directory { focus(hit.entry.key) }
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

  /// `region` is the known map rectangle of a clicked tile. Without it the region comes
  /// from the current frame.
  func select(_ entry: EntryRecord, region: Rectangle? = nil) {
    // Local highlight is published before any blocking generated call is dispatched.
    clickVersion += 1
    selected = entry
    selectedRow = nil
    aggregate = nil
    aggregateText = nil
    selectionRawPath = nil
    selectionPath = nil
    selectionVersion += 1
    reveal(entry)
    if let region {
      regionRequest = nil
      selectedRegion = region
    } else {
      updateSelectedRegion(entry.key)
    }
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
        selectionRawPath = path
        selectionPath = path.map(displayPath)
      }
      pathWorkerRunning = false
    }
  }

  /// Esc in the map or the tree: no selected item, region, card or tree highlight. Saved
  /// data, focus, expansion and scroll stay.
  var canClearSelection: Bool {
    (selected != nil || aggregate != nil) && !working && !loading && !replacingSession
      && pending == nil && !motion.active
  }
  func clearSelection() {
    guard canClearSelection else { return }
    clickVersion += 1
    pathRequest = nil
    regionRequest = nil
    parentRequest = nil
    selectionVersion += 1
    selected = nil
    selectedRow = nil
    selectedRegion = nil
    selectionRawPath = nil
    selectionPath = nil
    aggregate = nil
    aggregateText = nil
  }

  func selectAggregate(_ key: EntryKey, bytes: UInt64) {
    clickVersion += 1
    pathRequest = nil
    selectionVersion += 1
    selected = nil
    selectedRow = nil
    selectedRegion = nil
    selectionRawPath = nil
    selectionPath = nil
    aggregate = key
    aggregateText =
      "\(numbers.storage(bytes)) in grouped directory allocation. Open the directory for more detail."
  }

  func focus(_ key: EntryKey) {
    guard !working, !replacingSession else { return }
    guard requestedFocus?.sameEntry(other: key) != true else { return }
    let restore = history.first { $0.focus.sameEntry(other: key) }
    history.removeAll { $0.focus.sameEntry(other: key) }
    if let old = records?.focus.key, let tree {
      history.removeAll { $0.focus.sameEntry(other: old) }
      history.append(
        NavigationContext(focus: old, tree: tree, selection: selected?.key, scrollRow: scrollRow))
      if history.count > 64 { history.removeFirst() }
    }
    motion.cancel()
    recoveryToken = nil
    requestedFocus = key
    loading = true
    viewVersion += 1
    invalidatePresentation()
    restoring = restore
    cancelConfirmation()
    pathRequest = nil
    selectionVersion += 1
    selectionRawPath = nil
    selectionPath = nil
    selected = nil
    aggregate = nil
    aggregateText = nil
    let navigation = viewVersion
    Task { if navigation == viewVersion { await updateView(focus: key) } }
  }
  func focusParent() { if let parent = records?.focus.parent { focus(parent) } }
  func openSelectedDirectory() {
    if let entry = selected, entry.kind == .directory { focus(entry.key) }
  }
  // Kept as the keyboard/test parent-navigation seam; there is no Back stack UI.
  func back() { focusParent() }
  func revealSelection() { if let selected { reveal(selected) } }
  var selectedDisplayPath: String? {
    guard let relative = selectionRawPath else { return nil }
    return completeDisplayPath(relative)
  }
  /// The saved root path joined with a saved relative path, from the inventory only.
  func completeDisplayPath(_ relative: Data) -> String? {
    guard var root = records?.status.rootPath else { return nil }
    if !relative.isEmpty {
      if root.last != 47 { root.append(47) }
      root.append(relative)
    }
    return displayPath(root)
  }
  /// The status bar: the complete path of the map block under the pointer, also while another
  /// item is selected. A grouped block names its folder. Empty when the pointer is off the map.
  /// The path comes from the hover hit, so a hover reads no filesystem metadata.
  var statusText: String {
    guard let hover, let path = completeDisplayPath(hover.relativePath) else { return "" }
    return hover.actionable ? path : "Grouped in " + path
  }
  var selectedURL: URL? {
    guard !fixtureMode, recoveryToken == nil, !loading, !working, !replacingSession,
      let relative = selectionRawPath, var path = records?.status.rootPath
    else {
      return nil
    }
    if !relative.isEmpty {
      if path.last != 47 { path.append(47) }
      path.append(relative)
    }
    guard !path.contains(0) else { return nil }
    let url = (path + Data([0])).withUnsafeBytes { bytes in
      URL(
        fileURLWithFileSystemRepresentation: bytes.baseAddress!.assumingMemoryBound(to: CChar.self),
        isDirectory: selected?.kind == .directory, relativeTo: nil)
    }
    // Finder must never receive a lossy display-path reconstruction.
    return Self.pathBytes(url) == path ? url : nil
  }
  var canRevealInFinder: Bool {
    selectedURL != nil && !working && !replacingSession && pending == nil
  }
  func revealInFinder() {
    guard let url = selectedURL, !working, !replacingSession else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

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
    scheduleMapRebuild()
  }
  /// The map variant for a view appearance. The fixture override wins over the system.
  func mapAppearance(for appearance: NSAppearance) -> MapAppearance {
    fixtureAppearance
      ?? MapAppearance(
        appearance, increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
  }
  /// A light, dark or Increase Contrast change rebuilds the map from saved data with the
  /// resize debounce. It never scans and never reads live metadata.
  func mapAppearanceChanged(_ appearance: MapAppearance) {
    guard appearance != mapAppearance else { return }
    mapAppearance = appearance
    scheduleMapRebuild()
  }
  private func scheduleMapRebuild() {
    rebuildTask?.cancel()
    rebuildTask = Task {
      try? await Task.sleep(for: .milliseconds(180))
      // Recovery rebuilds at the latest viewport and appearance before releasing its
      // retained selection. An ordinary rebuild request must not supersede that validation.
      guard !Task.isCancelled, recoveryToken == nil, let key = requestedFocus else { return }
      await updateView(focus: key)
    }
  }
  var canAct: Bool {
    selected?.parent != nil && recoveryToken == nil && !working && !loading && !replacingSession
      && pending == nil
  }
  // Command enable rules. Each reads saved state only and is false while a confirmation is
  // pending; ExplorerCommand gives them to the menu bar, the card and the context menus.
  var canOpenInventory: Bool { !fixtureMode && !working && !replacingSession && pending == nil }
  var canReopenLastFolder: Bool { canOpenInventory && storage != nil && lastInventory != nil }
  var canRefresh: Bool {
    !working && !loading && !replacingSession && pending == nil && session != nil
      && records != nil
  }
  var canStopScan: Bool { scan.progress?.cancellable == true && pending == nil }
  private var canNavigate: Bool { !working && !loading && !replacingSession && pending == nil }
  var canOpenSelectedDirectory: Bool { canNavigate && selected?.kind == .directory }
  var canOpenEnclosingDirectory: Bool { canNavigate && records?.focus.parent != nil }
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
        pending = PendingConfirmation(
          action: action.0, details: action.1, name: entryName(entry))
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
    let navigation = viewVersion
    let previous = picture
    let source = selectedRegion
    let selectedKey = selected?.key
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
        // Failed/partial/uncertain removals retain the actual survivor selection, never a success ghost.
        let survivor = selectedKey
        let mayAnimate =
          navigation == viewVersion
          && RemovalMotionPlan.make(
            mutation: result.mutation, scope: result.scope, source: source,
            rootPath: records?.status.rootPath ?? Data(), visibleTargets: [],
            reduceMotion: reduceMotion) != nil
        if mayAnimate, let previous { motion.hold(previous) }
        await recoverView(s, preserving: survivor, retainingMotion: mayAnimate)
        let moved = mayAnimate ? await movedRegion(s, key: selectedKey, scope: result.scope) : []
        if generation == sessionVersion, mayAnimate, let previous,
          picture?.frame !== previous.frame,
          let plan = RemovalMotionPlan.make(
            mutation: result.mutation, scope: result.scope, source: source,
            rootPath: records?.status.rootPath ?? Data(),
            visibleTargets: (picture?.targets ?? []) + moved, reduceMotion: reduceMotion)
        {
          await motion.play(previous: previous, plan: plan)
        } else if generation == sessionVersion {
          motion.cancel()
        }
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
  /// An inside-Trash move keeps the saved key, so the new frame can locate its destination
  /// directly; the bounded accessibility targets omit most small or late-laid-out tiles.
  private func movedRegion(
    _ s: ExplorerSession, key: EntryKey?, scope: TrashScope?
  ) async -> [DiagramSelection] {
    guard case .inside = scope, let key, let frame = picture?.frame else { return [] }
    return await Task.detached { () -> [DiagramSelection] in
      guard let moved = try? s.selection(key: key), let rect = try? frame.region(key: key) else {
        return []
      }
      return [
        DiagramSelection(
          entry: moved.entry, relativePath: moved.relativePath, actionable: true, rect: rect,
          bytes: moved.entry.subtreeBytes)
      ]
    }.value
  }
  func retainIssues(_ update: UpdateRecord) {
    issues.append(contentsOf: update.issues)
    if update.issuesOmitted > 0 {
      issues.append(
        "\(numbers.count(UInt64(update.issuesOmitted))) additional issues omitted by core")
    }
  }
  func recoverView(
    _ s: ExplorerSession, preserving selection: EntryKey? = nil, retainingMotion: Bool = false
  ) async {
    if !retainingMotion { motion.cancel() }
    let generation = sessionVersion
    let navigation = viewVersion
    let token = UUID()
    recoveryToken = token
    defer { if recoveryToken == token { recoveryToken = nil } }
    history.removeAll()
    restoring = nil
    loading = true
    invalidatePresentation(retainingRows: true)
    pathRequest = nil
    selectionVersion += 1
    let candidates =
      ([records?.focus].compactMap { $0 } + (records?.ancestors.reversed() ?? [].reversed())).map(
        \.key)
    let key = await Task.detached { () -> EntryKey? in
      for key in candidates { if (try? s.selection(key: key)) != nil { return key } }
      return try? s.status().root.key
    }.value
    guard generation == sessionVersion, navigation == viewVersion, recoveryToken == token else {
      return
    }
    if let key {
      requestedFocus = key
      while recoveryToken == token {
        let size = viewport
        let appearance = mapAppearance
        await updateView(focus: key, recovery: true, preserving: selection)
        guard generation == sessionVersion, recoveryToken == token else { return }
        if size == viewport && appearance == mapAppearance { break }
      }
    } else {
      selected = nil
      selectedRow = nil
      selectionRawPath = nil
      selectionPath = nil
      loading = false
    }
  }
  /// Refreshes the focused folder in memory with the scan's progress, counter and Stop.
  /// Stop before the update leaves the inventory and the shown view unchanged.
  func refresh() {
    guard !working, !loading, !replacingSession, let s = session, let records else { return }
    let key = records.focus.key
    let name = records.breadcrumbName(records.focus)
    let control = ScanControl()
    working = true
    scan.begin(control, refreshing: name)
    let generation = sessionVersion
    Task {
      do {
        let update = try await Task.detached(priority: .userInitiated) {
          try s.refreshDirectoryControlled(key: key, control: control)
        }.value
        guard generation == sessionVersion else { return }
        retainIssues(update)
        outcome = "Refreshed “\(name)” in memory. Saved snapshot unchanged."
        await recoverView(s)
      } catch BridgeError.Cancelled {
        if generation == sessionVersion {
          outcome = "Refresh of “\(name)” stopped. The previous data is unchanged."
        }
      } catch { if generation == sessionVersion { self.error = "Refresh failed: \(error)" } }
      if generation == sessionVersion {
        scan.stopPolling(cancelScan: false)
        working = false
      }
    }
  }
  func createSnapshot() {
    guard !fixtureMode, !working, !replacingSession else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.message = "Choose the explicit inventory root. This scope will be scanned once."
    guard panel.runModal() == .OK, let root = panel.url else { return }
    createManaged(root: root)
  }
  /// Opens the last folder's managed snapshot offline. The metadata filename, not its display
  /// name, selects the file.
  func reopenLastFolder() {
    guard !fixtureMode, !working, !replacingSession, let storage, let lastInventory else { return }
    let path = Self.pathBytes(storage.url(for: lastInventory))
    load(scanDate: lastInventory.scannedAt) { try ExplorerSession.openSnapshot(snapshotPath: path) }
  }
  func createManaged(root: URL, control: ScanControl = ScanControl()) {
    guard !fixtureMode, !working, !replacingSession, let storage else { return }
    do {
      let destination = try storage.newGeneration()
      let source = Self.pathBytes(root)
      let output = Self.pathBytes(destination)
      load(scanControl: control, generation: destination) {
        try ExplorerSession.createControlled(
          sourceRoot: source, snapshotPath: output, workers: 4, control: control)
      }
    } catch { self.error = "Could not prepare managed storage: \(error)" }
  }
  func shutdown() {
    scan.stopPolling(cancelScan: true)
    motion.cancel()
    cancelConfirmation()
  }
  nonisolated static func pathBytes(_ url: URL) -> Data {
    url.withUnsafeFileSystemRepresentation { pointer in
      guard let pointer else { return Data() }
      return Data(bytes: pointer, count: strlen(pointer))
    }
  }
}
