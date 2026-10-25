#![cfg(target_os = "macos")]
use disk_map_bench::{Method, scan, snapshot};
use std::{
    ffi::OsString,
    fs::{self, File},
    io::{Seek, SeekFrom, Write},
    os::unix::{
        ffi::OsStringExt,
        fs::{MetadataExt, PermissionsExt, symlink},
    },
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture {
    base: PathBuf,
    root: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let base = PathBuf::from(format!(
            "/private/tmp/disk-map-bench-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&base).unwrap();
        let root = base.join("root");
        fs::create_dir(&root).unwrap();
        Self { base, root }
    }
    fn populate(&self) {
        for d in ["a", "z", "nested", "nested/deep", "empty-dir"] {
            fs::create_dir(self.root.join(d)).unwrap();
        }
        fs::write(self.root.join("z/owner"), vec![7u8; 8193]).unwrap();
        fs::hard_link(self.root.join("z/owner"), self.root.join("a/link")).unwrap();
        fs::hard_link(
            self.root.join("z/owner"),
            self.root.join("nested/deep/link"),
        )
        .unwrap();
        File::create(self.root.join("empty")).unwrap();
        fs::write(self.root.join("nested/small"), b"allocated, not logical").unwrap();
        let mut sparse = File::create(self.root.join("sparse")).unwrap();
        sparse.set_len(256 * 1024 * 1024).unwrap();
        sparse.seek(SeekFrom::Start(128 * 1024 * 1024)).unwrap();
        sparse.write_all(b"x").unwrap();
        fs::write(self.root.join("odd-雪-\n\t"), b"unusual filename bytes").unwrap();
        match fs::write(
            self.root
                .join(OsString::from_vec(b"odd-\xff-\xfe".to_vec())),
            b"raw filename bytes",
        ) {
            Ok(()) => {}
            Err(e) if e.raw_os_error() == Some(libc::EILSEQ) => eprintln!(
                "non-UTF8 filesystem fixture unavailable (EILSEQ); parser/snapshot byte tests cover it"
            ),
            Err(e) => panic!("non-UTF8 fixture: {e}"),
        }
        fs::write(self.base.join("outside"), vec![8; 16384]).unwrap();
        symlink(self.base.join("outside"), self.root.join("outside-link")).unwrap();
        symlink(&self.root, self.root.join("nested/cycle")).unwrap();
        symlink(self.base.join("missing"), self.root.join("broken")).unwrap();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.base).unwrap();
    }
}

#[test]
fn bulk_stat_and_workers_have_identical_canonical_allocations() {
    let fixture = Fixture::new();
    fixture.populate();
    let baseline = scan(&fixture.root, Method::Stat, 1).unwrap().map;
    assert_eq!(baseline.counters.errors, 0);
    assert_eq!(baseline.counters.symlinks, 3);
    let sparse = fs::metadata(fixture.root.join("sparse")).unwrap();
    assert!(sparse.blocks() * 512 < sparse.len());
    let rows = baseline.canonical();
    let owner = rows.iter().find(|r| r.0 == b"a/link").unwrap();
    assert_eq!(owner.2, owner.3);
    assert!(owner.3 > 0);
    for path in [b"z/owner".as_slice(), b"nested/deep/link"] {
        let row = rows.iter().find(|r| r.0 == path).unwrap();
        assert_eq!(row.3, 0);
        assert_eq!(row.2, owner.2);
    }
    for method in [Method::Bulk, Method::Stat] {
        for workers in [1, 4] {
            let map = scan(&fixture.root, method, workers).unwrap().map;
            assert_eq!(
                map.counters.errors, 0,
                "{method:?}: {:?}",
                map.error_samples
            );
            assert_eq!(map.counters.symlinks, 3);
            assert_eq!(map.canonical(), rows, "{method:?} workers={workers}");
        }
    }
    let path = fixture.base.join("map.bin");
    snapshot::save(&baseline, &path).unwrap();
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let loaded = snapshot::load(&path).unwrap();
    assert_eq!(loaded.root, baseline.root);
    assert_eq!(loaded.canonical(), rows);
    assert_eq!(loaded.counters, baseline.counters);
    snapshot::save(&loaded, &path).unwrap();
    let bytes = fs::read(&path).unwrap();
    for len in [0, 8, 103, bytes.len() / 2, bytes.len() - 1] {
        assert!(snapshot::decode(&bytes[..len]).is_err());
    }
    let mut bad = bytes;
    let middle = bad.len() / 2;
    bad[middle] ^= 0x80;
    assert!(snapshot::decode(&bad).is_err());
}

#[test]
fn resource_fork_allocation_matches_stat() {
    let fixture = Fixture::new();
    let path = fixture.root.join("forked");
    fs::write(&path, b"data").unwrap();
    // Named fork path uses macOS's supported filesystem API; only fixture data.
    fs::write(path.join("..namedfork/rsrc"), vec![9u8; 32768]).unwrap();
    let stat = scan(&fixture.root, Method::Stat, 1).unwrap().map;
    let bulk = scan(&fixture.root, Method::Bulk, 4).unwrap().map;
    assert_eq!(bulk.counters.errors, 0, "{:?}", bulk.error_samples);
    assert_eq!(bulk.canonical(), stat.canonical());
    assert!(
        bulk.nodes
            .iter()
            .find(|n| n.kind == disk_map_bench::Kind::File)
            .unwrap()
            .raw
            >= 32768
    );
}

#[test]
fn unreadable_directory_reports_partial_scan() {
    let fixture = Fixture::new();
    let denied = fixture.root.join("denied");
    fs::create_dir(&denied).unwrap();
    fs::write(denied.join("secret"), b"fixture").unwrap();
    fs::set_permissions(&denied, fs::Permissions::from_mode(0o0)).unwrap();
    let can_read = fs::read_dir(&denied).is_ok();
    let stat = scan(&fixture.root, Method::Stat, 1).unwrap().map;
    let bulk = scan(&fixture.root, Method::Bulk, 4).unwrap().map;
    fs::set_permissions(&denied, fs::Permissions::from_mode(0o700)).unwrap();
    if can_read {
        eprintln!("permission-denied assertion skipped: process can read mode-000 directory");
    } else {
        assert_eq!(stat.counters.errors, 1, "{:?}", stat.error_samples);
        assert_eq!(bulk.counters.errors, 1, "{:?}", bulk.error_samples);
        assert_eq!(stat.canonical(), bulk.canonical());
    }
}

#[test]
fn root_symlinks_are_rejected_and_empty_root_is_included() {
    let fixture = Fixture::new();
    let link = fixture.base.join("link");
    symlink(&fixture.root, &link).unwrap();
    for method in [Method::Bulk, Method::Stat] {
        assert!(scan(&link, method, 1).is_err());
        let map = scan(&fixture.root, method, 1).unwrap().map;
        assert_eq!(map.nodes.len(), 1);
        assert_eq!(
            map.nodes[0].subtree,
            fs::metadata(&fixture.root).unwrap().blocks() * 512
        );
    }
    assert!(scan(&fixture.root, Method::Bulk, 3).is_err());
}

#[test]
fn cli_snapshot_load_and_opt_in_inventory() {
    let fixture = Fixture::new();
    fixture.populate();
    let binary = env!("CARGO_BIN_EXE_disk-map-bench");
    let path = fixture.base.join("cli.bin");
    let output = std::process::Command::new(binary)
        .args(["--method", "bulk", "--workers", "4", "--root"])
        .arg(&fixture.root)
        .arg("--snapshot")
        .arg(&path)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert_eq!(stdout.lines().count(), 2);
    assert!(!stdout.contains("detail_relative"));
    let output = std::process::Command::new(binary)
        .arg("--load")
        .arg(&path)
        .args(["--queries", "--details"])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("file_by_raw"));
    assert!(stdout.contains("detail_relative_path_hex"));
}
