import XCTest

@testable import DiskInventory

/// The outcome banner, the busy bar and the header render `ExplorerModel.outcomeBanner`,
/// `progressBar`, `startScreenProgressBar` and `header`; one test per variant.
@MainActor final class StatusComponentTests: XCTestCase {
  /// A model of `scenario` that formats numbers for en_US.
  func fixture(_ scenario: String = "presentation") async throws -> ExplorerModel {
    try await fixtureModel(
      scenario, numbers: NativeNumberFormat(locale: Locale(identifier: "en_US")))
  }

  func testBannerIsHiddenWithoutAnErrorOutcomeOrNewIssue() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    XCTAssertNil(model.outcomeBanner)
  }

  func testBannerShowsAnOutcomeWithoutDetails() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    model.outcome = "Moved to Trash."
    let banner = try XCTUnwrap(model.outcomeBanner)
    XCTAssertEqual(banner, OutcomeBannerState(error: nil, outcome: "Moved to Trash.", issues: []))
    XCTAssertFalse(banner.showsDetails)
  }

  /// An error shows the red title, with its message in Details.
  func testBannerShowsAnErrorWithItsMessageInDetails() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    model.error = "Refresh failed: gone"
    let banner = try XCTUnwrap(model.outcomeBanner)
    XCTAssertEqual(
      banner, OutcomeBannerState(error: "Refresh failed: gone", outcome: nil, issues: []))
    XCTAssertTrue(banner.showsDetails)
  }

  /// Issues show in Details until Dismiss; a new issue shows the banner again with every issue.
  func testBannerShowsIssuesUntilDismissedAndAgainForANewIssue() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    model.issues = ["Skipped locked: permission denied"]
    let banner = try XCTUnwrap(model.outcomeBanner)
    XCTAssertEqual(banner.issues, ["Skipped locked: permission denied"])
    XCTAssertNil(banner.error)
    XCTAssertTrue(banner.showsDetails)
    model.dismissBanner()
    XCTAssertNil(model.outcomeBanner, "dismissed")
    model.issues.append("Skipped busy: resource busy")
    XCTAssertEqual(
      model.outcomeBanner,
      OutcomeBannerState(
        error: nil, outcome: nil,
        issues: ["Skipped locked: permission denied", "Skipped busy: resource busy"]))
  }

  /// The Details word and its chevron send one intent. Details stay open for a new outcome
  /// while the banner shows, and close when the banner hides.
  func testBannerDetailsToggleFromOneIntentAndCloseWhenTheBannerHides() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    model.toggleBannerDetails()
    XCTAssertFalse(model.bannerDetailsShown, "no banner, nothing to open")
    model.outcome = "Deleted. 3 items skipped."
    model.issues = ["Skipped locked: permission denied"]
    XCTAssertEqual(model.outcomeBanner?.detailsShown, false)
    model.toggleBannerDetails()
    XCTAssertEqual(model.outcomeBanner?.detailsShown, true)
    model.outcome = "Moved to Trash."
    XCTAssertEqual(model.outcomeBanner?.detailsShown, true, "a new outcome keeps Details open")
    model.toggleBannerDetails()
    XCTAssertEqual(model.outcomeBanner?.detailsShown, false)
    model.toggleBannerDetails()
    model.dismissBanner()
    XCTAssertNil(model.outcomeBanner)
    XCTAssertFalse(model.bannerDetailsShown, "Dismiss closes Details")
    model.issues.append("Skipped busy: resource busy")
    XCTAssertEqual(model.outcomeBanner?.detailsShown, false, "a new issue shows Details closed")
  }

  /// A new session: the explorer and the start screen both show the preparation.
  func testProgressBarShowsPreparingInventoryWhileTheSessionLoads() async throws {
    let model = ExplorerModel(
      arguments: ["--fixture-mode", "--scenario", "presentation"], environment: [:])
    defer { model.shutdown() }
    XCTAssertEqual(model.progressBar, .preparingInventory)
    XCTAssertEqual(model.startScreenProgressBar, .preparingInventory)
    try await waitUntil { model.records != nil && !model.loading && !model.replacingSession }
    XCTAssertNil(model.progressBar)
    XCTAssertNil(model.startScreenProgressBar)
  }

  /// Navigation without Rust progress shows only "Working…".
  func testProgressBarShowsWorkingWhileANavigationBuildsItsView() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    model.focus(try entry("small-files", in: model).key)
    XCTAssertEqual(model.progressBar, .working)
    XCTAssertEqual(model.startScreenProgressBar, .working)
    try await waitUntil { !model.loading }
    XCTAssertNil(model.progressBar)
  }

  /// A Trash preparation names the item. The start screen bar shows only session loads.
  func testProgressBarNamesTheItemThatAPreparationChecks() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    model.select(try entry("large-file", in: model))
    model.prepare(.trash)
    XCTAssertEqual(model.progressBar, .checking(name: "large-file"))
    XCTAssertNil(model.startScreenProgressBar)
    try await waitUntil { model.pending != nil }
    model.cancelConfirmation()
    XCTAssertNil(model.progressBar)
  }

  /// Refresh Directory shows its phase, its item counter, its time and an enabled Stop.
  func testProgressBarShowsARefreshPhaseCounterTimeAndStop() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    model.refresh()
    XCTAssertEqual(
      model.progressBar,
      .operation(
        phase: "Refreshing “Workspace”…", items: "0 items examined", elapsed: "0 sec",
        offersStop: true, canStop: true))
    try await waitUntil { !model.working && !model.loading }
  }

  /// A Trash runs without Stop and without a counter.
  func testProgressBarShowsATrashWithoutStopOrCounter() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    model.select(try entry("large-file", in: model))
    model.prepare(.trash)
    try await waitUntil { model.pending != nil }
    model.execute()
    XCTAssertEqual(
      model.progressBar,
      .operation(
        phase: "Checking “large-file”…", items: nil, offersStop: false, canStop: false))
    try await waitUntil { !model.working && !model.loading }
  }

  /// A complete fixture: the saved total, no badge, no scan date, fixture-locked menus.
  func testHeaderShowsTheSavedTotalWithoutBadgesForAFixture() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    XCTAssertEqual(
      model.header,
      HeaderState(
        reopenTitle: "Reopen Last Folder", canChooseFolder: false, canReopenLastFolder: false,
        breadcrumbsEnabled: true, partialScanErrors: nil, stale: false, dirty: false,
        total: model.numbers.storage(model.records!.status.root.subtreeBytes), scanDate: nil,
        canRefresh: true))
    XCTAssertEqual(model.header?.total, "13 KB")
  }

  /// A running operation disables the breadcrumbs and Refresh.
  func testHeaderDisablesBreadcrumbsAndRefreshWhileAPreparationRuns() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    model.select(try entry("large-file", in: model))
    model.prepare(.trash)
    let header = try XCTUnwrap(model.header)
    XCTAssertFalse(header.breadcrumbsEnabled)
    XCTAssertFalse(header.canRefresh)
    try await waitUntil { model.pending != nil }
    model.cancelConfirmation()
    XCTAssertEqual(model.header?.breadcrumbsEnabled, true)
  }

  /// A Delete leaves the inventory changed in memory: Not saved, still complete.
  func testHeaderShowsNotSavedAfterADelete() async throws {
    let model = try await fixture()
    defer { model.shutdown() }
    model.select(try entry("large-file", in: model))
    model.prepare(.permanentlyDelete)
    try await waitUntil { model.pending != nil }
    model.execute()
    try await waitUntil { !model.working && !model.loading }
    let header = try XCTUnwrap(model.header)
    XCTAssertTrue(header.dirty)
    XCTAssertFalse(header.stale)
  }

  /// A refresh that finds unknown allocation: Incomplete and Not saved.
  func testHeaderShowsIncompleteAfterARefreshWithUnknownAllocation() async throws {
    let model = try await fixture("unknown-allocation")
    defer { model.shutdown() }
    model.refresh()
    try await waitUntil { !model.working && !model.loading }
    let header = try XCTUnwrap(model.header)
    XCTAssertTrue(header.stale)
    XCTAssertTrue(header.dirty)
    XCTAssertNil(header.partialScanErrors)
  }

  /// A managed scan of an owned folder with an unreadable directory: the Partial badge with its
  /// error count, the scan date and the named reopen command.
  func testHeaderShowsPartialScanErrorsAndTheDateOfAManagedScan() async throws {
    let base = try XCTUnwrap(ProcessInfo.processInfo.environment["DI_TEST_ROOT"])
    let created = URL(fileURLWithPath: base).appendingPathComponent(
      "native-header-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
    // Roots must have no symlink component, such as /tmp.
    let canonical = try XCTUnwrap(realpath(created.path, nil))
    let root = URL(fileURLWithPath: String(cString: canonical))
    free(canonical)
    let source = root.appendingPathComponent("source")
    let denied = source.appendingPathComponent("denied")
    try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
      try? FileManager.default.removeItem(at: root)
    }
    try Data([1]).write(to: denied.appendingPathComponent("owned.txt"))
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
    try XCTSkipIf(
      (try? FileManager.default.contentsOfDirectory(atPath: denied.path)) != nil,
      "this process can read a mode-000 directory")
    let model = ExplorerModel(
      arguments: [], environment: [:],
      storage: ManagedInventoryStorage(root: root.appendingPathComponent("support")),
      numbers: NativeNumberFormat(locale: Locale(identifier: "en_US")))
    defer { model.shutdown() }
    model.createManaged(root: source)
    try await waitUntil { !model.replacingSession }
    XCTAssertNil(model.error)
    let header = try XCTUnwrap(model.header)
    XCTAssertEqual(header.partialScanErrors, "1 scan error")
    XCTAssertEqual(
      header.scanDate,
      model.scanDate.map { "Scanned " + $0.formatted(date: .abbreviated, time: .shortened) })
    XCTAssertNotNil(header.scanDate)
    XCTAssertEqual(header.reopenTitle, "Reopen “source”")
    XCTAssertTrue(header.canChooseFolder)
    XCTAssertTrue(header.canReopenLastFolder)
  }
}
