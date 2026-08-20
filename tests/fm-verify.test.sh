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

# release_retained_build_state: read what a run that failed closed durably
# retained - the surviving pids, the build worktree and its container - release
# the worktree and the container, and echo the pids to the caller.
#
# The ordering is the contract, not a convenience each caller re-invents: a run
# that refuses keeps that state on the host ON PURPOSE, so a test driving one
# must read the binding and release both BEFORE its first assertion. An
# assertion that fails ends the test immediately, and anything not released by
# then is left behind on the machine running the suite. Call this straight after
# the run, and assert only afterwards - including on the retained pids it
# returns, which are still readable after the release.
release_retained_build_state() {
  local binding=$FIX_HOME/state/demo-ship-verify.verify retained worktree container
  retained=$(awk -F= '$1 == "build_cleanup_pids" { print $2 }' "$binding")
  worktree=$(awk -F= '$1 == "build_cleanup_path" { print substr($0, index($0, "=") + 1) }' "$binding")
  container=$(awk -F= '$1 == "build_cleanup_container" { print substr($0, index($0, "=") + 1) }' "$binding")
  [ -z "$worktree" ] || git -C "$FIX_PROJ" worktree remove --force "$worktree" >/dev/null 2>&1 || true
  [ -z "$container" ] || /bin/rm -rf "$container"
  printf '%s\n' "$retained"
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

# A build that exits 0 and leaves no artifact is indistinguishable from a
# mistyped or stale --artifact, so fm-verify must not decide which it was. A
# product verdict here would blame the product for the operator's typo and, with
# the deterministic <ship-id>-verify-<rev> id, the durable report would then
# refuse the very retry that fixes it.
test_missing_artifact_after_a_clean_build_is_not_a_product_verdict() {
  new_fixture artifact-missing
  VERIFY_OUT=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd 'exit 0' --artifact build/mistyped.txt 2>&1)
  VERIFY_RC=$?
  expect_code 1 "$VERIFY_RC" \
    "an absent configured artifact is an orchestration failure, not a verification result"
  assert_contains "$VERIFY_OUT" "BLOCKED" "the failure must be reported as blocked"
  assert_contains "$VERIFY_OUT" "build/mistyped.txt" "the failure must name the configured artifact"
  assert_not_contains "$VERIFY_OUT" "not delivered" \
    "machinery must not speak for the product when the artifact path may simply be wrong"
  assert_absent "$FIX_HOME/data/demo-ship-verify/report.md" \
    "an absent artifact must not write a durable product report"
  assert_absent "$FIX_HOME/state/demo-ship-verify.status" \
    "an absent artifact must not write a product status line"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "no verifier may spawn without a runnable artifact"
  pass "fm-verify: an absent configured artifact reports blocked and records no verdict"
}

# install_divergent_stat_host <dir>: PATH shims reproducing the one host shape
# where an OS-branched identity reader silently stops working - a macOS box with
# GNU coreutils ahead of /usr/bin/stat. Two facts must hold at once, which is why
# both shims exist: `uname` says Darwin, so a reader that branches on the OS
# picks the BSD spelling, while the `stat` it actually reaches is GNU, where -f
# is --file-system and a BSD-style `stat -f %i <path>` degrades into a failed
# stat of a file literally named "%i". -c is the format flag and works.
#
# Stubbing the stat flavor ALONE proves nothing on Linux, which is the only OS
# that runs this suite in CI: there `uname` already reports Linux, so every
# reader takes the -c branch and a branched helper agrees with the shared one
# whether or not the bug is present. The uname shim is what makes these tests
# assert anything where they actually run.
#
# Scope note: BSD-format reads this fixture is not about - mode, link count,
# mtime - are answered rather than left to fail, so these tests can only redden
# for the identity question. A real such host exposes those readers too; that is
# a pre-existing property of fm-pr-lib and fm-lock-lib, untouched here.
install_divergent_stat_host() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/uname" <<'SH'
#!/usr/bin/env bash
# Bare `uname` is the only form the fleet libraries use to pick a stat spelling.
[ "$#" -eq 0 ] && { printf 'Darwin\n'; exit 0; }
for real in /usr/bin/uname /bin/uname; do
  [ -x "$real" ] && exec "$real" "$@"
done
exit 127
SH
  chmod +x "$dir/uname"
  cat > "$dir/stat" <<'SH'
#!/usr/bin/env bash
set -u
REAL_STAT=/usr/bin/stat
host_field() {  # <field-format> <path>: %d and %i spell the same in both flavors
  "$REAL_STAT" -c "$1" "$2" 2>/dev/null || "$REAL_STAT" -f "$1" "$2" 2>/dev/null
}
either() {  # <gnu-format> <bsd-format> <path>
  "$REAL_STAT" -c "$1" "$3" 2>/dev/null || "$REAL_STAT" -f "$2" "$3" 2>/dev/null
}
case "${1:-}" in
  -f)
    case "${2:-}" in
      %d|%i|'%d:%i')
        printf "stat: cannot stat '%s': No such file or directory\n" "$2" >&2
        exit 1
        ;;
      %m)  [ -e "${3:-}" ] && either %Y %m "$3" && exit 0; exit 1 ;;
      %Lp) [ -e "${3:-}" ] && either %a %Lp "$3" && exit 0; exit 1 ;;
      %l)  [ -e "${3:-}" ] && either %h %l "$3" && exit 0; exit 1 ;;
    esac
    ;;
  -c)
    case "${2:-}" in
      %d|%i|'%d:%i')
        [ -e "${3:-}" ] || {
          printf "stat: cannot stat '%s': No such file or directory\n" "${3:-}" >&2
          exit 1
        }
        device=$(host_field %d "$3")
        inode=$(host_field %i "$3")
        [ -n "$device" ] && [ -n "$inode" ] || exit 1
        rendered=${2//%d/$device}
        printf '%s\n' "${rendered//%i/$inode}"
        exit 0
        ;;
    esac
    ;;
esac
exec "$REAL_STAT" "$@"
SH
  chmod +x "$dir/stat"
}

