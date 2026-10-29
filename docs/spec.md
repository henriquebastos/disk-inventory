# 1 Inventory specification

Disk Inventory records allocated storage, not logical length or guaranteed
reclaimable space. [Collection](../src/lib.rs) and [native parsing](../src/native.rs)
retain the benchmark's accounting. [Inventory](../src/inventory.rs) provides the
saved-data lifecycle; [encoders](../src/export.rs) produce external-tool input.

## 1a Collection and accounting

Bulk collection batches macOS metadata through `getattrlistbulk`. The benchmark's
stat walker uses `st_blocks * 512`. Both share scheduling and accounting. The new
lifecycle uses bulk only, with 1, 2, 4 or 8 workers (default 4). Symlinks are excluded
entirely. Directory allocation, including the root, contributes to totals.

Regular-file hardlinks share `(device, inode)`. The smallest raw relative path
receives allocation once. Aliases retain raw allocation but have zero accounted
bytes. Parent IDs precede children; a reverse pass aggregates subtree totals.

A hardlinked file can change between the stats of two of its links. The scan then
counts a path error, so the result is partial (CLI exit 2), and gives every link the
first allocation that it read. A saved snapshot with conflicting sizes in a hardlink
group is corrupt, and loading it fails. Tests:
[src/lib.rs](../src/lib.rs)
"hardlink_allocation_change_during_scan_is_a_path_error_in_a_saved_partial_result" and
[src/snapshot.rs](../src/snapshot.rs) "snapshot_rejects_conflicting_hardlink_allocation".

[tests/accounting.rs](../tests/accounting.rs):

- "bulk_stat_and_workers_have_identical_canonical_allocations": bulk/stat and
  one/four workers agree; sparse allocation differs from length, hardlinks have one
  owner, outside/dangling/cyclic symlinks are excluded.
- "resource_fork_allocation_matches_stat": data/resource fork accounting agrees.
- "root_symlinks_are_rejected_and_empty_root_is_included": root policy and allocation.
- "unreadable_directory_reports_partial_scan": unreadable directories are errors.
  Permission assertions skip if the process can read the mode-000 fixture.

Native records validate masks, lengths and names before access. Missing required
fields are errors. Missing directory allocation permits a counted, identity-checked
stat fallback, not silent stat traversal. [src/native.rs](../src/native.rs) tests:
"bulk_parser_rejects_truncation_and_malformed_fields",
"bulk_parser_requires_mount_status_but_allows_directory_allocation_fallback", and
"bulk_parser_preserves_non_utf8_bytes".

## 1b Saved lifecycle and publication

The core's `Inventory::create(root, output, options)`, `open(file)` and
`sync(file, options)` return typed saved data without output or process control.
`entry(index)` and `entries()` expose `SavedEntry` with raw relative path bytes,
`Kind`, `allocated_bytes`, `accounted_bytes`, and `subtree_bytes`. The empty path is
the root; `root()` is absolute. Access is snapshot order, not canonical ordering.

The opt-in `Inventory::create_controlled` adds sampled metadata progress and
cooperative Stop without changing snapshot bytes or defaults. Its atomic publication
boundary, generated API and source-named regression tests are specified in
[scan-control.md](scan-control.md). It still requires a new destination.

`create` saves even partial results; `is_partial()` and `counters()` expose that
state. `sync` reopens the saved map and rescans only its full original root. Fatal
or partial scans do not publish. Partial sync returns an `io::Error` containing
`IncompleteSync` with counters. Output may be inside the source root, including
through parent aliases. Create scans before publication. Sync opens the destination
without following its symlink, loads its root and regular-file identity from that
same open file, and pins it throughout collection to prevent inode reuse. Both
collectors can internally omit that identity before arena insertion/accounting;
the public `scan` remains unfiltered. All current-snapshot hardlinks are omitted,
not names or directories. Directory allocation stays observed. Unrelated maps and
older generations retained by hardlinks count normally on later scans. A saved map
moved/copied inside its root can sync. Destination symlinks are rejected for lifecycle
writes; root symlink policy is unchanged. Snapshot parents must already exist.

[src/snapshot.rs](../src/snapshot.rs) stores explicit little-endian fields. Saving
uses a same-directory mode-0600 temporary file, flush/fsync, atomic publication and
parent fsync. Create uses a no-clobber hard link, so even a concurrently created
destination is not replaced; sync uses rename. Only implementation-owned temporary
files are removed. Publication or parent-fsync failures after publication may report
an error even though the new snapshot is visible. Snapshot directories must be
trusted: concurrent namespace changes and concurrent sync writers are not serialized.

Loading eagerly reads the entire snapshot, validates checksum and structure,
reconstructs arrays, and recomputes accounting. It never checks source paths. There
is no mmap, automatic refresh or targeted CLI sync. Typed entry access and export work
with a missing root. Export allocates one row/path at a time on top of the loaded map.

[tests/inventory.rs](../tests/inventory.rs):

- "core_lifecycle_and_hardlink_accounting": API use without a CLI, hardlink ownership,
  mode 0600, saved reads ignoring mutations, explicit sync and missing-root reads.
- "create_no_clobber_and_destination_safety": existing bytes and symlinks survive
  no-clobber publication; symlink roots and destination symlinks are rejected.
