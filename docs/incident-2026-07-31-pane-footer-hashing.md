# Incident 2026-07-31: pane-footer hashing blinded stale detection

A crewmate died mid-turn and sat idle for roughly 1.5 hours with nothing surfaced.
The watcher was alive the whole time with a fresh beacon, so `bin/fm-guard.sh` correctly stayed silent.
This was not a watcher-liveness failure.

## What happened

A crewmate on the `claude` harness ran a single turn for 8h11m, producing ~6000 lines of work.
The turn died on `API Error: Connection closed mid-response`, leaving the agent alive at an idle prompt with everything uncommitted.
It sat idle for about 1.5 hours before a human happened to look.

Evidence from `state/` at the time:

- `state/.watch-triage.log` showed an unbroken run of `absorbed heartbeat (no captain-relevant change)`, widening all night: `20:10, 20:30, 20:40, 20:50, 21:11, 21:21, 21:35, 21:58, 22:18, 22:42, 22:52, 23:02, 23:12, 23:23, 23:33, 23:44, 00:04, 00:45, 02:22, 04:41, 07:06`.
  The turn died at ~07:06; the next heartbeat was not due until ~09:00.
- No `state/.stale-firstmate_fm-scoursh-libcore-s2` file existed at all.
- The task's only status line, written ~8 hours earlier, was a `working:` note.
  No turn-end marker was ever written, because the turn never ended.

A second, independent observation the same day: a live session reported repeated wakes reading literally `stale: firstmate:fm-scoursh-libcore-s2` for an idle claude pane, minutes apart, over an extended period.
Those two observations look contradictory - one says stale detection never fired, the other says it fired over and over for the same pane - and reconciling them is what located the defect.

## Root cause

An idle claude pane is never byte-stable.
Its footer carries a live session-duration clock, a running cost figure and a context gauge, all of which advance on a pane doing no work at all.

Measured against the live pane on 2026-07-31, sampling the same window every 20s.
`body` is the capture's non-blank lines minus the trailing 6 (the footer block `window_is_busy` already scans); `full` is the whole capture, which is what the watcher hashed:

```
$ body() { tmux capture-pane -p -t "$1" -S -40 | grep -v '^[[:space:]]*$' \
    | awk -v n=6 '{b[NR]=$0} END {for(i=1;i<=NR-n;i++) print b[i]}'; }
$ for i in 1 2 3 4 5 6 7 8; do
    printf 'body=%s  full=%s\n' \
      "$(body 'firstmate:fm-scoursh-libcore-s2' | md5 -q | cut -c1-8)" \
      "$(tmux capture-pane -p -t 'firstmate:fm-scoursh-libcore-s2' -S -40 | md5 -q | cut -c1-8)"
    sleep 20
  done
body=a90b1a44  full=12c54d9b
body=a90b1a44  full=12c54d9b
body=a90b1a44  full=12c54d9b
body=a90b1a44  full=fd957f3d
body=a90b1a44  full=fd957f3d
body=a90b1a44  full=fd957f3d
body=a90b1a44  full=d2249e2e
body=a90b1a44  full=d2249e2e
```

The body hash held constant across 160s of a completely idle pane; the full-capture hash changed three times, once per minute.
The footer line responsible:

```
  Opus 5 · effort:high · scoursh  ⎇ fm/scoursh-libcore-s2 · ██████░░░░ 68% (678k/1M) · 9h47m · +6961/-77 · $88.95
```

`9h47m` becomes `9h48m` becomes `9h49m`, forever, with no agent running.

The same measurement against a genuinely busy pane shows the discrimination is real, not an artifact - there the body moves every sample:

```
busy-crew body=32c2970e full=b3fd9a10
busy-crew body=d04a3bd1 full=717dbc5a
busy-crew body=53b7a589 full=a3cfc411
busy-crew body=8f332151 full=344a9c66
```

`bin/fm-watch.sh` anchored all of its stale bookkeeping - `.hash-*`, `.count-*`, `.stale-*`, `.stale-since-*`, `.wedge-escalations-*` - to the full-capture hash.
A footer tick therefore invalidated every one of them once a minute, on a pane doing nothing.
That single defect produces both observed behaviours, depending only on what `crew_is_provably_working` returned:

- **Crew reads NOT provably working** - the stale is surfaced, correctly, but `.stale-*` remembers a hash the next tick invalidates, so the identical idle pane surfaces again on every tick.
  This is the repeated-wakes observation.
- **Crew reads provably working** - the stale is absorbed, correctly, and `.stale-since-*` is reset by the next tick, so the wedge timer never ages past one tick and `FM_STALE_ESCALATE_SECS` is unreachable.
  Nothing ever escalates.
  This is the silent 1.5 hours.

