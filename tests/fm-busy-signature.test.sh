#!/usr/bin/env bash
# Busy-signature detection (fm_pane_is_busy / FM_TMUX_BUSY_REGEX_DEFAULT).
#
# Regression cover for the claude busy signature going undetected: current
# claude builds render no "esc to interrupt" footer, so a genuinely working
# crewmate read as NOT busy and the watcher's wake triage lost its only
# positive evidence of work for firstmate's default harness.
#
# Every fixture below is REAL pane text captured from a live tmux crewmate on
# 2026-08-03 (Opus 5), not hand-written, so the assertions pin the actual
# rendering rather than an assumption about it.
#
# These tests must prove BOTH directions. A regex that only satisfies
# "busy pane -> BUSY" is also satisfied by a regex that always returns true,
# and that failure is far worse than the one being fixed: AGENTS.md section 8
# states the triage must never absorb a crewmate that has stopped, so an
# idle-matching signature would silently swallow a finished, blocked, or
# dialog-parked crewmate forever. The idle and dialog fixtures are the control.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-busy-signature)

# A fake tmux whose capture-pane serves the fixture named by FM_FAKE_PANE, so
# fm_pane_is_busy itself is exercised (not a reimplementation of its pipeline).
make_fake_tmux() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  capture-pane) cat "${FM_FAKE_PANE:-/dev/null}" 2>/dev/null; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

FAKEBIN=$(make_fake_tmux "$TMP_ROOT")

# is_busy <fixture-file> -> "BUSY" | "NOT BUSY"
is_busy() {
  if PATH="$FAKEBIN:$PATH" FM_FAKE_PANE="$1" fm_pane_is_busy "fake:win"; then
    printf 'BUSY'
  else
    printf 'NOT BUSY'
  fi
}

fixture() {  # <name> -> echoes path, content on stdin
  local p="$TMP_ROOT/$1.txt"
  cat > "$p"
  printf '%s\n' "$p"
}

# --- BUSY fixtures: a turn in flight ----------------------------------------
#
# The spinner verb is RANDOMISED and the leading glyph rotates, so each fixture
# below uses a different pair. Neither may be what the match keys on; the
# streaming token counter is the only stable discriminator.

test_streaming_spinner_is_busy() {
  local f
  f=$(fixture busy-wandering <<'EOF'
     tests/run-tests.sh 2>&1 | tail -60 (4m 54s · 3 lines)
     (ctrl+b ctrl+b (twice) to run in background)
✶ Wandering… (12m 26s · ↓ 24.1k tokens)
────────────────────────────────────────
❯
────────────────────────────────────────
  Opus 5 · effort:high · scoursh  ⎇ fm/scoursh-stranded-trio-r8 · █░░░░░░░░░ 10% (99k/1M) · 12m25s · +0/-0 · $2.42
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 6 agents
EOF
)
  [ "$(is_busy "$f")" = BUSY ] || fail "streaming claude pane read as not busy (the reported bug)"
  pass "claude mid-tool-call (streaming spinner) reads BUSY"
}

test_spinner_verb_and_glyph_are_not_matched() {
  local f
  # Same shape, different randomised verb, different glyph, and a thinking
  # suffix. A match keyed on the verb or glyph would fail here.
  f=$(fixture busy-whatchamacalliting <<'EOF'
      10 // applied to it, so a plain `git push` refused (non-fast-forward)
     … +246 lines
✽ Whatchamacalliting… (18m 36s · ↓ 84.7k tokens · thinking with high effort)
────────────────────────────────────────
❯
────────────────────────────────────────
  Opus 5 · effort:high · web  ⎇ fm/landing-state-rescue-w4 · ███░░░░░░░ 34% (343k/1M) · 14m05s · +2114/-72 · $12.05
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 5 agents
EOF
)
  [ "$(is_busy "$f")" = BUSY ] || fail "verb/glyph variant read as not busy"

  # The glyph is a bare "·" for part of the rotation - still busy.
  f=$(fixture busy-dot-glyph <<'EOF'
     done
· Hyperspacing… (17m 53s · ↓ 29.8k tokens · thought for 2s)
────────────────────────────────────────
❯
────────────────────────────────────────
  Opus 5 · effort:high · scoursh  ⎇ fm/x · █░░░░░░░░░ 19% (190k/1M) · 44m07s · +169/-177 · $10.11
  ⏵⏵ bypass permissions on · PR #46 · 3 shells · ← 6 agents
EOF
)
  [ "$(is_busy "$f")" = BUSY ] || fail "bare-dot spinner glyph read as not busy"
  pass "busy match survives randomised verb and rotating glyph"
}

