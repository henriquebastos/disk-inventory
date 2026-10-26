use super::*;
use crate::{Counters, Map, Node};
fn map() -> Map {
    let mut m = Map {
        root: "/native-free-virtual-tree".into(),
        nodes: vec![],
        names: vec![],
        counters: Counters::default(),
        error_samples: vec![],
    };
    add(&mut m, 0, b"", Kind::Dir, 0);
    m
}
fn add(m: &mut Map, parent: u32, name: &[u8], kind: Kind, bytes: u64) -> u32 {
    let id = m.nodes.len() as u32;
    m.nodes.push(Node {
        parent,
        name_offset: m.names.len() as u64,
        name_len: name.len() as u32,
        kind,
        dev: 1,
        ino: id as u64 + 1,
        raw: bytes,
        accounted: bytes,
        subtree: bytes,
        links: 1,
    });
    m.names.extend_from_slice(name);
    id
}
fn explorer(mut map: Map) -> Explorer {
    map.aggregate().unwrap();
    Explorer::from_map(map).unwrap()
}
#[test]
fn million_child_expansion_materializes_only_requested_rows() {
    let mut map = map();
    let directory = add(&mut map, 0, b"wide", Kind::Dir, 0);
    for i in 0..1_000_000 {
        add(
            &mut map,
            directory,
            format!("file-{i:07}").as_bytes(),
            Kind::File,
            4096,
        );
    }
    let start = std::time::Instant::now();
    let e = explorer(map);
    let index = start.elapsed();
    let mut view = TreeView::new(&e, e.root_handle()).unwrap();
    let start = std::time::Instant::now();
    view.expand(&e, e.handle(directory), true).unwrap();
    let page = view.rows(&e, 999_900, 128).unwrap();
    assert_eq!(page.total, 1_000_001);
    assert_eq!(page.rows.len(), 101);
    assert_eq!(page.visits, 202);
    assert_eq!(
        view.visible_row(&e, page.rows[0].entry.handle).unwrap(),
        Some(999_900)
    );
    assert!(view.expansion_payload_bytes() < 4096);
    assert_eq!(view.expanded_count(), 1);
    println!(
        "MILLION_TREE index={index:?} expand+tail={:?} transferred_rows={} visits={} retained_payload_bytes={} inventory_bytes={} index_bytes={}",
        start.elapsed(),
        page.rows.len(),
        page.visits,
        view.expansion_payload_bytes(),
        e.storage_stats().arena_bytes,
        e.storage_stats().index_bytes
    );
}
#[test]
fn deep_reveal_is_iterative_and_outside_keys_do_not_change_expansion() {
    let mut map = map();
    let outside = add(&mut map, 0, b"outside", Kind::File, 1);
    let root = add(&mut map, 0, b"chain", Kind::Dir, 0);
    let mut parent = root;
    for _ in 0..2000 {
        parent = add(&mut map, parent, b"d", Kind::Dir, 0);
    }
    let target = add(&mut map, parent, b"zero", Kind::File, 0);
    let e = explorer(map);
    let mut view = TreeView::new(&e, e.handle(root)).unwrap();
    assert!(view.reveal(&e, e.handle(outside)).is_err());
    assert_eq!(view.expanded_count(), 0);
    let row = view.reveal(&e, e.handle(target)).unwrap();
    assert_eq!(row, 2000);
    let p = view.rows(&e, row, 1).unwrap();
    assert_eq!(p.visits, 2001);
    assert_eq!(p.rows[0].entry.handle, e.handle(target));
    assert_eq!(p.rows[0].depth, 2000);
    assert_eq!(view.visible_row(&e, e.handle(target)).unwrap(), Some(row));
    let first = e.child_ids(root)[0];
    view.expand(&e, e.handle(first), false).unwrap();
    assert_eq!(view.row_count(), 1);
    assert_eq!(view.expanded_count(), 0);
    assert_eq!(view.visible_row(&e, e.handle(target)).unwrap(), None);
}
#[test]
fn virtual_rows_preserve_size_order_zero_and_shared_entries() {
    let mut map = map();
    let a = add(&mut map, 0, b"a", Kind::Dir, 10);
    let b = add(&mut map, 0, b"b", Kind::Dir, 0);
    let x = add(&mut map, a, b"x", Kind::File, 40);
    let zero = add(&mut map, a, b"zero", Kind::File, 0);
    let y = add(&mut map, b, b"y", Kind::File, 30);
    let alias = add(&mut map, b, b"alias", Kind::File, 40);
    map.nodes[alias as usize].ino = map.nodes[x as usize].ino;
    map.nodes[alias as usize].links = 2;
    map.nodes[x as usize].links = 2;
    let e = explorer(map);
    let mut view = TreeView::new(&e, e.root_handle()).unwrap();
    view.expand(&e, e.handle(a), true).unwrap();
    view.expand(&e, e.handle(b), true).unwrap();
    let p = view.rows(&e, 0, 256).unwrap();
    let keys: Vec<_> = p.rows.iter().map(|r| r.entry.handle).collect();
    assert_eq!(
        keys,
        vec![
            e.handle(a),
            e.handle(x),
            e.handle(zero),
            e.handle(b),
            e.handle(y),
            e.handle(alias)
        ]
    );
    assert_eq!(p.rows.last().unwrap().entry.accounted_bytes, 0);
    assert_eq!(view.reveal(&e, e.handle(alias)).unwrap(), 5);
    view.expand(&e, e.handle(a), false).unwrap();
    assert_eq!(view.reveal(&e, e.handle(alias)).unwrap(), 3);
    assert!(view.rows(&e, 0, 257).is_err());
    assert!(view.expand(&e, e.handle(x), true).is_err());
}

