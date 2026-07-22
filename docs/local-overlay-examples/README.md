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
| `git-config.example` | `$XDG_CONFIG_HOME/oh-my-devenv/git/config` | Git include | tool-native configuration |
| `git-pre-push.example` | `$XDG_CONFIG_HOME/oh-my-devenv/git/hooks/*` | Git configured hooks (2.54+) | tool-native guardrails |
| `ssh-config.d.corp.conf.example` | `$HOME/.ssh/config.d/*.conf` | OpenSSH Include | tool-native configuration |
| `npmrc.example` | `$HOME/.npmrc` | npm | tool-native configuration |
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
   brackets so a grep like
   `grep -RE '<[a-z-]+>' "$XDG_CONFIG_HOME/oh-my-devenv"` will catch anything
   you forgot.
4. For SSH config, the baseline-managed `~/.ssh/config` already includes
   `~/.ssh/config.d/*.conf` before its `Host *` catch-all. If you adapt these
   examples outside this baseline or keep a hand-managed top-level config, add
   that `Include` line before any `Host *` block.
5. For shell overlays, open a new shell to verify. Shell startup reads
   `env.sh`, `secrets.sh`, and the shell-specific rc overlay when present.
   Bootstrap reads `bootstrap.env` independently.
6. For a Git hook copied from `git-pre-push.example`, follow the registration
   steps below, then test it against one repo that should match your rule and
   one that should not before you trust it.
7. For Ghostty overrides, open a new terminal window after copying the example;
   `ghostty +show-config` should exit successfully and show the effective values.
8. Keep responsibilities clean:
   - `$XDG_CONFIG_HOME/oh-my-devenv/env.sh` is for persistent, non-secret exports that Bash and Zsh should load.
   - `$XDG_CONFIG_HOME/oh-my-devenv/bootstrap.env` is for non-secret settings consumed only by bootstrap tooling.
   - `$XDG_CONFIG_HOME/oh-my-devenv/secrets.sh` is for shell-compatible secrets that interactive Bash and Zsh read automatically; bootstrap and non-interactive shell commands never read it automatically.
   - `$XDG_CONFIG_HOME/oh-my-devenv/zshrc.zsh` and `$XDG_CONFIG_HOME/oh-my-devenv/bashrc.bash` are late interactive-only overlays for aliases, functions, and prompt tweaks.
   - The managed `~/.gitconfig` keeps your default Git identity; `$XDG_CONFIG_HOME/oh-my-devenv/git/config` is for user-owned Git preferences and guardrail registration.
   - `$XDG_CONFIG_HOME/oh-my-devenv/git/hooks/*` contains user-owned Git 2.54+ configured hooks, not shared baseline behavior.
   - `~/.npmrc` is the right home for scoped internal npm registry configuration.
   - `$XDG_CONFIG_HOME/ghostty/config.local.ghostty` is for machine-only appearance, sizing, or keybinding overrides on top of the shared Ghostty baseline.

## Git Configuration and Hooks

Copy the Git config and guardrail examples into the project-owned XDG namespace:

```bash
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
install -d "$XDG_CONFIG_HOME/oh-my-devenv/git/hooks"
cp docs/local-overlay-examples/git-config.example \
  "$XDG_CONFIG_HOME/oh-my-devenv/git/config"
cp docs/local-overlay-examples/git-pre-push.example \
  "$XDG_CONFIG_HOME/oh-my-devenv/git/hooks/pre-push"
chmod 755 "$XDG_CONFIG_HOME/oh-my-devenv/git/hooks/pre-push"
git config --file "$XDG_CONFIG_HOME/oh-my-devenv/git/config" \
  hook.oh-my-devenv-identity-guard.command \
  "$XDG_CONFIG_HOME/oh-my-devenv/git/hooks/pre-push"
git config --file "$XDG_CONFIG_HOME/oh-my-devenv/git/config" \
  hook.oh-my-devenv-identity-guard.event pre-push
```

Git does not expand `$XDG_CONFIG_HOME` in config values, so the setup commands
store its resolved absolute value. The equivalent commented config block stays
in `git-config.example` as reference. This configured-hook mechanism requires
Git 2.54 or newer. It adds the machine guardrail without setting
`core.hooksPath`; Git runs the repository's traditional `.git/hooks/pre-push`
afterward.

Verify the effective hook list before relying on it:

```bash
git hook list --show-scope pre-push
```

Older Git versions are not supported for this optional central guardrail. Keep
using repository-local `.git/hooks/*` on those machines instead; the project
does not ship a wrapper or compatibility path.

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
  `~/.gitconfig`. Keep that machine-wide fallback in the managed file; use the
  XDG Git overlay only for exceptions.
- Any file that the baseline should be responsible for. If adding a new key
  here would duplicate what `dot_gitconfig.tmpl` or `dot_zshrc.tmpl` already
  declare, update the baseline instead.
