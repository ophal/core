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

Branch names do not need to be version numbers.

Use:

- branch `0.2.x` for the `0.2` development and maintenance line
- annotated tags for actual releases

A release tag is `v<version>-<cut>`:

- `v0.2.0-1` — the first cut of `0.2.0`
- `v0.2.0-2` — a later cut of the same version
- `v0.2.1-1` — the first cut of the next version

**There is one naming scheme, and it is the one LuaRocks uses.** A tag maps
onto a rockspec with no translation: `v0.2.0-1` is `ophal-0.2.0-1.rockspec`
with `version = "0.2.0-1"`. There is deliberately no second vocabulary of
alphas, betas and release candidates, because a version that needs two names
has two names to keep in step.

Two consequences to know rather than rediscover:

- **A bare `v0.2.0` is never tagged.** The cut number is part of the name, so
  the unsuffixed form does not exist. This matters because a tool that parses
  tags as Semantic Versioning reads `-1` as a *prerelease* of `0.2.0` and sorts
  it before a bare `0.2.0`. Since the bare form never exists, nothing is ever
  ordered wrongly against it.
- **Sort with `git tag --sort=v:refname`.** Lexical order puts `-10` before
  `-2`, which the `0.1` line already demonstrates: `v0.1-alpha10` sorts before
  `v0.1-alpha2`.

This follows what the `0.1` line actually did. It was cut eleven times as
`v0.1-alpha1` through `v0.1-alpha11` and three more as `v0.1-beta1` through
`v0.1-beta3`, and a bare `v0.1` was never tagged — so the cut number was always
the real identifier and the word in front of it never carried information.

Maturity is communicated by the version itself. A `0.x` major already means the
interface may change in any release; it does not need a word in the tag as well.

Do not use branch names like `1.0.x` until the project is actually entering a
`1.0` stabilization or maintenance phase. A large architectural change alone
is not enough reason to name the active branch `1.0.x`.

## Release Flow

1. Development lands on `0.2.x`.
2. A release-ready `0.2.x` milestone is merged into `master`.
3. The release tag is applied to the released commit, as an annotated tag.
4. Patch work for the `0.2` line continues on `0.2.x` and is merged back into
   `master`.

Re-cutting the same version — `v0.2.0-2` after `v0.2.0-1` — is for a release
that ships different bytes: a packaging fix, a corrected file list, a build that
had to be redone. Code changes that a user would notice get a new version
instead.

## Remote Protection

If the remote hosting platform supports it:

- protect `master` from direct force-pushes
- require reviewed merges into `master`
- optionally protect `0.2.x` as the active release-development line

This policy keeps `master` as the public branch without renaming it, while
making `0.2.x` the clear place for the current release and post-upgrade work.
