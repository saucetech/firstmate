#!/usr/bin/env bash
# Behavior tests for bin/fm-verify.sh, the independent-verifier spawn.
#
# What these tests are actually protecting: a verifier is only worth running if
# it judges the product without inheriting the builder's assumptions, and if a
# failing verdict genuinely holds the merge. Both properties are easy to erode
# by accident - passing the branch name "for convenience", defaulting the
# promise from the task title, or letting a busy fleet skip verification. Each
# test below pins one of those.
#
# bin/fm-spawn.sh is stubbed through FM_VERIFY_SPAWN_OVERRIDE: this suite owns
# fm-verify's resolution, refusal, binding, and rollback behavior, while real
# worktree allocation and endpoint creation stay covered by the spawn suites.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-verify)
fm_git_identity

FIX_HOME=
FIX_PROJ=
FIX_SPAWN=
FIX_SPAWN_LOG=
FIX_TMP=
BUILD_CMD='mkdir -p build && cp README.md build/app.txt'
BUILD_ARTIFACT='build/app.txt'
REAL_GIT_VERIFY=$(command -v git)
REAL_MKTEMP_VERIFY=$(command -v mktemp)
REAL_MV_VERIFY=$(command -v mv)
export REAL_GIT_VERIFY
export REAL_MKTEMP_VERIFY
export REAL_MV_VERIFY

# new_fixture <slug> [ship-id] [kind]: a home with one finished ship task whose
# branch fm/<ship-id> carries a commit the task's clone can resolve.
new_fixture() {
  local slug=$1 ship=${2:-demo-ship} kind=${3:-ship} dir
  dir="$TMP_ROOT/$slug"
  FIX_HOME="$dir/home"
  FIX_PROJ="$dir/proj"
  FIX_TMP="$dir/tmp"
  mkdir -p "$FIX_HOME/state" "$FIX_HOME/data" "$FIX_TMP"
  fm_git_init_commit "$FIX_PROJ"
  git -C "$FIX_PROJ" checkout -q -b "fm/$ship"
  printf 'shipped change\n' >> "$FIX_PROJ/README.md"
  git -C "$FIX_PROJ" add README.md
  git -C "$FIX_PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'shipped change'
  git -C "$FIX_PROJ" checkout -q -
  fm_write_meta "$FIX_HOME/state/$ship.meta" \
    "window=fixture:fm-$ship" "project=$FIX_PROJ" "kind=$kind"
  printf 'done: implemented\n' > "$FIX_HOME/state/$ship.status"
  new_fake_spawn "$dir" 0
}

# new_fake_spawn <dir> <exit-code>: a stub that records the arguments it was
# called with, so tests can assert how the verifier was launched.
new_fake_spawn() {
  local dir=$1 code=$2
  FIX_SPAWN="$dir/fake-spawn.sh"
  FIX_SPAWN_LOG="$dir/spawn.log"
  : > "$FIX_SPAWN_LOG"
cat > "$FIX_SPAWN" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$FIX_SPAWN_LOG'
if [ $code -eq 0 ]; then
  neutral=
  previous=
  for arg in "\$@"; do
    if [ "\$previous" = neutral ]; then neutral=\$arg; break; fi
    [ "\$arg" != --neutral-dir ] || previous=neutral
  done
  printf 'window=fixture:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=scout\nlaunch_mode=neutral\n' \
    "\$1" "\$1" "\$neutral" "\$2" > '$FIX_HOME/state/'"\$1"'.meta'
fi
exit $code
SH
  chmod +x "$FIX_SPAWN"
}

# run_verify <args...>: invoke fm-verify against the current fixture, capturing
# combined output into VERIFY_OUT and the exit code into VERIFY_RC.
VERIFY_OUT=
VERIFY_RC=0
run_verify() {
  local ship=${1:-} arg
  local has_verify_id=0
  local verify_args=()
  shift || true
  for arg in "$@"; do
    case "$arg" in --verify-id|--verify-id=*) has_verify_id=1 ;; esac
  done
  if [ "$has_verify_id" -eq 1 ]; then
    verify_args=("$@")
  else
    verify_args=(--verify-id demo-ship-verify)
    [ "$#" -eq 0 ] || verify_args+=("$@")
  fi
  VERIFY_OUT=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    "$ROOT/bin/fm-verify.sh" "$ship" "${verify_args[@]}" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  return 0
}

PROMISE='A user pastes a link and gets a named recipe with real ingredients.'

# wait_for_marker <test-flag> <path>: poll up to ~30s for a marker file.
# The neutral-launch design performs a real build (git worktree add, build
# command, artifact staging) before it reaches any of these observation points,
# which takes seconds on its own and longer when the suite runs loaded. The
# original 1-3s budgets here predated that build phase, and their flakiness is
# what previously made this suite look broken - which invited a "fix" that
# reverted the feature instead of the timing assumption. Keep this generous.
wait_for_marker() {
  local flag=$1 path=$2 i=0
  while [ "$i" -lt 600 ]; do
    # Branch on the mode rather than expanding a variable into the test
    # operator position: `[ "$flag" "$path" ]` is unparseable to shellcheck.
    if [ "$flag" = -s ]; then
      [ -s "$path" ] && return 0
    else
      [ -e "$path" ] && return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}


test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-verify.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-verify.sh must parse cleanly (got: $out)"
  pass "fm-verify.sh: bash -n succeeds"
}

test_help_states_the_contract() {
  local help
  help=$("$ROOT/bin/fm-verify.sh" --help)
  assert_contains "$help" "user-facing promise" "--help must explain the one required input"
  assert_contains "$help" "--build-cmd" "--help must explain how runnable artifacts are produced"
  assert_contains "$help" "never exempts one" \
    "--help must state that capacity defers a verification rather than skipping it"
  pass "fm-verify.sh: --help states the promise contract and the capacity rule"
}

# The promise is the single input that keeps the verifier independent. If it
# could be defaulted or omitted, the role would quietly decay into "spawn
# something and hope", so absence must be a hard refusal.
test_promise_is_mandatory() {
  new_fixture promise-required
  run_verify demo-ship
  expect_code 2 "$VERIFY_RC" "fm-verify must refuse to run without a promise"
  assert_contains "$VERIFY_OUT" "user-facing promise is required" \
    "the refusal must name the missing promise"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "no verifier may be spawned without a promise"
  pass "fm-verify: refuses to spawn a verifier with no user-facing promise"
}

test_build_configuration_is_mandatory() {
  new_fixture build-required
  VERIFY_OUT=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" 2>&1)
  VERIFY_RC=$?
  expect_code 2 "$VERIFY_RC" "fm-verify must refuse without an artifact build configuration"
  assert_contains "$VERIFY_OUT" "no configured way to produce a runnable artifact" \
    "the refusal must state why the project is unverifiable"
  assert_contains "$VERIFY_OUT" "firstmate must decide" \
    "the refusal must keep the configuration decision with firstmate"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "no verifier may spawn without a runnable artifact"
  pass "fm-verify: refuses projects with no configured artifact build"
}

test_promise_must_be_singular_and_non_empty() {
  local promise_file
  new_fixture promise-shape
  promise_file="$TMP_ROOT/promise-shape/promise.md"
  printf '%s\n' "$PROMISE" > "$promise_file"

  run_verify demo-ship --promise "$PROMISE" --promise-file "$promise_file"
  expect_code 2 "$VERIFY_RC" "two promise sources must be refused"
  assert_contains "$VERIFY_OUT" "only one of" "the refusal must name the conflict"

  printf '   \n\n' > "$promise_file"
  run_verify demo-ship --promise-file "$promise_file"
  expect_code 2 "$VERIFY_RC" "a whitespace-only promise must be refused"
  assert_contains "$VERIFY_OUT" "promise is empty" "the refusal must name the empty promise"

  run_verify demo-ship --promise-file "$TMP_ROOT/promise-shape/absent.md"
  expect_code 2 "$VERIFY_RC" "a missing promise file must be refused"
  pass "fm-verify: the promise must be supplied exactly once and carry content"
}