# The neutral directory identity is written by fm-verify and re-checked by
# fm-spawn at launch and fm-teardown at cleanup. If the producer and the
# consumers reach it through different stat flavors, the two strings disagree on
# any box where those flavors disagree, and every neutral launch and every
# neutral cleanup refuses with a misleading "does not match its verifier
# ownership binding". One shared helper is the only thing that makes the
# comparison meaningful, so this drives the whole path through a stat that
# behaves like GNU coreutils rather than trusting the host's flavors to agree.
test_neutral_identity_comes_from_one_shared_helper() {
  local stub_bin binding neutral expected out rc
  new_fixture shared-identity
  stub_bin="$TMP_ROOT/shared-identity/stubbin"
  install_divergent_stat_host "$stub_bin"

  VERIFY_OUT=$(PATH="$stub_bin:$PATH" TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" \
    FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  expect_code 0 "$VERIFY_RC" \
    "a verification must bind its neutral directory through the shared identity helper (got: $VERIFY_OUT)"

  binding="$FIX_HOME/state/demo-ship-verify.verify"
  assert_present "$binding" "the verification binding must exist"
  neutral=$(awk -F= '/^neutral_cleanup_path=/ { print substr($0, index($0, "=") + 1) }' "$binding")
  [ -n "$neutral" ] || fail "the binding recorded no neutral directory path"

  # This is what every consumer computes: fm-spawn records it as neutral_identity
  # and fm-teardown compares it against the binding.
  expected=$(PATH="$stub_bin:$PATH" bash -c \
    'set -eu; . "$1/bin/fm-neutral-dir-lib.sh"; fm_neutral_filesystem_identity "$2"' \
    fm-identity "$ROOT" "$neutral") \
    || fail "the shared helper could not read the neutral directory identity"

  out=$(PATH="$stub_bin:$PATH" bash -c \
    'set -eu; . "$1/bin/fm-neutral-dir-lib.sh"; fm_neutral_directory_is_authorized "$2" "$3" "$4" "$5"' \
    fm-identity "$ROOT" "$neutral" "$expected" "$binding" "$FIX_PROJ" 2>&1)
  rc=$?
  expect_code 0 "$rc" \
    "the recorded and expected identities must agree, or neutral cleanup is dead on this box (got: $out)"

  rm -rf "$neutral"
  pass "fm-verify: the neutral identity is produced and consumed by one shared helper"
}

# The verifier binding's filesystem identity is read once when a retained
# binding is taken over, and read again under the capacity lock to prove no
# other process swapped the file in between. An OS-branched reader returns
# nothing at all on the host above, so the takeover refuses a binding sitting
# right there, reporting that its identity cannot be read - a permanent stall on
# a retry that should simply proceed, and one that no amount of reconciling the
# named artifacts can clear. Both reads go through the shared helper.
test_sidecar_identity_survives_a_divergent_stat_host() {
  local stub_bin sidecar
  new_fixture sidecar-identity
  stub_bin="$TMP_ROOT/sidecar-identity/stubbin"
  install_divergent_stat_host "$stub_bin"

  # A retained binding with nothing left to reconcile: exactly what a previous
  # verification leaves behind once its neutral directory, build worktree,
  # container, and processes are all gone. Taking it over reads its identity.
  sidecar="$FIX_HOME/state/demo-ship-verify.verify"
  printf 'verifies=demo-ship\n' > "$sidecar"

  VERIFY_OUT=$(PATH="$stub_bin:$PATH" TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" \
    FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  case "$VERIFY_OUT" in
    *'binding identity cannot be read'*)
      fail "the takeover refused a binding it can plainly see: $VERIFY_OUT" ;;
  esac
  expect_code 0 "$VERIFY_RC" \
    "taking over a retained binding must read its identity through the shared helper (got: $VERIFY_OUT)"
  assert_grep 'rev=' "$sidecar" "the taken-over binding must be rewritten for this verification"
  pass "fm-verify: a retained binding is taken over where the stat flavor and uname disagree"
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

# The build runner gates itself on seeing its own freshly forked leader in the
# process table before releasing it to exec. That leader provably exists at that
# point, but a `ps` snapshot is a SAMPLE, not an instantaneous truth: on a loaded
# host one sample can omit a live process. The runner used to take exactly one
# sample and treat a miss as fatal, which turned that sampling artifact into
# "BLOCKED: ... readiness-leader-missing" - a false orchestration failure that
# aborted real verifications on CI and landed on whichever test lost the race.
# The fake ps here drops the leader from the FIRST snapshot only, which is
# precisely that transient, and pins that the runner re-observes rather than
# blaming the product. Do not relax this into "the first sample must be right".
test_transient_process_table_miss_is_re_observed() {
  local fake_ps counter calls
  new_fixture readiness-transient-miss
  fake_ps="$FIX_TMP/fake-ps"
  counter="$FIX_TMP/ps-calls"
  : > "$counter"
  cat > "$fake_ps" <<'SH'
#!/usr/bin/env bash
# First call answers with a table that cannot contain the caller's leader, so
# the runner sees the exact transient a loaded host produces. Later calls are
# the real table, so the leader becomes observable and the build proceeds.
printf 'x\n' >> "$FM_VERIFY_TEST_PS_COUNTER"
if [ "$(wc -l < "$FM_VERIFY_TEST_PS_COUNTER")" -le 1 ]; then
  /bin/ps -o pid=,ppid=,pgid=,uid=,state=,etime=,lstart= -p 1 2>/dev/null
  exit 0
fi
exec /bin/ps "$@"
SH
  chmod +x "$fake_ps"
  VERIFY_OUT=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    FM_VERIFY_PS_OVERRIDE="$fake_ps" FM_VERIFY_TEST_PS_COUNTER="$counter" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  case "$VERIFY_OUT" in
    *readiness-leader-missing*)
      fail "one missed process-table sample still blocked the build (got: $VERIFY_OUT)" ;;
  esac
  expect_code 0 "$VERIFY_RC" \
    "a transient process-table miss must not fail the verification (got: $VERIFY_OUT)"
  calls=$(wc -l < "$counter" | tr -d ' ')
  [ "$calls" -ge 2 ] || fail "the runner never re-observed the process table (ps calls: $calls)"
  [ -s "$FIX_SPAWN_LOG" ] || fail "a recovered readiness observation must still reach the verifier spawn"
  pass "fm-verify: a transient process-table miss is re-observed, not blamed on the product"
}

# A leader that never becomes observable is a real orchestration failure, not a
# transient. The bounded re-observation above must not turn this into a hang or,
# worse, into a build that proceeds on tracking it cannot trust.
test_permanently_unobservable_leader_still_refuses() {
  local fake_ps out pid watchdog
  new_fixture readiness-never-observable
  fake_ps="$FIX_TMP/fake-ps"
  out="$FIX_TMP/never-observable.out"
  cat > "$fake_ps" <<'SH'
#!/usr/bin/env bash
# Never reports anything but pid 1, so the leader is never observable.
/bin/ps -o pid=,ppid=,pgid=,uid=,state=,etime=,lstart= -p 1 2>/dev/null
exit 0
SH
  chmod +x "$fake_ps"
  TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    FM_VERIFY_PS_OVERRIDE="$fake_ps" FM_VERIFY_READINESS_POLLS=3 \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" > "$out" 2>&1 &
  pid=$!
  # Watchdogged deliberately. Giving up here used to block forever in waitpid on
  # a leader that was itself waiting for a readiness byte, so the regression this
  # pins is a HANG. Without the bound it would eat the whole CI job and read as
  # an infrastructure problem; with it, the regression fails in seconds and says
  # what it was.
  ( sleep 60; kill -KILL "$pid" 2>/dev/null ) &
  watchdog=$!
  wait "$pid"; VERIFY_RC=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  [ "$VERIFY_RC" -ne 137 ] || \
    fail "an unobservable build leader hung the runner instead of refusing"
  VERIFY_OUT=$(cat "$out")
  expect_code 1 "$VERIFY_RC" "an unobservable build leader must remain an orchestration failure"
  assert_contains "$VERIFY_OUT" "readiness-leader-missing" \
    "the refusal must still name the unobservable leader"
  assert_absent "$FIX_HOME/data/demo-ship-verify/report.md" \
    "an unobservable leader must not write a product verdict"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "an unobservable leader must stop before verifier spawn"
  pass "fm-verify: a leader that never becomes observable still refuses"
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

test_build_descendant_left_alive_after_drain_fails_closed() {
  local BUILD_CMD helper leak_pid_file leak_pid leak_alive retained_pids
  new_fixture leaked-build-descendant
  helper="$FIX_TMP/leak-descendant.pl"
  leak_pid_file="$FIX_TMP/leaked.pid"
  # The leak the containment gate exists for: a process still running on the host
  # after the build is over. The daemon detaches into its own process group and
  # keeps the lineage descriptor, so the runner does observe that group. It then
  # orphans a second process INTO the same group through a transient middle
  # process, and that one closes every descriptor and moves its working directory
  # outside the build root - so per-pid tracking, the lineage scan and the
  # unaccounted-lineage scan all lose it. Its process group is the only remaining
  # thread back to the build, and the drain cannot reach it.
  cat > "$helper" <<'PL'
#!/usr/bin/env perl
use POSIX qw(setsid);
defined(my $detached = fork) or die "detach fork: $!";
exit 0 if $detached;
setsid() or die "setsid: $!";
defined(my $middle = fork) or die "middle fork: $!";
if (!$middle) {
  defined(my $leak = fork) or die "leak fork: $!";
  exit 0 if $leak;
  chdir '/' or die "chdir: $!";
  open my $pid_file, '>', $ARGV[0] or die "pid file: $!";
  print {$pid_file} "$$\n";
  close $pid_file;
  for my $fd (0 .. 255) { POSIX::close($fd); }
  $SIG{TERM} = 'IGNORE';
  sleep 1 while 1;
}
waitpid($middle, 0);
$SIG{TERM} = 'IGNORE';
sleep 1 while 1;
PL
  chmod +x "$helper"
  # Wait for the leaked pid to be published before the build returns, for the same
  # reason the sibling tests do: the process is created asynchronously and the
  # post-build scan would otherwise race it. This does NOT weaken the assertion -
  # the process still detaches, still ignores TERM, and detection still has to
  # find it with nothing but its process group.
  BUILD_CMD="mkdir -p build; cp README.md build/app.txt; '$helper' '$leak_pid_file' & while [ ! -s '$leak_pid_file' ]; do sleep 0.05; done; exit 0"
  run_verify demo-ship --promise "$PROMISE"
  # Record what the run left behind, then release all of it BEFORE asserting
  # anything. This test deliberately leaks a process that ignores TERM, so an
  # assertion that fails early must not be the reason it keeps running on the
  # host - see release_retained_build_state for the ordering rule.
  leak_pid=
  leak_alive=0
  if [ -s "$leak_pid_file" ]; then
    leak_pid=$(cat "$leak_pid_file")
    kill -0 "$leak_pid" 2>/dev/null && leak_alive=1
  fi
  pkill -KILL -f "$helper" 2>/dev/null || true
  [ -z "$leak_pid" ] || kill -KILL "$leak_pid" 2>/dev/null || true
  retained_pids=$(release_retained_build_state)
  expect_code 1 "$VERIFY_RC" "a descendant left alive after the drain must fail closed (got: $VERIFY_OUT)"
  [ -n "$leak_pid" ] || fail "the leaked descendant did not publish its pid"
  [ "$leak_alive" -eq 1 ] || fail "the test did not actually leak a live process"
  assert_contains "$VERIFY_OUT" "because build drain was not confirmed" \
    "a live leaked descendant must be reported as an unconfirmed drain"
  assert_contains "$retained_pids" "$leak_pid" \
    "the retained binding must name the process that is still running"
  assert_absent "$FIX_HOME/data/demo-ship-verify/report.md" \
    "a leaked descendant must not become a product verdict"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "a leaked descendant must stop artifact staging and spawn"
  pass "fm-verify: descendants left alive after the drain fail closed"
}

test_cleanly_exited_own_process_group_children_are_not_a_leak() {
  local BUILD_CMD helper
  new_fixture clean-process-group-children
  helper="$FIX_TMP/clean-process-groups.pl"
  # The other direction, and the reason this gate was rewritten: a real toolchain
  # runs plenty of work in process groups of its own and reaps all of it. Before
  # the fix the runner remembered every such child forever and refused at the end
  # on a set of processes that had already exited - on a real iOS build that was
  # hundreds of them, none alive, which blocked every iOS verification in the
  # fleet. Nothing here survives the build, so nothing here may fail it.
  cat > "$helper" <<'PL'
#!/usr/bin/env perl
use POSIX qw(setsid);
for my $round (1 .. 5) {
  defined(my $child = fork) or die "fork: $!";
  if (!$child) {
    setsid() or die "setsid: $!";
    select undef, undef, undef, 0.3;
    exit 0;
  }
  waitpid($child, 0);
}
PL
  chmod +x "$helper"
  BUILD_CMD="mkdir -p build; cp README.md build/app.txt; '$helper'; exit 0"
  run_verify demo-ship --promise "$PROMISE"
  expect_code 0 "$VERIFY_RC" "cleanly exited own-process-group children must not fail the build (got: $VERIFY_OUT)"
  [ -s "$FIX_SPAWN_LOG" ] || fail "the verification must reach the verifier spawn"
  pass "fm-verify: cleanly exited own-process-group children are not a leak"
}

# write_escaped_group_ps <path>: a ps wrapper that projects one synthetic process
# group into the view the build runner has of the process table, through the same
# FM_VERIFY_PS_OVERRIDE seam the rest of this suite uses.
#
# While the build leader is alive it shows a descendant of that leader running in
# a group of its own, which is what makes the runner remember the group. Once the
# leader is gone it shows that descendant reaped and one orphan still running in
# the same group - a process the drain never tracked and cannot reach, so the
# group number is the only thread left back to the build. The leader row it shows
# at that point decides whether the number still names the same group.
#
# Every drain-phase sample is recorded in FM_VERIFY_TEST_DRAIN_MARK, one line per
# sample, which is how a test can tell a verdict that was re-taken from one that
# was taken once. FM_VERIFY_TEST_GROUP_SAMPLES optionally retires the whole
# projected group - leader and orphan, since both are live members of it - after
# that many drain-phase samples, projecting the toolchain group that is on its
# way out while the check is looking at it; empty keeps it running for good.
#
# The projected pids are taken from above the highest number this platform can
# assign as a pid, so nothing here can ever name - and the drain can never aim a
# signal at - a real process on the host.
write_escaped_group_ps() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
output=$(/bin/ps "$@") || exit $?
printf '%s\n' "$output"
[ -s "$FM_VERIFY_TEST_LEADER" ] || exit 0
leader=$(cat "$FM_VERIFY_TEST_LEADER")
if kill -0 "$leader" 2>/dev/null; then
  printf '%s 1 %s %s S 10:00 %s\n' \
    "$FM_VERIFY_TEST_GROUP" "$FM_VERIFY_TEST_GROUP" "$FM_VERIFY_TEST_UID" "$FM_VERIFY_TEST_OBSERVED_START"
  printf '%s %s %s %s S 10:00 %s\n' \
    "$FM_VERIFY_TEST_ESCAPEE" "$leader" "$FM_VERIFY_TEST_GROUP" "$FM_VERIFY_TEST_UID" "$FM_VERIFY_TEST_OBSERVED_START"
  printf 'observed\n' >> "$FM_VERIFY_TEST_MARK"
else
  printf 'drained\n' >> "$FM_VERIFY_TEST_DRAIN_MARK"
  if [ -z "$FM_VERIFY_TEST_GROUP_SAMPLES" ] \
     || [ "$(wc -l < "$FM_VERIFY_TEST_DRAIN_MARK")" -le "$FM_VERIFY_TEST_GROUP_SAMPLES" ]; then
    printf '%s 1 %s %s S 10:00 %s\n' \
      "$FM_VERIFY_TEST_GROUP" "$FM_VERIFY_TEST_GROUP" "$FM_VERIFY_TEST_UID" "$FM_VERIFY_TEST_DRAIN_START"
    printf '%s 1 %s %s S 10:00 Tue Jan  2 00:00:00 2001\n' \
      "$FM_VERIFY_TEST_MEMBER" "$FM_VERIFY_TEST_GROUP" "$FM_VERIFY_TEST_UID"
  fi
fi
SH
  chmod +x "$1"
}

# Linux publishes its ceiling; the macOS ceiling is the fixed PID_MAX of 99999.
if [ -r /proc/sys/kernel/pid_max ]; then
  ESCAPED_GROUP_PID_BASE=$(( $(cat /proc/sys/kernel/pid_max) + 1 ))
else
  ESCAPED_GROUP_PID_BASE=100000
fi
ESCAPED_GROUP_LEADER_PID=$((ESCAPED_GROUP_PID_BASE + 1))
ESCAPED_GROUP_ESCAPEE_PID=$((ESCAPED_GROUP_PID_BASE + 2))
ESCAPED_GROUP_MEMBER_PID=$((ESCAPED_GROUP_PID_BASE + 3))
ESCAPED_GROUP_OBSERVED_START='Mon Jan  1 00:00:01 2001'
# The re-poll the runner gives a suspected escape before it calls it a leak: 20
# samples on the drain cadence. Kept in step with the budget passed to
# $settle_live_escaped in bin/fm-verify.sh, which owns the number.
ESCAPED_GROUP_SETTLE_WINDOW=20
# More drain-phase samples than a run takes to reach the check, so the projected
# group is genuinely caught alive by it, and fewer than the window is long, so it
# stops being reported while the window is still open.
ESCAPED_GROUP_SETTLE_SAMPLES=12

# run_escaped_group_fixture <slug> <drain-leader-start> [group-samples]: one
# verification whose build escapes into the projected group and leaves members
# of it behind - running for good, or for that many drain-phase samples.
# ESCAPED_GROUP_DRAIN_MARK holds one line per drain-phase sample of the run.
run_escaped_group_fixture() {
  local slug=$1 drain_start=$2 group_samples=${3:-} fake_ps leader mark
  new_fixture "$slug"
  fake_ps="$FIX_TMP/escaped-group-ps"
  leader="$FIX_TMP/build-leader.pid"
  mark="$FIX_TMP/escaped-group-observed"
  ESCAPED_GROUP_DRAIN_MARK="$FIX_TMP/escaped-group-drained"
  : > "$mark"
  : > "$ESCAPED_GROUP_DRAIN_MARK"
  write_escaped_group_ps "$fake_ps"
  # The build publishes its own pid - it is the runner's forked leader - and then
  # waits until the runner has actually sampled the process table twice with the
  # group in it, so observation is a fact of the run rather than a race with it.
  VERIFY_OUT=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    FM_VERIFY_PS_OVERRIDE="$fake_ps" \
    FM_VERIFY_TEST_LEADER="$leader" FM_VERIFY_TEST_MARK="$mark" FM_VERIFY_TEST_UID="$(id -u)" \
    FM_VERIFY_TEST_GROUP="$ESCAPED_GROUP_LEADER_PID" \
    FM_VERIFY_TEST_ESCAPEE="$ESCAPED_GROUP_ESCAPEE_PID" \
    FM_VERIFY_TEST_MEMBER="$ESCAPED_GROUP_MEMBER_PID" \
    FM_VERIFY_TEST_OBSERVED_START="$ESCAPED_GROUP_OBSERVED_START" \
    FM_VERIFY_TEST_DRAIN_START="$drain_start" \
    FM_VERIFY_TEST_DRAIN_MARK="$ESCAPED_GROUP_DRAIN_MARK" \
    FM_VERIFY_TEST_GROUP_SAMPLES="$group_samples" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd "printf '%s\n' \$\$ > '$leader'; mkdir -p build; cp README.md build/app.txt; while [ \"\$(wc -l < '$mark')\" -lt 2 ]; do sleep 0.05; done; exit 0" \
    --artifact "$BUILD_ARTIFACT" 2>&1)
  VERIFY_RC=$?
  [ "$(wc -l < "$mark")" -ge 2 ] || fail "the runner never observed the escaped process group"
  return 0
}

