#!/usr/bin/env bash
# tests/fm-pipeline-monitor.test.sh - behavior tests for
# bin/fm-pipeline-monitor.sh, the read-only live-tail window for a crewmate's
# no-mistakes validation run.
#
# Hermetic `--tick` tests (a fake `no-mistakes`, no real tmux) cover the
# display logic: worktree resolution from state/<id>.meta, graceful handling
# of no active run / a terminal outcome / a torn-down task / a missing
# no-mistakes CLI, and - the read-only safety contract - that a parked
# (awaiting_approval) run is displayed WITHOUT ever invoking `axi respond` or
# `axi abort`.
#
# A real-tmux section (private socket, mirrors
# tests/fm-backend-tmux-smoke.test.sh so it never touches the host's actual
# sessions) covers the window-management path: opening a monitor window in
# the crewmate's own session, reusing it on a second call, the window closing
# itself once a run reaches a terminal outcome, and no-op'ing with a pointer
# message for a non-tmux backend instead of touching tmux at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MONITOR="$ROOT/bin/fm-pipeline-monitor.sh"
TMP_ROOT=$(fm_test_tmproot fm-pipeline-monitor)
fm_git_identity fmtest fmtest@example.invalid

# Exported once so every test's plain assignment (FM_FAKE_AXI_STATUS=...)
# reaches the fake no-mistakes binary's environment without an
# export/command-substitution combo (SC2155) at each call site.
FM_FAKE_AXI_STATUS=""
FM_FAKE_AXI_LOGS=""
FM_FAKE_FORBIDDEN_LOG=""
export FM_FAKE_AXI_STATUS FM_FAKE_AXI_LOGS FM_FAKE_FORBIDDEN_LOG

make_repo() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
}

# A fakebin with a fake `no-mistakes`. Serves `axi status` / `axi logs --step`
# from env - and, the safety-critical bit, logs any `axi respond`/`axi abort`
# call to FM_FAKE_FORBIDDEN_LOG instead of silently honoring it, so a test can
# assert those subcommands are NEVER invoked by the monitor.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = axi ]; then
  shift
  case "${1:-}" in
    respond|abort)
      echo "FORBIDDEN_CALL:$1" >> "${FM_FAKE_FORBIDDEN_LOG:-/dev/null}"
      exit 0 ;;
    status)
      printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"
      exit 0 ;;
    logs)
      printf '%s\n' "${FM_FAKE_AXI_LOGS:-}"
      exit 0 ;;
  esac
fi
exit 0
SH
  chmod +x "$fb/no-mistakes"
  printf '%s\n' "$fb"
}

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

run_tick() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" "$MONITOR" --tick "$2"
}

# --- monitor_tick / --tick ---------------------------------------------------

test_resolves_worktree_and_shows_active_run() {
  local d; d=$(new_case active)
  make_repo "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-a.meta" "window=fm:fm-feat-a" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS=$'run:\n  id: "01RUN"\n  status: running\n  steps[2]{step,status,findings,duration_ms}:\n    intent,completed,0,0\n    review,running,0,0'
  FM_FAKE_AXI_LOGS="reviewing diff..."
  local out rc
  out=$(run_tick "$d" feat-a); rc=$?
  expect_code 0 "$rc" "active run keeps ticking (exit 0)"
  assert_contains "$out" "feat-a" "shows the task id"
  assert_contains "$out" "review,running" "shows the run's step table"
  assert_contains "$out" "tail of step 'review'" "identifies the active step"
  assert_contains "$out" "reviewing diff..." "shows the active step's log tail"
  pass "resolves the worktree from meta and shows the active run's step and log tail"
}

test_active_step_falls_through_to_top_level_ci_status() {
  local d; d=$(new_case ci-status)
  make_repo "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-m.meta" "window=fm:fm-feat-m" "worktree=$d/wt" "kind=ship"
  # No steps[] table and no gate: scalar - only a top-level `status: ci` line,
  # the third and last branch active_step() falls through to once neither of
  # the other two matches.
  FM_FAKE_AXI_STATUS=$'run:\n  id: "01RUN"\nstatus: ci'
  FM_FAKE_AXI_LOGS="waiting on checks..."
  local out rc
  out=$(run_tick "$d" feat-m); rc=$?
  expect_code 0 "$rc" "a ci-status run keeps ticking (exit 0)"
  assert_contains "$out" "tail of step 'ci'" "falls through to the top-level status: ci branch when no steps table or gate field matches"
  assert_contains "$out" "waiting on checks..." "shows the ci step's log tail"
  pass "active_step falls through to the top-level 'status: ci' branch when neither a steps-table row nor a gate field matches"
}

