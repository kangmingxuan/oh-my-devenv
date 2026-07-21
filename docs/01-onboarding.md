# Onboarding — what happens around your first apply

This page goes deeper on the first install after you finish the [Quick Start](../README.md#quick-start) in the root README. Use it when you want more detail on prompts, hook order, success signals, corporate-network exceptions, or troubleshooting.

---

## What you'll have in 5 minutes

After a successful first `chezmoi apply`, you should have:

- **Shells**: managed `zsh` and `bash`; `zsh` includes [oh-my-zsh](https://ohmyz.sh/) and the plugins listed in this repo’s manifest.
- **Runtimes**: `go`, `node`, `python`, and [mise](https://mise.jdx.dev/) as the version manager.
- **Tooling**: `git`, `curl`, `uv`, `golangci-lint`, `shellcheck`, `shfmt`, plus the Go and Python CLI tools declared in `bootstrap/manifests/ecosystem/`.
- **Dotfiles**: managed copies of `~/.zshrc`, `~/.bashrc`, `~/.gitconfig`, mise config, and related files — tuned for a shared baseline, not for one person’s taste.
- **Optional desktop baseline**: Ghostty, Maple Mono NF CN, and managed terminal/font configuration on macOS or non-WSL Ubuntu 26.04+.
- **Python workflow**: `uv` as the only documented package / auth / publish path; no pip-era machine-global config in the baseline.

Exact versions move with `main`; the final check script prints what you actually got on this machine.

---

## Where this page fits

The exact prerequisite install commands and real bootstrap URLs live in the [Quick Start](../README.md#quick-start) section of the root README. This page explains what happens around that first run and what to do if it fails.

You still need **SSH or HTTPS access** to the Git host that holds this repository before the bootstrap can work. You do **not** need Go, Node, or Python installed beforehand; the bootstrap scripts install them.

The shared baseline does not hard-code host-specific Git rewrites. If your environment needs private-host rewrites, SSH aliases, or host-specific guardrails, keep them in local overlays such as `~/.gitconfig.local` or the examples under `docs/local-overlay-examples/`.

Ghostty and its configured font form one explicit shared desktop choice. Other
macOS Homebrew apps such as OrbStack remain local opt-ins. If
you want them installed during the first `chezmoi init --apply`, create a local
Brewfile before running bootstrap and expose it through
`$XDG_CONFIG_HOME/oh-my-devenv/bootstrap.env` with
`DOTFILES_EXTRA_BREWFILES`. The default baseline still does not install
OrbStack or other optional casks.

---

## What you'll be prompted for

`chezmoi` will ask for a **Git author name**, **email address**, and whether to
install the **desktop baseline**. Those values only affect this computer and are
not committed back into the repository.

The desktop choice defaults to yes on macOS and on non-WSL Ubuntu 26.04+ when
the init process can see a graphical-session signal (`XDG_CURRENT_DESKTOP`,
`WAYLAND_DISPLAY`, or `DISPLAY`). It defaults to no elsewhere. The answer is
persisted as `desktopBaseline` in the local chezmoi data, so later applies do not
guess again. To change it deliberately, edit the local config, set
`desktopBaseline = true` or `false` under `[data]`, and apply:

```bash
chezmoi edit-config
chezmoi apply
```

The Git values become the default identity in the managed `~/.gitconfig`. If
you later need a different identity for a specific repository, prefer repo-local
`git config user.name ...` / `git config user.email ...` in that repository
instead of duplicating the machine-wide default in a shared overlay.

On supported Ubuntu machines, the desktop baseline also manages
`$XDG_CONFIG_HOME/fontconfig/conf.d/99-oh-my-devenv-maple-mono-nf-cn.conf`. This rule
prepends Maple Mono NF CN with a strong binding when an application requests
the generic `monospace` family. It is the Linux compatibility path used by
Ghostty, and it intentionally affects every Fontconfig client that requests
generic `monospace`. Turning off `desktopBaseline` and applying again leaves a
valid but inactive managed fragment, so the preference does not linger.

---

## What to expect during apply

Bootstrap is split into ordered hooks under `.chezmoiscripts/`:

0. **`run_before_00-*`** — prints the startup banner (hide it with `NO_LOGO=1`).
1. **`run_once_before_10-*`** — one-time prerequisites and, if needed, **backup** of any pre-existing managed files before they are overwritten.
2. **`run_onchange_after_20-*`** — system packages (`apt` on Linux / WSL, Homebrew on macOS), plus explicit macOS Homebrew opt-ins from `DOTFILES_INSTALL_REPO_OPTIONAL_BREWFILE` or `DOTFILES_EXTRA_BREWFILES`.
3. **`run_onchange_after_22-*`** — when selected, installs Ghostty and Maple Mono NF CN from the platform-specific desktop manifests.
4. **`run_onchange_after_25-*`** — shell assets (oh-my-zsh and plugins from the manifest).
5. **`run_onchange_after_30-*`** — install mise itself.
6. **`run_after_35-*`** — apply the dedicated `xdg_config/` chezmoi source directly under `$XDG_CONFIG_HOME`.
7. **`run_onchange_after_40-*`** — install language runtimes via mise.
8. **`run_onchange_after_50-*`** — sync ecosystem tools (`go install`, `uv tool`, etc.).
9. **`run_onchange_after_60-*`** — final environment check and a short “welcome” summary.

The generated chezmoi config excludes scripts from `chezmoi status`, so routine hook runs do not make a clean setup look locally modified.

The baseline also defaults `mise` GitHub attestation verification to off during installs, because fresh machines behind a shared egress IP can otherwise hit GitHub API rate limits while fetching `uv`, `golangci-lint`, or Python. If you explicitly want attestation verification on your machine, re-run with `MISE_GITHUB_ATTESTATIONS=true MISE_AQUA_GITHUB_ATTESTATIONS=true`. Python follows that global setting unless you set `MISE_PYTHON_GITHUB_ATTESTATIONS` separately.

---

## How to tell it worked

The last hook runs `run_onchange_after_60-check.sh`. On success you should see:

- The line **`All checks passed.`**
- A block titled **`Core tools in this environment:`** listing versions for `chezmoi`, `git`, `mise`, `go`, `node`, `python`, `uv`, and `golangci-lint`.
- A short **`Next steps:`** list at the very end (shell reload hint, this onboarding doc, `docs/local-overlay-examples/`, corporate-network + `DOTFILES_MIRROR_MODE`, and the Bug issue template) so you are not dropped back to a silent prompt after a long apply.

If anything fails, the script exits non-zero and prints diagnostic hints — see **Something broke** below.

---

## Restricted network?

If you are on a corporate or otherwise restricted network, public registries may be slow or blocked. Keep those overrides local to your machine rather than baking them into the shared baseline. Start from [**Local overlay examples**](local-overlay-examples/README.md) before your first apply:

- Put persistent Go settings in `$XDG_CONFIG_HOME/oh-my-devenv/env.sh`
- Put bootstrap mirror settings in `$XDG_CONFIG_HOME/oh-my-devenv/bootstrap.env`
- Keep internal npm scopes in `~/.npmrc`, not in shell startup files
- Keep Python internal indexes project-local and `uv`-only
- Set **`DOTFILES_MIRROR_MODE`** in `bootstrap.env` or export it before `chezmoi init --apply` when bootstrap itself needs mirror endpoints
- On Ubuntu, the pinned Maple Mono archive uses a resumable download and SHA-256 verification. If GitHub Releases is unavailable, set **`DOTFILES_MAPLE_MONO_URL`** to an alternate URL serving the exact same archive.

---

## What to do next

1. **Reload your shell** (or `source` your `~/.zshrc` / `~/.bashrc`) so `PATH`, completions, and any optional `$XDG_CONFIG_HOME/oh-my-devenv/env.sh` exports pick up the new tools.
2. If you need machine-only tweaks, start from the templates under [`docs/local-overlay-examples/`](local-overlay-examples/README.md) — they are **not** deployed by default.
3. Keep [`02-reference.md`](02-reference.md) handy for day-to-day commands and every environment variable / flag, or jump to [`docs/README.md`](README.md) for the full docs map.

---

## Something broke

1. Re-run with **`chezmoi apply --verbose --debug`** (or `chezmoi init --apply ...` again) and capture the failing step.
2. If the bootstrap warned about overwriting existing files, inspect backups under **`${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi-first-run-backup/<timestamp>/`**.
3. Open an issue using the repository's bug-report workflow so the report includes OS, command, and logs.

Do **not** paste secrets, tokens, or internal hostnames into public issues.
