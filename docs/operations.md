# 1 Live operation sessions

[src/operations.rs](../src/operations.rs) owns the indexed explorer and a narrow
`FileSystem` adapter. `OperationSession::new` indexes every recorded identity,
including files originally reporting one link, without consulting source paths.
`NativeFileSystem::open_snapshot` decodes and pins the same open snapshot inode;
it does not validate the source root. Snapshot format and CLI behavior are unchanged.

Use `explorer()` for saved selection, paging and layout. `live_metadata(handle)`
is a separate targeted request returning identity, kind, allocation, logical size,
mode, modification/birth timestamps and collection-policy fields. A failed request
does not silently change accounting. No selection recursively sizes a directory.
`DirectoryEntry.metadata` is `ScanMetadata`: identity, kind, allocated bytes, links,
flags and mount status only. It has no fabricated inspector fields. Native enumeration
uses bulk records directly; only missing directory allocation or symlink identity
needs child stat fallback. Directory descriptor validation and immediate pre-mutation
checks remain mandatory. Non-file link counts are ignored for change detection,
consistent with the collector's directory-link normalization.

## 1a Confirmation and outcomes

`prepare(handle, Action::{Trash,PermanentlyDelete})` returns a non-cloneable
`Confirmation<F::Pin>`. It exposes the raw absolute path and freshly observed
metadata, not a promise that the object is historically unchanged. Native pins use
metadata-only `O_EVTONLY` descriptors with no-follow checks. Dropping the confirmation
cancels and releases its pin. `execute` consumes it, revalidates the target/root,
and performs the explicitly chosen action. Cross-session, removed and replaced
slots cannot authorize actions; new entries never reuse removed slots.

The root, pinned snapshot identity, and directories containing any snapshot alias
are protected. Directory preparation/execution requires complete safety enumeration;
an inaccessible child prevents mutation. Descendant symlinks may be unlinked but
are never traversed. Permanent deletion uses descriptor-relative no-follow opens,
identity checks and `unlinkat`. There is no privilege escalation or Trash-to-delete
fallback. Native Trash rejects the main thread and unsupported URLs, uses Foundation's
actual resulting URL, and treats an error or missing URL conservatively as indeterminate.

`OperationReport` separates mutation outcome, destination scope and reconciliation.
In-scope moves relocate known allocation to the actual destination, updating moved
subtrees and affected aliases. Destination ancestry is classified by directory
identities, not string prefixes. Outside moves subtract scope usage, **not guaranteed
reclaimed disk space**. Unknown scope retains recorded allocation and marks it stale.
New destination ancestors with unscanned children also mark the session stale.
Partial removal reconciles survivors; failed enumeration preserves unknown children.

## 1b Refresh, ownership and work

`refresh_directory` enumerates only the selected region, plus targeted root/parent
validation and affected hardlink groups. It reconciles additions, removal, renames,
replacement and allocation changes, excluding snapshot aliases, symlinks, other-device
entries, discovered mounts and firmlinks. Failed enumeration is never an empty list.
Hardlink ownership remains the smallest raw relative path, including aliases outside
the refreshed/moved region. Allocation/link observations are staged per identity;
propagation and canonical ownership are applied once per affected group, then the
observation tables are released. A baseline is captured before the first group edit,
independently of newly appended aliases. Conflicts retain that allocation (including
known zero) across canonical-owner transfer and removal of old aliases. With no
trustworthy baseline, raw observations remain visible but the group is unattributed:
zero accounted bytes means **unknown, not measured zero**. An explicit issue and
stale state require presentation as a partial/stale total. Repeated conflicts cannot
promote those observations to a baseline. Consistent fresh observations resolve the
group even if raw values are unchanged; empty groups lose their uncertainty marker.
A single survivor observation does not override conflicting records from the same
refresh. After
removal (including an outside move), surviving groups receive a targeted identity-
validated alias observation; failure retains recorded allocation and marks stale.
Directory-own allocation remains separate.

`refresh_directory_controlled` takes a [ScanControl](scan-control.md). It reads the live
subtree first and changes nothing during that read; Stop returns `ScanCancelled`. A
compare-exchange from Scanning to Committing then arbitrates Stop, and the same reconciliation
runs from the read. A request that the read did not make uses the filesystem. The read holds
one subtree of directory records in memory, like a scan. "stopped_controlled_refresh_leaves_the_inventory_unchanged"
and "controlled_refresh_applies_the_same_update_and_counts_directory_records" in
[src/operations/tests.rs](../src/operations/tests.rs) cover every Stop point and equality with
`refresh_directory`.

Stable arena slots, tombstones, a sorted identity-ID baseline, an additions overlay
and affected CSR child-list overrides avoid a global accounting rebuild. Work is
bounded by the changed/selected region, affected parent fanout, ancestor depth and
identity groups (including tombstoned group members), **not solely changed entries**.
Affected parents are sorted once per update when ordering changes; deletion-only
child filtering preserves order. `UpdateWork` charges visited entries, baseline
identity comparisons and group visits (baseline capture, lookup, propagation/owner
choice, attribution),
ancestor validation/updates, child IDs copied/sorted
and refresh directory reads. It does not count adapter I/O or safety preflight scans.
Navigation/layout budgets are unchanged. Arenas/tombstones/overlays grow for the
session lifetime; reload is the reclamation boundary, not an interactive operation.

`SessionState::{dirty,stale}` are sticky, conservative flags, separate from original
scan counters. Local updates never save or rewrite the monolithic snapshot. Saving
is not exposed here. Run requests on a worker; retain the last bounded rows/layout
for presentation while Rust holds the session exclusively. Clone `activity()` before
moving it to the worker and poll `is_busy()` without locking. Completion returns
state/issues and new views can then be requested. No progress percentage is invented.

