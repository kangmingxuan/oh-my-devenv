---
name: refresh-devenv-baseline
description: "Review and refresh the development runtime and tool versions maintained by oh-my-devenv. Use for monthly baseline maintenance or an ad hoc baseline upgrade; excludes application dependency updates and live machine installation."
---

# Refresh Development Baseline

Review the baseline against upstream evidence. Prepare a validated source
change when needed. This skill defines the agent workflow. It does not schedule
work or authorize publication. Follow the current task's scope and existing
authorization. Do not ask again for actions already authorized.

## Read the Repository Contract

Paths below are relative to this skill in `.agents/skills/refresh-devenv-baseline/`.
Read [AGENTS.md](../../../AGENTS.md),
[the baseline policy](../../../docs/03-maintenance.md#baseline-refresh), and
[Local Validation](../../../CONTRIBUTING.md#local-validation). The policy owns
the cadence and ecosystem selection rules; the manifests own exact versions.
Do not copy either into this skill or create a second version inventory.

Keep the execution host, schedule, notification destination, and standing
permissions in the caller's configuration. Do not change them through this
skill. Run the workflow manually before enabling recurring execution. Verify
that the result reaches the intended destination.

## Establish the Starting Point

- Inspect the current checkout, prior maintenance run, related worktrees, and
  any open baseline-refresh PR. Check the caller's run state when available;
  the absence of a PR does not prove that no run is active. The scheduler must
  serialize scheduled runs; this inspection is not an atomic lock. If another
  run owns the work or ownership is unclear, report the overlap and stop edits.
- For a new review, fetch `main` from the verified repository remote. Record
  the base commit. Use an isolated worktree for edits. When explicitly continuing
  an existing change, reuse its branch/worktree after checking ownership instead
  of starting over. Preserve unrelated work. If upstream cannot be verified,
  mark the review incomplete; any safe local preparation remains provisional.
- Inspect the mise configuration, ecosystem and desktop manifests,
  `.pre-commit-config.yaml`, and CI workflows. Keep system packages under their
  package manager's ownership. GitHub Actions already have monthly Dependabot
  coverage; avoid a duplicate maintenance PR for the same updates.

## Decide and Prepare

- Check primary upstream release notes, support windows, release dates, OS and
  architecture requirements, and matching artifacts. Follow the repository's
  ecosystem policy. Latest release availability alone does not establish
  community adoption. Revisit prior deferrals and document missing evidence.
  If prior decision records are inaccessible, report that gap and mark the
  deferral review incomplete.
- Record current and proposed versions, or a retained version, with the
  decision, sources, and compatibility implications. Prefer support through the
  next review; record any earlier follow-up needed. Check coupled runtimes and
  tools together, including Go toolchain requirements and Python package wheels.
- Resolve mise candidates with `mise ls-remote <tool> <version>` and check Go
  module and Python package metadata as applicable. Keep complete pins in their
  existing source files. Update `CHANGELOG.md` for changes, including material
  migration effects. Separate independently risky upgrades.
- If no changes are appropriate, record a completed no-change review only when
  the planned checks were completed. Missing evidence or a failed check must
  remain visible as an incomplete or blocked review.

## Validate

Run the checks selected by `CONTRIBUTING.md`; reuse the existing smoke suite and
pre-commit configuration. On macOS, follow its Bash 3.2 validation instructions.
Inspect the full diff and cover changed content with a secret scan: the
pre-commit gitleaks hook scans staged content only. When staging is not
authorized, scan the unstaged diff and new files separately.

Distinguish version resolution, source validation, and actual installation and
runtime acceptance. Keep candidate binaries, test homes, and caches isolated;
a Git worktree does not isolate the host's home directory or installed tools.
If real macOS preflight is required but not authorized, finish safe source
checks and report the remaining signoff. Do not run live chezmoi apply, bootstrap
installers, or machine upgrades as part of a source refresh.

## Deliver and Report

- Complete the delivery steps covered by the task's existing authorization.
  A request to commit includes staging the intended changes unless the user
  limits that scope. Do not ask again for actions already authorized. Stop
  before an unauthorized step. Preserve the completed work and report the
  remaining steps. Lack of publication authorization does not block safe local
  preparation.
- Follow the caller's branch naming convention when creating a maintenance
  branch. For an authorized commit, inspect the staged diff and verify the
  resulting commit. After an authorized push, verify that the remote branch
  points to the intended commit.
- When opening a PR is authorized, use the
  [PR template](../../../.github/pull_request_template.md). Reuse a relevant PR
  only when its ownership and scope permit. Read back the PR URL, base, and
  head. Check CI for that head. Report pending, failed, and unavailable checks
  accurately. Keep the PR in draft when required validation or a migration
  decision is outstanding. Attach the PR to the task when the host provides
  that capability. Do not merge or apply to machines.
- Report the review date, base commit, version decisions and sources, checks
  with results, diff location or PR link, unresolved items, and next review
  date. For a read-only request, report the recommendations and review status.
  Do not describe recommendations as prepared source changes. For a source
  refresh, use one of three outcomes: **update prepared**, **review complete
  with no changes**, or **review incomplete/blocked**. A created PR is not proof
  of passing CI, installation, or notification delivery.
- Do not create an empty PR for a no-change review. Preserve its result in the
  run history. Surface actionable findings or failures through the caller's
  configured channel only when sending there is authorized; otherwise report
  in the current task. Verify delivery when readback is available.
- Preserve undelivered changes and useful failure evidence. Before retrying,
  inspect the prior run and published branch/PR to avoid duplicate delivery.
  Retry a transient read or safely repeatable validation failure once. If it
  persists, stop that step and report the recovery requirement. Continue
  independent safe work. If publication or notification has an unknown outcome,
  verify the remote state before any retry. Do not discard unresolved checks.
