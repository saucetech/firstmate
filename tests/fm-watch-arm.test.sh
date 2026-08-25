#!/usr/bin/env bash
# tests/fm-watch-arm.test.sh - the arm layer's cycle-close contract when the arm
# did not own the cycle.
#
# The watcher prints its one reason line to its OWN stdout, so only the arm that
# forked it ever reads that line. An arm that ATTACHED to an existing cycle holds
# no handle on it and can observe only a released lock, which is why a completely
# successful cycle used to be reported as
# "watcher: FAILED - cycle ended without an actionable reason" on every harness
# whose protocol reads that line. These are real-process tests: a real
# bin/fm-watch.sh holds the singleton, a real bin/fm-watch-arm.sh attaches to it,
# and a real status change drives a real wake through the watcher-bound delivery
# record and durable queue.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-arm-tests)

# Both starters background a real process the test later waits on, so they set a
# global instead of echoing: a command substitution would make the pid a child of
# a subshell this shell can no longer wait for.
SEED_PID=
ARM_PID=

# Start the real watcher as the singleton holder.
start_seed_watcher() {  # <state> <fakebin> <watch-out>
  local state=$1 fakebin=$2 out=$3 i
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  SEED_PID=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
      && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
    || fail "seed watcher did not take the lock"
}

# Attach a real arm to the live cycle.
start_attached_arm() {  # <state> <fakebin> <arm-out> <confirm-timeout>
  local state=$1 fakebin=$2 armout=$3 confirm=$4 i
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
    FM_ARM_CONFIRM_TIMEOUT="$confirm" "$WATCH_ARM" > "$armout" &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$SEED_PID" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$SEED_PID" "$armout" \
    || fail "arm did not attach to the live watcher: $(cat "$armout")"
}

