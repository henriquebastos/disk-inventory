use super::*;
use crate::operations::{Identity, memory::MemoryCalls};

fn session(s: &str) -> Arc<ExplorerSession> {
    ExplorerSession::fixture(s.into()).unwrap()
}
fn find(s: &ExplorerSession, name: &[u8]) -> Arc<EntryKey> {
    let root = s.status().unwrap().root.key;
    s.children(root, 0, 1024)
        .unwrap()
        .entries
        .into_iter()
        .find(|e| e.basename == name)
        .unwrap()
        .key
}
fn request() -> LayoutRequest {
    LayoutRequest {
        viewport: Rectangle {
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
fn memory<T>(s: &ExplorerSession, f: impl FnOnce(&mut MemoryFileSystem) -> T) -> T {
    let mut b = s.backend.lock().unwrap();
    let Backend::Memory(m) = &mut *b else {
        panic!("expected simulated backend")
    };
    f(m.filesystem_mut())
}
#[test]
fn saved_views_are_bounded_native_free_and_byte_exact() {
    let s = session("ordinary");
    let status = s.status().unwrap();
    assert!(status.simulated);
    assert!(!status.dirty && !status.stale && !status.scan_partial);
    let p = s.children(status.root.key.clone(), 0, 2).unwrap();
    assert_eq!(p.entries.len(), 2);
    assert_eq!(p.next_offset, Some(2));
    assert_eq!(p.entries_examined, 2);
    assert!(s.children(status.root.key.clone(), 0, 1025).is_err());
    let raw = s.selection(find(&s, b"raw-\xff")).unwrap();
    assert_eq!(raw.relative_path, b"raw-\xff");
    assert_eq!(raw.entry.basename, b"raw-\xff");
    assert!(raw.entry.display_name.contains('\u{fffd}'));
    assert!(
        raw.entry
            .parent
            .unwrap()
            .same_entry(status.root.key.clone())
    );
    assert_eq!(
        s.selection(find(&s, b"large-file"))
            .unwrap()
            .entry
            .allocated_bytes,
        (1u64 << 53) + 123
    );
    assert_eq!(
        s.selection(find(&s, b"zero-byte"))
            .unwrap()
            .entry
            .subtree_bytes,
        0
    );
    assert_eq!(
        s.selection(find(&s, b"hardlink-b"))
            .unwrap()
            .entry
            .accounted_bytes,
        0
    );
    let l = s.layout(status.root.key.clone(), request()).unwrap();
    assert!(l.focus.same_entry(status.root.key));
    assert!(l.tiles.len() + l.groups.len() <= 64);
    assert_eq!(
        l.tiles.iter().map(|t| t.bytes).sum::<u64>(),
        status.root.subtree_bytes
    );
    assert!(l.child_ids_examined <= 128);
    assert_eq!(memory(&s, |f| f.calls), MemoryCalls::default());
    let m = s.live_metadata(find(&s, b"large-file")).unwrap();
    assert_eq!(m.logical_bytes, (1u64 << 53) + 140);
    assert!(memory(&s, |f| f.calls.metadata) > 0);
    assert!(!s.status().unwrap().dirty);
}
#[test]
fn confirmation_pins_cancel_drop_replay_and_cross_session_are_real() {
    let s = session("ordinary");
    let other = session("ordinary");
    let key = find(&s, b"large-file");
    assert!(matches!(
        other.selection(key.clone()),
        Err(BridgeError::InvalidEntry { .. })
    ));
    let a = s
        .prepare(key.clone(), ActionKind::PermanentlyDelete)
        .unwrap();
    assert_eq!(a.details().raw_path, b"/Workspace/large-file");
    assert_eq!(memory(&s, |f| f.pinned_count()), 1);
    assert!(matches!(
        other.execute(a.clone()),
        Err(BridgeError::WrongSession)
    ));
    assert_eq!(memory(&s, |f| f.pinned_count()), 1);
    a.cancel().unwrap();
    assert_eq!(memory(&s, |f| f.pinned_count()), 0);
    assert!(matches!(s.execute(a), Err(BridgeError::ConsumedAction)));
    drop(s.prepare(key.clone(), ActionKind::Trash).unwrap());
    assert_eq!(memory(&s, |f| f.pinned_count()), 0);
    let a = s
        .prepare(key.clone(), ActionKind::PermanentlyDelete)
        .unwrap();
    assert!(matches!(
        s.execute(a.clone()).unwrap().mutation,
        MutationOutcome::Removed
    ));
    assert!(matches!(s.execute(a), Err(BridgeError::ConsumedAction)));
    assert!(matches!(
        s.selection(key),
        Err(BridgeError::InvalidEntry { .. })
    ));
    assert_eq!(memory(&s, |f| f.pinned_count()), 0);
}
#[test]
fn changed_after_prepare_consumes_action_without_mutating_replacement() {
    let s = session("ordinary");
    let key = find(&s, b"large-file");
    let a = s.prepare(key, ActionKind::PermanentlyDelete).unwrap();
    let root = s.status().unwrap().root.key;
    let old_tree = s.clone().tree(root.clone()).unwrap();
    let old_frame = s
        .clone()
        .diagram(root.clone(), 64, 32, MapAppearance::Dark)
        .unwrap();
    memory(&s, |f| {
        f.insert(
            "/Workspace/large-file",
            fixture::metadata(1000, crate::Kind::File, 7),
        )
    });
    assert!(s.execute(a.clone()).is_err());
    assert!(matches!(s.execute(a), Err(BridgeError::ConsumedAction)));
    assert_eq!(memory(&s, |f| f.calls.remove), 0);
    assert_eq!(memory(&s, |f| f.pinned_count()), 0);
    assert!(old_tree.rows(0, 1).is_err());
    assert!(old_frame.hit(0, 0).is_err());
    assert!(s.clone().tree(root.clone()).unwrap().rows(0, 1).is_ok());
    assert!(
        s.diagram(root, 64, 32, MapAppearance::Dark)
            .unwrap()
            .hit(0, 0)
            .is_ok()
    );
}
#[test]
fn fixture_trash_scopes_failures_and_partial_updates_survive_conversion() {
    for scenario in [
        "trash-inside",
        "trash-outside",
        "trash-unknown",
        "trash-missing",
        "trash-failure",
    ] {
        let s = session(scenario);
        let before = s.status().unwrap().root.subtree_bytes;
        let a = s
            .prepare(find(&s, b"large-file"), ActionKind::Trash)
            .unwrap();
        let r = s.execute(a).unwrap();
        match scenario {
            "trash-inside" => {
                assert!(matches!(r.scope, Some(TrashScope::Inside { .. })));
                assert_eq!(s.status().unwrap().root.subtree_bytes, before);
            }
            "trash-outside" => {
                assert!(matches!(r.scope, Some(TrashScope::Outside)));
                assert_eq!(
                    s.status().unwrap().root.subtree_bytes,
                    before - ((1u64 << 53) + 123)
                );
            }
            "trash-unknown" => {
                assert!(matches!(r.scope, Some(TrashScope::Unknown)));
                assert!(r.update.stale);
                assert!(!r.update.issues.is_empty());
            }
            "trash-missing" => {
                assert!(matches!(r.mutation, MutationOutcome::Indeterminate { .. }));
                assert!(r.update.stale);
            }
            "trash-failure" => {
                assert!(matches!(r.mutation, MutationOutcome::Failed { .. }));
                assert_eq!(s.status().unwrap().root.subtree_bytes, before);
            }
            _ => unreachable!(),
        }
        assert_eq!(memory(&s, |f| f.calls.remove), 0);
    }
    let s = session("partial-deletion");
    let a = s
        .prepare(find(&s, b"small-files"), ActionKind::PermanentlyDelete)
        .unwrap();
    let r = s.execute(a).unwrap();
    assert!(matches!(r.mutation, MutationOutcome::Partial { .. }));
    assert!(r.update.dirty && r.update.stale);
    assert!(!r.update.issues.is_empty());
}
#[test]
fn fixture_errors_fail_closed_and_unknown_allocation_stays_explicit() {
    assert!(ExplorerSession::fixture("unknown-native-fallback".into()).is_err());
    let s = session("metadata-failure");
    let key = find(&s, b"large-file");
    assert!(s.selection(key.clone()).is_ok());
    assert!(matches!(
        s.live_metadata(key),
        Err(BridgeError::PermissionDenied { .. })
    ));
    let s = session("changed-target");
    assert!(
        s.prepare(find(&s, b"large-file"), ActionKind::Trash)
            .is_err()
    );
    let s = session("permission-failure");
    let r = s.refresh_directory(find(&s, b"small-files")).unwrap();
    assert!(r.stale && !r.issues.is_empty());
    let a = s
        .prepare(find(&s, b"large-file"), ActionKind::PermanentlyDelete)
        .unwrap();
    assert!(matches!(
        s.execute(a).unwrap().mutation,
        MutationOutcome::Failed { .. }
    ));
    let s = session("unknown-allocation");
    let root = s.status().unwrap().root.key;
    let r = s.refresh_directory(root.clone()).unwrap();
    assert!(r.stale && r.issues.iter().any(|i| i.contains("no prior allocation")));
    let a = s.selection(find(&s, b"unknown-a")).unwrap().entry;
    assert_eq!((a.allocated_bytes, a.accounted_bytes), (100, 0));
    assert!(s.status().unwrap().stale);
    assert!(s.refresh_directory(root).unwrap().stale);
    memory(&s, |f| {
        assert_eq!(
            f.get(std::path::Path::new("/Workspace/unknown-a"))
                .unwrap()
                .identity,
            Identity {
                device: 1,
                inode: 100
            }
        )
    });
}
#[test]
fn busy_poll_does_not_take_the_session_lock() {
    let s = session("ordinary");
    let guard = s.backend.lock().unwrap();
    let worker = s.clone();
    let t = std::thread::spawn(move || worker.status().unwrap());
    let start = std::time::Instant::now();
    while !s.is_busy() {
        assert!(start.elapsed().as_secs() < 5);
        std::thread::yield_now();
    }
    assert!(s.is_busy());
    drop(guard);
    t.join().unwrap();
    assert!(!s.is_busy());
}
#[test]
fn native_snapshot_open_never_requires_the_recorded_source() {
    let root = std::env::var_os("BRIDGE_TEST_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let dir = root.join(format!("snapshot-test-{}", std::process::id()));
    std::fs::create_dir(&dir).unwrap();
    let snapshot = dir.join("saved.dmap");
    let mut map = fixture::map().unwrap();
    map.root = dir.join("unavailable-source");
    map.counters.errors = 2;
    crate::snapshot::save_new(&map, &snapshot).unwrap();
    let s = ExplorerSession::open_snapshot(snapshot.as_os_str().as_bytes().to_vec()).unwrap();
    let status = s.status().unwrap();
    assert!(!status.simulated && status.scan_partial);
    assert_eq!(status.counters.errors, 2);
    assert!(s.selection(find(&s, b"raw-\xff")).is_ok());
    assert!(s.layout(status.root.key, request()).is_ok());
    assert!(matches!(
        s.live_metadata(find(&s, b"large-file")),
        Err(BridgeError::NotFound { .. })
    ));
    drop(s);
    std::fs::remove_dir_all(dir).unwrap();
}
#[test]
fn update_issue_transfer_has_an_explicit_bound() {
    let r = UpdateRecord::from(crate::operations::UpdateReport {
        state: Default::default(),
        work: Default::default(),
        issues: (0..70).map(|i| i.to_string()).collect(),
    });
    assert_eq!(r.issues.len(), 64);
    assert_eq!(r.issues_omitted, 6);
}

#[test]
fn concurrent_execution_consumes_one_confirmation_exactly_once() {
    let s = session("ordinary");
    let action = s
        .prepare(find(&s, b"large-file"), ActionKind::PermanentlyDelete)
        .unwrap();
    let barrier = Arc::new(std::sync::Barrier::new(3));
    let threads: Vec<_> = (0..2)
        .map(|_| {
            let s = s.clone();
            let action = action.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                s.execute(action)
            })
        })
        .collect();
    barrier.wait();
    let results: Vec<_> = threads.into_iter().map(|t| t.join().unwrap()).collect();
    assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
    assert_eq!(
        results
            .iter()
            .filter(|r| matches!(r, Err(BridgeError::ConsumedAction)))
            .count(),
        1
    );
    assert_eq!(memory(&s, |f| f.calls.remove), 1);
    assert_eq!(memory(&s, |f| f.pinned_count()), 0);
    assert!(!s.is_busy());
}

#[test]
fn invalid_bridge_requests_return_typed_errors_without_source_calls() {
    assert!(matches!(
        ExplorerSession::open_snapshot(vec![0]),
        Err(BridgeError::InvalidInput { .. })
    ));
    let s = session("ordinary");
    let root = s.status().unwrap().root.key;
    let mut options = request();
    options.max_rectangles = 4097;
    assert!(matches!(
        s.layout(root.clone(), options),
        Err(BridgeError::InvalidInput { .. })
    ));
    let mut options = request();
    options.viewport.width = f64::NAN;
    assert!(matches!(
        s.layout(root.clone(), options),
        Err(BridgeError::InvalidInput { .. })
    ));
    assert!(matches!(
        s.children(root, 0, 0),
        Err(BridgeError::InvalidInput { .. })
    ));
    assert_eq!(memory(&s, |f| f.calls), MemoryCalls::default());
    assert!(!s.is_busy());
}

#[test]
fn presentation_and_delay_fixtures_are_isolated() {
    let ordinary = session("ordinary");
    let presentation = session("presentation");
    let delayed = session("metadata-delay");
    assert!(memory(&ordinary, |f| f.metadata_delays.is_empty()));
    assert!(memory(&presentation, |f| f.metadata_delays.is_empty()));
    assert_eq!(memory(&delayed, |f| f.metadata_delays.len()), 1);
    assert_eq!(
        memory(&delayed, |f| f.metadata_delays
            [std::path::Path::new("/Workspace/large-file")]),
        std::time::Duration::from_secs(1)
    );
    for s in [&presentation, &delayed] {
        assert_eq!(s.selection_query_count(), 0);
        assert!(s.status().unwrap().simulated);
        assert_eq!(
            s.selection(find(s, b"large-file"))
                .unwrap()
                .entry
                .allocated_bytes,
            4096
        );
        let children = s.children(find(s, b"small-files"), 0, 100).unwrap();
        assert_eq!(children.total, 128);
        assert_eq!(children.entries.len(), 100);
        assert_eq!(children.next_offset, Some(100));
        assert_eq!(
            s.children(find(s, b"small-files"), 100, 100)
                .unwrap()
                .entries
                .len(),
            28
        );
        assert_eq!(s.selection_query_count(), 1);
        assert_eq!(s.active_call_count(), 0);
    }
    assert_eq!(
        ordinary
            .children(find(&ordinary, b"small-files"), 0, 100)
            .unwrap()
            .total,
        16
    );
    assert_eq!(
        ordinary
            .selection(find(&ordinary, b"large-file"))
            .unwrap()
            .entry
            .allocated_bytes,
        (1u64 << 53) + 123
    );
}

#[test]
fn visual_details_fixture_has_nested_groups_and_long_directory_confirmation() {
    let s = session("visual-details");
    let status = s.status().unwrap();
    assert!(status.simulated);
    let collection = find(&s, b"collection");
    let nested = s
        .children(collection, 0, 100)
        .unwrap()
        .entries
        .into_iter()
        .find(|e| e.basename == b"nested-group")
        .unwrap()
        .key;
    let layout = s.layout(status.root.key.clone(), request()).unwrap();
    assert!(
        layout
            .groups
            .iter()
            .any(|g| g.directory.same_entry(nested.clone()))
    );
    assert_eq!(memory(&s, |f| f.calls), MemoryCalls::default());
    let mut key = find(&s, b"long-path");
    for _ in 0..4 {
        let page = s.children(key, 0, 100).unwrap();
        assert_eq!(page.entries.len(), 1);
        key = page.entries[0].key.clone();
    }
    let saved = s.selection(key.clone()).unwrap();
    assert_eq!(saved.entry.basename, b"target-directory");
    assert!(saved.relative_path.len() > 590);
    assert_eq!(saved.entry.subtree_bytes, 6164);
    for kind in [ActionKind::Trash, ActionKind::PermanentlyDelete] {
        let prepared = s.prepare(key.clone(), kind).unwrap();
        let details = prepared.details();
        assert!(matches!(details.metadata.kind, EntryKind::Directory));
        assert_eq!(details.metadata.allocated_bytes, 20);
        assert_eq!(details.metadata.logical_bytes, 37);
        assert!(details.raw_path.len() > 600);
        assert_eq!(memory(&s, |f| f.pinned_count()), 1);
        prepared.cancel().unwrap();
        assert_eq!(memory(&s, |f| f.pinned_count()), 0);
    }
    assert!(!s.status().unwrap().dirty);
}

#[test]
fn diagram_and_virtual_tree_are_native_free_bounded_and_revision_guarded() {
    let s = session("dix-wide");
    let root = s.status().unwrap().root.key;
    let tree = s.clone().tree(root.clone()).unwrap();
    let initial = tree.rows(0, 32).unwrap();
    let projects = initial
        .rows
        .iter()
        .find(|r| r.entry.display_name == "Projects")
        .unwrap()
        .entry
        .key
        .clone();
    tree.expand(projects.clone(), true).unwrap();
    let tail = tree.rows(99_990, 16).unwrap();
    assert!(tail.total > 100_000 && tail.rows.len() <= 16 && tail.visits <= 32);
    assert!(tail.expansion_payload_bytes < 4096 && tail.expanded_directories == 1);
    let tail_key = tail.rows[0].entry.key.clone();
    assert_eq!(tree.visible_row(tail_key.clone()).unwrap(), Some(99_990));
    tree.expand(projects.clone(), false).unwrap();
    assert_eq!(tree.visible_row(tail_key).unwrap(), None);
    assert!(
        tree.visible_row(session("dix").status().unwrap().root.key)
            .is_err()
    );
    tree.expand(projects.clone(), true).unwrap();
    let frame = s
        .clone()
        .diagram(root, 640, 400, MapAppearance::Dark)
        .unwrap();
    let image = frame.bitmap();
    assert!(
        image.tiles > 160,
        "tiles={} groups={} visits={}",
        image.tiles,
        image.groups,
        image.child_visits
    );
    assert_eq!(image.rgba.len(), 640 * 400 * 4);
    // Large sibling prefixes inside nonzero nested origins used to accumulate
    // endpoint drift and reject the whole squarified subdivision (only five tiles).
    for (width, height) in [(640, 400), (400, 640), (713, 421), (1426, 842)] {
        let image = s
            .clone()
            .diagram(
                s.status().unwrap().root.key,
                width,
                height,
                MapAppearance::Dark,
            )
            .unwrap()
            .bitmap();
        assert!(image.tiles > 160, "{width}x{height}: {} tiles", image.tiles);
        let budget = (width as u64 * height as u64).min(crate::diagram::MAX_REGIONS as u64);
        assert!(image.tiles + image.groups <= budget);
        assert!(image.child_visits <= 2 * budget);
        assert_eq!(image.surface_payload_bytes, 0);
        assert!(
            image.rgba.chunks_exact(4).all(|pixel| pixel[3] == 255),
            "pixel-center gap"
        );
        // Raster construction also asserts disjoint pixel ownership.
    }
    for x in [0, 100, 300, 639] {
        let _ = frame.hit(x, 100).unwrap();
    }
    assert_eq!(memory(&s, |f| f.calls), MemoryCalls::default());
    let target = find(&s, b"Movie.mov");
    let action = s
        .prepare(target.clone(), ActionKind::PermanentlyDelete)
        .unwrap();
    s.execute(action).unwrap();
    assert!(frame.hit(0, 0).is_err());
    assert!(frame.region(target).is_err());
    assert!(tree.rows(0, 16).is_err());
    assert!(tree.visible_row(projects.clone()).is_err());
    assert!(tree.reveal(projects).is_err());
}

#[test]
fn outline_swatch_colors_match_map_file_tiles_and_directories_have_none() {
    let s = session("dix");
    let root = s.status().unwrap().root.key;
    let tree = s.clone().tree(root.clone()).unwrap();
    let tiny = find(&s, b"Tiny files");
    tree.expand(tiny.clone(), true).unwrap();
    let notes = s
        .children(tiny, 0, 16)
        .unwrap()
        .entries
        .into_iter()
        .find(|e| e.basename == b"Notes")
        .unwrap()
        .key;
    tree.expand(notes.clone(), true).unwrap();
    let rows = tree.rows(0, 32).unwrap().rows;
    let swatch = |name: &str| {
        rows.iter()
            .find(|r| r.entry.display_name == name)
            .unwrap()
            .map_rgb
    };
    for name in ["Projects", "Tiny files", "Notes"] {
        assert_eq!(swatch(name), None, "{name}");
    }
    for (name, rgb) in [
        ("Movie.mov", 0x4f8ac6),
        ("eight-KiB.png", 0x519962),
        ("four-KiB.txt", 0x7f8793),
        ("empty.txt", 0x7f8793),
    ] {
        assert_eq!(swatch(name), Some(rgb), "{name}");
    }
    // The base color lies inside the rendered gradient of the same file tile.
    let frame = s
        .clone()
        .diagram(notes, 200, 100, MapAppearance::Dark)
        .unwrap();
    let image = frame.bitmap();
    for name in ["eight-KiB.png", "four-KiB.txt"] {
        let base = swatch(name).unwrap().to_be_bytes();
        let (mut low, mut high) = ([255u8; 3], [0u8; 3]);
        let mut owned = 0;
        for y in 1..image.height {
            for x in 1..image.width {
                let Some(hit) = frame.hit(x, y).unwrap() else {
                    continue;
                };
                // Skip the backing-pixel inset border at each tile's top and left edge.
                if hit.entry.display_name != name
                    || x as f64 <= hit.rect.x + 1.0
                    || y as f64 <= hit.rect.y + 1.0
                {
                    continue;
                }
                owned += 1;
                let at = (y * image.width + x) as usize * 4;
                for c in 0..3 {
                    low[c] = low[c].min(image.rgba[at + c]);
                    high[c] = high[c].max(image.rgba[at + c]);
                }
            }
        }
        assert!(owned > 100, "{name} owns {owned} pixels");
        assert!(
            (0..3).all(|c| low[c] <= base[c + 1] && base[c + 1] <= high[c]),
            "{name}: {low:?} <= {base:?} <= {high:?}"
        );
    }
}

#[test]
fn presentation_trash_inside_moves_a_visible_tile_to_a_visible_destination() {
    let s = session("presentation-trash-inside");
    let target = find(&s, b"large-file");
    let frame = |s: &Arc<ExplorerSession>| {
        s.clone()
            .diagram(s.status().unwrap().root.key, 640, 400, MapAppearance::Dark)
            .unwrap()
    };
    let before = frame(&s).region(target.clone()).unwrap().unwrap();
    assert!(before.width >= 8. && before.height >= 8.);
    let action = s.prepare(target.clone(), ActionKind::Trash).unwrap();
    let report = s.execute(action).unwrap();
    assert!(matches!(
        report.mutation,
        MutationOutcome::Trashed { destination } if destination == b"/Workspace/trash/moved"
    ));
    assert!(matches!(
        report.scope,
        Some(TrashScope::Inside { relative_path }) if relative_path == b"trash/moved"
    ));
    // The moved entry keeps its saved key, so the new frame can locate the destination tile.
    assert_eq!(
        s.selection(target.clone()).unwrap().relative_path,
        b"trash/moved"
    );
    let after = frame(&s);
    let rect = after.region(target).unwrap().unwrap();
    assert!(rect.width >= 8. && rect.height >= 8.);
    let dx = rect.x + rect.width / 2. - before.x - before.width / 2.;
    let dy = rect.y + rect.height / 2. - before.y - before.height / 2.;
    assert!(dx.hypot(dy) > 80., "travel endpoints must visibly differ");
    let hit = after
        .hit(
            (rect.x + rect.width / 2.) as u32,
            (rect.y + rect.height / 2.) as u32,
        )
        .unwrap()
        .unwrap();
    assert!(hit.actionable && hit.relative_path == b"trash/moved");
    // The original over-2^53 Trash scenario keeps its single aggregate map.
    let original = session("trash-inside");
    let large = find(&original, b"large-file");
    assert!(frame(&original).region(large).unwrap().is_none());
}

#[test]
fn presentation_trash_late_target_has_a_region_outside_accessibility_targets() {
    let s = session("presentation-trash-late-target");
    let key = find(&s, b"large-file");
    let action = s.prepare(key.clone(), ActionKind::Trash).unwrap();
    s.execute(action).unwrap();
    let frame = s
        .clone()
        .diagram(s.status().unwrap().root.key, 650, 520, MapAppearance::Dark)
        .unwrap();
    assert!(frame.region(key.clone()).unwrap().is_some());
    assert_eq!(s.selection(key).unwrap().relative_path, b"trash/moved");
    assert_eq!(frame.targets().unwrap().len(), 24);
    assert!(
        frame
            .targets()
            .unwrap()
            .iter()
            .all(|t| t.relative_path != b"trash/moved")
    );
}

#[test]
fn diagram_appearance_is_forwarded_and_swatch_colors_are_unchanged() {
    let s = session("dix");
    let root = s.status().unwrap().root.key;
    let tree = s.clone().tree(root.clone()).unwrap();
    let swatches = |tree: &ExplorerTree| {
        tree.rows(0, 32)
            .unwrap()
            .rows
            .into_iter()
            .map(|r| (r.entry.display_name, r.map_rgb))
            .collect::<Vec<_>>()
    };
    let before = swatches(&tree);
    let dark = s
        .clone()
        .diagram(root.clone(), 320, 200, MapAppearance::Dark)
        .unwrap();
    let dark_image = dark.bitmap();
    for appearance in [
        MapAppearance::Light,
        MapAppearance::Dark,
        MapAppearance::LightIncreasedContrast,
        MapAppearance::DarkIncreasedContrast,
    ] {
        let frame = s
            .clone()
            .diagram(root.clone(), 320, 200, appearance)
            .unwrap();
        let image = frame.bitmap();
        let [light, darker] = crate::diagram::MapAppearance::from(appearance).hatch();
        let (mut hatched, mut interior) = (0, 0);
        for y in 0..image.height {
            for x in 0..image.width {
                let hit = frame.hit(x, y).unwrap().unwrap();
                let other = dark.hit(x, y).unwrap().unwrap();
                assert!(hit.entry.key.same_entry(other.entry.key.clone()));
                assert_eq!(hit.actionable, other.actionable);
                let at = (y * image.width + x) as usize * 4;
                let pixel = &image.rgba[at..at + 3];
                if !hit.actionable {
                    let stripe = if (x + y) % 4 < 2 { light } else { darker };
                    assert_eq!(pixel, stripe, "{appearance:?} hatch");
                    hatched += 1;
                } else if x as f64 > hit.rect.x + 1.0 && y as f64 > hit.rect.y + 1.0 {
                    // File interiors, and so the swatch base colors, do not change.
                    assert_eq!(pixel, &dark_image.rgba[at..at + 3], "{appearance:?}");
                    interior += 1;
                }
            }
        }
        assert!(hatched > 0 && interior > 10_000, "{appearance:?}");
    }
    assert_eq!(swatches(&tree), before);
}
