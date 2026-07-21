# Local Overlay Examples

Need the broader docs map first? Start at [`docs/README.md`](../README.md).

This directory ships **starter templates** for the local extension points that
the baseline leaves to each user's home directory or user-owned tool config:

| Example | Location pattern | Consumers | Lifecycle |
| --- | --- | --- | --- |
| `env.sh.example` | `$XDG_CONFIG_HOME/oh-my-devenv/env.sh` | Bash and Zsh | persistent environment |
| `bootstrap.env.example` | `$XDG_CONFIG_HOME/oh-my-devenv/bootstrap.env` | bootstrap scripts | bootstrap settings |
| `secrets.sh.example` | `$XDG_CONFIG_HOME/oh-my-devenv/secrets.sh` | interactive Bash and Zsh | interactive secrets |
| `zshrc.zsh.example` | `$XDG_CONFIG_HOME/oh-my-devenv/zshrc.zsh` | Zsh | interactive shell |
| `bashrc.bash.example` | `$XDG_CONFIG_HOME/oh-my-devenv/bashrc.bash` | Bash | interactive shell |
| `gitconfig.local.example` | `$HOME/.gitconfig.local` | Git include | tool-native configuration |
| `git-pre-push.example` | `$XDG_CONFIG_HOME/git/hooks/*` | Git core.hooksPath | tool-native configuration |
| `ssh-config.d.corp.conf.example` | `$HOME/.ssh/config.d/*.conf` | OpenSSH Include | tool-native configuration |
| `npmrc.example` | `$HOME/.npmrc` | npm | tool-native configuration |
| `Brewfile.local.example` | `$XDG_CONFIG_HOME/oh-my-devenv/Brewfile.local` | macOS bootstrap | bootstrap package input |
| `ghostty-config.local.ghostty.example` | `$XDG_CONFIG_HOME/ghostty/config.local.ghostty` | Ghostty | tool-native configuration |

The machine-readable source for this table is
[`bootstrap/manifests/local-overlays.tsv`](../../bootstrap/manifests/local-overlays.tsv).
Uninstall protection and smoke validation read that inventory directly.

## Why `.example`?

Every file in this directory ends in `.example` on purpose:

- `chezmoi` never deploys them to `$HOME`. The repo's `.chezmoiignore` already
  matches `docs/**`, and the `.example` suffix is a second belt: even a mistaken
  removal of that ignore rule would not turn an example into a live overlay.
- The suffix makes it obvious in code review that the file is documentation,
  not something that ships live. Grepping for `.example` quickly enumerates
  every "safe to read" template in the repo.

## Workflow

The managed shells export `XDG_CONFIG_HOME`, defaulting to `$HOME/.config`. If
you are setting up an overlay before the first apply, initialize it in the
current shell first: `export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"`.
Custom values must be absolute and must be exported before running `chezmoi`;
local env files must not set or change `XDG_CONFIG_HOME`.

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
5. For shell overlays, open a new shell to verify. Shell startup reads
   `env.sh`, `secrets.sh`, and the shell-specific rc overlay when present.
   Bootstrap reads `bootstrap.env` independently.
6. For a Git hook copied from `git-pre-push.example`, run `chmod 755 "$XDG_CONFIG_HOME/git/hooks/pre-push"`
   and then test it against one repo that should match your rule and one that
   should not before you trust it.
7. For Ghostty overrides, open a new terminal window after copying the example;
   `ghostty +show-config` should exit successfully and show the effective values.
8. Keep responsibilities clean:
   - `$XDG_CONFIG_HOME/oh-my-devenv/env.sh` is for persistent, non-secret exports that Bash and Zsh should load.
   - `$XDG_CONFIG_HOME/oh-my-devenv/bootstrap.env` is for non-secret settings consumed only by bootstrap tooling.
   - `$XDG_CONFIG_HOME/oh-my-devenv/Brewfile.local` is the single fixed path for macOS-only Homebrew apps and CLIs outside the shared desktop baseline.
   - `$XDG_CONFIG_HOME/oh-my-devenv/secrets.sh` is for shell-compatible secrets that interactive Bash and Zsh read automatically; bootstrap and non-interactive shell commands never read it automatically.
   - `$XDG_CONFIG_HOME/oh-my-devenv/zshrc.zsh` and `$XDG_CONFIG_HOME/oh-my-devenv/bashrc.bash` are late interactive-only overlays for aliases, functions, and prompt tweaks.
   - The managed `~/.gitconfig` keeps your default Git identity; `~/.gitconfig.local` is for user-owned Git preferences and guardrails.
   - `$XDG_CONFIG_HOME/git/hooks/pre-push` is a user-owned guardrail, not part of the shared baseline.
   - `~/.npmrc` is the right home for scoped internal npm registry configuration.
   - `$XDG_CONFIG_HOME/ghostty/config.local.ghostty` is for machine-only appearance, sizing, or keybinding overrides on top of the shared Ghostty baseline.

## macOS Local Homebrew Apps

The selected macOS desktop baseline installs Ghostty, its configured font, and
OrbStack as one bundle. Other macOS GUI apps remain local opt-ins. You can add
them before the first `chezmoi init --apply` by creating the fixed local
Brewfile path:

```bash
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
mkdir -p "$XDG_CONFIG_HOME/oh-my-devenv"
cp docs/local-overlay-examples/Brewfile.local.example \
  "$XDG_CONFIG_HOME/oh-my-devenv/Brewfile.local"
```

The system-package hook reads this file when it exists. The file is deliberately
not part of the hook's `run_onchange` hash, so if you edit it later, sync it
explicitly:

```bash
brew bundle install --file="$XDG_CONFIG_HOME/oh-my-devenv/Brewfile.local"
```

## Optional Vendor Integrations

Vendor-specific shell and SSH integration stays in local overlays. JetBrains
Toolbox users and macOS desktop-baseline users who want OrbStack's shell or SSH
integration should create these overlays; the shared templates do not detect or
initialize either application.

To expose JetBrains Toolbox launchers, add the path for your platform to
`$XDG_CONFIG_HOME/oh-my-devenv/env.sh`:

```bash
# macOS:
toolbox_scripts="$HOME/Library/Application Support/JetBrains/Toolbox/scripts"
# Linux (use this assignment instead on Linux):
# toolbox_scripts="$HOME/.local/share/JetBrains/Toolbox/scripts"

if [[ -d "$toolbox_scripts" && ":$PATH:" != *":$toolbox_scripts:"* ]]; then
  export PATH="${PATH:+$PATH:}$toolbox_scripts"
fi
unset toolbox_scripts
```

For OrbStack PATH and completion initialization, add this guarded Zsh source to
the same `env.sh`. It runs before oh-my-zsh initializes completions and remains
safe when Bash reads the file:

```bash
if [[ -n "${ZSH_VERSION:-}" && -f "$HOME/.orbstack/shell/init.zsh" ]]; then
  source "$HOME/.orbstack/shell/init.zsh"
fi
```

Keep its SSH integration in a user-owned drop-in such as
`~/.ssh/config.d/orbstack.conf`:

```sshconfig
Include ~/.orbstack/ssh/conf*
```

These files are protected by the canonical overlay inventory and remain outside
chezmoi ownership.

## Automation Tokens

Some local automation needs tokens, including coding agents such as Codex or
Claude Code. Keep those tokens in `secrets.sh`, not `env.sh`, and inject them
deliberately by starting the tool from an environment that sourced the file:

```bash
source "$XDG_CONFIG_HOME/oh-my-devenv/secrets.sh"
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
