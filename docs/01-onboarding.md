# Onboarding — what happens around your first apply

This page provides more detail around the first install in the [Quick Start](../README.md#quick-start) in the root README. Use it when you want more detail on prompts, hook order, success signals, corporate-network exceptions, or troubleshooting.

## Where this page fits

The exact prerequisite install commands and real bootstrap URLs live in the [Quick Start](../README.md#quick-start) section of the root README. This page explains what happens around that first run and what to do if it fails.

You still need **SSH or HTTPS access** to the Git host that holds this repository before the bootstrap can work. You do **not** need Go, Node, or Python installed beforehand; the bootstrap scripts install them.

The public baseline does not hard-code private Git rewrites. If your environment needs private-host rewrites, SSH aliases, or host-specific guardrails, keep them in the XDG-based overlays under `$XDG_CONFIG_HOME/oh-my-devenv/` or the other tool-owned slots documented under `docs/local-overlay-examples/`.

The desktop choice is one platform-specific bundle rather than a set of
component switches. On macOS it installs Ghostty, Maple Mono NF CN, and
OrbStack together; on supported Ubuntu machines it installs the terminal,
font, and required Fontconfig rule. Homebrew only installs the OrbStack app:
launch it once to finish setup. Using OrbStack for freelance, business, or
professional work requires a paid [OrbStack license](https://docs.orbstack.dev/licensing).
OrbStack shell and SSH
initialization remains in the documented
[local vendor integration overlays](local-overlay-examples/README.md#optional-vendor-integrations).

## What you'll be prompted for

`chezmoi` will ask for a **Git author name**, **email address**, and whether to
install the **desktop baseline**. Those values only affect this computer and are
not committed back into the repository.

The desktop choice defaults to yes on macOS and Windows, and on Arch Linux and
Ubuntu 26.04+ outside WSL when the init process can see a graphical-session signal
(`XDG_CURRENT_DESKTOP`, `WAYLAND_DISPLAY`, or `DISPLAY`). It defaults to no
elsewhere. A `microsoft` kernel always excludes the desktop baseline, even when
WSLg sets `DISPLAY`. The answer is persisted as `desktopBaseline` in the local
chezmoi data, so later applies do not guess again. To change it deliberately,
edit the local config, set `desktopBaseline = true` or `false` under `[data]`,
and apply:

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
works around an observed Ubuntu issue where Ghostty falls back to the distro's
monospace font despite its explicit `font-family` setting. It applies only to
Ghostty's `monospace` requests (`prgname=ghostty`); other applications keep their
font preferences. On other platforms, or with `desktopBaseline` disabled, the
template renders empty and chezmoi removes a previously deployed file.

## Apply behavior

The main source deploys configuration from `dot_config/` to `$HOME/.config`.
Local overlays under the config root use this same root.

The generated chezmoi config excludes scripts from `chezmoi status`, so routine hook runs do not make a clean setup look locally modified.

The managed `mise` config turns GitHub attestation verification off, because fresh machines behind a shared egress IP can otherwise hit GitHub API rate limits while fetching `uv`, `golangci-lint`, or Python. To enable attestation verification, set the `MISE_GITHUB_ATTESTATIONS` and `MISE_AQUA_GITHUB_ATTESTATIONS` environment variables to `true` before you run `chezmoi apply` again.

## Restricted network?

If you are on a corporate or otherwise restricted network, public registries may be slow or blocked. Keep those private endpoints local to your machine rather than baking them into the public baseline. Start from [**Local overlay examples**](local-overlay-examples/README.md) before your first apply:

- Keep internal npm scopes in `~/.npmrc`, not in shell startup files
- Keep internal indexes for project dependencies in each project's `uv` configuration. For bootstrap tool installs, use the platform settings below

Windows hooks do not read `bootstrap.env`; see [Native Windows restricted network](#restricted-network-on-windows). For Unix settings, see [macOS and Linux restricted network](#restricted-network-on-macos-and-linux).

## macOS and Linux

### What you'll have in 5 minutes on macOS and Linux

After a successful first `chezmoi apply`, you should have:

- **Shells**: managed `zsh` and `bash`; `zsh` includes [oh-my-zsh](https://ohmyz.sh/) and the plugins listed in this repo’s manifest.
- **Runtimes**: `go`, `node`, `python`, and [mise](https://mise.jdx.dev/) as the version manager.
- **Tooling**: `git`, `curl`, `uv`, `golangci-lint`, `shellcheck`, `shfmt`, plus the Go and Python CLI tools declared in `bootstrap/manifests/ecosystem/`.
- **Dotfiles**: managed copies of `~/.zshrc`, `~/.bashrc`, `~/.gitconfig`, mise config, and related files — one maintainer's deliberate, opinionated defaults.
- **Optional desktop baseline**: an all-or-nothing platform bundle with Ghostty and Maple Mono NF CN on supported workstations, plus OrbStack on macOS.
- **Python workflow**: `uv` as the only documented package / auth / publish path; no pip-era machine-global config in the baseline.

Exact versions move with `main`; the final check script prints what you actually got on this machine.

### What to expect during apply

Bootstrap is split into ordered hooks under `.chezmoiscripts/`:

0. **`run_before_00-*`** — rejects unsupported `XDG_CONFIG_HOME` before file updates, then prints the startup banner (hide it with `NO_LOGO=1`).
1. **`run_once_before_10-*`** — one-time prerequisites and, if needed, **backup** of any pre-existing managed files before they are overwritten.
2. **`run_onchange_after_20-*`** — shared system packages (`apt` on Debian / Ubuntu, `pacman` on Arch Linux, Homebrew on macOS).
3. **`run_onchange_after_22-*`** — when selected, installs the platform desktop bundle: Ghostty and Maple Mono NF CN everywhere supported, plus OrbStack on macOS.
4. **`run_onchange_after_25-*`** — shell assets (oh-my-zsh and plugins from the manifest).
5. **`run_onchange_after_30-*`** — install mise itself.
6. **`run_onchange_after_40-*`** — install language runtimes via mise.
7. **`run_onchange_after_50-*`** — sync ecosystem tools (`go install`, `uv tool`, etc.).
8. **`run_onchange_after_55-*`** — generate official Bash / Zsh completion assets in standard user data directories.
9. **`run_onchange_after_60-*`** — run the shared environment check and print a short “welcome” summary.

Leave `XDG_CONFIG_HOME` unset or set it to exactly `$HOME/.config`. Apply and
`check.sh` reject other values, including empty and relative values. Managed
shells warn once and use `$HOME/.config`.

### How to tell it worked

The last hook calls `bootstrap/scripts/check.sh`. Run the same check directly at any time:

```bash
bash "$(chezmoi source-path)/bootstrap/scripts/check.sh"
```

The script resolves the repository from its own location. You can run it from
any directory. Apply uses the same check and adds next steps after the summary.
For example, the end of a successful apply can look like this in plain mode:

```text
  [info] Core tools in this environment:
  [ok] git 2.47.1

All checks passed. (8 core tools)
  [next] Reload your shell (open a new terminal) so PATH picks up the baseline tools.
```

If a check fails, the script exits with a nonzero status and prints diagnostics.

### Restricted network on macOS and Linux

- Put persistent Go settings in `$XDG_CONFIG_HOME/oh-my-devenv/env.sh`
- Put bootstrap endpoint overrides such as `GOPROXY`, `UV_INDEX_URL`, or the Homebrew domains in `$XDG_CONFIG_HOME/oh-my-devenv/bootstrap.env`; every Unix bootstrap script reads it before `chezmoi init --apply` installs anything.
- On Ubuntu, the pinned Maple Mono archive uses a resumable download and SHA-256 verification. If GitHub Releases is unavailable, set **`DOTFILES_MAPLE_MONO_URL`** to an alternate URL serving the exact same archive.

### Reload your shell

**Reload your shell** (or `source` your `~/.zshrc` / `~/.bashrc`) so `PATH`, completions, and any optional `$XDG_CONFIG_HOME/oh-my-devenv/env.sh` exports pick up the new tools.

### Troubleshoot on macOS and Linux

1. Run **`bash "$(chezmoi source-path)/bootstrap/scripts/check.sh"`** and capture its diagnostics. This command does not apply or install changes.
2. Re-run with **`chezmoi apply --verbose --debug`** (or `chezmoi init --apply ...` again) and capture the failing step.
3. If the bootstrap warned about overwriting existing files, inspect backups under **`${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi-first-run-backup/<timestamp>/`**, where each file keeps its original absolute path.

## Native Windows

### Prerequisites

The WinGet mise package requires the Microsoft Visual C++ 2015+ Redistributable
that matches its architecture (x64 or ARM64). The redistributable installs at
machine scope. If your device lacks it, an administrator must install it before
you apply; the hooks do not request elevation.

PowerShell must be 7.6 or later. Check the effective execution policy with
`Get-ExecutionPolicy` inside `pwsh`. If policy blocks the hooks, the source,
or an installer, stop and contact the device administrator.

If you already have a chezmoi configuration, run `chezmoi init` before the
next apply to pick up the Windows hook interpreter settings. Windows hooks use
`pwsh -NoProfile`. The environment check starts a separate shell to verify the profile.

On a restricted network, follow the [Windows restricted-network instructions](#restricted-network-on-windows) before you apply.

### What apply installs

Follow the [Windows quick start](../README.md#native-windows-quick-start). A
successful apply configures Git, OpenSSH, and mise under your home directory
and deploys the PowerShell profile body. It imports the user-scope packages in
`bootstrap/manifests/system/winget-packages.json` from the built-in `winget`
source and leaves installed versions in place. Update a package separately,
for example with `winget upgrade --id Git.Git`.
Apply installs mise with WinGet when it is missing. It also installs the
runtimes in the shared mise configuration and the Go and uv tools in
`bootstrap/manifests/ecosystem/`.

### Prompt and completions

The system baseline installs Oh My Posh. A new PowerShell terminal loads its
managed robbyrussell theme from disk. The profile also sets Emacs line editing
and binds Tab to a completion menu, matching the Unix Oh My Zsh baseline. The local
PowerShell overlay runs after initialization and can override the prompt and
these key settings.

Apply installs PowerShell completions for available commands in the shared
completion inventory. It logs and skips a known command when its application
is absent from `PATH`. Each inventory command must have a PowerShell generator
adapter. If no shipped script exists, apply runs the generator and fails if it
fails or returns empty or invalid PowerShell. Open a new interactive PowerShell
7.6 or later (`pwsh`) terminal with profile loading enabled to load the scripts
in `%LOCALAPPDATA%\oh-my-devenv\completions\powershell`.

### Desktop option

The desktop option requires Windows Terminal on `PATH` and the default
LocalAppData location under your home directory. It installs PowerToys and the
Maple Mono NF CN faces for the current user. It also deploys a Windows Terminal
fragment for the PowerShell profile. Sign out and back in if Windows Terminal cannot find the new
font. To disable the desktop option, set `desktopBaseline = false` in your
chezmoi configuration and apply again. This removes the project's Terminal
fragment and keeps the installed packages and fonts.

### Restricted network on Windows

Windows hooks do not read `bootstrap.env`. On a restricted network, configure
each tool's own user settings before you apply. For example, if the public
Python package hosts are blocked, point uv at your organization's package index
in `%APPDATA%\uv\uv.toml`:

```toml
[[index]]
url = "https://<your-package-index>/simple"
default = true
```

uv does not read `pip.ini` or `PIP_INDEX_URL`. If the public package file host
is blocked, the index must serve the package files as well as the package list.
Apply installs uv before the uv tools. If apply stops while it installs the uv
tools, open a new PowerShell session and run
`uvx --isolated --no-cache ruff --version` to check that uv can download and
run a package, then apply again. `--isolated` ignores an installed Ruff.
[uv configuration files](https://docs.astral.sh/uv/concepts/configuration-files/),
[uv indexes](https://docs.astral.sh/uv/concepts/indexes/),
[pip compatibility](https://docs.astral.sh/uv/pip/compatibility/#configuration-files-and-environment-variables)

### Backups and profile

On the first apply, review any backup under
`%LOCALAPPDATA%\oh-my-devenv\chezmoi-first-run-backup`. The path follows the
effective LocalApplicationData known folder. A run directory holds the previous
versions under `drives\<drive letter>\...`. Keep the backups private. If
OpenSSH rejects an existing file or drop-in due to its permissions, review the
file's owner and ACL. The checker leaves ACLs under your control.

Every apply checks for the managed line in `$PROFILE.CurrentUserAllHosts` and
adds it if needed. This uses the Documents location that PowerShell resolves.
Apply takes a separate pre-edit copy when it adds the line to an existing
profile. Start a new PowerShell session to load the profile. Put machine-local
settings in the [PowerShell overlay](local-overlay-examples/profile.local.ps1.example)
at `~/.config/oh-my-devenv/powershell/profile.local.ps1`. If the overlay sets
`GOBIN`, the profile prepends that directory to `PATH` when it is missing.
Apply adds the mise shims directory, `~/.local/bin`, and the Go binary directory
to the user `Path`. Restart an already running app if it still sees the old
`Path`. Apply records missing entries in
`%LOCALAPPDATA%\oh-my-devenv\user-path.json` before it adds them. If the registry
write fails, reapply to add the entries that are still missing.

### Check and uninstall

Apply prints `All checks passed.` after
the configuration, packages, runtimes, tools, user `Path`, PowerShell
completions, and any enabled desktop assets pass inspection. The check lists
core tool versions before the summary. Apply then prints the steps to load the
managed profile and find local settings.

```powershell
$source = chezmoi source-path
& (Join-Path $source 'bootstrap/windows/check.ps1')
& (Join-Path $source 'bootstrap/windows/uninstall.ps1')  # Preview
& (Join-Path $source 'bootstrap/windows/uninstall.ps1') -Apply
```

Close editors and wait for running Git commands to finish before uninstall
because the pre-delete backup holds the content seen when it ran.
Uninstall backs up the files it will remove and the profile it will edit.
Review the verified backup under `%LOCALAPPDATA%\oh-my-devenv\chezmoi-uninstall-backup`.
If backup fails, uninstall stops before it changes the profile or removes
files. The preview lists managed configuration, recorded user `Path` entries,
owned completion scripts and fonts, and recorded font registrations that still
point to those files. Uninstall removes those items and keeps the first-run
backups, installed packages, mise, runtimes, Go tools, and uv tools. It also
keeps unowned completion scripts and pre-existing matching fonts. Close applications
that are using a font if uninstall reports that it cannot delete the file.
After removal, uninstall resets chezmoi's script and entry state so that the
next `chezmoi apply` backs up any files that already exist at managed targets.
If apply used a custom configuration file, pass the same file to uninstall with
`-Config`.

### Native Windows and WSL

Choose the environment that matches your project:

| If your project targets | Use |
| --- | --- |
| Windows executables, Windows SDKs, or desktop integration | The [native Windows quick start](../README.md#native-windows-quick-start) |
| Linux executables, Linux build scripts, or Linux CI | The [macOS and Linux steps](../README.md#macos-and-linux) for Ubuntu / Debian, from inside an existing Ubuntu WSL distribution |
| Both Windows and Linux | Both quick starts, with separate checkouts and home directories |

Apply the baseline
separately in the Windows home and the WSL home if you use both environments.
Keep separate checkouts and dependency trees. Put native builds on the Windows
filesystem. Put Linux builds under your WSL home, for example `~/src`. A Dev
Drive provides no expected speedup for Linux builds under `/mnt/...`.
[WSL filesystems](https://learn.microsoft.com/en-us/windows/wsl/filesystems),
[Dev Drive and WSL](https://learn.microsoft.com/en-us/windows/dev-drive/#does-dev-drive-work-with-wsl-project-files)

For optional developer setup, see [Windows developer setup](05-windows-dev-setup.md).

## What to do next

1. If you need machine-only tweaks, start from the templates under [`docs/local-overlay-examples/`](local-overlay-examples/README.md) — they are **not** deployed by default.
2. Keep [`02-reference.md`](02-reference.md) handy for day-to-day commands and every environment variable / flag, or jump to [`docs/README.md`](README.md) for the full docs map.

## Something broke

Open an issue using the repository's bug-report workflow so the report includes OS, command, and logs.

Do **not** paste secrets, tokens, or internal hostnames into public issues.