test_refuses_what_cannot_be_verified() {
  new_fixture unknown-task
  run_verify no-such-task --promise "$PROMISE"
  expect_code 1 "$VERIFY_RC" "an unknown task must be refused"
  assert_contains "$VERIFY_OUT" "no record of task" "the refusal must say the task is unknown"

  new_fixture scout-task scouty scout
  run_verify scouty --promise "$PROMISE"
  expect_code 1 "$VERIFY_RC" "a scout task has no user-facing change to verify"
  assert_contains "$VERIFY_OUT" "kind=scout" "the refusal must name the wrong kind"
  pass "fm-verify: refuses a torn-down task and a task that ships nothing to a user"
}

test_refuses_when_the_revision_cannot_be_resolved() {
  new_fixture no-branch
  git -C "$FIX_PROJ" branch -q -D fm/demo-ship
  run_verify demo-ship --promise "$PROMISE"
  expect_code 1 "$VERIFY_RC" "an unresolvable revision must be refused, not guessed"
  assert_contains "$VERIFY_OUT" "cannot resolve" "the refusal must name the unresolvable revision"
  assert_contains "$VERIFY_OUT" "--rev" "the refusal must point at the way to supply a revision"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "no verifier may be spawned without a resolved revision"
  pass "fm-verify: refuses rather than verifying an unknown revision"
}

test_spawns_a_scout_in_a_neutral_artifact_directory() {
  local args neutral
  new_fixture spawn-shape
  run_verify demo-ship --promise "$PROMISE"
  expect_code 0 "$VERIFY_RC" "a well-formed verification must spawn (got: $VERIFY_OUT)"
  args=$(cat "$FIX_SPAWN_LOG")
  assert_contains "$args" "demo-ship-verify" "the verifier must launch under its own task id"
  assert_contains "$args" "$FIX_PROJ" "the verifier must launch against the task's project"
  assert_contains "$args" "--scout" \
    "the verifier must launch with scout semantics: scratch worktree, report deliverable, no PR"
  assert_contains "$args" "--neutral-dir" "the verifier must use the non-repository launch mode"
  neutral=$(printf '%s\n' "$args" | awk '{for (i=1;i<=NF;i++) if ($i=="--neutral-dir") print $(i+1)}')
  [ -d "$neutral" ] || fail "the neutral verifier directory was not retained for the live task"
  [ ! -e "$neutral/.git" ] || fail "the neutral verifier directory must not contain git metadata"
  [ ! -e "$neutral/AGENTS.md" ] || fail "the neutral verifier directory must not contain AGENTS.md"
  assert_present "$neutral/artifacts/build/app.txt" "the configured artifact must be copied into the neutral directory"
  pass "fm-verify: launches a scout with only the runnable artifact"
}

# The load-bearing independence property is structural: the verifier receives
# runnable artifacts in a directory with no repository or source tree.
test_verifier_is_handed_artifacts_not_source() {
  local brief
  new_fixture independence
  run_verify demo-ship --promise "$PROMISE"
  expect_code 0 "$VERIFY_RC" "the verification must spawn (got: $VERIFY_OUT)"
  brief="$FIX_HOME/data/demo-ship-verify/brief.md"
  assert_present "$brief" "the verifier must receive a brief"
  assert_grep 'already-built runnable artifact' "$brief" \
    "the verifier brief must point at the extracted runnable artifact"
  assert_grep 'do NOT have the source tree' "$brief" \
    "the verifier brief must state the structural source isolation"
  assert_no_grep 'git checkout' "$brief" "the verifier brief must not contain a repository checkout"
  assert_no_grep 'README.*quickstart\|explicit run script' "$brief" \
    "the verifier brief must not ask the verifier to discover a build"
  assert_no_grep 'AGENTS.md' "$brief" "the verifier brief must not name developer-facing instructions"
  assert_no_grep 'fm/demo-ship' "$brief" \
    "the brief must never name the task branch: it identifies the implementing task"
  assert_grep "$PROMISE" "$brief" "the verifier must receive the user-facing promise"
  pass "fm-verify: the verifier gets artifacts and a promise without source context"
}

test_explicit_revision_overrides_the_branch() {
  local base sidecar
  new_fixture explicit-rev
  base=$(git -C "$FIX_PROJ" rev-parse HEAD)
  run_verify demo-ship --promise "$PROMISE" --rev "$base"
  expect_code 0 "$VERIFY_RC" "an explicit revision must be accepted (got: $VERIFY_OUT)"
  sidecar="$FIX_HOME/state/demo-ship-verify.verify"
  assert_grep "rev=$base" "$sidecar" "an explicit --rev must bind the artifact build"
  pass "fm-verify: --rev pins the exact revision under verification"
}

test_binds_the_verdict_to_the_task_it_gates() {
  local sidecar rev
  new_fixture binding
  rev=$(git -C "$FIX_PROJ" rev-parse fm/demo-ship)
  run_verify demo-ship --promise "$PROMISE"
  expect_code 0 "$VERIFY_RC" "the verification must spawn (got: $VERIFY_OUT)"
  sidecar="$FIX_HOME/state/demo-ship-verify.verify"
  assert_present "$sidecar" "a verification must leave a durable binding record"
  assert_grep "verifies=demo-ship" "$sidecar" "the record must name the task whose merge it gates"
  assert_grep "rev=$rev" "$sidecar" "the record must pin the verified revision"
  assert_grep "project=$FIX_PROJ" "$sidecar" "the record must name the project"
  assert_grep "promise=" "$sidecar" "the record must fingerprint the promise that was judged"
  pass "fm-verify: a durable record binds the verdict to its task, revision, and promise"
}

test_duplicate_verification_is_refused() {
  new_fixture duplicate
  run_verify demo-ship --promise "$PROMISE"
  expect_code 0 "$VERIFY_RC" "the first verification must spawn (got: $VERIFY_OUT)"
  fm_write_meta "$FIX_HOME/state/demo-ship-verify.meta" "window=fixture:fm-demo-ship-verify"
  : > "$FIX_SPAWN_LOG"
  run_verify demo-ship --promise "$PROMISE"
  expect_code 1 "$VERIFY_RC" "a second concurrent verification of the same task must be refused"
  assert_contains "$VERIFY_OUT" "already under way" "the refusal must say a verification is running"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "a duplicate verification must not spawn"
  pass "fm-verify: refuses to start a second verification over a live one"
}

# Capacity must delay a verification, never excuse one. An exemption path is
# exactly how this role would become decorative under load.
test_capacity_defers_and_never_skips() {
  new_fixture capacity
  fm_write_meta "$FIX_HOME/state/other-verify.meta" "window=fixture:fm-other-verify"
  printf 'verifies=other\n' > "$FIX_HOME/state/other-verify.verify"

  VERIFY_OUT=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    FM_VERIFY_MAX_CONCURRENT=1 "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  expect_code 1 "$VERIFY_RC" "a verification at the capacity limit must not proceed"
  assert_contains "$VERIFY_OUT" "at the limit of 1" "the refusal must state the limit reached"
  assert_contains "$VERIFY_OUT" "never skipped" \
    "the refusal must make clear the verification waits rather than being dropped"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "a verification over capacity must not spawn"
  assert_absent "$FIX_HOME/data/demo-ship-verify/brief.md" \
    "a deferred verification must leave no half-built artifacts"
  pass "fm-verify: capacity defers a verification and says so, rather than skipping it"
}

test_capacity_ignores_finished_verifications() {
  new_fixture capacity-stale
  # A binding record whose task is gone belongs to a torn-down verification and
  # holds no build or simulator slot.
  printf 'verifies=old\n' > "$FIX_HOME/state/old-verify.verify"
  VERIFY_OUT=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    FM_VERIFY_MAX_CONCURRENT=1 "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  expect_code 0 "$VERIFY_RC" \
    "a torn-down verification must not consume capacity (got: $VERIFY_OUT)"
  pass "fm-verify: only live verifications count against capacity"
}