test_live_member_of_an_escaped_group_fails_closed() {
  local retained_pids drain_samples
  # The group half of the containment check, on the process it exists for: an
  # orphan the drain never tracked, still running in a group the build entered,
  # with that group still led by the same process. Binding the group to an
  # identity must not cost the check this refusal, and neither may re-polling
  # it: this member is reported by every sample of the settle window, including
  # the closing one, which is the whole definition of a leak.
  run_escaped_group_fixture escaped-group-still-ours "$ESCAPED_GROUP_OBSERVED_START"
  drain_samples=$(wc -l < "$ESCAPED_GROUP_DRAIN_MARK")
  retained_pids=$(release_retained_build_state)
  expect_code 1 "$VERIFY_RC" \
    "a live member of an escaped group must fail closed (got: $VERIFY_OUT)"
  assert_contains "$VERIFY_OUT" "because build drain was not confirmed" \
    "a live escaped descendant must be reported as an unconfirmed drain"
  # The refusal has to say what is still running and why the run stopped. A
  # containment result the caller cannot explain is how a real leak gets read as
  # a broken tool and retried, so this refusal owns its own sentence rather than
  # falling through to the unrecognized-result path.
  assert_contains "$VERIFY_OUT" "$ESCAPED_GROUP_MEMBER_PID" \
    "the refusal must name the process that is still running"
  assert_contains "$VERIFY_OUT" "process groups it escaped into" \
    "the refusal must explain that the build left processes running behind it"
  assert_contains "$retained_pids" "$ESCAPED_GROUP_MEMBER_PID" \
    "the retained binding must name the surviving member of the escaped group"
  assert_absent "$FIX_HOME/data/demo-ship-verify/report.md" \
    "an unconfirmed drain must not become a product verdict"
  # The refusal has to be the verdict of a closed window rather than of the one
  # sample that opened it, or the re-poll is not doing the job it was added for.
  [ "$drain_samples" -ge "$ESCAPED_GROUP_SETTLE_WINDOW" ] \
    || fail "the refusal was taken before the settle window closed (drain samples: $drain_samples)"
  pass "fm-verify: live members of an escaped process group fail closed"
}

