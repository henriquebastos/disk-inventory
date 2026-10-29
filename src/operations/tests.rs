use super::memory::{MemoryFileSystem, TrashBehavior};
use super::*;
use crate::{
    Counters, Entry, Map,
    layout::{LayoutOptions, Rect},
};

fn meta(ino: u64, kind: Kind, raw: u64) -> LiveMetadata {
    LiveMetadata {
        identity: Identity {
            device: 1,
            inode: ino,
        },
        kind,
        allocated_bytes: raw,
        logical_bytes: raw * 2,
        links: 1,
        mode: 0o600,
        modified_seconds: 123,
        modified_nanoseconds: 456,
        created_seconds: 100,
        flags: 0,
        mount: false,
    }
}
fn empty() -> Map {
    Map {
        root: PathBuf::from("/scope"),
        nodes: Vec::new(),
        names: Vec::new(),
        counters: Counters::default(),
        error_samples: Vec::new(),
    }
}
fn add(map: &mut Map, parent: u32, name: &[u8], m: &LiveMetadata) -> u32 {
    map.add(
        parent,
        name,
        Entry {
            kind: m.kind,
            dev: m.identity.device,
            ino: m.identity.inode,
            flags: m.flags,
            links: m.links,
            allocation: Some(m.allocated_bytes),
            mount: u32::from(m.mount),
        },
    )
    .unwrap()
}
fn session() -> OperationSession<MemoryFileSystem> {
    let mut map = empty();
    add(&mut map, 0, b"", &meta(1, Kind::Dir, 10));
    add(&mut map, 0, b"a", &meta(2, Kind::Dir, 20));
    add(&mut map, 1, b"file", &meta(3, Kind::File, 100));
    add(&mut map, 0, b"z", &meta(4, Kind::Dir, 30));
    add(&mut map, 3, b"sibling", &meta(5, Kind::File, 200));
    map.aggregate().unwrap();
    let mut fs = MemoryFileSystem::default();
    fs.insert("/", meta(99, Kind::Dir, 0));
    fs.insert("/outside", meta(98, Kind::Dir, 0));
    for id in 0..map.nodes.len() {
        let n = &map.nodes[id];
        fs.insert(map.path(id), meta(n.ino, n.kind, n.raw));
    }
    OperationSession::new(Explorer::from_map(map).unwrap(), fs)
}
fn handle(s: &OperationSession<MemoryFileSystem>, id: u32) -> EntryHandle {
    s.explorer.handle(id)
}
fn total<F: FileSystem>(s: &OperationSession<F>) -> u64 {
    s.explorer
        .entry(s.explorer.root_handle())
        .unwrap()
        .subtree_bytes
}
fn options() -> LayoutOptions {
    LayoutOptions {
        viewport: Rect {
            x: 0.,
            y: 0.,
            width: 800.,
            height: 600.,
        },
        max_rectangles: 64,
        min_area: 0.,
        max_depth: 16,
    }
}
fn assert_consistent<F: FileSystem>(s: &OperationSession<F>) {
    let mut own = 0;
    let mut visited = HashSet::new();
    let mut pending = vec![0];
    while let Some(id) = pending.pop() {
        assert!(visited.insert(id));
        assert!(s.explorer.is_live(id));
        let n = &s.explorer.map.nodes[id as usize];
        own += n.accounted;
        let child_sum: u64 = s
            .explorer
            .child_ids(id)
            .iter()
            .map(|&child| {
                assert_eq!(s.explorer.map.nodes[child as usize].parent, id);
                s.explorer.map.nodes[child as usize].subtree
            })
            .sum();
        assert_eq!(n.subtree, n.accounted + child_sum);
        pending.extend_from_slice(s.explorer.child_ids(id));
    }
    assert_eq!(own, total(s));
    let layout = s
        .explorer
        .layout(s.explorer.root_handle(), options())
        .unwrap();
    assert_eq!(layout.tiles.iter().map(|t| t.bytes).sum::<u64>(), total(s));
    assert!(layout.work.child_ids_examined <= 128);
}
#[test]
fn selection_is_offline_and_metadata_is_explicit_without_reaccounting() {
    let mut s = session();
    let file = handle(&s, 2);
    assert_eq!(s.explorer.entry(file).unwrap().allocated_bytes, 100);
    s.explorer.children(s.explorer.root_handle(), 0, 4).unwrap();
    s.explorer
        .layout(s.explorer.root_handle(), options())
        .unwrap();
    assert_eq!(s.filesystem.calls.metadata, 0);
    s.filesystem
        .insert("/scope/a/file", meta(3, Kind::File, 900));
    assert_eq!(s.live_metadata(file).unwrap().logical_bytes, 1800);
    assert_eq!(s.filesystem.calls.metadata, 1);
    assert_eq!(total(&s), 360);
    s.filesystem.erase(Path::new("/scope/a/file"));
    assert!(s.live_metadata(file).is_err());
    assert_eq!(total(&s), 360);
    assert_eq!(s.state(), SessionState::default());
}
#[test]
fn confirmation_rejects_missing_replaced_symlink_and_foreign_handles() {
    for replacement in [
        None,
        Some(meta(9, Kind::File, 100)),
        Some(meta(3, Kind::Symlink, 100)),
    ] {
        let mut s = session();
        let file = handle(&s, 2);
        let confirmation = s.prepare(file, Action::PermanentlyDelete).unwrap();
        s.filesystem.erase(Path::new("/scope/a/file"));
        if let Some(m) = replacement {
            s.filesystem.insert("/scope/a/file", m);
        }
        assert!(s.execute(confirmation).is_err());
        assert_eq!(s.filesystem.calls.remove, 0);
        assert_eq!(total(&s), 360);
    }
    let mut s = session();
    assert!(s.prepare(handle(&session(), 2), Action::Trash).is_err());
    let file = handle(&s, 2);
    s.filesystem.insert("/scope/a", meta(2, Kind::Symlink, 0));
    assert!(s.prepare(file, Action::PermanentlyDelete).is_err());
}
#[test]
fn root_snapshot_and_snapshot_containing_directories_are_protected() {
    let mut s = session();
    assert!(s.prepare(s.explorer.root_handle(), Action::Trash).is_err());
    s.filesystem.pin_snapshot(meta(3, Kind::File, 100).identity);
    for id in [1, 2] {
        assert!(s.prepare(handle(&s, id), Action::Trash).is_err());
        assert!(
            s.prepare(handle(&s, id), Action::PermanentlyDelete)
                .is_err()
        );
    }
    // An alias appearing after preparation is checked again before execution.
    let confirmation = s.prepare(handle(&s, 3), Action::PermanentlyDelete).unwrap();
    s.filesystem
        .insert("/scope/z/map-alias", meta(3, Kind::File, 100));
    assert!(s.execute(confirmation).is_err());
    assert_eq!(s.filesystem.calls.remove, 0);
}
#[test]
fn permanent_file_and_directory_removal_invalidate_only_affected_handles() {
    for id in [1, 2] {
        let mut s = session();
        let selected = handle(&s, id);
        let sibling = handle(&s, 4);
        let confirmation = s.prepare(selected, Action::PermanentlyDelete).unwrap();
        let report = s.execute(confirmation).unwrap();
        assert_eq!(report.mutation, Mutation::Removed);
        assert_eq!(total(&s), if id == 1 { 240 } else { 260 });
        assert!(s.explorer.entry(selected).is_err());
        assert!(s.live_metadata(selected).is_err());
        assert!(s.explorer.entry(sibling).is_ok());
        assert!(report.update.state.dirty);
        assert!(!report.update.state.stale);
        assert_consistent(&s);
    }
}
#[test]
fn trash_moves_inside_outside_and_unknown_without_permanent_fallback() {
    for (destination, expected, unknown) in [
        ("/scope/z/moved", 360, false),
        ("/outside/moved", 260, false),
        ("/outside/moved", 360, true),
    ] {
        let mut s = session();
        s.filesystem.trash_behavior = TrashBehavior::MoveTo(destination.into());
        s.filesystem.unknown_scope = unknown;
        let file = handle(&s, 2);
        let c = s.prepare(file, Action::Trash).unwrap();
        let r = s.execute(c).unwrap();
        assert!(matches!(r.mutation, Mutation::Trashed { .. }));
        assert_eq!(total(&s), expected);
        assert_eq!(s.filesystem.calls.remove, 0);
        assert_eq!(s.state.stale, unknown);
        if destination.starts_with("/scope") {
            assert_eq!(s.explorer.relative_path(file).unwrap(), b"z/moved");
        }
        assert_consistent(&s);
    }
    let mut s = session();
    let c = s.prepare(handle(&s, 2), Action::Trash).unwrap();
    assert!(matches!(
        s.execute(c).unwrap().mutation,
        Mutation::Failed(_)
    ));
    assert_eq!(s.filesystem.calls.remove, 0);
    assert_eq!(total(&s), 360);
    assert!(!s.state.dirty);
}
#[test]
fn scope_uses_directory_identity_aliases_not_textual_prefixes() {
    let mut s = session();
    s.filesystem
        .add_directory_alias("/alias".into(), "/scope/z".into());
    s.filesystem.trash_behavior = TrashBehavior::MoveTo("/alias/moved".into());
    let c = s.prepare(handle(&s, 2), Action::Trash).unwrap();
    let r = s.execute(c).unwrap();
    assert_eq!(r.scope, Some(DestinationScope::Inside(b"z/moved".to_vec())));
    assert_eq!(total(&s), 360);
    assert_consistent(&s);
}
#[test]
fn missing_destination_is_indeterminate_and_retains_recorded_allocation() {
    let mut s = session();
    s.filesystem.trash_behavior = TrashBehavior::MissingDestination("/outside/moved".into());
    let c = s.prepare(handle(&s, 2), Action::Trash).unwrap();
    let r = s.execute(c).unwrap();
    assert!(matches!(r.mutation, Mutation::Indeterminate(_)));
    assert_eq!(total(&s), 360);
    assert_eq!(
        s.state(),
        SessionState {
            dirty: true,
            stale: true
        }
    );
    assert_eq!(s.filesystem.calls.remove, 0);
}
#[test]
fn partial_removal_reconciles_survivors_and_preserves_inaccessible_data() {
    let mut s = session();
    s.filesystem
        .insert("/scope/a/second", meta(6, Kind::File, 50));
    let dir = handle(&s, 1);
    s.refresh_directory(dir).unwrap();
    s.filesystem.remove_failure_after = Some(1);
    let c = s.prepare(dir, Action::PermanentlyDelete).unwrap();
    let r = s.execute(c).unwrap();
    assert!(matches!(r.mutation, Mutation::Partial { .. }));
    assert!(r.update.state.stale);
    assert_eq!(total(&s), 310);
    assert_eq!(s.explorer.entry(dir).unwrap().child_count, 1);
    assert_consistent(&s);
    let retained = total(&s);
    s.filesystem.unreadable.insert("/scope/a".into());
    s.filesystem.erase(Path::new("/scope/a/second"));
    let r = s.refresh_directory(dir).unwrap();
    assert!(r.state.stale);
    assert_eq!(total(&s), retained);
    assert_eq!(s.explorer.entry(dir).unwrap().child_count, 1);
}
#[test]
fn refresh_reconciles_raw_names_replacements_renames_and_snapshot_alias_exclusion() {
    let mut s = session();
    let old = handle(&s, 2);
    let sibling = handle(&s, 4);
    s.filesystem
        .move_entry(Path::new("/scope/a/file"), Path::new("/scope/a/renamed"))
        .unwrap();
    s.filesystem
        .insert("/scope/a/file", meta(7, Kind::File, 80));
    s.filesystem.pin_snapshot(meta(8, Kind::File, 500).identity);
    s.filesystem
        .insert("/scope/a/snapshot", meta(8, Kind::File, 500));
    s.filesystem
        .insert("/scope/a/alias", meta(8, Kind::File, 500));
    s.filesystem.insert(
        Path::new("/scope/a").join(OsStr::from_bytes(b"raw-\xff")),
        meta(9, Kind::File, 0),
    );
    s.filesystem
        .insert("/scope/a/symlink", meta(10, Kind::Symlink, 1000));
    let r = s.refresh_directory(handle(&s, 1)).unwrap();
    assert!(!r.state.stale);
    assert_eq!(total(&s), 440);
    assert!(s.explorer.entry(old).is_err());
    assert!(s.explorer.entry(sibling).is_ok());
    let page = s.explorer.children(handle(&s, 1), 0, 100).unwrap();
    assert_eq!(page.total, 3);
    assert!(page.entries.iter().any(|e| e.basename == b"raw-\xff"));
    assert!(page.entries.iter().all(|e| e.handle.index() > old.index()));
    assert_consistent(&s);
}
#[test]
fn new_hardlink_finds_original_links_one_alias_outside_refreshed_subtree() {
    let mut s = session();
    // The existing /scope/z/sibling had links=1 when indexed.
    let mut alias = meta(5, Kind::File, 240);
    alias.links = 2;
    s.filesystem.insert("/scope/a/alias", alias);
    let r = s.refresh_directory(handle(&s, 1)).unwrap();
    assert!(!r.state.stale);
    assert_eq!(total(&s), 400);
    assert_eq!(
        s.explorer.entry(handle(&s, 4)).unwrap().allocated_bytes,
        240
    );
    assert_eq!(s.explorer.entry(handle(&s, 4)).unwrap().accounted_bytes, 0);
    let alias = s
        .explorer
        .children(handle(&s, 1), 0, 10)
        .unwrap()
        .entries
        .into_iter()
        .find(|e| e.basename == b"alias")
        .unwrap()
        .handle;
    let c = s.prepare(alias, Action::PermanentlyDelete).unwrap();
    s.execute(c).unwrap();
    assert_eq!(total(&s), 400);
    assert_eq!(
        s.explorer.entry(handle(&s, 4)).unwrap().accounted_bytes,
        240
    );
    assert_consistent(&s);
}
#[test]
fn directory_move_recomputes_canonical_hardlink_paths_outside_moved_subtree() {
    let mut s = session();
    let mut alias = meta(5, Kind::File, 200);
    alias.links = 2;
    s.filesystem.insert("/scope/a/alias", alias);
    s.refresh_directory(handle(&s, 1)).unwrap();
    assert_eq!(s.explorer.entry(handle(&s, 4)).unwrap().accounted_bytes, 0);
    s.filesystem.trash_behavior = TrashBehavior::MoveTo("/scope/zz".into());
    let dir = handle(&s, 1);
    let c = s.prepare(dir, Action::Trash).unwrap();
    s.execute(c).unwrap();
    assert_eq!(s.explorer.relative_path(dir).unwrap(), b"zz");
    assert_eq!(
        s.explorer.entry(handle(&s, 4)).unwrap().accounted_bytes,
        200
    );
    assert_eq!(total(&s), 360);
    assert_consistent(&s);
}
#[test]
fn moved_confirmation_is_stale_and_deleted_slots_are_never_reused() {
    let mut s = session();
    let file = handle(&s, 2);
    let old = s.prepare(file, Action::PermanentlyDelete).unwrap();
    s.filesystem.trash_behavior = TrashBehavior::MoveTo("/scope/z/moved".into());
    let c = s.prepare(file, Action::Trash).unwrap();
    s.execute(c).unwrap();
    assert!(s.execute(old).is_err());
    let c = s.prepare(file, Action::PermanentlyDelete).unwrap();
    s.execute(c).unwrap();
    s.filesystem
        .insert("/scope/z/moved", meta(10, Kind::File, 100));
    s.refresh_directory(handle(&s, 3)).unwrap();
    assert!(s.explorer.entry(file).is_err());
    assert_eq!(s.filesystem.calls.remove, 1);
    assert_consistent(&s);
}
fn with_unrelated(count: usize) -> OperationSession<MemoryFileSystem> {
    let mut s = session();
    let mut map = s.explorer.map.clone();
    for i in 0..count {
        add(
            &mut map,
            3,
            format!("other-{i:08}").as_bytes(),
            &meta(1000 + i as u64, Kind::File, 4),
        );
    }
    map.aggregate().unwrap();
    s.explorer = Explorer::from_map(map).unwrap();
    OperationSession::new(s.explorer, s.filesystem)
}
#[test]
fn incremental_work_is_independent_of_unrelated_entries_and_batched_per_parent() {
    let mut work = Vec::new();
    for count in [10, 100_000] {
        let mut s = with_unrelated(count);
        let c = s.prepare(handle(&s, 2), Action::PermanentlyDelete).unwrap();
        let r = s.execute(c).unwrap();
        // Two logarithmic lookups: pre-update baseline and final attribution.
        assert!(r.update.work.identity_comparisons < 64);
        assert_eq!(r.update.work.nodes_examined, 3);
        work.push((
            r.update.work.child_ids_copied,
            r.update.work.child_ids_sorted,
            r.update.work.ancestor_updates,
        ));
        let layout = s
            .explorer
            .layout(s.explorer.root_handle(), options())
            .unwrap();
        assert!(layout.work.child_ids_examined <= 128);
        assert_eq!(
            s.explorer
                .children(handle(&s, 3), 500, 10)
                .unwrap()
                .entries_examined,
            if count == 10 { 0 } else { 10 }
        );
        // Batch many additions/removals: child copying must not be quadratic.
        for i in 0..1000 {
            s.filesystem.insert(
                format!("/scope/a/new-{i}"),
                meta(1000000 + i, Kind::File, 1),
            );
        }
        let r = s.refresh_directory(handle(&s, 1)).unwrap();
        assert!(r.work.child_ids_copied < 1100, "{:?}", r.work);
        for i in 0..1000 {
            s.filesystem.erase(Path::new(&format!("/scope/a/new-{i}")));
        }
        let r = s.refresh_directory(handle(&s, 1)).unwrap();
        assert!(r.work.child_ids_copied < 1100, "{:?}", r.work);
    }
    assert_eq!(work[0], work[1]);
}
#[test]
fn refresh_mount_firmlink_and_inaccessible_regions_are_not_followed() {
    let mut s = session();
    let dir = handle(&s, 1);
    for (name, mut m) in [
        ("mount", meta(20, Kind::Dir, 100)),
        ("firmlink", meta(21, Kind::Dir, 100)),
        ("device", meta(22, Kind::Dir, 100)),
    ] {
        match name {
            "mount" => m.mount = true,
            "firmlink" => m.flags = crate::native::SF_FIRMLINK,
            _ => m.identity.device = 2,
        }
        s.filesystem.insert(format!("/scope/a/{name}"), m);
    }
    s.refresh_directory(dir).unwrap();
    assert_eq!(total(&s), 360);
    assert_eq!(s.explorer.entry(dir).unwrap().child_count, 1);
    s.filesystem.unreadable.insert("/scope/a".into());
    // The live mount, firmlink and other-device entries refuse both actions.
    assert!(s.prepare(dir, Action::PermanentlyDelete).is_err());
    assert!(s.prepare(dir, Action::Trash).is_err());
    // An inaccessible folder alone no longer prevents preparation: Delete skips it and
    // reports it, so nothing is deleted and the inventory stays.
    for name in ["mount", "firmlink", "device"] {
        s.filesystem.erase(Path::new(&format!("/scope/a/{name}")));
    }
    let c = s.prepare(dir, Action::PermanentlyDelete).unwrap();
    let Mutation::Failed(message) = s.execute(c).unwrap().mutation else {
        panic!("nothing could be deleted")
    };
    assert!(message.contains("/scope/a: permission denied"), "{message}");
    assert_eq!(total(&s), 360);
    assert!(s.filesystem.get(Path::new("/scope/a/file")).is_some());
    assert_consistent(&s);
}

