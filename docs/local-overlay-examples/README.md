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
4. For SSH config, the baseline-managed `~/.ssh/config` already includes
   `~/.ssh/config.d/*.conf` before its `Host *` catch-all. If you adapt these
   examples outside this baseline or keep a hand-managed top-level config, add
   that `Include` line before any `Host *` block.
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
   - `~/.zsh/work.zsh` and `~/.bash/work.bash` are late interactive-only overlays for aliases, functions, and prompt tweaks.
   - `~/.npmrc` is the right home for scoped internal npm registry configuration.

## Dual Worktree Setup

If you maintain both a public GitHub copy and an internal overlay, keep them in
**separate worktrees** so each one can carry the right Git identity and default
push remote.

Recommended shape:

1. Create the extra worktree from the shared repository clone:

   ```bash
   git worktree add ~/workspace/oh-my-devenv-public public-upstream
   git worktree add ~/workspace/oh-my-devenv-internal main
   ```

2. Enable per-worktree Git config in the repository:

   ```bash
   git -C ~/workspace/oh-my-devenv-public config extensions.worktreeConfig true
   ```

3. Set the **public** worktree identity and default push remote:

   ```bash
   git -C ~/workspace/oh-my-devenv-public config --worktree user.name "<your-name>"
   git -C ~/workspace/oh-my-devenv-public config --worktree user.email "<your-public-email>"
   git -C ~/workspace/oh-my-devenv-public config --worktree remote.pushDefault public
   ```

4. Set the **internal** worktree identity and default push remote:

   ```bash
   git -C ~/workspace/oh-my-devenv-internal config --worktree user.name "<your-name>"
   git -C ~/workspace/oh-my-devenv-internal config --worktree user.email "<your-work-email>"
   git -C ~/workspace/oh-my-devenv-internal config --worktree remote.pushDefault origin
   ```

5. Validate that the split stuck:

   ```bash
   git -C ~/workspace/oh-my-devenv-public config --worktree --get user.email
   git -C ~/workspace/oh-my-devenv-public config --worktree --get remote.pushDefault
   git -C ~/workspace/oh-my-devenv-internal config --worktree --get user.email
   git -C ~/workspace/oh-my-devenv-internal config --worktree --get remote.pushDefault
   ```

Keep the machine-wide fallback identity in the managed `~/.gitconfig`, and keep
the worktree-specific identities in the repositories themselves. Do **not** try
to solve the public/internal split by editing `~/.gitconfig.local` before every
commit.

If you are also using the pre-push guardrail, export `WORK_EMAIL_SUFFIX` and
`WORK_GIT_HOST` from a local secrets file or hard-code them in the copied hook
on your machine. The hook will then block the two common mistakes:

- pushing a work identity to a non-work remote
- pushing a non-work identity to the protected work remote

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
