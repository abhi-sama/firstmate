#!/usr/bin/env bash
# tests/fm-tasks-axi-resolve.test.sh - tasks-axi binary resolution for crew shells.
#
# A primary firstmate session inherits tasks-axi on PATH from the
# nvm-initialised login shell it started from. A crew or scout shell spawned
# into a task worktree does not re-establish that PATH, so
# bin/fm-decision-hold.sh's bare `tasks-axi` invocations failed there even
# when a compatible install existed on the same machine, and crews could not
# self-file their own decision-hold records
# (data/scoursh-sqli-demo-spec/report.md sec 8,
# data/scoursh-spa-autodiscovery-scout/report.md sec 8). This suite
# reconstructs that PATH-stripped shell with the real tasks-axi reachable only
# through an nvm-style fallback location and proves
# bin/fm-tasks-axi-lib.sh's fm_tasks_axi_bin resolves it there instead of
# failing, then that a full hold/complete/verify round-trip survives it.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tasks-axi-resolve)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
REAL_TASKS_AXI=$(command -v tasks-axi)
REAL_TASKS_AXI_DIR=$(dirname "$REAL_TASKS_AXI")
REAL_NPM_DIR=
if command -v npm >/dev/null 2>&1; then
  REAL_NPM_DIR=$(dirname "$(command -v npm)")
fi

# strip_path <dir> [<dir>...]: echo $PATH with the given directories removed,
# so tasks-axi (and, when given, npm) genuinely cannot be found on PATH -
# the exact shape of a crew shell spawned into a task worktree.
strip_path() {
  local removed=" $* " dir out='' old_ifs=$IFS
  IFS=:
  for dir in $PATH; do
    case "$removed" in
      *" $dir "*) continue ;;
    esac
    out="${out:+$out:}$dir"
  done
  IFS=$old_ifs
  printf '%s\n' "$out"
}

STRIPPED_PATH=$(strip_path "$REAL_TASKS_AXI_DIR" "$REAL_NPM_DIR")

# make_nvm_fallback <fake-home>: populate <fake-home>/.nvm with a shim that
# execs the real tasks-axi, at the layout fm_tasks_axi_nvm_fallback scans.
make_nvm_fallback() {
  local fake_home=$1 shim_dir
  shim_dir="$fake_home/.nvm/versions/node/v99.99.99/bin"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/tasks-axi" <<EOF
#!/usr/bin/env bash
exec "$REAL_TASKS_AXI" "\$@"
EOF
  chmod +x "$shim_dir/tasks-axi"
}

test_bare_command_fails_without_fallback_present() {
  local empty_home
  empty_home="$TMP_ROOT/no-fallback-home"
  mkdir -p "$empty_home"
  if PATH="$STRIPPED_PATH" HOME="$empty_home" NVM_DIR="$empty_home/.nvm" \
    command -v tasks-axi >/dev/null 2>&1; then
    fail "PATH-stripped sanity check found tasks-axi without a fallback; the reproduction is not faithful"
  fi
  if PATH="$STRIPPED_PATH" HOME="$empty_home" NVM_DIR="$empty_home/.nvm" \
    bash -c '. "$1/bin/fm-tasks-axi-lib.sh" && fm_tasks_axi_bin' _ "$ROOT" >/dev/null 2>&1; then
    fail "resolver found a tasks-axi binary with no PATH entry and no fallback location populated"
  fi
  pass "a PATH-stripped crew shell with no fallback location reproduces the original defect"
}

test_resolver_finds_nvm_fallback_when_path_lacks_it() {
  local fake_home resolved
  fake_home="$TMP_ROOT/nvm-fallback-home"
  make_nvm_fallback "$fake_home"
  resolved=$(PATH="$STRIPPED_PATH" HOME="$fake_home" NVM_DIR="$fake_home/.nvm" \
    bash -c '. "$1/bin/fm-tasks-axi-lib.sh" && fm_tasks_axi_bin' _ "$ROOT") \
    || fail "fm_tasks_axi_bin did not find the nvm fallback binary"
  [ "$resolved" = "$fake_home/.nvm/versions/node/v99.99.99/bin/tasks-axi" ] \
    || fail "fm_tasks_axi_bin returned an unexpected path: $resolved"
  PATH="$STRIPPED_PATH" HOME="$fake_home" NVM_DIR="$fake_home/.nvm" \
    bash -c '. "$1/bin/fm-tasks-axi-lib.sh" && fm_tasks_axi_compatible' _ "$ROOT" \
    || fail "the resolved fallback binary was not reported compatible"
  pass "fm_tasks_axi_bin resolves the nvm fallback when tasks-axi is absent from PATH"
}

test_decision_hold_round_trip_survives_path_stripped_crew_shell() {
  local home id hold_id
  home="$TMP_ROOT/decision-hold-home"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  make_nvm_fallback "$home"

  id=sample-crew-review
  mkdir -p "$home/data/$id"
  (cd "$home" && PATH="$REAL_TASKS_AXI_DIR:$PATH" "$REAL_TASKS_AXI" \
    add "$id" "Investigate sample crew scenario" --kind scout --repo sample --start) >/dev/null \
    || fail "could not create the origin fixture with the real tasks-axi"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'needs-decision [key=route]: choose route north or route south\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample crew review

One choice remains: the route.
EOF

  run_in_crew_shell() {
    PATH="$STRIPPED_PATH" HOME="$home" NVM_DIR="$home/.nvm" \
      FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
  }

  hold_id=$(run_in_crew_shell hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample \
    2> "$home/hold.err") || fail "hold failed in a PATH-stripped crew shell: $(cat "$home/hold.err")"
  [ "$hold_id" = "$id-decision-route" ] || fail "hold identity was not deterministic: $hold_id"
  run_in_crew_shell complete "$id" route > "$home/complete.out" 2> "$home/complete.err" \
    || fail "complete failed in a PATH-stripped crew shell: $(cat "$home/complete.err")"
  run_in_crew_shell verify "$id" > "$home/verify.out" 2> "$home/verify.err" \
    || fail "verify failed in a PATH-stripped crew shell: $(cat "$home/verify.err")"
  pass "hold/complete/verify round-trips through fm-decision-hold.sh in a PATH-stripped crew shell"
}

test_bare_command_fails_without_fallback_present
test_resolver_finds_nvm_fallback_when_path_lacks_it
test_decision_hold_round_trip_survives_path_stripped_crew_shell