test_spinner_displaced_by_notice_banner_is_busy() {
  local f
  # claude renders PERSISTENT notice rows directly under the spinner, which push
  # it out of the 6-row steady-state footer. Measured 2026-08-03, three of four
  # live crewmates carried such a banner at once, so this is the common layout,
  # not an edge case, and a 6-row scan read every one of them as not busy.
  f=$(fixture busy-banner-one <<'EOF'
     (ctrl+b ctrl+b (twice) to run in background)
✻ Incubating… (21m 12s · ↓ 14.2k tokens)
  ⎿  Tip: Continue your session in Claude Code Desktop with /desktop
────────────────────────────────────────
❯
────────────────────────────────────────
  Opus 5 · effort:high · scoursh  ⎇ fm/scoursh-docs-java-landing-m2 · █░░░░░░░░░ 18% (177k/1M) · 41m
  ⏵⏵ bypass permissions on · PR #48 · 1 shell · ← 5 agents
EOF
)
  [ "$(is_busy "$f")" = BUSY ] || fail "spinner displaced by one notice banner read as not busy"

  # Two stacked notice rows still leave the spinner inside the window.
  f=$(fixture busy-banner-two <<'EOF'
⏺ Background command completed (exit code 0)
✢ Generating… (13m 26s · ↓ 36.6k tokens)
  ⎿  Tip: Name your conversations with /rename to find them easily in /resume later
                    Plugins updated: 3 plugins · Run /reload-plugins to apply
────────────────────────────────────────
❯
────────────────────────────────────────
  Opus 5 · effort:high · scoursh  ⎇ fm/scoursh-go-sca-landing-l1 · ██░░░░░░░░ 28% (275k/1M) · 1h11m
  ⏵⏵ bypass permissions on · PR #46 · 31 shells · ← 5 agents
EOF
)
  [ "$(is_busy "$f")" = BUSY ] || fail "spinner displaced by two notice rows read as not busy"
  pass "spinner displaced by persistent notice banners still reads BUSY"
}

test_finished_pane_with_notice_banner_is_not_busy() {
  local f
  # The control for the widened window: a banner must not let transcript rows
  # drag an idle pane into a busy verdict.
  f=$(fixture idle-banner <<'EOF'
  module it couldn't be tested at all. Lift, not restructure, but it's your call.
✻ Cooked for 38m 40s
  ⎿  Tip: Run /install-slack-app to use Claude in Slack
────────────────────────────────────────
❯
────────────────────────────────────────
  Opus 5 · effort:high · crewban  ⎇ fm/landing-state-rescue-w4 · ████░░░░░░ 48% (478k/1M) · 41m29s
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 5 agents
EOF
)
  [ "$(is_busy "$f")" = "NOT BUSY" ] || fail "finished pane with a notice banner read as busy"
  pass "finished pane with a notice banner reads NOT BUSY"
}

