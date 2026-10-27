use super::*;
use crate::{
    Node,
    inventory::Inventory,
    layout::{Layout, LayoutOptions, MAX_DEPTH, MAX_RECTANGLES, Rect, TileKind},
};
use std::{hint::black_box, time::Instant};

fn tree() -> Map {
    let mut map = Map {
        root: "/nonexistent-explorer-saved-root".into(),
        nodes: Vec::new(),
        names: Vec::new(),
        counters: Counters::default(),
        error_samples: Vec::new(),
    };
    add(&mut map, 0, b"", Kind::Dir, 7);
    map
}
fn add(map: &mut Map, parent: u32, name: &[u8], kind: Kind, raw: u64) -> u32 {
    let id = map.nodes.len() as u32;
    map.nodes.push(Node {
        parent,
        name_offset: map.names.len() as u64,
        name_len: name.len() as u32,
        kind,
        dev: 1,
        ino: id as u64 + 1,
        raw,
        accounted: raw,
        subtree: raw,
        links: 1,
    });
    map.names.extend_from_slice(name);
    id
}
fn explorer(mut map: Map) -> Explorer {
    map.aggregate().unwrap();
    Explorer::from_map(map).unwrap()
}
fn options() -> LayoutOptions {
    LayoutOptions {
        viewport: Rect {
            x: 10.0,
            y: 20.0,
            width: 1200.0,
            height: 800.0,
        },
        max_rectangles: 256,
        min_area: 1.0,
        max_depth: 32,
    }
}
fn validate(layout: &Layout, options: LayoutOptions) {
    assert!(layout.tiles.len() + layout.groups.len() <= options.max_rectangles);
    assert_eq!(
        layout.tiles.iter().map(|t| t.bytes).sum::<u64>(),
        layout.total_bytes
    );
    assert!(layout.work.entries_examined <= options.max_rectangles);
    assert!(layout.work.child_ids_examined <= 2 * options.max_rectangles);
    let box_ = options.viewport;
    for rect in layout
        .tiles
        .iter()
        .map(|tile| tile.rect)
        .chain(layout.groups.iter().map(|group| group.rect))
    {
        assert!(rect.x + rect.width > rect.x);
        assert!(rect.y + rect.height > rect.y);
    }
    for (i, a) in layout.tiles.iter().enumerate() {
        let r = a.rect;
        assert!([r.x, r.y, r.width, r.height].iter().all(|n| n.is_finite()));
        assert!(r.width > 0.0 && r.height > 0.0);
        assert!(r.x >= box_.x - 1e-7 && r.y >= box_.y - 1e-7);
        assert!(r.x + r.width <= box_.x + box_.width + 1e-7);
        assert!(r.y + r.height <= box_.y + box_.height + 1e-7);
        let expected = a.bytes as f64 / layout.total_bytes as f64 * box_.width * box_.height;
        assert!(
            (r.width * r.height - expected).abs() < 1e-6,
            "area mismatch: {a:?}"
        );
        for b in &layout.tiles[i + 1..] {
            assert!(
                (r.x + r.width).min(b.rect.x + b.rect.width) - r.x.max(b.rect.x) < 1e-7
                    || (r.y + r.height).min(b.rect.y + b.rect.height) - r.y.max(b.rect.y) < 1e-7
            );
        }
    }
}

#[test]
fn unrepresentable_subdivisions_preserve_the_parent_region() {
    for (weights, viewport) in [
        (
            [1, 1],
            Rect {
                x: 1e16,
                y: 1e16,
                width: 2.0,
                height: 2.0,
            },
        ),
        (
            [i64::MAX as u64, 1],
            Rect {
                x: 0.0,
                y: 0.0,
                width: 1.0,
                height: 1.0,
            },
        ),
    ] {
        let mut map = tree();
        map.nodes[0].raw = 0;
        add(&mut map, 0, b"a", Kind::File, weights[0]);
        add(&mut map, 0, b"b", Kind::File, weights[1]);
        let explorer = explorer(map);
        let options = LayoutOptions {
            viewport,
            max_rectangles: 10,
            min_area: 0.0,
            max_depth: 4,
        };
        let layout = explorer.layout(explorer.root_handle(), options).unwrap();
        validate(&layout, options);
        assert_eq!(layout.tiles.len(), 1);
        assert!(layout.groups.is_empty());
        assert_eq!(layout.tiles[0].rect, viewport);
        assert_eq!(
            layout.tiles[0].kind,
            TileKind::Entry(explorer.root_handle())
        );
    }
}

