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

/// The explorer controller. Stored state is declared here; the role extensions in
/// `ExplorerModel+*.swift` hold the behavior. Swift `private` does not reach other files, so
/// the request bookkeeping (versions, worker flags, pending requests) is internal: views must
/// not read or write it.
@MainActor @Observable final class ExplorerModel {
  var session: ExplorerSession?
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
  var outlineVersion = 0
  var hoverVersion = 0
  var viewWorkerRunning = false
  var viewRequest: ViewRequest?
  var recoveryToken: UUID?
  struct ViewRequest {
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
  var treeWorkerRunning = false
  enum TreeIntent {
    case rows(UInt64)
    case expand(EntryKey, Bool, UInt64, EntryKey?, Int)
    case reveal(EntryKey, Int)
  }
  struct TreeRequest {
    let tree: ExplorerTree
    let generation: Int
    let version: Int
    let intent: TreeIntent
  }
  var pendingRows: TreeRequest?
  var pendingExpansion: TreeRequest?
  var pendingReveal: TreeRequest?
  var clickVersion = 0
  struct HitRequest {
    let frame: DiagramFrame
    let x: UInt32
    let y: UInt32
    let generation: Int
    let navigation: Int
    let version: Int
    let click: Bool
    let doubleClick: Bool
    /// The waiting click is served before the waiting hover.
    static let clickSlot = 0
    static let hoverSlot = 1
  }
  /// Map hit tests for the pointer: clicks select, hovers name the block in the status bar.
  let hitWorker = LatestWorker<HitRequest>(slots: 2)
  /// Frame, selected key, and the session, view and selection versions it was asked under.
  typealias RegionRequest = (DiagramFrame, EntryKey, Int, Int, Int)
  /// Publishes the map region of the selection.
  let regionWorker = LatestWorker<RegionRequest>()

  var selected: EntryRecord?
  var selectionPath: String?
  var selectionRawPath: Data?
  let numbers: NativeNumberFormat
  let scan = ScanCoordinator()
  let motion = ResultMotion()
  let storage: ManagedInventoryStorage?
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
  var mapAppearance: MapAppearance
  var loading = false
  var replacingSession = false
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
  var restoring: NavigationContext?
  @ObservationIgnored var scrollRow: UInt64 = 0
  var restoredScrollRow = 0
  var scrollSerial = 0
  var viewport = CGSize(width: 650, height: 520)
  let fixtureMode: Bool
  /// Fixture mode marks only the window title; the content matches production.
  var windowTitle: String { fixtureMode ? "Disk Inventory — SIMULATED" : "Disk Inventory" }
  var sessionVersion = 0
  var viewVersion = 0
  var selectionVersion = 0
  var actionVersion = 0
  struct PathRequest {
    let session: ExplorerSession
    let key: EntryKey
    let selectionVersion: Int
    let sessionVersion: Int
  }
  /// Publishes the saved path of the selection.
  let pathWorker = LatestWorker<PathRequest>()
  /// Every latest-wins worker, for `settled()`.
  var workers: [any Settling] { [pathWorker, regionWorker, parentWorker, hitWorker] }
  /// Returns once every worker is idle at the same moment. A worker that hands work to another
  /// is seen on the next pass. Session loads, operations, the rebuild debounce, the motion
  /// clock and AppKit are not workers: they publish `loading`, `working` or their own state.
  func settled() async {
    while let busy = workers.first(where: { !$0.isIdle }) { await busy.settled() }
  }
  struct ParentRequest {
    let session: ExplorerSession
    let source: EntryKey
    let parent: EntryKey
    let generation: Int
    let navigation: Int
    let selection: Int
  }
  /// Selects the parent of the selection (Left arrow).
  let parentWorker = LatestWorker<ParentRequest>()
  var preparing = false
  /// The item a Trash or Delete preparation checks, before its confirmation opens.
  var checking: String?
  var cancellationTask: Task<Void, Never>?
  var requestedFocus: EntryKey?
  var rebuildTask: Task<Void, Never>?

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

  nonisolated static func pathBytes(_ url: URL) -> Data {
    url.withUnsafeFileSystemRepresentation { pointer in
      guard let pointer else { return Data() }
      return Data(bytes: pointer, count: strlen(pointer))
    }
  }
}
