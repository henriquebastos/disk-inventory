//! `prototype-home` against the specialist prototype (`Explorer Window.dc.html`).
use super::*;
use crate::{
    bridge::ExplorerSession,
    diagram::MapAppearance,
    layout::{Rect, TileKind},
};
use std::collections::HashMap;

/// FNV-1a 64 over `path\tsize\n` for every node in creation order, with the root named
/// `ana`. The prototype's own `data()` under Node gives the same value after the one rename
/// (`CoreSimulator` to `CoreDevice`).
fn tree_checksum(map: &Map) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for id in 0..map.nodes.len() {
        let mut path = b"ana".to_vec();
        if id != 0 {
            path.push(b'/');
            path.extend(map.relative_path(id));
        }
        let line = [path, format!("\t{}\n", map.nodes[id].subtree).into_bytes()].concat();
        for byte in line {
            hash = (hash ^ byte as u64).wrapping_mul(0x100_0000_01b3);
        }
    }
    hash
}

#[test]
fn prototype_home_fixture_rebuilds_the_prototype_tree_exactly() {
    let map = prototype_home_map().unwrap();
    assert_eq!(map.nodes.len(), 542);
    let files = map.nodes.iter().filter(|n| n.kind == Kind::File).count();
    assert_eq!(files, 516);
    assert_eq!(map.nodes[0].subtree, 236_900_003_996);
    assert!(map.nodes.iter().all(|n| n.kind == Kind::File || n.raw == 0));
    assert_eq!(tree_checksum(&map), 0x5e76_0f22_16f6_264f);
    let session = ExplorerSession::fixture("prototype-home".into()).unwrap();
    let status = session.status().unwrap();
    assert!(status.simulated);
    assert_eq!(status.root_path, b"/Users/ana");
    assert_eq!(status.root.subtree_bytes, 236_900_003_996);
}

/// The prototype's `kindColor` for each fixture extension: OKLCH L 0.62, C 0.11 at the kind
/// hue (documents C 0.02, H 260), converted to clipped 8-bit sRGB.
#[test]
fn prototype_home_extensions_get_the_prototype_kind_colors() {
    let kinds: [(&[&str], [u8; 3]); 9] = [
        (VIDEO, [79, 138, 198]),     // H 250
        (IMAGE, [81, 153, 98]),      // H 150
        (AUDIO, [171, 109, 166]),    // H 330
        (ARCHIVE, [173, 124, 47]),   // H 75
        (&["app"], [133, 122, 196]), // H 290
        (CODE, [0, 153, 160]),       // H 200
        (CACHE, [190, 110, 82]),     // H 40
        (DATA, [138, 140, 52]),      // H 110
        (&["pdf", "pages", "txt", "log"], [127, 135, 147]),
    ];
    let map = prototype_home_map().unwrap();
    let mut seen = [0usize; 9];
    for id in 0..map.nodes.len() {
        if map.nodes[id].kind != Kind::File {
            continue;
        }
        let name = String::from_utf8(map.basename(id).to_vec()).unwrap();
        let extension = name.rsplit_once('.').unwrap().1;
        let kind = kinds
            .iter()
            .position(|(extensions, _)| extensions.contains(&extension))
            .unwrap();
        seen[kind] += 1;
        assert_eq!(
            crate::file_type::FolderContext::default().file_color(name.as_bytes()),
            kinds[kind].1,
            "{name}"
        );
    }
    assert!(seen.iter().all(|&count| count > 0), "{seen:?}");
}