`MemoryFileSystem` is public and stateful: raw paths/identities, moves, removal,
metadata, alias spellings, pins and injected failures. Its default Trash behavior
fails closed. It never constructs a native adapter. It favors simple fixture logic;
some fake operations scan its fixture map. Those costs are not native performance.

## 1c Evidence and limits

[src/operations/tests.rs](../src/operations/tests.rs):

- "selection_is_offline_and_metadata_is_explicit_without_reaccounting" and
  "no_op_refresh_preserves_handles_and_clean_state_and_replaced_root_is_rejected".
- "confirmations_pin_live_identity_until_cancel_error_or_completion",
  "confirmation_rejects_missing_replaced_symlink_and_foreign_handles",
  "native_confirmation_keeps_unlinked_inode_pinned_and_rejects_replacement" and
  "moved_confirmation_is_stale_and_deleted_slots_are_never_reused".
- "root_snapshot_and_snapshot_containing_directories_are_protected" and
  "native_snapshot_alias_protection_and_replaced_target_rejection".
- "trash_moves_inside_outside_and_unknown_without_permanent_fallback",
  "scope_uses_directory_identity_aliases_not_textual_prefixes" and
  "missing_destination_is_indeterminate_and_retains_recorded_allocation" and
  "unvalidated_returned_destination_is_unknown_even_when_ancestry_is_outside".
- "permanent_file_and_directory_removal_invalidate_only_affected_handles",
  "partial_removal_reconciles_survivors_and_preserves_inaccessible_data" and
  "partial_removal_with_failed_reconciliation_retains_unknown_children".
- "refresh_reconciles_raw_names_replacements_renames_and_snapshot_alias_exclusion",
  "refresh_mount_firmlink_and_inaccessible_regions_are_not_followed" and
  "in_scope_directory_move_refreshes_only_moved_region_and_marks_new_ancestry_unknown".
- "new_hardlink_finds_original_links_one_alias_outside_refreshed_subtree",
  "existing_hardlinks_allocation_and_directory_own_bytes_update_locally",
  "directory_move_recomputes_canonical_hardlink_paths_outside_moved_subtree" and
  "deleting_owner_reconciles_current_allocation_of_surviving_hardlink".
- "incremental_work_is_independent_of_unrelated_entries_and_batched_per_parent",
  "accounting_overflow_retains_consistent_attributed_totals_and_marks_stale" and
  "activity_is_observable_while_worker_refreshes_and_last_layout_remains_usable".
- "native_owned_fixture_metadata_url_scope_and_nofollow_permanent_removal" tests
  only owned fixtures, including a Data-volume namespace alias when available.

Additional regressions in [src/operations/tests.rs](../src/operations/tests.rs):

- "directory_removal_refreshes_surviving_hardlink_allocation" and
  "outside_directory_trash_refreshes_surviving_hardlink_allocation".
- "survivor_observation_failure_retains_recorded_allocation_and_marks_stale" and
  "conflicting_hardlink_observations_preserve_previous_allocations".
- "hardlink_observations_are_batched_for_new_and_changed_aliases" bounds new and
  changed groups at 100/1,000 aliases; "unchanged_nonfile_link_counts_do_not_dirty_refresh".
- "native_regular_refresh_uses_bulk_records_without_child_stats" isolates native
  adapter counters and distinguishes bulk enumeration from targeted inspector requests.
- "native_owned_bulk_refresh_performance" explicitly measures an owned 25,000-file
  fixture (normally ignored). Native directory time and total refresh time are separate;
  this is not fake-adapter timing or a production latency guarantee.

Conflict-baseline regressions in [src/operations/tests.rs](../src/operations/tests.rs):

- "newly_appended_conflicting_aliases_retain_baseline_in_both_orders" reverses
  observed values and actual enumeration order.
- "conflicting_new_aliases_retain_baseline_when_old_alias_is_removed" and
  "known_zero_allocation_is_not_an_unknown_conflict_baseline".
- "entirely_new_conflicting_identity_remains_unattributed_until_consistent",
  "unknown_group_recovers_from_unchanged_raw_observation_in_one_region" and
  "removing_all_unknown_aliases_prunes_uncertainty_without_reusing_a_baseline".
- "conflicting_alias_baselines_keep_group_work_linear" bounds 100/1,000 aliases;
  all baseline and propagation visits remain charged.

[src/operations/native.rs](../src/operations/native.rs)
"bulk_fallback_checks_directory_identity_and_preserves_symlink_identity" verifies
identity-checked allocation fallback and no-follow symlink identity on owned fixtures.

[src/operations/performance.rs](../src/operations/performance.rs)
"operations_release_performance" is an ignored, explicit release measurement of
three million unrelated entries and a million-child selected directory. It separates
fake adapter/core/layout time, requested live/temporary allocation and process peak RSS.
Allocator instrumentation adds overhead; this is not a native I/O or UI latency test.

**Untested/remaining limits:** Native Trash execution is deliberately untested against
user Trash. Foundation paths must be Unicode, shorter than its 1024-byte output buffer,
and round-trip byte-exactly (allowing a directory trailing slash). Raw non-Unicode paths
remain supported in saved/fake views; Foundation Trash rejects them before mutation.
Controlled mount/firmlink creation, hostile concurrent mutation and cloud behavior
are untested. Historical inode reuse before preparation cannot be detected from the
unchanged snapshot identity fields. Confirmation pins prevent reuse during confirmation,
not historical substitution. Namespace changes between final checks and path-based
Foundation/unlink calls are still possible; there is no atomic conditional filesystem
transaction. Enumeration is not a point-in-time snapshot. Stale/error outcomes are
conservative, not a claim of complete or race-free accounting.
