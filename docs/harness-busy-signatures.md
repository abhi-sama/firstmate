# Harness busy signatures: how they are measured and re-measured

A harness busy signature is a **verified empirical fact about a terminal UI**, not a stable contract.
It drifts whenever the harness changes how it renders a turn in flight, and nothing fails loudly when it does.
This document records where each one was measured, and the procedure for re-measuring it when a harness update moves it again.

The signature set itself is defined exactly once, as `FM_TMUX_BUSY_REGEX_DEFAULT` in `bin/fm-tmux-lib.sh`.
`bin/fm-watch.sh`, `bin/fm-crew-state.sh`, and `bin/fm-supervise-daemon.sh` all read it from there.
Per-harness supervision knowledge lives in the `harness-adapters` skill; the fixtures live in `tests/fm-busy-signature.test.sh`.

## Why a drifted signature is expensive

`AGENTS.md` section 8: the watcher absorbs a benign wake only while a crewmate is **provably working**, and `crew_is_provably_working` falls back to this pane predicate whenever there is no no-mistakes run to read (every `direct-PR` task and every scout task).

A signature that **misses a busy pane** costs spurious wakes, and, more seriously, flips the crewmate to not-provably-working, where the watcher trusts the status log's last line to decide terminal-vs-non-terminal.
A busy crewmate whose last line still reads `done:` from before a validation started can then be read as finished while it is still working.

A signature that **matches an idle pane** is far worse.
The watcher would absorb a genuinely stopped crewmate forever, which `AGENTS.md` names as the one thing the triage must never do.

**That asymmetry governs every edit.**
Never add anything the idle footer renders.
Never add a bare `esc` or `cancel`: both the trust dialog and the mid-turn permission dialog render `Esc to cancel` while genuinely waiting on a human.
Additions are additive - other harnesses and older builds still emit the existing alternatives, so an alternative is removed only when it is proven to match an idle pane.

## Re-measurement procedure

Do this when a harness update is suspected of moving its signature, or when spurious `stale` wakes appear for crewmates that are demonstrably working.

1. Find a crewmate that is **provably** mid-turn (streaming tokens or inside a tool call), and one that has **finished** its turn and is idle at the prompt.
2. Capture what the predicate actually reads, which is the last `FM_TMUX_BUSY_TAIL_DEFAULT` non-blank lines of a 40-line tail.
   Read the window from the constant rather than hard-coding it, so the procedure cannot drift from the code again:

   ```sh
   . bin/fm-tmux-lib.sh
   tmux capture-pane -p -t <window> -S -40 | grep -v '^[[:space:]]*$' | tail -"$FM_TMUX_BUSY_TAIL_DEFAULT"
   ```

3. Sample the busy pane repeatedly, because animated elements vary between frames:

   ```sh
   . bin/fm-tmux-lib.sh
   for i in $(seq 1 14); do
     tmux capture-pane -p -t <window> -S -40 | grep -v '^[[:space:]]*$' | tail -"$FM_TMUX_BUSY_TAIL_DEFAULT" | head -1
     sleep 4
   done | sort -u
   ```

4. Diff the two states and pick an anchor present **only** while a turn is in flight.
   Reject any candidate that also appears in the idle capture, and reject anything animated whose text varies between frames.
   Prefer an anchor with **structure** around it - a bracketing frame the harness draws, not a bare word or number - because the scan window is wider than the footer and therefore also reads body rows.
5. Capture the two dialog states too, since both must stay NOT BUSY: the trust prompt (launch the harness in a fresh untrusted directory) and a mid-turn tool-permission prompt (ask for a command the harness must confirm).
6. Add the captured text as fixtures to `tests/fm-busy-signature.test.sh`, in **both** directions, then update `FM_TMUX_BUSY_REGEX_DEFAULT` and the `harness-adapters` entry.
7. Confirm the fixtures actually discriminate, rather than passing vacuously:

   ```sh
   # The OLD signature must now fail the busy assertions.
   FM_BUSY_REGEX='<old regex>' bash tests/fm-busy-signature.test.sh
   # An always-true signature must fail the idle assertions.
   FM_BUSY_REGEX='.*' bash tests/fm-busy-signature.test.sh
   ```

## claude (measured 2026-08-03, Opus 5, tmux backend)

**Finding: current claude builds render no `esc to interrupt` footer at all**, so the signature that predated this measurement matched nothing and every working claude crewmate read as NOT BUSY.

A turn in flight renders a spinner line directly above the composer box:

```
✶ Wandering… (12m 26s · ↓ 24.1k tokens)
✽ Whatchamacalliting… (18m 36s · ↓ 84.7k tokens · thinking with high effort)
· Hyperspacing… (17m 53s · ↓ 29.8k tokens · thought for 2s)
```

Across 43 sampled busy footers in one session:

- The **verb is randomised** - `Wandering`, `Hyperspacing`, `Whatchamacalliting`, `Incubating`, `Gitifying` were all observed.
  Never match the verb.
- The **glyph rotates** through `· ✢ ✳ ✶ ✻ ✽`, including a bare `·`.
  Never match the glyph.
- The **streaming token counter** (`↓ 24.1k tokens`) was present in all 43.
  This is the discriminator.

The counter is matched **only inside the parenthesised elapsed-time frame** that wraps it, never bare anywhere on the line.
The match requires an open paren, a digit-led elapsed token, then the arrow, a number, and `tokens`, all before the frame closes:

