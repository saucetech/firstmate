#!/usr/bin/env bash
# Regression tests for fm-spawn.sh's worktree isolation: the settle loop that
# waits for `treehouse get` to move the pane, and the assertion that decides
# whether the resulting directory is safe to launch a worker in. Both drive the
# real script through a fake tmux whose pane_current_path answers are scripted.
#
# Settling. On some tmux/WSL setups a brand-new window's pane_current_path
# transiently reports a stale, unrelated-but-real path on the very first poll,
# before the pane actually settles into the worktree treehouse get moved it to.
# That stale path is a real git checkout too, just the wrong one, so a naive
# single-read loop silently records the wrong worktree= in state/<id>.meta.
#
# Isolation. The recorded worktree and the guarded launch both have to survive a
# project path spelled differently from the pane's own cwd read, and the guard
# has to refuse a pane that is genuinely sitting in the primary checkout rather
# than accept it because it merely looks like a distinct git top level. Those
# two relationships - "moved on from the project" and "genuinely outside it" -
# are different questions, and conflating them let a worker be recorded as
# running in the primary checkout on 2026-08-19, 2026-08-04 and 2026-08-24.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
# When FM_FAKE_TMUX_JOURNAL names a file, every subcommand is appended to it,
# so a test can observe whether the task endpoint was created and whether it
# was removed again.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TMUX_JOURNAL:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TMUX_JOURNAL"
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

write_neutral_binding() {
  local binding=$1 target=$2 identity=${3:-}
  [ -n "$identity" ] || identity=$(stat -c '%d:%i' "$target" 2>/dev/null || stat -f '%d:%i' "$target")
  fm_write_meta "$binding" \
    "verifies=ship-x1" \
    "neutral_cleanup_path=$target" \
    "neutral_cleanup_identity=$identity"
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

test_neutral_mode_refuses_a_git_repository() {
  local rec id out status
  id=neutralgitrefusal
  rec=$(make_settle_case neutral-git "$id" 0)
  read_settle_record "$rec"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --scout --neutral-dir "$STALE_DIR" 2>&1)
  status=$?
  expect_code 1 "$status" "neutral mode must refuse a directory that is a git repository"
  assert_contains "$out" "must not be a git repository or worktree" \
    "the neutral-mode refusal must name repository contamination"
  assert_absent "$HOME_DIR/state/$id.meta" "neutral-mode refusal must happen before metadata publication"
  pass "fm-spawn: neutral mode refuses a git repository before launch"
}

test_neutral_mode_refuses_a_directory_inside_the_project() {
  local rec id out status neutral
  id=neutralinsideproject
  rec=$(make_settle_case neutral-inside "$id" 0)
  read_settle_record "$rec"
  neutral="$PROJ_DIR/neutral"
  mkdir -p "$neutral"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --scout --neutral-dir "$neutral" 2>&1)
  status=$?
  expect_code 1 "$status" "neutral mode must refuse a directory inside the project"
  assert_contains "$out" "must not be a git repository or worktree" \
    "a project descendant must be recognized as repository-contaminated"
  assert_absent "$HOME_DIR/state/$id.meta" "project containment refusal must happen before metadata publication"
  pass "fm-spawn: neutral mode refuses a directory inside the project"
}

test_neutral_mode_records_directory_identity() {
  local rec id out status neutral identity
  id=neutralidentity
  rec=$(make_settle_case neutral-identity "$id" 0)
  read_settle_record "$rec"
  neutral="$(dirname "$HOME_DIR")/neutral-artifacts"
  mkdir -p "$neutral"
  write_neutral_binding "$HOME_DIR/state/$id.verify" "$neutral"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --scout --neutral-dir "$neutral" 2>&1)
  status=$?
  expect_code 0 "$status" "neutral mode must launch from an isolated ordinary directory (got: $out)"
  identity=$(stat -c '%d:%i' "$neutral" 2>/dev/null || stat -f '%d:%i' "$neutral")
  assert_grep "launch_mode=neutral" "$HOME_DIR/state/$id.meta" \
    "neutral task metadata must identify its teardown mode"
  assert_grep "neutral_identity=$identity" "$HOME_DIR/state/$id.meta" \
    "neutral task metadata must bind the directory device and inode"
  pass "fm-spawn: neutral mode records the launch directory filesystem identity"
}

test_neutral_mode_refuses_an_unbound_directory() {
  local rec id out status neutral
  id=neutralunbound
  rec=$(make_settle_case neutral-unbound "$id" 0)
  read_settle_record "$rec"
  neutral="$(dirname "$HOME_DIR")/unbound-artifacts"
  mkdir -p "$neutral"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --scout --neutral-dir "$neutral" 2>&1)
  status=$?
  expect_code 1 "$status" "neutral mode must refuse a directory without verifier ownership"
  assert_contains "$out" "no matching verifier ownership binding" \
    "an unbound neutral directory must be refused explicitly"
  assert_absent "$HOME_DIR/state/$id.meta" "unbound neutral refusal must precede metadata publication"
  pass "fm-spawn: neutral mode refuses an unbound directory"
}

