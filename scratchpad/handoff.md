# Handoff: fm-closer-sweep — independent pre-merge verifier

## Is the work committed? YES.

This worktree's HEAD `06b4a51` **"feat(bin): add the pre-merge independent verifier"
IS the closer work.** The task was originally specced as a stranded-work sweep
(`bin/fm-closer.sh`); the captain redirected it mid-task to a quality verifier and
deferred the sweep as a separate backlog item. The branch name `fm/fm-closer-sweep`
predates that redirect and was deliberately kept. So a commit that says "verifier"
on a branch that says "closer-sweep" is correct, not a mismatch.

## Coordinates

- **Branch:** `fm/fm-closer-sweep`
- **Worktree:** `/Users/sauce/.treehouse/firstmate-7bab20/1/firstmate`
- **Local HEAD:** `06b4a51` (this is the hand-recovered work)
- **PR head:** `b7de2fbc` — local HEAD plus the pipeline's own review/test/document commits
- **PR:** https://github.com/saucetech/firstmate/pull/2 — **OPEN, MERGEABLE**
- **Dead run id:** `01KZ4CD1TJ1790M51PEST8SW5W` — the no-mistakes daemon crashed; only
  the run record died. Branch, commits and PR are intact.
- **Verbatim `--intent`:** `scratchpad/nm-intent.txt` (68 lines, committed alongside this file).
  Re-run with it exactly:
  `no-mistakes axi run --intent "$(cat scratchpad/nm-intent.txt)"`
- **Gate targets:** `saucetech/firstmate` for BOTH push and PR base
  (`repos.upstream_url` == `fork_url` in `~/.no-mistakes/state.sqlite`, row `5bce7ea8fce8`).

## THE ONE JOB

CI on PR #2 is **7 of 8 green**. `Behavior portable serial 1` fails on ONE assertion in
`tests/fm-verify.test.sh`:

```
not ok - a late spawn failure must identify the partial task
         (missing: 'partial spawn left in place')
```

**What it asserts:** when `fm-spawn` fails *after* publishing `state/<id>.meta`,
`fm-verify` must RETAIN the brief and the binding and print a message containing
`partial spawn left in place`, naming the task to reconcile — never delete the artifacts
that identify a possibly-live endpoint. The string comes from `fm-verify.sh`'s rollback path.

**It passes locally 5 consecutive runs and fails on CI**, so it is environment-dependent —
almost certainly the same timing/ordering family as the two flakes already fixed on this
branch (below).

**Reproduce with the CI shard, not a bare run:**
```
./bin/fm-test-run.sh --lane portable-serial-1of4
```

**Fix the assumption or the implementation. NEVER the test.**

## Why that warning is not boilerplate

A no-mistakes **test step already destroyed this feature once**, in commit `479ac03`
("Restore commit-based verifier and Herdr teardown diagnostics"). It deleted **2543 lines**
to make a flaky suite pass — removing the entire neutral-artifact launch from
`fm-verify.sh`, `fm-spawn.sh` and `fm-teardown.sh`, **plus 291 lines of PRE-EXISTING tests**
in `tests/fm-teardown.test.sh` and `tests/fm-spawn-worktree-settle.test.sh`.
Document and lint then ran green on the gutted tree, so every gate reported success while
the load-bearing property was gone. Tracing `neutral` through `bin/fm-spawn.sh`:
0 at `fa16647`, 17 at `d98c690` where it was implemented, 20 across seven hardening commits,
then 0 from `479ac03` onward. Recovered by hand from `6a9d39e`.

## Integrity check — run before trusting ANY green step

```
grep -ci neutral bin/fm-verify.sh bin/fm-spawn.sh bin/fm-teardown.sh bin/fm-neutral-dir-lib.sh
   ->  49 / 34 / 38 / 19
tests/fm-verify.test.sh:  tests defined == tests invoked   ->  48 / 48
tests/fm-teardown.test.sh >= 2241 lines
tests/fm-spawn-worktree-settle.test.sh >= 292 lines
```

