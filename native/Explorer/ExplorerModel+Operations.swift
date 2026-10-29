import AppKit

extension ExplorerModel {
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
  var canStopScan: Bool {
    scan.progress?.cancellable == true && scan.offersStop && pending == nil
  }
  private var canNavigate: Bool { !working && !loading && !replacingSession && pending == nil }
  var canOpenSelectedDirectory: Bool { canNavigate && selected?.kind == .directory }
  var canOpenEnclosingDirectory: Bool { canNavigate && records?.focus.parent != nil }
  @discardableResult
  func prepare(_ kind: ActionKind) -> Task<Void, Never>? {
    guard canAct, let entry = selected, let s = session else { return nil }
    preparing = true
    working = true
    checking = entryName(entry)
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
        checking = nil
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
      checking = nil
    }
    // Executing work cannot be cancelled; its captured session remains alive.
  }
  /// Runs the confirmed action with the scan's progress: the phase names the item, Delete
  /// counts removed items and offers Stop. Stop before the first removal changes nothing.
  @discardableResult
  func execute() -> Task<Void, Never>? {
    guard !replacingSession, let confirmation = pending, let s = session else { return nil }
    pending = nil
    working = true
    let control = ScanControl()
    let kind = confirmation.details.action
    scan.begin(control, operation: (kind, confirmation.name))
    let generation = sessionVersion
    let navigation = viewVersion
    let previous = picture
    let source = selectedRegion
    let selectedKey = selected?.key
    return Task {
      do {
        let result = try await Task.detached(priority: .userInitiated) {
          try s.executeControlled(action: confirmation.action, control: control)
        }.value
        guard generation == sessionVersion else { return }
        report(result.mutation)
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
      } catch BridgeError.Cancelled {
        // Nothing was removed, so the shown view stays valid.
        if generation == sessionVersion {
          outcome = "Deletion of “\(confirmation.name)” stopped. Nothing was deleted."
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
      if generation == sessionVersion {
        scan.stopPolling(cancelScan: false)
        working = false
      }
    }
  }
  /// The outcome banner says what happened; skip reasons and messages go to Details.
  private func report(_ mutation: MutationOutcome) {
    switch mutation {
    case .removed: outcome = "Deleted."
    case .removedWithSkips(let removal):
      outcome = "Deleted. \(itemCount(removal.skipped)) skipped."
      retainSkips(removal)
    case .trashed: outcome = "Moved to Trash."
    case .failed(let message):
      outcome = "Failed. The operation could not be completed."
      issues.append(message)
    case .partial(let message, let stopped, let removal):
      if stopped {
        outcome = "Deletion stopped. \(itemCount(removal.removed)) deleted."
      } else {
        outcome = "Partial removal — some contents remain."
        issues.append(message)
      }
      retainSkips(removal)
    case .indeterminate(let message):
      outcome = "Indeterminate — verify before retrying."
      issues.append(message)
    }
  }
  private func itemCount(_ count: UInt64) -> String {
    "\(numbers.count(count)) \(count == 1 ? "item" : "items")"
  }
  private func retainSkips(_ removal: RemovalRecord) {
    issues.append(contentsOf: removal.reasons.map { "Skipped \($0)" })
    let unlisted = removal.skipped - UInt64(removal.reasons.count)
    if unlisted > 0 { issues.append("\(itemCount(unlisted)) more skipped, not listed") }
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
        outcome = "Refreshed “\(name)”."
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
}