pub(super) struct Fixture(pub(super) PathBuf);
impl Fixture {
    pub(super) fn new() -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        // An owned directory in the canonical temporary directory: no symlink ancestry.
        let path = std::fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!(
                "operations-fixture-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).unwrap();
    }
}
#[test]
fn native_owned_fixture_metadata_url_scope_and_nofollow_permanent_removal() {
    use std::{fs, os::unix::fs::symlink};
    let fixture = Fixture::new();
    let root = fixture.0.join("root");
    fs::create_dir(&root).unwrap();
    let nested = root.join("nested");
    fs::create_dir(&nested).unwrap();
    let outside = fixture.0.join("outside");
    fs::create_dir(&outside).unwrap();
    fs::write(outside.join("keep"), b"owned outside fixture").unwrap();
    fs::write(nested.join("file"), vec![0; 4096]).unwrap();
    symlink(&outside, nested.join("link")).unwrap();
    let map = fixture.0.join("map");
    crate::inventory::Inventory::create(&root, &map, Default::default()).unwrap();
    let mut s = native::NativeFileSystem::open_snapshot(&map).unwrap();
    let dir = s
        .explorer
        .children(s.explorer.root_handle(), 0, 10)
        .unwrap()
        .entries[0]
        .handle;
    assert_eq!(s.live_metadata(dir).unwrap().kind, Kind::Dir);
    let root_id = index::identity(&s.explorer.map.nodes[0]);
    assert_eq!(
        s.filesystem
            .classify_destination(&nested.join("file"), root_id),
        DestinationScope::Inside(b"nested/file".to_vec())
    );
    assert_eq!(
        s.filesystem
            .classify_destination(&outside.join("keep"), root_id),
        DestinationScope::Outside
    );
    assert_eq!(
        s.filesystem
            .classify_destination(&nested.join("missing"), root_id),
        DestinationScope::Unknown
    );
    // Controlled owned fixture accessed through the Data-volume namespace alias.
    let data_alias = PathBuf::from(format!(
        "/System/Volumes/Data{}",
        nested.join("file").display()
    ));
    match s.filesystem.metadata(&data_alias) {
        Ok(m)
            if m.identity
                == s.filesystem
                    .metadata(&nested.join("file"))
                    .unwrap()
                    .identity =>
        {
            assert_eq!(
                s.filesystem.classify_destination(&data_alias, root_id),
                DestinationScope::Inside(b"nested/file".to_vec())
            );
            println!("owned Data-volume alias identity/scope check passed");
        }
        _ => println!("SKIP: owned Data-volume alias not available on this host"),
    }
    native::validate_trash_path(&nested.join("é # line\nquoted\""), false).unwrap();
    native::validate_trash_path(&nested, true).unwrap();
    native::validate_trash_path(&nested.join("file"), false).unwrap();
    assert!(
        native::validate_trash_path(&root.join(OsStr::from_bytes(b"bad-\xff")), false).is_err()
    );
    assert!(native::validate_trash_path(&root.join("x".repeat(1024)), false).is_err());
    // /tmp is a symlink alias, not a firmlink: ancestor identity classification fails closed.
    let alias = PathBuf::from(nested.join("file").to_string_lossy().replacen(
        "/private/tmp",
        "/tmp",
        1,
    ));
    assert_eq!(
        s.filesystem.classify_destination(&alias, root_id),
        DestinationScope::Unknown
    );
    let c = s.prepare(dir, Action::PermanentlyDelete).unwrap();
    assert_eq!(s.execute(c).unwrap().mutation, Mutation::Removed);
    assert!(!nested.exists());
    assert!(outside.join("keep").exists());
    assert!(map.exists());
    assert_consistent(&s);
    // Snapshot open remains offline when the recorded root has vanished.
    fs::rename(&root, fixture.0.join("renamed-root")).unwrap();
    let offline = native::NativeFileSystem::open_snapshot(&map).unwrap();
    assert!(
        offline
            .explorer
            .children(offline.explorer.root_handle(), 0, 10)
            .is_ok()
    );
}
#[test]
fn native_snapshot_alias_protection_and_replaced_target_rejection() {
    use std::fs;
    let fixture = Fixture::new();
    let root = fixture.0.join("root");
    fs::create_dir(&root).unwrap();
    let nested = root.join("nested");
    fs::create_dir(&nested).unwrap();
    fs::write(nested.join("file"), b"fixture").unwrap();
    let map = fixture.0.join("map");
    crate::inventory::Inventory::create(&root, &map, Default::default()).unwrap();
    let mut s = native::NativeFileSystem::open_snapshot(&map).unwrap();
    let dir = s
        .explorer
        .children(s.explorer.root_handle(), 0, 10)
        .unwrap()
        .entries[0]
        .handle;
    let file = s.explorer.children(dir, 0, 10).unwrap().entries[0].handle;
    let c = s.prepare(file, Action::PermanentlyDelete).unwrap();
    fs::rename(nested.join("file"), nested.join("old")).unwrap();
    fs::write(nested.join("file"), b"replacement").unwrap();
    assert!(s.execute(c).is_err());
    assert!(nested.join("file").exists());
    fs::hard_link(&map, nested.join("map-alias")).unwrap();
    s.refresh_directory(dir).unwrap();
    assert_eq!(s.explorer.entry(dir).unwrap().child_count, 2);
    // An extra hard link of the snapshot is a protected entry: Delete skips it and keeps
    // its folder; the replacement and the renamed original are deleted.
    let c = s.prepare(dir, Action::PermanentlyDelete).unwrap();
    let Mutation::RemovedWithSkips(removal) = s.execute(c).unwrap().mutation else {
        panic!("the snapshot alias is skipped")
    };
    assert_eq!((removal.removed, removal.skipped), (2, 1));
    assert!(removal.reasons[0].contains("map-alias: protected"));
    assert!(nested.join("map-alias").exists());
    assert!(!nested.join("file").exists() && !nested.join("old").exists());
    assert_eq!(s.explorer.entry(dir).unwrap().child_count, 0);
    assert!(map.exists());
}