#[test]
fn rejected_subdivisions_consume_the_global_work_budget() {
    let mut map = tree();
    map.nodes[0].raw = 0;
    for directory in 0..8 {
        let parent = add(
            &mut map,
            0,
            format!("directory{directory}").as_bytes(),
            Kind::Dir,
            1,
        );
        for file in 0..8 {
            add(
                &mut map,
                parent,
                format!("file{file}").as_bytes(),
                Kind::File,
                1_000_000_000_000,
            );
        }
    }
    let explorer = explorer(map);
    for max_rectangles in [32, 16, 64] {
        let options = LayoutOptions {
            viewport: Rect {
                x: 1e16,
                y: 1e16,
                width: 16.0,
                height: 16.0,
            },
            max_rectangles,
            min_area: 0.0,
            max_depth: 4,
        };
        for cumulative_endpoints in [false, true] {
            let layout = explorer
                .layout_with_limits(
                    explorer.root_handle(),
                    options,
                    MAX_RECTANGLES,
                    MAX_DEPTH,
                    cumulative_endpoints,
                )
                .unwrap();
            validate(&layout, options);
        }
    }
}

#[test]
fn hierarchy_hardlinks_rollups_and_immediate_selection() {
    let mut map = tree();
    let a = add(&mut map, 0, b"a", Kind::Dir, 11);
    let b = add(&mut map, 0, b"b", Kind::Dir, 13);
    let owner = add(&mut map, a, b"file", Kind::File, 1000);
    let alias = add(&mut map, b, b"alias", Kind::File, 1000);
    map.nodes[owner as usize].links = 2;
    map.nodes[alias as usize].links = 2;
    map.nodes[alias as usize].ino = map.nodes[owner as usize].ino;
    for i in 0..100 {
        add(&mut map, b, format!("tiny-{i}").as_bytes(), Kind::File, 1);
    }
    add(&mut map, b, b"medium", Kind::File, 100);
    map.counters.errors = 2;
    let ex = explorer(map);
    assert!(ex.is_partial());
    assert_eq!(ex.counters().errors, 2);
    assert_eq!(ex.entry(ex.handle(owner)).unwrap().accounted_bytes, 1000);
    let alias_row = ex.entry(ex.handle(alias)).unwrap();
    assert_eq!(
        (alias_row.allocated_bytes, alias_row.accounted_bytes),
        (1000, 0)
    );
    assert_eq!(alias_row.parent, Some(ex.handle(b)));
    assert_eq!(ex.relative_path(alias_row.handle).unwrap(), b"b/alias");
    let mut opts = options();
    opts.min_area = 10000.0;
    let layout = ex.layout(ex.root_handle(), opts).unwrap();
    validate(&layout, opts);
    assert_eq!(layout.total_bytes, 1231);
    assert!(layout.tiles.iter().any(
        |t| matches!(t.kind, TileKind::Rollup { omitted_children, .. } if omitted_children >= 100)
    ));
    let focused = ex.layout(ex.handle(b), opts).unwrap();
    validate(&focused, opts);
    assert_eq!(focused.total_bytes, 213);
    for tile in &focused.tiles {
        if let TileKind::Entry(handle) = tile.kind {
            assert!(ex.relative_path(handle).unwrap().starts_with(b"b"));
        }
    }
}

#[test]
fn raw_byte_display_collisions_paging_and_session_identity() {
    let mut map = tree();
    add(&mut map, 0, &[0xff], Kind::File, 0);
    add(&mut map, 0, &[0xfe], Kind::File, 0);
    let other = explorer(map.clone());
    let nodes = map.nodes.as_ptr();
    let names = map.names.as_ptr();
    let ex = explorer(map);
    assert_eq!(ex.map.nodes.as_ptr(), nodes);
    assert_eq!(ex.map.names.as_ptr(), names);
    let page = ex.children(ex.root_handle(), 0, 1).unwrap();
    assert_eq!(
        (page.total, page.next_offset, page.entries_examined),
        (2, Some(1), 1)
    );
    let second = ex.children(ex.root_handle(), 1, 1).unwrap();
    assert_eq!(
        page.entries[0].display_name(),
        second.entries[0].display_name()
    );
    assert_ne!(page.entries[0].basename, second.entries[0].basename);
    assert_eq!(page.entries[0].basename, &[0xfe]);
    assert_ne!(page.entries[0].handle, second.entries[0].handle);
    assert!(other.entry(page.entries[0].handle).is_err());
    assert!(other.layout(ex.root_handle(), options()).is_err());
    assert!(ex.children(ex.root_handle(), 0, 0).is_err());
    assert!(ex.children(ex.root_handle(), 0, MAX_PAGE_SIZE + 1).is_err());
    assert!(ex.children(ex.handle(1), 0, 1).is_err());
    assert!(ex.layout(ex.handle(1), options()).is_err());
    assert!(ex.entry(ex.handle(u32::MAX)).is_err());
    assert!(
        ex.children(ex.root_handle(), usize::MAX, 1)
            .unwrap()
            .entries
            .is_empty()
    );
    assert_eq!(ex.storage_stats().index_bytes, 8 * ex.map.nodes.len());
}