test_capacity_counts_a_pre_spawn_reservation() {
  local dir hold_spawn entered release first_out first_pid first_rc second_spawn
  new_fixture capacity-reservation
  dir="$TMP_ROOT/capacity-reservation"
  hold_spawn="$dir/hold-spawn.sh"
  entered="$dir/spawn-entered"
  release="$dir/spawn-release"
  first_out="$dir/first.out"
  second_spawn=$FIX_SPAWN
cat > "$hold_spawn" <<SH
#!/usr/bin/env bash
touch '$entered'
while [ ! -e '$release' ]; do sleep 0.05; done
neutral=
previous=
for arg in "\$@"; do
  if [ "\$previous" = neutral ]; then neutral=\$arg; break; fi
  [ "\$arg" != --neutral-dir ] || previous=neutral
done
printf 'window=fixture:fm-%s\nworktree=%s\nproject=%s\nkind=scout\nlaunch_mode=neutral\n' \
  "\$1" "\$neutral" "\$2" > '$FIX_HOME/state/'"\$1"'.meta'
exit 0
SH
  chmod +x "$hold_spawn"

  TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$hold_spawn" \
    FM_VERIFY_MAX_CONCURRENT=1 "$ROOT/bin/fm-verify.sh" demo-ship \
    --verify-id first-reservation --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" > "$first_out" 2>&1 &
  first_pid=$!
  wait_for_marker -e "$entered" || true
  if [ ! -e "$entered" ]; then
    touch "$release"
    wait "$first_pid"
    fail "the first verification never reached its spawn"
  fi

  VERIFY_OUT=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$second_spawn" \
    FM_VERIFY_MAX_CONCURRENT=1 "$ROOT/bin/fm-verify.sh" demo-ship \
    --verify-id second-reservation --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  touch "$release"
  wait "$first_pid"; first_rc=$?

  expect_code 0 "$first_rc" "the slot-holding verification must finish (got: $(cat "$first_out"))"
  expect_code 1 "$VERIFY_RC" "a pre-spawn reservation must consume the only capacity slot"
  assert_contains "$VERIFY_OUT" "at the limit of 1" \
    "the concurrent refusal must identify the occupied capacity slot"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "the deferred verification must not reach its spawn"
  pass "fm-verify: a binding reserves capacity before task metadata is published"
}

test_concurrent_admission_keeps_one_available_slot() {
  local out_a out_b pid_a pid_b rc_a rc_b successes lines
  new_fixture capacity-atomic
  out_a="$FIX_TMP/race-a.out"
  out_b="$FIX_TMP/race-b.out"
  TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    FM_VERIFY_MAX_CONCURRENT=1 "$ROOT/bin/fm-verify.sh" demo-ship \
    --verify-id race-a --promise "$PROMISE" --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" \
    > "$out_a" 2>&1 &
  pid_a=$!
  TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    FM_VERIFY_MAX_CONCURRENT=1 "$ROOT/bin/fm-verify.sh" demo-ship \
    --verify-id race-b --promise "$PROMISE" --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" \
    > "$out_b" 2>&1 &
  pid_b=$!
  wait "$pid_a"; rc_a=$?
  wait "$pid_b"; rc_b=$?
  successes=0
  [ "$rc_a" -ne 0 ] || successes=$((successes + 1))
  [ "$rc_b" -ne 0 ] || successes=$((successes + 1))
  [ "$successes" -eq 1 ] || fail "atomic admission must admit exactly one contender, got rc_a=$rc_a rc_b=$rc_b"
  lines=$(wc -l < "$FIX_SPAWN_LOG" | tr -d ' ')
  [ "$lines" -eq 1 ] || fail "atomic admission must launch exactly one verifier, got $lines"
  pass "fm-verify: concurrent callers cannot both surrender an available slot"
}

test_concurrent_same_id_reservation_is_exclusive() {
  local out_a out_b pid_a pid_b rc_a rc_b successes lines
  new_fixture identity-atomic
  out_a="$FIX_TMP/same-a.out"
  out_b="$FIX_TMP/same-b.out"
  TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    FM_VERIFY_MAX_CONCURRENT=2 "$ROOT/bin/fm-verify.sh" demo-ship --verify-id same-verifier \
    --promise "$PROMISE" --build-cmd 'sleep 1; mkdir -p build; cp README.md build/app.txt' \
    --artifact "$BUILD_ARTIFACT" > "$out_a" 2>&1 &
  pid_a=$!
  TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    FM_VERIFY_MAX_CONCURRENT=2 "$ROOT/bin/fm-verify.sh" demo-ship --verify-id same-verifier \
    --promise "$PROMISE" --build-cmd 'sleep 1; mkdir -p build; cp README.md build/app.txt' \
    --artifact "$BUILD_ARTIFACT" > "$out_b" 2>&1 &
  pid_b=$!
  wait "$pid_a"; rc_a=$?
  wait "$pid_b"; rc_b=$?
  successes=0
  [ "$rc_a" -ne 0 ] || successes=$((successes + 1))
  [ "$rc_b" -ne 0 ] || successes=$((successes + 1))
  [ "$successes" -eq 1 ] \
    || fail "same verifier id must admit exactly one contender, got rc_a=$rc_a rc_b=$rc_b"
  lines=$(wc -l < "$FIX_SPAWN_LOG" | tr -d ' ')
  [ "$lines" -eq 1 ] || fail "same verifier id launched $lines verifier endpoints"
  pass "fm-verify: concurrent callers cannot reserve the same verifier id"
}

test_default_id_rolls_forward_with_the_revision() {
  local first_rev first_id second_rev second_id
  new_fixture revision-default-id
  first_rev=$(git -C "$FIX_PROJ" rev-parse fm/demo-ship)
  first_id="demo-ship-verify-${first_rev:0:12}"
  VERIFY_OUT=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    "$ROOT/bin/fm-verify.sh" demo-ship --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  expect_code 0 "$VERIFY_RC" "the first revision-specific default verification must spawn"
  assert_present "$FIX_HOME/state/$first_id.verify" \
    "the default verifier id must include the bound revision"
  rm -f "$FIX_HOME/state/$first_id.meta"
  git -C "$FIX_PROJ" checkout -q fm/demo-ship
  printf 'next shipped change\n' >> "$FIX_PROJ/README.md"
  git -C "$FIX_PROJ" add README.md
  git -C "$FIX_PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'next shipped change'
  git -C "$FIX_PROJ" checkout -q -
  second_rev=$(git -C "$FIX_PROJ" rev-parse fm/demo-ship)
  second_id="demo-ship-verify-${second_rev:0:12}"
  VERIFY_OUT=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    "$ROOT/bin/fm-verify.sh" demo-ship --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  expect_code 0 "$VERIFY_RC" "a moved head must receive a new default verifier id"
  [ "$first_id" != "$second_id" ] || fail "two revisions resolved to the same verifier id"
  assert_present "$FIX_HOME/data/$first_id/brief.md" \
    "re-verification discarded the earlier verifier brief"
  assert_present "$FIX_HOME/state/$first_id.verify" \
    "re-verification discarded the earlier revision binding"
  assert_present "$FIX_HOME/data/$second_id/brief.md" \
    "re-verification did not create a new verifier brief"
  assert_present "$FIX_HOME/state/$second_id.verify" \
    "re-verification did not create a new revision binding"
  pass "fm-verify: default ids preserve evidence across head revisions"
}

test_spawn_failure_with_unknown_endpoint_retains_artifacts() {
  local neutral
  new_fixture rollback
  new_fake_spawn "$TMP_ROOT/rollback" 1
  run_verify demo-ship --promise "$PROMISE"
  [ "$VERIFY_RC" -ne 0 ] || fail "a failed spawn must be reported as a failure"
  assert_contains "$VERIFY_OUT" "endpoint absence could not be confirmed" \
    "the failure must name the uncertain endpoint state"
  neutral=$(awk -F= '$1 == "neutral_cleanup_path" { print substr($0, index($0, "=") + 1) }' \
    "$FIX_HOME/state/demo-ship-verify.verify")
  [ -d "$neutral" ] || fail "an uncertain spawn failure removed the neutral directory"
  assert_present "$FIX_HOME/data/demo-ship-verify/brief.md" \
    "an uncertain spawn failure must retain the verifier brief"
  assert_contains "$VERIFY_OUT" "task 'demo-ship-verify'" \
    "the uncertain failure must name the task to reconcile"
  assert_contains "$VERIFY_OUT" "$neutral" \
    "the uncertain failure must name the neutral path to reconcile"
  pass "fm-verify: uncertain spawn failures retain reconciliation artifacts"
}

