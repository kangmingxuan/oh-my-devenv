# Changelog

All notable public user-visible changes to this repository are documented here. The format follows [Keep a Changelog 1.1](https://keepachangelog.com/en/1.1.0/).

## Versioning Policy

This public repository versions the shared baseline with [Semantic Versioning 2.0](https://semver.org/).

- Minor versions (`v0.<M>.0`) ship a coherent slice of public-facing improvements.
- Patch versions (`v0.<M>.<N>`) ship focused fixes without broadening scope.
- The leading `0.` signals that the public baseline is still settling after the public/internal split; load-bearing interfaces may still change between minors with a callout.

## Release Discipline

- Public releases are cut from the public repository's `main` branch after CI is green and the intended PRs are merged.
- `CHANGELOG.md` is updated in the same PR that introduces a public user-visible change.
- Internal-only changes stay out of this file and remain tracked in the internal overlay repository.

## Git Tags

- Public tags are annotated tags pushed from the public repository.
- Internal mirrors may sync those tags for reference, but the public repository remains the source of truth for public release history.

## Public History

This changelog is intentionally reset for the public-safe version of the repository.

- Earlier internal milestones, issue links, and release metadata stay in the internal overlay repository.
- Public history starts with the first published snapshot of this shared baseline.

## [Unreleased]

### Added

- `smoke-tests-macos` CI job that runs the smoke suite on `macos-latest`, so the `darwin` template arms are rendered and shell-checked instead of going untested.
- `apply-linux` CI job that runs a real `chezmoi init --apply` end to end and asserts the final environment check passes, covering installer semantics the render-only smoke suite cannot.
- Dependabot configuration to keep GitHub Actions versions current.
- macOS Homebrew opt-in extension point for first-bootstrap optional packages, using `DOTFILES_INSTALL_REPO_OPTIONAL_BREWFILE` and `DOTFILES_EXTRA_BREWFILES`.

### Changed

- The public-boundary lint now reads forbidden patterns from the overlay-owned `bootstrap/manifests/system/boundary-denylist.txt` and scans the entire working tree, so the public scripts no longer hard-code internal identity strings and the lint no longer skips itself or the shell templates.
- Prepared the first public-safe snapshot by removing internal bootstrap defaults, moving restricted-network setup to local overlays, and trimming internal-only repository metadata from the public-prep branch.
- Added the first operational handbook for the public/internal split, including routing from `CONTRIBUTING.md` and `docs/README.md`.
- Added GitHub collaboration files, public-boundary checks, and CI workflows so the public repository can accept issues, pull requests, and safety checks on its own.

### Removed

- The unused `isWsl` chezmoi data flag and the `DOTFILES_FORCE_WSL` escape hatch, plus the redundant `smoke-tests-wsl-shaped` CI job. WSL continues to work through the standard Linux path.
- `.gitlab-ci.yml` from the public repository; the internal overlay owns its own CI definition.