test_attached_arm_reports_the_delivered_wake() {
  local dir state fakebin out armout status
  dir=$(make_case attached-delivered-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # A real captain-relevant status change: the watcher records it in the durable
  # queue, prints its one reason line to its own stdout, and exits.
  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  grep -q '^signal:' "$out" || fail "seed watcher did not surface the signal wake: $(cat "$out")"

  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -q 'demo.status' "$state/.wake-queue" \
    || fail "the wake was not durably recorded, so this case proves nothing"
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "attached arm reported a delivered wake as a failed cycle: $(cat "$armout")"
  grep -q '^signal:' "$armout" \
    || fail "attached arm did not report the durably recorded wake reason: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm whose cycle delivered a wake must close successfully"
  grep -q 'reason=attached-delivered-wake' "$state/.watch-cycle-exits.log" \
    || fail "the delivered-wake close was not classified in the lifecycle ledger"
  pass "watch-arm: an attached arm reports the wake its cycle delivered instead of a false failure"
}

test_attached_arm_reports_the_delivered_wake_after_drain() {
  local dir state fakebin out armout status
  dir=$(make_case attached-drained-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  # A wider confirmation budget keeps the arm in its successor wait while the
  # handling turn drains, which is the ordering this case exists to cover.
  start_attached_arm "$state" "$fakebin" "$armout" 5

  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  # The handling turn consumes the records before the attached arm closes: the
  # queue is empty again, while the watcher's identity-bound terminal record
  # still proves which cycle delivered the reason.
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "drain failed"
  [ ! -s "$state/.wake-queue" ] || fail "drain left records behind"

  wait_for_exit "$ARM_PID" 200
  status=$?
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "attached arm reported an already-handled wake as a failed cycle: $(cat "$armout")"
  grep -q '^signal:' "$armout" \
    || fail "attached arm did not report the delivered reason after the queue drain: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm whose wake was already drained must close successfully"
  pass "watch-arm: a delivered wake consumed by the handling turn still closes the attached arm cleanly"
}

test_attached_arm_still_fails_on_a_wake_it_did_not_deliver() {
  local dir state fakebin out armout status
  dir=$(make_case attached-no-delivery)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # A process-event producer advances the same home-wide queue while the
  # observed watcher remains uninvolved, so only watcher-bound evidence can
  # distinguish this from a delivered watcher cycle.
  append_wake "$state" check process-event "check: process-event result captured: fixture"
  kill "$SEED_PID" 2>/dev/null || true
  wait "$SEED_PID" 2>/dev/null || true
  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" \
    || fail "a cycle that delivered nothing must still fail loudly: $(cat "$armout")"
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "arm did not exit nonzero for a cycle that delivered nothing (status $status)"
  pass "watch-arm: a cycle that delivered no wake of its own still fails loudly"
}

# --- config/watch.env: the general watcher cadence knob ----------------------
# docs/configuration.md "Watcher cadence tuning" gives a home an optional,
# gitignored config/watch.env for FM_SIGNAL_GRACE and similar knobs. The sourcing
# lives in THIS wrapper, not in any one harness's hook, because the Claude Stop
# hook, the OpenCode plugin, the Pi extension and the Grok tracked background
# task all funnel through it; a hook-local sourcing left the knob silently inert
# for every non-Claude primary. Codex's foreground bin/fm-watch-checkpoint.sh
# path is the documented exception and is not exercised here.
#
# These cases run the REAL bin/fm-watch-arm.sh through a bin/ of symlinks whose
# fm-watch.sh is a stub that records the environment it was actually forked
# with, so each one proves what the wrapper hands the watcher child rather than
# what its own shell happens to hold.
make_arm_env_case() {  # <name>
  local name=$1 dir bin
  dir="$TMP_ROOT/$name"
  bin="$dir/bin"
  mkdir -p "$dir/state" "$dir/config" "$bin"
  ln -s "$ROOT/bin/fm-watch-arm.sh" "$bin/fm-watch-arm.sh"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$bin/fm-wake-lib.sh"
  cat > "$bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
{
  printf 'FM_SIGNAL_GRACE=%s\n' "${FM_SIGNAL_GRACE:-<unset>}"
  printf 'FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-<unset>}"
} > "$FM_STATE_OVERRIDE/watch-env"
printf 'signal: %s/fixture.status\n' "$FM_STATE_OVERRIDE"
exit 0
SH
  chmod +x "$bin/fm-watch.sh"
  printf '%s\n' "$dir"
}

# Run the wrapper as a non-Claude primary would: spawn it directly, with no hook
# in the process tree that could have sourced anything on its behalf.
run_arm_env_case() {  # <dir>
  local dir=$1
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_ARM_CONFIRM_TIMEOUT=3 \
    FM_ARM_ATTACH_POLL=0.1 "$dir/bin/fm-watch-arm.sh" 2>&1
}

test_watch_env_reaches_the_watcher_from_the_shared_arm_wrapper() {
  local dir out status dump
  dir=$(make_arm_env_case watch-env-reaches-watcher)
  # No `export`: the wrapper sources under `set -a`, so a plain assignment must
  # still reach the forked watcher child.
  printf 'FM_SIGNAL_GRACE=77\n' > "$dir/config/watch.env"
  out=$(run_arm_env_case "$dir"); status=$?
  expect_code 0 "$status" "arming with a config/watch.env present must still close cleanly"
  [ -e "$dir/state/watch-env" ] || fail "the arm wrapper never forked the watcher: $out"
  dump=$(cat "$dir/state/watch-env")
  grep -Fx "FM_SIGNAL_GRACE=77" "$dir/state/watch-env" >/dev/null \
    || fail "config/watch.env's cadence knob did not reach the watcher a non-Claude primary armed: $dump"
  pass "watch-arm: config/watch.env reaches the watcher from the shared arm wrapper, with no export needed"
}

test_x_mode_env_still_wins_over_watch_env() {
  local dir out status dump
  dir=$(make_arm_env_case watch-env-x-mode-precedence)
  printf 'FM_SIGNAL_GRACE=77\nFM_CHECK_INTERVAL=999\n' > "$dir/config/watch.env"
  printf 'export FM_CHECK_INTERVAL=30\n' > "$dir/config/x-mode.env"
  out=$(run_arm_env_case "$dir"); status=$?
  expect_code 0 "$status" "arming with both cadence configs present must still close cleanly"
  [ -e "$dir/state/watch-env" ] || fail "the arm wrapper never forked the watcher: $out"
  dump=$(cat "$dir/state/watch-env")
  grep -Fx "FM_CHECK_INTERVAL=30" "$dir/state/watch-env" >/dev/null \
    || fail "config/x-mode.env's generated cadence did not win over config/watch.env: $dump"
  grep -Fx "FM_SIGNAL_GRACE=77" "$dir/state/watch-env" >/dev/null \
    || fail "config/x-mode.env's precedence dropped watch.env's non-conflicting knob: $dump"
  pass "watch-arm: config/x-mode.env's generated cadence still wins over config/watch.env"
}

test_malformed_watch_env_does_not_break_arming() {
  local dir out status
  dir=$(make_arm_env_case watch-env-malformed)
  printf 'this is not valid shell ((( \n' > "$dir/config/watch.env"
  out=$(run_arm_env_case "$dir"); status=$?
  expect_code 0 "$status" "a malformed config/watch.env must not break arming"
  [ -e "$dir/state/watch-env" ] || fail "a malformed config/watch.env stopped the wrapper forking the watcher: $out"
  pass "watch-arm: a malformed config/watch.env fails past its own bad line without breaking arming"
}

test_attached_arm_reports_the_delivered_wake
test_attached_arm_reports_the_delivered_wake_after_drain
test_attached_arm_still_fails_on_a_wake_it_did_not_deliver
test_watch_env_reaches_the_watcher_from_the_shared_arm_wrapper
test_x_mode_env_still_wins_over_watch_env
test_malformed_watch_env_does_not_break_arming
