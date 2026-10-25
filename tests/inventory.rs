#![cfg(target_os = "macos")]
use disk_map_bench::{
    Kind, Method, Node,
    export::{self, Format},
    hex,
    inventory::{IncompleteSync, Inventory, ScanOptions},
    scan, snapshot,
};
use std::{
    fs,
    io::{self, Write},
    os::unix::fs::{PermissionsExt, symlink},
    path::{Path, PathBuf},
    process::{Command, Output, Stdio},
    sync::atomic::{AtomicU64, Ordering},
};

static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture {
    base: PathBuf,
    root: PathBuf,
    snapshot: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let base = PathBuf::from(format!(
            "/private/tmp/disk-inventory-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&base).unwrap();
        let root = base.join("root");
        fs::create_dir(&root).unwrap();
        let snapshot = base.join("map.bin");
        Self {
            base,
            root,
            snapshot,
        }
    }
    fn create(&self) -> Inventory {
        Inventory::create(&self.root, &self.snapshot, ScanOptions::default()).unwrap()
    }
    fn cli(&self, command: &str, flags: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_disk-inventory"))
            .arg(command)
            .arg(&self.snapshot)
            .args(flags)
            .output()
            .unwrap()
    }
    // Synthetic names guarantee non-UTF8 coverage even on APFS which rejects such names.
    fn synthetic(&self, names: &[Vec<u8>], partial: bool) -> Inventory {
        let mut map = scan(&self.root, Method::Bulk, 1).unwrap().map;
        for name in names {
            map.nodes.push(Node {
                parent: 0,
                name_len: name.len() as u32,
                name_offset: map.names.len() as u64,
                dev: map.nodes[0].dev,
                ino: map.nodes.len() as u64 + 100,
                raw: 8192,
                accounted: 8192,
                subtree: 8192,
                links: 1,
                kind: Kind::File,
            });
            map.names.extend(name);
        }
        map.counters.errors = u64::from(partial);
        map.aggregate().unwrap();
        snapshot::save(&map, &self.snapshot).unwrap();
        Inventory::open(&self.snapshot).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.base).unwrap();
    }
}
fn success(output: &Output) {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(output.stderr.is_empty());
}
fn exported(inventory: &Inventory, format: Format) -> Vec<u8> {
    let mut bytes = Vec::new();
    export::export(inventory, format, &mut bytes).unwrap();
    bytes
}

#[test]
fn core_lifecycle_and_hardlink_accounting() {
    let f = Fixture::new();
    fs::write(f.root.join("z"), vec![1; 8193]).unwrap();
    fs::hard_link(f.root.join("z"), f.root.join("a")).unwrap();
    let inventory = f.create();
    assert_eq!(inventory.root(), f.root);
    assert_eq!(inventory.len(), 3);
    assert!(!inventory.is_empty());
    assert!(!inventory.is_partial());
    assert!(inventory.entry(3).is_none());
    let entries: Vec<_> = inventory.entries().collect();
    assert_eq!(entries[0].relative_path, b"");
    let owner = entries.iter().find(|e| e.relative_path == b"a").unwrap();
    let alias = entries.iter().find(|e| e.relative_path == b"z").unwrap();
    assert!(owner.allocated_bytes > 0);
    assert_eq!(owner.allocated_bytes, owner.accounted_bytes);
    assert_eq!(alias.allocated_bytes, owner.allocated_bytes);
    assert_eq!(alias.accounted_bytes, 0);
    assert_eq!(
        inventory.subtree_bytes(),
        entries.iter().map(|e| e.accounted_bytes).sum()
    );
    assert_eq!(
        fs::metadata(&f.snapshot).unwrap().permissions().mode() & 0o777,
        0o600
    );
    fs::remove_file(f.root.join("a")).unwrap();
    fs::write(f.root.join("new"), b"new data").unwrap();
    assert_eq!(
        Inventory::open(&f.snapshot)
            .unwrap()
            .entries()
            .collect::<Vec<_>>(),
        entries
    );
    let updated = Inventory::sync(&f.snapshot, ScanOptions { workers: 2 }).unwrap();
    assert!(!updated.entries().any(|e| e.relative_path == b"a"));
    assert!(updated.entries().any(|e| e.relative_path == b"new"));
    let z = updated.entries().find(|e| e.relative_path == b"z").unwrap();
    assert_eq!(z.accounted_bytes, z.allocated_bytes);
    fs::rename(&f.root, f.base.join("renamed")).unwrap();
    let saved = Inventory::open(&f.snapshot).unwrap();
    assert_eq!(
        saved.entries().collect::<Vec<_>>(),
        updated.entries().collect::<Vec<_>>()
    );
    assert_eq!(
        exported(&saved, Format::Csv),
        exported(&updated, Format::Csv)
    );
}

