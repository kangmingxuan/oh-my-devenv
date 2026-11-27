# Onboarding — what happens around your first apply

This page goes deeper on the first install after you finish the [Quick Start](../README.md#quick-start) in the root README. Use it when you want more detail on prompts, hook order, success signals, corporate-network exceptions, or troubleshooting.

---

## Native Windows

Follow the [Windows quick start](../README.md#native-windows-quick-start). A
successful apply configures Git, OpenSSH, and mise under your home directory
and deploys the PowerShell profile body. It imports the user-scope packages in
`bootstrap/manifests/system/winget-packages.json` from the built-in `winget`
source and leaves installed versions in place. Update a package separately,
for example with `winget upgrade --id Git.Git`.
Apply installs mise with WinGet when it is missing. It also installs the
runtimes in the shared mise configuration and the Go and uv tools in
`bootstrap/manifests/ecosystem/`.

The WinGet mise package requires the Microsoft Visual C++ 2015+ Redistributable
that matches its architecture (x64 or ARM64). The redistributable installs at
machine scope. If your device lacks it, an administrator must install it before
you apply; the hooks do not request elevation.

PowerShell must be 7.6 or later. Check the effective execution policy with
`Get-ExecutionPolicy` inside `pwsh`. If policy blocks the hooks, the source,
or an installer, stop and contact the device administrator.

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

If you already have a chezmoi configuration, run `chezmoi init` before the
next apply to pick up the Windows hook interpreter settings. Windows hooks use
`pwsh -NoProfile`. The environment check starts a separate shell to verify the profile.

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

The desktop option requires Windows Terminal on `PATH` and the default
LocalAppData location under your home directory. It installs PowerToys and the
Maple Mono NF CN faces for the current user. It also deploys a Windows Terminal
fragment for the PowerShell profile. Sign out and back in if Windows Terminal cannot find the new
font. To disable the desktop option, set `desktopBaseline = false` in your
chezmoi configuration and apply again. This removes the project's Terminal
fragment and keeps the installed packages and fonts. Apply prints `All checks passed.` after
the configuration, packages, runtimes, tools, user `Path`, PowerShell
completions, and any enabled desktop assets pass inspection. The check lists
core tool versions before the summary. Apply then prints the steps to load the
managed profile and find local settings.

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

### Git SSH on Windows

The baseline leaves Git's SSH client selection to Git and your settings. The
Windows checker reports the SSH executable it finds on `PATH` and checks
that the executable reads the managed SSH config. Inspect Git separately from
the repository and shell where you use it. Choose a remote that uses SSH.

```powershell
git remote get-url origin
git config --show-origin --show-scope --get core.sshCommand
git config --show-origin --show-scope --get ssh.variant
Get-Item Env:GIT_SSH_COMMAND, Env:GIT_SSH, Env:GIT_SSH_VARIANT -ErrorAction SilentlyContinue
Get-Command ssh -All
```

Git tries `GIT_SSH_COMMAND` first, then the effective `core.sshCommand`, then
`GIT_SSH`, then its default `ssh`. `GIT_SSH_VARIANT` overrides `ssh.variant`
when Git selects arguments for the client. From a temporary PowerShell session
in the same repository, set `$env:GIT_TRACE = '1'` and run
`git ls-remote origin`. Read the trace entry for the SSH command.
[Git SSH selection](https://raw.githubusercontent.com/git/git/master/connect.c),
[Git configuration](https://git-scm.com/docs/git-config#Documentation/git-config.txt-coresshCommand),
[Git tracing](https://git-scm.com/docs/git#Documentation/git.txt-GITTRACE)

If you want Git to use Windows OpenSSH, run the following in native
PowerShell. It writes a shell-quoted absolute command with forward slashes
to the user-owned [Git include](local-overlay-examples/README.md#git-configuration-and-hooks).

```powershell
$openSsh = Join-Path $env:SystemRoot 'System32/OpenSSH'
$ssh = Join-Path $openSsh 'ssh.exe'
if (-not (Test-Path -LiteralPath $ssh -PathType Leaf)) {
    throw "Windows OpenSSH client not found at $ssh."
}
$gitInclude = Join-Path $HOME '.config/oh-my-devenv/git/config'
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $gitInclude))
$sshCommand = "'" + $ssh.Replace('\', '/').Replace("'", "'\''") + "'"
git config --file $gitInclude core.sshCommand $sshCommand
if ($LASTEXITCODE -ne 0) {
    throw "Could not set core.sshCommand in $gitInclude."
}
```

Enabling and starting the Windows `ssh-agent` service is an administrator step
outside the baseline. If you use that agent, run `Get-Service ssh-agent` and
`& (Join-Path $env:SystemRoot 'System32/OpenSSH/ssh-add.exe') -l` to check the service and list its
loaded keys. Use that same `ssh-add.exe` with your private key path to load
a key. The Windows and Git for Windows clients can use different agents.
The managed SSH config sets `IdentitiesOnly yes`. For a key with a custom
filename, set `IdentityFile` in the host's local SSH config drop-in.
Rerun the Git trace and confirm that `git ls-remote` succeeds against your
SSH remote.
[Windows OpenSSH key management](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement),
[Git for Windows agent differences](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent?platform=windows),
[OpenSSH identity selection](https://man.openbsd.org/ssh_config#IdentitiesOnly)

### Native build prerequisites

Install native build tools when a project requires them. An administrator
must install Visual Studio Build Tools. The VC++ Redistributable supplies
runtime libraries. Build Tools provides the compiler and SDK components.
[Visual Studio installation permissions](https://learn.microsoft.com/en-us/visualstudio/install/install-visual-studio)

| Build | What to check |
| --- | --- |
| Python native extension | If no Windows wheel matches your Python version, ABI, and architecture, check the package's source-build instructions. A native CPython extension can require MSVC and a Windows SDK. A pure-Python source distribution can build without a C compiler. [Python extension builds](https://docs.python.org/3/extending/windows.html) |
| Node add-on using node-gyp | Use a supported Python version and the Visual Studio Desktop development with C++ workload. Run `node -p process.arch` to check the running Node architecture. A native ARM64 target also needs the ARM64 C++ compiler and libraries and ARM64 ATL. [node-gyp Windows requirements](https://github.com/nodejs/node-gyp#on-windows) |
| Go package using cgo | Run `go env GOOS GOARCH CGO_ENABLED CC`. Use a GCC/MinGW-w64 or Clang toolchain that meets the Go release's compiler requirements for the target. MSVC's `cl.exe` cannot serve as cgo's C compiler. [Go cgo documentation](https://pkg.go.dev/cmd/cgo), [Go compiler requirements](https://go.dev/wiki/MinimumRequirements#cgo) |

For an MSVC build, use the Visual Studio Installer copy of `vswhere.exe` to
look for the target compiler component. Run the line for the target you need.

```powershell
$vswhere = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw "Visual Studio Installer's vswhere.exe was not found."
}
# x64 target
& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
# ARM64 target
& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath
```

A path identifies an instance with that component. If the query succeeds and
prints no path, it found no matching instance. Verify the SDK and any extra
components with a project build in the developer shell for the target.
[vswhere location](https://github.com/microsoft/vswhere/wiki/Installing),
[vswhere compiler query](https://github.com/microsoft/vswhere/wiki/Find-VC),
[Build Tools component IDs](https://learn.microsoft.com/en-us/visualstudio/install/workload-component-id-vs-build-tools)

### Dev Drive caches

If you already have a writable Dev Drive, choose a separate absolute cache
directory per tool on that drive. The baseline leaves drive provisioning to
you. For uv, put the cache on the same filesystem as the Python environments
that use it so uv can link files. Across volumes, uv falls back to copying.
[Dev Drive](https://learn.microsoft.com/en-us/windows/dev-drive/),
[uv cache placement](https://docs.astral.sh/uv/concepts/cache/#cache-directory)

Choose the scope before you set the variables.

- **PowerShell and its children.** Set the variables in
  `~/.config/oh-my-devenv/powershell/profile.local.ps1`, for example
  `$env:UV_CACHE_DIR = 'D:\dev-cache\uv'`. The overlay runs after
  `mise activate`, so a `MISE_CACHE_DIR` assignment there applies to
  later mise invocations in that session. The hooks run with `-NoProfile`.
  They can inherit the launching process's variables.
- **Applications launched independently.** Set Windows user environment
  variables to cover PowerShell startup, hooks launched outside the profile,
  and IDEs. For example, run
  `[Environment]::SetEnvironmentVariable('UV_CACHE_DIR', 'D:\dev-cache\uv', 'User')`.
  Substitute your own path. Sign out and back in if a running launcher
  continues to pass the old environment.
  [Windows environment scopes](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_environment_variables)

Run each readback in the shell or application that will use the cache.

| Cache | Environment variable | Readback |
| --- | --- | --- |
| [mise cache](https://mise.jdx.dev/directories.html) | `MISE_CACHE_DIR` | `mise cache path` |
| [uv package cache](https://docs.astral.sh/uv/concepts/cache/) | `UV_CACHE_DIR` | `uv cache dir` |
| [Go module cache](https://pkg.go.dev/cmd/go#hdr-Environment_variables) | `GOMODCACHE` | `go env GOMODCACHE` |
| [Go build cache](https://pkg.go.dev/cmd/go#hdr-Environment_variables) | `GOCACHE` | `go env GOCACHE` |
| [npm cache](https://docs.npmjs.com/cli/v11/using-npm/config/#cache) | `npm_config_cache` | `npm config get cache` |

Leave `MISE_DATA_DIR`, `MISE_INSTALLS_DIR`, the mise shim directory,
`GOPATH`, `GOBIN`, `UV_TOOL_DIR`, and `UV_TOOL_BIN_DIR` outside this
cache setup. The baseline tracks its managed user `Path` entries for mise
shims, the Go binary directory, and `~/.local/bin`, the default for Windows
uv tool executables. Moving installed tool data or executables can disrupt
those entries or the tools they resolve.
[uv executable directories](https://docs.astral.sh/uv/reference/storage/#executable-directory)

## What you'll have in 5 minutes on macOS and Linux

After a successful first `chezmoi apply`, you should have:

- **Shells**: managed `zsh` and `bash`; `zsh` includes [oh-my-zsh](https://ohmyz.sh/) and the plugins listed in this repo’s manifest.
- **Runtimes**: `go`, `node`, `python`, and [mise](https://mise.jdx.dev/) as the version manager.
- **Tooling**: `git`, `curl`, `uv`, `golangci-lint`, `shellcheck`, `shfmt`, plus the Go and Python CLI tools declared in `bootstrap/manifests/ecosystem/`.
- **Dotfiles**: managed copies of `~/.zshrc`, `~/.bashrc`, `~/.gitconfig`, mise config, and related files — one maintainer's deliberate, opinionated defaults.
- **Optional desktop baseline**: an all-or-nothing platform bundle with Ghostty and Maple Mono NF CN on supported workstations, plus OrbStack on macOS.
- **Python workflow**: `uv` as the only documented package / auth / publish path; no pip-era machine-global config in the baseline.

Exact versions move with `main`; the final check script prints what you actually got on this machine.

---

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

---

## What you'll be prompted for

`chezmoi` will ask for a **Git author name**, **email address**, and whether to
install the **desktop baseline**. Those values only affect this computer and are
not committed back into the repository.

The desktop choice defaults to yes on macOS and on Arch Linux and Ubuntu 26.04+
outside WSL when the init process can see a graphical-session signal
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

---

## What to expect during apply

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

The main source deploys configuration from `dot_config/` to `$HOME/.config`.
Leave `XDG_CONFIG_HOME` unset or set it to exactly `$HOME/.config`. Apply and
`check.sh` reject other values, including empty and relative values. Managed
shells warn once and use `$HOME/.config`. Local overlays under the config root
use this same root.

The generated chezmoi config excludes scripts from `chezmoi status`, so routine hook runs do not make a clean setup look locally modified.

The managed `mise` config turns GitHub attestation verification off, because fresh machines behind a shared egress IP can otherwise hit GitHub API rate limits while fetching `uv`, `golangci-lint`, or Python. If you explicitly want attestation verification on your machine, re-run with `MISE_GITHUB_ATTESTATIONS=true MISE_AQUA_GITHUB_ATTESTATIONS=true`.

---

## How to tell it worked

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

---

## Restricted network?

If you are on a corporate or otherwise restricted network, public registries may be slow or blocked. Keep those private endpoints local to your machine rather than baking them into the public baseline. Start from [**Local overlay examples**](local-overlay-examples/README.md) before your first apply:

- Put persistent Go settings in `$XDG_CONFIG_HOME/oh-my-devenv/env.sh`
- Put bootstrap endpoint overrides such as `GOPROXY`, `UV_INDEX_URL`, or the Homebrew domains in `$XDG_CONFIG_HOME/oh-my-devenv/bootstrap.env`; every Unix bootstrap script reads it before `chezmoi init --apply` installs anything. Windows hooks do not read this file; see [Native Windows](#native-windows)
- Keep internal npm scopes in `~/.npmrc`, not in shell startup files
- Keep Python internal indexes project-local and `uv`-only
- On Ubuntu, the pinned Maple Mono archive uses a resumable download and SHA-256 verification. If GitHub Releases is unavailable, set **`DOTFILES_MAPLE_MONO_URL`** to an alternate URL serving the exact same archive.

---

## What to do next

1. **Reload your shell** (or `source` your `~/.zshrc` / `~/.bashrc`) so `PATH`, completions, and any optional `$XDG_CONFIG_HOME/oh-my-devenv/env.sh` exports pick up the new tools.
2. If you need machine-only tweaks, start from the templates under [`docs/local-overlay-examples/`](local-overlay-examples/README.md) — they are **not** deployed by default.
3. Keep [`02-reference.md`](02-reference.md) handy for day-to-day commands and every environment variable / flag, or jump to [`docs/README.md`](README.md) for the full docs map.

---

## Something broke

1. Run **`bash "$(chezmoi source-path)/bootstrap/scripts/check.sh"`** and capture its diagnostics. This command does not apply or install changes.
2. Re-run with **`chezmoi apply --verbose --debug`** (or `chezmoi init --apply ...` again) and capture the failing step.
3. If the bootstrap warned about overwriting existing files, inspect backups under **`${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi-first-run-backup/<timestamp>/`**, where each file keeps its original absolute path.
4. Open an issue using the repository's bug-report workflow so the report includes OS, command, and logs.

Do **not** paste secrets, tokens, or internal hostnames into public issues.
