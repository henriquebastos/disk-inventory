import AppKit

extension ExplorerModel {
  private func parentRequestIsCurrent(_ request: ParentRequest) -> Bool {
    isIdle && request.session === session && request.generation == sessionVersion
      && request.navigation == viewVersion && request.selection == selectionVersion
      && selected?.key.sameEntry(other: request.source) == true
  }
  func selectParent(_ entry: EntryRecord) {
    guard let key = entry.parent, let session else { return }
    let request = ParentRequest(
      session: session, source: entry.key, parent: key,
      generation: sessionVersion, navigation: viewVersion, selection: selectionVersion)
    parentWorker.submit(request, serve: serveParent)
  }
  private func serveParent(_ request: ParentRequest) async {
    guard parentRequestIsCurrent(request) else { return }
    let result = try? await Task.detached {
      try request.session.selection(key: request.parent).entry
    }.value
    if parentRequestIsCurrent(request), let result { select(result) }
  }
  /// The shown region stays until the new one arrives. Clearing it first drew the map
  /// without the selection dim for one to three frames whenever a display refresh fell
  /// between the click and the session-locked region query: the click flicker.
  func updateSelectedRegion(_ key: EntryKey) {
    guard let frame = picture?.frame else {
      selectedRegion = nil
      return
    }
    regionWorker.submit(
      (frame, key, sessionVersion, viewVersion, selectionVersion), serve: serveRegion)
  }
  private func serveRegion(_ request: RegionRequest) async {
    let (frame, key, generation, navigation, selection) = request
    let region = try? await Task.detached { try frame.region(key: key) }.value
    if generation == sessionVersion, navigation == viewVersion, selection == selectionVersion {
      selectedRegion = region
    }
  }
  func point(_ x: UInt32, _ y: UInt32, click: Bool = false, doubleClick: Bool = false) {
    guard acceptsMapPointer, let frame = picture?.frame else {
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
          acceptsMapPointer
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
      regionWorker.discard()
      selectedRegion = region
    } else {
      updateSelectedRegion(entry.key)
    }
    guard let s = session else { return }
    pathWorker.submit(
      PathRequest(
        session: s, key: entry.key,
        selectionVersion: selectionVersion, sessionVersion: sessionVersion),
      serve: servePath)
  }
  /// At most one blocking call plus one replaceable request, even during rapid keyboard selection.
  private func servePath(_ request: PathRequest) async {
    let path = await Task.detached(priority: .userInitiated) {
      try? request.session.selection(key: request.key).relativePath
    }.value
    guard request.selectionVersion == selectionVersion,
      request.sessionVersion == sessionVersion
    else { return }
    selectionRawPath = path
    selectionPath = path.map(displayPath)
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
    pathWorker.discard()
    regionWorker.discard()
    parentWorker.discard()
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
    pathWorker.discard()
    selectionVersion += 1
    selected = nil
    selectedRow = nil
    selectedRegion = nil
    selectionRawPath = nil
    selectionPath = nil
    aggregate = key
    aggregateText = numbers.storage(bytes)
  }
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
}