/// Test-only port of the prototype's `layout()`: `place()` and `sq()` with the same
/// floating-point steps. Returns drawn file rectangles, files placed below 0.5 px² (not drawn)
/// and hatched directories, by node ID.
struct PrototypeLayout {
    files: HashMap<usize, Rect>,
    undrawn: Vec<usize>,
    hatched: Vec<usize>,
}
fn prototype_layout(map: &Map, width: f64, height: f64) -> PrototypeLayout {
    // `recompute()` sorts children by size, largest first; JavaScript sort is stable.
    let mut children = vec![Vec::new(); map.nodes.len()];
    for id in 1..map.nodes.len() {
        children[map.nodes[id].parent as usize].push(id);
    }
    for list in &mut children {
        list.sort_by_key(|&id| std::cmp::Reverse(map.nodes[id].subtree));
    }
    let mut out = PrototypeLayout {
        files: HashMap::new(),
        undrawn: Vec::new(),
        hatched: Vec::new(),
    };
    fn place(
        map: &Map,
        children: &[Vec<usize>],
        out: &mut PrototypeLayout,
        n: usize,
        (x, y, w, h): (f64, f64, f64, f64),
        depth: u32,
    ) {
        if map.nodes[n].kind == Kind::File {
            if w * h >= 0.5 {
                let rect = Rect {
                    x,
                    y,
                    width: w,
                    height: h,
                };
                out.files.insert(n, rect);
            } else {
                out.undrawn.push(n);
            }
            return;
        }
        if depth > 0 && (w < 3.0 || h < 3.0) {
            out.hatched.push(n);
            return;
        }
        // sq(items, x, y, w, h)
        let items: Vec<usize> = children[n]
            .iter()
            .copied()
            .filter(|&c| map.nodes[c].subtree > 0)
            .collect();
        let total: f64 = items.iter().map(|&c| map.nodes[c].subtree as f64).sum();
        if total == 0.0 {
            return;
        }
        let (mut x, mut y, mut w, mut h) = (x, y, w, h);
        let scale = w * h / total;
        let list: Vec<(usize, f64)> = items
            .iter()
            .map(|&c| (c, map.nodes[c].subtree as f64 * scale))
            .collect();
        let mut start = 0;
        while start < list.len() {
            let side = w.min(h);
            let (mut end, mut sum, mut best) = (start, 0.0, f64::INFINITY);
            for &(_, a) in &list[start..] {
                let ns = sum + a;
                let mx = if end > start { list[start].1 } else { a };
                let worst = (side * side * mx / (ns * ns)).max((ns * ns) / (side * side * a));
                if end > start && worst > best {
                    break;
                }
                end += 1;
                sum = ns;
                best = worst;
            }
            let row = &list[start..end];
            start = end;
            if w >= h {
                let cw = sum / h;
                let mut yy = y;
                for &(c, a) in row {
                    let rh = a / cw;
                    place(map, children, out, c, (x, yy, cw, rh), depth + 1);
                    yy += rh;
                }
                x += cw;
                w -= cw;
            } else {
                let rh = sum / w;
                let mut xx = x;
                for &(c, a) in row {
                    let rw = a / rh;
                    place(map, children, out, c, (xx, y, rw, rh), depth + 1);
                    xx += rw;
                }
                y += rh;
                h -= rh;
            }
        }
    }
    place(map, &children, &mut out, 0, (0.0, 0.0, width, height), 0);
    out
}

fn under(map: &Map, mut id: usize, ancestor: usize) -> bool {
    while id != 0 {
        id = map.nodes[id].parent as usize;
        if id == ancestor {
            return true;
        }
    }
    false
}

