import Foundation

// Real generated types and Rust sessions only. No Swift filesystem/accounting mock.
private func require(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}
private func expectError<T>(_ matches: (BridgeError) -> Bool, _ body: () throws -> T) throws {
    do {
        _ = try body()
        preconditionFailure("expected a typed bridge error")
    } catch let error as BridgeError {
        require(matches(error), "unexpected bridge error: \(error)")
    }
}
private func find(_ session: ExplorerSession, _ name: Data) throws -> EntryKey {
    let root = try session.status().root.key
    var offset: UInt64 = 0
    while true {
        let page = try session.children(parent: root, offset: offset, limit: 3)
        if let entry = page.entries.first(where: { $0.basename == name }) { return entry.key }
        guard let next = page.nextOffset else { preconditionFailure("missing fixture entry \(name)") }
        offset = next
    }
}
private func find(_ session: ExplorerSession, _ name: String) throws -> EntryKey {
    try find(session, Data(name.utf8))
}
private let request = LayoutRequest(
    viewport: Rectangle(x: 0, y: 0, width: 800, height: 600),
    maxRectangles: 64, minArea: 0, maxDepth: 16)

@main
struct BridgeSmoke {
    static func main() throws {
        require(CommandLine.arguments.count == 2, "pass an owned empty fixture directory")
        let session = try ExplorerSession.fixture(scenario: "ordinary")
        let initial = try session.status()
        require(initial.simulated && !initial.stale && !initial.dirty, "visible simulated status")
        require(!session.isBusy(), "idle after synchronous call")
        let large = try find(session, "large-file")
        require(session.activeCallCount() == 0 && session.selectionQueryCount() == 0, "idle diagnostic counters")
        let selected = try session.selection(key: large)
        require(session.selectionQueryCount() == 1, "actual saved-selection backend entry")
        require(selected.entry.allocatedBytes == (UInt64(1) << 53) + 123, "lossless UInt64")
        require(selected.entry.parent!.sameEntry(other: initial.root.key), "parent handle")
        require(try session.selection(key: find(session, "zero-byte")).entry.subtreeBytes == 0, "zero row")
        require(try session.selection(key: find(session, "hardlink-b")).entry.accountedBytes == 0, "dedup in Rust")
        let raw = Data([114, 97, 119, 45, 255])
        let rawSelection = try session.selection(key: find(session, raw))
        require(rawSelection.relativePath == raw && rawSelection.entry.basename == raw, "raw Data roundtrip")
        let layout = try session.layout(focus: initial.root.key, request: request)
        require(layout.focus.sameEntry(other: initial.root.key), "selection never changes focus")
        require(layout.tiles.count + layout.groups.count <= 64, "bounded Rust rectangles")
        require(layout.tiles.reduce(UInt64(0)) { $0 + $1.bytes } == initial.root.subtreeBytes, "conserved Rust weights")
        let live = try session.liveMetadata(key: large)
        require(live.logicalBytes == (UInt64(1) << 53) + 140, "explicit live metadata")
        let cancelled = try session.prepare(key: large, action: .trash)
        require(cancelled.details().rawPath == Data("/Workspace/large-file".utf8), "confirmation raw path")
        try cancelled.cancel()
        try expectError({ if case .ConsumedAction = $0 { true } else { false } }) { try session.execute(action: cancelled) }
        let other = try ExplorerSession.fixture(scenario: "ordinary")
        try expectError({ if case .InvalidEntry = $0 { true } else { false } }) { try other.selection(key: large) }
        let action = try session.prepare(key: large, action: .permanentlyDelete)
        try expectError({ if case .WrongSession = $0 { true } else { false } }) { try other.execute(action: action) }
        let removed = try session.execute(action: action)
        require(removed.mutation == .removed && removed.update.dirty, "stateful permanent removal")
        try expectError({ if case .ConsumedAction = $0 { true } else { false } }) { try session.execute(action: action) }
        try expectError({ if case .InvalidEntry = $0 { true } else { false } }) { try session.selection(key: large) }
        let changed = try session.layout(focus: initial.root.key, request: request)
        require(changed.totalBytes == initial.root.subtreeBytes - selected.entry.subtreeBytes, "changed layout")
        _ = try session.refreshDirectory(key: initial.root.key)

        for scenario in ["trash-inside", "trash-outside", "trash-unknown", "trash-missing", "trash-failure"] {
            let s = try ExplorerSession.fixture(scenario: scenario)
            let before = try s.status().root.subtreeBytes
            let a = try s.prepare(key: find(s, "large-file"), action: .trash)
            let r = try s.execute(action: a)
            switch scenario {
            case "trash-inside":
                guard case .inside(let path) = r.scope else { preconditionFailure("inside scope") }
                require(path == Data("trash/moved".utf8), "Rust destination")
                require(try s.status().root.subtreeBytes == before, "inside accounting")
                let trash = try find(s, "trash")
                require(try s.children(parent: trash, offset: 0, limit: 10).entries.contains { $0.basename == Data("moved".utf8) }, "visible relocation")
            case "trash-outside":
                require(r.scope == .outside, "outside scope")
                require(try s.status().root.subtreeBytes == before - ((UInt64(1) << 53) + 123), "outside accounting")
            case "trash-unknown": require(r.scope == .unknown && r.update.stale && !r.update.issues.isEmpty, "unknown scope is stale")
            case "trash-missing":
                guard case .indeterminate = r.mutation else { preconditionFailure("indeterminate") }
                require(r.update.stale, "missing destination stale")
            default:
                guard case .failed = r.mutation else { preconditionFailure("failed") }
                require(try s.status().root.subtreeBytes == before, "failed means unchanged")
            }
        }
        let partial = try ExplorerSession.fixture(scenario: "partial-deletion")
        let partialAction = try partial.prepare(key: find(partial, "small-files"), action: .permanentlyDelete)
        let partialResult = try partial.execute(action: partialAction)
        guard case .partial = partialResult.mutation else { preconditionFailure("partial result") }
        require(partialResult.update.stale && !partialResult.update.issues.isEmpty, "partial not empty")
        let denied = try ExplorerSession.fixture(scenario: "metadata-failure")
        let deniedKey = try find(denied, "large-file")
        _ = try denied.selection(key: deniedKey)
        try expectError({ if case .PermissionDenied = $0 { true } else { false } }) { try denied.liveMetadata(key: deniedKey) }
        let permission = try ExplorerSession.fixture(scenario: "permission-failure")
        require(try permission.refreshDirectory(key: find(permission, "small-files")).stale, "permission refresh stale")
        let replaced = try ExplorerSession.fixture(scenario: "changed-target")
        try expectError({ if case .InvalidInput = $0 { true } else { false } }) {
            try replaced.prepare(key: find(replaced, "large-file"), action: .trash)
        }
        let unknown = try ExplorerSession.fixture(scenario: "unknown-allocation")
        let update = try unknown.refreshDirectory(key: unknown.status().root.key)
        require(update.stale && update.issues.contains { $0.contains("no prior allocation") }, "unknown accounting explicit")
        let unattributed = try unknown.selection(key: find(unknown, "unknown-a")).entry
        require(unattributed.allocatedBytes == 100 && unattributed.accountedBytes == 0, "unknown is not measured zero")
        try expectError({ if case .InvalidInput = $0 { true } else { false } }) { try ExplorerSession.fixture(scenario: "not-a-mode") }

        let dix = try ExplorerSession.fixture(scenario: "dix")
        let dixRoot = try dix.status().root.key
        let tree = try dix.tree(root: dixRoot)
        let projects = try find(dix, "Projects")
        require(try tree.expand(key: projects, expanded: true) == 2003, "virtual expansion")
        require(try tree.rows(offset: 250, limit: 256).rows.count == 256, "bounded row transfer")
        let diagram = try dix.diagram(focus: dixRoot, width: 640, height: 400, appearance: .dark)
        let bitmap = diagram.bitmap()
        require(bitmap.rgba.count == 640 * 400 * 4 && bitmap.tiles > 160, "flat detailed bitmap")
        let target = try diagram.targets().first!
        let hit = try diagram.hit(x: UInt32(target.rect.x + target.rect.width / 2), y: UInt32(target.rect.y + target.rect.height / 2))!
        require(hit.actionable && hit.entry.key.sameEntry(other: target.entry.key), "pixel owner")
        let virtualRow = try tree.reveal(key: hit.entry.key)
        require(try tree.rows(offset: virtualRow, limit: 1).rows[0].entry.key.sameEntry(other: hit.entry.key), "linked reveal")
        require(try tree.visibleRow(key: hit.entry.key) == virtualRow, "read-only visible row")
        _ = try tree.expand(key: projects, expanded: false)
        require(try tree.visibleRow(key: find(dix, "Movie.mov")) == 1, "shifted sibling row")
        if hit.relativePath.starts(with: Data("Projects/".utf8)) {
            require(try tree.visibleRow(key: hit.entry.key) == nil, "collapsed descendant remains hidden")
        }
        require(try diagram.region(key: projects) != nil, "directory selection region")
        _ = try dix.refreshDirectory(key: dixRoot)
        try expectError({ if case .ObsoleteRevision = $0 { true } else { false } }) { try diagram.hit(x: 0, y: 0) }
        try expectError({ if case .ObsoleteRevision = $0 { true } else { false } }) { try tree.rows(offset: 0, limit: 1) }
        try expectError({ if case .ObsoleteRevision = $0 { true } else { false } }) { try tree.visibleRow(key: projects) }

        // One explicitly owned one-file source tests create and offline native snapshot open.
        // No native Trash/permanent operation is ever requested.
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = base.appendingPathComponent("source", isDirectory: true)
        let snapshot = base.appendingPathComponent("saved.dmap")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("owned synthetic fixture".utf8).write(to: source.appendingPathComponent("example"))
        let stopped = ScanControl()
        require(stopped.progress().phase == .ready && stopped.progress().cancellable, "independent control ready")
        require(stopped.cancel(), "pre-create stop accepted")
        try expectError({ if case .Cancelled = $0 { true } else { false } }) {
            try ExplorerSession.createControlled(sourceRoot: Data(source.path.utf8), snapshotPath: Data(snapshot.path.utf8), workers: 1, control: stopped)
        }
        require(stopped.progress().phase == .cancelled && !FileManager.default.fileExists(atPath: snapshot.path), "cancelled never publishes")
        let control = ScanControl()
        let native = try ExplorerSession.createControlled(sourceRoot: Data(source.path.utf8), snapshotPath: Data(snapshot.path.utf8), workers: 1, control: control)
        require(control.progress().phase == .complete && !control.progress().cancellable, "reopened and indexed")
        require(control.progress().itemsExamined == 2 && !control.cancel(), "root plus file; too late to stop")
        require(try !native.status().simulated, "explicit native constructor")
        _ = try ExplorerSession.create(sourceRoot: Data(source.path.utf8),
            snapshotPath: Data(base.appendingPathComponent("uncontrolled.dmap").path.utf8), workers: 1)
        try FileManager.default.moveItem(at: source, to: base.appendingPathComponent("source-unavailable"))
        let offline = try ExplorerSession.openSnapshot(snapshotPath: Data(snapshot.path.utf8))
        let savedKey = try find(offline, "example")
        _ = try offline.selection(key: savedKey)
        _ = try offline.layout(focus: offline.status().root.key, request: request)
        try expectError({ if case .NotFound = $0 { true } else { false } }) { try offline.liveMetadata(key: savedKey) }
        print("Swift generated bridge smoke passed: diagram/tree/revisions, views, bytes, pins, scopes, failures, refresh, create/offline open")
    }
}