#[path = "performance.rs"]
mod performance;

#[test]
fn partial_removal_with_failed_reconciliation_retains_unknown_children() {
    let mut s = session();
    s.filesystem
        .insert("/scope/a/second", meta(6, Kind::File, 50));
    let dir = handle(&s, 1);
    s.refresh_directory(dir).unwrap();
    let before = total(&s);
    s.filesystem.remove_failure_after = Some(1);
    s.filesystem.unreadable_after_partial = true;
    let c = s.prepare(dir, Action::PermanentlyDelete).unwrap();
    let r = s.execute(c).unwrap();
    assert!(matches!(r.mutation, Mutation::Partial { .. }));
    assert!(r.update.issues.len() >= 2);
    assert!(r.update.state.stale);
    assert_eq!(total(&s), before);
    assert_eq!(s.explorer.entry(dir).unwrap().child_count, 2);
    assert_consistent(&s);
}
#[test]
fn existing_hardlinks_allocation_and_directory_own_bytes_update_locally() {
    let mut s = session();
    let mut linked = meta(3, Kind::File, 100);
    linked.links = 2;
    let mut map = s.explorer.map.clone();
    map.nodes[2].links = 2;
    add(&mut map, 3, b"alias", &linked);
    map.aggregate().unwrap();
    s.filesystem.insert("/scope/a/file", linked.clone());
    s.filesystem.insert("/scope/z/alias", linked.clone());
    let mut s = OperationSession::new(Explorer::from_map(map).unwrap(), s.filesystem);
    assert_eq!(total(&s), 360);
    linked.allocated_bytes = 400;
    s.filesystem.insert("/scope/z/alias", linked);
    s.filesystem.insert("/scope/z", meta(4, Kind::Dir, 50));
    let r = s.refresh_directory(handle(&s, 3)).unwrap();
    assert!(!r.state.stale);
    assert_eq!(total(&s), 680);
    assert_eq!(
        s.explorer.entry(handle(&s, 2)).unwrap().accounted_bytes,
        400
    );
    assert_eq!(s.explorer.entry(handle(&s, 5)).unwrap().accounted_bytes, 0);
    assert_consistent(&s);
    let root = s.explorer.root_handle();
    let r = s.refresh_directory(root).unwrap();
    assert!(r.issues.is_empty());
    assert_eq!(total(&s), 680);
    assert_consistent(&s);
}
#[test]
fn no_op_refresh_preserves_handles_and_clean_state_and_replaced_root_is_rejected() {
    let mut s = session();
    let file = handle(&s, 2);
    let r = s.refresh_directory(handle(&s, 1)).unwrap();
    assert_eq!(r.state, SessionState::default());
    assert!(s.explorer.entry(file).is_ok());
    let c = s.prepare(file, Action::PermanentlyDelete).unwrap();
    s.filesystem.insert("/scope", meta(999, Kind::Dir, 0));
    assert!(s.execute(c).is_err());
    let r = s.refresh_directory(handle(&s, 1)).unwrap();
    assert!(r.state.stale);
    assert_eq!(total(&s), 360);
    assert!(s.explorer.entry(file).is_ok());
}
#[test]
fn accounting_overflow_retains_consistent_attributed_totals_and_marks_stale() {
    let mut map = empty();
    let mut fs = MemoryFileSystem::default();
    let huge = meta(1, Kind::Dir, i64::MAX as u64);
    add(&mut map, 0, b"", &huge);
    fs.insert("/scope", huge);
    let huge = meta(2, Kind::File, i64::MAX as u64);
    add(&mut map, 0, b"file", &huge);
    fs.insert("/scope/file", huge);
    map.aggregate().unwrap();
    let mut s = OperationSession::new(Explorer::from_map(map).unwrap(), fs);
    let before = total(&s);
    s.filesystem.insert("/scope/new", meta(3, Kind::File, 100));
    let r = s.refresh_directory(s.explorer.root_handle()).unwrap();
    assert!(r.state.stale);
    assert_eq!(total(&s), before);
    assert_consistent(&s);
}
#[test]
fn activity_is_observable_while_worker_refreshes_and_last_layout_remains_usable() {
    struct Blocking {
        inner: MemoryFileSystem,
        started: std::sync::mpsc::Sender<()>,
        resume: std::sync::mpsc::Receiver<()>,
    }
    impl FileSystem for Blocking {
        type Pin = <MemoryFileSystem as FileSystem>::Pin;
        fn pin(&mut self, target: &Target) -> io::Result<Self::Pin> {
            self.inner.pin(target)
        }
        fn snapshot_identity(&self) -> Option<Identity> {
            self.inner.snapshot_identity()
        }
        fn metadata(&mut self, p: &Path) -> io::Result<LiveMetadata> {
            self.inner.metadata(p)
        }
        fn read_directory(&mut self, t: &Target) -> io::Result<Vec<DirectoryEntry>> {
            self.started.send(()).unwrap();
            self.resume.recv().unwrap();
            self.inner.read_directory(t)
        }
        fn trash(&mut self, t: &Target, pin: &Self::Pin) -> Mutation {
            self.inner.trash(t, pin)
        }
        fn refuse_protected_within(&mut self, t: &Target) -> io::Result<()> {
            self.inner.refuse_protected_within(t)
        }
        fn remove(
            &mut self,
            t: &Target,
            pin: &Self::Pin,
            control: Option<&ScanControl>,
        ) -> Mutation {
            self.inner.remove(t, pin, control)
        }
        fn classify_destination(&mut self, p: &Path, r: Identity) -> DestinationScope {
            self.inner.classify_destination(p, r)
        }
    }
    let s = session();
    let (started, rx) = std::sync::mpsc::channel();
    let (tx, resume) = std::sync::mpsc::channel();
    let mut s = OperationSession::new(
        s.explorer,
        Blocking {
            inner: s.filesystem,
            started,
            resume,
        },
    );
    let last = s
        .explorer
        .layout(s.explorer.root_handle(), options())
        .unwrap();
    let activity = s.activity();
    assert!(!activity.is_busy());
    let dir = s.explorer.handle(1);
    let worker = std::thread::spawn(move || {
        let r = s.refresh_directory(dir).unwrap();
        (s, r)
    });
    rx.recv().unwrap();
    assert!(activity.is_busy());
    assert_eq!(last.total_bytes, 360);
    tx.send(()).unwrap();
    let (s, r) = worker.join().unwrap();
    assert!(!activity.is_busy());
    assert!(!r.state.stale);
    assert_consistent(&s);
}