test_reused_process_group_number_is_not_this_builds_leak() {
  # The same shape, with one difference that decides everything: the group number
  # is now led by a different process than the one the build escaped into, which
  # is what a pid counter wrapping during a long build leaves behind. The live
  # process wearing that number belongs to a stranger, and the check must not
  # convict it - a false leak strands a build worktree and sends whoever reads the
  # refusal after a process that has nothing to do with this build.
  run_escaped_group_fixture escaped-group-number-reused 'Wed Mar  3 12:00:00 2003'
  expect_code 0 "$VERIFY_RC" \
    "a reused process group number must not fail the build (got: $VERIFY_OUT)"
  assert_not_contains "$VERIFY_OUT" "because build drain was not confirmed" \
    "a stranger wearing a remembered group number must not be reported as a leak"
  [ -s "$FIX_SPAWN_LOG" ] || fail "the verification must reach the verifier spawn"
  pass "fm-verify: a reused process group number is not this build's leak"
}

test_escaped_group_member_that_exits_during_the_settle_is_not_a_leak() {
  local drain_samples
  # A snapshot is a sample, so a liveness verdict taken from one of them convicts
  # the process that was already on its way out: a toolchain helper whose last
  # tracked ancestor died between samples is caught by the check and gone by the
  # time anyone reads the refusal - a refused verification, a stranded worktree
  # and an operator sent after a pid that no longer exists. Here the projected
  # group stops being reported partway through the window, so nothing of this
  # build is still running when the window closes and nothing may fail.
  run_escaped_group_fixture escaped-group-member-exits "$ESCAPED_GROUP_OBSERVED_START" \
    "$ESCAPED_GROUP_SETTLE_SAMPLES"
  drain_samples=$(wc -l < "$ESCAPED_GROUP_DRAIN_MARK")
  expect_code 0 "$VERIFY_RC" \
    "a member that exits during the settle window must not fail the build (got: $VERIFY_OUT)"
  assert_not_contains "$VERIFY_OUT" "because build drain was not confirmed" \
    "a member that exits during the settle window must not be reported as a leak"
  # Sampling past the point where the group stopped being reported is what makes
  # this a re-taken verdict rather than one that never saw the group at all: on
  # a single sample the run would have refused while it was still there.
  [ "$drain_samples" -gt "$ESCAPED_GROUP_SETTLE_SAMPLES" ] \
    || fail "the runner never re-sampled the escaped group (drain samples: $drain_samples)"
  [ -s "$FIX_SPAWN_LOG" ] || fail "the verification must reach the verifier spawn"
  pass "fm-verify: an escaped-group member that exits during the settle is not a leak"
}


