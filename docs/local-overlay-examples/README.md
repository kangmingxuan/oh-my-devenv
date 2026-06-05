# Local Overlay Examples

Need the broader docs map first? Start at [`docs/README.md`](../README.md).

This directory ships **starter templates** for the local extension points that
the baseline leaves to each user's home directory or user-owned tool config:

| Example file                            | Real overlay location              | Sourced / read by                                   |
| --------------------------------------- | ---------------------------------- | --------------------------------------------------- |
| `work-env.sh.example`                   | `${XDG_CONFIG_HOME:-$HOME/.config}/work/env.sh` | `~/.zsh/env.zsh`, `~/.bash/env.bash`, `bootstrap/scripts/common.sh` |
| `gitconfig.local.example`               | `~/.gitconfig.local`               | Baseline `dot_gitconfig.tmpl` via `[include]`       |
| `git-pre-push.example`                  | `~/.config/git/hooks/pre-push`     | Git via `core.hooksPath`                            |
| `ssh-config.d.corp.conf.example`        | `~/.ssh/config.d/<your-alias>.conf` | `~/.ssh/config` via its `Include ~/.ssh/config.d/*.conf` directive |
| `zshrc.secrets.example`                 | `~/.zshrc.secrets`                 | Baseline `dot_zshrc.tmpl` via a guarded `source`    |
| `bashrc.secrets.example`                | `~/.bashrc.secrets`                | Baseline `dot_bashrc.tmpl` via a guarded `source`   |
| `zsh-work.zsh.example`                  | `~/.zsh/work.zsh`                  | Baseline `dot_zshrc.tmpl` via a guarded `source`    |
| `bash-work.bash.example`                | `~/.bash/work.bash`                | Baseline `dot_bashrc.tmpl` via a guarded `source`   |
| `npmrc.example`                         | `~/.npmrc`                         | `npm`                                               |

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
4. For SSH config, make sure `~/.ssh/config` contains the line
   `Include ~/.ssh/config.d/*.conf` before any `Host *` catch-all. If you do
   not yet have an `~/.ssh/config`, create one and paste `Include` as the first
   non-comment line.
5. For shell overlays, open a new shell to verify. `${XDG_CONFIG_HOME:-$HOME/.config}/work/env.sh`,
   `~/.zshrc.secrets`, `~/.bashrc.secrets`, `~/.zsh/work.zsh`, and
   `~/.bash/work.bash` are all guarded by `[[ -f ... ]]` sources in the
   baseline, so a missing file is silently ignored and a present file is loaded
   on next shell start.
6. For a Git hook copied from `git-pre-push.example`, run `chmod 755 ~/.config/git/hooks/pre-push`
   and then test it against one repo that should match your rule and one that
   should not before you trust it.
7. Keep responsibilities clean:
   - `${XDG_CONFIG_HOME:-$HOME/.config}/work/env.sh` is for shell-compatible, non-secret exports that Bash, Zsh, and bootstrap should all see.
   - The managed `~/.gitconfig` keeps your default Git identity; `~/.gitconfig.local` is for user-owned Git preferences and guardrails.
   - `~/.config/git/hooks/pre-push` is a user-owned guardrail, not part of the shared baseline.
   - `~/.zsh/work.zsh` and `~/.bash/work.bash` are interactive-only overlays for aliases, functions, and prompt tweaks.
   - `~/.npmrc` is the right home for scoped internal npm registry configuration.

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
- Any file that changes `~/.ssh/config` itself (the top-level SSH config).
  Modifying `~/.ssh/config` from a dotfiles repo fights with sshd updates and
  other local tooling; stick to `~/.ssh/config.d/*.conf` fragments.
- The default machine-wide `[user]` block that the baseline already writes into
   `~/.gitconfig`. Keep that machine-wide fallback in the managed file; use
  `~/.gitconfig.local` only for exceptions.
- Any file that the baseline should be responsible for. If adding a new key
  here would duplicate what `dot_gitconfig.tmpl` or `dot_zshrc.tmpl` already
  declare, update the baseline instead.