test_uncertain_endpoint_holds_capacity() {
  local second_out second_rc
  new_fixture uncertain-endpoint-capacity
  new_fake_spawn "$TMP_ROOT/uncertain-endpoint-capacity" 1
  run_verify demo-ship --verify-id uncertain-first --promise "$PROMISE"
  expect_code 1 "$VERIFY_RC" "an uncertain spawn must fail closed"
  assert_grep 'endpoint_uncertain=1' "$FIX_HOME/state/uncertain-first.verify" \
    "the uncertain endpoint must be recorded durably"
  : > "$FIX_SPAWN_LOG"
  second_out=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    FM_VERIFY_MAX_CONCURRENT=1 "$ROOT/bin/fm-verify.sh" demo-ship \
    --verify-id uncertain-second --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  second_rc=$?
  expect_code 1 "$second_rc" "an uncertain endpoint must continue consuming its slot"
  assert_contains "$second_out" "at the limit of 1" \
    "the next verification must report the retained capacity slot"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "a retained uncertain endpoint admitted another spawn"
  pass "fm-verify: uncertain endpoints retain their capacity slots"
}

test_existing_report_refuses_id_reuse() {
  new_fixture rollback-existing-data
  mkdir -p "$FIX_HOME/data/demo-ship-verify"
  printf 'retained report\n' > "$FIX_HOME/data/demo-ship-verify/report.md"
  new_fake_spawn "$TMP_ROOT/rollback-existing-data" 1
  run_verify demo-ship --promise "$PROMISE"
  expect_code 1 "$VERIFY_RC" "a verifier id with existing evidence must be refused"
  assert_contains "$VERIFY_OUT" "report already exists" \
    "the refusal must identify the retained verifier report"
  assert_grep 'retained report' "$FIX_HOME/data/demo-ship-verify/report.md" \
    "id reuse must preserve the earlier verifier report"
  assert_absent "$FIX_HOME/data/demo-ship-verify/brief.md" \
    "id reuse must not add a brief beside earlier evidence"
  assert_absent "$FIX_HOME/state/demo-ship-verify.verify" \
    "id reuse must not publish a replacement binding"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "id reuse reached verifier spawn"
  pass "fm-verify: verifier ids cannot overwrite existing evidence"
}

test_partial_spawn_retains_reconciliation_artifacts() {
  new_fixture partial-spawn
  cat > "$FIX_SPAWN" <<SH
#!/usr/bin/env bash
printf 'window=fixture:fm-demo-ship-verify\n' > '$FIX_HOME/state/demo-ship-verify.meta'
exit 1
SH
  chmod +x "$FIX_SPAWN"
  run_verify demo-ship --promise "$PROMISE"
  [ "$VERIFY_RC" -ne 0 ] || fail "a partial spawn must be reported as a failure"
  assert_contains "$VERIFY_OUT" "partial spawn left in place" \
    "a late spawn failure must identify the partial task"
  assert_contains "$VERIFY_OUT" "task 'demo-ship-verify'" \
    "the reconciliation message must name the exact verifier task id"
  assert_present "$FIX_HOME/data/demo-ship-verify/brief.md" \
    "a partial spawn must retain the verifier brief"
  assert_present "$FIX_HOME/state/demo-ship-verify.verify" \
    "a partial spawn must retain the verification binding"
  pass "fm-verify: partial spawn artifacts remain available for reconciliation"
}

test_spawn_handoff_persistence_failure_is_reported() {
  local fakebin
  new_fixture handoff-persistence
  fakebin="$FIX_TMP/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
source_path=${1:-}
destination=${2:-}
if [ "$destination" = "${FM_VERIFY_TEST_SIDECAR:-}" ] \
   && grep -q '^endpoint_uncertain=1$' "$destination" 2>/dev/null \
   && ! grep -q '^endpoint_uncertain=' "$source_path" 2>/dev/null; then
  exit 73
fi
exec "$REAL_MV_VERIFY" "$@"
SH
  chmod +x "$fakebin/mv"
  VERIFY_OUT=$(PATH="$fakebin:$PATH" TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" \
    FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    FM_VERIFY_TEST_SIDECAR="$FIX_HOME/state/demo-ship-verify.verify" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  expect_code 1 "$VERIFY_RC" "a failed handoff write must fail the verifier spawn"
  assert_contains "$VERIFY_OUT" "handoff could not be persisted" \
    "the handoff failure must report its durable-state problem"
  assert_grep 'endpoint_uncertain=1' "$FIX_HOME/state/demo-ship-verify.verify" \
    "a failed handoff write must not pretend endpoint uncertainty was cleared"
  pass "fm-verify: spawn handoff failures remain explicit and reconcilable"
}

test_build_failure_is_a_result_without_a_spawn() {
  new_fixture build-failure
  VERIFY_OUT=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd 'exit 17' --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  expect_code 0 "$VERIFY_RC" "a build failure is a verification result, not an orchestration failure"
  assert_contains "$VERIFY_OUT" "not delivered - does not build" \
    "the build result must state the failing verdict"
  assert_grep 'not delivered' "$FIX_HOME/data/demo-ship-verify/report.md" \
    "the build result must be durable in the verifier report"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "a verifier must not spawn without a runnable artifact"
  pass "fm-verify: build failure records not delivered without spawning"
}

test_artifact_path_cannot_escape_through_a_symlinked_parent() {
  new_fixture artifact-parent-escape
  VERIFY_OUT=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd "ln -s '$FIX_PROJ' escaped" --artifact escaped/README.md 2>&1)
  VERIFY_RC=$?
  expect_code 1 "$VERIFY_RC" "a symlinked artifact parent that escapes source isolation must be refused"
  assert_contains "$VERIFY_OUT" "artifact path escapes" \
    "the refusal must name the escaping configured path"
  assert_absent "$FIX_HOME/data/demo-ship-verify/report.md" \
    "an artifact isolation failure must not become a product verdict"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "an escaping artifact path must be refused before spawn"
  pass "fm-verify: rejects artifact parents that escape the build worktree"
}

test_artifact_descendant_symlink_must_stay_neutral() {
  new_fixture artifact-descendant-escape
  VERIFY_OUT=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd "mkdir -p build/App && ln -s '$FIX_PROJ/README.md' build/App/source-link" \
    --artifact build/App 2>&1)
  VERIFY_RC=$?
  expect_code 1 "$VERIFY_RC" "an artifact descendant symlink to source must be refused"
  assert_contains "$VERIFY_OUT" "symbolic link escapes the neutral directory" \
    "the refusal must identify the descendant symlink escape"
  assert_absent "$FIX_HOME/data/demo-ship-verify/report.md" \
    "a descendant symlink escape must not become a product verdict"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "an external descendant symlink must be refused before spawn"
  pass "fm-verify: rejects artifact symlinks that point outside neutral storage"
}

test_artifact_internal_symlink_is_preserved() {
  local args neutral
  new_fixture artifact-internal-symlink
  VERIFY_OUT=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd 'mkdir -p build/App/Versions/A && cp README.md build/App/Versions/A/app && ln -s A build/App/Versions/Current' \
    --artifact build/App 2>&1)
  VERIFY_RC=$?
  expect_code 0 "$VERIFY_RC" "an internal relative artifact symlink must remain usable (got: $VERIFY_OUT)"
  args=$(cat "$FIX_SPAWN_LOG")
  neutral=$(printf '%s\n' "$args" | awk '{for (i=1;i<=NF;i++) if ($i=="--neutral-dir") print $(i+1)}')
  [ -L "$neutral/artifacts/build/App/Versions/Current" ] \
    || fail "the artifact's internal relative symlink was not preserved"
  [ "$(readlink "$neutral/artifacts/build/App/Versions/Current")" = A ] \
    || fail "the artifact's internal relative symlink target changed"
  pass "fm-verify: preserves internal relative symlinks inside artifacts"
}