test_neutral_mode_refuses_a_mismatched_binding_identity() {
  local rec id out status neutral
  id=neutralbindingmismatch
  rec=$(make_settle_case neutral-binding-mismatch "$id" 0)
  read_settle_record "$rec"
  neutral="$(dirname "$HOME_DIR")/mismatched-artifacts"
  mkdir -p "$neutral"
  write_neutral_binding "$HOME_DIR/state/$id.verify" "$neutral" "0:0"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --scout --neutral-dir "$neutral" 2>&1)
  status=$?
  expect_code 1 "$status" "neutral mode must refuse a stale verifier identity"
  assert_contains "$out" "does not match its verifier ownership binding" \
    "a stale verifier identity must be refused explicitly"
  assert_absent "$HOME_DIR/state/$id.meta" "stale binding refusal must precede metadata publication"
  pass "fm-spawn: neutral mode refuses a stale verifier identity"
}

test_neutral_mode_refuses_external_projects_root_descendants() {
  local rec id out status projects neutral
  id=neutralexternalprojects
  rec=$(make_settle_case neutral-external-projects "$id" 0)
  read_settle_record "$rec"
  projects="$(dirname "$HOME_DIR")/external-projects"
  neutral="$projects/neutral-artifacts"
  mkdir -p "$neutral"
  write_neutral_binding "$HOME_DIR/state/$id.verify" "$neutral"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --scout --neutral-dir "$neutral" 2>&1)
  status=$?
  expect_code 1 "$status" "neutral mode must refuse a directory beneath an external projects root"
  assert_contains "$out" "conflicts with a protected path" \
    "the projects root must remain protected outside the firstmate home"
  assert_absent "$HOME_DIR/state/$id.meta" "projects-root refusal must precede metadata publication"
  pass "fm-spawn: neutral mode protects an external projects root"
}

# run_isolation_spawn <id> <project-arg> [env=value ...] runs a spawn against an
# arbitrary spelling of the project path, journalling every backend command so a
# test can assert whether the task endpoint survived. The poll knobs keep a
# deliberate no-settle case from burning the full production wait.
run_isolation_spawn() {
  local id=$1 project_arg=$2
  shift 2
  env "$@" \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_TMUX_JOURNAL="$JOURNAL" \
    FM_SPAWN_WORKTREE_POLLS=6 FM_SPAWN_WORKTREE_POLL_INTERVAL=0.1 \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$project_arg" --mode no-mistakes --yolo off 2>&1
}

# assert_refused_without_trace <id> <output> <status> <what>
# A refusal is only safe if it leaves nothing behind: the four things the
# 2026-08-19 and 2026-08-04 incidents each left in the primary checkout are a
# non-zero exit, a durable task record, a turn-end hook, and a live endpoint.
assert_refused_without_trace() {
  local id=$1 out=$2 status=$3 what=$4
  [ "$status" -ne 0 ] || fail "$what: spawn exited 0 instead of refusing (output: $out)"
  assert_absent "$HOME_DIR/state/$id.meta" "$what: a refused spawn must publish no task record"
  assert_absent "$PROJ_DIR/.claude/settings.local.json" \
    "$what: a refused spawn must install no turn-end hook in the primary checkout"
  assert_grep "kill-window" "$JOURNAL" \
    "$what: a refused spawn must remove the endpoint it created"
}