/// Compares every file rectangle that both layouts draw: each edge within 1 px.
/// Not compared, each with a checked reason: files that the prototype does not draw (in a
/// hatched directory, or under 0.5 px²), and files inside one of our aggregates (a rollup
/// below min_area or over budget, or a directory drawn whole).
/// A rollup is one sibling with the summed weight, so it can change the row split of its
/// siblings and their descendants. At the three large viewports every compared file must
/// match. At the small 200x150 and 60x40 viewports, files after a rollup may differ; all others
/// must match. At 60x40 the prototype hatches a directory.
/// Set `DI_PARITY_PRINT=1` to print every rectangle for the overlay images.
#[test]
fn squarify_matches_prototype_layout_at_render_and_portrait_viewports() {
    let map = prototype_home_map().unwrap();
    let explorer = Explorer::from_map(map.clone()).unwrap();
    let print = std::env::var_os("DI_PARITY_PRINT").is_some();
    let path = |id: usize| format!("ana/{}", String::from_utf8_lossy(&map.relative_path(id)));
    // 939x750 is the map of the designer render 1a-browse.png (1380x850 window). 640x900 is
    // portrait. 1702x1443 is the app map in backing pixels in the UI test window.
    // `strict`: every compared file must match.
    for (width, height, strict) in [
        (939u32, 750u32, true),
        (640, 900, true),
        (1702, 1443, true),
        (200, 150, false),
        (60, 40, false),
    ] {
        let prototype = prototype_layout(&map, width as f64, height as f64);
        let diagram = explorer
            .diagram(explorer.root_handle(), width, height, MapAppearance::Dark)
            .unwrap();
        let mut ours = HashMap::new();
        // Directories with a rollup tile, and directories drawn whole.
        let (mut rollups, mut whole) = (Vec::new(), Vec::new());
        for tile in &diagram.layout.tiles {
            match tile.kind {
                TileKind::Entry(key) if map.nodes[key.index() as usize].kind == Kind::Dir => {
                    whole.push((key.index() as usize, tile.rect))
                }
                TileKind::Entry(key) => {
                    ours.insert(key.index() as usize, tile.rect);
                }
                TileKind::Rollup { directory, .. } => {
                    rollups.push((directory.index() as usize, tile.rect))
                }
            }
        }
        let after_rollup = |id: usize| rollups.iter().any(|&(d, _)| under(&map, id, d));
        let (mut compared, mut matched, mut differ_after_rollup) = (0, 0, 0);
        let mut max_error = 0.0f64;
        for (&id, p) in &prototype.files {
            let Some(o) = ours.get(&id) else { continue };
            compared += 1;
            let error = [
                (p.x - o.x).abs(),
                (p.y - o.y).abs(),
                (p.x + p.width - o.x - o.width).abs(),
                (p.y + p.height - o.y - o.height).abs(),
            ]
            .into_iter()
            .fold(0.0, f64::max);
            if error <= 1.0 {
                matched += 1;
                max_error = max_error.max(error);
            } else if !strict && after_rollup(id) {
                differ_after_rollup += 1;
            } else {
                panic!("{width}x{height}: {} edges {error} px apart", path(id));
            }
        }
        let prototype_only: Vec<usize> = (prototype.files.keys())
            .copied()
            .filter(|id| !ours.contains_key(id))
            .collect();
        let ours_only: Vec<usize> = (ours.keys())
            .copied()
            .filter(|id| !prototype.files.contains_key(id))
            .collect();
        for &id in &prototype_only {
            assert!(
                after_rollup(id) || whole.iter().any(|&(d, _)| under(&map, id, d)),
                "{width}x{height}: {} is in none of our aggregates",
                path(id)
            );
        }
        for &id in &ours_only {
            assert!(
                prototype.hatched.iter().any(|&d| under(&map, id, d))
                    || prototype.undrawn.contains(&id),
                "{width}x{height}: {} has no exclusion reason",
                path(id)
            );
        }
        println!(
            "PARITY viewport={width}x{height} prototype_drawn={} ours_files={} compared={compared} \
             matched={matched} max_edge_error_of_matched={max_error:e} \
             differ_after_rollup={differ_after_rollup} prototype_only={} ours_only={} \
             prototype_undrawn={} prototype_hatched_dirs={} our_rollups={} our_whole_dirs={}",
            prototype.files.len(),
            ours.len(),
            prototype_only.len(),
            ours_only.len(),
            prototype.undrawn.len(),
            prototype.hatched.len(),
            rollups.len(),
            whole.len(),
        );
        if print {
            let rects = (prototype.files.iter().map(|(&id, &r)| ("prototype", id, r)))
                .chain(ours.iter().map(|(&id, &r)| ("ours", id, r)))
                .chain(rollups.iter().map(|&(id, r)| ("rollup", id, r)))
                .chain(whole.iter().map(|&(id, r)| ("whole", id, r)))
                .chain(prototype.hatched.iter().map(|&id| {
                    (
                        "hatched",
                        id,
                        Rect {
                            x: 0.0,
                            y: 0.0,
                            width: 0.0,
                            height: 0.0,
                        },
                    )
                }));
            for (side, id, r) in rects {
                println!(
                    "RECT {width}x{height} {side} {} {} {} {} {}",
                    r.x,
                    r.y,
                    r.width,
                    r.height,
                    path(id)
                );
            }
        }
        if strict {
            assert_eq!(matched, compared, "{width}x{height}");
            assert!(
                compared >= 500,
                "{width}x{height}: only {compared} compared"
            );
        }
    }
}
