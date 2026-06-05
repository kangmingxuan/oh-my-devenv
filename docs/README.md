# Documentation Guide

This repository's docs are intentionally split by reader journey. Start with the page that matches what you are trying to do; do not read everything in order.

The repository is a single-maintainer, best-effort shared baseline. The docs should help you get productive quickly, understand the edges of the baseline, and find the right reference when something changes.

## Start Here

| If you are... | Read this first | Then read... |
|---------------|-----------------|--------------|
| Setting up a machine for the first time | [`README.md`](../README.md) `->` Quick Start | [`01-onboarding.md`](01-onboarding.md) for prompts, hook order, success signals, and troubleshooting |
| Trying to understand the full docs map | This page | The linked page for your task |
| Customizing your machine without changing the shared baseline | [`local-overlay-examples/README.md`](local-overlay-examples/README.md) | [`04-maintenance.md`](04-maintenance.md#validating-a-mirror-override) if you are testing a new mirror override |
| Reviewing or maintaining the repo | [`04-maintenance.md`](04-maintenance.md) | [`CONTRIBUTING.md`](../CONTRIBUTING.md) and [`CHANGELOG.md`](../CHANGELOG.md) |
| Investigating design rationale | [`design/README.md`](design/README.md) | The matching design doc |

## Document Map

- [`README.md`](../README.md): landing page and the self-contained first-run quick start for the default clean-machine path.
- [`01-onboarding.md`](01-onboarding.md): deeper first-run context, including prompts, hook order, success signals, and troubleshooting.
- [`local-overlay-examples/README.md`](local-overlay-examples/README.md): copyable templates for machine-local overlays that do not belong in the shared baseline.
- [`03-macos-preflight.md`](03-macos-preflight.md): the manual checklist for merge requests that touch macOS-only behavior.
- [`04-maintenance.md`](04-maintenance.md): day-to-day maintainer workflow, lightweight CI expectations, dependency bumps, removals, and release hygiene.
- [`design/README.md`](design/README.md): long-form rationale and architectural decisions.
- [`design/01-public-github-core-and-internal-gitlab-overlay.en.md`](design/01-public-github-core-and-internal-gitlab-overlay.en.md): recommended split model for a public-safe GitHub core and an internal GitLab overlay.
- [`CHANGELOG.md`](../CHANGELOG.md): user-visible changes by milestone.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md): contributor workflow, scope rules, and secret hygiene.

## Which Page Owns What?

- Keep the minimum successful first-run path in [`README.md`](../README.md).
- Put extended first-run context, prompts, expectations, and troubleshooting in [`01-onboarding.md`](01-onboarding.md).
- Put maintainer workflow, validation, and release process in [`04-maintenance.md`](04-maintenance.md).
- Put copyable local examples in [`local-overlay-examples/`](local-overlay-examples/README.md), not in the root docs.
- Put rationale and trade-offs in [`design/`](design/README.md), not in the operational guides.
- Keep [`README.md`](../README.md) readable as a landing page. If a section starts feeling like a handbook chapter, move it into `docs/` and link to it.

## When In Doubt

If you are adding or editing docs:

1. Choose one page as the canonical home.
2. Keep other pages short and link back to that home instead of duplicating long instructions.
3. Update [`README.md`](../README.md) or this page if the reader entry points changed.