test_bare_token_counter_in_the_body_is_not_busy() {
  local f
  # The control for the widened window in the other direction: rows 7-8 of the
  # scan are pane BODY, so a stopped crewmate whose transcript merely MENTIONS a
  # token count must not read busy. This shape occurs in this repo's own prose
  # and fixtures, so a crewmate doing firstmate self-work really does end turns
  # with it on screen. The match is anchored to the parenthesised spinner frame
  # precisely so that bare mention does not reproduce it.
  f=$(fixture idle-body-mentions-counter <<'EOF'
  - The **streaming token counter** (`↓ 24.1k tokens`) was present in all 43.
    This is the discriminator; the docs quote ↓ 84.7k tokens as a second sample.
✻ Worked for 12m 03s
────────────────────────────────────────
❯
────────────────────────────────────────
  Opus 5 · effort:high · firstmate  ⎇ fm/busy-signature-claude-v9 · ██░░░░░░░░ 22% (220k/1M) · 27m
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 5 agents
EOF
)
  [ "$(is_busy "$f")" = "NOT BUSY" ] \
    || fail "a stopped crewmate whose body mentions a token counter read as busy - the watcher would absorb it"

  # Same text with no footer at all, so every line is body.
  f=$(fixture idle-body-counter-only <<'EOF'
the discriminator is ↓ 24.1k tokens
grep for (↓|↑)[[:space:]]*[0-9][0-9.,]*[km]?[[:space:]]+tokens
EOF
)
  [ "$(is_busy "$f")" = "NOT BUSY" ] || fail "a bare token counter in pane body read as busy"
  pass "a token counter outside the spinner's parenthesised frame reads NOT BUSY"
}

test_run_in_background_hint_alone_is_not_busy() {
  local f
  # claude's run-in-background hint is NOT part of the signature. It is a bare
  # literal that appears verbatim in this file and in
  # docs/harness-busy-signatures.md, so a crewmate doing firstmate self-work
  # that ends its turn displaying either one would read busy while stopped, and
  # the watcher would absorb it. The busy fixtures above carry this same hint
  # line and still read BUSY via the anchored counter on the spinner line below
  # it, which is the proof that dropping it costs no detection.
  f=$(fixture idle-body-run-in-background <<'EOF'
⏺ Read(tests/fm-busy-signature.test.sh)
  ⎿       (ctrl+b ctrl+b (twice) to run in background)
✻ Worked for 4m 11s
────────────────────────────────────────
❯
────────────────────────────────────────
  Opus 5 · effort:high · firstmate  ⎇ fm/busy-signature-claude-v9 · ██░░░░░░░░ 21% (210k/1M) · 18m
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 5 agents
EOF
)
  [ "$(is_busy "$f")" = "NOT BUSY" ] \
    || fail "a stopped crewmate displaying the run-in-background hint read as busy - the watcher would absorb it"

  # The hint on its own, as it appears when the fixture file is simply on screen.
  f=$(fixture idle-run-in-background-only <<'EOF'
     (ctrl+b ctrl+b (twice) to run in background)
EOF
)
  [ "$(is_busy "$f")" = "NOT BUSY" ] || fail "the run-in-background hint matched the busy signature on its own"
  pass "claude's run-in-background hint never reads BUSY on its own"
}

test_busy_window_is_wider_than_the_body_hash_split() {
  # The busy window and fm-watch.sh's PANE_FOOTER_LINES answer different
  # questions and must stay separate constants; sharing one is what made the
  # busy read un-widenable without blunting stale detection.
  [ "$FM_TMUX_BUSY_TAIL_DEFAULT" -gt 6 ] \
    || fail "busy scan window is not wider than the 6-row steady-state footer"
  # shellcheck disable=SC2016  # single quotes are deliberate: this asserts the literal source text, not its expansion
  assert_grep 'PANE_FOOTER_LINES=${FM_PANE_FOOTER_LINES:-6}' \
    "$ROOT/bin/fm-watch.sh" "fm-watch.sh's body/footer hash split is no longer 6"
  pass "busy scan window is decoupled from, and wider than, the body-hash split"
}