test_build_descendant_closing_lineage_fails_closed() {
  local BUILD_CMD helper escaped_pid_file escaped_pid retained_pids
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
  # Same ordering rule as the sibling leak test: this daemon also ignores TERM,
  # so everything the run left running or on disk is released before the first
  # assertion that can end this test.
  escaped_pid=
  [ ! -s "$escaped_pid_file" ] || escaped_pid=$(cat "$escaped_pid_file")
  pkill -KILL -f "$helper" 2>/dev/null || true
  [ -z "$escaped_pid" ] || kill -KILL "$escaped_pid" 2>/dev/null || true
  retained_pids=$(release_retained_build_state)
  expect_code 1 "$VERIFY_RC" "a descriptor-closing daemon must fail closed (got: $VERIFY_OUT)"
  [ -n "$escaped_pid" ] || fail "the descriptor-closing descendant did not publish its pid"
  assert_contains "$VERIFY_OUT" "lineage continuity was lost" \
    "the refusal must identify the lost lineage boundary"
  assert_contains "$retained_pids" "$escaped_pid" \
    "the retained binding must identify the unaccounted descendant"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "lost lineage must stop before verifier spawn"
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
  local helper fake_ps target_pid snapshot worktree_file out pid rc worktree worktree_retained refusal retained_pids
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
  # This test is about the worktree still being there, so whether it survived is
  # recorded as a fact first - and only then released, under the same ordering
  # rule as the sibling refusal tests (see release_retained_build_state).
  worktree=$(cat "$worktree_file")
  worktree_retained=0
  [ ! -d "$worktree" ] || worktree_retained=1
  refusal=$(cat "$out")
  retained_pids=$(release_retained_build_state)
  [ "$worktree_retained" -eq 1 ] || fail "unconfirmed drain removed the live build worktree"
  assert_contains "$refusal" "$worktree" \
    "the drain refusal must report the exact retained worktree"
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
  run_verify demo-ship --promise "$PROMISE" --harness claude --effort high --model opus-5 --backend tmux
  expect_code 0 "$VERIFY_RC" "a verification with dispatch flags must spawn (got: $VERIFY_OUT)"
  args=$(cat "$FIX_SPAWN_LOG")
  assert_contains "$args" "--harness claude" "the resolved harness must reach the spawn"
  assert_contains "$args" "--effort high" "the resolved effort must reach the spawn"
  assert_contains "$args" "--model opus-5" "the resolved model must reach the spawn"
  assert_contains "$args" "--backend tmux" \
    "a backend that survives the preflight must still reach the spawn unchanged"
  pass "fm-verify: dispatch profile flags pass through to the spawn unchanged"
}

