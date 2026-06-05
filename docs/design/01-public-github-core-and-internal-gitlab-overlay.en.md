# Technical Design: Public GitHub Core and Internal GitLab Overlay

## 1. Goals

Provide a maintainable distribution model for this repository when we need both:

- a public-safe GitHub version
- an internal GitLab version

Requirements:

- Keep shared bootstrap and dotfiles logic in one place
- Prevent long-term drift between the two distributions
- Keep internal-only defaults and workflow rules out of the public version
- Give contributors a clear rule for where a change should land first

## 2. Problem Statement

The current repository mixes two different concerns:

1. a reusable cross-platform development environment baseline
2. organization-specific defaults, workflow assumptions, and corporate-network guidance

That coupling is visible in several places today:

- hard-coded GitLab host rewrites in `dot_gitconfig.tmpl`
- default work-identity and push-guardrail guidance in onboarding and overlay docs
- internal corporate-network setup and mirror guidance
- GitLab-specific issue, MR, CI, and ownership workflow under `.gitlab/`, `CODEOWNERS`, and maintainer docs

If we publish the repo as-is, the public version will carry internal defaults that do not apply to external users. If we split the repo into two equal copies, the shared bootstrap logic and documentation will drift.

## 3. Design Decision

Use an asymmetric two-repository model:

1. **Public core repository**: contains the public-safe baseline and is the only place where shared logic is changed directly.
2. **Internal overlay repository**: carries the public core plus a thin layer of organization-specific defaults, workflow files, and internal operational docs.

### Preferred source of truth

If the public GitHub repository is expected to accept outside issues or pull requests, it should become the source of truth for all shared logic.

That means:

- shared scripts, manifests, templates, and public-safe docs are authored in the public core first
- the internal GitLab version imports or mirrors those changes
- internal-only behavior is added only in the internal overlay

### Acceptable fallback

If organizational constraints require GitLab to remain the operational home for day-to-day work, keep the same asymmetric model but still designate exactly one repository as the owner of shared logic.

The hard rule is the same in both cases:

**Do not maintain two equal repositories or two long-lived public/internal branches that both accept direct edits to shared logic.**

## 4. Boundary Model For This Repository

The current repo should be split into three buckets.

### Public core

These surfaces are broadly reusable and should stay shared after debranding where needed:

- `bootstrap/` scripts and manifests
- shell environment templates and shared overlay loading behavior
- runtime/tool installation flow
- uninstall and smoke-test structure
- platform docs such as onboarding, maintenance, and macOS preflight once organization-specific defaults are removed
- long-form design docs under `docs/design/`

### Internal overlay

These surfaces are intrinsically internal or workflow-specific and should stay only in the internal distribution:

- `.gitlab/` issue templates and MR templates
- `AGENTS.md` rules that assume the internal GitLab workflow
- `CODEOWNERS` entries tied to internal handles
- internal corporate-network operational guidance
- internal-only examples for SSH bastions, scoped registries, and corporate Git hosts
- any default Git rewrite or hook that encodes organization-specific hosts, email domains, or other internal routing rules

### Needs debranding before it can live in the public core

These files should remain part of the shared baseline, but not in their current form:

- `README.md`
- `CONTRIBUTING.md`
- `CHANGELOG.md`
- `docs/01-onboarding.md`
- `docs/local-overlay-examples/README.md`
- `docs/local-overlay-examples/gitconfig.local.example`
- `docs/local-overlay-examples/git-pre-push.example`
- `dot_gitconfig.tmpl`
- `bootstrap/scripts/run-smoke-tests.sh`

For these files, the correct move is usually one of:

- replace organization-specific language with neutral language
- move the internal-only subsection into the overlay repo
- split one file into a public core file plus a small internal add-on

## 5. Contributor Workflow

Every change should answer one question first:

**Is this shared baseline behavior, or is this internal overlay behavior?**

### Shared baseline change

If the change benefits both distributions or changes shared runtime behavior:

1. land it in the public core first
2. sync it into the internal overlay repository
3. add or update internal-only docs only if the internal overlay still needs extra instructions

Examples:

- a new bootstrap script
- a manifest update for a broadly useful tool
- shell-loading behavior
- a bug fix in the installer flow
- a public-safe documentation clarification

### Internal-only change

If the change depends on internal infrastructure, internal identity rules, or GitLab-internal process:

1. keep it in the internal overlay only
2. do not copy it into the public core
3. if it touches a shared file today, first extract the shared part and move the internal part behind the overlay boundary

Examples:

- Git rewrites for an internal Git host
- guidance for corporate mirrors, CA trust, or private registries
- GitLab issue/MR workflow policy
- push hooks that inspect organization-specific email domains

### Suspicious middle ground

If a change starts from an internal use case but the mechanism is reusable, upstream the mechanism and keep only the values internal.