#[test]
fn empty_zero_skewed_and_deep_trees_conserve_allocation() {
    let ex = explorer(tree());
    validate(&ex.layout(ex.root_handle(), options()).unwrap(), options());
    let mut map = tree();
    map.nodes[0].raw = 0;
    add(&mut map, 0, b"zero", Kind::Dir, 0);
    let ex = explorer(map);
    assert!(
        ex.layout(ex.root_handle(), options())
            .unwrap()
            .tiles
            .is_empty()
    );
    assert_eq!(
        ex.children(ex.root_handle(), 0, 10).unwrap().entries.len(),
        1
    );
    let mut map = tree();
    let mut parent = 0;
    for _ in 0..1000 {
        parent = add(&mut map, parent, b"chain", Kind::Dir, 1);
    }
    add(
        &mut map,
        parent,
        b"huge",
        Kind::File,
        i64::MAX as u64 - 2000,
    );
    let ex = explorer(map);
    for budget in [1, 2, 3, 10, 256, 4096] {
        let opts = LayoutOptions {
            max_rectangles: budget,
            min_area: 0.0,
            max_depth: 64,
            ..options()
        };
        validate(&ex.layout(ex.root_handle(), opts).unwrap(), opts);
        validate(&ex.layout(ex.handle(parent), opts).unwrap(), opts);
    }
}

#[test]
fn invalid_geometry_and_limits_are_rejected() {
    let ex = explorer(tree());
    for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -1.0, 0.0] {
        let mut opts = options();
        opts.viewport.width = bad;
        assert!(ex.layout(ex.root_handle(), opts).is_err());
        opts = options();
        opts.viewport.height = bad;
        assert!(ex.layout(ex.root_handle(), opts).is_err());
    }
    for bad in [f64::NAN, f64::INFINITY, -1.0] {
        let opts = LayoutOptions {
            min_area: bad,
            ..options()
        };
        assert!(ex.layout(ex.root_handle(), opts).is_err());
    }
    for budget in [0, MAX_RECTANGLES + 1] {
        assert!(
            ex.layout(
                ex.root_handle(),
                LayoutOptions {
                    max_rectangles: budget,
                    ..options()
                }
            )
            .is_err()
        );
    }
    assert!(
        ex.layout(
            ex.root_handle(),
            LayoutOptions {
                max_depth: MAX_DEPTH + 1,
                ..options()
            }
        )
        .is_err()
    );
    let mut opts = options();
    opts.viewport.x = f64::MAX;
    assert!(ex.layout(ex.root_handle(), opts).is_err());
    opts.viewport.x = f64::NAN;
    assert!(ex.layout(ex.root_handle(), opts).is_err());
    opts = options();
    opts.viewport.x = 0.0;
    opts.viewport.y = 0.0;
    opts.viewport.width = f64::from_bits(1);
    opts.viewport.height = 1.0;
    assert!(ex.layout(ex.root_handle(), opts).is_err());
}

