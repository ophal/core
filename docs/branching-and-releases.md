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

## Current State

The `0.1` integration is complete:

- `master` remains the public branch name and was not renamed
- `0.1` was merged into `master` through `merge/0.1-into-master`
- `0.2.x` was created from the updated `master` and is now the active release
  and upgrade line

Historical freeze tags for that transition already exist:

- `pre-merge-master-2026-03-22`
- `pre-merge-0.1-tip-2026-03-22`

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
2. Prerelease tags are cut on `0.2.x` as needed.
3. A release-ready `0.2.x` milestone is merged into `master`.
4. The release tag is applied to the released commit.
5. Patch work for the `0.2` line continues on `0.2.x` and is merged back into
   `master`.

## Remote Protection

If the remote hosting platform supports it:

- protect `master` from direct force-pushes
- require reviewed merges into `master`
- optionally protect `0.2.x` as the active release-development line

This policy keeps `master` as the public branch without renaming it, while
making `0.2.x` the clear place for the current release and post-upgrade work.