#[test]
fn visible_row_tracks_sibling_shifts_without_expanding_hidden_ancestors() {
    let mut m = map();
    let before = add(&mut m, 0, b"before", Kind::Dir, 100);
    let nested = add(&mut m, before, b"nested", Kind::Dir, 0);
    let leaf = add(&mut m, nested, b"leaf", Kind::File, 50);
    let selected = add(&mut m, 0, b"selected", Kind::File, 20);
    let after = add(&mut m, 0, b"after", Kind::Dir, 0);
    add(&mut m, after, b"tiny", Kind::File, 1);
    let e = explorer(m);
    let mut t = TreeView::new(&e, e.root_handle()).unwrap();
    assert_eq!(t.visible_row(&e, e.root_handle()).unwrap(), None);
    assert_eq!(t.visible_row(&e, e.handle(selected)).unwrap(), Some(1));
    assert_eq!(t.visible_row(&e, e.handle(leaf)).unwrap(), None);
    t.expand(&e, e.handle(after), true).unwrap();
    assert_eq!(t.visible_row(&e, e.handle(selected)).unwrap(), Some(1));
    t.expand(&e, e.handle(before), true).unwrap();
    assert_eq!(t.visible_row(&e, e.handle(selected)).unwrap(), Some(2));
    t.expand(&e, e.handle(nested), true).unwrap();
    assert_eq!(t.visible_row(&e, e.handle(selected)).unwrap(), Some(3));
    assert_eq!(t.visible_row(&e, e.handle(leaf)).unwrap(), Some(2));
    t.expand(&e, e.handle(before), false).unwrap();
    let payload = t.expansion_payload_bytes();
    let count = t.expanded_count();
    assert_eq!(t.visible_row(&e, e.handle(selected)).unwrap(), Some(1));
    assert_eq!(t.visible_row(&e, e.handle(leaf)).unwrap(), None);
    assert_eq!(t.expansion_payload_bytes(), payload);
    assert_eq!(t.expanded_count(), count);
    let scoped = TreeView::new(&e, e.handle(after)).unwrap();
    assert_eq!(scoped.visible_row(&e, e.handle(selected)).unwrap(), None);
    let foreign = explorer(map());
    assert!(t.visible_row(&e, foreign.root_handle()).is_err());
}

#[test]
fn row_payload_accounting_does_not_traverse_expansion_state() {
    let mut m = map();
    let mut parent = 0;
    for _ in 0..2000 {
        parent = add(&mut m, parent, b"d", Kind::Dir, 0);
    }
    let leaf = add(&mut m, parent, b"file", Kind::File, 4096);
    let e = explorer(m);
    let mut t = TreeView::new(&e, e.root_handle()).unwrap();
    t.reveal(&e, e.handle(leaf)).unwrap();
    for expanded in [true, false] {
        if !expanded {
            t.expand(&e, e.handle(e.child_ids(0)[0]), false).unwrap();
        }
        let expected = t.branches.capacity() * std::mem::size_of::<(u32, Branch)>()
            + t.branches
                .values()
                .map(|b| {
                    b.prefix.capacity() * std::mem::size_of::<(usize, u32, usize)>()
                        + b.children.len() * std::mem::size_of::<(usize, u32)>()
                })
                .sum::<usize>();
        t.payload_term_reads.set(0);
        let mut visits = 0;
        for _ in 0..100 {
            visits += t.rows(&e, 0, 1).unwrap().visits;
            assert_eq!(t.expansion_payload_bytes(), expected);
        }
        println!(
            "ROW_PAYLOAD expanded={expanded} retained_capacity={} row_visits={visits} payload_term_reads={}",
            t.branches.capacity(),
            t.payload_term_reads.get()
        );
        assert_eq!(visits, 100);
        assert_eq!(
            t.payload_term_reads.get(),
            100,
            "one cached payload read per query, regardless of expansion state/capacity"
        );
    }
    // Check the incremental sum against the old full calculation across growing/shrinking
    // sibling prefixes, repeated expansion, deep removal and reveal into existing branches.
    let mut m = map();
    let mut keys = vec![];
    for i in 0..32 {
        let dir = add(&mut m, 0, format!("d{i}").as_bytes(), Kind::Dir, 0);
        let nested = add(&mut m, dir, b"nested", Kind::Dir, 0);
        let leaf = add(&mut m, nested, b"file", Kind::File, 10);
        keys.push((dir, leaf));
    }
    let e = explorer(m);
    let mut t = TreeView::new(&e, e.root_handle()).unwrap();
    for round in 0..4 {
        for &(dir, leaf) in &keys {
            if round % 2 == 0 {
                t.reveal(&e, e.handle(leaf)).unwrap();
                t.expand(&e, e.handle(dir), true).unwrap();
            } else {
                t.expand(&e, e.handle(dir), false).unwrap();
                t.expand(&e, e.handle(dir), false).unwrap();
            }
            let full = t.branches.capacity() * std::mem::size_of::<(u32, Branch)>()
                + t.branches
                    .values()
                    .map(Branch::payload_bytes)
                    .sum::<usize>();
            assert_eq!(t.expansion_payload_bytes(), full);
        }
    }
}