fn unrelated_tree(count: usize) -> Explorer {
    let mut map = tree();
    let focus = add(&mut map, 0, b"focus", Kind::Dir, 2);
    add(&mut map, focus, b"large", Kind::File, 10000);
    let unrelated = add(&mut map, 0, b"unrelated", Kind::Dir, 3);
    for i in 0..count {
        add(
            &mut map,
            unrelated,
            format!("file-{i}").as_bytes(),
            Kind::File,
            1,
        );
    }
    explorer(map)
}
#[test]
fn focus_and_resize_do_not_visit_unrelated_subtrees_or_entire_fanout() {
    let small = unrelated_tree(10);
    let large = unrelated_tree(100000);
    for width in [1.0, 500.0, 2000.0] {
        let mut opts = options();
        opts.viewport.width = width;
        let a = small.layout(small.handle(1), opts).unwrap();
        let b = large.layout(large.handle(1), opts).unwrap();
        validate(&b, opts);
        assert_eq!(a.work, b.work);
        assert_eq!(b.work.child_ids_examined, 1);
        assert_eq!(a.total_bytes, b.total_bytes);
        let wide = large.layout(large.handle(3), opts).unwrap();
        validate(&wide, opts);
        assert!(wide.work.child_ids_examined <= opts.max_rectangles);
        let page = large.children(large.handle(3), 90000, 20).unwrap();
        assert_eq!(page.entries_examined, 20);
    }
}

#[test]
fn varied_hierarchies_have_bounded_proportional_deterministic_layouts() {
    let mut map = tree();
    let mut seed = 1u64;
    let mut dirs = vec![0];
    for i in 0..2000 {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
        let parent = dirs[seed as usize % dirs.len()];
        let kind = if i % 7 == 0 { Kind::Dir } else { Kind::File };
        let id = add(
            &mut map,
            parent,
            format!("{i}").as_bytes(),
            kind,
            seed % 100000,
        );
        if kind == Kind::Dir {
            dirs.push(id);
        }
    }
    let ex = explorer(map);
    for &focus in dirs.iter().step_by(11) {
        for budget in [3, 31, 256] {
            let opts = LayoutOptions {
                max_rectangles: budget,
                ..options()
            };
            let a = ex.layout(ex.handle(focus), opts).unwrap();
            let b = ex.layout(ex.handle(focus), opts).unwrap();
            let translated_options = LayoutOptions {
                viewport: Rect {
                    x: opts.viewport.x + 137.0,
                    y: opts.viewport.y + 251.0,
                    ..opts.viewport
                },
                ..opts
            };
            let translated = ex.layout(ex.handle(focus), translated_options).unwrap();
            validate(&translated, translated_options);
            assert_eq!(
                a.tiles
                    .iter()
                    .map(|tile| (tile.kind, tile.bytes))
                    .collect::<Vec<_>>(),
                translated
                    .tiles
                    .iter()
                    .map(|tile| (tile.kind, tile.bytes))
                    .collect::<Vec<_>>(),
                "ordinary coordinate rounding must not remove detail"
            );
            validate(&a, opts);
            assert_eq!(a.work, b.work);
            assert_eq!(
                a.tiles.iter().map(|t| (t.kind, t.rect)).collect::<Vec<_>>(),
                b.tiles.iter().map(|t| (t.kind, t.rect)).collect::<Vec<_>>()
            );
        }
    }
}

