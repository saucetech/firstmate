#!/usr/bin/env bash
# Build a finished ship revision and spawn an INDEPENDENT VERIFIER before merge.
#
# The verifier receives a runnable artifact and the user-facing promise in a
# neutral non-repository directory. It never receives source, a branch name, the
# implementing brief, the PR, or the builder's report. fm-spawn.sh still owns
# harness/backend resolution, endpoint creation, hooks, and metadata publication.
#
# Usage: fm-verify.sh <ship-task-id> (--promise-file <path>|--promise <text>) --build-cmd <command> --artifact <relative-path> [--artifact <relative-path> ...] [options]
#   --promise-file <path>  file holding the user-facing promise
#   --promise <text>       the user-facing promise inline
#   --build-cmd <command>  project-specific command run in a detached build worktree
#   --artifact <path>      runnable artifact relative to that worktree; repeatable
#   --rev <commit-ish>     revision to verify; default fm/<ship-task-id>
#   --verify-id <id>       verifier task id; default <ship-task-id>-verify-<revision>
#   --harness <name> | --model <name> | --effort <level> | --backend <name>
#                          passed through to bin/fm-spawn.sh unchanged
#   --dry-run              run preflight and print the plan without writing
#   -h, --help             print this header
#
# FM_VERIFY_BUILD_TIMEOUT bounds the build in seconds and defaults to 1800.
# FM_VERIFY_MAX_CONCURRENT defaults to 2. Reaching capacity delays verification;
# it never exempts one. FM_VERIFY_SPAWN_OVERRIDE replaces fm-spawn.sh for tests.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SPAWN_CMD=${FM_VERIFY_SPAWN_OVERRIDE:-$SCRIPT_DIR/fm-spawn.sh}
MAX_CONCURRENT=${FM_VERIFY_MAX_CONCURRENT:-2}
BUILD_TIMEOUT=${FM_VERIFY_BUILD_TIMEOUT:-1800}

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

case "$MAX_CONCURRENT" in
  ''|*[!0-9]*) echo "error: FM_VERIFY_MAX_CONCURRENT must be a non-negative integer" >&2; exit 2 ;;
esac
case "$BUILD_TIMEOUT" in
  ''|*[!0-9]*|0) echo "error: FM_VERIFY_BUILD_TIMEOUT must be a positive integer" >&2; exit 2 ;;
esac

PROMISE=
PROMISE_FILE=
PROMISE_SET=0
BUILD_CMD=
BUILD_CMD_SET=0
ARTIFACTS=()
REV_ARG=
VERIFY_ID=
DRY_RUN=0
PASSTHROUGH=()
POS=()
want_value=

for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in --*) echo "error: --$want_value requires a value" >&2; exit 2 ;; esac
    case "$want_value" in
      promise) PROMISE=$a; PROMISE_SET=$((PROMISE_SET + 1)) ;;
      promise-file) PROMISE_FILE=$a; PROMISE_SET=$((PROMISE_SET + 1)) ;;
      build-cmd) BUILD_CMD=$a; BUILD_CMD_SET=$((BUILD_CMD_SET + 1)) ;;
      artifact) ARTIFACTS+=("$a") ;;
      rev) REV_ARG=$a ;;
      verify-id) VERIFY_ID=$a ;;
      harness|model|effort|backend) PASSTHROUGH+=("--$want_value" "$a") ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --promise|--promise-file|--build-cmd|--artifact|--rev|--verify-id|--harness|--model|--effort|--backend) want_value=${a#--} ;;
    --promise=*) PROMISE=${a#--promise=}; PROMISE_SET=$((PROMISE_SET + 1)) ;;
    --promise-file=*) PROMISE_FILE=${a#--promise-file=}; PROMISE_SET=$((PROMISE_SET + 1)) ;;
    --build-cmd=*) BUILD_CMD=${a#--build-cmd=}; BUILD_CMD_SET=$((BUILD_CMD_SET + 1)) ;;
    --artifact=*) ARTIFACTS+=("${a#--artifact=}") ;;
    --rev=*) REV_ARG=${a#--rev=} ;;
    --verify-id=*) VERIFY_ID=${a#--verify-id=} ;;
    --harness=*|--model=*|--effort=*|--backend=*) PASSTHROUGH+=("$a") ;;
    --dry-run) DRY_RUN=1 ;;
    --*) echo "error: unknown option '$a'" >&2; exit 2 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 2; }
[ "${#POS[@]}" -eq 1 ] || { echo "error: exactly one <ship-task-id> is required" >&2; usage >&2; exit 2; }
SHIP_ID=${POS[0]}
fm_pr_task_id_valid "$SHIP_ID" || { echo "error: invalid task id '$SHIP_ID'" >&2; exit 2; }

if [ "$PROMISE_SET" -eq 0 ]; then
  echo "error: a user-facing promise is required; pass --promise-file <path> or --promise <text>" >&2
  exit 2
fi
[ "$PROMISE_SET" -eq 1 ] || { echo "error: pass only one of --promise or --promise-file" >&2; exit 2; }
if [ -n "$PROMISE_FILE" ]; then
  [ -f "$PROMISE_FILE" ] || { echo "error: promise file not found: $PROMISE_FILE" >&2; exit 2; }
  PROMISE=$(cat "$PROMISE_FILE")
fi
case "$(printf '%s' "$PROMISE" | tr -d '[:space:]')" in '') echo "error: the promise is empty" >&2; exit 2 ;; esac

if [ "$BUILD_CMD_SET" -ne 1 ] || [ "${#ARTIFACTS[@]}" -eq 0 ]; then
  echo "error: this project has no configured way to produce a runnable artifact and is therefore unverifiable" >&2
  echo "       firstmate must decide and supply one --build-cmd plus at least one --artifact" >&2
  exit 2
