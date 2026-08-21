#!/usr/bin/env bash
# Claude Stop-owned watcher auto-arm (asyncRewake hook).
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "asyncRewake": true and an explicit multi-hour timeout. Claude Code fires it
# in the background on EVERY Stop of a Claude primary session, with no
# deduplication across firings. It owns routine tokenless watcher continuity
# for Claude primaries (main home and marked secondmate homes):
#
#   - Scope: only a genuine primary checkout (plain checkout or validly marked
#     secondmate home) with AGENTS.md, bin/, and the effective state dir - the
#     exact fm-turnend-guard.sh scope. Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session's harness ancestor holds state/.lock.
#     When an existing numeric owner fails the shared harness-liveness predicate,
#     the hook delegates guarded recovery to bin/fm-lock.sh and then re-verifies
#     ownership. A live owner, missing lock, malformed lock, or unresolved
#     ancestry remains inert, so a competing session never arms or rewakes.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER rewakes the primary (checked again at
#     translation time so a mid-cycle AFK transition is honored).
#   - Need: arms only while work is in flight (state/*.meta) or X mode has a
#     relay poll to run (state/x-watch.check.sh); an idle home exits 0.
#   - Single-flight: Claude does not dedupe async hooks, so a home-scoped owner
#     lock (state/.claude-autoarm.lock) admits exactly one owner; every other
#     concurrent firing exits 0 without translating, which keeps one event
#     epoch on exactly one recovery turn. A DEAD owner is reclaimed by
#     fm_lock_try_acquire; an owner that is still alive but wedged inside its own
#     foreground arm is taken over here, under the narrow test below, because it
#     would otherwise hold the claim forever and silence every later firing.
#     A takeover it performed, and a claim it could not break at all, are
#     recorded in state/.claude-autoarm-contended so neither is invisible; every
#     ordinary race stays silent, and the record is cleared only once a watcher
#     beat inside the grace window shows supervision came back, never by the next
#     successful claim. The session-start digest (bin/fm-session-start.sh) is
#     that record's one reader, and reads it without clearing it. A taken-over
#     owner that later resumes is dispossessed: it writes no epoch, resets no
#     failure state, and emits no rewake, so one cycle keeps one writer.
#   - Foreground arm: the owner runs bin/fm-watch-arm.sh in the FOREGROUND of
#     this hook-owned process tree (never shell &); Claude owns the process
#     group, so its timeout/session teardown kills arm and watcher together.
#   - Translation: while supervision is still needed and AFK remains inactive,
#     an actionable arm close (signal:/stale:/check:/heartbeat) prints one
#     rewake banner to stderr and exits 2, which wakes Claude even while idle
#     ("Stop hook feedback"). A close that reports no actionable reason is
#     benign when a live identity-matched watcher still has a fresh beacon.
#   - Failure handling: a typed failure is rechecked against the same live,
#     fresh watcher predicate and retried a bounded number of times in this
#     hook. Only an exhausted failure with no verified watcher emits one
#     last-resort notice per failure episode; later consecutive failures still
#     exit 2 to guarantee the next Stop-owned retry without repeating notice,
#     until the synchronous guard has consumed its attended fail-open.
#
# The epoch ledger state/.claude-autoarm-epoch records the latest claim and
# outcome so the synchronous Stop guard (bin/fm-turnend-guard.sh --claude) can
# allow a stop whose recovery this hook already owns, instead of forcing a
# duplicate continuation for the same event epoch. The failure marker
# state/.claude-autoarm-failure-notified deduplicates the last-resort notice,
# and state/.claude-autoarm-failure-alarmed bounds the attended fail-open and
# suppresses any later automatic continuation in that unresolved episode.
#
# This hook never blocks the Stop decision itself and never prints to stdout:
# exit 0 is always silent, and exit 2 carries the rewake banner on stderr.
# On any uncertainty such as unresolvable ancestry, malformed lock state, or
# lock contention, it exits 0 and leaves continuity to the synchronous guard and
# the model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
OWNER_LOCK="$STATE/.claude-autoarm.lock"
EPOCH="$STATE/.claude-autoarm-epoch"
FAILURE_NOTICE="$STATE/.claude-autoarm-failure-notified"
FAILURE_ALARM="$STATE/.claude-autoarm-failure-alarmed"
CONTENDED="$STATE/.claude-autoarm-contended"
AUTOARM_ATTEMPTS=${FM_CLAUDE_AUTOARM_ATTEMPTS:-2}
case "$AUTOARM_ATTEMPTS" in
  1|2|3) : ;;
  *) AUTOARM_ATTEMPTS=2 ;;
esac
# How long an owner may hold the single-flight lock before this hook will even
# consider it wedged. Kept strictly above GRACE so a watcher that the current
# owner has only just started is never mistaken for an owner with no watcher.
OWNER_WEDGE_AFTER=${FM_CLAUDE_AUTOARM_WEDGE_AFTER:-900}
case "$OWNER_WEDGE_AFTER" in
  ''|*[!0-9]*) OWNER_WEDGE_AFTER=900 ;;
esac
[ "$OWNER_WEDGE_AFTER" -gt "$GRACE" ] || OWNER_WEDGE_AFTER=$((GRACE * 3))

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