#[test]
fn inventory_transfers_the_loaded_arena_without_source_io() {
    let base = std::env::var_os("CARGO_TARGET_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join(format!("explorer-fixture-{}", std::process::id()));
    std::fs::create_dir_all(&base).unwrap();
    let path = base.join("saved.dmap");
    let ex = unrelated_tree(10);
    crate::snapshot::save_new(&ex.map, &path).unwrap();
    let loaded = Inventory::open(&path).unwrap().into_explorer().unwrap();
    assert_eq!(loaded.root(), ex.root());
    assert_eq!(
        loaded.entry(loaded.root_handle()).unwrap().subtree_bytes,
        ex.map.nodes[0].subtree
    );
    validate(
        &loaded.layout(loaded.root_handle(), options()).unwrap(),
        options(),
    );
    std::fs::remove_file(path).unwrap();
    std::fs::remove_dir(base).unwrap();
}

fn rss_kib() -> u64 {
    let out = std::process::Command::new("/bin/ps")
        .args(["-o", "rss=", "-p", &std::process::id().to_string()])
        .output()
        .unwrap();
    String::from_utf8(out.stdout)
        .unwrap()
        .trim()
        .parse()
        .unwrap()
}
/// Opt in with `cargo test --release --lib explorer_release_performance -- --ignored --nocapture`.
/// EXPLORER_SNAPSHOT reads an existing saved map only; otherwise EXPLORER_ENTRIES
/// (default 3,000,000) creates an in-memory synthetic arena, never a live tree.
#[test]
#[ignore = "multi-million-entry release performance fixture"]
fn explorer_release_performance() {
    if cfg!(debug_assertions) {
        panic!("run this fixture with --release");
    }
    let baseline_rss = rss_kib();
    let start = Instant::now();
    let map = if let Some(path) = std::env::var_os("EXPLORER_SNAPSHOT") {
        crate::snapshot::load(Path::new(&path)).unwrap()
    } else {
        let count = std::env::var("EXPLORER_ENTRIES")
            .unwrap_or_else(|_| "3000000".into())
            .parse::<usize>()
            .unwrap();
        assert!(count >= 2_000_000);
        let mut map = tree();
        map.nodes.reserve_exact(count - 1);
        map.names.reserve_exact(count * 12);
        for i in 1..count {
            let (parent, kind) = if i <= 1000 {
                (0, Kind::Dir)
            } else {
                (1 + (i % 1000) as u32, Kind::File)
            };
            add(
                &mut map,
                parent,
                format!("e{i:010}").as_bytes(),
                kind,
                (i as u64 % 8192) * 512,
            );
        }
        map.aggregate().unwrap();
        map
    };
    let load = start.elapsed();
    let loaded_rss = rss_kib();
    let start = Instant::now();
    let ex = Explorer::from_map(map).unwrap();
    let index = start.elapsed();
    let indexed_rss = rss_kib();
    let stats = ex.storage_stats();
    let focus = ex
        .children(ex.root_handle(), 0, MAX_PAGE_SIZE)
        .unwrap()
        .entries
        .into_iter()
        .find(|e| e.kind == Kind::Dir)
        .unwrap()
        .handle;
    let iterations = 2000;
    let start = Instant::now();
    let mut rows = 0;
    for i in 0..iterations {
        let page = ex.children(focus, i % 10, 100).unwrap();
        rows += page.entries.len();
        black_box(page);
        black_box(ex.entry(focus).unwrap());
    }
    let query = start.elapsed();
    let start = Instant::now();
    let mut tiles = 0;
    let mut groups = 0;
    let mut examined = 0;
    for i in 0..iterations {
        let mut opts = options();
        opts.viewport.width += (i % 100) as f64;
        let layout = ex
            .layout(if i % 2 == 0 { ex.root_handle() } else { focus }, opts)
            .unwrap();
        assert_eq!(
            layout.tiles.iter().map(|t| t.bytes).sum::<u64>(),
            layout.total_bytes
        );
        assert!(layout.tiles.len() + layout.groups.len() <= opts.max_rectangles);
        tiles += layout.tiles.len();
        groups += layout.groups.len();
        examined += layout.work.child_ids_examined;
        black_box(layout);
    }
    let layout = start.elapsed();
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::uninit();
    assert_eq!(
        unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) },
        0
    );
    let peak_bytes = unsafe { usage.assume_init() }.ru_maxrss;
    println!(
        "entries={} total_bytes={} partial={} errors={} arena_bytes={} index_bytes={} baseline_rss_kib={} loaded_rss_kib={} indexed_rss_kib={} peak_rss_bytes={} load_ms={:.3} index_ms={:.3} iterations={} query_us={:.3} layout_us={:.3} avg_rows={:.2} avg_tiles={:.2} avg_groups={:.2} avg_child_ids_examined={:.2}",
        stats.entries,
        ex.map.nodes[0].subtree,
        ex.is_partial(),
        ex.counters().errors,
        stats.arena_bytes,
        stats.index_bytes,
        baseline_rss,
        loaded_rss,
        indexed_rss,
        peak_bytes,
        load.as_secs_f64() * 1000.0,
        index.as_secs_f64() * 1000.0,
        iterations,
        query.as_secs_f64() * 1e6 / iterations as f64,
        layout.as_secs_f64() * 1e6 / iterations as f64,
        rows as f64 / iterations as f64,
        tiles as f64 / iterations as f64,
        groups as f64 / iterations as f64,
        examined as f64 / iterations as f64
    );
}

