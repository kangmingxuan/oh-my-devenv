# Contributing

This repository is a public, opinionated development environment managed by [chezmoi](https://www.chezmoi.io/). Personal taste is part of the product: changes should strengthen one coherent current design rather than approximate a neutral default for everyone. Everything that lands here is rendered on every tracking machine, so it must remain reproducible, safe to publish, and free of private identities, credentials, infrastructure, and machine state.

## Scope

Changes that belong in this repository:

- System packages selected as part of the maintained environment (editors, `git`, `curl`, formatting and diagnostic tools).
- The explicitly selected, platform-specific desktop baseline on supported workstations, including OrbStack on macOS.
- Baseline shell, Git, SSH, and runtime templates that work on macOS, Ubuntu/Debian, and WSL.
- Public coding-agent instructions and secret-free settings that express the maintained workflow.
- Source-only bootstrap scripts and their smoke-test coverage.
- Documentation describing the baseline and its maintenance.

Changes that do **not** belong in this repository:

- Personal identifiers (real names, personal emails, personal domains).
- Personal SSH hosts, internal IP ranges, or private infrastructure hostnames that are not safe in a public repository.
- Generated agent state, transcripts, caches, trust decisions, or machine-local permissions.
- Anything that requires a private credential or private network to validate.

Use the documented local extension points for machine-specific or team-specific
values. The complete paths, consumers, lifecycles, and copyable examples live
in [`docs/local-overlay-examples/README.md`](docs/local-overlay-examples/README.md);
[`bootstrap/manifests/local-overlays.tsv`](bootstrap/manifests/local-overlays.tsv)
is the canonical inventory enforced by smoke tests and uninstall protection.

The repository represents only the latest design. When a design changes, replace
the old path in the same change; do not add compatibility aliases, fallback
loaders, or parallel legacy configuration. Recovery belongs in backups and Git
history, not runtime branches.

## Development Workflow

1. Create a feature branch from `main`.
2. Make focused changes. Prefer one topic per pull request.
3. Run the smoke tests locally before opening a pull request:

   ```bash
   bash bootstrap/scripts/run-smoke-tests.sh
   ```

4. If you modify templates, bootstrap scripts, or manifest files, also run:

   ```bash
   pre-commit run --all-files
   ```

5. Open a pull request against `main` using the repository's review template when one is provided.

## Commit Style

- Use imperative, present-tense subject lines (`Add ...`, `Fix ...`, `Update ...`).
- Keep the subject line under 72 characters.
- Explain the "why" in the body when the change is not obvious from the diff.
- Group related changes into a single commit when it helps review; split unrelated changes.

## Templates And Rendering

- Shell and application templates (`dot_*.tmpl`, `dot_*/env.*.tmpl`, and `xdg_config/**/*.tmpl`) must render on macOS and Linux/WSL, with and without optional integrations.
- The templates are smoke-tested by rendering them with `chezmoi execute-template` and syntax-checking the output with the corresponding shell.
- When you add a new template, add it to `bootstrap/scripts/run-smoke-tests.sh` so rendering and syntax checks are enforced on every change.
- Tests verify parsing, rendering, syntax, permissions, management boundaries, and user-visible behavior. Do not duplicate literal configuration values in test code; the configuration file is their source of truth.

## Manifest Contracts

The following source manifests are consumed by both the installer scripts and the post-install check script. Keep both sides in sync:

- `bootstrap/manifests/shell/oh-my-zsh-plugins.txt`
- `bootstrap/manifests/system/apt-packages.txt`
- `bootstrap/manifests/system/Brewfile`
- `bootstrap/manifests/desktop/apt-packages.txt`
- `bootstrap/manifests/desktop/Brewfile`
- `bootstrap/manifests/desktop/maple-mono-nf-cn.env`
- `bootstrap/manifests/ecosystem/go-tools.txt`
- `bootstrap/manifests/ecosystem/uv-tools.txt`

If you add, rename, or remove an entry, confirm that:

- The corresponding installer script handles the new entry.
- `run-smoke-tests.sh` still passes locally.
- The post-install environment check continues to recognize the tool.

## Secret Hygiene

- Never commit real credentials, tokens, or keys.
- [gitleaks](https://github.com/gitleaks/gitleaks) runs through `pre-commit` to catch the common patterns.
- If you intentionally add a non-secret fixture that trips gitleaks, prefer moving it out of the repo or using an obvious placeholder. Use a narrowly scoped `gitleaks:allow` comment only as a last resort.

## CI

The repository CI runs on GitHub Actions for every push and pull request: `run-smoke-tests.sh` on both `ubuntu-latest` and `macos-latest`, a real `chezmoi init --apply` (`apply-linux`), and a `gitleaks` secret scan. A change should not be merged while the pipeline is failing.

## Reporting Issues

When reporting a bug, include:

- OS and architecture (for example, `macOS 15 arm64`, `Ubuntu 24.04 amd64`, `WSL Ubuntu 24.04`).
- chezmoi version (`chezmoi --version`).
- The exact command you ran and the observed output.
- Whether the issue reproduces with a clean `$HOME` or only on an existing machine.