test_busy_tail_override_is_guarded() {
  local f
  f=$(fixture busy-override-guard <<'EOF'
✻ Incubating… (21m 12s · ↓ 14.2k tokens)
  ⎿  Tip: Continue your session in Claude Code Desktop with /desktop
────────────────────────────────────────
❯
────────────────────────────────────────
  Opus 5 · effort:high · scoursh  ⎇ fm/x · █░░░░░░░░░ 18% (177k/1M) · 41m
  ⏵⏵ bypass permissions on · ← 5 agents
EOF
)
  # A zero or junk override must fall back, not silently scan nothing and
  # report every pane in the fleet as idle.
  [ "$(FM_BUSY_TAIL_LINES=0 is_busy "$f")" = BUSY ] || fail "FM_BUSY_TAIL_LINES=0 silently disabled the busy scan"
  [ "$(FM_BUSY_TAIL_LINES=junk is_busy "$f")" = BUSY ] || fail "non-numeric FM_BUSY_TAIL_LINES silently disabled the busy scan"
  pass "FM_BUSY_TAIL_LINES falls back on zero or non-numeric input"
}

test_legacy_and_other_harness_signatures_still_match() {
  local f
  # Additive fix: older claude builds and the other verified adapters still
  # emit these, so removing any of them would silently unfix their harness.
  f=$(fixture busy-esc-interrupt <<'EOF'
some transcript line
esc to interrupt
EOF
)
  [ "$(is_busy "$f")" = BUSY ] || fail "legacy 'esc to interrupt' no longer matches"

  f=$(fixture busy-pi <<'EOF'
some transcript line
Working...
EOF
)
  [ "$(is_busy "$f")" = BUSY ] || fail "pi 'Working...' no longer matches"

  f=$(fixture busy-grok <<'EOF'
some transcript line
Ctrl+c:cancel
EOF
)
  [ "$(is_busy "$f")" = BUSY ] || fail "grok 'Ctrl+c:cancel' no longer matches"
  pass "pre-existing harness signatures still match (additive, not a replacement)"
}

# --- NOT BUSY fixtures: the control -----------------------------------------

test_finished_pane_is_not_busy() {
  local f
  # The finished pane carries its OWN elapsed timer ("Worked for 26m 21s"), and
  # the always-present status line carries another ("31m31s"). This is why the
  # match keys on the token counter and never on a timer.
  f=$(fixture idle-worked-for <<'EOF'
  including that a starved runner cannot complete process.exit(0) and so could
  not shut down gracefully either.
✻ Worked for 26m 21s
────────────────────────────────────────
❯
────────────────────────────────────────
  Opus 5 · effort:high · crewban  ⎇ fm/runner-fifo-threadpool-t7 · ███░░░░░░░ 32% (322k/1M) · 31m31s · +645/-78 · $17.83
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 5 agents
EOF
)
  [ "$(is_busy "$f")" = "NOT BUSY" ] || fail "FINISHED pane read as busy - the watcher would absorb a stopped crewmate forever"

  # A second finished-pane wording, with a different mode line.
  f=$(fixture idle-brewed-for <<'EOF'
  Ran 1 shell command
⏺ 2026
✻ Brewed for 3s
────────────────────────────────────────
❯ now the month
────────────────────────────────────────
  Opus 5 (1M context) · effort:high · trustdir  ⎇ master · ░░░░░░░░░░ 3% (35k/1M) · 55s · +0/-0 · $0.19
  ⏸ manual mode on · ← 5 agents
EOF
)
  [ "$(is_busy "$f")" = "NOT BUSY" ] || fail "finished pane ('Brewed for 3s') read as busy"
  pass "claude idle at the prompt (turn finished) reads NOT BUSY"
}

test_permission_dialog_is_not_busy() {
  local f
  # A crewmate parked on a mid-turn tool-permission dialog is waiting on a
  # human. fm-crew-state.sh's crew_pane_is_busy documents that this case stays
  # not-busy; if it ever read busy, the watcher would absorb it forever and the
  # crewmate would sit on the dialog unnoticed. Note "Esc to cancel" here: that
  # is why no bare "esc"/"cancel" alternative may be added to the signature.
  f=$(fixture dialog-permission <<'EOF'
   curl -sS https://example.com | grep -i '<title>'
   Fetch example.com and extract title
 This command requires approval
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for: curl -sS https://example.com
   3. No
 Esc to cancel · Tab to amend · ctrl+e to explain
EOF
)
  [ "$(is_busy "$f")" = "NOT BUSY" ] || fail "mid-turn permission dialog read as busy - a crewmate stuck on a dialog would be absorbed forever"
  pass "claude on a permission dialog reads NOT BUSY"
}

