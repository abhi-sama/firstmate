#!/usr/bin/env bash
# tests/fm-afk-preflight-e2e.test.sh - the away-mode entry pre-flight
# (bin/fm-supervise-daemon.sh's afk_preflight_composer and its startup gate).
#
# Task fm-afk-composer-wedge. Away mode delegates every captain-facing
# escalation to a supervisor composer the daemon must be able to classify. When
# it cannot, the injector defers on every cycle and the captain hears nothing
# until they return: the incident that added this gate sat on a review-ready PR
# for 3h16m while the max-defer alarm escalated by logging louder. The captain
# is present at ENTRY, so the daemon refuses there instead.
#
# These run the real daemon executable against a real tmux pane on a private
# socket, so the composer verdict comes from the production classifier rather
# than a stub that could only confirm its own assumption:
#
#   1. A pane sitting at a bare shell prompt is the dead-shell `unknown` case.
#      Away mode must REFUSE, exit non-zero, say why, and clear state/.afk so
#      firstmate does not believe a daemon owns supervision while none does.
#   2. FM_AFK_PREFLIGHT=0 must start anyway, so the gate is never a dead end.
#   3. A pane drawing a real agent composer must be ACCEPTED, proving the gate
#      refuses unreadable panes rather than refusing everything.
#   4. With away mode off the gate never fires: ordinary supervision does not
#      inject, and refusing to supervise would be the worse failure.
#
# The gate alone is not enough, which the last group covers. On the documented
# claude path the daemon is launched by the captain's own in-pane background
# tool, so at ENTRY the agent is mid-turn and the pane only reads `busy` - the
# state the incident itself started from. composer_readiness_watch therefore
# keeps proving readability for as long as away mode lasts, and alarms on an
# idle composer that stays unreadable EVEN WITH AN EMPTY BUFFER: the max-defer
# alarm keys off an escalation that is already stuck, so it cannot warn before
# the first one is swallowed.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="afk-preflight-$$"
TMP_ROOT=
SHIM_DIR=

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup_all() {
  [ -n "${REAL_TMUX:-}" ] && "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "${TMP_ROOT:-}" "${SHIM_DIR:-}" 2>/dev/null || true
}
trap cleanup_all EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-preflight.XXXXXX")
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"

# A tmux shim first on PATH sends the daemon's bare `tmux` calls to the private
# socket, exactly as tests/fm-afk-inject-e2e.test.sh does.
SHIM_DIR="$TMP_ROOT/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/tmux" <<SHIM
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SHIM
chmod +x "$SHIM_DIR/tmux"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s pf -x 100 -y 30 2>/dev/null \
  || { echo "skip: could not start a private tmux server"; exit 0; }
PANE=$("$REAL_TMUX" -L "$SOCKET" list-panes -t pf -F '#{pane_id}' | head -1)

# run_daemon <afk-on|afk-off> [env assignments...] -> rc; stdout+stderr in $OUT
OUT=
run_daemon() {
  local afk=$1; shift
  local rc=0
  rm -f "$STATE/.afk" "$STATE/.supervise-daemon.log"
  rm -rf "$STATE/.supervise-daemon.lock" 2>/dev/null || true
  [ "$afk" = afk-on ] && date '+%s' > "$STATE/.afk"
  OUT=$(
    PATH="$SHIM_DIR:$PATH" \
    FM_STATE_OVERRIDE="$STATE" \
    FM_SUPERVISOR_TARGET="$PANE" \
    FM_SUPERVISOR_BACKEND=tmux \
    FM_AFK_PREFLIGHT_SAMPLES=2 \
    FM_AFK_PREFLIGHT_SLEEP=0 \
    FM_WEDGE_ALARM_EXEC=discard \
    env "$@" "$DAEMON" 2>&1
  ) || rc=$?
  return "$rc"
}

# A daemon that PASSES the gate runs forever, so the accept cases are proven by
# waiting for the line they expect and then stopping it, not by exit status.
# run_daemon_bg <afk-on|afk-off> <await-regex> [env assignments...]
DAEMON_BG=
run_daemon_bg() {
  local afk=$1 await=$2; shift 2
  local log="$STATE/.supervise-daemon.log" i=0
  rm -f "$STATE/.afk" "$log"
  rm -rf "$STATE/.supervise-daemon.lock" 2>/dev/null || true
  if [ "$afk" = afk-on ]; then date '+%s' > "$STATE/.afk"; fi
  PATH="$SHIM_DIR:$PATH" \
  FM_STATE_OVERRIDE="$STATE" \
  FM_SUPERVISOR_TARGET="$PANE" \
  FM_SUPERVISOR_BACKEND=tmux \
  FM_AFK_PREFLIGHT_SAMPLES=2 \
  FM_AFK_PREFLIGHT_SLEEP=0 \
  FM_WEDGE_ALARM_EXEC=discard \
  env "$@" "$DAEMON" >"$TMP_ROOT/bg.log" 2>&1 &
  DAEMON_BG=$!
  # Wait for the expected line, up to ~20s, so a slow start cannot look like a
  # missing one. The daemon is killed only after the line lands or time runs out.
  while [ "$i" -lt 200 ]; do
    if [ -s "$log" ] && grep -qE "$await" "$log" 2>/dev/null; then break; fi
    kill -0 "$DAEMON_BG" 2>/dev/null || break
    i=$((i + 1))
    sleep 0.1
  done
  kill "$DAEMON_BG" 2>/dev/null || true
  wait "$DAEMON_BG" 2>/dev/null || true
  return 0
}

