#!/bin/bash
# Runs the repository checks in named stages, stops at the first failure and ends with one
# summary line. Usage: scripts/check.sh MODE [xcodebuild test options...]
#   fast        Rust format, Clippy (3 feature sets), Rust tests (default and bridge),
#               swift-format, documentation (links, quoted test names, below 1,500 words),
#               git diff --check on tracked changes and new untracked files
#   model       fast, then the GUI build with the app icon check, the bridge smoke and model tests
#   model-only  the GUI build and model tests, no Rust stages; options such as
#               -only-testing:ExplorerModelTests/NativeNumberFormatTests select tests
#   ui          the GUI build and the UI tests; options such as
#               -only-testing:ExplorerUITests/ExplorerUITests/testName select tests;
#               ui --no-build [options] uses the last GUI build in GUI_ROOT
#   all         model, then every UI test
# Outputs stay outside the repository: CHECK_ROOT (default /private/tmp/disk-inventory-check),
# CARGO_TARGET_DIR (default CHECK_ROOT/target), GUI_ROOT (default CHECK_ROOT/gui), and TMPDIR.
# Each run writes its stage logs and summary.txt to CHECK_ROOT/logs/MODE-TIME-PID; result
# bundles are deleted after their summary is read. All modes except fast hold the machine lock
# /private/tmp/disk-inventory-gui.lock from the GUI build to the end; a second run stops.
set -uo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd -P)
mode=${1:-}
[[ $# -gt 0 ]] && shift
case "$mode" in
  fast | model | all) [[ $# -eq 0 ]] || { echo "$mode takes no options" >&2; exit 2; } ;;
  ui | model-only) ;;
  *) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0" >&2; exit 2 ;;
esac
build=yes
if [[ $mode == ui && ${1:-} == --no-build ]]; then
  build=no
  shift
fi
root=${CHECK_ROOT:-/private/tmp/disk-inventory-check}
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$root/target}
gui=${GUI_ROOT:-$root/gui}
export TMPDIR=${TMPDIR:-$root/tmp}
export CARGO_NET_OFFLINE=true
for dir in "$root" "$CARGO_TARGET_DIR" "$gui" "$TMPDIR"; do
  [[ "$dir" == /* ]] || { echo "check: $dir must be an absolute path" >&2; exit 2; }
  case "$dir/" in "$repo/"*) echo "check: $dir must be outside the repository" >&2; exit 2 ;; esac
  mkdir -p "$dir"
  real=$(cd "$dir" && pwd -P)
  case "$real/" in "$repo/"*) echo "check: $dir must be outside the repository" >&2; exit 2 ;; esac
  # A full build and the UI results need room; a nearly full disk fails late and unclearly.
  free=$(df -Pk "$real" | awk 'NR == 2 { print $4 }')
  if ((free < 1536 * 1024)); then
    echo "check: refusing to run, $((free / 1024)) MB free on the volume of $dir (< 1.5 GB)" >&2
    exit 2
  fi
done
if [[ $build == no && ! -d "$gui/DerivedData/Build/Products/Debug/DiskInventory.app" ]]; then
  echo "check: ui --no-build needs a GUI build in $gui; run check.sh ui or model-only first" >&2
  exit 2
fi
# Each run has its own folder, so a parallel run in the same CHECK_ROOT keeps its logs.
logs="$root/logs/$mode-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$logs" "$gui/results"
cd "$repo"

started=$SECONDS
count=0
report=()
finish() {
  local total=$((SECONDS - started))
  printf '%s\n' ${report[@]+"${report[@]}"} > "$logs/summary.txt"
  if [[ $1 == ok ]]; then
    echo "check $mode: passed $count stages in ${total}s (logs $logs)"
  else
    echo "check $mode: FAILED at stage '$2' after ${total}s ($count stages passed; log $logs)"
    exit 1
  fi
}
# Runs one stage with its output in a log. A line "summary: TEXT" in the log is shown.
stage() {
  local name=$1 begin=$SECONDS
  shift
  printf '==> %-16s ' "$name"
  if "$@" > "$logs/$name.log" 2>&1; then
    local took=$((SECONDS - begin)) note
    note=$(grep '^summary: ' "$logs/$name.log" | tail -1 | sed 's/^summary: //')
    printf 'ok %5ss  %s\n' "$took" "$note"
    count=$((count + 1))
    report+=("$name ok ${took}s $note")
  else
    printf 'FAILED after %ss\n' "$((SECONDS - begin))"
    tail -n 40 "$logs/$name.log"
    report+=("$name FAILED")
    finish failed "$name"
  fi
}

cargo_tests() {
  cargo test --offline --locked "$@" || return
  echo "summary: $(awk '/^test result:/ { p += $4; i += $8 } END { print p " passed, " i " ignored" }' \
    "$logs/$current.log")"
}
swift_format() { xcrun swift-format lint --strict -r native && echo "summary: native/ clean"; }
# git diff --check HEAD skips untracked files, so each new file is compared with /dev/null.
diff_check() {
  local file status=0 found
  git diff --check HEAD || status=1
  while IFS= read -r -d '' file; do
    git diff --no-index --check -- /dev/null "$file"
    found=$?
    # Exit 1 means only "the files differ"; a higher code means whitespace errors or a failure.
    ((found <= 1)) || status=1
  done < <(git ls-files -z --others --exclude-standard)
  ((status == 0)) && echo "summary: no whitespace errors"
  return $status
}
# One GUI run per machine: UI tests need the screen and the pointer, and the hosted model tests
# open an app window that can take the focus from them. The lock is a directory because mkdir
# is atomic. The traps remove it at each exit: success, a failed stage, Ctrl-C, TERM or HUP.
gui_lock=/private/tmp/disk-inventory-gui.lock
lock_gui() {
  if ! mkdir "$gui_lock" 2>/dev/null; then
    local owner pid
    owner=$(cat "$gui_lock/owner" 2>/dev/null) || true
    echo "check $mode: another GUI run holds $gui_lock (${owner:-owner not written yet})." >&2
    pid=${owner#pid }
    pid=${pid%%,*}
    # Never remove a stale lock here: two runs that both see it stale would race.
    if [[ $pid =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
      echo "The lock is stale: pid $pid is not running. Run: rm -r $gui_lock" >&2
    else
      echo "Wait until that run ends." >&2
    fi
    exit 2
  fi
  # Remove only our own lock, in case someone removed it by hand and another run took it.
  trap '[[ $(cat "$gui_lock/owner" 2>/dev/null) == "pid $$,"* ]] && rm -rf "$gui_lock"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  echo "pid $$, CHECK_ROOT $root, check.sh $mode since $(date '+%H:%M:%S')" > "$gui_lock/owner"
}
gui_build() { bash scripts/build-gui.sh "$gui"; }
bridge_smoke() {
  local fixture status
  fixture=$(mktemp -d "$TMPDIR/bridge-smoke.XXXXXX") || return
  "$gui/bridge/bridge-smoke" "$fixture"
  status=$?
  rm -rf "$fixture"
  return $status
}
# Runs built tests through scripts/test-gui.sh, prints the result summary and failing tests,
# then deletes the result bundle.
xcode_tests() {
  local bundle status
  bundle="$gui/results/$current-$(date +%Y%m%d-%H%M%S).xcresult"
  RESULT_BUNDLE="$bundle" bash scripts/test-gui.sh "$gui" "$@"
  status=$?
  if [[ -d "$bundle" ]]; then
    xcrun xcresulttool get test-results tests --path "$bundle" | python3 -c '
import json, sys
def walk(node):
    if node.get("nodeType") == "Test Case" and node.get("result") != "Passed":
        print(node.get("result"), node.get("name"))
    for child in node.get("children", []):
        walk(child)
for node in json.load(sys.stdin)["testNodes"]:
    walk(node)'
    xcrun xcresulttool get test-results summary --path "$bundle" | python3 -c '
import json, sys
s = json.load(sys.stdin)
print("summary: {passedTests} passed, {failedTests} failed, {skippedTests} skipped of "
      "{totalTestCount}".format(**s))'
    rm -rf "$bundle"
  fi
  return $status
}
run() { current=$1; stage "$@"; }
# Runs xcode_tests with -only-testing:SUITE unless the options already select tests.
suite_tests() {
  local suite=$1 option
  shift
  for option in "$@"; do
    [[ $option == -only-testing:* ]] && { xcode_tests "$@"; return; }
  done
  xcode_tests "-only-testing:$suite" "$@"
}

fast() {
  run fmt cargo fmt --check
  run clippy-default cargo clippy --offline --locked --all-targets -- -D warnings
  run clippy-bridge cargo clippy --offline --locked --all-targets --features bridge -- -D warnings
  run clippy-bindgen \
    cargo clippy --offline --locked --all-targets --features bridge-build -- -D warnings
  run test-default cargo_tests
  run test-bridge cargo_tests --features bridge
  run swift-format swift_format
  run docs python3 scripts/check-docs.py "$repo"
  run diff-check diff_check
}
model() {
  fast
  lock_gui
  run gui-build gui_build
  run bridge-smoke bridge_smoke
  run model-tests suite_tests ExplorerModelTests
}

case "$mode" in
  fast) fast ;;
  model) model ;;
  model-only)
    lock_gui
    run gui-build gui_build
    run model-tests suite_tests ExplorerModelTests "$@"
    ;;
  ui)
    lock_gui
    [[ $build == no ]] || run gui-build gui_build
    run ui-tests suite_tests ExplorerUITests "$@"
    ;;
  all)
    model
    run ui-tests suite_tests ExplorerUITests
    ;;
esac
finish ok
