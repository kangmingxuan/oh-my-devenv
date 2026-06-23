# Technical Design: Release and Versioning Policy

## 1. Goals

Document how this repository tracks releases so the changelog and tags stay the
authoritative record of what shipped.

Requirements:

- keep release history understandable from the repository alone
- make `CHANGELOG.md` and Git tags the source of truth for what each version contains
- keep the release process lightweight enough for a single maintainer to run

## 2. Versioning Policy

Use Semantic Versioning 2.0 for the baseline while it is still maturing.

- Minor releases (`v0.<M>.0`) ship a coherent slice of improvements.
- Patch releases (`v0.<M>.<N>`) ship focused fixes.
- The baseline stays in `0.x` until the shared contracts have settled enough to
  promise stronger compatibility.

## 3. Changelog Discipline

`CHANGELOG.md` is the release ledger.

- Every user-visible change updates the `Unreleased` section in the same PR that ships it.
- Write entries for the reader of a future version, not as commit notes.

## 4. Release Procedure

The release procedure stays lightweight:

1. Merge the intended PRs into `main`.
2. Confirm CI is green.
3. Move the shipped entries from `Unreleased` under a new version heading in `CHANGELOG.md`.
4. Create an annotated tag from `main` (`v<version>`).
5. Push the tag.

## 5. Follow-Up Automation

Once the manual process is stable, optional accelerators include:

- GitHub release drafting
- tag validation in CI
- changelog policy checks for PRs that claim user-visible changes

These are optional, not prerequisites for the policy itself.