#[test]
fn create_no_clobber_and_destination_safety() {
    let f = Fixture::new();
    fs::write(&f.snapshot, b"old bytes").unwrap();
    let error = Inventory::create(&f.root, &f.snapshot, ScanOptions::default()).unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::AlreadyExists);
    assert_eq!(fs::read(&f.snapshot).unwrap(), b"old bytes");
    let map = scan(&f.root, Method::Bulk, 1).unwrap().map;
    assert_eq!(
        snapshot::save_new(&map, &f.snapshot).unwrap_err().kind(),
        io::ErrorKind::AlreadyExists
    );
    assert_eq!(fs::read(&f.snapshot).unwrap(), b"old bytes");
    let alias = f.base.join("alias");
    symlink(&f.root, &alias).unwrap();
    for output in [f.root.join("map"), alias.join("map")] {
        let error = Inventory::create(&f.root, &output, ScanOptions::default()).unwrap_err();
        assert!(error.to_string().contains("outside"));
        assert!(!output.exists());
    }
    assert!(Inventory::create(&alias, &f.base.join("new"), ScanOptions::default()).is_err());
    let inside = f.root.join("legacy-map");
    snapshot::save(&map, &inside).unwrap();
    let old = fs::read(&inside).unwrap();
    assert!(
        Inventory::sync(&inside, ScanOptions::default())
            .unwrap_err()
            .to_string()
            .contains("outside")
    );
    assert_eq!(fs::read(&inside).unwrap(), old);
    let link = f.base.join("map-link");
    symlink(&f.snapshot, &link).unwrap();
    assert!(snapshot::save_new(&map, &link).is_err());
    assert_eq!(fs::read(&f.snapshot).unwrap(), b"old bytes");
    assert_eq!(fs::read_dir(&f.base).unwrap().count(), 4); // No leaked publication temporaries.
}