#[test]
fn confirmations_pin_live_identity_until_cancel_error_or_completion() {
    let mut s = session();
    let file = handle(&s, 2);
    s.filesystem
        .insert("/scope/a/file", meta(3, Kind::File, 150));
    let c = s.prepare(file, Action::Trash).unwrap();
    assert_eq!(c.metadata().allocated_bytes, 150);
    assert_eq!(c.path(), Path::new("/scope/a/file"));
    assert_eq!(s.filesystem.pinned_count(), 1);
    drop(c);
    assert_eq!(s.filesystem.pinned_count(), 0);
    let c = s.prepare(file, Action::PermanentlyDelete).unwrap();
    s.filesystem
        .insert("/scope/a/file", meta(99, Kind::File, 150));
    assert!(s.execute(c).is_err());
    assert_eq!(s.filesystem.pinned_count(), 0);
    s.filesystem
        .insert("/scope/a/file", meta(3, Kind::File, 150));
    let c = s.prepare(file, Action::PermanentlyDelete).unwrap();
    s.execute(c).unwrap();
    assert_eq!(s.filesystem.pinned_count(), 0);
}
#[test]
fn native_confirmation_keeps_unlinked_inode_pinned_and_rejects_replacement() {
    use std::{fs, os::unix::fs::MetadataExt};
    let fixture = Fixture::new();
    let root = fixture.0.join("root");
    fs::create_dir(&root).unwrap();
    let path = root.join("file");
    fs::write(&path, b"owned fixture").unwrap();
    let map = fixture.0.join("map");
    crate::inventory::Inventory::create(&root, &map, Default::default()).unwrap();
    let mut s = native::NativeFileSystem::open_snapshot(&map).unwrap();
    let file = s
        .explorer
        .children(s.explorer.root_handle(), 0, 1)
        .unwrap()
        .entries[0]
        .handle;
    let c = s.prepare(file, Action::PermanentlyDelete).unwrap();
    assert_eq!(
        c.pin._file.metadata().unwrap().ino(),
        c.metadata().identity.inode
    );
    drop(c);
    assert!(path.exists()); // Cancellation performs no mutation.
    let c = s.prepare(file, Action::PermanentlyDelete).unwrap();
    fs::remove_file(&path).unwrap();
    assert_eq!(c.pin._file.metadata().unwrap().nlink(), 0);
    fs::write(&path, b"new owned fixture").unwrap();
    assert!(s.execute(c).is_err());
    assert!(path.exists());
    s.refresh_directory(s.explorer.root_handle()).unwrap();
    let replacement = s
        .explorer
        .children(s.explorer.root_handle(), 0, 1)
        .unwrap()
        .entries[0]
        .handle;
    assert_ne!(file, replacement);
    let c = s.prepare(replacement, Action::PermanentlyDelete).unwrap();
    let retained = root.join("retained");
    fs::rename(&path, &retained).unwrap();
    let outside = fixture.0.join("outside");
    fs::write(&outside, b"owned outside target").unwrap();
    std::os::unix::fs::symlink(&outside, &path).unwrap();
    assert!(s.execute(c).is_err());
    assert!(outside.exists());
    fs::remove_file(&path).unwrap();
    fs::rename(&retained, &path).unwrap();
    let c = s.prepare(replacement, Action::PermanentlyDelete).unwrap();
    assert_eq!(s.execute(c).unwrap().mutation, Mutation::Removed);
    assert!(!path.exists());
}
#[test]
fn deleting_owner_reconciles_current_allocation_of_surviving_hardlink() {
    let mut s = session();
    let mut linked = meta(3, Kind::File, 100);
    linked.links = 2;
    s.filesystem.insert("/scope/z/alias", linked.clone());
    s.refresh_directory(handle(&s, 3)).unwrap();
    linked.allocated_bytes = 500;
    s.filesystem.insert("/scope/z/alias", linked);
    let c = s.prepare(handle(&s, 2), Action::PermanentlyDelete).unwrap();
    s.execute(c).unwrap();
    assert_eq!(total(&s), 760);
    assert_consistent(&s);
}
#[test]
fn in_scope_directory_move_keeps_the_saved_subtree_without_a_walk_and_marks_new_ancestry_unknown() {
    let mut s = session();
    s.filesystem.insert("/scope/new", meta(50, Kind::Dir, 7));
    s.filesystem
        .insert("/scope/new/unscanned", meta(51, Kind::File, 999));
    s.filesystem
        .insert("/scope/a/live-new", meta(52, Kind::File, 13));
    s.filesystem.trash_behavior = TrashBehavior::MoveTo("/scope/new/moved".into());
    let dir = handle(&s, 1);
    let c = s.prepare(dir, Action::Trash).unwrap();
    let r = s.execute(c).unwrap();
    assert_eq!(s.explorer.relative_path(dir).unwrap(), b"new/moved");
    // The saved subtree moved with its saved sizes: no directory of it was read, so the
    // live file the scan never saw is not added.
    assert_eq!(s.filesystem.calls.directories, 0);
    assert_eq!(s.explorer.entry(dir).unwrap().child_count, 1);
    assert_eq!(s.explorer.entry(dir).unwrap().subtree_bytes, 120);
    assert!(r.update.state.stale);
    assert_eq!(total(&s), 367);
    assert_consistent(&s);
}

#[test]
fn unvalidated_returned_destination_is_unknown_even_when_ancestry_is_outside() {
    let mut s = session();
    s.filesystem.trash_behavior = TrashBehavior::MoveTo("/outside/moved".into());
    s.filesystem.metadata_errors.insert("/outside/moved".into());
    let c = s.prepare(handle(&s, 2), Action::Trash).unwrap();
    let r = s.execute(c).unwrap();
    assert_eq!(r.scope, Some(DestinationScope::Unknown));
    assert!(r.update.state.stale);
    assert_eq!(total(&s), 360);
    assert_eq!(s.filesystem.calls.remove, 0);
    assert_consistent(&s);
}

fn survivor_session() -> OperationSession<MemoryFileSystem> {
    let mut s = session();
    let mut alias = meta(3, Kind::File, 100);
    alias.links = 2;
    s.filesystem.insert("/scope/z/alias", alias.clone());
    s.refresh_directory(handle(&s, 3)).unwrap();
    alias.allocated_bytes = 500;
    s.filesystem.insert("/scope/z/alias", alias);
    s
}
#[test]
fn directory_removal_refreshes_surviving_hardlink_allocation() {
    let mut s = survivor_session();
    let c = s.prepare(handle(&s, 1), Action::PermanentlyDelete).unwrap();
    let r = s.execute(c).unwrap();
    println!(
        "directory removal total={} work={:?}",
        total(&s),
        r.update.work
    );
    assert_eq!(total(&s), 740);
    assert!(!r.update.state.stale);
    let alias = s
        .explorer
        .children(handle(&s, 3), 0, 10)
        .unwrap()
        .entries
        .into_iter()
        .find(|e| e.basename == b"alias")
        .unwrap()
        .handle;
    assert_eq!(s.explorer.entry(alias).unwrap().allocated_bytes, 500);
    assert_consistent(&s);
}
#[test]
fn outside_directory_trash_refreshes_surviving_hardlink_allocation() {
    let mut s = survivor_session();
    s.filesystem.trash_behavior = TrashBehavior::MoveTo("/outside/moved".into());
    let c = s.prepare(handle(&s, 1), Action::Trash).unwrap();
    let r = s.execute(c).unwrap();
    assert_eq!(r.scope, Some(DestinationScope::Outside));
    assert_eq!(total(&s), 740);
    assert!(!r.update.state.stale);
    assert_eq!(s.filesystem.calls.remove, 0);
    assert_consistent(&s);
}
#[test]
fn survivor_observation_failure_retains_recorded_allocation_and_marks_stale() {
    let mut s = survivor_session();
    s.filesystem.metadata_errors.insert("/scope/z/alias".into());
    let c = s.prepare(handle(&s, 1), Action::PermanentlyDelete).unwrap();
    let r = s.execute(c).unwrap();
    assert!(r.update.state.stale);
    assert!(!r.update.issues.is_empty());
    assert_eq!(total(&s), 340);
    assert_consistent(&s);
}
#[test]
fn hardlink_observations_are_batched_for_new_and_changed_aliases() {
    let mut measurements = Vec::new();
    for count in [100, 1000] {
        let mut s = session();
        let mut alias = meta(5, Kind::File, 200);
        alias.links = count + 1;
        for i in 0..count {
            s.filesystem
                .insert(format!("/scope/a/alias-{i:04}"), alias.clone());
        }
        let r = s.refresh_directory(handle(&s, 1)).unwrap();
        println!("new_aliases={count} work={:?}", r.work);
        measurements.push((count, r.work.identity_members));
        assert_eq!(total(&s), 360);
        alias.allocated_bytes = 500;
        s.filesystem.insert("/scope/z/sibling", alias);
        let r = s.refresh_directory(handle(&s, 1)).unwrap();
        println!("changed_aliases={count} work={:?}", r.work);
        measurements.push((count, r.work.identity_members));
        assert_eq!(total(&s), 660);
        assert!(!r.state.stale);
        assert_consistent(&s);
    }
    for (count, members) in measurements {
        assert!(
            members <= 5 * (count as usize + 1),
            "{count} aliases visited {members} times"
        );
    }
}
#[test]
fn unchanged_nonfile_link_counts_do_not_dirty_refresh() {
    let mut s = session();
    let mut directory = meta(2, Kind::Dir, 20);
    directory.links = 9;
    s.filesystem.insert("/scope/a", directory);
    let mut root = meta(1, Kind::Dir, 10);
    root.links = 3;
    s.filesystem.insert("/scope", root);
    let r = s.refresh_directory(handle(&s, 1)).unwrap();
    assert_eq!(r.state, SessionState::default());
    assert_eq!(total(&s), 360);
    assert_eq!(s.explorer.map.nodes[1].links, 1);
}