test_trust_dialog_is_not_busy() {
  local f
  f=$(fixture dialog-trust <<'EOF'
 Quick safety check: Is this a project you created or one you trust?
 Claude Code'll be able to read, edit, and execute files here.
 Security guide
 ❯ 1. Yes, I trust this folder
   2. No, exit
 Enter to confirm · Esc to cancel
EOF
)
  [ "$(is_busy "$f")" = "NOT BUSY" ] || fail "trust dialog read as busy - a crewmate stuck on the trust prompt would be absorbed forever"
  pass "claude on a trust dialog reads NOT BUSY"
}

test_idle_footer_furniture_never_matches_alone() {
  local f line
  # Every row the IDLE footer renders, one at a time. Matching any of these
  # would turn the predicate into a constant true, because they are present
  # whether or not a turn is running.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    f=$(printf '%s\n' "$line" | fixture idle-furniture)
    [ "$(is_busy "$f")" = "NOT BUSY" ] \
      || fail "idle footer furniture matched the busy signature: '$line'"
  done <<'EOF'
❯
⏵⏵ bypass permissions on (shift+tab to cycle) · ← 5 agents
⏸ manual mode on · ← 5 agents
  Opus 5 · effort:high · scoursh  ⎇ fm/x · █░░░░░░░░░ 10% (99k/1M) · 12m25s · +0/-0 · $2.42
────────────────────────────────────────
✻ Worked for 26m 21s
✻ Cooked for 35s · 3 shells still running
 Enter to confirm · Esc to cancel
EOF
  pass "no idle footer row matches the busy signature on its own"
}

test_empty_capture_is_not_busy() {
  local f
  f=$(fixture empty </dev/null)
  [ "$(is_busy "$f")" = "NOT BUSY" ] || fail "empty capture read as busy"
  pass "empty capture reads NOT BUSY"
}

# --- the shared default is the ONE definition -------------------------------

test_watcher_reuses_the_shared_default() {
  # fm-watch.sh used to carry its own copy of the regex literal, so fixing one
  # was not fixing the other. It must read the shared default instead.
  # shellcheck disable=SC2016  # single quotes are deliberate: this asserts the literal source text, not its expansion
  assert_grep 'BUSY_REGEX=${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}' \
    "$ROOT/bin/fm-watch.sh" "fm-watch.sh does not reuse FM_TMUX_BUSY_REGEX_DEFAULT"
  assert_no_grep 'esc (to )?interrupt' \
    "$ROOT/bin/fm-watch.sh" "fm-watch.sh still carries its own copy of the busy regex literal"
  pass "fm-watch.sh reuses the single shared busy-signature definition"
}

test_env_override_still_wins() {
  local f
  f=$(fixture override <<'EOF'
some transcript line
CUSTOM-HARNESS-BUSY
EOF
)
  [ "$(FM_BUSY_REGEX='CUSTOM-HARNESS-BUSY' is_busy "$f")" = BUSY ] \
    || fail "FM_BUSY_REGEX override no longer takes effect"
  pass "FM_BUSY_REGEX override still wins over the default"
}

test_streaming_spinner_is_busy
test_spinner_verb_and_glyph_are_not_matched
test_spinner_displaced_by_notice_banner_is_busy
test_finished_pane_with_notice_banner_is_not_busy
test_bare_token_counter_in_the_body_is_not_busy
test_run_in_background_hint_alone_is_not_busy
test_busy_window_is_wider_than_the_body_hash_split
test_busy_tail_override_is_guarded
test_legacy_and_other_harness_signatures_still_match
test_finished_pane_is_not_busy
test_permission_dialog_is_not_busy
test_trust_dialog_is_not_busy
test_idle_footer_furniture_never_matches_alone
test_empty_capture_is_not_busy
test_watcher_reuses_the_shared_default
test_env_override_still_wins