#[test]
fn cli_create_info_export_sync_and_missing_root() {
    let f = Fixture::new();
    fs::write(f.root.join("first"), b"fixture").unwrap();
    let create = Command::new(env!("CARGO_BIN_EXE_disk-inventory"))
        .arg("create")
        .arg(&f.root)
        .arg("--output")
        .arg(&f.snapshot)
        .output()
        .unwrap();
    success(&create);
    assert_eq!(create.stdout.iter().filter(|&&b| b == b'\n').count(), 1);
    assert!(create.stdout.starts_with(b"{\"root\":"));
    let info = f.cli("info", &[]);
    success(&info);
    assert_eq!(create.stdout, info.stdout);
    let old = fs::read(&f.snapshot).unwrap();
    let duplicate = Command::new(env!("CARGO_BIN_EXE_disk-inventory"))
        .arg("create")
        .arg(&f.root)
        .arg("--output")
        .arg(&f.snapshot)
        .output()
        .unwrap();
    assert_eq!(duplicate.status.code(), Some(1));
    assert!(duplicate.stdout.is_empty());
    assert_eq!(fs::read(&f.snapshot).unwrap(), old);
    let inventory = Inventory::open(&f.snapshot).unwrap();
    for (name, format) in [
        ("csv", Format::Csv),
        ("jsonl", Format::Jsonl),
        ("tsv", Format::Tsv),
    ] {
        let result = f.cli("export", &["--format", name]);
        success(&result);
        assert_eq!(result.stdout, exported(&inventory, format));
    }
    fs::remove_file(f.root.join("first")).unwrap();
    fs::write(f.root.join("second"), vec![4; 16384]).unwrap();
    assert_eq!(f.cli("info", &[]).stdout, info.stdout);
    let sync = f.cli("sync", &["--workers", "1"]);
    success(&sync);
    assert_eq!(sync.stdout, f.cli("info", &[]).stdout);
    assert!(
        Inventory::open(&f.snapshot)
            .unwrap()
            .entries()
            .any(|e| e.relative_path == b"second")
    );
    let before = f.cli("export", &["--format", "jsonl"]);
    let bytes = fs::read(&f.snapshot).unwrap();
    fs::rename(&f.root, f.base.join("missing")).unwrap();
    let after = f.cli("export", &["--format", "jsonl"]);
    success(&after);
    assert_eq!(before.stdout, after.stdout);
    success(&f.cli("info", &[]));
    let failed = f.cli("sync", &[]);
    assert_eq!(failed.status.code(), Some(1));
    assert!(failed.stdout.is_empty());
    assert!(!failed.stderr.is_empty());
    assert_eq!(fs::read(&f.snapshot).unwrap(), bytes);
}

#[test]
fn partial_sync_preserves_old_bytes_and_creation_reports_partial() {
    let f = Fixture::new();
    let denied = f.root.join("denied");
    fs::create_dir(&denied).unwrap();
    fs::write(denied.join("secret"), b"fixture").unwrap();
    f.create();
    let old = fs::read(&f.snapshot).unwrap();
    fs::set_permissions(&denied, fs::Permissions::from_mode(0o0)).unwrap();
    if fs::read_dir(&denied).is_ok() {
        fs::set_permissions(&denied, fs::Permissions::from_mode(0o700)).unwrap();
        eprintln!("permission assertions skipped: process can read mode-000 directory");
        return;
    }
    let result = Inventory::sync(&f.snapshot, ScanOptions::default());
    let cli_sync = f.cli("sync", &[]);
    let partial_path = f.base.join("partial.bin");
    let partial = Inventory::create(&f.root, &partial_path, ScanOptions::default());
    let cli_partial = f.base.join("cli-partial.bin");
    let cli_create = Command::new(env!("CARGO_BIN_EXE_disk-inventory"))
        .arg("create")
        .arg(&f.root)
        .arg("--output")
        .arg(&cli_partial)
        .output()
        .unwrap();
    fs::set_permissions(&denied, fs::Permissions::from_mode(0o700)).unwrap();
    let error = result.unwrap_err();
    assert!(error.get_ref().unwrap().is::<IncompleteSync>());
    assert_eq!(cli_sync.status.code(), Some(2));
    assert!(cli_sync.stdout.is_empty());
    assert!(String::from_utf8_lossy(&cli_sync.stderr).contains("unchanged"));
    assert_eq!(fs::read(&f.snapshot).unwrap(), old);
    assert!(partial.unwrap().is_partial());
    assert_eq!(cli_create.status.code(), Some(2));
    assert!(cli_create.stdout.starts_with(b"{"));
    assert!(String::from_utf8_lossy(&cli_create.stderr).contains("partial"));
    assert!(Inventory::open(&cli_partial).unwrap().is_partial());
    assert!(
        !Inventory::sync(&partial_path, ScanOptions::default())
            .unwrap()
            .is_partial()
    );
}