test_cross_artifact_internal_symlink_is_preserved() {
  local args neutral
  new_fixture cross-artifact-internal-symlink
  VERIFY_OUT=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd 'mkdir -p build/first build/second && ln -s ../second/payload build/first/to-payload && cp README.md build/second/payload' \
    --artifact build/first --artifact build/second 2>&1)
  VERIFY_RC=$?
  expect_code 0 "$VERIFY_RC" "a symlink into a later staged artifact must remain usable (got: $VERIFY_OUT)"
  args=$(cat "$FIX_SPAWN_LOG")
  neutral=$(printf '%s\n' "$args" | awk '{for (i=1;i<=NF;i++) if ($i=="--neutral-dir") print $(i+1)}')
  [ -L "$neutral/artifacts/build/first/to-payload" ] \
    || fail "the cross-artifact relative symlink was not preserved"
  [ "$(cat "$neutral/artifacts/build/first/to-payload")" = "$(cat "$neutral/artifacts/build/second/payload")" ] \
    || fail "the cross-artifact relative symlink no longer resolves to its staged target"
  pass "fm-verify: accepts internal symlinks between fully staged artifacts"
}

test_unusable_build_runner_is_not_a_product_verdict() {
  local fakebin
  new_fixture unusable-build-runner
  fakebin="$FIX_TMP/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/perl" <<'SH'
#!/usr/bin/env bash
exit 86
SH
  chmod +x "$fakebin/perl"
  VERIFY_OUT=$(PATH="$fakebin:$PATH" TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" \
    FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify \
    --promise "$PROMISE" --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  expect_code 1 "$VERIFY_RC" "an unusable build runner must be an orchestration error"
  assert_contains "$VERIFY_OUT" "build runner is missing or unusable" \
    "the error must identify the unavailable runner"
  assert_absent "$FIX_HOME/data/demo-ship-verify/report.md" \
    "runner failure must not write a product verdict"
  assert_absent "$FIX_HOME/state/demo-ship-verify.status" \
    "runner failure must not write a delivered-state record"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "runner failure must stop before verifier spawn"
  pass "fm-verify: reports an unusable runner without blaming the product"
}

test_build_timeout_is_not_a_product_verdict() {
  new_fixture build-timeout
  VERIFY_OUT=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    FM_VERIFY_BUILD_TIMEOUT=1 "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd 'sleep 5' --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  expect_code 1 "$VERIFY_RC" "a locally imposed build timeout must be an orchestration error"
  assert_contains "$VERIFY_OUT" "FM_VERIFY_BUILD_TIMEOUT=1 seconds" \
    "the timeout error must name the elapsed bound"
  assert_absent "$FIX_HOME/data/demo-ship-verify/report.md" \
    "a build timeout must not write a product verdict"
  assert_absent "$FIX_HOME/state/demo-ship-verify.status" \
    "a build timeout must not write a delivered-state record"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "a timed-out build must stop before verifier spawn"
  pass "fm-verify: reports build timeout as orchestration failure"
}

test_build_cannot_forge_runner_status() {
  local BUILD_CMD
  new_fixture forged-runner-status
  BUILD_CMD='mkdir -p build && cp README.md build/app.txt && printf "%s\n" exit:125 > ../runner.status && chmod 000 ../runner.status'
  run_verify demo-ship --promise "$PROMISE"
  expect_code 0 "$VERIFY_RC" "a guessed status path must not influence a successful build (got: $VERIFY_OUT)"
  [ -s "$FIX_SPAWN_LOG" ] || fail "a guessed status path prevented verifier spawn"
  assert_absent "$FIX_HOME/data/demo-ship-verify/report.md" \
    "a guessed status path manufactured a product verdict"
  pass "fm-verify: build output cannot forge the private runner result"
}

test_build_descendants_are_drained_before_staging() {
  local BUILD_CMD BUILD_ARTIFACT args neutral descendant
  new_fixture build-descendant-drain
  # shellcheck disable=SC2016  # single quotes are deliberate: this is a build-command
  # string evaluated later by the build shell, so $! and $descendant must stay literal.
  BUILD_CMD='mkdir -p build; cp README.md build/app.txt; (trap "" TERM; while :; do sleep 1; done) & descendant=$!; echo "$descendant" > build/descendant.pid; exit 0'
  BUILD_ARTIFACT=build
  run_verify demo-ship --promise "$PROMISE"
  expect_code 0 "$VERIFY_RC" "a build with a background descendant must finish under supervision (got: $VERIFY_OUT)"
  args=$(cat "$FIX_SPAWN_LOG")
  neutral=$(printf '%s\n' "$args" | awk '{for (i=1;i<=NF;i++) if ($i=="--neutral-dir") print $(i+1)}')
  descendant=$(cat "$neutral/artifacts/build/descendant.pid")
  if kill -0 "$descendant" 2>/dev/null; then
    kill -KILL "$descendant" 2>/dev/null || true
    fail "a build descendant remained alive after artifact staging"
  fi
  pass "fm-verify: build descendants are drained before artifact staging"
}

test_build_descendant_escaping_its_process_group_fails_closed() {
  local BUILD_CMD helper escaped_pid_file escaped_pid
  new_fixture escaped-build-descendant
  helper="$FIX_TMP/escape-descendant.pl"
  escaped_pid_file="$FIX_TMP/escaped.pid"
  cat > "$helper" <<'PL'
#!/usr/bin/env perl
use POSIX qw(setsid);
defined(my $first = fork) or die "first fork: $!";
exit 0 if $first;
setsid() or die "setsid: $!";
defined(my $second = fork) or die "second fork: $!";
exit 0 if $second;
open STDIN, '<', '/dev/null' or die "stdin: $!";
open STDOUT, '>', '/dev/null' or die "stdout: $!";
open STDERR, '>', '/dev/null' or die "stderr: $!";
open my $pid_file, '>', $ARGV[0] or die "pid file: $!";
print {$pid_file} "$$\n";
close $pid_file;
$SIG{TERM} = 'IGNORE';
sleep 1 while 1;
PL
  chmod +x "$helper"
  # The helper double-forks, so the detached grandchild is created asynchronously
  # and may not exist yet when the build returns. Wait for it to publish its pid
  # before exiting, or the post-build scan races it and the run refuses without
  # naming that pid - an observed ~1-in-5 flake. This does NOT weaken the
  # assertion: the descendant still detaches, still ignores TERM, and detection
  # still has to find it uncooperatively. Do not delete this wait to "fix" a
  # failure here - a flaky test in this suite is what previously invited a
  # revert of the feature instead of a fix to the timing assumption.
  BUILD_CMD="mkdir -p build; cp README.md build/app.txt; '$helper' '$escaped_pid_file'; while [ ! -s '$escaped_pid_file' ]; do sleep 0.05; done; exit 0"
  run_verify demo-ship --promise "$PROMISE"
  expect_code 1 "$VERIFY_RC" "an immediate double-forked descendant must fail closed (got: $VERIFY_OUT)"
  [ -s "$escaped_pid_file" ] || fail "the escaped descendant did not publish its pid"
  escaped_pid=$(cat "$escaped_pid_file")
  assert_contains "$VERIFY_OUT" "escaped-descendants:$escaped_pid" \
    "the orchestration error must identify the escaped descendant"
  if kill -0 "$escaped_pid" 2>/dev/null; then
    kill -KILL "$escaped_pid" 2>/dev/null || true
    fail "the escaped build descendant remained alive"
  fi
  assert_absent "$FIX_HOME/data/demo-ship-verify/report.md" \
    "an escaped descendant must not become a product verdict"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "an escaped descendant must stop artifact staging and spawn"
  pass "fm-verify: immediate escaped build descendants fail closed"
}

test_build_descendant_closing_lineage_fails_closed() {
  local BUILD_CMD helper escaped_pid_file escaped_pid retained_pids worktree container
  new_fixture closed-lineage-descendant
  helper="$FIX_TMP/close-lineage.pl"
  escaped_pid_file="$FIX_TMP/closed-lineage.pid"
  cat > "$helper" <<'PL'
#!/usr/bin/env perl
use POSIX qw(setsid);
defined(my $first = fork) or die "first fork: $!";
exit 0 if $first;
setsid() or die "setsid: $!";
defined(my $second = fork) or die "second fork: $!";
exit 0 if $second;
for my $fd (0 .. 255) { POSIX::close($fd); }
open my $pid_file, '>', $ARGV[0] or exit 74;
print {$pid_file} "$$\n";
close $pid_file;
$SIG{TERM} = 'IGNORE';
sleep 1 while 1;
PL
  chmod +x "$helper"
  # The helper double-forks, so the detached grandchild is created asynchronously
  # and may not exist yet when the build returns. Wait for it to publish its pid
  # before exiting, or the post-build scan races it and the run refuses without
  # naming that pid - an observed ~1-in-5 flake. This does NOT weaken the
  # assertion: the descendant still detaches, still ignores TERM, and detection
  # still has to find it uncooperatively. Do not delete this wait to "fix" a
  # failure here - a flaky test in this suite is what previously invited a
  # revert of the feature instead of a fix to the timing assumption.
  BUILD_CMD="mkdir -p build; cp README.md build/app.txt; '$helper' '$escaped_pid_file'; while [ ! -s '$escaped_pid_file' ]; do sleep 0.05; done; exit 0"
  run_verify demo-ship --promise "$PROMISE"
  expect_code 1 "$VERIFY_RC" "a descriptor-closing daemon must fail closed (got: $VERIFY_OUT)"
  [ -s "$escaped_pid_file" ] || fail "the descriptor-closing descendant did not publish its pid"
  escaped_pid=$(cat "$escaped_pid_file")
  assert_contains "$VERIFY_OUT" "lineage continuity was lost" \
    "the refusal must identify the lost lineage boundary"
  retained_pids=$(awk -F= '$1 == "build_cleanup_pids" { print $2 }' "$FIX_HOME/state/demo-ship-verify.verify")
  assert_contains "$retained_pids" "$escaped_pid" \
    "the retained binding must identify the unaccounted descendant"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "lost lineage must stop before verifier spawn"
  worktree=$(awk -F= '$1 == "build_cleanup_path" { print substr($0, index($0, "=") + 1) }' "$FIX_HOME/state/demo-ship-verify.verify")
  container=$(awk -F= '$1 == "build_cleanup_container" { print substr($0, index($0, "=") + 1) }' "$FIX_HOME/state/demo-ship-verify.verify")
  kill -KILL "$escaped_pid" 2>/dev/null || true
  git -C "$FIX_PROJ" worktree remove --force "$worktree" >/dev/null 2>&1 || true
  /bin/rm -rf "$container"
  pass "fm-verify: descriptor-closing descendants fail closed"
}

test_worktree_allocation_failure_is_not_a_product_verdict() {
  local fakebin
  new_fixture worktree-allocation-failure
  fakebin="$FIX_TMP/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" worktree add "*) echo "simulated allocation failure" >&2; exit 73 ;;
esac
exec "$REAL_GIT_VERIFY" "$@"
SH
  chmod +x "$fakebin/git"
  VERIFY_OUT=$(PATH="$fakebin:$PATH" TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" \
    FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify \
    --promise "$PROMISE" --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  expect_code 1 "$VERIFY_RC" "worktree allocation failure must be an orchestration error"
  assert_contains "$VERIFY_OUT" "could not create detached build worktree" \
    "the error must identify failed worktree allocation"
  assert_absent "$FIX_HOME/data/demo-ship-verify/report.md" \
    "worktree allocation failure must not write a product verdict"
  assert_absent "$FIX_HOME/state/demo-ship-verify.status" \
    "worktree allocation failure must not write a delivered-state record"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "worktree allocation failure must not spawn a verifier"
  pass "fm-verify: reports worktree allocation failures without blaming the product"
}

test_unconfirmed_worktree_cleanup_fails_closed() {
  local fakebin
  new_fixture worktree-cleanup-failure
  fakebin="$FIX_TMP/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" worktree remove --force "*) echo "simulated remove failure" >&2; exit 74 ;;
  *" worktree prune "*) echo "simulated prune failure" >&2; exit 75 ;;
esac
exec "$REAL_GIT_VERIFY" "$@"
SH
  chmod +x "$fakebin/git"
  VERIFY_OUT=$(PATH="$fakebin:$PATH" TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" \
    FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify \
    --promise "$PROMISE" --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  expect_code 1 "$VERIFY_RC" "unconfirmed worktree cleanup must fail closed"
  assert_contains "$VERIFY_OUT" "cleanup could not be confirmed" \
    "the error must name the exact cleanup confirmation failure"
  assert_absent "$FIX_HOME/data/demo-ship-verify/report.md" \
    "cleanup infrastructure failure must not write a product verdict"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "unconfirmed cleanup must stop before verifier spawn"
  pass "fm-verify: unconfirmed detached-worktree cleanup fails closed"
}

test_unconfirmed_build_container_cleanup_is_durable() {
  local fakebin container retry_out retry_rc
  new_fixture build-container-cleanup-failure
  fakebin="$FIX_TMP/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */fm-verify-build.*)
      [ -d "$arg" ] && exit 76
      ;;
  esac
done
exec /bin/rm "$@"
SH
  chmod +x "$fakebin/rm"
  VERIFY_OUT=$(PATH="$fakebin:$PATH" TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" \
    FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify \
    --promise "$PROMISE" --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  expect_code 1 "$VERIFY_RC" "an unconfirmed build-container cleanup must fail closed"
  container=$(awk -F= '$1 == "build_cleanup_container" { print substr($0, index($0, "=") + 1) }' \
    "$FIX_HOME/state/demo-ship-verify.verify")
  [ -d "$container" ] || fail "the retained build container was not recorded exactly"
  assert_contains "$VERIFY_OUT" "$container" \
    "the cleanup refusal must name the retained build container"
  retry_out=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  retry_rc=$?
  expect_code 1 "$retry_rc" "a retained build container must block retry"
  assert_contains "$retry_out" "$container" \
    "the retry refusal must name the unreconciled container"
  /bin/rm -rf "$container"
  pass "fm-verify: unconfirmed build-container cleanup remains reconcilable"
}

test_partial_add_cleanup_matches_canonical_path() {
  local fakebin alias_tmp
  new_fixture partial-add-path-alias
  fakebin="$FIX_TMP/fakebin"
  alias_tmp="$TMP_ROOT/partial-add-path-alias/tmp-alias"
  mkdir -p "$fakebin"
  ln -s "$FIX_TMP" "$alias_tmp"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" worktree add "*)
    "$REAL_GIT_VERIFY" "$@" || exit $?
    target=
    for arg in "$@"; do
      case "$arg" in */worktree) target=$arg ;; esac
    done
    "$REAL_GIT_VERIFY" -C "$2" worktree lock "$target" || exit $?
    /bin/rm -rf "$target"
    exit 73
    ;;
esac
exec "$REAL_GIT_VERIFY" "$@"
SH
  chmod +x "$fakebin/git"
  VERIFY_OUT=$(PATH="$fakebin:$PATH" TMPDIR="$alias_tmp" FM_HOME="$FIX_HOME" \
    FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify \
    --promise "$PROMISE" --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  expect_code 1 "$VERIFY_RC" "a locked partial-add record under a path alias must fail closed"
  assert_contains "$VERIFY_OUT" "cleanup could not be confirmed" \
    "canonical cleanup must identify the surviving worktree record"
  assert_absent "$FIX_HOME/data/demo-ship-verify/report.md" \
    "partial-add cleanup failure must not write a product verdict"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "partial-add cleanup failure must stop before verifier spawn"
  pass "fm-verify: partial-add cleanup matches canonical worktree paths"
}

test_signal_terminated_build_is_a_product_failure() {
  new_fixture signaled-build
  VERIFY_OUT=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd 'mkdir -p build && cp README.md build/app.txt && kill -TERM $$' \
    --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  expect_code 0 "$VERIFY_RC" "a signal-terminated build is a product result after the build ran"
  assert_contains "$VERIFY_OUT" "not delivered - does not build" \
    "a signal-terminated build must not be mistaken for success"
  assert_grep 'not delivered' "$FIX_HOME/data/demo-ship-verify/report.md" \
    "the signal-terminated build result must be durable"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "a verifier must not spawn after a signal-terminated build"
  pass "fm-verify: treats signal-terminated builds as failed builds"
}

test_interrupt_cleans_an_unpublished_reservation() {
  local entered out pid rc
  new_fixture interrupted-build
  entered="$FIX_TMP/build-entered"
  out="$FIX_TMP/interrupted.out"
  TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd "touch '$entered'; while :; do sleep 1; done" --artifact "$BUILD_ARTIFACT" \
    > "$out" 2>&1 &
  pid=$!
  wait_for_marker -e "$entered" || true
  [ -e "$entered" ] || { kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "interrupted build never started"; }
  kill -TERM "$pid"
  wait "$pid"; rc=$?
  [ "$rc" -ne 0 ] || fail "an interrupted verification must exit non-zero"
  assert_absent "$FIX_HOME/state/demo-ship-verify.verify" \
    "an interrupt before metadata publication must remove the reservation"
  assert_absent "$FIX_HOME/data/demo-ship-verify/brief.md" \
    "an interrupt before metadata publication must remove any generated brief"
  pass "fm-verify: interruption cleans unpublished artifacts and reservations"
}

test_interrupt_with_unconfirmed_drain_retains_build_worktree() {
  local helper fake_ps target_pid snapshot worktree_file out pid rc worktree retained_pids
  new_fixture interrupt-undrained-build
  helper="$FIX_TMP/escape-descendant.pl"
  fake_ps="$FIX_TMP/fake-ps"
  target_pid="$FIX_TMP/escaped.pid"
  snapshot="$FIX_TMP/escaped.ps"
  worktree_file="$FIX_TMP/build-worktree"
  out="$FIX_TMP/interrupted.out"
  cat > "$helper" <<'PL'
#!/usr/bin/env perl
use POSIX qw(setsid);
setsid() or die "setsid: $!";
open my $pid_file, '>', $ARGV[0] or die "pid file: $!";
print {$pid_file} "$$\n";
close $pid_file;
$SIG{TERM} = 'IGNORE';
sleep 1 while 1;
PL
  chmod +x "$helper"
  cat > "$fake_ps" <<'SH'
#!/usr/bin/env bash
output=$(/bin/ps "$@") || exit $?
printf '%s\n' "$output"
if [ -s "$FM_VERIFY_TEST_TARGET_PID" ]; then
  target=$(cat "$FM_VERIFY_TEST_TARGET_PID")
  line=$(printf '%s\n' "$output" | awk -v pid="$target" '$1 == pid { print; exit }')
  if [ -n "$line" ]; then
    printf '%s\n' "$line" > "$FM_VERIFY_TEST_PS_SNAPSHOT"
  elif [ -s "$FM_VERIFY_TEST_PS_SNAPSHOT" ]; then
    cat "$FM_VERIFY_TEST_PS_SNAPSHOT"
  fi
fi
SH
  chmod +x "$fake_ps"
  TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    FM_VERIFY_PS_OVERRIDE="$fake_ps" FM_VERIFY_TEST_TARGET_PID="$target_pid" \
    FM_VERIFY_TEST_PS_SNAPSHOT="$snapshot" "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify \
    --promise "$PROMISE" \
    --build-cmd "pwd > '$worktree_file'; '$helper' '$target_pid' & while :; do sleep 1; done" \
    --artifact "$BUILD_ARTIFACT" > "$out" 2>&1 &
  pid=$!
  wait_for_marker -s "$snapshot" || true
  [ -s "$snapshot" ] || { kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "runner never observed the escaped descendant"; }
  kill -TERM "$pid"
  wait "$pid"; rc=$?
  [ "$rc" -ne 0 ] || fail "an interrupt with unconfirmed drain must exit non-zero"
  worktree=$(cat "$worktree_file")
  [ -d "$worktree" ] || fail "unconfirmed drain removed the live build worktree"
  assert_contains "$(cat "$out")" "$worktree" \
    "the drain refusal must report the exact retained worktree"
  retained_pids=$(awk -F= '$1 == "build_cleanup_pids" { print $2 }' "$FIX_HOME/state/demo-ship-verify.verify")
  assert_contains "$retained_pids" "$(cat "$target_pid")" \
    "the durable binding must identify the surviving descendant"
  pass "fm-verify: unconfirmed interrupt drain retains a reconcilable worktree"
}

test_failed_unpublished_neutral_removal_retains_binding() {
  local fakebin neutral
  new_fixture unpublished-neutral-removal-failure
  new_fake_spawn "$TMP_ROOT/unpublished-neutral-removal-failure" 71
  fakebin="$FIX_TMP/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    */fm-verify-artifacts.*) exit 73 ;;
  esac
done
exec /bin/rm "\$@"
SH
  chmod +x "$fakebin/rm"
  VERIFY_OUT=$(PATH="$fakebin:$PATH" TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" \
    FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify \
    --promise "$PROMISE" --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  expect_code 1 "$VERIFY_RC" "failed neutral cleanup must fail closed"
  neutral=$(awk '{for (i=1;i<=NF;i++) if ($i=="--neutral-dir") print $(i+1)}' "$FIX_SPAWN_LOG")
  [ -d "$neutral" ] || fail "the failed-removal fixture did not retain the neutral directory"
  assert_present "$FIX_HOME/state/demo-ship-verify.verify" \
    "failed neutral removal erased the verifier binding"
  assert_present "$FIX_HOME/data/demo-ship-verify/brief.md" \
    "failed neutral removal erased the verifier brief"
  assert_contains "$VERIFY_OUT" "$neutral" \
    "failed neutral removal did not report the exact retained path"
  pass "fm-verify: failed neutral cleanup retains reconciliation records"
}

test_early_neutral_cleanup_failure_is_durable_and_blocks_retry() {
  local fakebin neutral identity retry_out retry_rc
  new_fixture early-neutral-removal-failure
  fakebin="$FIX_TMP/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */fm-verify-artifacts.*) exit 73 ;;
  esac
done
exec /bin/rm "$@"
SH
  chmod +x "$fakebin/rm"
  VERIFY_OUT=$(PATH="$fakebin:$PATH" TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" \
    FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify \
    --promise "$PROMISE" \
    --build-cmd "mkdir -p build/App && ln -s '$FIX_PROJ/README.md' build/App/source-link" \
    --artifact build/App 2>&1)
  VERIFY_RC=$?
  expect_code 1 "$VERIFY_RC" "an early neutral cleanup failure must fail closed"
  assert_absent "$FIX_HOME/data/demo-ship-verify/brief.md" \
    "the early isolation refusal fixture must fail before brief creation"
  assert_absent "$FIX_HOME/state/demo-ship-verify.meta" \
    "the early isolation refusal fixture must fail before metadata publication"
  neutral=$(awk -F= '$1 == "neutral_cleanup_path" { print substr($0, index($0, "=") + 1) }' \
    "$FIX_HOME/state/demo-ship-verify.verify")
  identity=$(awk -F= '$1 == "neutral_cleanup_identity" { print $2 }' \
    "$FIX_HOME/state/demo-ship-verify.verify")
  [ -d "$neutral" ] || fail "the durable binding did not identify the retained neutral directory"
  [ -n "$identity" ] || fail "the durable binding did not retain the neutral directory identity"
  retry_out=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  retry_rc=$?
  expect_code 1 "$retry_rc" "a retry must refuse an unreconciled neutral directory"
  assert_contains "$retry_out" "$neutral" \
    "the retry refusal must name the exact unreconciled neutral directory"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "an unreconciled neutral directory must block retry before spawn"
  pass "fm-verify: early neutral cleanup ownership survives and blocks retry"
}

test_interrupted_neutral_publication_is_durable_and_blocks_retry() {
  local fakebin entered release neutral out pid rc identity retry_out retry_rc
  new_fixture interrupted-neutral-publication
  fakebin="$FIX_TMP/fakebin"
  entered="$FIX_TMP/neutral-created"
  release="$FIX_TMP/release-neutral"
  neutral="$FIX_TMP/interrupted-neutral"
  out="$FIX_TMP/interrupted-neutral.out"
  mkdir -p "$fakebin"
  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *fm-verify-artifacts.*)
    mkdir -p "$FM_VERIFY_TEST_NEUTRAL"
    : > "$FM_VERIFY_TEST_ENTERED"
    while [ ! -e "$FM_VERIFY_TEST_RELEASE" ]; do sleep 0.01; done
    printf '%s\n' "$FM_VERIFY_TEST_NEUTRAL"
    exit 0
    ;;
esac
exec "$REAL_MKTEMP_VERIFY" "$@"
SH
  chmod +x "$fakebin/mktemp"
  PATH="$fakebin:$PATH" TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" \
    FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" FM_VERIFY_TEST_NEUTRAL="$neutral" \
    FM_VERIFY_TEST_ENTERED="$entered" FM_VERIFY_TEST_RELEASE="$release" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" > "$out" 2>&1 &
  pid=$!
  wait_for_marker -e "$entered" || true
  [ -e "$entered" ] || { kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "neutral allocation did not reach the publication window"; }
  kill -TERM "$pid"
  touch "$release"
  wait "$pid"; rc=$?
  [ "$rc" -ne 0 ] || fail "an interrupted neutral publication must exit non-zero"
  [ -d "$neutral" ] || fail "the interrupted neutral directory was not retained"
  assert_grep "neutral_cleanup_path=$neutral" "$FIX_HOME/state/demo-ship-verify.verify" \
    "the interrupted allocation must retain its exact cleanup path"
  identity=$(awk -F= '$1 == "neutral_cleanup_identity" { print $2 }' \
    "$FIX_HOME/state/demo-ship-verify.verify")
  [ -n "$identity" ] || fail "the interrupted allocation did not retain its filesystem identity"
  retry_out=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  retry_rc=$?
  expect_code 1 "$retry_rc" "a retry must refuse the interrupted neutral allocation"
  assert_contains "$retry_out" "$neutral" \
    "the retry refusal must name the retained neutral directory"
  pass "fm-verify: interrupted neutral publication remains reconcilable"
}

test_retry_refuses_live_recorded_build_survivors() {
  local survivor retry_out retry_rc
  new_fixture live-recorded-survivor
  sleep 30 &
  survivor=$!
  fm_write_meta "$FIX_HOME/state/demo-ship-verify.verify" \
    "verifies=demo-ship" "build_cleanup_path=$FIX_TMP/removed-worktree" \
    "build_cleanup_pids=$survivor" "marker=retained"
  retry_out=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  retry_rc=$?
  kill -TERM "$survivor" 2>/dev/null || true
  wait "$survivor" 2>/dev/null || true
  expect_code 1 "$retry_rc" "a retry must refuse while a recorded survivor remains alive"
  assert_contains "$retry_out" "$survivor" \
    "the retry refusal must identify the live recorded process"
  assert_grep 'marker=retained' "$FIX_HOME/state/demo-ship-verify.verify" \
    "the retry must not overwrite retained process ownership"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "a live retained process must block retry before spawn"
  pass "fm-verify: live retained build processes block retry"
}

test_dry_run_changes_nothing() {
  new_fixture dry-run
  run_verify demo-ship --promise "$PROMISE" --dry-run
  expect_code 0 "$VERIFY_RC" "a dry run must succeed (got: $VERIFY_OUT)"
  assert_contains "$VERIFY_OUT" "--scout" "a dry run must show the spawn it would perform"
  assert_contains "$VERIFY_OUT" "nothing was written" "a dry run must say it wrote nothing"
  assert_absent "$FIX_HOME/data/demo-ship-verify" "a dry run must not scaffold a brief"
  assert_absent "$FIX_HOME/state/demo-ship-verify.verify" "a dry run must not bind a verification"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "a dry run must not spawn"
  pass "fm-verify: --dry-run reports the plan and writes nothing"
}

test_dispatch_flags_reach_the_spawn() {
  local args
  new_fixture passthrough
  run_verify demo-ship --promise "$PROMISE" --harness claude --effort high --model opus-5
  expect_code 0 "$VERIFY_RC" "a verification with dispatch flags must spawn (got: $VERIFY_OUT)"
  args=$(cat "$FIX_SPAWN_LOG")
  assert_contains "$args" "--harness claude" "the resolved harness must reach the spawn"
  assert_contains "$args" "--effort high" "the resolved effort must reach the spawn"
  assert_contains "$args" "--model opus-5" "the resolved model must reach the spawn"
  pass "fm-verify: dispatch profile flags pass through to the spawn unchanged"
}

test_unfinished_task_is_flagged_but_allowed() {
  new_fixture unfinished
  printf 'working: still building\n' > "$FIX_HOME/state/demo-ship.status"
  run_verify demo-ship --promise "$PROMISE"
  expect_code 0 "$VERIFY_RC" "verifying an unfinished task stays firstmate's judgement"
  assert_contains "$VERIFY_OUT" "has not reported done" \
    "verifying a task that has not finished must be warned about"
  pass "fm-verify: warns when the change may still move, without taking the decision"
}

test_script_parses
test_help_states_the_contract
test_promise_is_mandatory
test_build_configuration_is_mandatory
test_promise_must_be_singular_and_non_empty
test_refuses_what_cannot_be_verified
test_refuses_when_the_revision_cannot_be_resolved
test_spawns_a_scout_in_a_neutral_artifact_directory
test_verifier_is_handed_artifacts_not_source
test_explicit_revision_overrides_the_branch
test_binds_the_verdict_to_the_task_it_gates
test_duplicate_verification_is_refused
test_capacity_defers_and_never_skips
test_capacity_ignores_finished_verifications
test_capacity_counts_a_pre_spawn_reservation
test_concurrent_admission_keeps_one_available_slot
test_concurrent_same_id_reservation_is_exclusive
test_default_id_rolls_forward_with_the_revision
test_spawn_failure_with_unknown_endpoint_retains_artifacts
test_uncertain_endpoint_holds_capacity
test_existing_report_refuses_id_reuse
test_partial_spawn_retains_reconciliation_artifacts
test_spawn_handoff_persistence_failure_is_reported
test_build_failure_is_a_result_without_a_spawn
test_artifact_path_cannot_escape_through_a_symlinked_parent
test_artifact_descendant_symlink_must_stay_neutral
test_artifact_internal_symlink_is_preserved
test_cross_artifact_internal_symlink_is_preserved
test_unusable_build_runner_is_not_a_product_verdict
test_build_timeout_is_not_a_product_verdict
test_build_cannot_forge_runner_status
test_build_descendants_are_drained_before_staging
test_build_descendant_escaping_its_process_group_fails_closed
test_build_descendant_closing_lineage_fails_closed
test_worktree_allocation_failure_is_not_a_product_verdict
test_unconfirmed_worktree_cleanup_fails_closed
test_unconfirmed_build_container_cleanup_is_durable
test_partial_add_cleanup_matches_canonical_path
test_signal_terminated_build_is_a_product_failure
test_interrupt_cleans_an_unpublished_reservation
test_interrupt_with_unconfirmed_drain_retains_build_worktree
test_failed_unpublished_neutral_removal_retains_binding
test_early_neutral_cleanup_failure_is_durable_and_blocks_retry
test_interrupted_neutral_publication_is_durable_and_blocks_retry
test_retry_refuses_live_recorded_build_survivors
test_dry_run_changes_nothing
test_dispatch_flags_reach_the_spawn
test_unfinished_task_is_flagged_but_allowed
