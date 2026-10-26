use super::*;
use crate::{Counters, Entry, Map};
#[test]
fn million_file_diagram_respects_pixel_region_work_and_memory_envelopes() {
    let mut map = Map {
        root: "/native-free-diagram".into(),
        nodes: vec![],
        names: vec![],
        counters: Counters::default(),
        error_samples: vec![],
    };
    for id in 0..=1_000_000 {
        let name = if id == 0 {
            String::new()
        } else {
            format!("f-{id:07}.png")
        };
        map.add(
            0,
            name.as_bytes(),
            Entry {
                kind: if id == 0 { Kind::Dir } else { Kind::File },
                dev: 1,
                ino: id + 1,
                flags: 0,
                links: 1,
                allocation: Some(if id == 0 { 0 } else { 4096 }),
                mount: 0,
            },
        )
        .unwrap();
    }
    map.aggregate().unwrap();
    let e = Explorer::from_map(map).unwrap();
    let frame = e.diagram(e.root_handle(), 2000, 2000).unwrap();
    assert!(frame.stats.tiles + frame.stats.groups <= MAX_REGIONS);
    assert_eq!(frame.stats.pixels, MAX_PIXELS);
    assert!(frame.stats.child_visits <= 2 * MAX_REGIONS);
    assert_eq!(
        frame.layout.tiles.iter().map(|t| t.bytes).sum::<u64>(),
        4_096_000_000
    );
    assert!(frame.stats.retained_payload_bytes < 200_000_000);
    assert!(
        frame.stats.aggregate_pixels > 0,
        "region limit must remain observable"
    );
    assert!(frame.owners.iter().all(|&owner| owner != 0));
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::uninit();
    assert_eq!(
        unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) },
        0
    );
    let rss = unsafe { usage.assume_init() }.ru_maxrss as u64
        * if cfg!(target_os = "macos") { 1 } else { 1024 };
    println!(
        "MILLION_DIAGRAM regions={} visits={} retained_payload={} surface_payload={} layout_us={} raster_us={} aggregate_pixels={} process_peak_rss_bytes={rss}; core only, excludes Swift/FFI/display",
        frame.stats.tiles + frame.stats.groups,
        frame.stats.child_visits,
        frame.stats.retained_payload_bytes,
        frame.stats.surface_payload_bytes,
        frame.stats.layout_micros,
        frame.stats.raster_micros,
        frame.stats.aggregate_pixels
    );
}