#[test]
fn partial_saved_reads_preserve_status_and_data_without_root() {
    let f = Fixture::new();
    let inventory = f.synthetic(&[b"saved".to_vec()], true);
    fs::rename(&f.root, f.base.join("renamed")).unwrap();
    let info = f.cli("info", &[]);
    assert_eq!(info.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&info.stdout).contains("\"partial\":true"));
    assert!(String::from_utf8_lossy(&info.stderr).contains("warning"));
    for (name, format) in [
        ("csv", Format::Csv),
        ("jsonl", Format::Jsonl),
        ("tsv", Format::Tsv),
    ] {
        let result = f.cli("export", &["--format", name]);
        assert_eq!(result.status.code(), Some(2));
        assert!(String::from_utf8_lossy(&result.stderr).contains("warning"));
        assert_eq!(result.stdout, exported(&inventory, format));
    }
}

#[test]
fn invalid_cli_arguments_fail_before_scanning() {
    let f = Fixture::new();
    let binary = env!("CARGO_BIN_EXE_disk-inventory");
    for flags in [
        vec!["--workers", "3"],
        vec!["--workers", "4", "--workers", "4"],
        vec!["--output", "duplicate"],
        vec!["--query", "x"],
        vec!["--workers"],
    ] {
        let result = Command::new(binary)
            .arg("create")
            .arg(f.base.join("nonexistent"))
            .arg("--output")
            .arg(&f.snapshot)
            .args(flags)
            .output()
            .unwrap();
        assert_eq!(result.status.code(), Some(1));
        assert!(result.stdout.is_empty());
        let error = String::from_utf8_lossy(&result.stderr);
        assert!(
            error.contains("workers") || error.contains("argument"),
            "{error}"
        );
        assert!(!f.snapshot.exists());
    }
    for args in [
        vec![],
        vec!["query"],
        vec!["create", "x"],
        vec!["info", "missing", "--workers", "4"],
        vec!["export", "missing"],
        vec!["export", "missing", "--format", "bad"],
        vec!["export", "missing", "--format", "csv", "--format", "tsv"],
        vec!["sync", "missing", "--output", "x"],
    ] {
        let result = Command::new(binary).args(args).output().unwrap();
        assert_eq!(result.status.code(), Some(1));
        assert!(result.stdout.is_empty());
        assert!(!String::from_utf8_lossy(&result.stderr).contains("os error"));
    }
    let help = Command::new(binary).arg("--help").output().unwrap();
    assert!(help.status.success());
    assert!(help.stdout.is_empty());
    assert!(String::from_utf8_lossy(&help.stderr).contains("create"));
}