test_no_active_run_is_graceful() {
  local d; d=$(new_case norun)
  make_repo "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-b.meta" "window=fm:fm-feat-b" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS=""
  local out rc
  out=$(run_tick "$d" feat-b); rc=$?
  expect_code 0 "$rc" "no active run keeps polling (exit 0)"
  assert_contains "$out" "no active no-mistakes run yet" "reports no active run gracefully"
  pass "no active run degrades gracefully instead of erroring"
}

test_terminal_outcome_is_detected() {
  local d; d=$(new_case outcome-passed)
  make_repo "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-c.meta" "window=fm:fm-feat-c" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS=$'run:\n  id: "01RUN"\n  status: completed\noutcome: passed'
  local out rc
  out=$(run_tick "$d" feat-c); rc=$?
  expect_code 1 "$rc" "a terminal outcome reports terminal (exit 1)"
  assert_contains "$out" "run finished: outcome=passed" "surfaces the outcome"
  pass "a terminal outcome ends the tick as terminal, run finished"
}

test_torn_down_missing_meta_is_graceful() {
  local d; d=$(new_case nometa)
  make_fakebin "$d" >/dev/null
  local out rc
  out=$(run_tick "$d" ghost); rc=$?
  expect_code 1 "$rc" "missing meta is terminal (exit 1)"
  assert_contains "$out" "no metadata found" "reports missing metadata"
  pass "a task that never existed (or was already torn down) is handled gracefully"
}

test_torn_down_worktree_is_graceful() {
  local d; d=$(new_case nowt)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-d.meta" "window=fm:fm-feat-d" "worktree=$d/no-such-worktree" "kind=ship"
  local out rc
  out=$(run_tick "$d" feat-d); rc=$?
  expect_code 1 "$rc" "a torn-down worktree is terminal (exit 1)"
  assert_contains "$out" "worktree gone" "reports the worktree is gone"
  pass "a torn-down worktree (teardown already ran) is handled gracefully"
}

test_missing_no_mistakes_cli_is_graceful() {
  local d minbin out rc
  d=$(new_case nocli)
  make_repo "$d/wt"
  fm_write_meta "$d/state/feat-e.meta" "window=fm:fm-feat-e" "worktree=$d/wt" "kind=ship"
  # A PATH with just enough (env/bash to launch the script, git for its own
  # tooling) to run, but no-mistakes nowhere on it.
  minbin=$(dirname "$(command -v env)"):$(dirname "$(command -v bash)"):$(dirname "$(command -v git)")
  out=$(PATH="$minbin" FM_STATE_OVERRIDE="$d/state" "$MONITOR" --tick feat-e); rc=$?
  expect_code 1 "$rc" "missing no-mistakes CLI is terminal (exit 1)"
  assert_contains "$out" "no-mistakes CLI not found" "reports the missing CLI"
  pass "a missing no-mistakes CLI is handled gracefully"
}