fn native_regular_fixture(count: usize) -> (Fixture, OperationSession<native::NativeFileSystem>) {
    let fixture = Fixture::new();
    let root = fixture.0.join("root");
    std::fs::create_dir(&root).unwrap();
    for i in 0..count {
        std::fs::File::create(root.join(format!("file-{i:05}"))).unwrap();
    }
    std::fs::write(root.join("file-00000"), vec![0; 4096]).unwrap();
    let map = fixture.0.join("map");
    crate::inventory::Inventory::create(&root, &map, Default::default()).unwrap();
    let s = native::NativeFileSystem::open_snapshot(&map).unwrap();
    (fixture, s)
}
#[test]
fn native_regular_refresh_uses_bulk_records_without_child_stats() {
    let (_fixture, mut s) = native_regular_fixture(128);
    let r = s.refresh_directory(s.explorer.root_handle()).unwrap();
    let work = s.filesystem.enumeration_work;
    println!(
        "native regular refresh: {work:?}; targeted metadata={}",
        s.filesystem.metadata_requests
    );
    assert_eq!(work.records, 128);
    assert_eq!(work.child_stat_calls, 0);
    assert_eq!(s.filesystem.metadata_requests, 2); // root validation and root-own allocation
    assert_eq!(r.state, SessionState::default());
    let file = s
        .explorer
        .children(s.explorer.root_handle(), 0, 1)
        .unwrap()
        .entries[0]
        .handle;
    let live = s.live_metadata(file).unwrap();
    assert_eq!(live.logical_bytes, 4096);
    assert_eq!(s.filesystem.metadata_requests, 3);
    assert_consistent(&s);
}
#[test]
#[ignore = "bounded owned native fixture measurement (25,000 regular files)"]
fn native_owned_bulk_refresh_performance() {
    let started = std::time::Instant::now();
    let (_fixture, mut s) = native_regular_fixture(25_000);
    println!(
        "native fixture files=25000 create_scan_load_ms={:.3}",
        started.elapsed().as_secs_f64() * 1000.
    );
    for iteration in 0..3 {
        if iteration != 0 {
            std::fs::write(
                s.explorer.root().join(format!("file-{iteration:05}")),
                vec![0; 4096 * iteration],
            )
            .unwrap();
        }
        s.filesystem.enumeration_work = Default::default();
        s.filesystem.metadata_requests = 0;
        s.filesystem.enumeration_elapsed = std::time::Duration::ZERO;
        let started = std::time::Instant::now();
        let r = s.refresh_directory(s.explorer.root_handle()).unwrap();
        println!(
            "native refresh iteration={iteration} (0=no-op,1/2=one-file-change) total_ms={:.3} native_directory_ms={:.3} enumeration={:?} targeted_metadata={} core_work={:?}",
            started.elapsed().as_secs_f64() * 1000.,
            s.filesystem.enumeration_elapsed.as_secs_f64() * 1000.,
            s.filesystem.enumeration_work,
            s.filesystem.metadata_requests,
            r.work
        );
        assert_eq!(s.filesystem.enumeration_work.records, 25_000);
        assert_eq!(s.filesystem.enumeration_work.child_stat_calls, 0);
        assert_eq!(s.filesystem.metadata_requests, 2);
        assert!(!r.state.stale);
        assert_consistent(&s);
    }
}
#[test]
fn conflicting_hardlink_observations_preserve_previous_allocations() {
    let mut s = session();
    let mut alias = meta(5, Kind::File, 200);
    alias.links = 3;
    s.filesystem.insert("/scope/a/alias-a", alias.clone());
    s.filesystem.insert("/scope/a/alias-b", alias);
    s.refresh_directory(handle(&s, 1)).unwrap();
    // Deliberately inconsistent fixture records: singleton inserts bypass the
    // fake's normal shared-inode propagation to model a racing enumeration.
    s.filesystem
        .insert("/scope/a/alias-a", meta(5, Kind::File, 100));
    s.filesystem
        .insert("/scope/a/alias-b", meta(5, Kind::File, 500));
    let r = s.refresh_directory(handle(&s, 1)).unwrap();
    assert!(r.state.stale);
    assert!(
        r.issues
            .iter()
            .any(|s| s.contains("conflicting allocation"))
    );
    assert_eq!(total(&s), 360);
    for entry in s.explorer.children(handle(&s, 1), 0, 10).unwrap().entries {
        if entry.basename.starts_with(b"alias") {
            assert_eq!(entry.allocated_bytes, 200);
        }
    }
    assert_consistent(&s);
}

struct ListingOrder {
    inner: MemoryFileSystem,
    reverse: bool,
}
impl FileSystem for ListingOrder {
    type Pin = <MemoryFileSystem as FileSystem>::Pin;
    fn pin(&mut self, t: &Target) -> io::Result<Self::Pin> {
        self.inner.pin(t)
    }
    fn snapshot_identity(&self) -> Option<Identity> {
        self.inner.snapshot_identity()
    }
    fn metadata(&mut self, p: &Path) -> io::Result<LiveMetadata> {
        self.inner.metadata(p)
    }
    fn read_directory(&mut self, t: &Target) -> io::Result<Vec<DirectoryEntry>> {
        let mut entries = self.inner.read_directory(t)?;
        if self.reverse {
            entries.reverse();
        }
        Ok(entries)
    }
    fn trash(&mut self, t: &Target, p: &Self::Pin) -> Mutation {
        self.inner.trash(t, p)
    }
    fn refuse_protected_within(&mut self, t: &Target) -> io::Result<()> {
        self.inner.refuse_protected_within(t)
    }
    fn remove(&mut self, t: &Target, p: &Self::Pin, c: Option<&ScanControl>) -> Mutation {
        self.inner.remove(t, p, c)
    }
    fn classify_destination(&mut self, p: &Path, r: Identity) -> DestinationScope {
        self.inner.classify_destination(p, r)
    }
}
#[test]
fn newly_appended_conflicting_aliases_retain_baseline_in_both_orders() {
    for (first, last) in [(100, 500), (500, 100)] {
        for reverse_listing in [false, true] {
            let mut s = session();
            let rows = vec![("/scope/a/alias-a", first), ("/scope/a/alias-b", last)];
            for (path, raw) in rows {
                s.filesystem.insert(path, meta(5, Kind::File, raw));
            }
            let mut s = OperationSession::new(
                s.explorer,
                ListingOrder {
                    inner: s.filesystem,
                    reverse: reverse_listing,
                },
            );
            let r = s.refresh_directory(s.explorer.handle(1)).unwrap();
            println!(
                "new conflict first={first} reverse_listing={reverse_listing} total={} work={:?}",
                total(&s),
                r.work
            );
            assert_eq!(total(&s), 360);
            assert!(r.state.stale);
            let aliases: Vec<_> = s
                .explorer
                .children(s.explorer.handle(1), 0, 10)
                .unwrap()
                .entries
                .into_iter()
                .filter(|e| e.basename.starts_with(b"alias"))
                .collect();
            assert_eq!(aliases.len(), 2);
            for a in aliases {
                assert_eq!(a.allocated_bytes, 200);
                assert_eq!(
                    a.accounted_bytes,
                    if a.basename == b"alias-a" { 200 } else { 0 }
                );
            }
            assert_eq!(
                s.explorer
                    .entry(s.explorer.handle(4))
                    .unwrap()
                    .accounted_bytes,
                0
            );
            assert_consistent(&s);
        }
    }
}
#[test]
fn conflicting_new_aliases_retain_baseline_when_old_alias_is_removed() {
    let mut s = session();
    // This identity is an overlay entry, not an original baseline-index slot.
    s.filesystem
        .insert("/scope/a/old", meta(20, Kind::File, 200));
    s.refresh_directory(handle(&s, 1)).unwrap();
    let before = total(&s);
    s.filesystem.erase(Path::new("/scope/a/old"));
    s.filesystem
        .insert("/scope/a/alias-a", meta(20, Kind::File, 100));
    s.filesystem
        .insert("/scope/a/alias-b", meta(20, Kind::File, 500));
    let r = s.refresh_directory(handle(&s, 1)).unwrap();
    println!("removed baseline total={} work={:?}", total(&s), r.work);
    assert!(r.state.stale);
    assert_eq!(total(&s), before);
    for a in s.explorer.children(handle(&s, 1), 0, 10).unwrap().entries {
        if a.basename.starts_with(b"alias") {
            assert_eq!(a.allocated_bytes, 200);
        }
    }
    assert_consistent(&s);
}
#[test]
fn entirely_new_conflicting_identity_remains_unattributed_until_consistent() {
    for (first, last) in [(100, 500), (500, 100)] {
        let mut s = session();
        for (path, raw) in [("/scope/a/alias-a", first), ("/scope/a/alias-b", last)] {
            s.filesystem.insert(path, meta(20, Kind::File, raw));
        }
        for iteration in 0..2 {
            let r = s.refresh_directory(handle(&s, 1)).unwrap();
            println!(
                "unknown conflict iteration={iteration} first={first} total={} work={:?}",
                total(&s),
                r.work
            );
            assert_eq!(total(&s), 360);
            assert!(r.state.stale);
            assert!(r.issues.iter().any(
                |issue| issue.contains("no prior allocation") && issue.contains("unattributed")
            ));
            for a in s.explorer.children(handle(&s, 1), 0, 10).unwrap().entries {
                if a.basename.starts_with(b"alias") {
                    assert_eq!(a.accounted_bytes, 0);
                    assert_eq!(
                        a.allocated_bytes,
                        if a.basename == b"alias-a" {
                            first
                        } else {
                            last
                        }
                    );
                }
            }
            assert_consistent(&s);
        }
        // Both fresh values now equal already stored raw values at some alias.
        s.filesystem
            .insert("/scope/a/alias-b", meta(20, Kind::File, first));
        let r = s.refresh_directory(handle(&s, 1)).unwrap();
        assert!(r.issues.is_empty());
        assert_eq!(total(&s), 360 + first);
        assert_consistent(&s);
    }
}
#[test]
fn known_zero_allocation_is_not_an_unknown_conflict_baseline() {
    let mut s = session();
    s.filesystem
        .insert("/scope/z/zero", meta(20, Kind::File, 0));
    s.refresh_directory(handle(&s, 3)).unwrap();
    s.filesystem
        .insert("/scope/a/alias-a", meta(20, Kind::File, 100));
    s.filesystem
        .insert("/scope/a/alias-b", meta(20, Kind::File, 500));
    let r = s.refresh_directory(handle(&s, 1)).unwrap();
    assert_eq!(total(&s), 360);
    assert!(r.state.stale);
    assert!(
        r.issues
            .iter()
            .all(|issue| !issue.contains("no prior allocation"))
    );
    for a in s.explorer.children(handle(&s, 1), 0, 10).unwrap().entries {
        if a.basename.starts_with(b"alias") {
            assert_eq!(a.allocated_bytes, 0);
            assert_eq!(a.accounted_bytes, 0);
        }
    }
    assert_consistent(&s);
}