Examples:

- keep mirror-mode machinery in the public core
- keep actual internal mirror endpoints and usage policy in the internal overlay

## 6. Synchronization Model

Synchronization should be one-way for shared logic.

### Preferred model

- GitHub public core is the owner of shared logic
- GitLab internal repo periodically imports the public core
- GitLab then layers on internal files and internal patches only where needed

### Mechanical options

Any of these are acceptable as long as the direction stays one-way:

- `git subtree`
- a scripted sync branch
- a scheduled mirror job followed by a small internal patch layer

Tooling choice is secondary. The important constraint is that shared files have one editing home.

### Review rule

If the same concern is being edited in both repositories, reviewers should stop and ask whether the shared part belongs in the core instead.

## 7. Validation And Governance

The public core should defend its boundary explicitly.

Recommended public-repo checks:

- secret scanning
- a denylist check for internal hostnames and identity patterns that must not ship publicly
- smoke tests that pass without any internal network access
- documentation review to keep public entry points free of internal bootstrap URLs

Recommended internal-repo checks:

- overlay files do not silently fork shared bootstrap logic without justification
- internal docs link back to the shared public behavior instead of duplicating long shared instructions
- any new internal patch explains why the behavior cannot live in the public core

## 8. Bootstrapping The First Public Repository

The initial split needs one extra decision that does not exist once both repos are already running:

**Should the public repository inherit the full existing internal history?**

### Default recommendation

Unless the full internal history has already been audited as public-safe, do **not** push the current `main` history directly to GitHub.

The safer default is:

- prepare a sanitized public-safe tree first
- create a fresh public root commit from that tree
- keep future shared history from that point forward

This is slightly less elegant than preserving all historical ancestry, but it avoids leaking old internal-only content through Git history.

### When preserving history is acceptable

Preserve the existing history only if both are true:

- the full history has been reviewed for internal URLs, identities, workflow text, and other internal-only material
- you are willing to rewrite or remove any unsafe commits before publication

If either condition is false, start the public repo from a fresh sanitized root commit.

### Recommended first-time sequence

1. Create a working branch in the internal repo for the public split.
2. Prepare a sanitized branch that removes or debrands internal-only files and default values.
3. Create an orphan branch from that sanitized tree, for example `public-upstream`.
4. Commit that snapshot as the initial public-core commit.
5. Create an **empty** GitHub repository with no generated README, license, or `.gitignore`.
6. Add the GitHub repo as a remote and push `public-upstream` to GitHub's `main`.
7. Keep `public-upstream` in the internal repo as the tracking branch for the public core.
8. Merge `public-upstream` into the internal `main` once so future public-to-internal syncs have a normal merge base.
9. After that point, switch the contributor workflow: shared changes start on GitHub, internal-only changes start on GitLab.

### Example one-time commands

These commands assume the public-safe tree has already been prepared on a branch such as `public-prep`:

```bash
git switch public-prep
git switch --orphan public-upstream
git commit -m "Initial public core snapshot"

git remote add public git@github.com:<org>/<repo>.git
git push public public-upstream:main

git switch main
git merge --allow-unrelated-histories --no-ff public-upstream
```

Notes:

- The orphan branch gives the public repo a clean first commit without exposing older internal history.
- The one-time `--allow-unrelated-histories` merge is the bridge that lets later merges from `public-upstream` into internal `main` behave normally.
- From that point forward, do not edit `public-upstream` directly in GitLab; update it only by fetching from GitHub.

## 9. Migration Plan For The Current Repo

### Phase 1: define and enforce the boundary

- add this design doc
- classify existing files into core, overlay, and debranding buckets
- stop adding new organization-specific defaults to shared files unless there is no boundary yet

### Phase 2: public-safe core cleanup

- rewrite `README.md`, onboarding, and contributing docs around neutral defaults
- move the hard-coded internal Git-host rewrite out of the shared `dot_gitconfig.tmpl`
- update smoke tests so internal defaults are no longer part of the shared contract

### Phase 3: internal overlay extraction

- keep `.gitlab/`, internal workflow rules, corporate-network docs, and internal examples only in the GitLab distribution
- reintroduce organization-specific defaults there as a thin overlay instead of as shared baseline behavior

### Phase 4: sync automation

- choose one mechanical sync path
- automate import of the shared core into the internal repo
- keep automation out of scope until the boundary is already clean

## 10. Rejected Alternatives

### Long-lived public/internal branches in one repository

Rejected because every shared change becomes branch choreography and conflict resolution.

### Two equal repositories with manual cherry-picks

Rejected because source-of-truth becomes ambiguous and documentation drifts first.

### Keep everything in one repo behind many `INTERNAL_*` switches

Rejected because it leaves public entry points, tests, and docs entangled with internal assumptions and raises maintenance cost for both audiences.
