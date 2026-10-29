import AppKit

extension ExplorerModel {
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
    regionWorker.discard()
    parentWorker.discard()
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
  func resize(_ proposed: CGSize) {
    guard proposed.width.isFinite, proposed.height.isFinite, proposed.width > 0, proposed.height > 0
    else { return }
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
    pathWorker.discard()
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
}