# The real claude composer shape, including the TITLED rule from the incident.
write_composer_fixture() { printf '%s' "$TMP_ROOT/composer.sh"; }

# --- 1. dead shell at a bare prompt: refuse ---------------------------------
test_bare_shell_refuses_away_mode() {
  # A plain interactive shell prompt is the dead-shell shape the composer guard
  # exists to refuse; it is `unknown` and no amount of waiting resolves it.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE" 'PS1="$ "; clear' Enter
  sleep 1
  local rc=0
  run_daemon afk-on || rc=$?
  [ "$rc" -ne 0 ] || fail "away mode must refuse to start on an unclassifiable composer (exit was 0)"
  case "$OUT" in
    *'away mode refused'*) ;;
    *) fail "refusal must say what happened, got: $OUT" ;;
  esac
  case "$OUT" in
    *FM_AFK_PREFLIGHT=0*) ;;
    *) fail "refusal must name the override so the gate is not a dead end, got: $OUT" ;;
  esac
  [ ! -f "$STATE/.afk" ] \
    || fail "a refused daemon must clear away mode, not leave supervision unowned"
  grep -q 'away-mode preflight FAILED' "$STATE/.supervise-daemon.log" \
    || fail "the refusal must be recorded durably in the daemon log"
  # The resolution diagnostic the incident lacked must survive the refusal.
  grep -q 'daemon starting.*target=.*backend=' "$STATE/.supervise-daemon.log" \
    || fail "target/backend resolution must be logged even when the pre-flight refuses"
  pass "away-mode entry refuses an unclassifiable composer, says why, and disarms away mode"
}

# --- 2. the override still starts -------------------------------------------
test_override_starts_anyway() {
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE" 'PS1="$ "; clear' Enter
  sleep 1
  run_daemon_bg afk-on 'FM_AFK_PREFLIGHT=0; starting anyway' FM_AFK_PREFLIGHT=0
  grep -q 'FM_AFK_PREFLIGHT=0; starting anyway' "$STATE/.supervise-daemon.log" \
    || fail "FM_AFK_PREFLIGHT=0 must start the daemon and record that it bypassed the gate"
  pass "FM_AFK_PREFLIGHT=0 bypasses the gate deliberately and says so"
}

# --- 3. a real agent composer is accepted -----------------------------------
test_readable_composer_starts() {
  # Real claude's composer shape, including the TITLED rule that caused the
  # incident: a transcript line, the session title written into the rule above
  # the `❯` row, the closing rule, and the footer, with the cursor left on the
  # composer row. Written to a script and run, because send-keys cannot carry
  # the embedded newlines reliably.
  local composer
  composer=$(write_composer_fixture)
  cat > "$composer" <<'COMPOSER'
clear
printf 'transcript line\n'
printf '\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500 Some Session Title \u2500\n'
printf '\u276f \n'
printf '\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n'
printf '  bypass permissions on\n'
printf '\033[3A\033[2C'
read -r _
COMPOSER
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE" "clear; bash '$composer'" Enter
  sleep 2
  run_daemon_bg afk-on 'away-mode preflight: supervisor composer readable'
  grep -q 'away-mode preflight: supervisor composer readable' "$STATE/.supervise-daemon.log" \
    || fail "a classifiable composer must pass the gate; log: $(cat "$STATE/.supervise-daemon.log" 2>/dev/null)"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE" Enter
  sleep 1
  pass "a classifiable agent composer passes the away-mode entry gate"
}

# --- 4. the gate is away-mode only ------------------------------------------
test_gate_is_away_mode_only() {
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE" 'PS1="$ "; clear' Enter
  sleep 1
  run_daemon_bg afk-off 'daemon starting'
  grep -q 'daemon starting' "$STATE/.supervise-daemon.log" \
    || fail "ordinary supervision must still start on an unreadable pane"
  grep -q 'away-mode preflight' "$STATE/.supervise-daemon.log" \
    && fail "the pre-flight must not run when away mode is off"
  pass "the pre-flight gates away mode only; ordinary supervision is never refused"
}

# --- 5. the readiness watch: the half the max-defer alarm cannot do ----------
# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervise-daemon.sh"

