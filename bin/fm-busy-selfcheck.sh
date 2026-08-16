#!/usr/bin/env bash
# fm-busy-selfcheck.sh - startup regression guard for the rendered busy-footer
# signatures in bin/fm-tmux-lib.sh.
#
# Why: the Claude busy footer drifted silently once (task fm-busy-signature-drift):
# the shipped signature stopped matching what Claude Code actually renders, every
# working Claude pane read as idle, and nothing asserted the signature until an
# operator measured it by hand. This check makes the next drift loud at session
# start instead of degrading delivery guards for an entire session.
#
# What it checks: each recorded live-capture fixture below is fed through the
# real consumer pipeline (fm_busy_tail_window_match, the same window the submit
# acknowledgement, away-mode busy guard, and secondmate pending-reply
# observation use). Recorded busy footers must classify busy; recorded idle
# shapes must NOT (false-BUSY is the dangerous direction: it converts a
# swallowed Enter into a claimed delivery). FM_BUSY_REGEX is honored, so a
# session-scoped operator override is validated against the same fixtures.
#
# Fixture-based, not live-pane-based, by design: it catches a broken signature
# or override deterministically at every startup with no spawn cost. Drift in a
# NEW harness version is caught the first time an operator re-records fixtures
# or a delivery guard misbehaves; the fixtures then pin the corrected signature
# forever. Fixture provenance: live captures 2026-08-03 (Claude Code 2.1.220)
# reverified live 2026-08-16 (Claude Code 2.1.233); see
# docs/verification/runtime-backends.md.
#
# Usage: fm-busy-selfcheck.sh
#   Silent with exit 0 when every fixture classifies correctly.
#   Prints one "BUSY_SIGNATURE: <harness> ..." line per failed fixture and
#   exits 1. bin/fm-bootstrap.sh runs this in its always-on detect section.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"

FAILED=0

busy_fixture() {  # <harness> <label> <fixture>
  local harness=$1 label=$2 fixture=$3
  printf '%s\n' "$fixture" | fm_busy_tail_window_match "$harness" && return 0
  printf 'BUSY_SIGNATURE: %s recorded busy footer no longer matches (%s) - working %s panes will read idle and delivery guards degrade; inspect FM_BUSY_REGEX and the %s signature in bin/fm-tmux-lib.sh\n' \
    "$harness" "$label" "$harness" "$harness"
  FAILED=1
}

idle_fixture() {  # <harness> <label> <fixture>
  local harness=$1 label=$2 fixture=$3
  printf '%s\n' "$fixture" | fm_busy_tail_window_match "$harness" || return 0
  printf 'BUSY_SIGNATURE: %s recorded idle shape matches as busy (%s) - a false-BUSY can convert a swallowed Enter into a claimed delivery; inspect FM_BUSY_REGEX and the %s signature in bin/fm-tmux-lib.sh\n' \
    "$harness" "$label" "$harness"
  FAILED=1
}

# Claude renders three busy footer shapes; all three must classify busy.
busy_fixture claude 'streaming token counter' '✻ Fermenting… (4m 39s · ↓ 17.0k tokens)'
busy_fixture claude 'long-quiet streaming round' '✻ Whirring… (37m 35s · ↓ 64.6k tokens)'
busy_fixture claude 'tool wait' '✻ Sautéed for 1m 8s · 1 monitor still running'
busy_fixture claude 'extended thinking' '✢ Pondering… (2m 50s · thinking some more with xhigh effort)'
busy_fixture claude 'legacy interrupt footer' 'esc to interrupt'

# The busy footer must survive a queued-messages composer: the composer box,
# queued hint, tip, and status rows render BELOW the footer and push it 7-9
# non-blank rows above the bottom of the pane.
busy_fixture claude 'queued-messages window depth' '✻ Cooked for 16s · 1 shell still running

╭──────────────────────────────────────────╮
│ > next steps after the current build     │
╰──────────────────────────────────────────╯
  Press up to edit queued messages
  ⎿  Tip: Use /clear to start fresh when switching topics
────────────────────────────────
❯
────────────────────────────────
  ⬆ /gsd:update │ Fable 5 │ savour ██░░░░░░░░ 29%
  ⏵⏵ bypass permissions on · 1 shell · ← 1 agent'

# Idle shapes recorded from finished panes. The /clear composer hint carries a
# token count and once false-matched a proposed bare token-count signature
# (measured 2026-08-05); it must never classify busy.
idle_fixture claude 'finished-turn timer' '✻ Worked for 31s'
idle_fixture claude '/clear composer hint' '❯ new task? /clear to save 194.6k tokens'
idle_fixture claude 'status bar tool count' '⏵⏵ bypass permissions on · 1 shell · ← 1 agent'

# The other verified harnesses' single-token signatures.
busy_fixture codex 'interrupt footer' 'esc to interrupt'
busy_fixture opencode 'interrupt footer' 'esc interrupt'
busy_fixture pi 'working footer' 'Working...'
busy_fixture grok 'cancel footer' 'Ctrl+c:cancel'
busy_fixture kimi 'moon spinner' ' 🌑 · thinking'

exit "$FAILED"
