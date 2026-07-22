# Changelog

All notable user-visible changes to this repository are documented here. The format follows [Keep a Changelog 1.1](https://keepachangelog.com/en/1.1.0/).

## Versioning Policy

This repository versions the baseline with [Semantic Versioning 2.0](https://semver.org/).

- Minor versions (`v0.<M>.0`) ship a coherent slice of improvements.
- Patch versions (`v0.<M>.<N>`) ship focused fixes without broadening scope.
- The leading `0.` signals that the baseline is still settling; load-bearing interfaces may still change between minors with a callout.

## Release Discipline

- Releases are cut from `main` after CI is green and the intended PRs are merged.
- `CHANGELOG.md` is updated in the same PR that introduces a user-visible change.
- Tags are annotated tags pushed from `main`, and are the source of truth for release history.

## [Unreleased]

### Added

- Opt-in, all-or-nothing desktop baseline for macOS and non-WSL Ubuntu 26.04+: Ghostty, Maple Mono NF CN, managed Ghostty defaults, a Linux Fontconfig compatibility rule, and OrbStack on macOS.
- `smoke-tests-macos` CI job that runs the smoke suite on `macos-latest`, so the `darwin` template arms are rendered and shell-checked instead of going untested.
- `apply-linux` CI job that runs a real `chezmoi init --apply` end to end and asserts the final environment check passes, covering installer semantics the render-only smoke suite cannot.
- Dependabot configuration to keep GitHub Actions versions current.
- Bilingual landing page: a Chinese `README.zh.md` translation of the root README, with a language switcher linking it and the English `README.md` together.
- `docs/02-reference.md`: a single lookup page for the bootstrap hooks, what gets installed, day-to-day commands, and every environment variable / flag the baseline understands.

### Changed

- Expanded the selected macOS desktop bundle to include OrbStack. Existing macOS machines with `desktopBaseline = true` install it the next time the desktop manifest hook runs.
- Moved JetBrains Toolbox PATH setup and OrbStack shell/SSH initialization out of managed templates and into documented local overlays.
- Split persistent shell environment from bootstrap-only settings: shells read `env.sh`, bootstrap reads `bootstrap.env`, and one inventory now defines every supported local overlay and its uninstall protection.
- Made `XDG_CONFIG_HOME` the single config root for managed mise, Ghostty, and Fontconfig files and for local config overlays. It defaults to `$HOME/.config`; custom absolute roots are applied through a dedicated chezmoi subsource.
- Moved the user-owned Git config and configured hooks under `$XDG_CONFIG_HOME/oh-my-devenv/git/`. Git 2.54+ guardrails now coexist with repository-local `.git/hooks/*` instead of replacing them through `core.hooksPath`.
- Upgraded uv from 0.10.9 to 0.11.28, adopting the 0.11 networking and certificate-verification changes while keeping uv pinned to a reproducible patch release.
- Pinned Go, Node, and Python to complete patch versions; refreshed the Go, Python, lint, hook, and secret-scanning tools to current compatible releases; and made related low-risk dependency maintenance a single reviewable change.
- Reworked the root `README.md` into a more scannable landing page: added status and platform badges, a "What you get" feature summary, and a Mermaid bootstrap-flow diagram; relocated the verbose first-run details to `docs/01-onboarding.md`; and moved the best-effort scope note into its own section. The Quick Start steps and the `#quick-start` anchor are unchanged.
- Reorganized `docs/README.md` around reader intent (use / customize / look up / understand / maintain) and refreshed the operational docs to match the current bootstrap — the `run_before_00-banner` hook, the `MISE_PYTHON_GITHUB_ATTESTATIONS` override, and the oh-my-zsh plugin-manifest contract.

### Removed

- The pre-bootstrap `Brewfile.local` extension point. Machine-local applications outside the selected desktop baseline are no longer part of this repository's bootstrap contract.
- The overlapping repo-owned optional Homebrew catalog and environment-variable selectors.
- The unused `usage` CLI from the shared baseline. Existing machine-local installs are left untouched and can be removed explicitly with `mise uninstall usage@2.18.2`.
- The unused `isWsl` chezmoi data flag and the `DOTFILES_FORCE_WSL` escape hatch, plus the redundant `smoke-tests-wsl-shaped` CI job. WSL continues to work through the standard Linux path.
