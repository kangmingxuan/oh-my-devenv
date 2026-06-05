# Technical Design: Public Release and Versioning Policy

## 1. Goals

Document how the public repository should track releases now that the public and
internal histories have diverged.

Requirements:

- keep public release history understandable without exposing internal history
- make `CHANGELOG.md` and tags authoritative for the public repository
- prevent internal-only milestones or release notes from leaking back into the public repo

## 2. Public History Starts At The Sanitized Snapshot

The public repository intentionally starts its visible history at the first
sanitized public snapshot.

That means:

- earlier internal milestones stay in the internal overlay repository
- the public changelog and public tags describe only public-safe history
- maintainers should not try to reconstruct internal release history inside the public repo

## 3. Source Of Truth

- The public repository is the source of truth for public tags and public release notes.
- The internal repository may import or mirror those tags for reference.
- Internal-only release notes remain internal.

## 4. Versioning Policy

Use Semantic Versioning 2.0 for the public baseline while it is still maturing.

- Minor releases (`v0.<M>.0`) ship a coherent slice of public-facing improvements.
- Patch releases (`v0.<M>.<N>`) ship focused fixes.
- The public baseline remains in `0.x` until maintainers believe the shared contracts have settled enough to promise stronger compatibility.

## 5. Changelog Discipline

`CHANGELOG.md` is the public release ledger.

- Every public user-visible change updates the `Unreleased` section in the PR that ships it.
- Internal-only changes do not belong in the public changelog.
- A change synced from the public repo into the internal repo should not be re-described as a new internal public release event.

## 6. Release Procedure

The public release procedure should stay lightweight:

1. Merge the intended PRs into public `main`.
2. Confirm public CI is green.
3. Confirm `CHANGELOG.md` describes the public-facing changes to ship.
4. Create an annotated tag from public `main`.
5. Push the tag to the public repository.
6. Sync the resulting shared changes into the internal repository as needed.

## 7. What Not To Do

- Do not backfill internal milestone names into the public changelog.
- Do not tag from an internal-only branch and call it a public release.
- Do not use the public changelog to describe internal operational or compliance changes that are invisible to public users.

## 8. Follow-Up Automation

Once the manual process is stable, maintainers may add lightweight tooling such as:

- GitHub release drafting
- tag validation in CI
- changelog policy checks for PRs that claim user-visible changes

Those are optional accelerators, not prerequisites for the release policy itself.