#[test]
fn virtual_tree_large_fanout_reveal_and_collapse_are_sparse() {
    let mut map = tree();
    let directory = add(&mut map, 0, b"directory", Kind::Dir, 0);
    let nested = add(&mut map, directory, b"nested", Kind::Dir, 0);
    let target = add(&mut map, nested, b"target.txt", Kind::File, 8000);
    for i in 0..100_000 {
        add(
            &mut map,
            directory,
            format!("file-{i:06}").as_bytes(),
            Kind::File,
            4096,
        );
    }
    let e = explorer(map);
    let mut view = crate::tree_view::TreeView::new(&e, e.root_handle()).unwrap();
    assert_eq!(view.row_count(), 1);
    view.expand(&e, e.handle(directory), true).unwrap();
    assert_eq!(view.row_count(), 100_002);
    let page = view.rows(&e, 99_990, 12).unwrap();
    assert_eq!(page.rows.len(), 12);
    assert!(page.visits <= 24);
    assert_eq!(view.expanded_count(), 1);
    assert!(view.expansion_payload_bytes() < 4096);
    let row = view.reveal(&e, e.handle(target)).unwrap();
    let page = view.rows(&e, row, 1).unwrap();
    assert_eq!(page.rows[0].entry.handle, e.handle(target));
    assert_eq!(page.rows[0].depth, 2);
    assert_eq!(view.row_count(), 100_003);
    view.expand(&e, e.handle(directory), false).unwrap();
    assert_eq!(view.row_count(), 1);
    assert_eq!(view.expanded_count(), 0);
}
#[test]
fn diagram_pixel_detail_and_zoom_preserve_weights_and_hit_authority() {
    let mut map = tree();
    let dir = add(&mut map, 0, b"dense", Kind::Dir, 4096);
    for i in 0..500 {
        add(
            &mut map,
            dir,
            format!("image-{i}.png").as_bytes(),
            Kind::File,
            4096,
        );
    }
    let tiny = add(&mut map, 0, b"tiny", Kind::Dir, 0);
    let small = add(&mut map, tiny, b"4k.txt", Kind::File, 4096);
    add(&mut map, tiny, b"8k.txt", Kind::File, 8192);
    add(&mut map, tiny, b"empty", Kind::File, 0);
    let e = explorer(map);
    let frame = e.diagram(e.root_handle(), 640, 400).unwrap();
    assert!(frame.stats.tiles > 160);
    assert_eq!(
        frame.layout.tiles.iter().map(|t| t.bytes).sum::<u64>(),
        frame.layout.total_bytes
    );
    assert!(frame.stats.child_visits <= 2 * crate::diagram::MAX_REGIONS);
    assert_eq!(frame.rgba().len(), 640 * 400 * 4);
    let zoom = e.diagram(e.handle(tiny), 100, 100).unwrap();
    let r = zoom.region(e.handle(small)).unwrap();
    let hit = zoom
        .hit((r.x + r.width / 2.0) as u32, (r.y + r.height / 2.0) as u32)
        .unwrap();
    assert_eq!(hit.key, e.handle(small));
    assert!(hit.actionable);
    assert_eq!(hit.bytes, 4096);
    assert!(e.diagram(e.root_handle(), u32::MAX, u32::MAX).is_err());
    let one = e.diagram(e.root_handle(), 1, 1).unwrap();
    assert!(!one.hit(0, 0).unwrap().actionable);
    let again = e.diagram(e.root_handle(), 640, 400).unwrap();
    assert_eq!(frame.rgba(), again.rgba());
}

