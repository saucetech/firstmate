#!/usr/bin/env bash
# tests/fm-busy-selfcheck.test.sh - regression: the startup busy-signature
# self-check passes on the shipped signatures and fails loudly, in both
# directions, when a shipped signature stops classifying the recorded fixtures
# correctly - and treats a session-scoped FM_BUSY_REGEX override as the narrow,
# one-harness stopgap it is: the shipped signatures are still validated with the
# override cleared, and the override itself is only ever a finding in the
# dangerous false-BUSY direction.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-busy-selfcheck.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

test_shipped_signatures_pass_silently() {
  local out rc
  out=$(env -u FM_BUSY_REGEX "$ROOT/bin/fm-busy-selfcheck.sh" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "shipped signatures must pass the self-check, got exit $rc: $out"
  [ -z "$out" ] || fail "a passing self-check must stay silent, got: $out"
  pass "fm-busy-selfcheck: shipped signatures pass silently"
}

# The shipped signatures cannot be swapped from the environment (that is the
# point: FM_BUSY_REGEX no longer reaches the busy direction), so both shipped
# failure directions are pinned by running the real script against a stub
# signature library in a sandbox copy of bin/.
sandbox_with_matcher() {  # <name> <return-code> -> sandbox dir
  local sandbox=$1 rc=$2
  sandbox="$TMP_ROOT/$sandbox"
  mkdir -p "$sandbox"
  cp "$ROOT/bin/fm-busy-selfcheck.sh" "$sandbox/fm-busy-selfcheck.sh"
  cat > "$sandbox/fm-tmux-lib.sh" <<SH
fm_busy_tail_window_match() { cat >/dev/null; return $rc; }
SH
  printf '%s\n' "$sandbox"
}

test_dead_shipped_signature_fails_loudly() {
  local sandbox out rc
  sandbox=$(sandbox_with_matcher dead-signature 1)
  out=$(env -u FM_BUSY_REGEX bash "$sandbox/fm-busy-selfcheck.sh" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a shipped signature matching no busy fixture must fail the self-check"
  assert_contains "$out" "BUSY_SIGNATURE: claude shipped signature: recorded busy footer no longer matches" \
    "a dead shipped signature must name its source and the dead-busy direction"
  pass "fm-busy-selfcheck: a dead shipped signature fails loudly with BUSY_SIGNATURE lines"
}

test_false_busy_shipped_signature_fails_loudly() {
  local sandbox out rc
  sandbox=$(sandbox_with_matcher false-busy-signature 0)
  out=$(env -u FM_BUSY_REGEX bash "$sandbox/fm-busy-selfcheck.sh" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a shipped signature matching idle shapes must fail the self-check"
  assert_contains "$out" "BUSY_SIGNATURE: claude shipped signature: recorded idle shape matches as busy" \
    "a false-BUSY shipped signature must name its source and the dangerous direction"
  pass "fm-busy-selfcheck: a false-BUSY shipped signature fails loudly with BUSY_SIGNATURE lines"
}

# FM_BUSY_REGEX is global in fm_busy_lines_match but is used as a narrow,
# one-harness stopgap while a drift is being fixed. Running the per-harness busy
# fixtures against such an override would fail the untargeted harnesses by
# construction and print a permanent false diagnostic on every bootstrap, so the
# busy direction is checked against the shipped signatures only.
test_narrow_override_raises_no_false_busy_alarm() {
  local out rc
  out=$(FM_BUSY_REGEX='esc to interrupt' "$ROOT/bin/fm-busy-selfcheck.sh" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "a narrow claude-only override must not fail the self-check, got exit $rc: $out"
  [ -z "$out" ] || fail "a narrow claude-only override must raise no BUSY_SIGNATURE line, got: $out"
  pass "fm-busy-selfcheck: a narrow FM_BUSY_REGEX override raises no false busy-fixture alarm"
}

test_false_busy_override_fails_loudly() {
  local out rc
  out=$(FM_BUSY_REGEX='Worked for [0-9]+s' "$ROOT/bin/fm-busy-selfcheck.sh" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an override matching a recorded idle fixture must fail the self-check"
  assert_contains "$out" "BUSY_SIGNATURE: claude FM_BUSY_REGEX override: recorded idle shape matches as busy" \
    "a false-BUSY override must be attributed to FM_BUSY_REGEX, not the shipped signature"
  case "$out" in
    *'shipped signature:'*) fail "an override finding must not be reported against the shipped signatures: $out" ;;
  esac
  pass "fm-busy-selfcheck: a false-BUSY FM_BUSY_REGEX override fails loudly"
}

test_bootstrap_surfaces_the_diagnostic() {
  local out home
  home="$TMP_ROOT/bootstrap-home"
  mkdir -p "$home"
  out=$(FM_BUSY_REGEX='Worked for [0-9]+s' FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) || true
  assert_contains "$out" "BUSY_SIGNATURE:" \
    "bootstrap detect must surface the self-check's diagnostic lines"
  pass "fm-bootstrap: detect surfaces BUSY_SIGNATURE diagnostics"
}

test_shipped_signatures_pass_silently
test_dead_shipped_signature_fails_loudly
test_false_busy_shipped_signature_fails_loudly
test_narrow_override_raises_no_false_busy_alarm
test_false_busy_override_fails_loudly
test_bootstrap_surfaces_the_diagnostic
