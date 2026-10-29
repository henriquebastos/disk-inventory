# 1 Disk Inventory

A macOS allocated-storage inventory with a reusable Rust core and a small CLI:
**create, sync, info, export**. Scan once, then use saved data with external tools
such as jq, sort or SQLite. There is no filtering or sorting language. The CLI never
deletes source files. The reusable [operation session](docs/operations.md)
adds explicitly confirmed Trash/removal and local refresh for native clients.
The optional [generated Swift bridge](docs/bridge.md) exposes owned sessions and
bounded views, with native-free fixture scenarios. The [native explorer](docs/native-explorer.md)
adds a SwiftUI/AppKit table, treemap, compact selection summary and explicitly confirmed
operations. No source-file contents are read.

Opening a snapshot eagerly reads and validates the entire file, reconstructs its
arrays and recomputes accounting. Export streams entries from that in-memory map;
it does not sort or materialize all export rows. This is not mmap or lazy loading.

## 1a Build and use

Requirements: macOS, Apple SDK and Rust. Native dependencies are pinned in
[Cargo.toml](Cargo.toml): libc and minimal objc2/Foundation bindings. Tests also use
Python 3 and the system sqlite3 CLI as independent
export parsers; Node.js runs the benchmark helpers.

```sh
export CARGO_TARGET_DIR=/private/tmp/disk-inventory-target
cargo build --release --offline --locked
BIN="$CARGO_TARGET_DIR/release/disk-inventory"
RUN=$(mktemp -d /private/tmp/disk-inventory.XXXXXX)
mkdir "$RUN/tree"
printf 'fixture\n' > "$RUN/tree/example"
"$BIN" create "$RUN/tree" --output "$RUN/map.bin"
"$BIN" info "$RUN/map.bin"
"$BIN" export "$RUN/map.bin" --format jsonl
"$BIN" sync "$RUN/map.bin" --workers 4
```

Choose an explicit scope before scanning real data. Roots must be absolute, without
symlink components; use `/private/tmp`, not `/tmp`. Symlinks in the tree are excluded.
Native bulk collection defaults to four workers; `create` and `sync` accept
`--workers 1|2|4|8`. Unknown, duplicate and misplaced flags are errors.

`create` requires a new output file. `sync` rescans the whole original root and
atomically replaces the existing snapshot only after a complete scan. Fatal or
partial scans preserve the old bytes. The output may be inside the root, including
through parent-directory aliases. Create scans before publishing; sync omits the
current snapshot's regular-file identity and all its hardlink aliases. Its own file
allocation is omitted, but directory allocation remains observed. Other files,
including older snapshot generations retained by hardlinks, count normally.
Lifecycle writes reject destination symlinks. Use a trusted snapshot directory;
concurrent namespace changes and sync writers are not serialized. There is no
targeted CLI sync or automatic refresh.

For the macOS Data volume, with the snapshot in your home directory:

```sh
"$BIN" create /System/Volumes/Data --output "$HOME/map.dmap"
"$BIN" sync "$HOME/map.dmap"
```

Collection stays on one device and excludes discovered mounts (bulk also excludes
firmlinks). Scanning `/` does **not** inventory all volumes. Permission errors can
produce a partial map; the tool does not elevate privileges.

`info` and `export` never check or refresh the source tree: they work even if it
has been renamed or removed. `create`, `sync` and `info` emit one JSON summary;
`export` emits only rows. Diagnostics and help go to stderr. Closed output pipes
are quiet. Exit status: **0** complete, **2** partial, **1** fatal. Creation may save
a partial map; reading it still produces data with status 2 and a stderr warning.
A partial sync emits a warning/error and status 2 without replacing the old map.

## 1b Export contract

```sh
"$BIN" export "$RUN/map.bin" --format csv > "$RUN/entries.csv"
"$BIN" export "$RUN/map.bin" --format tsv > "$RUN/entries.tsv"
```

All formats have the same fields in this order:

| Field | Meaning |
|---|---|
| `path` | Human UTF-8 relative path; invalid bytes become U+FFFD |
| `path_hex` | Lossless lowercase hex of raw relative path bytes |
| `kind` | `file`, `directory`, or `other` |
| `allocated_bytes` | Raw allocated bytes, including hardlink aliases |
| `accounted_bytes` | Deduplicated allocation attributed to this entry |
| `subtree_bytes` | Attributed allocation including descendants |

The root entry's relative path is empty. The absolute root and its lossless
`root_hex` are in `info`. Unicode is not normalized by export. Use `path_hex`, not
the human field, for byte-exact identity. Rows are in snapshot order, not sorted;
order can change after sync. Totals are allocation, not guaranteed reclaimable space.

CSV and TSV **always include a header**. CSV quotes human paths and doubles embedded
quotes; records can span physical lines. TSV escapes backslash as `\\`, tab as
`\t`, LF as `\n`, CR as `\r`, giving one physical line per record; decode escapes
left-to-right. JSONL has no header, one JSON object per line and numeric byte fields.
CSV preserves formula-like filenames verbatim; don't treat untrusted names as spreadsheet formulas.