- "in_root_create_and_repeated_sync_omit_snapshot_from_entries_and_totals": in-root
  creation/repeated sync omit self from typed entries, exports and totals; public
  bulk/stat scans remain unfiltered.
- "aliased_parent_and_current_snapshot_hardlinks_exclude_only_current_identity":
  aliased parent works; current hardlinks are omitted, unrelated snapshot-looking
  files and old-generation hardlinks count with deduplication.
- "legacy_snapshot_moved_or_copied_inside_root_can_sync": version-1 compatibility.
- "partial_sync_preserves_old_bytes_and_creation_reports_partial": core/CLI partial
  sync preserves in-root bytes; partial creation and later complete sync. Permission
  assertions conditionally skip for privileged processes.
- "cli_create_info_export_sync_and_missing_root": command lifecycle, data-only stdout,
  unchanged reads until sync, missing-root export and fatal-sync in-root byte preservation.

[src/lib.rs](../src/lib.rs)
"snapshot_identity_exclusion_precedes_accounting_in_both_collectors" checks the
private identity omission with bulk/stat and one/four workers, including aliases,
accounted totals and retention of directory identities.

[tests/accounting.rs](../tests/accounting.rs)
"bulk_stat_and_workers_have_identical_canonical_allocations" covers snapshot mode,
accounting, counters, truncation and payload corruption. [src/snapshot.rs](../src/snapshot.rs)
"snapshot_rejects_corrupt_structure_with_valid_checksum" and
"snapshot_preserves_non_utf8_bytes" cover structural validation and raw names.

## 1c CLI and export

The [CLI](../src/bin/disk-inventory.rs) accepts only create, sync, info and export;
there is no query/filter/sort language. Create/sync/info print one JSON summary;
export emits only entries. Help/diagnostics go to stderr. Exit codes: 0 complete,
2 partial, 1 fatal. Partial snapshots still yield data plus a stderr warning.
Partial sync returns 2 with no stdout and preserves the previous snapshot. Broken
pipes are quiet, retaining the complete/partial status.

All export formats contain `path`, `path_hex`, `kind`, `allocated_bytes`,
`accounted_bytes`, `subtree_bytes`. Human paths use UTF-8 replacement for invalid
bytes; hex is lossless and authoritative. Paths are relative, with an empty root
path; info provides the absolute `root` and `root_hex`. No Unicode normalization is
performed by export. Kind is `file`, `directory` or `other`. CSV/TSV always include
headers; JSONL does not. CSV quotes human paths and doubles quotes, permitting
multiline fields. TSV escapes backslash/tab/LF/CR as `\\`/`\t`/`\n`/`\r`, decoded
left-to-right; every record occupies one physical line. JSONL escapes JSON control
characters and emits byte counts as integers. Rows are unsorted; IDs/order are not
stable across sync. The [README](../README.md) includes a typed SQLite import.

[tests/inventory.rs](../tests/inventory.rs):

- "export_encoders_round_trip_and_sqlite_typed_import": independent Python CSV/JSON
  parsers and TSV decoder, Unicode/control/nonUTF8 names, real sqlite3 `.import`,
  INTEGER storage and numeric sums. Helper: [export_roundtrip.py](../tests/export_roundtrip.py).
- "cli_csv_pipes_into_sqlite_without_source_tree": direct CLI-to-SQLite pipe,
  typed numeric columns and lossless filename identity after the source root disappears.
- "partial_saved_reads_preserve_status_and_data_without_root": partial info and all
  exports preserve status/warnings without a root, using an unconditional synthetic map.
- "invalid_cli_arguments_fail_before_scanning": duplicate/unknown/misplaced flags
  and invalid workers/formats fail without scanning.
- "export_broken_pipe_is_quiet_and_streaming_errors_propagate": closed CLI pipes are
  quiet and library writer failures propagate.

The old benchmark alone retains top-ten queries and canonical details.
[tests/accounting.rs](../tests/accounting.rs) "cli_snapshot_load_and_opt_in_inventory"
covers its unchanged adapter.

## 1d Limits

Scans stay on the root device and exclude discovered mounts. Bulk also excludes
firmlinks; stat cannot reliably identify them. Compare collectors only where bulk
preflight reports zero firmlinks/errors. Directory opens reject symlink components
and verify identity, but collection/destination checks are not race-proof. A live
scan is not a point-in-time snapshot. No file contents, hashing of source files,
privilege escalation, SQLite dependency, watchers or mmap are involved. Explicit
confirmed library operations and their limits are specified in
[operations.md](operations.md); the CLI does not expose deletion.

Errors are counted; up to sixteen scan samples are held in the legacy map. Saved
snapshots retain counts, not samples. Inaccessible subtrees are not known empty.
Symlink/mount/firmlink exclusions have separate counters; snapshot self-omission has none. APFS clones/shared extents are not
deduplicated; totals need not match `df`. Cloud hydration is not deliberately requested.

Controlled mounts/firmlinks, compressed files, cloud placeholders, concurrent mutation,
publication fault injection and crash recovery are untested. APFS may reject nonUTF8
fixture names; synthetic parser/snapshot/export tests guarantee byte coverage.

The native bitmap diagram and sparse virtual tree are additional presentation APIs;
see [native-diagram.md](native-diagram.md) for their pixel/work bounds, squarified
placement, revision invalidation and source-named tests. The legacy bounded layout
API retains its existing placement and behavior.
