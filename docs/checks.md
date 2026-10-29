# 1 Checks

[check.sh](../scripts/check.sh) runs all checks in named stages (`fast`, `model`,
`model-only`, `ui`, `all`); [README.md](../README.md) lists what each mode runs and
[AGENTS.md](../AGENTS.md) tells which mode a change needs. Run `scripts/check.sh` without a
mode to see the usage text.

## 1a Environment

Set these variables to absolute paths outside the repository. Use one `CHECK_ROOT` for
each agent or worktree: two runs that share a `GUI_ROOT` write the same Xcode project and
DerivedData.

```sh
export CHECK_ROOT=/private/tmp/disk-inventory-check-$USER-1  # logs, and the defaults below
export CARGO_TARGET_DIR=$CHECK_ROOT/target                    # one Cargo tree for all stages
export GUI_ROOT=$CHECK_ROOT/gui                               # Xcode project, DerivedData, bridge
export TMPDIR=$CHECK_ROOT/tmp
```

macOS always sets `TMPDIR`, so the `CHECK_ROOT/tmp` default applies only when you unset it.
[build-bridge.sh](../scripts/build-bridge.sh) uses the exported `CARGO_TARGET_DIR`, so
the GUI build and the Rust stages share one Cargo tree.

Every mode except `fast` holds the machine lock `/private/tmp/disk-inventory-gui.lock`
from the GUI build to the end of the run. UI tests need the screen and the pointer, and the
hosted model tests open an app window that can take the focus from them. A second run stops
(exit 2) before its GUI build and names the pid and `CHECK_ROOT` of the run that holds the
lock. The lock is removed when the run ends, also after a failure or Ctrl-C. A stale lock
after a crash: remove the directory (`rm -r /private/tmp/disk-inventory-gui.lock`).

## 1b Run one test

Rust (`CARGO_TARGET_DIR` and `TMPDIR` exported as above):

```sh
cargo test --offline --locked --features bridge presentation_and_delay_fixtures_are_isolated
cargo test --offline --locked --test accounting resource_fork_allocation_matches_stat
```

Model tests: `model-only` builds the GUI and runs the selected model tests, with no Rust
stages. Without an `-only-testing:` option it runs all of `ExplorerModelTests`.

```sh
scripts/check.sh model-only -only-testing:ExplorerModelTests/NativeNumberFormatTests
scripts/check.sh model-only -only-testing:ExplorerModelTests/DixModelTests/testNativeHundredThousandRowsAreVirtual
```

UI tests: `ui` builds the GUI and runs the selected UI tests. `ui --no-build` uses the
last GUI build in `GUI_ROOT`; use it only when the sources did not change after that build.
`-test-iterations 5` runs each selected test five times.

```sh
scripts/check.sh ui -only-testing:ExplorerUITests/ExplorerUITests/testFixtureModeFailsClosed
scripts/check.sh ui --no-build -test-iterations 5 \
  -only-testing:ExplorerUITests/ExplorerUITests/testFixtureModeFailsClosed
```

## 1c Logs

Each run writes to its own folder, `CHECK_ROOT/logs/MODE-YYYYmmdd-HHMMSS-PID`: one
`STAGE.log` for each stage and `summary.txt` with one line for each stage (result, time,
counts). The last line of the run names the folder. When a stage fails, the script shows
the last 40 lines of its log and stops (exit 1). The test stages also list each failed
test. Result bundles are deleted after their summary is read. Old log folders stay; remove
them when you do not need them.

## 1d Troubleshooting

- **"refusing to run, N MB free"**: a GUI build and its results need about 1.5 GB. Make
  space in your own `CHECK_ROOT`; do not delete outputs of other agents.
- **XcodeGen `Code=4`, "The file “XcodeGen” doesn’t exist"**: the `--project` directory is
  missing. [build-gui.sh](../scripts/build-gui.sh) makes it. If you run `xcodegen` by hand,
  run `mkdir -p` on the project directory first.
- **A macOS crash dialog** ("DiskInventory quit unexpectedly") blocks XCUITest: the next
  tests cannot get the focus and time out. Only the user can click **Ignore**. Ask the user,
  then run the failed tests again.
- **UI tests need an unlocked interactive console.** Do not change security settings to force
  automation. A UI test that cannot start is a failure, not a reason to retry.
- **`ui --no-build` stops with "needs a GUI build"**: run `ui` or `model-only` once in that
  `GUI_ROOT`.

## 1e Known flakes

None known. check.sh does not retry a failed test. To report a flake, run the one test
again with `-test-iterations 5` (model, UI) or in a loop (Rust), keep the stage logs, and
add the test name, the failure line and its cause to this list.

## 1f Disk and time

Measured on an Apple silicon Mac:

| Run | Time |
|---|---|
| `fast`, warm Cargo tree | about 20 s |
| GUI build, no source change | about 10–15 s |
| GUI build in a new `GUI_ROOT`, warm Cargo tree | about 70 s |
| all model tests (145) | about 90 s |
| `model`, warm | about 2 min |
| one short UI test with `ui --no-build` | about 10 s |
| all UI tests | about 8–9 min |

A first build in a new Cargo tree takes longer (not measured). `CARGO_TARGET_DIR` uses about
2.1 GB (debug, release and bridge builds). `GUI_ROOT` uses about 0.3 GB after its first
build and grows to about 0.8 GB as DerivedData and the module cache fill.