# Drive the watch directly so the elapsed window is exact rather than waited out.
# Every call runs the production function against the real tmux pane.
readiness_env() {
  # These cases call the production functions IN THIS SHELL, so the private-socket
  # shim must be on PATH here too. Without it their bare `tmux` calls reach the
  # operator's real server, where the same pane id may name a live pane.
  PATH="$SHIM_DIR:$PATH"
  export PATH
  LOG="$STATE/.supervise-daemon.log"
  FM_SUPERVISOR_TARGET="$PANE"
  FM_SUPERVISOR_BACKEND=tmux
  FM_COMPOSER_UNREADABLE_SECS=300
  FM_WEDGE_ALARM_EXEC="$TMP_ROOT/notify.sh"
  export FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND FM_COMPOSER_UNREADABLE_SECS FM_WEDGE_ALARM_EXEC
  # The sourced daemon's alarm rate-limit clock. Reset per case so one case's
  # alarm cannot suppress the next one's. ShellCheck cannot see the use because
  # the daemon that reads it is sourced, not declared here.
  # shellcheck disable=SC2034
  WEDGE_ALARM_LAST_EPOCH=0
  cat > "$TMP_ROOT/notify.sh" <<'NOTIFY'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$FM_NOTIFY_LOG"
NOTIFY
  chmod +x "$TMP_ROOT/notify.sh"
  FM_NOTIFY_LOG="$TMP_ROOT/notify.log"
  export FM_NOTIFY_LOG
  : > "$FM_NOTIFY_LOG"
  : > "$LOG"
  rm -f "$STATE/.subsuper-composer-unreadable" "$STATE/.subsuper-escalations"
  date '+%s' > "$STATE/.afk"
}

test_readiness_alarms_with_an_empty_buffer() {
  readiness_env
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE" 'PS1="$ "; clear' Enter
  sleep 1
  # First idle observation only starts the clock.
  composer_readiness_watch "$STATE"
  [ -e "$STATE/.subsuper-composer-unreadable" ] \
    || fail "an unreadable idle composer must start the readiness clock"
  [ ! -s "$TMP_ROOT/notify.log" ] \
    || fail "the first unreadable observation must not alarm; it could still be a redraw"
  # Age the marker past the window; the buffer stays deliberately EMPTY.
  echo $(( $(date '+%s') - 400 )) > "$STATE/.subsuper-composer-unreadable"
  [ ! -s "$STATE/.subsuper-escalations" ] || fail "this case must run with an empty buffer"
  composer_readiness_watch "$STATE"
  grep -q 'composer has been UNREADABLE' "$LOG" \
    || fail "a sustained unreadable composer must be reported; log: $(cat "$LOG")"
  grep -q 'composer unreadable' "$TMP_ROOT/notify.log" \
    || fail "the readiness alarm must reach the captain's alert channel, not just the log"
  pass "an unreadable composer alarms on its own, before any escalation is swallowed"
}

test_readiness_clears_when_composer_returns() {
  readiness_env
  echo $(( $(date '+%s') - 400 )) > "$STATE/.subsuper-composer-unreadable"
  local composer
  composer=$(write_composer_fixture)
  [ -s "$composer" ] || fail "the composer fixture must exist before the readiness recovery case"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE" "clear; bash '$composer'" Enter
  sleep 2
  composer_readiness_watch "$STATE"
  [ ! -e "$STATE/.subsuper-composer-unreadable" ] \
    || fail "a composer that becomes readable again must clear the alarm state"
  grep -q 'composer readable again' "$LOG" || fail "recovery must be recorded"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE" Enter
  sleep 1
  pass "the readiness watch clears itself when the composer becomes readable again"
}

test_readiness_ignores_a_busy_pane_and_afk_off() {
  readiness_env
  # A pane mid-turn says nothing about the idle composer, so it must not accrue.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE" 'clear; printf "esc to interrupt\n"; sleep 30' Enter
  sleep 1
  if pane_is_busy "$PANE" tmux; then
    composer_readiness_watch "$STATE"
    [ ! -e "$STATE/.subsuper-composer-unreadable" ] \
      || fail "a busy pane must not accumulate unreadable time"
    pass "a busy pane is skipped, not counted against the composer"
  else
    printf '# busy signature not reproducible in this harness; skipping the busy half\n'
  fi
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE" C-c
  sleep 1
  # Away mode off: the watch must do nothing at all.
  readiness_env
  rm -f "$STATE/.afk"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE" 'PS1="$ "; clear' Enter
  sleep 1
  composer_readiness_watch "$STATE"
  [ ! -e "$STATE/.subsuper-composer-unreadable" ] \
    || fail "the readiness watch must be inert when away mode is off"
  pass "the readiness watch is inert outside away mode"
}

test_bare_shell_refuses_away_mode
test_override_starts_anyway
test_readable_composer_starts
test_gate_is_away_mode_only
test_readiness_alarms_with_an_empty_buffer
test_readiness_clears_when_composer_returns
test_readiness_ignores_a_busy_pane_and_afk_off