The heartbeat could not compensate.
Its backoff exists so an idle fleet stops burning turns, but it cannot tell an idle fleet from one job running silently: a crew in a single very long turn writes no status and fires no turn-end hook, so the cadence widened to its 2h cap while a task was in flight.
The observed intervals in the triage log above exceed even that cap, which is consistent with poll cycles slowed by the re-classification each footer tick forced.

One branch remains that fits the missing `.stale-*` file specifically and that the evidence cannot settle post-mortem, because the pane is gone: a busy signature is pane-rendered, so a session that dies mid-turn can leave it standing on screen.
While it stands, `window_is_busy` suppresses the entire triage block, so no `.stale-*` is ever written and the crew is never classified at all.
That branch is bounded rather than diagnosed - see `FM_BUSY_CLAIM_MAX` below.

## Fix

In `bin/fm-watch.sh`:

- The stale hash covers the pane **body** only - the transcript above the harness footer - via `hash_pane_body`.
  The footer is still read, by `window_is_busy`, for the busy signature; that is what it is for.
  Both sides share `PANE_FOOTER_LINES` so they cannot drift apart.
  A footer tick is no longer mistaken for progress, so the suppressor holds and the wedge timer matures.
- `FM_BUSY_CLAIM_MAX` (default 1800s) bounds how long a rendered busy signature may suppress supervision: a pane still claiming busy whose body has produced no output for that long surfaces once per episode, and the episode re-arms the moment the body moves again.
- `FM_HEARTBEAT_MAX_INFLIGHT` (default 900s) caps the heartbeat backoff whenever any task is in flight.
  The 2h cap remains for a genuinely idle fleet.

## Stated bounds

The point of the fix is that the worst-case notice delay is a known number rather than an emergent property of the backoff:

| Situation | Worst case before firstmate is woken |
| --- | --- |
| Crew stops and its pane stops claiming busy, crew not provably working | 2 polls (~30s at the default `FM_POLL`) |
| Crew stops, absorbed as provably working | `FM_STALE_ESCALATE_SECS` (240s) after that |
| Crew dies leaving a busy signature rendered | `FM_BUSY_CLAIM_MAX` (1800s) |
| Fail-safe fleet-scan while any task is in flight | `FM_HEARTBEAT_MAX_INFLIGHT` (900s) |

## Regression coverage

`tests/fm-watch-triage.test.sh` drives a real watcher against a pane with a constant body and a footer ticking every 3s - the live cadence (60s tick, 15s poll) compressed:

Each test below was run against the pre-fix `bin/fm-watch.sh` (`ce0589e`) and against the fixed one, so the ledger states which ones actually reproduce the defect and which only guard it:

| Test | Pre-fix | Fixed | Role |
| --- | --- | --- | --- |
| `test_footer_tick_does_not_reset_wedge_timer` | fails | passes | reproduces the silent half |
| `test_footer_tick_surfaces_idle_pane_only_once` | fails | passes | reproduces the chatty half |
| `test_busy_claim_is_bounded` | fails | passes | reproduces the rendered-busy branch |
| `test_long_working_stretch_then_death_is_surfaced_promptly` | passes | passes | guard only |
| `test_working_crew_never_hits_the_busy_claim_bound` | n/a | passes | non-chatty guard |
| `test_wedge_escalation_resets_when_pane_becomes_active` | n/a | passes | non-chatty guard |
| `test_heartbeat_backoff_capped_while_work_in_flight` | n/a | passes | in-flight cadence cap |

Exact output for the first one:

```
########## PRE-FIX (expect FAIL) ##########
not ok - the wedge timer never matured on a pane whose footer keeps ticking (the 2026-07-31 silent half)
PREFIX_EXIT=1
########## FIXED (expect PASS) ##########
ok - the wedge timer matures on a pane whose footer ticks, instead of being reset by every tick
FIXED_EXIT=0
```

The fourth row is worth stating plainly, because it contradicts the obvious guess about this incident.
A pane that moves for a long stretch and then goes genuinely static, with no busy signature, was **already** detected within two polls before any of this work - that path was never broken.
The same day's independent observations confirm it from both directions: a live session reported repeated `stale:` wakes for an idle pane, and a second crewmate whose turn died on the same API error was surfaced within minutes.
The failure was never "a static pane is not noticed".
It was that a pane which is doing nothing does not go static in the first place, because its footer keeps moving - so the bookkeeping built on that hash either re-fired forever or never matured.
A fix aimed at the guessed shape would have passed its own test and changed nothing.
