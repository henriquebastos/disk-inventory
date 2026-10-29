import AppKit

extension ExplorerModel {
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
}