# The measured 2026-08-24 defect. A project path typed in any case other than
# its on-disk spelling can never string-match the pane's own cwd read, so the
# settle loop concluded on its FIRST poll that the pane had already left the
# project and recorded the PRIMARY CHECKOUT as the isolated worktree. Every
# comparison must therefore be device+inode identity, not text.
#
# Only reproducible on a case-insensitive volume (macOS's default APFS, and the
# platform all three incidents happened on): where two spellings name two
# genuinely different directories, the mis-spelled one simply does not exist and
# the spawn refuses for that reason instead.
test_mixed_case_project_spelling_records_the_pooled_worktree() {
  local rec id out status parent mixed recorded_project
  id=isolation-mixed-case-z3
  rec=$(make_settle_case isolation-mixed-case "$id" 3)
  read_settle_record "$rec"
  JOURNAL="$(dirname "$COUNTFILE")/tmux-journal"

  parent=$(dirname "$PROJ_DIR")
  mixed="$parent/$(printf '%s' "$(basename "$PROJ_DIR")" | tr '[:lower:]' '[:upper:]')"
  if [ "$mixed" = "$PROJ_DIR" ] || [ ! -d "$mixed" ]; then
    pass "SKIP (case-sensitive volume): a mis-cased project path names no directory here"
    return 0
  fi

  # The pane reports the project in its true on-disk spelling for the first
  # reads - exactly what tmux does before treehouse get's cd lands - then the
  # pooled worktree.
  out=$(run_isolation_spawn "$id" "$mixed" \
    FM_FAKE_PANE_STALE="$PROJ_DIR" FM_FAKE_PANE_STALE_READS=3 \
    FM_FAKE_PANE_PATH="$WT_DIR")
  status=$?

  expect_code 0 "$status" "a mis-cased project path must still settle in the pooled worktree (got: $out)"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the pooled worktree for a mis-cased project path"
  assert_no_grep "worktree=$PROJ_DIR" "$HOME_DIR/state/$id.meta" \
    "meta recorded the PRIMARY CHECKOUT as the isolated worktree"
  # One repo must map to one worktree pool however its path was typed, so the
  # recorded project is the canonical directory rather than the spelling used.
  recorded_project=$(sed -n 's/^project=//p' "$HOME_DIR/state/$id.meta")
  [ -n "$recorded_project" ] && [ "$recorded_project" -ef "$PROJ_DIR" ] \
    || fail "meta recorded project='$recorded_project', which is not the project directory"
  [ "$recorded_project" != "$mixed" ] \
    || fail "meta recorded the mis-cased spelling verbatim, so this repo would lease from a second worktree pool"
  pass "fm-spawn: a mis-cased project path records the pooled worktree, never the primary checkout"
}

# The guard's own hazard: a pane that never leaves the primary checkout. The
# launch must be refused outright rather than accepted, timed out into a
# half-built task, or left parked on a live endpoint in the primary checkout.
test_pane_that_never_leaves_the_primary_checkout_is_refused() {
  local rec id out status
  id=isolation-never-leaves-z4
  rec=$(make_settle_case isolation-never-leaves "$id" 0)
  read_settle_record "$rec"
  JOURNAL="$(dirname "$COUNTFILE")/tmux-journal"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"

  out=$(run_isolation_spawn "$id" "$PROJ_DIR" \
    FM_FAKE_PANE_STALE="$PROJ_DIR" FM_FAKE_PANE_STALE_READS=0 \
    FM_FAKE_PANE_PATH="$PROJ_DIR")
  status=$?

  assert_refused_without_trace "$id" "$out" "$status" "pane parked in the primary checkout"
  assert_contains "$out" "primary checkout" \
    "the refusal must name the primary checkout as the reason, so the operator knows what to fix"
  pass "fm-spawn: a pane that never leaves the primary checkout is refused, leaving no record, hook, or endpoint"
}

# The other half of the relationship the old guard conflated: a directory can be
# a genuine, distinct git worktree top level and still sit INSIDE the primary
# checkout, where a worker's writes tangle it just the same. "Different from the
# project" is not the safety property; "genuinely outside it" is.
test_worktree_inside_the_primary_checkout_is_refused() {
  local rec id out status nested
  id=isolation-nested-worktree-z5
  rec=$(make_settle_case isolation-nested "$id" 0)
  read_settle_record "$rec"
  JOURNAL="$(dirname "$COUNTFILE")/tmux-journal"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  nested="$PROJ_DIR/nested-worktree"
  git -C "$PROJ_DIR" worktree add --quiet -b nested-inside "$nested"

  out=$(run_isolation_spawn "$id" "$PROJ_DIR" \
    FM_FAKE_PANE_STALE="$nested" FM_FAKE_PANE_STALE_READS=0 \
    FM_FAKE_PANE_PATH="$nested")
  status=$?

  assert_refused_without_trace "$id" "$out" "$status" "worktree nested inside the primary checkout"
  assert_absent "$nested/.claude/settings.local.json" \
    "no turn-end hook may be installed in a worktree inside the primary checkout"
  pass "fm-spawn: a worktree inside the primary checkout is refused, however distinct it looks"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_mixed_case_project_spelling_records_the_pooled_worktree
test_pane_that_never_leaves_the_primary_checkout_is_refused
test_worktree_inside_the_primary_checkout_is_refused
test_neutral_mode_refuses_a_git_repository
test_neutral_mode_refuses_a_directory_inside_the_project
test_neutral_mode_records_directory_identity
test_neutral_mode_refuses_an_unbound_directory
test_neutral_mode_refuses_a_mismatched_binding_identity
test_neutral_mode_refuses_external_projects_root_descendants

echo "# all fm-spawn-worktree-settle tests passed"