#[test]
fn unknown_group_recovers_from_unchanged_raw_observation_in_one_region() {
    let mut s = session();
    s.filesystem
        .insert("/scope/a/alias", meta(20, Kind::File, 100));
    s.filesystem
        .insert("/scope/z/alias", meta(20, Kind::File, 500));
    s.refresh_directory(s.explorer.root_handle()).unwrap();
    assert_eq!(total(&s), 360);
    assert!(
        s.unresolved_groups
            .contains(&meta(20, Kind::File, 0).identity)
    );
    s.filesystem
        .insert("/scope/z/alias", meta(20, Kind::File, 100));
    let r = s.refresh_directory(handle(&s, 1)).unwrap();
    println!(
        "unchanged raw recovery total={} work={:?}",
        total(&s),
        r.work
    );
    assert!(r.issues.is_empty());
    assert_eq!(total(&s), 460);
    assert!(s.unresolved_groups.is_empty());
    assert_consistent(&s);
}
#[test]
fn removing_all_unknown_aliases_prunes_uncertainty_without_reusing_a_baseline() {
    let mut s = session();
    for iteration in 0..2 {
        s.filesystem
            .insert("/scope/a/alias-a", meta(20, Kind::File, 100));
        s.filesystem
            .insert("/scope/a/alias-b", meta(20, Kind::File, 500));
        let r = s.refresh_directory(handle(&s, 1)).unwrap();
        assert_eq!(total(&s), 360);
        assert!(r.issues.iter().any(|i| i.contains("no prior allocation")));
        assert_eq!(s.unresolved_groups.len(), 1);
        s.filesystem.erase(Path::new("/scope/a/alias-a"));
        s.filesystem.erase(Path::new("/scope/a/alias-b"));
        let r = s.refresh_directory(handle(&s, 1)).unwrap();
        println!("unknown cleanup iteration={iteration} work={:?}", r.work);
        assert_eq!(total(&s), 360);
        assert!(s.unresolved_groups.is_empty());
        assert_consistent(&s);
    }
}
#[test]
fn conflicting_alias_baselines_keep_group_work_linear() {
    for count in [100, 1000] {
        let mut s = session();
        for i in 0..count {
            s.filesystem.insert(
                format!("/scope/a/alias-{i:04}"),
                meta(5, Kind::File, if i % 2 == 0 { 100 } else { 500 }),
            );
        }
        let r = s.refresh_directory(handle(&s, 1)).unwrap();
        println!(
            "conflicting_aliases={count} total={} work={:?}",
            total(&s),
            r.work
        );
        assert_eq!(total(&s), 360);
        assert!(r.state.stale);
        assert!(r.work.identity_members <= 5 * (count + 1));
        assert_eq!(s.baselines.capacity(), 0);
        assert_consistent(&s);
    }
}

fn inventory_rows<F: FileSystem>(s: &OperationSession<F>) -> Vec<(Vec<u8>, u64, u64)> {
    let mut rows = vec![];
    let mut pending = vec![0u32];
    while let Some(id) = pending.pop() {
        let n = &s.explorer.map.nodes[id as usize];
        rows.push((
            s.explorer.map.relative_path(id as usize),
            n.accounted,
            n.subtree,
        ));
        pending.extend_from_slice(s.explorer.child_ids(id));
    }
    rows.sort();
    rows
}
fn change_live_tree(fs: &mut MemoryFileSystem) {
    fs.insert("/scope/a/new", meta(20, Kind::File, 70));
    fs.insert("/scope/a/deeper", meta(21, Kind::Dir, 5));
    fs.insert("/scope/a/deeper/inner", meta(22, Kind::File, 33));
    fs.erase(Path::new("/scope/z/sibling"));
}
#[test]
fn controlled_refresh_applies_the_same_update_and_counts_directory_records() {
    let (mut plain, mut controlled) = (session(), session());
    change_live_tree(&mut plain.filesystem);
    change_live_tree(&mut controlled.filesystem);
    let expected = plain.refresh_directory(handle(&plain, 0)).unwrap();
    let control = ScanControl::default();
    let report = controlled
        .refresh_directory_controlled(handle(&controlled, 0), &control)
        .unwrap();
    assert_eq!(inventory_rows(&controlled), inventory_rows(&plain));
    assert_eq!(report.issues, expected.issues);
    assert_eq!(report.state, expected.state);
    let progress = control.progress();
    assert_eq!(progress.phase, ScanPhase::Committed);
    assert!(!progress.cancellable);
    // Four directory metadata requests (root, a, a/deeper, z) and six directory records
    // (a, z; file, new, deeper; inner).
    assert_eq!(progress.items_examined, 10);
    assert!(!control.cancel(), "Stop after the commit point is rejected");
    assert!(controlled.prefetched.is_none());
    assert_consistent(&controlled);
    // A reused control fails without starting a second refresh.
    assert!(
        controlled
            .refresh_directory_controlled(handle(&controlled, 0), &control)
            .is_err()
    );
    assert_eq!(control.progress().phase, ScanPhase::Committed);
}
#[test]
fn stopped_controlled_refresh_leaves_the_inventory_unchanged() {
    use std::sync::atomic::AtomicUsize;
    let counted = Arc::new(AtomicUsize::new(0));
    let control = ScanControl::default();
    let count = counted.clone();
    *control.hook.lock().unwrap() = Some(Box::new(move |_| {
        count.fetch_add(1, Ordering::Relaxed);
    }));
    let mut s = session();
    change_live_tree(&mut s.filesystem);
    s.refresh_directory_controlled(handle(&s, 0), &control)
        .unwrap();
    let checks = counted.load(Ordering::Relaxed);
    assert!(
        checks >= 8,
        "Stop is checked during the whole read, got {checks}"
    );
    // Stop at every check point: before the read, between directories, and at the commit.
    for stop_at in 1..=checks {
        let mut s = session();
        change_live_tree(&mut s.filesystem);
        let (before, state) = (inventory_rows(&s), s.state());
        let control = ScanControl::default();
        let seen = Arc::new(AtomicUsize::new(0));
        let hook_seen = seen.clone();
        *control.hook.lock().unwrap() = Some(Box::new(move |c| {
            if hook_seen.fetch_add(1, Ordering::Relaxed) + 1 == stop_at {
                c.cancel();
            }
        }));
        let error = s
            .refresh_directory_controlled(handle(&s, 0), &control)
            .unwrap_err();
        assert!(
            error
                .get_ref()
                .is_some_and(|e| e.is::<crate::scan_control::ScanCancelled>()),
            "stop at {stop_at}: {error}"
        );
        assert_eq!(control.progress().phase, ScanPhase::Cancelled);
        assert_eq!(inventory_rows(&s), before, "stop at {stop_at}");
        assert_eq!(s.state(), state);
        assert!(s.prefetched.is_none());
        // The session stays usable: a later refresh applies the change.
        s.refresh_directory(handle(&s, 0)).unwrap();
        assert_ne!(inventory_rows(&s), before);
        assert_consistent(&s);
    }
}