# Consume the Stop payload once. The decisions below are state-based; the
# payload is read so a slow writer can never wedge on a full pipe.
cat >/dev/null 2>&1 || true

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- identity: only the lock-owning session's hooks may arm ------------------
# A prior session may have died after leaving its numeric harness pid in .lock.
# Use the shared liveness predicate to recognize only that stale-owner case.
# Defer the mutating claim until after the unchanged AFK and need gates, so an
# idle or away home remains byte-for-byte inert. Missing or malformed locks are
# uncertainty rather than stale-owner evidence and remain inert.
RECOVER_SESSION_LOCK=0
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in
    ''|*[!0-9]*) exit 0 ;;
  esac
  fm_harness_pid_alive "$LOCK_PID" && exit 0
  RECOVER_SESSION_LOCK=1
fi

# --- AFK: the away daemon owns the watcher and triage; never rewake ----------
[ -e "$STATE/.afk" ] && exit 0

# --- need: in-flight work or an X-mode relay poll ----------------------------
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

# --- stale session-lock recovery ---------------------------------------------
# Delegate the claim to fm-lock.sh so its live-owner refusal and write semantics
# remain the single acquisition owner, then re-verify current-session identity
# before touching any auto-arm state.
if [ "$RECOVER_SESSION_LOCK" -eq 1 ]; then
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit 0
  fm_session_lock_owned_by_self "$STATE" || exit 0
fi

# --- single-flight owner claim ------------------------------------------------
# Claude runs one background process per firing with no dedupe. Exactly one
# owner foregrounds the arm and translates its close; every other firing exits
# 0 so one watcher cycle maps to at most one exit-2 rewake.
#
# fm_lock_try_acquire already reclaims a demonstrably dead owner. The remaining
# way this claim can block forever is an owner that is still ALIVE but wedged
# inside its own foreground arm: the watcher it was supposed to produce died
# under it, so it never returns, never releases, and every later firing exits 0
# in silence until an operator arms by hand.
#
# The wedge test is deliberately narrow, because a HEALTHY cycle also holds this
# lock for hours while its watcher waits for a wake. An owner counts as wedged
# only when it has held past OWNER_WEDGE_AFTER, is still alive, and has no live
# identity-matched watcher with a fresh beacon to show for it. A long cycle
# backed by a beating watcher keeps its claim, and so does a fresh concurrent
# firing; only a claim with nothing supervising behind it is taken over.
record_contention() {  # <holder-pid> <held-seconds> <outcome>
  local tmp
  tmp="$CONTENDED.tmp.$$"
  printf 'pid=%s held_for=%s outcome=%s updated_at=%s\n' \
    "$1" "$2" "$3" "$(date +%s)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$CONTENDED" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

# Evidence that supervision actually came back. This hook's model arms the
# watcher at turn end and that watcher exits on its wake, so at the next Stop
# there is normally no watcher PROCESS left to find - only the beat it left
# behind. A beacon beaten inside the grace window is therefore the model-correct
# signal here, while the pid-strict predicate below stays pid-strict, because a
# leftover beacon must never excuse a claim with nothing running behind it.
supervision_recently_beat() {
  local age
  age=$(fm_path_age "$STATE/.last-watcher-beat")
  case "$age" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$age" -lt "$GRACE" ]
}

owner_is_wedged() {  # <holder-pid> <held-seconds>
  local pid=$1 held=$2
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$held" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$held" -ge "$OWNER_WEDGE_AFTER" ] || return 1
  fm_pid_alive "$pid" || return 1
  ! fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"
}

# True when this firing owns the single-flight lock. A refusal that resolves
# itself - a concurrent firing losing an ordinary race, or an owner this hook
# cannot prove wedged - stays silent, exactly as before.
#
# An ordinary acquire does NOT clear a recorded takeover or unresolved claim:
# this hook fires on every Stop, so clearing on any successful claim would erase
# the record seconds after it was written and leave the failure invisible again.
# The record survives until a watcher beat inside the grace window shows that
# supervision came back, and while an owner is wedged with nothing supervising
# that beacon goes stale and the record is kept.
claim_owner_lock() {
  local held_pid held_for broke
  if fm_lock_try_acquire "$OWNER_LOCK"; then
    if supervision_recently_beat; then
      rm -f "$CONTENDED" 2>/dev/null || true
    fi
    return 0
  fi
  held_pid=${FM_LOCK_HELD_PID:-}
  held_for=$(fm_lock_owner_held_for "$OWNER_LOCK") || return 1
  owner_is_wedged "$held_pid" "$held_for" || return 1
  # Only a GENUINE break failure - that owner still holds the lock and it could
  # not be removed - is an unresolved claim worth recording. Both ways a peer
  # firing can beat this one to the same wedged owner are ordinary races that
  # armed supervision anyway, and stay silent like every other lost race: the
  # break finding the claim already moved on (exit 2), and losing the re-acquire
  # after a successful break.
  fm_lock_break_wedged_owner "$OWNER_LOCK" "$held_pid" && broke=0 || broke=$?
  case "$broke" in
    0) : ;;
    2) return 1 ;;
    *) record_contention "$held_pid" "$held_for" stuck; return 1 ;;
  esac
  fm_lock_try_acquire "$OWNER_LOCK" || return 1
  record_contention "$held_pid" "$held_for" broken
  return 0
}

