# Contributing

This repository is a public, opinionated development environment managed by [chezmoi](https://www.chezmoi.io/). Personal taste is part of the product: changes should strengthen one coherent current design rather than approximate a neutral default for everyone. Everything that lands here is rendered on every tracking machine, so it must remain reproducible, safe to publish, and free of private identities, credentials, infrastructure, and machine state.

## Scope

Changes that belong in this repository:

- System packages selected as part of the maintained environment (editors, `git`, `curl`, formatting and diagnostic tools).
- The explicitly selected, platform-specific desktop baseline on supported workstations, including OrbStack on macOS.
- Baseline shell, Git, SSH, and runtime templates that work on macOS, Ubuntu/Debian, and Arch Linux.
- Source-only bootstrap scripts and their smoke-test coverage.
- Documentation describing the baseline and its maintenance.

Changes that do **not** belong in this repository:

- Personal identifiers (real names, personal emails, personal domains).
- Personal SSH hosts, internal IP ranges, or private infrastructure hostnames that are not safe in a public repository.
- Team- or project-specific tooling that only a subset of users need.
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
3. Select and run the checks in [Local Validation](#local-validation).
4. Record each check as passed, failed, not run, or not applicable, with a reason
   for anything other than passed.
5. Open a pull request against `main` using the repository's review template when one is provided.

## Local Validation

Use this table as the canonical local validation policy. Select checks from the
behavior changed, not from the operating system named in prose. Once the
appropriate checks pass, do not repeat them unless the source changes, a check
fails, or an unresolved concern needs more evidence.

| Change | Required local validation |
| --- | --- |
| Prose, links, or comments only, excluding documentation fixtures consumed by smoke tests | Targeted review of the changed text, links, and formatting. Smoke tests and `pre-commit` may be reported as not applicable. Documentation that discusses macOS does not by itself require a real macOS install. |
| Bootstrap scripts, chezmoi templates, manifests, deployment or ignore boundaries, or documentation fixtures consumed by smoke tests (the local-overlay examples) | Run `bash bootstrap/scripts/run-smoke-tests.sh`. The suite renders and syntax-checks templates, checks contracts and deployment boundaries, exercises the shared checker and selected installers with stubs, tests local font archives and rollback behavior, applies the nested XDG source under temporary roots, and runs ShellCheck. It does not install system packages or runtimes, run a complete bootstrap, or apply to the real home directory. |
| Executable or configuration behavior, including workflow, pre-commit, or scan configuration | Run `pre-commit run --all-files`. The ShellCheck hook covers `bootstrap/scripts/*.sh`; the gitleaks hook scans staged changes only, so a pass before staging does not cover the unstaged diff. CI performs the separate repository-wide secret scan. Also run smoke tests when the change falls in the preceding row. |
| A concrete macOS installation concern that `apply-macos` cannot cover, such as specific hardware, another macOS or Xcode CLT version, or existing-machine state and overlays | Complete the lighter checks and require the relevant CI jobs to pass at the reviewed SHA. Then follow the manual [macOS preflight](docs/04-macos-preflight.md). Routine macOS package, installer, runtime, activation, or post-install-check changes covered by `apply-macos` do not trigger manual preflight. Pure prose, links, comments, and render-only configuration changes do not require the full preflight. |

The smoke suite is source verification and is safe to run locally: its write
operations use temporary fixture directories and stub commands. A real
`chezmoi apply`, bootstrap installer, or full macOS preflight can change the
user's home directory or installed toolchain and therefore requires explicit
authorization. If that authorization is pending, finish the requested source
changes and safe checks, record the manual signoff as not run, and hold merge
readiness until the signoff is available.

## Commit Style

- Use imperative, present-tense subject lines (`Add ...`, `Fix ...`, `Update ...`).
- Keep the subject line under 72 characters.
- Explain the "why" in the body when the change is not obvious from the diff.
- Group related changes into a single commit when it helps review; split unrelated changes.

## Templates And Rendering

All repository Bash code, including rendered `.chezmoiscripts/` hooks, Linux-only
scripts, and managed Bash dotfiles, must be compatible with Bash 3.2, the macOS
`/bin/bash`. Do not use Bash 4+ features; under `set -u`, expand potentially
empty arrays with `${arr[@]+"${arr[@]}"}`. The `smoke-tests-macos` job puts a
`bash` symlink to `/bin/bash` first on `PATH`, so the suite and every script it
executes run on Bash 3.2. For code the suite does not execute, it runs `bash -n`
and rejects Bash 4+ builtins and expansions such as `mapfile` and associative
arrays. The Linux and Arch smoke jobs use distribution Bash (5.x).

To check locally on a Mac with a newer Bash first on `PATH`:

```bash
mkdir -p /tmp/system-bash && ln -sf /bin/bash /tmp/system-bash/bash
PATH="/tmp/system-bash:$PATH" bash bootstrap/scripts/run-smoke-tests.sh
```

The font archive fixtures require `zip` and `unzip`. Smoke CI installs both on
Ubuntu and Arch. macOS provides both tools.

- Shell and application templates (`dot_*.tmpl`, `dot_*/env.*.tmpl`, and `xdg_config/**/*.tmpl`) must render on macOS and Linux, with and without optional integrations.
- The smoke suite renders templates with `chezmoi execute-template`, syntax-checks the output with the corresponding shell, and exercises selected behavior in temporary fixture directories.
- Every hook under `.chezmoiscripts/` is rendered for each supported platform automatically. When you add another template, add it to `bootstrap/scripts/run-smoke-tests.sh` so rendering and syntax checks are enforced on every change.
- Tests verify parsing, rendering, syntax, permissions, management boundaries, and user-visible behavior. Do not duplicate literal configuration values in test code; the configuration file is their source of truth.

## Manifest Contracts

The installer scripts and `bootstrap/scripts/check.sh` consume the following source manifests. Keep both sides in sync:

- `bootstrap/manifests/shell/oh-my-zsh-plugins.txt`
- `bootstrap/manifests/shell/completions.txt`
- `bootstrap/manifests/system/apt-packages.txt`
- `bootstrap/manifests/system/pacman-packages.txt`
- `bootstrap/manifests/system/Brewfile`
- `bootstrap/manifests/desktop/apt-packages.txt`
- `bootstrap/manifests/desktop/pacman-packages.txt`
- `bootstrap/manifests/desktop/Brewfile`
- `bootstrap/manifests/desktop/maple-mono-nf-cn.env`
- `bootstrap/manifests/ecosystem/go-tools.txt`
- `bootstrap/manifests/ecosystem/uv-tools.txt`
- `xdg_config/mise/config.toml.tmpl` (validated natively by `mise`)

If you add, rename, or remove an entry, confirm that:

- The corresponding installer script handles the new entry. A new completion command also needs a generator adapter in `install-shell-completions.sh` unless it reuses an existing one.
- `run-smoke-tests.sh` still passes locally. Ordinary entry changes must not require test edits; the suite validates schemas, rendering, and behavior rather than current values.
- The post-install environment check continues to recognize the tool.

## Secret Hygiene

- Never commit real credentials, tokens, or keys.
- [gitleaks](https://github.com/gitleaks/gitleaks) runs through `pre-commit` to catch the common patterns.
- If you intentionally add a non-secret fixture that trips gitleaks, prefer moving it out of the repo or using an obvious placeholder. Use a narrowly scoped `gitleaks:allow` comment only as a last resort.

## CI

The repository CI runs on GitHub Actions for every push and pull request. Smoke jobs run `run-smoke-tests.sh` on `ubuntu-latest`, `macos-latest`, and an `archlinux:base` container. Four jobs run a real `chezmoi apply`: `apply-linux` covers the non-desktop Ubuntu path with a custom `XDG_CONFIG_HOME` and backup assertions; `apply-ubuntu-desktop` uses `ubuntu:26.04`; `apply-arch` uses `archlinux:base`; and `apply-macos` uses `macos-latest`. The last three enable the desktop baseline. Every apply job asserts `All checks passed.` and runs `bash bootstrap/scripts/check.sh <config>`. The macOS job installs the OrbStack cask without launching OrbStack. A separate job runs the `gitleaks` secret scan. Do not merge a change while the pipeline is failing.

## Reporting Issues

When reporting a bug, include:

- OS and architecture (for example, `macOS 15 arm64` or `Ubuntu 24.04 amd64`).
- chezmoi version (`chezmoi --version`).
- The exact command you ran and the observed output.
- Whether the issue reproduces with a clean `$HOME` or only on an existing machine.