#[test]
fn export_broken_pipe_is_quiet_and_streaming_errors_propagate() {
    let f = Fixture::new();
    let names: Vec<_> = (0..4096)
        .map(|i| format!("entry-{i:06}").into_bytes())
        .collect();
    let inventory = f.synthetic(&names, false);
    for format in ["csv", "jsonl", "tsv"] {
        let mut child = Command::new(env!("CARGO_BIN_EXE_disk-inventory"))
            .arg("export")
            .arg(&f.snapshot)
            .args(["--format", format])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        drop(child.stdout.take());
        let output = child.wait_with_output().unwrap();
        success(&output);
    }
    struct Refuse;
    impl Write for Refuse {
        fn write(&mut self, _: &[u8]) -> io::Result<usize> {
            Err(io::Error::new(io::ErrorKind::BrokenPipe, "test"))
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    for format in [Format::Csv, Format::Jsonl, Format::Tsv] {
        assert_eq!(
            export::export(&inventory, format, Refuse)
                .unwrap_err()
                .kind(),
            io::ErrorKind::BrokenPipe
        );
    }
}

#[test]
fn export_encoders_round_trip_and_sqlite_typed_import() {
    let f = Fixture::new();
    let names = vec![
        "雪-café-😀,\"quoted\"\\back\tline\nreturn\r-end"
            .as_bytes()
            .to_vec(),
        b"raw-\xff-\xfe\n\t\"\\,".to_vec(),
        b"control-\x01\x0b\x1f".to_vec(),
        b"=formula".to_vec(),
        "decomposed-e\u{301}".as_bytes().to_vec(),
    ];
    let inventory = f.synthetic(&names, false);
    for (name, format) in [
        ("csv", Format::Csv),
        ("jsonl", Format::Jsonl),
        ("tsv", Format::Tsv),
    ] {
        fs::write(
            f.base.join(format!("rows.{name}")),
            exported(&inventory, format),
        )
        .unwrap();
    }
    let expected = inventory
        .entries()
        .map(|e| format!("{}\n", hex(&e.relative_path)))
        .collect::<String>();
    fs::write(f.base.join("expected-hex"), expected).unwrap();
    let check = Command::new("python3")
        .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/export_roundtrip.py"))
        .arg(&f.base)
        .output()
        .expect("python3 is required for independent CSV/JSON parser validation");
    success(&check);
    let script = format!(
        ".bail on\nCREATE TABLE entries(path TEXT, path_hex TEXT, kind TEXT, allocated_bytes INTEGER, accounted_bytes INTEGER, subtree_bytes INTEGER);\n.mode csv\n.import --skip 1 {} entries\nSELECT count(*), sum(accounted_bytes), sum(typeof(allocated_bytes) != 'integer' OR typeof(accounted_bytes) != 'integer' OR typeof(subtree_bytes) != 'integer') FROM entries;\nSELECT sum(accounted_bytes) FROM entries WHERE kind = 'file';\nSELECT hex(path) FROM entries ORDER BY rowid;\n",
        f.base.join("rows.csv").display()
    );
    let mut child = Command::new("sqlite3")
        .arg(":memory:")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("sqlite3 CLI is required for real CSV import validation");
    child
        .stdin
        .take()
        .unwrap()
        .write_all(script.as_bytes())
        .unwrap();
    let result = child.wait_with_output().unwrap();
    success(&result);
    let expected = format!(
        "{},{},0\n{}\n{}",
        inventory.len(),
        inventory.subtree_bytes(),
        names.len() * 8192,
        inventory
            .entries()
            .map(|e| {
                let human = String::from_utf8_lossy(&e.relative_path);
                let h = hex(human.as_bytes()).to_uppercase();
                format!("{}\n", if h.is_empty() { "\"\"" } else { &h })
            })
            .collect::<String>()
    );
    assert_eq!(String::from_utf8(result.stdout).unwrap(), expected);
}

#[test]
fn cli_csv_pipes_into_sqlite_without_source_tree() {
    let f = Fixture::new();
    let inventory = f.synthetic(
        &[b"comma,quote\"line\n".to_vec(), b"raw-\xff".to_vec()],
        false,
    );
    fs::rename(&f.root, f.base.join("source-unavailable")).unwrap();
    let mut exporter = Command::new(env!("CARGO_BIN_EXE_disk-inventory"))
        .arg("export")
        .arg(&f.snapshot)
        .args(["--format", "csv"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let result = Command::new("sqlite3")
        .args([
            "-bail",
            "-csv",
            ":memory:",
            "CREATE TABLE entries(path TEXT, path_hex TEXT, kind TEXT, allocated_bytes INTEGER, accounted_bytes INTEGER, subtree_bytes INTEGER);",
            ".import --csv --skip 1 /dev/stdin entries",
            "SELECT count(*),sum(accounted_bytes),sum(typeof(allocated_bytes)!='integer') FROM entries;",
            "SELECT path_hex FROM entries WHERE kind='file' ORDER BY path_hex;",
        ])
        .stdin(Stdio::from(exporter.stdout.take().unwrap()))
        .output()
        .expect("sqlite3 CLI is required for the direct pipe test");
    success(&exporter.wait_with_output().unwrap());
    success(&result);
    assert_eq!(
        String::from_utf8(result.stdout).unwrap(),
        format!(
            "{},{},0\n{}\n{}\n",
            inventory.len(),
            inventory.subtree_bytes(),
            hex(b"comma,quote\"line\n"),
            hex(b"raw-\xff"),
        )
    );
}
