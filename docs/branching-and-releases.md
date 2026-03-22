# Branching and Release Policy

## Purpose

This document defines the Git workflow and release naming policy for Ophal.

The goal is to keep one obvious public trunk, one active release-development
line, and reproducible rollback points before major integrations.

## Branch Roles

- `master`: public trunk and latest accepted baseline
- `0.2.x`: active development line for the architecture upgrade and the `0.2`
  release series
- `feature/<topic>`: short-lived feature branch cut from `0.2.x`
- `fix/<topic>`: short-lived bug-fix branch cut from `0.2.x`
- `merge/<topic>`: temporary integration branch used for risky merges

After `0.1` is merged into `master`, `0.1` becomes historical and is no longer
treated as an active long-lived mainline.

## Current Transition Plan

The current repository state is:

- `master` remains the public branch name and will not be renamed
- `0.1` contains the more recent internal development history
- the next active release line will be `0.2.x`

The transition flow is:

1. Tag current `master` with an annotated rollback tag before any merge.
2. Tag the current `0.1` tip as a matching freeze point.
3. Create `merge/0.1-into-master` from `master`.
4. Merge `0.1` into that integration branch and resolve conflicts there.
5. Validate the merge.
6. Merge the validated integration branch into `master`.
7. Create `0.2.x` from the updated `master`.
8. Do architecture and release work on `0.2.x`.

Recommended freeze tags:

- `pre-merge-0.1-into-master-YYYY-MM-DD`
- `pre-merge-0.1-tip-YYYY-MM-DD`

## Merge Rules

- Do not develop major upgrade work directly on `master`.
- Merge short-lived topic branches into `0.2.x`.
- Merge `0.2.x` back into `master` at controlled milestones or releases.
- Use merge commits for major integration branches so the history preserves the
  context of the merge.
- If a bad merge reaches `master`, revert the merge commit instead of rewriting
  published history.

## Version and Tag Policy

Branch names do not need to be Semantic Version numbers.

Use:

- branch `0.2.x` for the `0.2` development and maintenance line
- annotated tags for actual release versions

Release tags follow Semantic Versioning:

- `v0.2.0-alpha.1`
- `v0.2.0-beta.1`
- `v0.2.0-rc.1`
- `v0.2.0`
- `v0.2.1`

Do not use branch names like `1.0.x` until the project is actually entering a
`1.0` stabilization or maintenance phase. A large architectural change alone
is not enough reason to name the active branch `1.0.x`.

## Release Flow

1. Development lands on `0.2.x`.
2. Prerelease tags are cut on `0.2.x`.
3. The final release commit is merged into `master`.
4. The final version tag is applied to the released commit.
5. Patch work for the `0.2` line continues on `0.2.x` and is merged back into
   `master`.

## Remote Protection

If the remote hosting platform supports it:

- protect `master` from direct force-pushes
- require reviewed merges into `master`
- optionally protect `0.2.x` as the active release-development line

This policy keeps `master` as the public branch without renaming it, while
making `0.2.x` the clear place for the next round of architecture work.
