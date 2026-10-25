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
        let selected = try session.selection(key: large)
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
        require(cancelled.details().rawPath == Data("/simulated-inventory/large-file".utf8), "confirmation raw path")
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

        // One explicitly owned one-file source tests create and offline native snapshot open.
        // No native Trash/permanent operation is ever requested.
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = base.appendingPathComponent("source", isDirectory: true)
        let snapshot = base.appendingPathComponent("saved.dmap")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("owned synthetic fixture".utf8).write(to: source.appendingPathComponent("example"))
        let native = try ExplorerSession.create(sourceRoot: Data(source.path.utf8), snapshotPath: Data(snapshot.path.utf8), workers: 1)
        require(try !native.status().simulated, "explicit native constructor")
        try FileManager.default.moveItem(at: source, to: base.appendingPathComponent("source-unavailable"))
        let offline = try ExplorerSession.openSnapshot(snapshotPath: Data(snapshot.path.utf8))
        let savedKey = try find(offline, "example")
        _ = try offline.selection(key: savedKey)
        _ = try offline.layout(focus: offline.status().root.key, request: request)
        try expectError({ if case .NotFound = $0 { true } else { false } }) { try offline.liveMetadata(key: savedKey) }
        print("Swift generated bridge smoke passed: views, bytes, pins, scopes, failures, refresh, create/offline open")
    }
}
