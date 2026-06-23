# Documentation Guide

This repository's docs are split by reader journey. Start with the page that matches what you are trying to do — you do not need to read everything in order.

The repository is a single-maintainer, best-effort shared baseline. These docs help you get productive fast, look things up when something changes, and understand the edges of the baseline.

## Start here — find your path

| I want to… | Start here | Then |
|------------|-----------|------|
| **Set up a new machine** | [`README.md`](../README.md) → Quick Start | [`01-onboarding.md`](01-onboarding.md) for prompts, hook order, success signals, and troubleshooting |
| **Customize my machine** without changing the shared baseline | [`local-overlay-examples/README.md`](local-overlay-examples/README.md) | [`02-reference.md`](02-reference.md) to look up the flag or overlay slot you need |
| **Look up** a flag, command, or what gets installed | [`02-reference.md`](02-reference.md) | The manifest it links to for exact versions |
| **Understand how and why** it is built | [`design/README.md`](design/README.md) | [`design/00-cross-platform-bootstrap.en.md`](design/00-cross-platform-bootstrap.en.md) for the layered model |
| **Maintain or contribute** to the baseline | [`03-maintenance.md`](03-maintenance.md) | [`CONTRIBUTING.md`](../CONTRIBUTING.md), and [`04-macos-preflight.md`](04-macos-preflight.md) for macOS-touching changes |

## Document map

### Get started and use

- [`README.md`](../README.md): landing page and the self-contained first-run quick start. A Chinese translation lives in [`README.zh.md`](../README.zh.md).
- [`01-onboarding.md`](01-onboarding.md): the first-run walkthrough — prompts, hook order, success signals, and troubleshooting.
- [`02-reference.md`](02-reference.md): quick reference for the bootstrap hooks, what gets installed, day-to-day commands, and every environment variable / flag.
- [`local-overlay-examples/README.md`](local-overlay-examples/README.md): copyable templates for machine-local overlays that do not belong in the shared baseline.

### Understand the design

- [`design/README.md`](design/README.md): index of the long-form rationale and architectural decisions.
- [`design/00-cross-platform-bootstrap.en.md`](design/00-cross-platform-bootstrap.en.md) ([中文](design/00-cross-platform-bootstrap.zh.md)): the layered bootstrap model (system / runtime / ecosystem) and why chezmoi.
- [`design/01-release-and-versioning.en.md`](design/01-release-and-versioning.en.md): release, changelog, and tag policy.

### Maintain and contribute

- [`03-maintenance.md`](03-maintenance.md): day-to-day maintainer workflow, CI expectations, dependency bumps, removals, and release hygiene.
- [`04-macos-preflight.md`](04-macos-preflight.md): the manual checklist for changes that touch macOS-only behavior.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md): contributor workflow, scope rules, and secret hygiene.
- [`CHANGELOG.md`](../CHANGELOG.md): user-visible changes by milestone.

## Which page owns what?

- Keep the minimum successful first-run path in [`README.md`](../README.md).
- Put extended first-run context, prompts, expectations, and troubleshooting in [`01-onboarding.md`](01-onboarding.md).
- Put lookups — hooks, installed tools, commands, and environment variables / flags — in [`02-reference.md`](02-reference.md).
- Put copyable local examples in [`local-overlay-examples/`](local-overlay-examples/README.md), not in the root docs.
- Put maintainer workflow, validation, and release process in [`03-maintenance.md`](03-maintenance.md).
- Put rationale and trade-offs in [`design/`](design/README.md), not in the operational guides.
- Keep [`README.md`](../README.md) readable as a landing page. If a section starts feeling like a handbook chapter, move it into `docs/` and link to it.

## When in doubt

If you are adding or editing docs:

1. Choose one page as the canonical home.
2. Keep other pages short and link back to that home instead of duplicating long instructions.
3. Update [`README.md`](../README.md) or this page if the reader entry points changed.
