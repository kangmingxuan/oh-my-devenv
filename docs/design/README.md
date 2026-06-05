# Design Docs

This folder holds long-form **technical design** documents for this repository. Design docs explain *why* the current shape exists — decisions, trade-offs, and alternatives considered — and are written to outlive any single milestone.

Everything else under `docs/` (`01-onboarding.md`, `04-maintenance.md`, `03-macos-preflight.md`, `local-overlay-examples/`) is **operational**: it tells a reader what to do today. Design docs tell the next maintainer *why the "what to do today" looks the way it does*.

Need the broader docs map first? Start at [`docs/README.md`](../README.md).

## Current design docs

| Doc | When to read |
|-----|--------------|
| [`00-cross-platform-bootstrap.en.md`](00-cross-platform-bootstrap.en.md) | You need the authoritative rationale for the layered bootstrap model (system / runtime / ecosystem), the choice of chezmoi over alternatives, and how the three platforms (macOS / Ubuntu / WSL) share one source of truth. English. |
| [`00-cross-platform-bootstrap.zh.md`](00-cross-platform-bootstrap.zh.md) | Same document in Chinese. The two files are kept in sync by hand; if they diverge, treat the English version as the source of truth unless the commit message says otherwise. |
| [`01-public-github-core-and-internal-gitlab-overlay.en.md`](01-public-github-core-and-internal-gitlab-overlay.en.md) | You need the recommended maintenance model for keeping a public-safe GitHub version and an internal GitLab version without turning them into two drifting products. English. |
| [`02-public-release-and-versioning.en.md`](02-public-release-and-versioning.en.md) | You need the public repository's release, changelog, and tagging policy after the history split. English. |

## When to add a design doc here

Add a new design doc when any of the following is true:

- A decision will be referenced across multiple MRs (so it needs a single home, not a commit message).
- The decision has multiple plausible alternatives that were considered and rejected; the rationale must survive once the people in the room have moved on.
- The decision creates a load-bearing convention that future contributors will have to respect (layout, naming, ownership boundaries).

Keep operational how-tos (onboarding, maintenance, troubleshooting) out of this folder — they belong one level up under `docs/`.