test_never_calls_respond_or_abort() {
  local d; d=$(new_case readonly)
  make_repo "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f.meta" "window=fm:fm-feat-f" "worktree=$d/wt" "kind=ship"
  # A parked run with an ask-user finding - the one state where a DRIVING
  # agent would call `axi respond`. The monitor must only ever display it.
  FM_FAKE_AXI_STATUS=$'run:\n  id: "01RUN"\n  status: awaiting_approval\n  awaiting_agent: parked 2m10s\n  findings[1]{id,severity,file,line,action,description}:\n    r1,error,b.go,,ask-user,changes product behavior\ngate: review'
  FM_FAKE_AXI_LOGS="waiting for a decision..."
  local forbidden_log="$d/forbidden.log"
  local out rc
  out=$(PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" FM_FAKE_FORBIDDEN_LOG="$forbidden_log" "$MONITOR" --tick feat-f); rc=$?
  expect_code 0 "$rc" "a parked run is not terminal, keeps polling (exit 0)"
  assert_contains "$out" "gate: review" "displays the parked gate"
  assert_contains "$out" "tail of step 'review'" "identifies the scalar gate as the active step"
  assert_absent "$forbidden_log" "axi respond/abort must never be invoked while displaying a parked run"
  pass "a parked (ask-user) run is displayed without ever calling axi respond or axi abort"
}

test_cli_error_blob_is_graceful() {
  local d; d=$(new_case cli-error)
  make_repo "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-j.meta" "window=fm:fm-feat-j" "worktree=$d/wt" "kind=ship"
  # no-mistakes prints its own errors to stdout, not stderr (e.g. when the
  # repo is not yet registered); nm_bounded discards stderr/exit status, so
  # this blob reaches monitor_tick indistinguishable from a real status block
  # unless it is explicitly recognized.
  FM_FAKE_AXI_STATUS="error: repo not initialized (run 'no-mistakes init' first)"
  local out rc
  out=$(run_tick "$d" feat-j); rc=$?
  expect_code 0 "$rc" "a CLI error blob keeps polling, not terminal (exit 0)"
  assert_contains "$out" "no active no-mistakes run yet" "a CLI error is shown as no active run, not displayed as a raw status block"
  assert_not_contains "$out" "error: repo not initialized" "the raw CLI error text is not echoed forever as if it were a status block"
  pass "a no-mistakes CLI error blob on stdout degrades gracefully instead of being displayed forever"
}

test_usage_errors() {
  local rc
  "$MONITOR" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "no-arg usage error exits 2"
  "$MONITOR" --loop >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "--loop without an id exits 2"
  "$MONITOR" --tick >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "--tick without an id exits 2"
  "$MONITOR" --help >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "--help exits 0"
  pass "usage errors exit 2, --help exits 0"
}

test_resolves_worktree_and_shows_active_run
test_active_step_falls_through_to_top_level_ci_status
test_no_active_run_is_graceful
test_terminal_outcome_is_detected
test_torn_down_missing_meta_is_graceful
test_torn_down_worktree_is_graceful
test_missing_no_mistakes_cli_is_graceful
test_never_calls_respond_or_abort
test_cli_error_blob_is_graceful
test_usage_errors

# --- real-tmux window management --------------------------------------------
#
# Isolated on a private socket (`-L`), exactly like
# tests/fm-backend-tmux-smoke.test.sh, so it never touches the host's actual
# tmux sessions. tmux captures the spawning client's environment into the
# server's GLOBAL environment ONCE, at server start (verified empirically: a
# later command's own env changes do not reach windows created after it,
# `tmux set-environment` does) - so PATH (the tmux shim plus the fake
# no-mistakes) and FM_STATE_OVERRIDE are set BEFORE the private server's first
# `new-session`, and every window this script's own `tmux new-window` call
# spawns after that (including the `--loop` subprocess it launches) inherits
# them; per-test fake data (FM_FAKE_AXI_STATUS etc.) is pushed with
# `set-environment` right before the call that triggers window creation, since
# that IS reflected in windows created afterward.
if command -v tmux >/dev/null 2>&1; then
  REAL_TMUX=$(command -v tmux)
  SOCKET="fm-pipeline-monitor-$$"
  TMUX_SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-pipeline-monitor-tmux.XXXXXX")
  FM_TEST_CLEANUP_DIRS+=("$TMUX_SHIM_DIR")

  SOCKET2=""
  cleanup_tmux() {
    "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    [ -z "$SOCKET2" ] || "$REAL_TMUX" -L "$SOCKET2" kill-server >/dev/null 2>&1 || true
    fm_test_cleanup
  }
  trap cleanup_tmux EXIT

  cat > "$TMUX_SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
  chmod +x "$TMUX_SHIM_DIR/tmux"

  D=$(new_case tmux-window)
  make_repo "$D/wt"
  FB=$(make_fakebin "$D")
  TMUX_ENV_PATH="$TMUX_SHIM_DIR:$FB:$PATH"

  tmuxp() { PATH="$TMUX_ENV_PATH" tmux "$@"; }  # tmux, through the private-socket shim

  # Start the private server with the env every later window must inherit.
  PATH="$TMUX_ENV_PATH" FM_STATE_OVERRIDE="$D/state" \
    tmux new-session -d -s smoke -n fm-feat-g -x 200 -y 50 \
    || fail "real tmux: failed to start the private-socket session"
  # Backstop for every spawned --loop below: never let a real monitor loop
  # spin unbounded in this suite, regardless of what any individual test
  # expects to happen. A genuinely active run (TICK_WAS_EMPTY=0, e.g. status:
  # running) never counts toward this, so it does not interfere with the
  # reuse test below, which deliberately keeps its window alive.
  tmuxp set-environment FM_PIPELINE_MONITOR_MAX_EMPTY_TICKS 3

  test_opens_and_reuses_window() {
    fm_write_meta "$D/state/feat-g.meta" "window=smoke:fm-feat-g" "worktree=$D/wt" "kind=ship"
    tmuxp set-environment FM_FAKE_AXI_STATUS $'run:\n  id: "01RUN"\n  status: running\n  steps[1]{step,status,findings,duration_ms}:\n    review,running,0,0'
    tmuxp set-environment FM_FAKE_AXI_LOGS "still going"
    tmuxp set-environment FM_PIPELINE_MONITOR_INTERVAL 1

    local out
    out=$(PATH="$TMUX_ENV_PATH" FM_STATE_OVERRIDE="$D/state" "$MONITOR" feat-g)
    assert_contains "$out" "opened smoke:fm-monitor-feat-g" "first call opens the monitor window"
    tmuxp list-windows -t smoke -F '#{window_name}' | grep -qx fm-monitor-feat-g \
      || fail "monitor window fm-monitor-feat-g was not created in the crewmate's session"

    out=$(PATH="$TMUX_ENV_PATH" FM_STATE_OVERRIDE="$D/state" "$MONITOR" feat-g)
    assert_contains "$out" "reusing existing window smoke:fm-monitor-feat-g" "second call reuses the window"
    local count
    count=$(tmuxp list-windows -t smoke -F '#{window_name}' | grep -cx fm-monitor-feat-g)
    [ "$count" -eq 1 ] || fail "reusing the monitor window must not create a duplicate (found $count)"

    tmuxp kill-window -t smoke:fm-monitor-feat-g >/dev/null 2>&1 || true
    pass "real tmux: opens the monitor window once and reuses it on a second call"
  }

  test_window_closes_on_terminal_outcome() {
    fm_write_meta "$D/state/feat-h.meta" "window=smoke:fm-feat-g" "worktree=$D/wt" "kind=ship"
    tmuxp set-environment FM_FAKE_AXI_STATUS $'run:\n  id: "01RUN"\n  status: completed\noutcome: passed'
    tmuxp set-environment FM_PIPELINE_MONITOR_INTERVAL 1
    tmuxp set-environment FM_PIPELINE_MONITOR_CLOSE_DELAY 1

    local out
    out=$(PATH="$TMUX_ENV_PATH" FM_STATE_OVERRIDE="$D/state" "$MONITOR" feat-h)
    assert_contains "$out" "opened smoke:fm-monitor-feat-h" "opens the monitor window for feat-h"

    local waited=0
    while PATH="$TMUX_ENV_PATH" tmux list-windows -t smoke -F '#{window_name}' 2>/dev/null | grep -qx fm-monitor-feat-h; do
      sleep 1
      waited=$((waited + 1))
      [ "$waited" -lt 15 ] || fail "monitor window did not close itself after a terminal outcome"
    done
    pass "real tmux: the monitor window closes itself once the run reaches a terminal outcome"
  }

  test_non_tmux_backend_is_noop() {
    fm_write_meta "$D/state/feat-i.meta" "window=smoke:fm-feat-g" "worktree=$D/wt" "kind=ship" "backend=herdr"
    local errfile="$D/feat-i.stderr" out err rc
    out=$(PATH="$TMUX_ENV_PATH" FM_STATE_OVERRIDE="$D/state" "$MONITOR" feat-i 2>"$errfile") ; rc=$?
    err=$(cat "$errfile" 2>/dev/null || true)
    rm -f "$errfile"
    expect_code 0 "$rc" "a non-tmux backend exits 0 (never blocks the caller)"
    assert_contains "$out$err" "tmux-only" "explains live tailing is tmux-only for this task's backend"
    PATH="$TMUX_ENV_PATH" tmux list-windows -t smoke -F '#{window_name}' 2>/dev/null | grep -qx fm-monitor-feat-i \
      && fail "a non-tmux-backend task must never get a monitor window"
    pass "real tmux: a task on a non-tmux backend no-ops with a pointer instead of touching tmux"
  }

  # A SEPARATE private server, started WITHOUT FM_STATE_OVERRIDE or FM_HOME in
  # its own start-time env, proves the spawned --loop process resolves the
  # CALLING process's state dir via the new env-prefix forwarding fix - not
  # by accident, the way the tests above could (their shared "smoke" server
  # happens to have FM_STATE_OVERRIDE baked into its own start env already).
  test_env_forwarding_reaches_spawned_pane() {
    SOCKET2="fm-pipeline-monitor-noenv-$$"
    local d2 fb2 shimdir2 pathnoenv
    d2=$(new_case env-forward)
    make_repo "$d2/wt"
    fb2=$(make_fakebin "$d2")
    shimdir2=$(mktemp -d "${TMPDIR:-/tmp}/fm-pipeline-monitor-tmux2.XXXXXX")
    FM_TEST_CLEANUP_DIRS+=("$shimdir2")
    cat > "$shimdir2/tmux" <<SH2
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET2" "\$@"
SH2
    chmod +x "$shimdir2/tmux"
    pathnoenv="$shimdir2:$fb2:$PATH"

    env -u FM_STATE_OVERRIDE -u FM_HOME PATH="$pathnoenv" \
      FM_PIPELINE_MONITOR_INTERVAL=1 FM_PIPELINE_MONITOR_MAX_EMPTY_TICKS=3 \
      tmux new-session -d -s smoke2 -n fm-feat-k -x 200 -y 50 \
      || fail "real tmux: failed to start the no-env private-socket session"

    fm_write_meta "$d2/state/feat-k.meta" "window=smoke2:fm-feat-k" "worktree=$d2/wt" "kind=ship"
    local out
    out=$(PATH="$pathnoenv" FM_STATE_OVERRIDE="$d2/state" "$MONITOR" feat-k)
    assert_contains "$out" "opened smoke2:fm-monitor-feat-k" "opens the monitor window in the no-env server"

    local waited=0 pane=""
    while :; do
      pane=$(PATH="$pathnoenv" tmux capture-pane -p -t smoke2:fm-monitor-feat-k 2>/dev/null || true)
      case "$pane" in *"no active no-mistakes run yet"*) break ;; esac
      case "$pane" in *"no metadata found"*) fail "spawned pane resolved the WRONG state dir - env was not forwarded: $pane" ;; esac
      waited=$((waited + 1))
      [ "$waited" -lt 15 ] || fail "spawned pane never reached a recognizable state within 15s: $pane"
      sleep 1
    done

    PATH="$pathnoenv" tmux kill-window -t smoke2:fm-monitor-feat-k >/dev/null 2>&1 || true
    "$REAL_TMUX" -L "$SOCKET2" kill-server >/dev/null 2>&1 || true
    SOCKET2=""
    pass "real tmux: FM_HOME/FM_STATE_OVERRIDE/PATH reach the spawned pane even when the tmux server's own start env has none of them"
  }

  # A monitor left open for a task that never actually starts validation must
  # not poll forever - the regression this whole suite exists to prevent (a
  # test spawning an unbounded real --loop once hung the entire suite until
  # a live process had to be killed by hand). No FM_FAKE_AXI_STATUS is ever
  # set, so every tick is empty; with MAX_EMPTY_TICKS=2 and a 1s interval the
  # window must close ITSELF within a few seconds, with NO manual kill-window
  # from this test at all - proving genuine self-termination, not test-side
  # cleanup papering over the tool's own behavior.
  test_gives_up_after_max_empty_ticks() {
    fm_write_meta "$D/state/feat-l.meta" "window=smoke:fm-feat-g" "worktree=$D/wt" "kind=ship"
    tmuxp set-environment FM_FAKE_AXI_STATUS ""
    tmuxp set-environment FM_PIPELINE_MONITOR_INTERVAL 1
    tmuxp set-environment FM_PIPELINE_MONITOR_CLOSE_DELAY 1
    tmuxp set-environment FM_PIPELINE_MONITOR_MAX_EMPTY_TICKS 2

    local out
    out=$(PATH="$TMUX_ENV_PATH" FM_STATE_OVERRIDE="$D/state" "$MONITOR" feat-l)
    assert_contains "$out" "opened smoke:fm-monitor-feat-l" "opens the monitor window for feat-l"

    local waited=0
    while tmuxp list-windows -t smoke -F '#{window_name}' 2>/dev/null | grep -qx fm-monitor-feat-l; do
      sleep 1
      waited=$((waited + 1))
      [ "$waited" -lt 15 ] || fail "monitor window did not give up and self-close after max-empty-ticks (would hang forever in production)"
    done
    # Restore the shared session's defaults for any test added after this one.
    tmuxp set-environment FM_PIPELINE_MONITOR_MAX_EMPTY_TICKS 3
    pass "real tmux: the monitor window gives up and closes itself after FM_PIPELINE_MONITOR_MAX_EMPTY_TICKS with no run ever appearing"
  }

  test_opens_and_reuses_window
  test_window_closes_on_terminal_outcome
  test_non_tmux_backend_is_noop
  test_env_forwarding_reaches_spawned_pane
  test_gives_up_after_max_empty_ticks

  cleanup_tmux
  trap - EXIT
else
  pass "real-tmux window-management tests skipped (tmux not found)"
fi

echo "all fm-pipeline-monitor tests passed"
