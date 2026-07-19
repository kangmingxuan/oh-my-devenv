# Local Overlay Examples

Need the broader docs map first? Start at [`docs/README.md`](../README.md).

This directory ships **starter templates** for the local extension points that
the baseline leaves to each user's home directory or user-owned tool config:

| Example file                            | Real overlay location              | Sourced / read by                                   |
| --------------------------------------- | ---------------------------------- | --------------------------------------------------- |
| `env.sh.example`                        | `${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/env.sh` | `~/.zsh/env.zsh`, `~/.bash/env.bash`, `bootstrap/scripts/common.sh` |
| `secrets.sh.example`                    | `${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/secrets.sh` | `~/.zshrc`, `~/.bashrc` |
| `zshrc.zsh.example`                     | `${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/zshrc.zsh` | Baseline `dot_zshrc.tmpl` via a guarded `source`    |
| `bashrc.bash.example`                   | `${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/bashrc.bash` | Baseline `dot_bashrc.tmpl` via a guarded `source`   |
| `gitconfig.local.example`               | `~/.gitconfig.local`               | Baseline `dot_gitconfig.tmpl` via `[include]`       |
| `git-pre-push.example`                  | `~/.config/git/hooks/pre-push`     | Git via `core.hooksPath`                            |
| `ssh-config.d.corp.conf.example`        | `~/.ssh/config.d/<your-alias>.conf` | `~/.ssh/config` via its `Include ~/.ssh/config.d/*.conf` directive |
| `npmrc.example`                         | `~/.npmrc`                         | `npm`                                               |
| `Brewfile.local.example`                | `${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/Brewfile.local` | macOS bootstrap when `DOTFILES_EXTRA_BREWFILES` points to it |
| `ghostty-config.local.ghostty.example`  | `${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/config.local.ghostty` | Managed Ghostty `config.ghostty` via `config-file` |

## Why `.example`?

Every file in this directory ends in `.example` on purpose:

- `chezmoi` never deploys them to `$HOME`. The repo's `.chezmoiignore` already
  matches `docs/**`, and the `.example` suffix is a second belt: even a mistaken
  removal of that ignore rule would not turn an example into a live overlay.
- The suffix makes it obvious in code review that the file is documentation,
  not something that ships live. Grepping for `.example` quickly enumerates
  every "safe to read" template in the repo.

## Workflow

1. Pick the example file that matches the extension point you want to use.
2. Copy it to the real overlay location shown in the table above, **dropping the
   `.example` suffix**. For `~/.ssh/config.d/*.conf`, also rename it to something
   meaningful for you (e.g. `~/.ssh/config.d/work.conf`).
3. Fill in the `<placeholder>` tokens. Every placeholder is wrapped in angle
   brackets so a grep like `grep -RE '<[a-z-]+>' ~/.gitconfig.local` will catch
   anything you forgot.
4. For SSH config, the baseline-managed `~/.ssh/config` already includes
   `~/.ssh/config.d/*.conf` before its `Host *` catch-all. If you adapt these
   examples outside this baseline or keep a hand-managed top-level config, add
   that `Include` line before any `Host *` block.
5. For shell overlays, open a new shell to verify. The files under
   `${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/` are all guarded by
   `[[ -f ... ]]` sources in the baseline, so a missing file is silently ignored
   and a present file is loaded on next shell start.
6. For a Git hook copied from `git-pre-push.example`, run `chmod 755 ~/.config/git/hooks/pre-push`
   and then test it against one repo that should match your rule and one that
   should not before you trust it.
7. For Ghostty overrides, open a new terminal window after copying the example;
   `ghostty +show-config` should exit successfully and show the effective values.
8. Keep responsibilities clean:
   - `${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/env.sh` is for shell-compatible, non-secret exports that Bash, Zsh, and bootstrap should all see.
   - `${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/Brewfile.local` is for macOS-only Homebrew apps and CLIs that you explicitly opt in to during first bootstrap.
   - `${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/secrets.sh` is for shell-compatible secrets that interactive Bash and Zsh read automatically; bootstrap and non-interactive shell commands never read it automatically.
   - `${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/zshrc.zsh` and `${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/bashrc.bash` are late interactive-only overlays for aliases, functions, and prompt tweaks.
   - The managed `~/.gitconfig` keeps your default Git identity; `~/.gitconfig.local` is for user-owned Git preferences and guardrails.
   - `~/.config/git/hooks/pre-push` is a user-owned guardrail, not part of the shared baseline.
   - `~/.npmrc` is the right home for scoped internal npm registry configuration.
   - `~/.config/ghostty/config.local.ghostty` is for machine-only appearance, sizing, or keybinding overrides on top of the shared Ghostty baseline.

## macOS Local Homebrew Apps

The selected desktop baseline installs only Ghostty and its configured font.
Other macOS GUI apps remain local opt-ins. You can add them before the first
`chezmoi init --apply` by creating a local Brewfile and pointing bootstrap at it
from `env.sh`:

```bash
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv"
cp docs/local-overlay-examples/Brewfile.local.example \
  "${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/Brewfile.local"
printf '%s\n' \
  'export DOTFILES_EXTRA_BREWFILES="${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/Brewfile.local"' \
  >> "${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/env.sh"
```

To install the repo-maintained optional catalog instead, set
`DOTFILES_INSTALL_REPO_OPTIONAL_BREWFILE=1` in the same `env.sh`. These opt-ins
are read by the first system-package hook. Paths in `DOTFILES_EXTRA_BREWFILES`
must expand to absolute paths, and missing files fail bootstrap instead of being
silently skipped. If you edit `Brewfile.local` later, sync it explicitly:

```bash
brew bundle install --file="${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/Brewfile.local"
```

## Automation Tokens

Some local automation needs tokens, including coding agents such as Codex or
Claude Code. Keep those tokens in `secrets.sh`, not `env.sh`, and inject them
deliberately by starting the tool from an environment that sourced the file:

```bash
source "${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/secrets.sh"
codex
```

Use the tool's own secret or environment configuration when that is a better
fit. The baseline intentionally does not make non-interactive shell commands
source `secrets.sh`.

## What Belongs Here vs. Upstream

These overlays exist specifically for values that **must not** be part of the
shared baseline:

- Personal identity (your real name and email for git commits)
- Corporate or team-specific hostnames, proxies, rewrites, and aliases that do not belong in the shared baseline
- Secrets (tokens, credentials) — even revoked ones
- Machine-local toggles that only make sense on one workstation

If you find yourself copy-pasting the same content into more than a few local
overlays, that is a signal the baseline should grow a neutral, parameterized
version of it. File an issue instead of maintaining the overlay in every
teammate's `~/`.

## What Does **Not** Belong Here

- Anything with a real hostname, IP address, user handle, or token, even in a
  comment. The directory is committed to the repo and scanned by gitleaks.
- Any local overlay that replaces or edits `~/.ssh/config` itself. The baseline
  owns that top-level config; local host additions should stay in
  `~/.ssh/config.d/*.conf` fragments.
- The default machine-wide `[user]` block that the baseline already writes into
   `~/.gitconfig`. Keep that machine-wide fallback in the managed file; use
  `~/.gitconfig.local` only for exceptions.
- Any file that the baseline should be responsible for. If adding a new key
  here would duplicate what `dot_gitconfig.tmpl` or `dot_zshrc.tmpl` already
  declare, update the baseline instead.