#[test]
fn diagram_squarify_places_compact_siblings_in_wide_tall_and_retina_frames() {
    let mut map = tree();
    map.nodes[0].raw = 0;
    map.nodes[0].accounted = 0;
    map.nodes[0].subtree = 0;
    for i in 0..72 {
        add(&mut map, 0, format!("{i}.png").as_bytes(), Kind::File, 4096);
    }
    let e = explorer(map);
    for (width, height) in [(1000, 300), (300, 1000), (2000, 600), (600, 2000)] {
        let frame = e.diagram(e.root_handle(), width, height).unwrap();
        assert_eq!(frame.layout.tiles.len(), 72);
        for tile in &frame.layout.tiles {
            let expected = width as f64 * height as f64 / 72.0;
            assert!((tile.rect.area() - expected).abs() < expected * 1e-9);
        }
        // Squarify starts with five compact cells on the SHORT side, unlike the
        // former three long-side strips of 24 siblings. Scaling/transposing is stable.
        let first = frame.layout.tiles[0].rect;
        let scale = width.max(height) as f64 / 1000.0;
        let (long, short) = if width > height {
            (first.width, first.height)
        } else {
            (first.height, first.width)
        };
        assert!((long - 1000.0 / 72.0 * 5.0 * scale).abs() < 1e-9);
        assert!((short - 60.0 * scale).abs() < 1e-9);
        // The existing legacy API's algorithm and limits are unchanged.
        let legacy = e
            .layout(
                e.root_handle(),
                LayoutOptions {
                    viewport: Rect {
                        x: 0.0,
                        y: 0.0,
                        width: width as f64,
                        height: height as f64,
                    },
                    max_rectangles: 256,
                    min_area: 1.0,
                    max_depth: 64,
                },
            )
            .unwrap();
        for (new, old) in frame.layout.tiles.iter().zip(&legacy.tiles) {
            for (a, b) in [
                (new.rect.x, old.rect.x),
                (new.rect.y, old.rect.y),
                (new.rect.width, old.rect.width),
                (new.rect.height, old.rect.height),
            ] {
                assert!((a - b).abs() < 1e-9);
            }
            assert_eq!(new.bytes, old.bytes);
            assert_eq!(new.kind, old.kind);
        }
        for y in 0..height {
            for x in 0..width {
                let hit = frame.hit(x, y).expect("no pixel-center gaps");
                assert!(hit.actionable);
                assert!(
                    x as f64 + 0.5 >= hit.rect.x && (x as f64 + 0.5) < hit.rect.x + hit.rect.width
                );
                assert!(
                    y as f64 + 0.5 >= hit.rect.y && (y as f64 + 0.5) < hit.rect.y + hit.rect.height
                );
            }
        }
        assert!(frame.hit(width, 0).is_none());
        assert!(frame.hit(0, height).is_none());
    }
}

#[test]
fn diagram_skewed_nested_geometry_keeps_area_coverage_zero_and_budget_semantics() {
    let mut map = tree();
    let mut parent = 0;
    for i in 0..80 {
        parent = add(
            &mut map,
            parent,
            format!("deep-{i}").as_bytes(),
            Kind::Dir,
            0,
        );
    }
    let deep = add(&mut map, parent, b"deep.png", Kind::File, 1_000_000);
    let zero = add(&mut map, 0, b"empty", Kind::File, 0);
    for d in 0..9 {
        let dir = add(&mut map, 0, format!("dir-{d}").as_bytes(), Kind::Dir, d);
        for n in 1..=31 {
            add(
                &mut map,
                dir,
                format!("f-{n}.swift").as_bytes(),
                Kind::File,
                n * n * 13 + 1,
            );
        }
    }
    let e = explorer(map);
    for (w, h) in [(713, 421), (421, 713), (1426, 842)] {
        let f = e.diagram(e.root_handle(), w, h).unwrap();
        assert!(f.region(e.handle(deep)).is_some(), "no fixed depth policy");
        assert!(f.region(e.handle(zero)).is_none());
        assert_eq!(
            f.layout.tiles.iter().map(|t| t.bytes).sum::<u64>(),
            f.layout.total_bytes
        );
        for tile in &f.layout.tiles {
            let expected = w as f64 * h as f64 * tile.bytes as f64 / f.layout.total_bytes as f64;
            assert!((tile.rect.area() - expected).abs() < expected * 1e-9);
        }
        for y in 0..h {
            for x in 0..w {
                assert!(f.hit(x, y).is_some());
            }
        }
        assert!(
            f.stats.child_visits <= 2 * (w as usize * h as usize).min(crate::diagram::MAX_REGIONS)
        );
        // Raster construction additionally asserts that no pixel receives two owners.
    }
    let mut empty = tree();
    empty.nodes[0].raw = 0;
    empty.nodes[0].accounted = 0;
    empty.nodes[0].subtree = 0;
    add(&mut empty, 0, b"zero", Kind::File, 0);
    let e = explorer(empty);
    let frame = e.diagram(e.root_handle(), 32, 32).unwrap();
    assert!(frame.layout.tiles.is_empty());
    assert!(frame.hit(0, 0).is_none());
}

