# 1 Fixture scenarios

`ExplorerSession.fixture(scenario:)` in [src/bridge/fixture.rs](../src/bridge/fixture.rs)
builds a session from a scenario name. It always uses the stateful `MemoryFileSystem` with
the real Rust explorer, layout, accounting and operations. An unknown name fails closed; no
path uses the native adapter. `status().simulated` is true. The bridge contract is in
[bridge.md](bridge.md).

Launch the built app with a scenario (G is the GUI root of [checks.md](checks.md)):

```sh
open -n "$G/DerivedData/Build/Products/Debug/DiskInventory.app" \
  --args --fixture-mode --scenario dix
```

Model and UI tests load scenarios by name. Fixture mode is specified in
[native-explorer.md](native-explorer.md).

## 1a Base inventory

`ordinary` and most failure scenarios use one small inventory. Find its entries through
bounded queries: `small-files/small-00` through `small-15`, `large-file` (2^53+123 allocated
bytes), `zero-byte`, `hardlink-a`, `hardlink-b`, `trash`, and raw bytes `raw-` followed by FF.

## 1b Scenarios

| Scenario | Behavior/target |
|---|---|
| `dix` | `/Workspace`: `Projects` with 2,000 files (4–64 KiB, four extensions), `Tiny files/Notes` (4 KiB, 8 KiB and empty files) and a 64 MiB `Movie.mov` |
| `dix-wide` | `dix` with 100,000 files in `Projects` |
| `dix-deep` | 80 nested directories `level-0` … `level-79` and one `bottom.txt` |
| `presentation` | Balanced 4096-byte large file and 128 small children for native UI pagination |
| `metadata-delay` | Presentation inventory; only large-file MemoryFileSystem metadata sleeps one second |
| `prototype-home` | The design prototype's 236.9 GB home `/Users/ana`: its names (`CoreSimulator` is `CoreDevice`), hierarchy, sizes and extensions; directories own zero bytes |
| `prototype-home-refresh` | `prototype-home`; each directory metadata request sleeps 300 ms and `Library/Caches/new cache.db` (2 GB) exists only live |
| `prototype-home-nested-trash` | `prototype-home` plus `Projects/.Trash` with four videos (4 GB), added after the prototype's entries |
| `file-type-colors` | `/Users/ana` with more extensions, files without an extension in Git object storage (submodules, one slash-named, and a bare repository included) and cache folders, and gray controls |
| `visual-details` | Isolated nested groups and a long directory path; entry-only metadata differs from subtree bytes |
| `ordinary`, `trash-outside` | Trash moves to `/.Trash/moved` |
| `trash-inside` | Moves to `trash/moved` within scope |
| `presentation-trash-inside` | Larger Trash directory separates the visible source and destination regions |
| `presentation-trash-late-target` | Presentation sizes place the destination outside the 24 accessibility targets |
| `metadata-failure` | `large-file` metadata denied; selection still works |
| `permission-failure` | `small-files` enumeration denied; removal fails and changes nothing |
| `changed-target` | Live `large-file` identity differs from saved |
| `partial-deletion` | Removing `small-files` fails after one unlink; enumeration denied |
| `trash-unknown`, `trash-missing` | Unknown scope or missing returned destination |
| `trash-failure` | Failed Trash that changes nothing |
| `unknown-allocation` | Refresh root adds conflicting `unknown-a`/`unknown-b`; unattributed/stale |
| `operation-quick`, `operation-skip` | `prototype-home`; in `-skip` Delete skips three `Library` files |
| `operation-slow` | Each check, the Trash move and the update take 3 s; each removal 30 ms |
| `operation-paused` | Holds each stage (check, trash, removal after 5 entries, update) until `releaseFixtureStage()`; `waitForHeldFixtureStage()` names it |

The fixture invariants and their tests are listed in [bridge.md](bridge.md). The `dix`
scenarios are used by
[DixModelTests.swift](../native/ExplorerModelTests/DixModelTests.swift) and
[src/bridge/tests.rs](../src/bridge/tests.rs)
"diagram_and_virtual_tree_are_native_free_bounded_and_revision_guarded" (`dix-wide`).