```
\([0-9][^)]*(↓|↑)[[:space:]]*[0-9][0-9.,]*[km]?[[:space:]]+tokens
```

That frame is **structural**, drawn by the harness, and prose that merely mentions a token count does not reproduce it.
The line "the streaming token counter (`↓ 24.1k tokens`) was present in all 43", a few lines above in this very document, does not match, and neither does a transcript row quoting `↓ 24.1k tokens` on its own.
**This is what makes a scan window wider than the footer safe**, because rows past the steady-state footer are pane body rather than chrome.

Be honest about the limit: this narrows the false-positive surface rather than eliminating it.
Verbatim pane text pasted into a transcript can still carry a complete frame, and a stopped crewmate whose body ends in one would read busy.
The bounded backstops remain the safety net for that residue: a provably-working pane still escalates at `FM_STALE_ESCALATE_SECS` (240s), and a standing busy signature over a silent body surfaces at `FM_BUSY_CLAIM_MAX` (1800s).

The finished pane renders its own elapsed timer, with no parentheses and no token counter:

```
✻ Worked for 26m 21s
✻ Cooked for 35s · 3 shells still running
✻ Brewed for 3s
```

**This is why the match keys on the token counter and never on an elapsed timer.**
A finished pane has a timer, and the always-present status line carries another (`· 12m25s ·`), so any timer-shaped match would match an idle pane - the catastrophic direction.

Both human-blocked states were captured and neither carries a token counter, so both correctly read NOT BUSY:

```
 Esc to cancel · Tab to amend · ctrl+e to explain      (mid-turn permission dialog)
 Enter to confirm · Esc to cancel                      (trust dialog)
```

`(ctrl+b ctrl+b` is claude's run-in-background hint, rendered only under an in-flight tool call, and is matched as a secondary anchor.

### Footer height, notice banners, and the scan window

claude's steady-state footer is 6 rows - spinner, rule, composer, rule, status, mode - which puts the spinner on row 6.
That is why the scan window was historically 6.

But claude also renders **persistent** notice rows directly under the spinner: a `/desktop` or `/rename` tip, a plugin-update banner, a login-expiry warning.
Each one pushes the spinner further out of a 6-row window, and the busy read then misses it entirely.

This is the common layout, not an edge case.
Measured 2026-08-03, **three of four** live crewmates carried such a banner simultaneously, and each was genuinely streaming tokens:

```
     (ctrl+b ctrl+b (twice) to run in background)
✻ Incubating… (21m 12s · ↓ 14.2k tokens)          <- spinner, row 7 from the bottom
  ⎿  Tip: Continue your session in Claude Code Desktop with /desktop
────────────────────────────────────────
❯
────────────────────────────────────────
  Opus 5 · effort:high · scoursh  ⎇ fm/… · 18% (177k/1M) · 41m
  ⏵⏵ bypass permissions on · PR #48 · 1 shell · ← 5 agents
```

The window is therefore `FM_TMUX_BUSY_TAIL_DEFAULT` (8), which covers a spinner displaced by up to two notice rows.
Rows 7 and 8 of that window are pane **body**, not footer, so the width is only safe in company with the parenthesised-frame anchor above.
The two are complementary: the width buys margin against composers and notice banners that push the spinner up, and the anchor removes the false-positive surface that margin would otherwise open.

**It is deliberately not `PANE_FOOTER_LINES`**, which stays 6 in `bin/fm-watch.sh`.
Those two constants answer different questions.
The busy window asks how far up the spinner might have been pushed; `PANE_FOOTER_LINES` asks which trailing rows tick on their own and so must be excluded from the stale **body** hash.
They were a single constant until 2026-08-03, and that sharing is exactly what made the busy read un-widenable: raising it would also have dropped real transcript rows out of the body hash and blunted stale detection.

Note that the body hash partly masks this failure on the stale path, which is why it went unnoticed.
A spinner pushed outside the 6-row footer sits inside the hashed body, so its ticking counter keeps the hash changing and the pane never goes stale.
Measured 2026-08-03 sampling both layouts every 7s: a banner-shifted pane rehashed on every poll, while an unshifted one held a stable hash.
That masking does **not** extend to `crew_is_provably_working`'s no-verb signal path, which consults this predicate directly, so a missed busy read there surfaces the spurious wakes the triage exists to absorb.

## Other harnesses

These are unchanged by the 2026-08-03 claude measurement and remain as verified in the `harness-adapters` skill.

| Harness | Signature | Verified |
|---|---|---|
| codex | `esc to interrupt`, shown as `• Working (Xs • esc to interrupt)` | 2026-06-11, codex-cli 0.139.0 |
| opencode | `esc interrupt` (no "to") | 2026-06-11, v1.15.7-1.17.3 |
| pi | `Working...` | 2026-06-11 |
| grok | `Ctrl+c:cancel`, the mid-turn cancel hint shown iff a turn is running | 2026-06-29, grok 0.2.73 |

`esc (to )?interrupt` also covers older claude builds, which is why it is retained rather than replaced.

Per-harness overrides remain available without a code change: `FM_BUSY_REGEX` replaces the whole set, and `FM_COMPOSER_IDLE_RE` handles empty-composer detection (`docs/configuration.md`).