Real SQLite import with explicitly typed numeric columns (no SQLite in the core):

```sh
set -o pipefail
"$BIN" export "$RUN/map.bin" --format csv |
  sqlite3 -bail "$RUN/inventory.sqlite" \
    'CREATE TABLE entries(path TEXT, path_hex TEXT, kind TEXT,
      allocated_bytes INTEGER, accounted_bytes INTEGER, subtree_bytes INTEGER);' \
    '.import --csv --skip 1 /dev/stdin entries'
sqlite3 "$RUN/inventory.sqlite" \
  "SELECT path, allocated_bytes FROM entries WHERE kind='file'
   ORDER BY allocated_bytes DESC LIMIT 20;"
```

Use a new database for this example. `pipefail` preserves export failures and partial
status even if SQLite succeeds; it does not undo an import. The typed import,
numeric aggregation and direct pipe with an unavailable source tree are tested in
[tests/inventory.rs](tests/inventory.rs).

## 1c Reuse and verify

The library crate remains `disk_map_bench` for compatibility.
[Inventory](src/inventory.rs) exposes `create`, `open`, full-root `sync`, `root`,
`counters`, `is_partial`, `entry` and `entries`. `SavedEntry` has raw relative path
bytes, typed `Kind` and all three byte counts. `ScanOptions::default()` uses four
workers. Partial sync returns an `io::Error` containing typed `IncompleteSync`.
The core has no stdout, stderr or exit handling. [Export encoders](src/export.rs)
accept any `std::io::Write`; GUI clients can use typed entries directly.

```sh
cargo fmt --check
cargo test --offline --locked
cargo clippy --offline --locked --all-targets -- -D warnings
```

The unchanged `disk-map-bench` binary retains bulk/stat experiments and opt-in
`--queries`/`--details`; these are not part of the new inventory interface.

```sh
node scripts/run-benchmark.mjs "$CARGO_TARGET_DIR/release/disk-map-bench" \
  "$RUN/tree" "$RUN/benchmark"
```

The helper alternates three samples per method/worker count, verifies accounting,
and measures persistence/reload without purging caches. Keep results outside Git.
[make-fixture.mjs](scripts/make-fixture.mjs) builds a larger owned fixture.

See [the specification](docs/spec.md) for accounting, safety limits and test
citations; [AGENTS.md](AGENTS.md) for contributor navigation. Collection is in
[src/lib.rs](src/lib.rs), native parsing in [src/native.rs](src/native.rs), persistence
in [src/snapshot.rs](src/snapshot.rs), and the thin CLI in
[src/bin/disk-inventory.rs](src/bin/disk-inventory.rs).

## 1d Checks and test layers

[check.sh](scripts/check.sh) runs the checks in named stages, stops at the first failure and
prints one summary line with the time of each stage:

```sh
export CHECK_ROOT=/private/tmp/disk-inventory-check  # all outputs, outside the repository
scripts/check.sh fast   # format, Clippy x3, Rust tests, swift-format, docs, git diff --check
scripts/check.sh model  # fast, GUI build and app icon check, bridge smoke, model tests
scripts/check.sh ui -only-testing:ExplorerUITests/ExplorerUITests/testSiblingRowsStayVisibleAfterDeleteWithSkipsDeleteAndTrash
scripts/check.sh all    # model, then every UI test
```

`CARGO_TARGET_DIR` and `GUI_ROOT` default below `CHECK_ROOT`; `TMPDIR` must also be outside the
repository. It refuses to run with less than 1.5 GB free. The docs stage
([check-docs.py](scripts/check-docs.py)) keeps each Markdown document below 1,500 words with
resolving links and existing quoted test names. UI tests need an unlocked console; they run one
at a time through [test-gui.sh](scripts/test-gui.sh), and result bundles are deleted after the
summary is read.

Test each change in the cheapest layer that can fail when the behavior changes:

1. Rust: domain, accounting and diagram pixels. [map_pixels.rs](src/bridge/tests/map_pixels.rs)
   measures the fixture maps at window size.
2. Model tests in `native/ExplorerModelTests`: texts, enablement, phases and outcomes. They wait
   with `waitUntil`, which re-checks when an observed model property changes, or `pollUntil`
   for Rust bridge and AppKit view state ([ModelWait.swift](native/ExplorerModelTests/ModelWait.swift)).
3. Component pictures drawn offscreen, such as
   [MapDrawingModelTests.swift](native/ExplorerModelTests/MapDrawingModelTests.swift).
4. XCUITests only for real input (mouse, keyboard, menus, sheets, help tags), window-level
   layout and rendering, and end-to-end flows.

A UI assertion moves only with a replacement that fails on a deliberately broken variant.