#[test]
fn diagram_integer_precision_hardlinks_and_zero_entries_survive_squarify() {
    let mut map = tree();
    map.nodes[0].raw = 0;
    // Exact total u64::MAX, with low bits that cannot be represented by f64.
    let weights = [
        (1u64 << 63) + 1,
        (1u64 << 62) + 3,
        (1u64 << 61) + 5,
        (1u64 << 61) - 10,
    ];
    let mut ids = Vec::new();
    for (i, weight) in weights.into_iter().enumerate() {
        ids.push(add(
            &mut map,
            0,
            format!("a-{i}.mov").as_bytes(),
            Kind::File,
            weight,
        ));
    }
    let alias = add(&mut map, 0, b"z-alias.mov", Kind::File, weights[0]);
    map.nodes[ids[0] as usize].links = 2;
    map.nodes[alias as usize].links = 2;
    map.nodes[alias as usize].ino = map.nodes[ids[0] as usize].ino;
    let zero = add(&mut map, 0, b"zero", Kind::File, 0);
    let e = explorer(map);
    for (width, height) in [(160, 100), (100, 160), (1, 1)] {
        let f = e.diagram(e.root_handle(), width, height).unwrap();
        assert_eq!(f.layout.total_bytes, u64::MAX);
        assert_eq!(
            f.layout.tiles.iter().map(|t| t.bytes as u128).sum::<u128>(),
            u64::MAX as u128
        );
        assert!(f.region(e.handle(alias)).is_none());
        assert!(f.region(e.handle(zero)).is_none());
        if width > 1 {
            for (&id, weight) in ids.iter().zip(weights) {
                let tile = f
                    .layout
                    .tiles
                    .iter()
                    .find(|t| t.kind == TileKind::Entry(e.handle(id)))
                    .unwrap();
                assert_eq!(tile.bytes, weight);
            }
        }
        for y in 0..height {
            for x in 0..width {
                let hit = f.hit(x, y).unwrap();
                assert_eq!(hit.actionable, width > 1);
            }
        }
        let budget = (width as usize * height as usize).min(crate::diagram::MAX_REGIONS);
        assert!(f.stats.tiles + f.stats.groups <= budget);
        assert!(f.stats.child_visits <= 2 * budget);
    }
    let tree = crate::tree_view::TreeView::new(&e, e.root_handle()).unwrap();
    let rows = tree.rows(&e, 0, 10).unwrap();
    assert_eq!(rows.rows.len(), 6);
    for id in [alias, zero] {
        let entry = &rows
            .rows
            .iter()
            .find(|r| r.entry.handle == e.handle(id))
            .unwrap()
            .entry;
        assert_eq!(entry.accounted_bytes, 0);
    }
    assert_eq!(
        e.entry(e.handle(alias)).unwrap().allocated_bytes,
        weights[0]
    );
}

#[test]
fn diagram_flat_gradient_has_no_ancestor_ridges_and_aggregates_are_hatched() {
    let make = |depth| {
        let mut map = tree();
        map.nodes[0].raw = 0;
        let mut parent = 0;
        for _ in 0..depth {
            parent = add(&mut map, parent, b"nested", Kind::Dir, 0);
        }
        add(&mut map, parent, b"image.png", Kind::File, 100);
        explorer(map)
    };
    let shallow = make(0);
    let nested = make(12);
    let a = shallow.diagram(shallow.root_handle(), 101, 81).unwrap();
    let b = nested.diagram(nested.root_handle(), 101, 81).unwrap();
    assert_eq!(a.rgba(), b.rgba(), "ancestors must not add lighting ridges");
    assert_eq!(a.stats.surface_payload_bytes, 0);
    assert_eq!(b.stats.surface_payload_bytes, 0);
    let pixel = |x: usize, y: usize| &a.rgba()[(y * 101 + x) * 4..(y * 101 + x) * 4 + 3];
    // Real raster, not just the color helper: only the first edge is darkened;
    // the interior is a restrained monotonic 155-degree gradient, not a cushion.
    for y in 2..79 {
        for x in 2..99 {
            assert!((0..3).all(|c| pixel(x, y)[c] <= pixel(x - 1, y)[c]));
            assert!((0..3).all(|c| pixel(x, y)[c] <= pixel(x, y - 1)[c]));
        }
    }
    assert_eq!(pixel(1, 1), [105, 167, 119]);
    assert_eq!(pixel(99, 79), [69, 129, 83]);
    let aggregate = explorer(tree());
    let f = aggregate.diagram(aggregate.root_handle(), 8, 8).unwrap();
    assert_eq!(f.stats.aggregate_pixels, 64);
    for y in 0..8 {
        for x in 0..8 {
            let at = (y * 8 + x) * 4;
            let color = if (x + y) % 4 < 2 {
                [59, 59, 62]
            } else {
                [38, 38, 40]
            };
            assert_eq!(&f.rgba()[at..at + 3], color);
            assert_eq!(f.rgba()[at + 3], 255);
            assert!(!f.hit(x as u32, y as u32).unwrap().actionable);
        }
    }
}
