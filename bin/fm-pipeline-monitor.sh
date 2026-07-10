#!/usr/bin/env bash
# fm-pipeline-monitor.sh - live, read-only tail of a crewmate's no-mistakes
# validation run.
#
# Why this exists: while a crewmate drives `/no-mistakes`, the crewmate's own
# window just shows "1 shell running" plus a spinner - the pipeline's
# review/test/lint agents run as headless subprocesses, so the actual
# per-step work (which step is active, what a review agent is finding) is
# invisible without hand-running `no-mistakes axi status` / `axi logs` in the
# worktree. This opens a dedicated tmux window that does exactly that, on a
# refresh loop, so the captain (or firstmate) can just watch it.
#
# Usage:
#   fm-pipeline-monitor.sh <task-id>            open or reuse the monitor window
#   fm-pipeline-monitor.sh --loop <task-id>     (internal) run the tail loop in
#                                                the foreground; this is what the
#                                                monitor window itself runs
#   fm-pipeline-monitor.sh --tick <task-id>     (internal/test) print one status
#                                                block and exit; 0 = still in
#                                                flight, 1 = terminal (outcome
#                                                reached or torn down)
#
# Contract: OBSERVER ONLY. This script never calls `no-mistakes axi respond`
# or `no-mistakes axi abort` - it reads `axi status` and `axi logs --step` and
# nothing else. It never touches projects/ or the crewmate's worktree beyond
# `cd` for those read-only calls. It resolves the crewmate's worktree and
# backend target from state/<id>.meta the same way bin/fm-crew-state.sh does,
# but does not replace that helper: fm-crew-state.sh answers "what state is
# this crew in" for the watcher/firstmate; this script is a human-facing
# terminal view of the same underlying no-mistakes run.
#
# tmux-first: tmux is firstmate's verified reference runtime backend
# (docs/tmux-backend.md). On any other backend (herdr/zellij/orca/cmux) this
# prints a pointer to running `no-mistakes axi status`/`axi logs` directly in
# the worktree instead of opening a window - see docs/pipeline-monitor.md.
#
# The monitor window's own process exits (closing the window - tmux's default
# behavior for a window whose command process exits) once the run reaches an
# `outcome:` or the task is torn down (its meta or worktree disappears); it
# also explicitly kills its own window via $TMUX_PANE as a belt-and-braces
# cleanup in case the user's tmux.conf sets `remain-on-exit on`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

SELF="$SCRIPT_DIR/fm-pipeline-monitor.sh"

usage() {
  cat <<'EOF'
usage: fm-pipeline-monitor.sh <task-id>
       fm-pipeline-monitor.sh --loop <task-id>   (internal: runs the tail loop)
       fm-pipeline-monitor.sh --tick <task-id>   (internal/test: one status block)

Opens (or reuses) a dedicated tmux window, fm-monitor-<task-id>, that live-tails
the no-mistakes validation pipeline for <task-id>'s crewmate worktree: the run's
9-step status (`no-mistakes axi status`) plus a bounded tail of the active
step's log (`no-mistakes axi logs --step <step>`), refreshed every few seconds.

Read-only observer: never calls `axi respond` or `axi abort`. The window closes
itself once the run reaches an outcome or the task is torn down.

tmux-only for now: on any other recorded backend, prints a pointer to running
`no-mistakes axi status`/`axi logs` directly in the worktree and exits 0.
See docs/pipeline-monitor.md.
EOF
}

# --- bounded no-mistakes calls (read-only: axi status / axi logs only) -----

NM_TIMEOUT=${FM_PIPELINE_MONITOR_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac

nm_timeout_cmd() {
  if command -v timeout >/dev/null 2>&1; then
    printf 'timeout'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout'
  else
    printf 'none'
  fi
}
NM_HAVE_TIMEOUT=$(nm_timeout_cmd)

# nm_bounded: run `no-mistakes <args...>` in <worktree>, bounded by
# NM_TIMEOUT when a timeout binary is available (unbounded otherwise - this is
# a display refresh, not a correctness-critical decision, so a missing
# timeout binary degrades to "the next refresh waits a bit longer" rather
# than blocking the whole script).
nm_bounded() {  # <worktree> <args...>
  local wt=$1
  shift
  case "$NM_HAVE_TIMEOUT" in
    timeout)  ( cd "$wt" && timeout "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null || true ;;
    gtimeout) ( cd "$wt" && gtimeout "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null || true ;;
    *)        ( cd "$wt" && no-mistakes "$@" ) 2>/dev/null || true ;;
  esac
}

nm_status() {  # <worktree>
  nm_bounded "$1" axi status
}

nm_logs() {  # <worktree> <step> <lines>
  nm_bounded "$1" axi logs --step "$2" | tail -n "$3"
}