/// A directory `/scope/a/many` with `count` live files the saved scan does not have.
fn with_live_files(count: u64) -> OperationSession<MemoryFileSystem> {
    let mut s = session();
    s.filesystem.insert("/scope/a/many", meta(40, Kind::Dir, 0));
    for i in 0..count {
        s.filesystem.insert(
            format!("/scope/a/many/f-{i:06}"),
            meta(100_000 + i, Kind::File, 1),
        );
    }
    s
}
#[test]
fn trash_and_delete_checks_read_no_directory_and_do_not_grow_with_the_subtree() {
    let mut calls = Vec::new();
    for count in [10, 10_000] {
        for action in [Action::Trash, Action::PermanentlyDelete] {
            let mut s = with_live_files(count);
            s.filesystem.trash_behavior = TrashBehavior::MoveTo("/outside/moved".into());
            let c = s.prepare(handle(&s, 1), action).unwrap();
            let prepared = s.filesystem.calls;
            let r = s.execute(c).unwrap();
            assert!(
                matches!(r.mutation, Mutation::Removed | Mutation::Trashed { .. }),
                "{:?}",
                r.mutation
            );
            assert_eq!(total(&s), 240);
            // Root, target and protected locations only, at prepare and again at execute.
            assert_eq!(prepared.directories, 0, "{action:?} prepare lists nothing");
            assert_eq!(
                s.filesystem.calls.directories, 0,
                "{action:?} lists nothing"
            );
            assert_eq!(s.filesystem.calls.protection_checks, 2);
            calls.push((action, s.filesystem.calls.metadata));
        }
    }
    assert_eq!(
        calls[..2],
        calls[2..],
        "metadata requests do not depend on the subtree"
    );
}
#[test]
fn delete_is_one_walk_that_also_removes_entries_created_after_the_scan() {
    let mut s = with_live_files(100);
    let c = s.prepare(handle(&s, 1), Action::PermanentlyDelete).unwrap();
    assert_eq!(s.execute(c).unwrap().mutation, Mutation::Removed);
    assert!(
        s.filesystem
            .get(Path::new("/scope/a/many/f-000099"))
            .is_none()
    );
    assert!(s.filesystem.get(Path::new("/scope/a")).is_none());
    assert_eq!(s.filesystem.calls.remove, 1);
    assert_eq!(
        s.filesystem.calls.directories, 0,
        "the removal walk is the only walk"
    );
    assert_eq!(total(&s), 240);
    assert_consistent(&s);
}
#[test]
fn mount_snapshot_and_firmlink_inside_are_refused_before_any_removal() {
    for kind in ["mount", "firmlink", "device", "snapshot"] {
        let protected = || {
            let mut m = meta(60, Kind::Dir, 5);
            match kind {
                "mount" => m.mount = true,
                "firmlink" => m.flags = crate::native::SF_FIRMLINK,
                "device" => m.identity.device = 2,
                _ => m = meta(61, Kind::File, 5),
            }
            m
        };
        for action in [Action::Trash, Action::PermanentlyDelete] {
            // Present at preparation: refused from the target-level checks, nothing listed.
            let mut s = session();
            s.filesystem.trash_behavior = TrashBehavior::MoveTo("/outside/moved".into());
            s.filesystem.pin_snapshot(meta(61, Kind::File, 5).identity);
            s.filesystem.insert("/scope/a/deep", meta(62, Kind::Dir, 0));
            s.filesystem.insert("/scope/a/deep/x", protected());
            assert!(
                s.prepare(handle(&s, 1), action).is_err(),
                "{kind} {action:?}"
            );
            assert_eq!(s.filesystem.calls.directories, 0);
            // Appearing after preparation: execute checks again before anything changes.
            s.filesystem.erase(Path::new("/scope/a/deep/x"));
            let c = s.prepare(handle(&s, 1), action).unwrap();
            s.filesystem.insert("/scope/a/deep/x", protected());
            assert!(s.execute(c).is_err(), "{kind} {action:?}");
            let calls = s.filesystem.calls;
            assert_eq!((calls.directories, calls.remove, calls.trash), (0, 0, 0));
            assert!(s.filesystem.get(Path::new("/scope/a/file")).is_some());
            assert_eq!(total(&s), 360);
            assert!(!s.state().dirty);
        }
    }
}
#[test]
fn delete_skips_inaccessible_and_locked_entries_reports_them_and_keeps_their_folders() {
    let mut s = session();
    for (path, m) in [
        ("/scope/a/second", meta(70, Kind::File, 50)),
        ("/scope/a/locked", meta(71, Kind::File, 7)),
        ("/scope/a/closed", meta(72, Kind::Dir, 3)),
        ("/scope/a/closed/inner", meta(73, Kind::File, 9)),
    ] {
        s.filesystem.insert(path, m);
    }
    let dir = handle(&s, 1);
    s.refresh_directory(dir).unwrap();
    assert_eq!(total(&s), 429);
    s.filesystem.unreadable.insert("/scope/a/closed".into());
    s.filesystem.remove_skips.insert(
        "/scope/a/locked".into(),
        "not permitted, for example locked".into(),
    );
    let c = s.prepare(dir, Action::PermanentlyDelete).unwrap();
    let r = s.execute(c).unwrap();
    let Mutation::RemovedWithSkips(removal) = r.mutation else {
        panic!("{:?}", r.mutation)
    };
    assert_eq!((removal.removed, removal.skipped), (2, 2));
    assert_eq!(
        removal.reasons,
        [
            "/scope/a/closed: permission denied",
            "/scope/a/locked: not permitted, for example locked"
        ]
    );
    // The survivors are read again; only the unreadable folder keeps its saved contents.
    assert!(r.update.state.dirty && r.update.state.stale);
    assert_eq!(s.explorer.entry(dir).unwrap().child_count, 2);
    assert_eq!(total(&s), 429 - 150);
    assert!(
        s.filesystem
            .get(Path::new("/scope/a/closed/inner"))
            .is_some()
    );
    assert_consistent(&s);
}
#[test]
fn delete_errors_that_end_the_walk_report_exact_counts() {
    let mut s = with_live_files(10);
    s.filesystem.remove_failure_after = Some(4);
    let c = s.prepare(handle(&s, 1), Action::PermanentlyDelete).unwrap();
    let r = s.execute(c).unwrap();
    let Mutation::Partial {
        message,
        stopped,
        removal,
    } = r.mutation
    else {
        panic!("{:?}", r.mutation)
    };
    assert!(!stopped);
    assert_eq!(message, "injected unlink failure");
    assert_eq!((removal.removed, removal.skipped), (4, 0));
    assert!(r.update.state.stale);
    // `file` goes first, then three of the ten files.
    assert!(s.filesystem.get(Path::new("/scope/a/file")).is_none());
    let left = (0..10)
        .filter(|i| {
            s.filesystem
                .get(Path::new(&format!("/scope/a/many/f-{i:06}")))
                .is_some()
        })
        .count();
    assert_eq!(left, 7);
}
/// Cancels when the removal reached `at` entries; returns whether Stop was accepted.
fn stop_after(control: &ScanControl, at: u64) -> Arc<AtomicBool> {
    let accepted = Arc::new(AtomicBool::new(false));
    let seen = accepted.clone();
    *control.hook.lock().unwrap() = Some(Box::new(move |c| {
        let p = c.progress();
        if p.phase == ScanPhase::Removing && p.items_examined == at && c.cancel() {
            seen.store(true, Ordering::Relaxed);
        }
    }));
    accepted
}
#[test]
fn stop_during_controlled_delete_reports_partial_with_exact_counts() {
    let mut s = with_live_files(20);
    let dir = handle(&s, 1);
    s.refresh_directory(dir).unwrap();
    let control = ScanControl::default();
    let accepted = stop_after(&control, 7);
    let c = s.prepare(dir, Action::PermanentlyDelete).unwrap();
    let r = s.execute_controlled(c, &control).unwrap();
    assert!(accepted.load(Ordering::Relaxed));
    let Mutation::Partial {
        stopped, removal, ..
    } = r.mutation
    else {
        panic!("{:?}", r.mutation)
    };
    assert!(stopped);
    assert_eq!((removal.removed, removal.skipped), (7, 0));
    assert_eq!(control.progress().items_examined, 7);
    assert_eq!(control.progress().phase, ScanPhase::Committed);
    // `file` and six of the twenty files are gone; the inventory holds the other fourteen.
    let many = s
        .explorer
        .children(dir, 0, 10)
        .unwrap()
        .entries
        .into_iter()
        .find(|e| e.basename == b"many")
        .unwrap();
    assert_eq!(s.explorer.entry(many.handle).unwrap().child_count, 14);
    assert!(!r.update.state.stale);
    assert_consistent(&s);
}
#[test]
fn stop_before_the_first_unlink_cancels_with_nothing_changed_and_trash_cannot_stop() {
    // Stop during the execute checks.
    let mut s = with_live_files(5);
    let control = ScanControl::default();
    *control.hook.lock().unwrap() = Some(Box::new(|c| {
        if c.progress().phase == ScanPhase::Scanning {
            c.cancel();
        }
    }));
    let c = s.prepare(handle(&s, 1), Action::PermanentlyDelete).unwrap();
    let before = inventory_rows(&s);
    let error = s.execute_controlled(c, &control).unwrap_err();
    assert!(
        error
            .get_ref()
            .is_some_and(|e| e.is::<crate::scan_control::ScanCancelled>())
    );
    assert_eq!(control.progress().phase, ScanPhase::Cancelled);
    assert_eq!(s.filesystem.calls.remove, 0);
    assert_eq!(inventory_rows(&s), before);
    assert!(!s.state().dirty);
    assert_eq!(s.filesystem.pinned_count(), 0);
    // Stop as the removal begins.
    let control = ScanControl::default();
    let accepted = stop_after(&control, 0);
    let c = s.prepare(handle(&s, 1), Action::PermanentlyDelete).unwrap();
    assert!(s.execute_controlled(c, &control).is_err());
    assert!(accepted.load(Ordering::Relaxed));
    assert!(
        s.filesystem
            .get(Path::new("/scope/a/many/f-000000"))
            .is_some()
    );
    assert_eq!(inventory_rows(&s), before);
    // Trash commits before its checks: Stop is rejected while it moves.
    let gate = Arc::new(super::memory::StageGate::default());
    s.filesystem.stages.gate = Some(gate.clone());
    s.filesystem.trash_behavior = TrashBehavior::MoveTo("/outside/moved".into());
    let control = Arc::new(ScanControl::default());
    let worker = {
        let control = control.clone();
        std::thread::spawn(move || {
            let c = s.prepare(handle(&s, 1), Action::Trash).unwrap();
            let r = s.execute_controlled(c, &control).unwrap();
            (s, r)
        })
    };
    let wait = || gate.wait_for_held(std::time::Duration::from_secs(10));
    use super::memory::Stage;
    for stage in [Stage::Check, Stage::Check, Stage::Trash, Stage::Update] {
        assert_eq!(wait(), Some(stage));
        let progress = control.progress();
        if stage != Stage::Check || progress.phase == ScanPhase::Committing {
            assert!(!progress.cancellable && !control.cancel(), "{stage:?}");
        }
        gate.release();
    }
    let (s, r) = worker.join().unwrap();
    assert!(matches!(r.mutation, Mutation::Trashed { .. }));
    assert_eq!(control.progress().phase, ScanPhase::Committed);
    assert_eq!(total(&s), 240);
}

