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

- Arch Linux family package installation and checks through pacman.
- Arch template, installer, and login regression coverage, plus a `smoke-tests-arch` CI job.
- Opt-in, all-or-nothing desktop baseline for macOS, non-WSL Arch Linux, and Ubuntu 26.04+: Ghostty, Maple Mono NF CN, managed Ghostty defaults, an Ubuntu Ghostty-specific Fontconfig compatibility rule, and OrbStack on macOS.
- `smoke-tests-macos` CI job that runs the smoke suite on `macos-latest`, so the `darwin` template arms are rendered and shell-checked instead of going untested.
- `apply-linux` CI job that runs a real `chezmoi init --apply` end to end and asserts the final environment check passes, covering installer semantics the render-only smoke suite cannot.
- Dependabot configuration to keep GitHub Actions versions current.
- Bilingual landing page: a Chinese `README.zh.md` translation of the root README, with a language switcher linking it and the English `README.md` together.
- `docs/02-reference.md`: a single lookup page for the bootstrap hooks, what gets installed, day-to-day commands, and every environment variable / flag the baseline understands.
- Centrally generated CLI completions in the standard Bash and Zsh user data directories, including `uvx` and Linux `bat` adapters.
- A documented, uninstall-protected mise local overlay for machine-only global tools and settings.
- `bootstrap/manifests/shell/completions.txt`: one declarative inventory of completion commands and platforms shared by the installer, the environment check, uninstall, and the smoke suite.
- Generated completion files carry an ownership marker. `install` prunes marked files whose command left the manifest or platform once the current entries install, `check` reports them as stale, and `list` includes them for uninstall; unmarked files and symlinks are never removed.

### Changed

- Scoped the existing font-discovery workaround to Ghostty on supported Ubuntu desktops. Other platforms render an inactive rule, and desktop validation checks installed font faces without imposing a system-wide `monospace` preference.

- Support native Arch bat completions alongside Debian's batcat wrappers.
- Manage the Bash login entry point and allow quiet shared initialization in `env.sh`.
- Defined oh-my-devenv as the maintainer's public, opinionated current design: validation checks behavior and safety boundaries without duplicating configuration facts, and superseded designs are replaced without compatibility logic.
- The final environment check validates the same manifests the installers consumed: apt manifests through `dpkg-query`, pacman manifests through `pacman -Q`, Brewfiles through `brew bundle check`, the mise configuration through `mise ls --missing`, the completion manifest through the installer, and the font manifest's declared family and faces. Its version card lists the mise-managed toolchain from `mise current`.
- `maple-mono-nf-cn.env` now declares the font family and required PostScript faces; the Linux installer, the check, and the managed Ghostty and Fontconfig templates read that single source.
- `mirrors.env` lists only the internal keys in one `<ENV_VAR_NAME> <value>` format. External mode leaves the caller environment untouched and downstream tools keep their own defaults.
- `install-go-tools.sh` requires every entry to pin an exact `module@vX.Y.Z` version and rejects anything else before installing.
- `uninstall.sh` requests plain line output from both `chezmoi managed` calls with `--format=` and aborts when a producer fails.
- The smoke suite validates manifest schemas, template rendering and syntax, platform contracts, and fixture behavior instead of asserting current package names, versions, URLs, or preference values, so ordinary manifest changes no longer require test edits.
- Expanded the selected macOS desktop bundle to include OrbStack. Existing macOS machines with `desktopBaseline = true` install it the next time the desktop manifest hook runs.
- Moved JetBrains Toolbox PATH setup and OrbStack shell/SSH initialization out of managed templates and into documented local overlays.
- Split persistent shell environment from bootstrap-only settings: shells read `env.sh`, bootstrap reads `bootstrap.env`, and one inventory now defines every supported local overlay and its uninstall protection.
- Made `XDG_CONFIG_HOME` the single config root for managed mise, Ghostty, and Fontconfig files and for local config overlays. It defaults to `$HOME/.config`; custom absolute roots are applied through a dedicated chezmoi subsource.
- Moved the user-owned Git config and configured hooks under `$XDG_CONFIG_HOME/oh-my-devenv/git/`. Git 2.54+ guardrails now coexist with repository-local `.git/hooks/*` instead of replacing them through `core.hooksPath`.
- Upgraded uv from 0.10.9 to 0.11.28, adopting the 0.11 networking and certificate-verification changes while keeping uv pinned to a reproducible patch release.
- Pinned Go, Node, and Python to complete patch versions; refreshed the Go, Python, lint, hook, and secret-scanning tools to current compatible releases; and made related low-risk dependency maintenance a single reviewable change.
- Reworked the root `README.md` into a more scannable landing page: added status and platform badges, a "What you get" feature summary, and a Mermaid bootstrap-flow diagram; relocated the verbose first-run details to `docs/01-onboarding.md`; and moved the best-effort scope note into its own section. The Quick Start steps and the `#quick-start` anchor are unchanged.
- Reorganized `docs/README.md` around reader intent (use / customize / look up / understand / maintain) and refreshed the operational docs to match the current bootstrap — the `run_before_00-banner` hook, the `MISE_PYTHON_GITHUB_ATTESTATIONS` override, and the oh-my-zsh plugin-manifest contract.
- Simplified shell startup by consuming official completion assets instead of probing and generating them interactively. Zsh keeps `zsh-completions` last in `fpath` as a fallback; macOS Bash is intentionally limited.

### Removed

- The pre-bootstrap `Brewfile.local` extension point. Machine-local applications outside the selected desktop baseline are no longer part of this repository's bootstrap contract.
- The overlapping repo-owned optional Homebrew catalog and environment-variable selectors.
- The unused `isWsl` chezmoi data flag and the `DOTFILES_FORCE_WSL` escape hatch, plus the redundant `smoke-tests-wsl-shaped` CI job. WSL continues to work through the standard Linux path.
- The `golangci-lint` name veto in `install-go-tools.sh`; tool ownership follows the manifest that declares the tool.
- The `external` rows in `mirrors.env`, the unused mirror lookup helper, the JSON and `python3` fallback in `uninstall.sh`, and `@latest` handling in the Go tool installer.