# active_step: best-effort guess at the currently active step name from an
# `axi status` TOON blob, for display only (not a state-machine decision -
# bin/fm-crew-state.sh owns that contract). Checks, in order: a steps[] table
# row whose status is running/fixing/awaiting_approval/fix_review; a scalar
# `gate:` field (parked, no steps table); a top-level `status: ci`.
active_step() {  # <status-text>
  local out=$1 step
  step=$(printf '%s\n' "$out" | grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*,[[:space:]]*"?(running|fixing|awaiting_approval|fix_review)"?[[:space:]]*,' | head -1)
  if [ -n "$step" ]; then
    step=$(printf '%s' "$step" | sed 's/^[[:space:]]*//')
    printf '%s' "${step%%,*}"
    return 0
  fi
  step=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*gate:[[:space:]]*"\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)"\{0,1\}[[:space:]]*$/\1/p' | head -1)
  if [ -n "$step" ]; then
    printf '%s' "$step"
    return 0
  fi
  if printf '%s\n' "$out" | grep -qE '^[[:space:]]*status:[[:space:]]*"?ci"?[[:space:]]*$'; then
    printf 'ci'
    return 0
  fi
  return 0
}

# monitor_tick: print one status block for <task-id>. Returns 0 while the run
# is still in flight (keep polling), 1 on a terminal condition - torn down,
# no-mistakes missing, or the run reached an outcome.
monitor_tick() {  # <task-id>
  local id=$1 meta wt status_out outcome step tail_n
  meta="$STATE/$id.meta"
  tail_n=${FM_PIPELINE_MONITOR_TAIL:-25}
  printf '=== pipeline monitor: %s ===\n' "$id"

  if [ ! -f "$meta" ]; then
    echo "task $id: no metadata found (torn down?)"
    return 1
  fi
  wt=$(fm_meta_get "$meta" worktree)
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    echo "task $id: worktree gone (torn down)"
    return 1
  fi
  if ! command -v no-mistakes >/dev/null 2>&1; then
    echo "no-mistakes CLI not found on PATH"
    return 1
  fi

  status_out=$(nm_status "$wt")
  if [ -z "$status_out" ]; then
    echo "no active no-mistakes run yet for this worktree"
    return 0
  fi
  printf '%s\n' "$status_out"

  outcome=$(printf '%s\n' "$status_out" | sed -n 's/^[[:space:]]*outcome:[[:space:]]*//p' | head -1)
  if [ -n "$outcome" ]; then
    echo "--- run finished: outcome=$outcome ---"
    return 1
  fi

  step=$(active_step "$status_out")
  if [ -n "$step" ]; then
    echo "--- tail of step '$step' ---"
    nm_logs "$wt" "$step" "$tail_n"
  fi
  return 0
}

# run_loop: the monitor window's actual command. Ticks until monitor_tick
# reports terminal, pauses so the final message is readable, then closes its
# own window.
run_loop() {  # <task-id>
  local id=$1 interval=${FM_PIPELINE_MONITOR_INTERVAL:-5}
  while :; do
    clear 2>/dev/null || true
    if ! monitor_tick "$id"; then
      sleep "${FM_PIPELINE_MONITOR_CLOSE_DELAY:-5}"
      break
    fi
    sleep "$interval"
  done
  if [ -n "${TMUX_PANE:-}" ]; then
    tmux kill-window -t "$TMUX_PANE" 2>/dev/null || true
  fi
}

# open_or_reuse_window: the default entrypoint. Resolves the crewmate's own
# tmux session from its meta and opens fm-monitor-<id> as a window in that
# same session (or reuses it if already open), running `$SELF --loop <id>` as
# the window's command.
open_or_reuse_window() {  # <task-id>
  local id=$1 meta backend window ses wname
  meta="$STATE/$id.meta"
  if [ ! -f "$meta" ]; then
    echo "error: no metadata for $id at $meta" >&2
    return 1
  fi

  backend=$(fm_backend_of_meta "$meta")
  if [ "$backend" != tmux ]; then
    echo "pipeline monitor: task $id runs on the '$backend' backend; live tailing is tmux-only for now (docs/pipeline-monitor.md)." >&2
    echo "Run directly in the worktree instead: no-mistakes axi status   /   no-mistakes axi logs --step <step>" >&2
    return 0
  fi

  window=$(fm_meta_get "$meta" window)
  if [ -z "$window" ]; then
    echo "error: no window recorded for $id in $meta" >&2
    return 1
  fi
  ses=${window%%:*}

  command -v tmux >/dev/null 2>&1 || { echo "error: tmux not found" >&2; return 1; }
  if ! tmux has-session -t "$ses" 2>/dev/null; then
    echo "error: tmux session '$ses' not found; task $id may already be torn down" >&2
    return 1
  fi

  wname="fm-monitor-$id"
  if tmux list-windows -t "$ses" -F '#{window_name}' 2>/dev/null | grep -qx "$wname"; then
    echo "pipeline monitor: reusing existing window $ses:$wname"
    return 0
  fi

  tmux new-window -d -t "$ses" -n "$wname" "$SELF" --loop "$id"
  echo "pipeline monitor: opened $ses:$wname"
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --loop)
    LOOP_ID=${2:-}
    [ -n "$LOOP_ID" ] || { usage >&2; exit 2; }
    run_loop "$LOOP_ID"
    exit 0
    ;;
  --tick)
    TICK_ID=${2:-}
    [ -n "$TICK_ID" ] || { usage >&2; exit 2; }
    monitor_tick "$TICK_ID"
    exit $?
    ;;
  '')
    usage >&2
    exit 2
    ;;
  *)
    open_or_reuse_window "$1"
    exit $?
    ;;
esac
