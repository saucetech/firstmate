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
# swallowed Enter into a claimed delivery).
#
# FM_BUSY_REGEX handling: that override is GLOBAL in fm_busy_lines_match - when
# set it replaces the signature for every harness, not just the one the
# operator targeted - and its whole purpose is to be a narrow, one-harness
# stopgap while a drift is being fixed. So the shipped per-harness signatures
# are always validated with the override cleared, and the override is then
# checked on its own terms:
#   - it must be a valid ERE (an invalid one makes grep exit 2, so every pane
#     reads not-busy while grep's stderr leaks into the session digest);
#   - it must match at least ONE recorded busy footer across all harnesses, so
#     a typo'd or stale pattern that matches nothing is caught while a narrow
#     one-harness stopgap that matches that harness's recorded fixtures is not;
#     a stopgap aimed at a NEW drifted shape no fixture records yet trips this
#     too, which is why the printed line names both explanations and asks for
#     the recorded fixture plus corrected signature rather than for a clear;
#   - no recorded idle shape may match it, the dangerous false-BUSY direction,
#     which applies fleet-wide whichever harness the operator targeted.
# Per-harness busy fixtures are deliberately NOT reported against the override:
# a narrow override fails the untargeted harnesses by construction, which would
# print a permanent false diagnostic on every bootstrap. Each printed line names
# its source ("shipped signature" or "FM_BUSY_REGEX override") so the two are
# never confused, and an override finding carries the harness field "all"
# because the override is fleet-wide.
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
#   Prints one "BUSY_SIGNATURE: <harness> <source>: <detail>" line per failed
#   fixture, or one line with harness "all" per fleet-wide override fault, and
#   exits 1. bin/fm-bootstrap.sh runs this in its always-on detect section.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"

# Capture the operator override and clear it, so every fixture below classifies
# under the SHIPPED signatures. The override is re-applied by name at the end,
# on its own terms.
BUSY_REGEX_OVERRIDE=${FM_BUSY_REGEX:-}
unset FM_BUSY_REGEX

FAILED=0
OVERRIDE_BUSY_HITS=0
OVERRIDE_INVALID=0

# shellcheck disable=SC2329 # Invoked indirectly as an each_busy_fixture callback.
busy_fixture() {  # <harness> <label> <fixture>
  local harness=$1 label=$2 fixture=$3
  printf '%s\n' "$fixture" | fm_busy_tail_window_match "$harness" && return 0
  printf 'BUSY_SIGNATURE: %s shipped signature: recorded busy footer no longer matches (%s) - working %s panes will read idle and delivery guards degrade; fix the %s signature in bin/fm-tmux-lib.sh\n' \
    "$harness" "$label" "$harness" "$harness"
  FAILED=1
}

# The override's busy direction is a UNION probe, not a per-harness assertion:
# it only records whether the pattern is a valid ERE and whether any recorded
# busy footer matches it. grep's stderr is swallowed here so an invalid pattern
# reports as one BUSY_SIGNATURE line instead of raw grep noise in the session
# digest.
# shellcheck disable=SC2329 # Invoked indirectly as an each_busy_fixture callback.
override_busy_probe() {  # <harness> <label> <fixture>
  local harness=$1 fixture=$3 rc
  printf '%s\n' "$fixture" | FM_BUSY_REGEX=$BUSY_REGEX_OVERRIDE fm_busy_tail_window_match "$harness" 2>/dev/null
  rc=$?
  case "$rc" in
    0) OVERRIDE_BUSY_HITS=$(( OVERRIDE_BUSY_HITS + 1 )) ;;
    1) ;;
    *) OVERRIDE_INVALID=1 ;;
  esac
}

# shellcheck disable=SC2329 # Invoked indirectly as an each_idle_fixture callback.
idle_fixture() {  # <harness> <label> <fixture>
  local harness=$1 label=$2 fixture=$3
  printf '%s\n' "$fixture" | fm_busy_tail_window_match "$harness" || return 0
  printf 'BUSY_SIGNATURE: %s shipped signature: recorded idle shape matches as busy (%s) - a false-BUSY can convert a swallowed Enter into a claimed delivery; fix the %s signature in bin/fm-tmux-lib.sh\n' \
    "$harness" "$label" "$harness"
  FAILED=1
}

