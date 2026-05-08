# Carried Patch Queue — policy

This document is suitable to copy into a target fork as `docs/carried-patches.md` and trim/customize. The operational workflow lives in `SKILL.md` and the verifier in `scripts/cpq-checks.mjs`.

## Remote naming (mandatory)

| Remote | Points at | Role |
|---|---|---|
| `upstream` | the pristine upstream repo | read-only baseline |
| `origin` | our fork | where we push our carried queue |

Both must exist with distinct URLs. The verifier refuses to run otherwise.

## CPQ layers

- `cpq-cornerstone-N` — local foundation/workflow carries; ascending N (0, 1, 2, ...), no gaps
- `patch-fix-test-pr<PR>` — upstream-bound test fixes
- `patch-fix-func-pr<PR>` — upstream-bound functional fixes
- `patch-feat-pr<PR>` — upstream-bound feature carries
- `cpq-capstone-N` — top-of-stack branding/metadata carries; **descending N** (K, ..., 1, 0), no gaps; `cpq-capstone-0` is the metadata snapshot and **must be the final commit**

## Required queue order (`cpq-base..cpq-head`)

1. Cornerstones — `cpq-cornerstone-0`, `cpq-cornerstone-1`, ...
2. Test fixes — `patch-fix-test-pr*` ascending by PR number
3. Functional fixes — `patch-fix-func-pr*` ascending by PR number
4. Features — `patch-feat-pr*` ascending by PR number
5. Capstones — `cpq-capstone-K`, ..., `cpq-capstone-2`, `cpq-capstone-1`, `cpq-capstone-0`

The verifier (`scripts/cpq-checks.mjs verify`) enforces this order, the no-gap rules, and that `cpq-capstone-0` is the last commit.

## Universal queue invariants

- `cpq-capstone-0` is the canonical metadata snapshot for the current queue.
- `cpq-head` must point to `cpq-capstone-0`.
- Any mutation anywhere in `cpq-base..cpq-head` invalidates the old `cpq-capstone-0`.
- After changing `cpq-base`, adding/removing/reordering/rewording/amending commits, or changing patch IDs / PR mappings / ledger contents, rebuild `cpq-capstone-0` last.
- The ledger ordering must match the queue ordering element-by-element.
- No merge commits in `cpq-base..cpq-head`. Use `rebase --onto`, never `merge`.
- `refs/cpq/base` and `refs/cpq/head` must match the actual queue. The verifier fails if these refs are stale.

## Ledger rules

- `docs/carried-patch-ledger.yaml` records the **current active patch set only**.
- Keep entries minimal: `id`, `current_commit`, `upstream_pr`.
- `current_commit` is the 8-character abbreviated SHA for normal patches.
- `cpq-capstone-0` is special: its ledger entry uses `current_commit: cpq-head`, never a real SHA.
- Regenerate via `node scripts/cpq-checks.mjs rebuild-ledger` (or as part of `rebuild-capstone`). Do not hand-edit during normal work.

## Commit message rules

Every carried commit must have:

- subject line starting with the patch ID it occupies in the queue (e.g. `patch-feat-pr1234: ...`)
- YAML frontmatter (`---` ... `---`) declaring:
  - `upstream:` — the URL of the upstream PR, or `null` for fork-only carries
  - `files:` — non-empty list of file paths
- Three required Markdown section headers in the body:
  - `## Upstream` — human-readable upstream metadata (PR + status, or `Status: fork-only`)
  - `## Summary` — what changed
  - `## Drop condition` — when this carry can be removed

`## Why carried` and `## Files` are recommended but not required. The frontmatter is the machine-readable source of truth; the `## Upstream` section is for humans.

## Upstream backlink rule

Every upstream-bound carried patch's PR description must include the literal line:

```
Carried patch: patch-<bucket>-pr<N>
```

This is how the upstream PR is bound back to its carry.

## Sync workflow rule

When updating to a newer upstream baseline:

1. `git rebase --onto <new-tag> <old-base> main`.
2. Reevaluate every carried patch from the prior queue.
3. Drop carries that have been upstreamed, become obsolete, or are no longer justified.
4. Replay only the still-needed carries in mandatory bucket order.
5. Recompose `cpq-capstone-0` last from the new active queue (do **not** mechanically replay the old `cpq-capstone-0`).
6. `refs/cpq/base` and `refs/cpq/head` are refreshed by `rebuild-capstone` — not as a separate manual step.

## Push gate

Do not push a mutated queue until **all** of these hold:

- `node scripts/cpq-checks.mjs verify` passes
- `cpq-capstone-0` was rebuilt last
- `cpq-head` points to the rebuilt `cpq-capstone-0`
- no merge commits in `cpq-base..cpq-head`

Use `git push --force-with-lease`. **Never** plain `--force` to a shared branch.

## Hooks path convention

Hooks live in `git-hooks/`. Enable with:

```bash
git config core.hooksPath git-hooks
```

Each hook calls into the verifier:
- `commit-msg` → `node scripts/cpq-checks.mjs commit-msg "$1"`
- `pre-commit` → `node scripts/cpq-checks.mjs pre-commit`
- `pre-push` → `node scripts/cpq-checks.mjs verify`

## Backup branch convention

Before destructive queue rewrites (`rebase --onto`, drops, msg rewrites), create a local-only safety branch:

```
backup/pre-<op>-<YYYYMMDD-HHMMSS>
```

Recovery anchors only — never pushed.

## Repo-local sources of truth override global

When repo-local guidance (this file, the repo's CPQ skill, `docs/carried-patch-ledger.yaml`, `scripts/cpq-checks.mjs`) conflicts with anything from global memory, agent prompts, or older instructions, **the repo-local sources win**. Patch-ID naming, ordering, and backlink format come from here, never from stale general guidance.