/// An owned native tree `root/dir` with `files` files and `dir/sub` with eight more.
fn native_tree(files: usize) -> (Fixture, OperationSession<native::NativeFileSystem>) {
    let fixture = Fixture::new();
    let dir = fixture.0.join("root/dir");
    std::fs::create_dir_all(dir.join("sub")).unwrap();
    for i in 0..files {
        std::fs::write(dir.join(format!("file-{i:05}")), b"owned").unwrap();
    }
    for i in 0..8 {
        std::fs::write(dir.join(format!("sub/inner-{i}")), b"owned").unwrap();
    }
    let map = fixture.0.join("map");
    crate::inventory::Inventory::create(&fixture.0.join("root"), &map, Default::default()).unwrap();
    let s = native::NativeFileSystem::open_snapshot(&map).unwrap();
    (fixture, s)
}
fn first_child<F: FileSystem>(s: &OperationSession<F>) -> EntryHandle {
    s.explorer
        .children(s.explorer.root_handle(), 0, 1)
        .unwrap()
        .entries[0]
        .handle
}
#[test]
fn native_delete_is_one_walk_and_its_checks_read_no_directory() {
    let mut metadata = Vec::new();
    for files in [16, 512] {
        let (fixture, mut s) = native_tree(files);
        let dir = first_child(&s);
        let c = s.prepare(dir, Action::Trash).unwrap();
        drop(c); // Native Trash is never executed in tests.
        let c = s.prepare(dir, Action::PermanentlyDelete).unwrap();
        assert_eq!(s.execute(c).unwrap().mutation, Mutation::Removed);
        assert!(!fixture.0.join("root/dir").exists());
        // The checks list no directory; the removal walk lists each entry exactly once.
        assert_eq!(s.filesystem.enumeration_work.records, 0);
        assert_eq!(s.filesystem.removal_records, files + 1 + 8);
        metadata.push(s.filesystem.metadata_requests);
        assert_consistent(&s);
    }
    println!("native metadata requests for 16 and 512 files: {metadata:?}");
    assert_eq!(
        metadata[0], metadata[1],
        "checks do not grow with the subtree"
    );
}
#[test]
fn native_snapshot_inside_the_target_is_refused_and_an_extra_link_is_not() {
    use std::fs;
    let fixture = Fixture::new();
    let dir = fixture.0.join("root/dir");
    fs::create_dir_all(dir.join("deep")).unwrap();
    fs::write(dir.join("deep/file"), b"owned").unwrap();
    // The snapshot's own path is inside the target.
    let map = dir.join("deep/map");
    crate::inventory::Inventory::create(&fixture.0.join("root"), &map, Default::default()).unwrap();
    let mut s = native::NativeFileSystem::open_snapshot(&map).unwrap();
    let target = first_child(&s);
    for action in [Action::Trash, Action::PermanentlyDelete] {
        let error = s.prepare(target, action).unwrap_err();
        assert!(error.to_string().contains("active snapshot"), "{error}");
    }
    assert_eq!(s.filesystem.enumeration_work.records, 0);
    assert!(map.exists() && dir.join("deep/file").exists());
    drop(s);
    // The snapshot lives outside; an extra hard link inside, made after opening, is the most
    // recently looked-up name, so the descriptor may report it.
    let outside = fixture.0.join("map");
    fs::rename(&map, &outside).unwrap();
    let mut s = native::NativeFileSystem::open_snapshot(&outside).unwrap();
    let alias = dir.join("deep/map-alias");
    let file = fs::File::open(&outside).unwrap();
    fs::hard_link(&outside, &alias).unwrap();
    fs::metadata(&alias).unwrap();
    let mut named = vec![0u8; libc::PATH_MAX as usize];
    // SAFETY: F_GETPATH writes at most MAXPATHLEN bytes, NUL-terminated.
    unsafe {
        libc::fcntl(
            std::os::fd::AsRawFd::as_raw_fd(&file),
            libc::F_GETPATH,
            named.as_mut_ptr(),
        )
    };
    named.truncate(named.iter().position(|&b| b == 0).unwrap());
    println!("descriptor path: {}", String::from_utf8_lossy(&named));
    let target = first_child(&s);
    drop(s.prepare(target, Action::Trash).unwrap());
    let c = s.prepare(target, Action::PermanentlyDelete).unwrap();
    let Mutation::RemovedWithSkips(removal) = s.execute(c).unwrap().mutation else {
        panic!("the extra link is skipped")
    };
    assert_eq!((removal.removed, removal.skipped), (1, 1));
    assert_eq!(
        removal.reasons,
        [format!(
            "{}: protected: scan root, active snapshot or another volume",
            alias.display()
        )]
    );
    assert!(alias.exists() && outside.exists() && !dir.join("deep/file").exists());
}
/// Restores the permissions and flags a test changed, so the fixture can be deleted.
struct Restore(Vec<(PathBuf, u32)>);
impl Drop for Restore {
    fn drop(&mut self) {
        use std::os::unix::fs::PermissionsExt;
        for (path, mode) in &self.0 {
            let c = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
            // SAFETY: valid NUL-terminated path; clears the owner's immutable flag.
            unsafe { libc::chflags(c.as_ptr(), 0) };
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(*mode)).unwrap();
        }
    }
}
#[test]
fn native_delete_skips_locked_and_unwritable_entries_and_keeps_their_folders() {
    use std::{fs, os::unix::fs::PermissionsExt};
    let fixture = Fixture::new();
    let dir = fixture.0.join("root/dir");
    fs::create_dir_all(dir.join("closed")).unwrap();
    fs::create_dir_all(dir.join("open/deeper")).unwrap();
    for file in ["plain", "locked", "closed/kept", "open/deeper/gone"] {
        fs::write(dir.join(file), b"owned").unwrap();
    }
    let map = fixture.0.join("map");
    crate::inventory::Inventory::create(&fixture.0.join("root"), &map, Default::default()).unwrap();
    let mut s = native::NativeFileSystem::open_snapshot(&map).unwrap();
    let target = first_child(&s);
    let _restore = Restore(vec![
        (dir.join("locked"), 0o644),
        (dir.join("closed"), 0o755),
    ]);
    let locked = std::ffi::CString::new(dir.join("locked").as_os_str().as_bytes()).unwrap();
    // SAFETY: valid NUL-terminated path of an owned file; the owner may set this flag.
    assert_eq!(
        unsafe { libc::chflags(locked.as_ptr(), libc::UF_IMMUTABLE) },
        0
    );
    fs::set_permissions(dir.join("closed"), fs::Permissions::from_mode(0o555)).unwrap();
    // Created after the scan: deleted like the rest.
    fs::write(dir.join("open/late"), b"owned").unwrap();
    let c = s.prepare(target, Action::PermanentlyDelete).unwrap();
    let r = s.execute(c).unwrap();
    let Mutation::RemovedWithSkips(removal) = r.mutation else {
        panic!("{:?}", r.mutation)
    };
    // plain, open/late, open/deeper/gone, open/deeper and open.
    assert_eq!((removal.removed, removal.skipped), (5, 2));
    let mut reasons = removal.reasons.clone();
    reasons.sort();
    assert_eq!(
        reasons,
        [
            format!("{}: permission denied", dir.join("closed/kept").display()),
            format!(
                "{}: not permitted, for example locked",
                dir.join("locked").display()
            ),
        ]
    );
    assert!(dir.join("locked").exists() && dir.join("closed/kept").exists());
    assert!(!dir.join("plain").exists() && !dir.join("open").exists());
    let kept: Vec<_> = s
        .explorer
        .children(target, 0, 10)
        .unwrap()
        .entries
        .into_iter()
        .map(|e| e.basename)
        .collect();
    assert_eq!(kept, [b"closed".to_vec(), b"locked".to_vec()]);
    assert_consistent(&s);
}
#[test]
fn native_stop_mid_delete_reports_partial_with_exact_counts() {
    let (fixture, mut s) = native_tree(40);
    let dir = first_child(&s);
    let control = ScanControl::default();
    let accepted = stop_after(&control, 12);
    let c = s.prepare(dir, Action::PermanentlyDelete).unwrap();
    let r = s.execute_controlled(c, &control).unwrap();
    assert!(accepted.load(Ordering::Relaxed));
    let Mutation::Partial {
        stopped, removal, ..
    } = r.mutation
    else {
        panic!("{:?}", r.mutation)
    };
    assert!(stopped);
    assert_eq!((removal.removed, removal.skipped), (12, 0));
    let left = |path: &Path| std::fs::read_dir(path).unwrap().count();
    let root = fixture.0.join("root/dir");
    assert_eq!(left(&root) + left(&root.join("sub")), 40 + 1 + 8 - 12);
    assert!(!r.update.state.stale);
    assert_eq!(s.explorer.entry(dir).unwrap().child_count, left(&root));
    assert_consistent(&s);
}
