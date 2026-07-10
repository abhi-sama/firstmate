# Pipeline monitor (`bin/fm-pipeline-monitor.sh`)

Live, read-only visibility into a crewmate's `no-mistakes` validation run.

## The problem it solves

While a crewmate drives `/no-mistakes`, its own tmux window shows only "1 shell running" plus a spinner - the pipeline's review/test/lint work happens in headless subprocesses.
Seeing which of the nine steps is active, or what a review agent is currently finding, otherwise requires hand-running `no-mistakes axi status` and `no-mistakes axi logs --step <step>` inside the crewmate's worktree.

`bin/fm-pipeline-monitor.sh <task-id>` opens a dedicated tmux window, `fm-monitor-<task-id>`, that does exactly that on a refresh loop: the run's step table (`axi status`) plus a bounded tail of the active step's log (`axi logs --step <step>`), refreshed every few seconds.

## Usage

```sh
bin/fm-pipeline-monitor.sh <task-id>
```

Opens the monitor window in the same tmux session as the crewmate's own window (resolved from `state/<task-id>.meta`), or reuses it if already open.
Run it any time after a crewmate has started (or is about to start) validation; if no run exists yet it just displays "no active no-mistakes run yet" and keeps polling.

Two internal subcommands exist for the window's own use and for tests, not for interactive use:

- `--loop <task-id>` runs the tail loop in the foreground - this is the command the monitor window itself runs.
- `--tick <task-id>` prints exactly one status block and exits (0 = still in flight, 1 = terminal); used by `tests/fm-pipeline-monitor.test.sh` to test the display logic without an infinite loop or a real tmux window.

## Read-only contract

The script calls only `no-mistakes axi status` and `no-mistakes axi logs --step <step>`.
It never calls `axi respond` or `axi abort`, never touches `projects/`, and never mutates the run in any way - it is strictly an observer alongside the crewmate that actually drives its own validation.
It does not replace [`bin/fm-crew-state.sh`](../bin/fm-crew-state.sh): that script is the deterministic current-state read the watcher and firstmate use to decide what to do next; this script is a human-facing terminal view of the same underlying run.

## Lifecycle

The window closes itself once the run reaches an `outcome:` (pass or fail), the task is torn down (its `state/<id>.meta` or worktree disappears), or no `no-mistakes` run ever appears for `FM_PIPELINE_MONITOR_MAX_EMPTY_TICKS` consecutive checks - it prints a final message, pauses a few seconds so it is readable, then exits, which closes the tmux window (and it also explicitly runs `tmux kill-window` on itself as a fallback in case a `remain-on-exit on` tmux config would otherwise leave a dead pane behind).
That last case matters because a monitor is often opened right when validation is triggered, before the crewmate's own `no-mistakes axi run` has actually started - if validation is never triggered at all (the task is abandoned, reassigned, or the crewmate never gets to it), the monitor must not poll forever; it gives up after the configured number of empty checks instead.
The loop also exits promptly on `SIGTERM`/`SIGINT` rather than waiting out a full refresh interval first.
Opening the monitor a second time for the same task reuses the existing window instead of creating a duplicate.

## Backend support

tmux is firstmate's verified reference runtime backend ([`docs/tmux-backend.md`](tmux-backend.md)).
The pipeline monitor is tmux-only for now: for a task recorded on any other backend (`herdr`, `zellij`, `orca`, `cmux`), it prints a pointer to running `no-mistakes axi status` / `axi logs --step <step>` directly in the worktree and exits 0 rather than opening anything - it never blocks or errors the caller.

## Triggering it automatically (opt-in)

By default nothing changes: the monitor is a standalone command you or firstmate run on demand.
Set the local, gitignored `config/pipeline-monitor` file to `on` to have firstmate also open the monitor window right after it triggers validation for a `no-mistakes`-mode ship task (AGENTS.md section 7, "Validate").
This is a pure convenience hook - firstmate triggering validation itself never depends on the monitor window opening successfully, and a missing/failed monitor window never blocks or changes validation.
Absent or any value other than `on` keeps today's behavior (manual only).

## Tuning

- `FM_PIPELINE_MONITOR_INTERVAL` - seconds between refreshes while a run is in flight (default 5).
- `FM_PIPELINE_MONITOR_TAIL` - lines of the active step's log tail to show (default 25).
- `FM_PIPELINE_MONITOR_CLOSE_DELAY` - seconds the final message stays up before the window closes (default 5).
- `FM_PIPELINE_MONITOR_NM_TIMEOUT` - bound, in seconds, on each `no-mistakes` call (default 10; uses `timeout`/`gtimeout` when available, unbounded otherwise since this is a display refresh, not a correctness-critical decision).
- `FM_PIPELINE_MONITOR_MAX_EMPTY_TICKS` - consecutive no-active-run checks tolerated before the loop gives up and closes (default 360, about 30 minutes at the default interval; `0` disables the guard - not recommended for a window a captain might leave open unattended).