# shellcheck disable=SC2329 # Invoked indirectly as an each_idle_fixture callback.
override_idle_fixture() {  # <harness> <label> <fixture>
  local harness=$1 label=$2 fixture=$3
  printf '%s\n' "$fixture" | FM_BUSY_REGEX=$BUSY_REGEX_OVERRIDE fm_busy_tail_window_match "$harness" 2>/dev/null || return 0
  printf 'BUSY_SIGNATURE: %s FM_BUSY_REGEX override: recorded idle shape matches as busy (%s) - the override is global, so it makes every finished pane read busy and can convert a swallowed Enter into a claimed delivery; narrow or clear FM_BUSY_REGEX\n' \
    "$harness" "$label"
  FAILED=1
}

# Idle shapes recorded from finished panes, checked against the shipped
# signatures and (in the false-BUSY direction only) against an operator
# override. The /clear composer hint carries a token count and once
# false-matched a proposed bare token-count signature (measured 2026-08-05); it
# must never classify busy.
each_idle_fixture() {  # <fixture-callback>
  "$1" claude 'finished-turn timer' '✻ Worked for 31s'
  "$1" claude '/clear composer hint' '❯ new task? /clear to save 194.6k tokens'
  "$1" claude 'status bar tool count' '⏵⏵ bypass permissions on · 1 shell · ← 1 agent'
}

each_busy_fixture() {  # <fixture-callback>
  # Claude renders three busy footer shapes; all three must classify busy.
  "$1" claude 'streaming token counter' '✻ Fermenting… (4m 39s · ↓ 17.0k tokens)'
  "$1" claude 'long-quiet streaming round' '✻ Whirring… (37m 35s · ↓ 64.6k tokens)'
  "$1" claude 'tool wait' '✻ Sautéed for 1m 8s · 1 monitor still running'
  "$1" claude 'extended thinking' '✢ Pondering… (2m 50s · thinking some more with xhigh effort)'
  "$1" claude 'legacy interrupt footer' 'esc to interrupt'

  # The busy footer must survive a queued-messages composer: the composer box,
  # queued hint, tip, and status rows render BELOW the footer and push it 7-9
  # non-blank rows above the bottom of the pane.
  "$1" claude 'queued-messages window depth' '✻ Cooked for 16s · 1 shell still running

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

  # The other verified harnesses' single-token signatures.
  "$1" codex 'interrupt footer' 'esc to interrupt'
  "$1" opencode 'interrupt footer' 'esc interrupt'
  "$1" pi 'working footer' 'Working...'
  "$1" grok 'cancel footer' 'Ctrl+c:cancel'
  "$1" kimi 'moon spinner' ' 🌑 · thinking'
}

each_busy_fixture busy_fixture
each_idle_fixture idle_fixture

# A session-scoped operator override is checked on its own terms; see the
# FM_BUSY_REGEX handling note above.
if [ -n "$BUSY_REGEX_OVERRIDE" ]; then
  each_busy_fixture override_busy_probe
  if [ "$OVERRIDE_INVALID" -ne 0 ]; then
    printf 'BUSY_SIGNATURE: all FM_BUSY_REGEX override: not a valid extended regular expression - every pane reads not-busy under it, so away-mode injection and submit acknowledgement lose their busy guard; fix or clear FM_BUSY_REGEX\n'
    FAILED=1
  else
    if [ "$OVERRIDE_BUSY_HITS" -eq 0 ]; then
      printf 'BUSY_SIGNATURE: all FM_BUSY_REGEX override: matches no recorded busy footer - either the pattern is dead (a typo or a stale copy, under which every working pane reads idle and delivery guards degrade fleet-wide), or it deliberately targets a NEW drifted footer shape these recorded fixtures cannot know yet; establish which live, then record the real shape as a fixture and ship the corrected signature in bin/fm-tmux-lib.sh before clearing FM_BUSY_REGEX\n'
      FAILED=1
    fi
    each_idle_fixture override_idle_fixture
  fi
fi

exit "$FAILED"
