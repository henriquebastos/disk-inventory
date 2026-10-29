import AppKit

extension ExplorerModel {
  private func parentRequestIsCurrent(_ request: ParentRequest) -> Bool {
    isIdle && request.session === session && request.generation == sessionVersion
      && request.navigation == viewVersion && request.selection == selectionVersion
      && selection.entry?.key.sameEntry(other: request.source) == true
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
  /// The shown region stays until the new one arrives, so no display refresh between the
  /// click and the session-locked region query draws the map without the selection dim.
  func updateSelectedRegion(_ key: EntryKey) {
    guard let frame = picture?.frame else {
      selection.region = nil
      return
    }
    regionWorker.submit(
      RegionRequest(
        frame: frame, key: key, sessionVersion: sessionVersion, viewVersion: viewVersion,
        selectionVersion: selectionVersion), serve: serveRegion)
  }
  private func serveRegion(_ request: RegionRequest) async {
    let region = try? await Task.detached { try request.frame.region(key: request.key) }.value
    if request.sessionVersion == sessionVersion, request.viewVersion == viewVersion,
      request.selectionVersion == selectionVersion
    {
      selection.region = region
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
    hitWorker.submit(
      request, slot: click ? HitRequest.clickSlot : HitRequest.hoverSlot, serve: serveHit)
  }
  private func serveHit(_ request: HitRequest) async {
    let hit = try? await Task.detached { try request.frame.hit(x: request.x, y: request.y) }
      .value
    guard request.generation == sessionVersion, request.navigation == viewVersion,
      acceptsMapPointer
    else {
      return
    }
    if request.click {
      guard request.version == clickVersion, let hit else { return }
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
  func clearHover() {
    hoverVersion += 1
    hitWorker.discard(slot: HitRequest.hoverSlot)
    hover = nil
  }

  /// `region` is the known map rectangle of a clicked tile. Without it the region comes
  /// from the current frame.
  func select(_ entry: EntryRecord, region: Rectangle? = nil) {
    // Local highlight is published before any blocking generated call is dispatched.
    clickVersion += 1
    // The shown region stays until the region of the new item arrives.
    selection = SelectionState(entry: entry, region: selection.region)
    selectionVersion += 1
    reveal(entry)
    if let region {
      regionWorker.discard()
      selection.region = region
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
  /// A click on a tree row: selects its item and highlights the clicked row at once, before
  /// the reveal answers with the same row.
  func selectRow(_ row: Int, entry: EntryRecord) {
    select(entry)
    selection.row = row
  }
  /// At most one blocking call plus one replaceable request, even during rapid keyboard selection.
  /// A failed lookup marks the path unavailable, so the card does not show "Loading path…".
  private func servePath(_ request: PathRequest) async {
    let path = await Task.detached(priority: .userInitiated) {
      try? request.session.selection(key: request.key).relativePath
    }.value
    guard request.selectionVersion == selectionVersion,
      request.sessionVersion == sessionVersion
    else { return }
    selection.rawPath = path
    selection.path = path.map(displayPath)
    selection.pathUnavailable = path == nil
  }

  /// Esc in the map or the tree: no selected item, region, card or tree highlight. Saved
  /// data, focus, expansion and scroll stay.
  var canClearSelection: Bool {
    (selection.entry != nil || selection.aggregate != nil) && !working && !loading
      && !replacingSession
      && pending == nil && !motion.active
  }
  func clearSelection() {
    guard canClearSelection else { return }
    clickVersion += 1
    pathWorker.discard()
    regionWorker.discard()
    parentWorker.discard()
    selectionVersion += 1
    selection.clear()
  }

  func selectAggregate(_ key: EntryKey, bytes: UInt64) {
    clickVersion += 1
    pathWorker.discard()
    selectionVersion += 1
    selection = SelectionState(aggregate: key, aggregateText: numbers.storage(bytes))
  }
  func revealSelection() { if let entry = selection.entry { reveal(entry) } }
  var selectedDisplayPath: String? {
    guard let relative = selection.rawPath else { return nil }
    return completeDisplayPath(relative)
  }
  /// The saved root path joined with a saved relative path, from the inventory only.
  func completeDisplayPath(_ relative: Data) -> String? {
    guard let root = records?.status.rootPath else { return nil }
    return displayPath(joinedPath(root: root, relative: relative))
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
      let relative = selection.rawPath, let root = records?.status.rootPath
    else {
      return nil
    }
    let path = joinedPath(root: root, relative: relative)
    guard !path.contains(0) else { return nil }
    let url = (path + Data([0])).withUnsafeBytes { bytes in
      URL(
        fileURLWithFileSystemRepresentation: bytes.baseAddress!.assumingMemoryBound(to: CChar.self),
        isDirectory: selection.entry?.kind == .directory, relativeTo: nil)
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
