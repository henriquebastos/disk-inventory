#!/bin/bash
# Runs the repository checks in named stages, stops at the first failure and ends with one
# summary line. Usage: scripts/check.sh fast|model|ui [xcodebuild test options...]|all
#   fast   Rust format, Clippy (3 feature sets), Rust tests (default and bridge), swift-format,
#          documentation (links, quoted test names, below 1,500 words), git diff --check
#   model  fast, then the GUI build with the app icon check, the bridge smoke and model tests
#   ui     the GUI build and the UI tests; options such as
#          -only-testing:ExplorerUITests/ExplorerUITests/testName select tests
#   all    model, then every UI test
# Outputs stay outside the repository: CHECK_ROOT (default /private/tmp/disk-inventory-check),
# CARGO_TARGET_DIR (default CHECK_ROOT/target), GUI_ROOT (default CHECK_ROOT/gui), and TMPDIR.
# Stage logs go to CHECK_ROOT/logs; result bundles are deleted after their summary is read.
set -uo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd -P)
mode=${1:-}
[[ $# -gt 0 ]] && shift
case "$mode" in
  fast | model | all) [[ $# -eq 0 ]] || { echo "$mode takes no options" >&2; exit 2; } ;;
  ui) ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
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
logs="$root/logs"
rm -rf "$logs"
mkdir -p "$logs" "$gui/results"
cd "$repo"

started=$SECONDS
count=0
report=()
finish() {
  local total=$((SECONDS - started))
  printf '%s\n' ${report[@]+"${report[@]}"} > "$logs/summary.txt"
  if [[ $1 == ok ]]; then
    echo "check $mode: passed $count stages in ${total}s"
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
diff_check() { git diff --check HEAD && echo "summary: no whitespace errors"; }
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
  run gui-build gui_build
  run bridge-smoke bridge_smoke
  run model-tests xcode_tests -only-testing:ExplorerModelTests
}
ui_tests() {
  if [[ $# -eq 0 ]]; then set -- -only-testing:ExplorerUITests; fi
  run ui-tests xcode_tests "$@"
}

case "$mode" in
  fast) fast ;;
  model) model ;;
  ui)
    run gui-build gui_build
    ui_tests "$@"
    ;;
  all)
    model
    ui_tests
    ;;
esac
finish ok