A drop is not automatically bad — check whether the reference moved into
`bin/fm-neutral-dir-lib.sh` and whether tests grew — but never accept it unexamined.
Counting passing tests is NOT sufficient: also compare defined vs invoked, or a silently
unregistered test reads as green.

## The two flake fixes — both must survive

1. **Four polling budgets of 1–3s** waited for markers only reachable *after* a real build
   (`git worktree add` + build command + artifact staging), which takes ~2s alone and longer
   under a loaded suite. Those budgets predate the build phase entirely. Replaced by a single
   `wait_for_marker` helper on a ~30s budget.
2. **Both double-fork descendant tests raced their own setup:** the build launched a
   detaching helper then returned immediately, so the post-build scan could run before the
   grandchild existed — an observed ~1-in-5 flake. The build now waits for the helper to
   publish its pid.

Neither weakens an assertion: the descendants still detach, still ignore TERM, and detection
still has to find them uncooperatively. Both carry comments saying they must not be deleted
to make a red suite green. **Deleting them re-creates the exact conditions that lost this
feature the first time.**

## Settled decisions — do not re-litigate

- The verifier launches **outside any repository**, against a built artifact staged into a
  neutral directory, so no harness can autoload project `AGENTS.md`/`CLAUDE.md`. This
  replaced a "suppress autoload" approach the captain explicitly rejected.
- **Protection is the union; authorization is the binding.** Removal validates against the
  union of child + active-parent protected trees AND requires a `state/<verify-id>.verify`
  binding matching path *and* device:inode. Neither substitutes for the other. This closed
  two real data-destruction risks (`--neutral-dir "$HOME/Documents"`, and forced secondmate
  cleanup reaching the parent's home/projects root).
- **Machinery never speaks for the product:** every orchestration failure (worktree
  allocation, runner start, artifact copy, unconfirmed cleanup, symlink escape, build
  timeout) reports blocked/error and NEVER writes a product verdict. Only a build command
  that actually ran and failed yields a product result.
- Containment of build descendants is best-effort on macOS (no cgroups, no PID namespaces);
  the contract is to **fail closed and refuse**, not to acquire non-cooperative process
  tracking. Building a process supervisor was explicitly ruled out of scope.
- `not delivered` blocking the merge is a **policy gate in AGENTS.md**; a hard refusal inside
  `bin/fm-pr-merge.sh` was deliberately excluded and is follow-up work.
- Cross-home capacity locking is out of scope; only within-home admission is serialized,
  under a home-local lock.
- The captain's UI/AI quality bar applies to **the promise's own claims** and never adds
  requirements the promise does not make.
- One narrow `--neutral-dir` launch mode was added to `bin/fm-spawn.sh`. The pre-existing
  broken `validate_spawn_worktree` is deliberately NOT fixed here (`fm-spawn-isolation-guard-fails`).

## How to continue

Re-run with the verbatim intent (above). A fresh run re-validates the branch's current
state, so already-resolved findings do not re-surface. Drive with `no-mistakes axi status`
and `axi respond`: `auto-fix` findings are the driver's to take, `ask-user` go to the captain.
A client-side socket timeout on `respond` proves nothing either way — **re-read the state
before assuming it landed or didn't** (observed both outcomes).

Do NOT reset the branch, open a new branch, or drop prior gate-fix commits.

## Three backlog items — NOT this task

1. `tests/fm-teardown.test.sh` → `herdr-preflight-missing-adapter` fails on **unmodified
   `origin/main`**. Pre-existing, reproduced, not from this change.
2. **`disable_project_settings: true` in `.no-mistakes.yaml` is not holding.** Gate agents
   address the user as "captain", i.e. they appear to load firstmate's `AGENTS.md` fleet
   identity. That is a plausible root cause for a test step concluding that deleting a
   feature and 291 lines of pre-existing tests was its call to make. Affects every repo
   behind this gate.
3. `fm-verify` build-runner hardening: detached-daemon cwd escape, tmux/cmux endpoint-identity
   confirmation, and compound cleanup-publication failures — six findings deliberately
   accepted after eight review rounds. They affect only pathological builds on a code path
   that has never executed.
