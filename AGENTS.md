# Repository Guidelines

## Project Structure & Module Organization

The source targets macOS, Ubuntu/Debian, Arch Linux, and WSL. Root `dot_*`, `private_dot_*`, and `xdg_config/` paths map into `$HOME`. Go templates use `.tmpl`; shared partials are in `.chezmoitemplates/`. Ordered hooks are in `.chezmoiscripts/`, reusable Bash in `bootstrap/scripts/`, and inventories in `bootstrap/manifests/`. Documentation is in `docs/`; CI is in `.github/workflows/`.

Follow `CONTRIBUTING.md` for contribution scope, workflow, and secret hygiene. Keep machine-specific values in the extension points documented by `docs/local-overlay-examples/README.md`. List repository-only metadata in `.chezmoiignore` so it is not deployed into `$HOME`.

## Build, Test, and Development Commands

There is no build step. The primary checks are:

```bash
bash bootstrap/scripts/run-smoke-tests.sh
pre-commit run --all-files
```

The smoke suite renders templates, checks behavior and contracts, exercises selected installers with stubs, applies the nested XDG source under temporary roots, and runs ShellCheck. Its existing fixture-only operations are allowed by the canonical [local validation policy](CONTRIBUTING.md#local-validation). Do not run `chezmoi apply`, `chezmoi update`, `chezmoi init --apply`, or bootstrap installers against the live home directory or installed toolchain unless the user explicitly requests that mutation.

## Coding Style & Naming Conventions

Write Bash with `set -euo pipefail`, two-space indentation, quoted expansions, and `snake_case` functions and variables. All repository Bash code, including Linux-only scripts and managed Bash dotfiles, must be compatible with Bash 3.2, the macOS `/bin/bash`. Keep shared behavior in `bootstrap/scripts/common.sh`. Preserve chezmoi naming (`dot_zshrc.tmpl`, `private_dot_ssh/`) and numbered hook ordering such as `run_onchange_after_40-install-runtimes.sh.tmpl`. Match existing Markdown and YAML formatting; ShellCheck is the enforced shell linter.

## Design Principles

Treat configuration files and manifests as the sole source of truth. Tests may validate parsing, rendering, syntax, permissions, boundaries, and observable behavior, but must not duplicate volatile configuration facts such as package lists, versions, paths, or defaults in test logic.

Maintain only the current design. Replace superseded paths and behavior in the same change; do not add compatibility aliases, fallback loaders, migration branches, or parallel legacy configuration. Prefer clarity and maintainability over backward compatibility.

## Testing Guidelines

Follow the [local validation policy](CONTRIBUTING.md#local-validation). Finish the requested source edits, documentation, and appropriate safe checks even when a separate live-install signoff is pending. Register new templates in `run-smoke-tests.sh` so relevant OS branches are rendered and syntax-checked. When a manifest format changes, update every consumer of that contract; changing ordinary entries should not require test changes. Report the exact checks run and any environment limitations.

## Commit & Pull Request Guidelines

Do not stage, commit, push, or open a pull request unless requested. When asked, follow the commit rules in `CONTRIBUTING.md` and the pull-request template. Recent history generally uses focused Conventional Commit subjects such as `fix(shell): ...` and `feat(ghostty): ...`. Report smoke-suite and pre-commit results explicitly, and update durable documentation for user-visible behavior.