# install_unsearchable_mktemp <fakebin> <template-glob>: a shim that hands back a
# directory which is readable and writable but NOT searchable. `stat` still
# answers, so the ownership records are published exactly as on the happy path,
# while `cd` into it fails - the one shape that drives the canonicalization
# guards without racing anything.
install_unsearchable_mktemp() {
  local fakebin=$1 glob=$2
  mkdir -p "$fakebin"
  cat > "$fakebin/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in
  *$glob*)
    mkdir -p "\$FM_VERIFY_TEST_TARGET"
    chmod 600 "\$FM_VERIFY_TEST_TARGET"
    printf '%s\n' "\$FM_VERIFY_TEST_TARGET"
    exit 0
    ;;
esac
exec "\$REAL_MKTEMP_VERIFY" "\$@"
SH
  chmod +x "$fakebin/mktemp"
}

# A refusal that empties the variable holding the path it is refusing about
# destroys the only thing that made it recoverable: the EXIT trap's removal
# becomes vacuous, KEEP_BINDING stays 0, and the rollback deletes the sidecar
# while the mktemp'd directory stays on disk - a leaked directory whose
# ownership record was just erased. The path must survive the failure.
test_uncanonicalizable_neutral_directory_keeps_its_ownership_record() {
  local neutral out rc
  new_fixture uncanonicalizable-neutral
  neutral="$FIX_TMP/unsearchable-neutral"
  install_unsearchable_mktemp "$FIX_TMP/fakebin" 'fm-verify-artifacts.'
  out=$(PATH="$FIX_TMP/fakebin:$PATH" TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" \
    FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" FM_VERIFY_TEST_TARGET="$neutral" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  rc=$?
  chmod 700 "$neutral" 2>/dev/null || true
  expect_code 1 "$rc" "an uncanonicalizable neutral directory must refuse"
  assert_contains "$out" "$neutral" \
    "the refusal must name the exact directory it could not canonicalize"
  if [ -e "$neutral" ] || [ -L "$neutral" ]; then
    assert_grep "neutral_cleanup_path=$neutral" "$FIX_HOME/state/demo-ship-verify.verify" \
      "a neutral directory left on disk must keep the binding that records who owns it"
  fi
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "an uncanonicalizable neutral directory still spawned a verifier"
  pass "fm-verify: an uncanonicalizable neutral directory never outlives its ownership record"
}

# The same shape one allocation earlier, where it is worse: cleanup_build_worktree
# bails on an empty BUILD_CONTAINER, so the container leaked with no message at
# all. Fixing one of two identical instances is how the next reader concludes
# the pattern is fine.
test_uncanonicalizable_build_container_is_not_leaked_silently() {
  local container out rc
  new_fixture uncanonicalizable-build-container
  container="$FIX_TMP/unsearchable-container"
  install_unsearchable_mktemp "$FIX_TMP/fakebin" 'fm-verify-build.'
  out=$(PATH="$FIX_TMP/fakebin:$PATH" TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" \
    FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" FM_VERIFY_TEST_TARGET="$container" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  rc=$?
  chmod 700 "$container" 2>/dev/null || true
  expect_code 1 "$rc" "an uncanonicalizable build container must refuse"
  assert_contains "$out" "$container" \
    "the refusal must name the exact container it could not canonicalize"
  [ ! -e "$container" ] || fail "the build container was leaked instead of being cleaned up"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "an uncanonicalizable build container still spawned a verifier"
  pass "fm-verify: an uncanonicalizable build container is cleaned up, not silently leaked"
}

# bin/fm-spawn.sh refuses --neutral-dir under backend=orca, and every verifier
# spawn supplies one. Meeting that refusal at the end - after a full detached
# build, an artifact copy and a scaffolded brief - retains a neutral directory
# for hand reconciliation every single time, for a mismatch that is knowable
# before anything is written.
test_backend_that_cannot_launch_a_verifier_refuses_before_any_work() {
  local marker out rc
  new_fixture orca-preflight
  marker="$FIX_TMP/build-ran"
  out=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    FM_BACKEND=orca "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify \
    --promise "$PROMISE" --build-cmd "touch '$marker'" --artifact "$BUILD_ARTIFACT" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a backend that cannot launch a neutral verifier must refuse"
  assert_contains "$out" "backend 'orca'" "the refusal must name the resolved backend"
  assert_contains "$out" "non-repository directory" \
    "the refusal must name the neutral-launch capability the backend lacks"
  [ ! -e "$marker" ] || fail "an unusable backend ran the build before refusing"
  [ ! -s "$FIX_SPAWN_LOG" ] || fail "an unusable backend still reached the spawn"
  assert_absent "$FIX_HOME/state/demo-ship-verify.verify" \
    "a backend refusal must leave no binding to reconcile"
  assert_absent "$FIX_HOME/data/demo-ship-verify/brief.md" \
    "a backend refusal must scaffold nothing"

  # The flag form must refuse identically: the backend can arrive either way.
  out=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    "$ROOT/bin/fm-verify.sh" demo-ship --verify-id demo-ship-verify --backend orca \
    --promise "$PROMISE" --build-cmd "touch '$marker'" --artifact "$BUILD_ARTIFACT" 2>&1)
  rc=$?
  expect_code 1 "$rc" "an explicit --backend orca must refuse too"
  assert_contains "$out" "backend 'orca'" "the explicit-flag refusal must name the backend"
  assert_contains "$out" "non-repository directory" \
    "the explicit-flag refusal must name the neutral-launch capability"
  [ ! -e "$marker" ] || fail "an explicit unusable backend ran the build before refusing"
  pass "fm-verify: a backend that cannot launch a verifier refuses before any expensive work"
}

# "This verification WAITS for a slot" is true while work is in flight and false
# when the slots are held by bindings a spawn stranded. The machinery must not
# state something it knows to be false.
test_capacity_refusal_names_stranded_bindings() {
  local stranded out rc
  new_fixture capacity-stranded
  stranded="$FIX_HOME/state/stranded-verify.verify"
  printf 'verifies=other\nendpoint_uncertain=1\n' > "$stranded"
  out=$(TMPDIR="$FIX_TMP" FM_HOME="$FIX_HOME" FM_VERIFY_SPAWN_OVERRIDE="$FIX_SPAWN" \
    FM_VERIFY_MAX_CONCURRENT=1 "$ROOT/bin/fm-verify.sh" demo-ship \
    --verify-id demo-ship-verify --promise "$PROMISE" \
    --build-cmd "$BUILD_CMD" --artifact "$BUILD_ARTIFACT" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a stranded binding still holds its slot and still refuses"
  assert_contains "$out" "at the limit of 1" "the refusal must still state the limit reached"
  assert_contains "$out" "1 of those slot(s) are held by stranded bindings" \
    "the refusal must name how many slots hold no work"
  assert_contains "$out" "$stranded" \
    "the refusal must name the exact binding path to reconcile"
  assert_contains "$out" "endpoint_uncertain=1" \
    "the refusal must name the field that keeps the slot held"
  assert_contains "$out" "retained DELIBERATELY" \
    "the refusal must say the binding is kept on purpose, not lost"
  assert_not_contains "$out" "never skipped" \
    "the refusal must not claim work is in flight when the slots are wedged"
  pass "fm-verify: a capacity refusal names stranded bindings instead of implying live work"
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
test_missing_artifact_after_a_clean_build_is_not_a_product_verdict
test_neutral_identity_comes_from_one_shared_helper
test_sidecar_identity_survives_a_divergent_stat_host
test_artifact_path_cannot_escape_through_a_symlinked_parent
test_artifact_descendant_symlink_must_stay_neutral
test_artifact_internal_symlink_is_preserved
test_cross_artifact_internal_symlink_is_preserved
test_unusable_build_runner_is_not_a_product_verdict
test_transient_process_table_miss_is_re_observed
test_permanently_unobservable_leader_still_refuses
test_build_timeout_is_not_a_product_verdict
test_build_cannot_forge_runner_status
test_build_descendants_are_drained_before_staging
test_build_descendant_left_alive_after_drain_fails_closed
test_cleanly_exited_own_process_group_children_are_not_a_leak
test_live_member_of_an_escaped_group_fails_closed
test_reused_process_group_number_is_not_this_builds_leak
test_escaped_group_member_that_exits_during_the_settle_is_not_a_leak
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
test_uncanonicalizable_neutral_directory_keeps_its_ownership_record
test_uncanonicalizable_build_container_is_not_leaked_silently
test_backend_that_cannot_launch_a_verifier_refuses_before_any_work
test_capacity_refusal_names_stranded_bindings
test_unfinished_task_is_flagged_but_allowed
