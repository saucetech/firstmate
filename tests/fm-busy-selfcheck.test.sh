#!/usr/bin/env bash
# tests/fm-busy-selfcheck.test.sh - regression: the startup busy-signature
# self-check passes on the shipped signatures and fails loudly, in both
# directions, when the effective signature stops classifying the recorded
# fixtures correctly.
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

test_dead_signature_fails_loudly() {
  local out rc
  out=$(FM_BUSY_REGEX='will-never-match-any-footer' "$ROOT/bin/fm-busy-selfcheck.sh" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a signature matching no busy fixture must fail the self-check"
  assert_contains "$out" "BUSY_SIGNATURE: claude recorded busy footer no longer matches" \
    "a dead signature must name the dead-busy direction"
  pass "fm-busy-selfcheck: a dead signature fails loudly with BUSY_SIGNATURE lines"
}

test_false_busy_signature_fails_loudly() {
  local out rc
  out=$(FM_BUSY_REGEX='.' "$ROOT/bin/fm-busy-selfcheck.sh" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a signature matching idle shapes must fail the self-check"
  assert_contains "$out" "BUSY_SIGNATURE: claude recorded idle shape matches as busy" \
    "a false-BUSY signature must name the dangerous direction"
  pass "fm-busy-selfcheck: a false-BUSY signature fails loudly with BUSY_SIGNATURE lines"
}

test_bootstrap_surfaces_the_diagnostic() {
  local out home
  home="$TMP_ROOT/bootstrap-home"
  mkdir -p "$home"
  out=$(FM_BUSY_REGEX='will-never-match-any-footer' FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) || true
  assert_contains "$out" "BUSY_SIGNATURE:" \
    "bootstrap detect must surface the self-check's diagnostic lines"
  pass "fm-bootstrap: detect surfaces BUSY_SIGNATURE diagnostics"
}

test_shipped_signatures_pass_silently
test_dead_signature_fails_loudly
test_false_busy_signature_fails_loudly
test_bootstrap_surfaces_the_diagnostic
