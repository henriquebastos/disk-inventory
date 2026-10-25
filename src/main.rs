use disk_map_bench::{Kind, Map, Method, hex, invalid, native, scan, snapshot};
use std::{
    io::{self, Write},
    os::unix::ffi::OsStrExt,
    path::PathBuf,
    time::{Duration, Instant},
};

fn usage() -> &'static str {
    "disk-map-bench --method bulk|stat --workers 1|2|4|8 --root ABSOLUTE_PATH [--snapshot PATH] [--details] [--queries]\n\
     disk-map-bench --load PATH [--details] [--queries]\n\
     TSV output; paths are raw-byte hex. --details prints the whole inventory (opt-in).\n\
     --queries prints ten largest root children and files. Partial scans report errors and exit 2."
}
#[derive(Default)]
struct Timings {
    scan: Duration,
    aggregate: Duration,
    snapshot: Duration,
    load: Duration,
    total: Duration,
}
fn report(
    map: &Map,
    method: &str,
    workers: usize,
    times: Timings,
    details: bool,
    queries: bool,
) -> io::Result<()> {
    let query_start = Instant::now();
    let query_ids = queries.then(|| [map.largest(true, 10), map.largest(false, 10)]);
    let query_time = if queries {
        query_start.elapsed()
    } else {
        Duration::ZERO
    };
    let mut out = io::BufWriter::new(io::stdout().lock());
    writeln!(
        out,
        "root_hex\tmethod\tworkers\tentries\tfiles\tdirs\tother\tskipped_symlinks\tskipped_mounts\tskipped_firmlinks\terrors\tduplicate_dirs\tallocated_bytes\tscan_ms\taggregation_ms\tsnapshot_ms\tload_ms\tquery_ms\ttotal_ms\tarena_capacity_bytes\tnode_bytes\tpeak_rss_bytes\tmetadata_fallbacks\troot_fstats\tdirectory_fstats"
    )?;
    let count = |kind| map.nodes.iter().filter(|n| n.kind == kind).count();
    let c = &map.counters;
    writeln!(
        out,
        "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{:.3}\t{:.3}\t{:.3}\t{:.3}\t{:.3}\t{:.3}\t{}\t{}\t{}\t{}\t{}\t{}",
        hex(map.root.as_os_str().as_bytes()),
        method,
        workers,
        map.nodes.len(),
        count(Kind::File),
        count(Kind::Dir),
        count(Kind::Other),
        c.symlinks,
        c.mounts,
        c.firmlinks,
        c.errors,
        c.duplicate_dirs,
        map.nodes[0].subtree,
        times.scan.as_secs_f64() * 1000.,
        times.aggregate.as_secs_f64() * 1000.,
        times.snapshot.as_secs_f64() * 1000.,
        times.load.as_secs_f64() * 1000.,
        query_time.as_secs_f64() * 1000.,
        (times.total + query_time).as_secs_f64() * 1000.,
        map.arena_bytes(),
        std::mem::size_of::<disk_map_bench::Node>(),
        native::peak_rss()?,
        c.metadata_fallbacks,
        c.root_fstats,
        c.directory_fstats
    )?;
    for sample in &map.error_samples {
        eprintln!("error_sample_path_hex\t{sample}");
    }
    if let Some(query_ids) = query_ids {
        writeln!(
            out,
            "query\trelative_path_hex\traw_bytes\taccounted_bytes\tsubtree_bytes"
        )?;
        for (children, ids) in [true, false].into_iter().zip(query_ids) {
            for id in ids {
                let n = &map.nodes[id];
                writeln!(
                    out,
                    "{}\t{}\t{}\t{}\t{}",
                    if children {
                        "root_child"
                    } else {
                        "file_by_raw"
                    },
                    hex(&map.relative_path(id)),
                    n.raw,
                    n.accounted,
                    n.subtree
                )?;
            }
        }
    }
    if details {
        writeln!(
            out,
            "detail_relative_path_hex\tkind\traw_bytes\taccounted_bytes\tsubtree_bytes"
        )?;
        for (path, kind, raw, accounted, subtree) in map.canonical() {
            writeln!(
                out,
                "{}\t{}\t{}\t{}\t{}",
                hex(&path),
                kind,
                raw,
                accounted,
                subtree
            )?;
        }
    }
    out.flush()
}
fn run() -> io::Result<bool> {
    let mut method = None;
    let mut workers = None;
    let mut root = None;
    let mut save = None;
    let mut load = None;
    let mut details = false;
    let mut queries = false;
    let mut args = std::env::args_os().skip(1);
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--help" | "-h") => {
                println!("{}", usage());
                return Ok(false);
            }
            Some("--details") => details = true,
            Some("--queries") => queries = true,
            Some("--method") if method.is_none() => {
                method = Some(match args.next().as_deref().and_then(|s| s.to_str()) {
                    Some("bulk") => Method::Bulk,
                    Some("stat") => Method::Stat,
                    _ => return Err(invalid("method must be bulk or stat")),
                });
            }
            Some("--workers") if workers.is_none() => {
                workers = Some(
                    args.next()
                        .and_then(|s| s.to_str().and_then(|s| s.parse::<usize>().ok()))
                        .ok_or_else(|| invalid("missing/invalid workers"))?,
                );
            }
            Some("--root") if root.is_none() => {
                root = Some(PathBuf::from(
                    args.next().ok_or_else(|| invalid("missing root"))?,
                ))
            }
            Some("--snapshot") if save.is_none() => {
                save = Some(PathBuf::from(
                    args.next()
                        .ok_or_else(|| invalid("missing snapshot path"))?,
                ))
            }
            Some("--load") if load.is_none() => {
                load = Some(PathBuf::from(
                    args.next().ok_or_else(|| invalid("missing load path"))?,
                ))
            }
            _ => return Err(invalid(usage())),
        }
    }
    let total = Instant::now();
    let map = if let Some(path) = load {
        if root.is_some() || method.is_some() || workers.is_some() || save.is_some() {
            return Err(invalid("--load cannot be combined with scan options"));
        }
        let begin = Instant::now();
        let map = snapshot::load(&path)?;
        let load_time = begin.elapsed();
        report(
            &map,
            "load",
            0,
            Timings {
                load: load_time,
                total: total.elapsed(),
                ..Timings::default()
            },
            details,
            queries,
        )?;
        map
    } else {
        let root = root.ok_or_else(|| invalid(usage()))?;
        let method = method.ok_or_else(|| invalid("--method required"))?;
        let workers = workers.ok_or_else(|| invalid("--workers required"))?;
        let scan = scan(&root, method, workers)?;
        let snapshot_time = if let Some(path) = save {
            let start = Instant::now();
            snapshot::save(&scan.map, &path)?;
            start.elapsed()
        } else {
            Duration::ZERO
        };
        report(
            &scan.map,
            method.name(),
            workers,
            Timings {
                scan: scan.scan_time,
                aggregate: scan.aggregation_time,
                snapshot: snapshot_time,
                total: total.elapsed(),
                ..Timings::default()
            },
            details,
            queries,
        )?;
        scan.map
    };
    Ok(map.counters.errors != 0)
}
fn main() {
    match run() {
        Ok(false) => {}
        Ok(true) => std::process::exit(2),
        Err(error) => {
            eprintln!("disk-map-bench: {error}");
            std::process::exit(1);
        }
    }
}