fi
case "$(printf '%s' "$BUILD_CMD" | tr -d '[:space:]')" in '') echo "error: --build-cmd must not be empty" >&2; exit 2 ;; esac
for artifact in "${ARTIFACTS[@]}"; do
  case "$artifact" in
    ''|/*|..|../*|*/..|*/../*) echo "error: --artifact must be a safe path relative to the build worktree: $artifact" >&2; exit 2 ;;
  esac
done

SHIP_META="$STATE/$SHIP_ID.meta"
[ -f "$SHIP_META" ] || { echo "error: no record of task '$SHIP_ID' at $SHIP_META" >&2; exit 1; }
SHIP_KIND=$(fm_meta_get "$SHIP_META" kind)
SHIP_KIND=${SHIP_KIND:-ship}
[ "$SHIP_KIND" = ship ] || { echo "error: task '$SHIP_ID' is kind=$SHIP_KIND; only a ship task can be verified" >&2; exit 1; }
PROJECT=$(fm_meta_get "$SHIP_META" project)
[ -d "$PROJECT" ] || { echo "error: project directory for '$SHIP_ID' does not exist: $PROJECT" >&2; exit 1; }
git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error: project for '$SHIP_ID' is not a git repository: $PROJECT" >&2; exit 1; }
REPO_NAME=$(basename "$PROJECT")

SHIP_STATUS="$STATE/$SHIP_ID.status"
if [ -f "$SHIP_STATUS" ]; then
  grep -q '^done:' "$SHIP_STATUS" 2>/dev/null || echo "warning: task '$SHIP_ID' has not reported done; verifying a head that may still change" >&2
else
  echo "warning: task '$SHIP_ID' has no status log; verifying a head that may still change" >&2
fi

REV_SOURCE=$REV_ARG
[ -n "$REV_SOURCE" ] || REV_SOURCE="fm/$SHIP_ID"
REV=$(git -C "$PROJECT" rev-parse --verify --quiet "$REV_SOURCE^{commit}" 2>/dev/null) || {
  echo "error: cannot resolve '$REV_SOURCE' to a commit in $PROJECT" >&2
  [ -n "$REV_ARG" ] || echo "       pass --rev <commit-ish> with the revision to verify" >&2
  exit 1
}
REV_SHORT=$(git -C "$PROJECT" rev-parse --short "$REV")

sha256_hex() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

if [ -z "$VERIFY_ID" ]; then
  VERIFY_ID_STEM=$SHIP_ID
  if [ "${#VERIFY_ID_STEM}" -gt 44 ]; then
    TASK_ID_DIGEST=$(printf '%s' "$SHIP_ID" | sha256_hex)
    VERIFY_ID_STEM="${SHIP_ID:0:31}-${TASK_ID_DIGEST:0:12}"
  fi
  VERIFY_ID="$VERIFY_ID_STEM-verify-${REV:0:12}"
fi
fm_task_id_creation_valid "$VERIFY_ID" || { echo "error: invalid verifier task id '$VERIFY_ID'" >&2; exit 2; }
[ "$VERIFY_ID" != "$SHIP_ID" ] || { echo "error: the verifier task id must differ from '$SHIP_ID'" >&2; exit 2; }
VERIFY_META="$STATE/$VERIFY_ID.meta"
VERIFY_SIDECAR="$STATE/$VERIFY_ID.verify"
VERIFY_DATA_DIR="$DATA/$VERIFY_ID"
VERIFY_BRIEF="$VERIFY_DATA_DIR/brief.md"
VERIFY_REPORT="$VERIFY_DATA_DIR/report.md"
VERIFY_SIDECAR_IDENTITY=
if [ -e "$VERIFY_META" ]; then
  if [ -e "$VERIFY_SIDECAR" ]; then
    echo "error: a verification of '$SHIP_ID' is already under way as '$VERIFY_ID'" >&2
  else
    echo "error: task id '$VERIFY_ID' is already in use" >&2
  fi
  exit 1
fi
if [ -e "$VERIFY_SIDECAR" ]; then
  STALE_NEUTRAL_PATH=$(fm_meta_get "$VERIFY_SIDECAR" neutral_cleanup_path)
  STALE_BUILD_PATH=$(fm_meta_get "$VERIFY_SIDECAR" build_cleanup_path)
  STALE_BUILD_CONTAINER=$(fm_meta_get "$VERIFY_SIDECAR" build_cleanup_container)
  STALE_BUILD_PIDS=$(fm_meta_get "$VERIFY_SIDECAR" build_cleanup_pids)
  STALE_ENDPOINT_UNCERTAIN=$(fm_meta_get "$VERIFY_SIDECAR" endpoint_uncertain)
  STALE_RESERVATION_PID=$(fm_meta_get "$VERIFY_SIDECAR" reservation_pid)
  STALE_VERIFIES=$(fm_meta_get "$VERIFY_SIDECAR" verifies)
  if [ -n "$STALE_VERIFIES" ] && [ "$STALE_VERIFIES" != "$SHIP_ID" ]; then
    echo "error: task id '$VERIFY_ID' is already in use" >&2
    exit 1
  fi
  case "$STALE_RESERVATION_PID" in
    ''|*[!0-9]*) ;;
    *)
      if kill -0 "$STALE_RESERVATION_PID" 2>/dev/null; then
        echo "error: a verification of '$SHIP_ID' is already under way as '$VERIFY_ID'" >&2
        exit 1
      fi
      ;;
  esac
  STALE_LIVE_PIDS=
  OLD_IFS=$IFS
  IFS=,
  for stale_pid in $STALE_BUILD_PIDS; do
    case "$stale_pid" in
      '') ;;
      *[!0-9]*) STALE_LIVE_PIDS=${STALE_LIVE_PIDS}${STALE_LIVE_PIDS:+,}$stale_pid ;;
      *)
        if kill -0 "$stale_pid" 2>/dev/null; then
          STALE_LIVE_PIDS=${STALE_LIVE_PIDS}${STALE_LIVE_PIDS:+,}$stale_pid
        fi
        ;;
    esac
  done
  IFS=$OLD_IFS
  if [ -n "$STALE_NEUTRAL_PATH" ] && { [ -e "$STALE_NEUTRAL_PATH" ] || [ -L "$STALE_NEUTRAL_PATH" ]; }; then
    echo "error: verifier task '$VERIFY_ID' retains an unreconciled neutral directory at $STALE_NEUTRAL_PATH" >&2
    echo "       remove that exact directory after validating its recorded identity, then retry" >&2
    exit 1
  fi
  if [ -n "$STALE_BUILD_PATH" ] && { [ -e "$STALE_BUILD_PATH" ] || [ -L "$STALE_BUILD_PATH" ] || git -C "$PROJECT" -c core.quotePath=false worktree list --porcelain 2>/dev/null | grep -Fqx "worktree $STALE_BUILD_PATH"; }; then
    echo "error: verifier task '$VERIFY_ID' retains an unreconciled build worktree at $STALE_BUILD_PATH" >&2
    echo "       reconcile that exact worktree before retrying" >&2
    exit 1
  fi
  if [ -n "$STALE_BUILD_CONTAINER" ] && { [ -e "$STALE_BUILD_CONTAINER" ] || [ -L "$STALE_BUILD_CONTAINER" ]; }; then
    echo "error: verifier task '$VERIFY_ID' retains an unreconciled build container at $STALE_BUILD_CONTAINER" >&2
    echo "       reconcile that exact container before retrying" >&2
    exit 1
  fi
  if [ -n "$STALE_LIVE_PIDS" ]; then
    echo "error: verifier task '$VERIFY_ID' retains unreconciled build processes: $STALE_LIVE_PIDS" >&2
    echo "       reconcile those exact processes before retrying" >&2
    exit 1
  fi
  if [ "$STALE_ENDPOINT_UNCERTAIN" = 1 ]; then
    echo "error: verifier task '$VERIFY_ID' retains an endpoint whose absence is unconfirmed" >&2
    echo "       reconcile task '$VERIFY_ID' before retrying" >&2
    exit 1
  fi
  VERIFY_SIDECAR_IDENTITY=$(fm_pr_file_identity "$VERIFY_SIDECAR") || {
    echo "error: verifier binding identity cannot be read at $VERIFY_SIDECAR" >&2
    exit 1
  }
fi
[ ! -e "$VERIFY_BRIEF" ] || { echo "error: a brief already exists at $VERIFY_BRIEF" >&2; exit 1; }
[ ! -e "$VERIFY_REPORT" ] || { echo "error: a report already exists at $VERIFY_REPORT" >&2; exit 1; }

live_verifications() {
  local sidecar id reservation_pid endpoint_uncertain count=0
  for sidecar in "$STATE"/*.verify; do
    [ -f "$sidecar" ] || continue
    id=$(basename "$sidecar" .verify)
    if [ -f "$STATE/$id.meta" ]; then
      count=$((count + 1))
      continue
    fi
    endpoint_uncertain=$(fm_meta_get "$sidecar" endpoint_uncertain)
    if [ "$endpoint_uncertain" = 1 ]; then
      count=$((count + 1))
      continue
    fi
    reservation_pid=$(fm_meta_get "$sidecar" reservation_pid)
    case "$reservation_pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$reservation_pid" 2>/dev/null || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

capacity_refusal() {
  echo "error: $1 verification(s) already running, at the limit of $MAX_CONCURRENT" >&2
  echo "       this verification WAITS for a slot; it is never skipped - the merge waits with it" >&2
}

if [ "$DRY_RUN" -eq 1 ]; then
  LIVE=$(live_verifications)
  [ "$LIVE" -lt "$MAX_CONCURRENT" ] || { capacity_refusal "$LIVE"; exit 1; }
  printf 'would verify:  %s\nrevision:      %s (%s from %s)\nproject:       %s\nverifier task: %s\n' "$SHIP_ID" "$REV" "$REV_SHORT" "$REV_SOURCE" "$PROJECT" "$VERIFY_ID"
  printf 'build command: %s\n' "$BUILD_CMD"
  for artifact in "${ARTIFACTS[@]}"; do printf 'artifact:      %s\n' "$artifact"; done
  printf 'spawn command: %s %s %s --scout --neutral-dir <created-after-build>\n' "$SPAWN_CMD" "$VERIFY_ID" "$PROJECT"
  printf 'dry run: nothing was written and no verifier was spawned\n'
  exit 0
fi

CREATED_DATA_DIR=0
CREATED_BRIEF=0
CREATED_SIDECAR=0
KEEP_BINDING=0
CAPACITY_LOCK="$STATE/.verify-capacity.lock"
CAPACITY_LOCK_HELD=0
BUILD_CONTAINER=
BUILD_DIR=
BUILD_DIR_REAL=
BUILD_PID=
BUILD_RUNNER_STARTED=0
BUILD_DRAIN_CONFIRMED=1
BUILD_RUNNER_RESULT=
BUILD_RUNNER_RC=0
BUILD_STATUS_READ_OPEN=0
BUILD_STATUS_WRITE_OPEN=0
NEUTRAL_DIR=
NEUTRAL_IDENTITY=
SIGNAL_CRITICAL=0
SIGNAL_CRITICAL_KIND=
PENDING_SIGNAL=0
RETAIN_NEUTRAL=0
SPAWN_ATTEMPTED=0
SPAWN_ENDPOINT_UNCERTAIN=0
PERL_BIN=

verify_rollback() {
  [ "$CREATED_SIDECAR" -eq 0 ] || rm -f "$VERIFY_SIDECAR"
  if [ "$CREATED_BRIEF" -eq 1 ]; then
    if [ "$CREATED_DATA_DIR" -eq 1 ]; then
      rm -rf "$VERIFY_DATA_DIR"
    else
      rm -f "$VERIFY_BRIEF"
    fi
  fi
}

worktree_path_listed() {
  local listed line path path_real
  listed=$(git -C "$PROJECT" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || return 2
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        path=${line#worktree }
        [ "$path" != "$BUILD_DIR" ] || return 0
        if path_real=$(CDPATH='' cd -- "$(dirname "$path")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")"); then
          [ "$path_real" != "$BUILD_DIR_REAL" ] || return 0
        fi
        ;;
    esac
  done <<EOF
$listed
EOF
  return 1
}

close_build_status_fds() {
  if [ "$BUILD_STATUS_WRITE_OPEN" -eq 1 ]; then
    exec 3>&-
    BUILD_STATUS_WRITE_OPEN=0
  fi
  if [ "$BUILD_STATUS_READ_OPEN" -eq 1 ]; then
    exec 4<&-
    BUILD_STATUS_READ_OPEN=0
  fi
}

runner_result_confirms_drain() {
  case "$1" in
    drained:*) return 0 ;;
  esac
  return 1
}

runner_result_matches_exit() {
  local result=$1 actual=$2 expected
  case "$result" in
    drained:exit:*) expected=${result#drained:exit:} ;;
    drained:signal:*)
      expected=${result#drained:signal:}
      case "$expected" in ''|*[!0-9]*) return 1 ;; esac
      expected=$((128 + expected))
      ;;
    drained:timeout:*|drained:error:*|undrained:pids=*|undrained:lineage=*) expected=125 ;;
    *) return 1 ;;
  esac
  case "$expected" in ''|*[!0-9]*) return 1 ;; esac
  [ "$actual" -eq "$expected" ]
}

runner_result_survivors() {
  case "$1" in
    undrained:pids=*) printf '%s\n' "${1#undrained:pids=}" ;;
    undrained:lineage=*) printf '%s\n' "${1#undrained:lineage=}" ;;
    *) printf '%s\n' unknown ;;
  esac
}

capture_interrupted_runner() {
  local read_rc=1
  [ -n "$BUILD_PID" ] || return 0
  kill -TERM "$BUILD_PID" 2>/dev/null || true
  if wait "$BUILD_PID"; then
    BUILD_RUNNER_RC=0
  else
    BUILD_RUNNER_RC=$?
  fi
  BUILD_PID=
  if [ "$BUILD_STATUS_WRITE_OPEN" -eq 1 ]; then
    exec 3>&-
    BUILD_STATUS_WRITE_OPEN=0
  fi
  if [ "$BUILD_STATUS_READ_OPEN" -eq 1 ]; then
    if IFS= read -r BUILD_RUNNER_RESULT <&4; then
      read_rc=0
    fi
    exec 4<&-
    BUILD_STATUS_READ_OPEN=0
  fi
  if [ "$read_rc" -eq 0 ] \
     && runner_result_confirms_drain "$BUILD_RUNNER_RESULT" \
     && runner_result_matches_exit "$BUILD_RUNNER_RESULT" "$BUILD_RUNNER_RC"; then
    BUILD_DRAIN_CONFIRMED=1
  else
    BUILD_DRAIN_CONFIRMED=0
  fi
}

update_sidecar_fields() {
  local tmp="$STATE/.$VERIFY_ID.verify.$$" key
  [ -f "$VERIFY_SIDECAR" ] || return 1
  cp "$VERIFY_SIDECAR" "$tmp" || return 1
  while [ "$#" -gt 0 ]; do
    key=${1%%=*}
    if ! awk -v key="$key" 'index($0, key "=") != 1' "$tmp" > "$tmp.next"; then
      rm -f "$tmp" "$tmp.next"
      return 1
    fi
    printf '%s\n' "$1" >> "$tmp.next" || { rm -f "$tmp" "$tmp.next"; return 1; }
    mv "$tmp.next" "$tmp" || { rm -f "$tmp" "$tmp.next"; return 1; }
    shift
  done
  mv "$tmp" "$VERIFY_SIDECAR"
}

retain_build_cleanup_record() {
  local survivors=${1:-}
  if [ -z "$survivors" ] && [ "$BUILD_RUNNER_STARTED" -eq 1 ] && [ "$BUILD_DRAIN_CONFIRMED" -ne 1 ]; then
    survivors=$(runner_result_survivors "$BUILD_RUNNER_RESULT")
  fi
  KEEP_BINDING=1
  update_sidecar_fields "build_cleanup_path=$BUILD_DIR" \
    "build_cleanup_container=$BUILD_CONTAINER" "build_cleanup_pids=$survivors"
}

cleanup_build_worktree() {
  local listed_rc=1 remove_rc=0 prune_rc=0 survivors
  if [ -n "$BUILD_PID" ]; then
    capture_interrupted_runner
  fi
  if [ "$BUILD_RUNNER_STARTED" -eq 1 ] && [ "$BUILD_DRAIN_CONFIRMED" -ne 1 ]; then
    survivors=$(runner_result_survivors "$BUILD_RUNNER_RESULT")
    if ! retain_build_cleanup_record; then
      close_build_status_fds
      echo "BLOCKED: could not durably publish retained build ownership for $BUILD_DIR; surviving pids: $survivors" >&2
      return 1
    fi
    close_build_status_fds
    echo "BLOCKED: detached build worktree retained at $BUILD_DIR because build drain was not confirmed; surviving pids: $survivors" >&2
    echo "       reconcile that exact worktree and those processes before retrying" >&2
    return 1
  fi
  # Build-worktree cleanup is confirmed-or-reported; possible live writers always leave a loud, reconcilable worktree.
  close_build_status_fds
  if [ -z "$BUILD_DIR" ]; then
    [ -n "$BUILD_CONTAINER" ] || return 0
    if ! rm -rf -- "$BUILD_CONTAINER" || [ -e "$BUILD_CONTAINER" ] || [ -L "$BUILD_CONTAINER" ]; then
      retain_build_cleanup_record "" || echo "BLOCKED: could not durably publish retained build-container ownership for $BUILD_CONTAINER" >&2
      echo "BLOCKED: detached build worktree container remains at $BUILD_CONTAINER; reconcile that exact path before retrying" >&2
      return 1
    fi
    BUILD_CONTAINER=
    return 0
  fi
  if worktree_path_listed; then
    listed_rc=0
  else
    listed_rc=$?
  fi
  if [ "$listed_rc" -eq 2 ]; then
    retain_build_cleanup_record "" || echo "BLOCKED: could not durably publish retained build ownership for $BUILD_DIR" >&2
    echo "BLOCKED: could not inspect detached build worktrees while cleaning $BUILD_DIR; reconcile that path before retrying" >&2
    return 1
  fi
  if [ "$listed_rc" -eq 0 ]; then
    git -C "$PROJECT" worktree remove --force "$BUILD_DIR" >/dev/null 2>&1 || remove_rc=$?
  elif [ -d "$BUILD_DIR" ] || [ -L "$BUILD_DIR" ]; then
    rmdir "$BUILD_DIR" >/dev/null 2>&1 || remove_rc=$?
  fi
  git -C "$PROJECT" worktree prune >/dev/null 2>&1 || prune_rc=$?
  if worktree_path_listed; then
    listed_rc=0
  else
    listed_rc=$?
  fi
  if [ "$remove_rc" -ne 0 ] || [ "$prune_rc" -ne 0 ] || [ "$listed_rc" -ne 1 ] \
     || [ -e "$BUILD_DIR" ] || [ -L "$BUILD_DIR" ]; then
    retain_build_cleanup_record "" || echo "BLOCKED: could not durably publish retained build ownership for $BUILD_DIR" >&2
    echo "BLOCKED: detached build worktree cleanup could not be confirmed for $BUILD_DIR; reconcile that exact path and its git worktree record before retrying" >&2
    return 1
  fi
  if [ -n "$BUILD_CONTAINER" ]; then
    if ! rm -rf -- "$BUILD_CONTAINER" || [ -e "$BUILD_CONTAINER" ] || [ -L "$BUILD_CONTAINER" ]; then
      retain_build_cleanup_record "" || echo "BLOCKED: could not durably publish retained build-container ownership for $BUILD_CONTAINER" >&2
      echo "BLOCKED: detached build worktree container remains at $BUILD_CONTAINER; reconcile that exact path before retrying" >&2
      return 1
    fi
  fi
  BUILD_CONTAINER=
  BUILD_DIR=
  BUILD_DIR_REAL=
  BUILD_RUNNER_STARTED=0
  BUILD_DRAIN_CONFIRMED=1
}

remove_unpublished_neutral_directory() {
  local target=$1 current_identity
  [ -n "$target" ] || return 0
  current_identity=$(fm_pr_file_identity "$target") || {
    echo "BLOCKED: neutral verifier directory identity could not be read for $target; verifier binding was retained for reconciliation" >&2
    return 1
  }
  if [ -z "$NEUTRAL_IDENTITY" ] || [ "$current_identity" != "$NEUTRAL_IDENTITY" ]; then
    echo "BLOCKED: neutral verifier directory identity no longer matches for $target; verifier binding was retained for reconciliation" >&2
    return 1
  fi
  if ! rm -rf -- "$target" || [ -e "$target" ] || [ -L "$target" ]; then
    echo "BLOCKED: neutral verifier directory removal could not be confirmed for $target; verifier binding and metadata were retained for reconciliation" >&2
    return 1
  fi
}

verify_exit_cleanup() {
  local status=$?
  [ "$CAPACITY_LOCK_HELD" -eq 0 ] || { CAPACITY_LOCK_HELD=0; fm_lock_release "$CAPACITY_LOCK" || true; }
  cleanup_build_worktree || status=1
  if [ ! -e "$VERIFY_META" ]; then
    if [ "$RETAIN_NEUTRAL" -eq 1 ]; then
      KEEP_BINDING=1
      status=1
    elif [ "$SPAWN_ATTEMPTED" -eq 1 ] && [ "$SPAWN_ENDPOINT_UNCERTAIN" -eq 1 ]; then
      KEEP_BINDING=1
      status=1
    elif remove_unpublished_neutral_directory "$NEUTRAL_DIR"; then
      NEUTRAL_DIR=
      [ "$KEEP_BINDING" -eq 1 ] || verify_rollback
    else
      status=1
    fi
  fi
  return "$status"
}

handle_verification_signal() {
  local code=$1
  if [ "$SIGNAL_CRITICAL" -eq 1 ]; then
    PENDING_SIGNAL=$code
    if [ "$SIGNAL_CRITICAL_KIND" = neutral ]; then
      RETAIN_NEUTRAL=1
      KEEP_BINDING=1
    fi
    return 0
  fi
  exit "$code"
}

finish_signal_critical_section() {
  SIGNAL_CRITICAL=0
  SIGNAL_CRITICAL_KIND=
  [ "$PENDING_SIGNAL" -eq 0 ] || exit "$PENDING_SIGNAL"
}

trap verify_exit_cleanup EXIT
trap 'handle_verification_signal 130' INT
trap 'handle_verification_signal 143' TERM
trap 'handle_verification_signal 129' HUP

promise_digest() {
  printf 'sha256:%s\n' "$(printf '%s' "$PROMISE" | sha256_hex)"
}

write_sidecar() {
  local tmp="$STATE/.$VERIFY_ID.verify.$$"
  {
    echo "verifies=$SHIP_ID"
    echo "rev=$REV"
    echo "rev_source=$REV_SOURCE"
    echo "project=$PROJECT"
    echo "promise=$(promise_digest)"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "reservation_pid=$$"
  } > "$tmp" && mv "$tmp" "$VERIFY_SIDECAR"
}

remove_sidecar_fields() {
  local pattern=$1
  local tmp="$STATE/.$VERIFY_ID.verify.$$" grep_rc
  [ -f "$VERIFY_SIDECAR" ] || return 1
  if ! awk -v pattern="$pattern" '$0 !~ pattern' "$VERIFY_SIDECAR" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv "$tmp" "$VERIFY_SIDECAR"; then
    rm -f "$tmp"
    return 1
  fi
  if grep -Eq "$pattern" "$VERIFY_SIDECAR"; then
    return 1
  else
    grep_rc=$?
  fi
  [ "$grep_rc" -eq 1 ]
}

clear_reservation() {
  remove_sidecar_fields '^reservation_pid='
}

mark_endpoint_uncertain() {
  update_sidecar_fields "endpoint_uncertain=1"
}

clear_spawn_handoff() {
  remove_sidecar_fields '^(reservation_pid|endpoint_uncertain)='
}

mkdir -p "$STATE"
fm_lock_acquire_wait "$CAPACITY_LOCK"
CAPACITY_LOCK_HELD=1
if [ -e "$VERIFY_META" ] || [ -e "$VERIFY_BRIEF" ] || [ -e "$VERIFY_REPORT" ]; then
  echo "error: verifier task id '$VERIFY_ID' became unavailable while reserving it" >&2
  exit 1
fi
if [ -n "$VERIFY_SIDECAR_IDENTITY" ]; then
  CURRENT_SIDECAR_IDENTITY=$(fm_pr_file_identity "$VERIFY_SIDECAR" 2>/dev/null || true)
  if [ "$CURRENT_SIDECAR_IDENTITY" != "$VERIFY_SIDECAR_IDENTITY" ]; then
    echo "error: verifier task id '$VERIFY_ID' became unavailable while reserving it" >&2
    exit 1
  fi
elif [ -e "$VERIFY_SIDECAR" ]; then
  echo "error: verifier task id '$VERIFY_ID' became unavailable while reserving it" >&2
  exit 1
fi
LIVE=$(live_verifications)
if [ "$LIVE" -ge "$MAX_CONCURRENT" ]; then
  CAPACITY_LOCK_HELD=0
  fm_lock_release "$CAPACITY_LOCK"
  capacity_refusal "$LIVE"
  exit 1
fi
write_sidecar || { echo "error: could not publish verification binding at $VERIFY_SIDECAR" >&2; exit 1; }
CREATED_SIDECAR=1
CAPACITY_LOCK_HELD=0
fm_lock_release "$CAPACITY_LOCK"

record_build_result() {
  local reason=$1
  [ -d "$VERIFY_DATA_DIR" ] || { mkdir -p "$VERIFY_DATA_DIR"; CREATED_DATA_DIR=1; }
  cat > "$VERIFY_REPORT" <<EOF
# Verdict
not delivered
The configured build did not produce the runnable artifact required for verification.

# Claim by claim
No promise claim was exercised because no runnable artifact was produced.

# Looks finished but is not
The change did not produce the configured runnable artifact.

# What I could not test, and why
$reason

# Independence attestation
No verifier was spawned and no implementation material was supplied to one.

# Simulator hygiene
Created 0, deleted 0, remaining 0.
EOF
  printf 'done: not delivered - does not build\n' > "$STATE/$VERIFY_ID.status"
  clear_reservation
  KEEP_BINDING=1
  echo "verification result for '$SHIP_ID': not delivered - does not build: $reason" >&2
}

# shellcheck disable=SC2016  # single quotes are deliberate: these are Perl program texts whose $variables must reach perl unexpanded, not shell expansions.
run_build_with_timeout() {
  exec "$PERL_BIN" -MCwd=abs_path -MFcntl=F_GETFD,F_SETFD,FD_CLOEXEC,F_GETFL,F_SETFL,O_NONBLOCK -MErrno=EAGAIN,EWOULDBLOCK -MFile::Temp=tempfile -MPOSIX=WNOHANG -e '
    $timeout = shift @ARGV;
    $ps_bin = shift @ARGV;
    $lsof_bin = shift @ARGV;
    $runner_started = time;
    $publish = sub {
      $value = shift;
      print STDOUT "$value\n" or return 0;
      close(STDOUT) or return 0;
      return 1;
    };
    $status_flags = fcntl(STDOUT, F_GETFD, 0);
    defined($status_flags) && fcntl(STDOUT, F_SETFD, $status_flags | FD_CLOEXEC)
      or do { $publish->("error:status-channel:$!"); exit 125; };
    pipe($read_pipe, $write_pipe) or do { $publish->("drained:error:exec-channel:$!"); exit 125; };
    pipe($ready_read, $ready_write) or do { $publish->("drained:error:ready-channel:$!"); exit 125; };
    ($lineage_file, $lineage_path) = tempfile("fm-verify-lineage.XXXXXX", TMPDIR => 1, UNLINK => 1);
    defined($lineage_file) or do { $publish->("drained:error:lineage-channel:$!"); exit 125; };
    @lineage_stat = stat($lineage_file);
    @lineage_stat or do { $publish->("drained:error:lineage-channel:$!"); exit 125; };
    unlink($lineage_path) or do { $publish->("drained:error:lineage-channel:$!"); exit 125; };
    $lineage_fd = fileno($lineage_file);
    $lineage_flags = fcntl($lineage_file, F_GETFD, 0);
    defined($lineage_flags) && fcntl($lineage_file, F_SETFD, $lineage_flags & ~FD_CLOEXEC)
      or do { $publish->("drained:error:lineage-channel:$!"); exit 125; };
    $lineage_device = $lineage_stat[0];
    $lineage_inode = $lineage_stat[1];
    $runner_uid = $<;
    $build_root = abs_path(".");
    defined($build_root) or do { $publish->("drained:error:build-root:$!"); exit 125; };
    @build_root_stat = stat($build_root);
    @build_root_stat or do { $publish->("drained:error:build-root:$!"); exit 125; };
    $flags = fcntl($write_pipe, F_GETFD, 0);
    defined($flags) && fcntl($write_pipe, F_SETFD, $flags | FD_CLOEXEC)
      or do { $publish->("drained:error:exec-channel:$!"); exit 125; };
    $pid = fork();
    defined($pid) or do { $publish->("drained:error:fork:$!"); exit 125; };
    if ($pid == 0) {
      close($read_pipe);
      close($ready_write);
      setpgrp(0, 0) or do {
        print $write_pipe "setpgrp:$!\n";
        close($write_pipe);
        exit 125;
      };
      open(STDOUT, ">&", STDERR) or do {
        print $write_pipe "stdout:$!\n";
        close($write_pipe);
        exit 125;
      };
      $exec_fd = fileno($write_pipe);
      $ready_fd = fileno($ready_read);
      opendir($fd_dir, "/dev/fd") or do {
        print $write_pipe "fd-scan:$!\n";
        close($write_pipe);
        exit 125;
      };
      @open_fds = grep { /^\d+$/ } readdir($fd_dir);
      closedir($fd_dir);
      for $fd (@open_fds) {
        next if $fd < 3;
        next if $fd == $exec_fd;
        next if $fd == $ready_fd;
        next if $fd == $lineage_fd;
        POSIX::close($fd);
      }
      $ready_count = sysread($ready_read, $ready_value, 1);
      if (!defined($ready_count) || $ready_count != 1 || $ready_value ne "1") {
        print $write_pipe "readiness:$!\n";
        close($write_pipe);
        exit 125;
      }
      close($ready_read);
      select undef, undef, undef, 0.05;
      exec @ARGV;
      print $write_pipe "exec:$!\n";
      close($write_pipe);
      exit 127;
    }
    close($write_pipe);
    close($ready_read);
    close($lineage_file);
    $leader_reaped = 0;
    $leader_status = 0;
    $lineage_scanned = 0;
    $lineage_scan_rounds = 0;
    %tracked_start = ();
    %escaped_seen = ();
    %baseline_start = ();
    $reap_leader = sub {
      return 1 if $leader_reaped;
      $reaped = waitpid($pid, WNOHANG);
      if ($reaped == $pid) {
        $leader_status = $?;
        $leader_reaped = 1;
        return 1;
      }
      return 1 if $reaped == 0;
      return 0;
    };
    $snapshot = sub {
      open($ps, "-|", $ps_bin, "-axo", "pid=,ppid=,pgid=,uid=,state=,etime=,lstart=")
        or return (undef, "ps:$!");
      %processes = ();
      while ($line = <$ps>) {
        if ($line =~ /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(.+?)\s*$/) {
          $elapsed_text = $6;
          $days = 0;
          if ($elapsed_text =~ s/^(\d+)-//) {
            $days = $1;
          }
          @elapsed_parts = split /:/, $elapsed_text;
          $elapsed = 0;
          for $elapsed_part (@elapsed_parts) {
            $elapsed = $elapsed * 60 + $elapsed_part;
          }
          $elapsed += $days * 86400;
          $processes{$1} = { ppid => $2, pgid => $3, uid => $4, state => $5, elapsed => $elapsed, start => $7 };
        }
      }
      close($ps) or return (undef, "ps-exit");
      return (\%processes, "");
    };
    $scan_lineage = sub {
      $lineage_matches = 0;
      %lineage_seen_pids = ();
      $lineage_pid = "";
      $lineage_record_fd = "";
      $lineage_record_device = "";
      $lineage_record_inode = "";
      $lineage_record_type = "";
      $lineage_max_age = time - $runner_started + 3;
      @lineage_candidates = grep { $processes{$_}->{elapsed} <= $lineage_max_age } keys %processes;
      return "" unless @lineage_candidates;
      $accept_lineage_record = sub {
        return unless $lineage_pid =~ /^\d+$/;
        return unless $lineage_record_fd =~ /^\d+$/ && $lineage_record_fd == $lineage_fd;
        return unless $lineage_record_type eq "REG";
        return unless $lineage_record_device ne "" && $lineage_record_device == $lineage_device;
        return unless $lineage_record_inode =~ /^\d+$/ && $lineage_record_inode == $lineage_inode;
        $lineage_matches++;
        $lineage_seen_pids{$lineage_pid} = 1;
      };
      open($lineage_lsof, "-|", $lsof_bin, "-n", "-P", "-a", "-p", join(",", @lineage_candidates), "-d", $lineage_fd, "-F", "pDift")
        or return "lsof:$!";
      while ($line = <$lineage_lsof>) {
        chomp($line);
        if ($line =~ /^p(\d+)$/) {
          $accept_lineage_record->();
          $lineage_pid = $1;
          $lineage_record_fd = "";
          $lineage_record_device = "";
          $lineage_record_inode = "";
          $lineage_record_type = "";
        } elsif ($line =~ /^f(\d+)/) {
          $lineage_record_fd = $1;
        } elsif ($line =~ /^D(0x[0-9a-fA-F]+|\d+)$/) {
          $lineage_device_value = $1;
          $lineage_record_device = $lineage_device_value =~ /^0x/ ? hex($lineage_device_value) : $lineage_device_value;
        } elsif ($line =~ /^i(\d+)$/) {
          $lineage_record_inode = $1;
        } elsif ($line =~ /^t(.+)$/) {
          $lineage_record_type = $1;
        }
      }
      $accept_lineage_record->();
      close($lineage_lsof);
      $lineage_lsof_status = $? >> 8;
      return "lsof-exit:$lineage_lsof_status" unless $lineage_lsof_status == 0 || $lineage_lsof_status == 1;
      return "";
    };
    $refresh_descendants = sub {
      ($processes, $snapshot_error) = $snapshot->();
      return (undef, $snapshot_error) unless defined($processes);
      if ($leader_reaped && !$lineage_scanned) {
        if ($lineage_scan_rounds == 0) {
          select undef, undef, undef, 0.05;
          ($processes, $snapshot_error) = $snapshot->();
          return (undef, $snapshot_error) unless defined($processes);
        }
        $lineage_error = $scan_lineage->();
        return (undef, $lineage_error) if length($lineage_error);
        if ($lineage_matches > 0) {
          ($processes, $snapshot_error) = $snapshot->();
          return (undef, $snapshot_error) unless defined($processes);
          for $lineage_pid (keys %lineage_seen_pids) {
            next unless exists($processes->{$lineage_pid});
            $tracked_start{$lineage_pid} = $processes->{$lineage_pid}->{start};
            if ($lineage_pid != $pid && $processes->{$lineage_pid}->{pgid} != $pid) {
              $escaped_seen{$lineage_pid} = $processes->{$lineage_pid}->{start};
            }
          }
        }
        $lineage_scan_rounds++;
        $lineage_scanned = 1 if $lineage_matches == 0 || $lineage_scan_rounds >= 3;
      }
      if (exists($processes->{$pid}) && !exists($tracked_start{$pid})) {
        $tracked_start{$pid} = $processes->{$pid}->{start};
      }
      $changed = 1;
      while ($changed) {
        $changed = 0;
        for $candidate (keys %{$processes}) {
          next if $candidate == $$;
          $entry = $processes->{$candidate};
          $parent = $entry->{ppid};
          $parent_tracked = exists($tracked_start{$parent})
            && exists($processes->{$parent})
            && $processes->{$parent}->{start} eq $tracked_start{$parent};
          $belongs = $entry->{pgid} == $pid || $parent == $pid || $parent_tracked;
          next unless $belongs;
          if (!exists($tracked_start{$candidate}) || $tracked_start{$candidate} ne $entry->{start}) {
            $tracked_start{$candidate} = $entry->{start};
            $changed = 1;
          }
          if ($candidate != $pid && $entry->{pgid} != $pid) {
            $escaped_seen{$candidate} = $entry->{start};
          }
        }
      }
      @live = ();
      for $candidate (keys %tracked_start) {
        next unless exists($processes->{$candidate});
        $entry = $processes->{$candidate};
        next unless $entry->{start} eq $tracked_start{$candidate};
        next if $entry->{state} =~ /^Z/;
        push @live, $candidate;
      }
      return (\@live, "");
    };
    $wait_all_gone = sub {
      $attempts = shift;
      for (1 .. $attempts) {
        $reap_leader->() or return (0, "wait:$!");
        ($live, $refresh_error) = $refresh_descendants->();
        return (0, $refresh_error) unless defined($live);
        return (1, "") unless @{$live};
        select undef, undef, undef, 0.05;
      }
      ($live, $refresh_error) = $refresh_descendants->();
      return (0, $refresh_error) unless defined($live);
      return (1, "") unless @{$live};
      return (0, join(",", sort { $a <=> $b } @{$live}));
    };
    $unaccounted_lineage = sub {
      ($processes, $snapshot_error) = $snapshot->();
      return (undef, $snapshot_error) unless defined($processes);
      $lineage_max_age = time - $runner_started + 3;
      @unaccounted_candidates = ();
      for $candidate (keys %{$processes}) {
        $entry = $processes->{$candidate};
        next unless $entry->{uid} == $runner_uid;
        next unless $entry->{ppid} == 1;
        next unless $entry->{elapsed} <= $lineage_max_age;
        next if $entry->{state} =~ /^Z/;
        next if exists($baseline_start{$candidate}) && $baseline_start{$candidate} eq $entry->{start};
        next if exists($tracked_start{$candidate}) && $tracked_start{$candidate} eq $entry->{start};
        push @unaccounted_candidates, $candidate;
      }
      return ([], "") unless @unaccounted_candidates;
      $path_inside_build = sub {
        $current = abs_path(shift);
        return 0 unless defined($current);
        while (1) {
          @current_stat = stat($current);
          return 0 unless @current_stat;
          return 1 if $current_stat[0] == $build_root_stat[0] && $current_stat[1] == $build_root_stat[1];
          $parent = abs_path("$current/..");
          return 0 unless defined($parent);
          @parent_stat = stat($parent);
          return 0 unless @parent_stat;
          return 0 if $parent_stat[0] == $current_stat[0] && $parent_stat[1] == $current_stat[1];
          $current = $parent;
        }
      };
      %candidate_pid = map { $_ => 1 } @unaccounted_candidates;
      %unaccounted_pid = ();
      $cwd_pid = "";
      open($cwd_lsof, "-|", $lsof_bin, "-n", "-P", "-a", "-p", join(",", @unaccounted_candidates), "-d", "cwd", "-F", "pn")
        or return (undef, "lsof:$!");
      while ($line = <$cwd_lsof>) {
        chomp($line);
        if ($line =~ /^p(\d+)$/) {
          $cwd_pid = $1;
        } elsif ($line =~ /^n(.+)$/ && exists($candidate_pid{$cwd_pid}) && $path_inside_build->($1)) {
          $unaccounted_pid{$cwd_pid} = 1;
        }
      }
      close($cwd_lsof);
      $cwd_lsof_status = $? >> 8;
      return (undef, "lsof-exit:$cwd_lsof_status") unless $cwd_lsof_status == 0 || $cwd_lsof_status == 1;
      @unaccounted = keys %unaccounted_pid;
      return (\@unaccounted, "");
    };
    $terminate_all = sub {
      ($live, $refresh_error) = $refresh_descendants->();
      return (0, $refresh_error) unless defined($live);
      return (1, "") unless @{$live};
      kill "TERM", -$pid;
      kill "TERM", @{$live};
      ($drained, $detail) = $wait_all_gone->(20);
      return (1, "") if $drained;
      return (0, $detail) if $detail =~ /^(?:ps:|ps-exit|wait:)/;
      kill "KILL", -$pid;
      ($live, $refresh_error) = $refresh_descendants->();
      return (0, $refresh_error) unless defined($live);
      kill "KILL", @{$live} if @{$live};
      return $wait_all_gone->(40);
    };
    $stop = sub {
      $result = shift;
      $SIG{ALRM} = $SIG{TERM} = $SIG{INT} = $SIG{HUP} = "IGNORE";
      alarm 0;
      ($drained, $detail) = $terminate_all->();
      if (!$leader_reaped) {
        $waited = waitpid($pid, 0);
        $leader_reaped = 1 if $waited == $pid;
      }
      if (!$drained || !$leader_reaped) {
        $detail = "leader-not-reaped" if !$leader_reaped;
        $publish->("undrained:pids=$detail") or exit 125;
        exit 125;
      }
      ($unaccounted, $lineage_error) = $unaccounted_lineage->();
      if (!defined($unaccounted)) {
        $publish->("undrained:pids=$lineage_error") or exit 125;
        exit 125;
      }
      if (@{$unaccounted}) {
        $publish->("undrained:lineage=" . join(",", sort { $a <=> $b } @{$unaccounted})) or exit 125;
        exit 125;
      }
      $publish->("drained:$result") or exit 125;
      exit 125;
    };
    $SIG{ALRM} = sub { $stop->("timeout:$timeout") };
    $SIG{TERM} = sub { $stop->("error:interrupted:TERM") };
    $SIG{INT} = sub { $stop->("error:interrupted:INT") };
    $SIG{HUP} = sub { $stop->("error:interrupted:HUP") };
    alarm $timeout;
    ($live, $refresh_error) = $refresh_descendants->();
    $stop->("error:$refresh_error") unless defined($live);
    $stop->("error:readiness-leader-missing") unless exists($tracked_start{$pid});
    for $candidate (keys %{$processes}) {
      next unless $processes->{$candidate}->{uid} == $runner_uid;
      $baseline_start{$candidate} = $processes->{$candidate}->{start};
    }
    $read_flags = fcntl($read_pipe, F_GETFL, 0);
    defined($read_flags) && fcntl($read_pipe, F_SETFL, $read_flags | O_NONBLOCK)
      or $stop->("error:exec-channel:$!");
    print $ready_write "1" or $stop->("error:ready-channel:$!");
    close($ready_write) or $stop->("error:ready-channel:$!");
    $exec_ready = 0;
    $exec_error = "";
    while (!$exec_ready) {
      ($live, $refresh_error) = $refresh_descendants->();
      $stop->("error:$refresh_error") unless defined($live);
      $read_count = sysread($read_pipe, $exec_chunk, 4096);
      if (defined($read_count)) {
        if ($read_count == 0) {
          $exec_ready = 1;
        } else {
          $exec_error .= $exec_chunk;
        }
      } elsif ($! != EAGAIN && $! != EWOULDBLOCK) {
        $stop->("error:exec-channel:$!");
      }
      $reap_leader->() or $stop->("error:wait:$!");
      select undef, undef, undef, 0.001 unless $exec_ready;
    }
    close($read_pipe);
    if (length($exec_error)) {
      $exec_error =~ s/[\r\n]+/ /g;
      $stop->("error:$exec_error");
    }
    while (!$leader_reaped) {
      ($live, $refresh_error) = $refresh_descendants->();
      if (!defined($live)) {
        $stop->("error:$refresh_error");
      }
      $reap_leader->() or $stop->("error:wait:$!");
      select undef, undef, undef, 0.02 unless $leader_reaped;
    }
    alarm 0;
    ($live, $refresh_error) = $refresh_descendants->();
    $stop->("error:$refresh_error") unless defined($live);
    ($drained, $detail) = $terminate_all->();
    if (!$drained) {
      $publish->("undrained:pids=$detail") or exit 125;
      exit 125;
    }
    ($unaccounted, $lineage_error) = $unaccounted_lineage->();
    if (!defined($unaccounted)) {
      $publish->("undrained:pids=$lineage_error") or exit 125;
      exit 125;
    }
    if (@{$unaccounted}) {
      $publish->("undrained:lineage=" . join(",", sort { $a <=> $b } @{$unaccounted})) or exit 125;
      exit 125;
    }
    if (keys %escaped_seen) {
      $escaped = join(",", sort { $a <=> $b } keys %escaped_seen);
      $publish->("drained:error:escaped-descendants:$escaped") or exit 125;
      exit 125;
    }
    $status = $leader_status;
    if (($status & 127) != 0) {
      $signal = $status & 127;
      $publish->("drained:signal:$signal") or exit 125;
      exit(128 + $signal);
    }
    $exit_code = $status >> 8;
    $publish->("drained:exit:$exit_code") or exit 125;
    exit($exit_code);
  ' "$BUILD_TIMEOUT" "$PS_BIN" "$LSOF_BIN" /bin/bash -lc "$BUILD_CMD"
}

# shellcheck disable=SC2016  # single quotes are deliberate: these are Perl program texts whose $variables must reach perl unexpanded, not shell expansions.
resolve_existing_path() {
  "$PERL_BIN" -MCwd=abs_path -e '$path = abs_path($ARGV[0]); defined $path or exit 1; print $path' "$1"
}

path_resolves_inside() {
  local candidate=$1 root=$2
  case "$candidate" in
    "$root"|"$root"/*) return 0 ;;
  esac
  return 1
}

# shellcheck disable=SC2016  # single quotes are deliberate: these are Perl program texts whose $variables must reach perl unexpanded, not shell expansions.
path_components_stay_inside() {
  local root=$1 relative=$2
  "$PERL_BIN" -MCwd=abs_path -e '
    $root = abs_path(shift @ARGV); defined $root or exit 2;
    $relative = shift @ARGV; $current = $root;
    for $component (split m{/+}, $relative) {
      $current .= "/$component";
      last unless -e $current || -l $current;
      $resolved = abs_path($current);
      if (!defined $resolved) { print $current; exit 2; }
      if ($resolved ne $root && index($resolved, "$root/") != 0) { print $resolved; exit 1; }
    }
  ' "$root" "$relative"
}

neutral_symlinks_stay_inside() {
  local link resolved
  while IFS= read -r -d '' link; do
    resolved=$(resolve_existing_path "$link") || {
      echo "BLOCKED: copied artifact contains an unresolved symbolic link: $link" >&2
      return 1
    }
    if ! path_resolves_inside "$resolved" "$NEUTRAL_DIR"; then
      echo "BLOCKED: copied artifact symbolic link escapes the neutral directory: $link -> $resolved" >&2
      return 1
    fi
  done < <(find "$NEUTRAL_DIR" -type l -print0)
}

PERL_BIN=$(command -v perl 2>/dev/null || true)
PS_BIN=${FM_VERIFY_PS_OVERRIDE:-/bin/ps}
LSOF_BIN=${FM_VERIFY_LSOF_OVERRIDE:-$(command -v lsof 2>/dev/null || true)}
if [ -z "$PERL_BIN" ] || [ ! -x "$PERL_BIN" ] \
   || ! "$PERL_BIN" -MFcntl=F_GETFD,F_SETFD,FD_CLOEXEC,F_GETFL,F_SETFL,O_NONBLOCK -MErrno=EAGAIN,EWOULDBLOCK -MFile::Temp=tempfile -MCwd=abs_path -e 'exit 0' >/dev/null 2>&1 \
   || [ ! -x /bin/bash ] || [ ! -x "$PS_BIN" ] || [ ! -x "$LSOF_BIN" ]; then
  echo "BLOCKED: the build runner is missing or unusable; no product verdict was recorded" >&2
  exit 1
fi

BUILD_CONTAINER=$(mktemp -d "${TMPDIR:-/tmp}/fm-verify-build.XXXXXX") || {
  echo "BLOCKED: could not allocate a detached build-worktree container" >&2
  exit 1
}
BUILD_CONTAINER=$(CDPATH='' cd -- "$BUILD_CONTAINER" && pwd -P) || {
  echo "BLOCKED: could not canonicalize the detached build-worktree container" >&2
  exit 1
}
BUILD_DIR="$BUILD_CONTAINER/worktree"
BUILD_DIR_REAL="$BUILD_DIR"
SIGNAL_CRITICAL=1
SIGNAL_CRITICAL_KIND=neutral
NEUTRAL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-verify-artifacts.XXXXXX") || {
  echo "BLOCKED: could not allocate a neutral artifact directory" >&2
  exit 1
}
if ! printf 'neutral_cleanup_path=%s\n' "$NEUTRAL_DIR" >> "$VERIFY_SIDECAR" \
   || [ "$(fm_meta_get "$VERIFY_SIDECAR" neutral_cleanup_path)" != "$NEUTRAL_DIR" ]; then
  if rmdir "$NEUTRAL_DIR" 2>/dev/null && [ ! -e "$NEUTRAL_DIR" ]; then
    NEUTRAL_DIR=
  fi
  echo "BLOCKED: could not immediately publish neutral-directory ownership for ${NEUTRAL_DIR:-the removed allocation}" >&2
  exit 1
fi
NEUTRAL_IDENTITY=$(fm_pr_file_identity "$NEUTRAL_DIR") || {
  echo "BLOCKED: could not bind the neutral artifact directory identity at $NEUTRAL_DIR" >&2
  exit 1
}
if ! printf 'neutral_cleanup_identity=%s\n' "$NEUTRAL_IDENTITY" >> "$VERIFY_SIDECAR" \
   || [ "$(fm_meta_get "$VERIFY_SIDECAR" neutral_cleanup_identity)" != "$NEUTRAL_IDENTITY" ]; then
  echo "BLOCKED: could not immediately publish neutral-directory identity for $NEUTRAL_DIR" >&2
  exit 1
fi
finish_signal_critical_section
NEUTRAL_DIR=$(CDPATH='' cd -- "$NEUTRAL_DIR" && pwd -P)
mkdir -p "$NEUTRAL_DIR/artifacts" "$NEUTRAL_DIR/scratch" || {
  echo "BLOCKED: could not prepare the neutral artifact directory at $NEUTRAL_DIR" >&2
  exit 1
}
update_sidecar_fields "neutral_cleanup_path=$NEUTRAL_DIR" "neutral_cleanup_identity=$NEUTRAL_IDENTITY" || {
  echo "BLOCKED: could not durably bind the neutral artifact directory at $NEUTRAL_DIR" >&2
  exit 1
}

if ! git -C "$PROJECT" worktree add --quiet --detach "$BUILD_DIR" "$REV"; then
  FAILED_BUILD_DIR=$BUILD_DIR
  cleanup_build_worktree || true
  echo "BLOCKED: could not create detached build worktree at $FAILED_BUILD_DIR; no product verdict was recorded" >&2
  exit 1
fi
BUILD_DIR_REAL=$(CDPATH='' cd -- "$BUILD_DIR" && pwd -P) || {
  echo "BLOCKED: could not resolve detached build worktree at $BUILD_DIR" >&2
  exit 1
}
RUNNER_RESULT=
RUNNER_READ_RC=1
RUNNER_STATUS_PATH=$(mktemp "$BUILD_CONTAINER/.runner-status.XXXXXX") || {
  echo "BLOCKED: could not establish the private build-runner status channel" >&2
  exit 1
}
if ! exec 3<> "$RUNNER_STATUS_PATH" || ! exec 4< "$RUNNER_STATUS_PATH"; then
  rm -f -- "$RUNNER_STATUS_PATH" || true
  echo "BLOCKED: could not establish the private build-runner status channel" >&2
  exit 1
fi
BUILD_STATUS_WRITE_OPEN=1
BUILD_STATUS_READ_OPEN=1
if ! rm -f -- "$RUNNER_STATUS_PATH" || [ -e "$RUNNER_STATUS_PATH" ] || [ -L "$RUNNER_STATUS_PATH" ]; then
  close_build_status_fds
  echo "BLOCKED: could not make the build-runner status channel private" >&2
  exit 1
fi
RUNNER_STATUS_PATH=
SIGNAL_CRITICAL=1
SIGNAL_CRITICAL_KIND=runner
BUILD_RUNNER_STARTED=1
BUILD_DRAIN_CONFIRMED=0
(cd "$BUILD_DIR" && run_build_with_timeout) >&3 &
BUILD_PID=$!
exec 3>&-
BUILD_STATUS_WRITE_OPEN=0
finish_signal_critical_section
set +e
wait "$BUILD_PID"
BUILD_RUNNER_RC=$?
set -e
BUILD_PID=
if IFS= read -r RUNNER_RESULT <&4; then
  RUNNER_READ_RC=0
fi
exec 4<&-
BUILD_STATUS_READ_OPEN=0
if [ "$RUNNER_READ_RC" -eq 0 ]; then
  BUILD_RUNNER_RESULT=$RUNNER_RESULT
  if runner_result_confirms_drain "$RUNNER_RESULT" \
     && runner_result_matches_exit "$RUNNER_RESULT" "$BUILD_RUNNER_RC"; then
    BUILD_DRAIN_CONFIRMED=1
  fi
fi
[ "$RUNNER_READ_RC" -eq 0 ] || RUNNER_RESULT=invalid
if [ "$RUNNER_RESULT" != invalid ] \
   && ! runner_result_matches_exit "$RUNNER_RESULT" "$BUILD_RUNNER_RC"; then
  RUNNER_RESULT=invalid
fi
case "$RUNNER_RESULT" in
  drained:exit:*)
    BUILD_RC=${RUNNER_RESULT#drained:exit:}
    case "$BUILD_RC" in ''|*[!0-9]*) RUNNER_RESULT=invalid ;; esac
    ;;
  drained:signal:*)
    BUILD_SIGNAL=${RUNNER_RESULT#drained:signal:}
    case "$BUILD_SIGNAL" in ''|*[!0-9]*) RUNNER_RESULT=invalid ;; esac
    if [ "$RUNNER_RESULT" != invalid ]; then
      BUILD_RC=$((128 + BUILD_SIGNAL))
    fi
    ;;
  drained:timeout:*)
    cleanup_build_worktree || exit 1
    echo "BLOCKED: the build runner exceeded FM_VERIFY_BUILD_TIMEOUT=$BUILD_TIMEOUT seconds; no product verdict was recorded" >&2
    exit 1
    ;;
  drained:error:*)
    cleanup_build_worktree || exit 1
    echo "BLOCKED: the build runner failed before the product could be exercised: ${RUNNER_RESULT#drained:error:}" >&2
    exit 1
    ;;
  undrained:pids=*)
    cleanup_build_worktree || true
    echo "BLOCKED: the build runner could not drain all attributable processes; no product verdict was recorded" >&2
    exit 1
    ;;
  undrained:lineage=*)
    cleanup_build_worktree || true
    echo "BLOCKED: build lineage continuity was lost for surviving pids ${RUNNER_RESULT#undrained:lineage=}; no product verdict was recorded" >&2
    exit 1
    ;;
  *) RUNNER_RESULT=invalid ;;
esac
if [ "$RUNNER_RESULT" = invalid ]; then
  cleanup_build_worktree || exit 1
  echo "BLOCKED: the build runner returned no trustworthy result; no product verdict was recorded" >&2
  exit 1
fi
if [ "$BUILD_RC" -ne 0 ]; then
  cleanup_build_worktree || exit 1
  record_build_result "The configured build command exited with status $BUILD_RC."
  exit 0
fi

ARTIFACT_LIST=
for artifact in "${ARTIFACTS[@]}"; do
  source_path="$BUILD_DIR/$artifact"
  if ! component_result=$(path_components_stay_inside "$BUILD_DIR_REAL" "$artifact"); then
    cleanup_build_worktree || true
    echo "BLOCKED: configured artifact path escapes the detached build worktree: $artifact -> ${component_result:-unresolved component}" >&2
    exit 1
  fi
  if [ ! -e "$source_path" ] && [ ! -L "$source_path" ]; then
    cleanup_build_worktree || exit 1
    record_build_result "The expected artifact '$artifact' was missing."
    exit 0
  fi
  resolved_source=$(resolve_existing_path "$source_path") || {
    cleanup_build_worktree || true
    echo "BLOCKED: configured artifact could not be resolved safely: $artifact" >&2
    exit 1
  }
  if ! path_resolves_inside "$resolved_source" "$BUILD_DIR_REAL"; then
    cleanup_build_worktree || true
    echo "BLOCKED: configured artifact resolves outside the detached build worktree: $artifact -> $resolved_source" >&2
    exit 1
  fi
  destination="$NEUTRAL_DIR/artifacts/$artifact"
  if ! destination_result=$(path_components_stay_inside "$NEUTRAL_DIR" "artifacts/$artifact"); then
    cleanup_build_worktree || true
    echo "BLOCKED: configured artifact destination escapes the neutral directory: $artifact -> ${destination_result:-unresolved component}" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$destination")" || {
    cleanup_build_worktree || true
    echo "BLOCKED: could not prepare the destination for artifact '$artifact'" >&2
    exit 1
  }
  cp -R -p "$source_path" "$destination" || {
    cleanup_build_worktree || true
    echo "BLOCKED: could not copy configured artifact '$artifact' into the neutral directory" >&2
    exit 1
  }
  ARTIFACT_LIST="${ARTIFACT_LIST}- $destination
"
done
if ! neutral_symlinks_stay_inside; then
  cleanup_build_worktree || true
  exit 1
fi
cleanup_build_worktree || exit 1

if find "$NEUTRAL_DIR" \( -name .git -o -name AGENTS.md -o -name CLAUDE.md \) -print -quit | grep -q .; then
  echo "BLOCKED: a configured artifact contained repository or developer-instruction material; no product verdict was recorded" >&2
  exit 1
fi

[ -d "$VERIFY_DATA_DIR" ] || CREATED_DATA_DIR=1
FM_VERIFY_PROMISE=$PROMISE FM_VERIFY_ARTIFACTS=$ARTIFACT_LIST \
  "$SCRIPT_DIR/fm-brief.sh" "$VERIFY_ID" "$REPO_NAME" --verify >/dev/null || {
    echo "error: could not scaffold the verifier brief" >&2
    exit 1
  }
CREATED_BRIEF=1

SPAWN_ARGS=("$VERIFY_ID" "$PROJECT" --scout --neutral-dir "$NEUTRAL_DIR")
[ "${#PASSTHROUGH[@]}" -eq 0 ] || SPAWN_ARGS+=("${PASSTHROUGH[@]}")
SPAWN_RC=0
mark_endpoint_uncertain || {
  echo "error: could not durably publish uncertain endpoint ownership for task '$VERIFY_ID'" >&2
  exit 1
}
SPAWN_ATTEMPTED=1
SPAWN_ENDPOINT_UNCERTAIN=1
KEEP_BINDING=1
"$SPAWN_CMD" "${SPAWN_ARGS[@]}" || SPAWN_RC=$?

if [ "$SPAWN_RC" -ne 0 ]; then
  if [ -e "$VERIFY_META" ]; then
    SPAWN_ENDPOINT_UNCERTAIN=0
    clear_spawn_handoff || {
      echo "error: partial spawn handoff could not be persisted for task '$VERIFY_ID'; binding retained for reconciliation" >&2
      exit 1
    }
    echo "error: partial spawn left in place for task '$VERIFY_ID'; verifier brief and binding retained" >&2
    echo "       reconcile task '$VERIFY_ID' before retrying verification" >&2
    exit 1
  fi
  echo "error: verifier spawn failed and endpoint absence could not be confirmed for task '$VERIFY_ID'" >&2
  echo "       neutral directory retained at $NEUTRAL_DIR; reconcile the task and path before retrying" >&2
  exit 1
fi
if [ ! -e "$VERIFY_META" ]; then
  echo "error: verifier spawn returned success without metadata, so endpoint absence could not be confirmed for task '$VERIFY_ID'" >&2
  echo "       neutral directory retained at $NEUTRAL_DIR; reconcile the task and path before retrying" >&2
  exit 1
fi
SPAWN_ENDPOINT_UNCERTAIN=0
clear_spawn_handoff || {
  echo "error: successful spawn handoff could not be persisted for task '$VERIFY_ID'; binding retained for reconciliation" >&2
  exit 1
}

printf 'verifying %s at %s as %s (verdict: %s)\n' "$SHIP_ID" "$REV_SHORT" "$VERIFY_ID" "$VERIFY_REPORT"