claim_owner_lock || exit 0
CLAIM_OWNER_DIR=${FM_LOCK_OWNER_DIR:-}
if ! fm_lock_set_role "$OWNER_LOCK" autoarm; then
  fm_lock_release "$OWNER_LOCK"
  exit 0
fi
trap 'fm_lock_release "$OWNER_LOCK"' EXIT

# The takeover above removes a wedged owner's claim but deliberately leaves that
# process running, so this hook must never assume it still holds what it claimed.
# A dispossessed owner that finally resumes - a blocked arm waking after the
# machine slept - would otherwise bump the epoch its successor now owns, clear
# the successor's failure markers, and emit a second rewake banner for a single
# watcher cycle. The epoch ledger has one writer only while this holds.
still_owns_claim() {
  local pid
  if [ -n "$CLAIM_OWNER_DIR" ] && [ -L "$OWNER_LOCK" ]; then
    fm_lock_points_to_owner "$OWNER_LOCK" "$CLAIM_OWNER_DIR" || return 1
  fi
  pid=$(cat "$OWNER_LOCK/pid" 2>/dev/null || true)
  [ "$pid" = "${BASHPID:-$$}" ]
}

write_epoch() {  # <outcome>
  local outcome=$1 seq tmp
  seq=$(sed -n 's/^epoch=\([0-9][0-9]*\) .*/\1/p' "$EPOCH" 2>/dev/null || true)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  tmp="$EPOCH.tmp.$$"
  printf 'epoch=%s owner_pid=%s outcome=%s updated_at=%s\n' \
    "$seq" "${BASHPID:-$$}" "$outcome" "$(date +%s)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$EPOCH" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

write_epoch arming

# X mode cadence: source the generated config so an X instance polls at its
# 30s cadence (fm-bootstrap.sh x_mode_setup contract).
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# --- foreground the real arm wrapper ------------------------------------------
# NO shell &: this hook process tree is the harness-owned lifecycle. The arm
# forks the watcher as its own tracked child exactly as it does for the
# model-driven background-task path, and propagates the wake reason on close.
# Every non-actionable close is checked against the same identity-matched live
# watcher and fresh-beacon predicate used by the turn-end guard before it is
# retried or translated into an operator-visible failure.
OUT=
ACTIONABLE=0
HEALTHY=0
attempt=0
while [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ]; do
  attempt=$((attempt + 1))
  OUT=$(mktemp "$STATE/.claude-autoarm-output.XXXXXX") || OUT=
  if [ -n "$OUT" ]; then
    "$SCRIPT_DIR/fm-watch-arm.sh" >"$OUT" 2>&1 || true
  else
    "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 || true
  fi

  # Ownership first: everything below this point writes shared auto-arm state,
  # and a claim taken over while this arm was blocked belongs to its successor.
  if ! still_owns_claim; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi

  # AFK may have appeared mid-cycle: the daemon owns triage now, so suppress
  # every subsequent classification and handoff.
  if [ -e "$STATE/.afk" ]; then
    write_epoch afk
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi

  ACTIONABLE=0
  if [ -n "$OUT" ]; then
    grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" 2>/dev/null && ACTIONABLE=1
  fi
  [ "$ACTIONABLE" -eq 1 ] && break

  # A non-actionable close is benign when another verified watcher already owns
  # this home and is still beating within the shared grace window.
  if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    HEALTHY=1
    break
  fi
  [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ] || break
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  OUT=
done

# The need may have vanished mid-cycle (fleet torn down, X opted out): nothing
# left to supervise, so close quietly instead of waking the model.
if ! need_supervision; then
  write_epoch clean
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$HEALTHY" -eq 1 ]; then
  if fm_failure_episode_reset "$STATE"; then
    write_epoch clean
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  write_epoch failed-suppressed
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  [ -e "$FAILURE_ALARM" ] && exit 0
  exit 2
fi

# After the synchronous guard has consumed the episode's attended fail-open,
# do not create another exit-2 continuation that could defeat it.
if [ -e "$FAILURE_ALARM" ]; then
  write_epoch failed-suppressed
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$ACTIONABLE" -eq 1 ]; then
  write_epoch rewake
  {
    printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
    [ -n "$OUT" ] && grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
  } >&2
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 2
fi

# Notify only once for this continuous failure episode; every later invocation
# still exits 2 so Claude must continue into another Stop-owned retry without
# creating a repeated operator notice or manual-arm loop.
if [ ! -e "$FAILURE_NOTICE" ]; then
  write_epoch failed
  {
    printf 'firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism is broken after %s bounded attempts, and no live watcher with a fresh beacon was verified.\n' "$attempt"
    [ -n "$OUT" ] && grep -E '^(watcher:|signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n'
  } >&2
  : > "$FAILURE_NOTICE" 2>/dev/null || true
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 2
fi
write_epoch failed-suppressed
[ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
exit 2
