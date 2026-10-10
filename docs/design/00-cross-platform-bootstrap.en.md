# Technical Design: Cross-Platform Development Environment Bootstrap with chezmoi

## 1. Goals

Provide a repeatable and maintainable development environment bootstrap plan for:

- macOS
- Ubuntu / Debian
- Arch Linux family
- Windows WSL

Requirements:

- Use `chezmoi` as the single source of truth for dotfiles
- Automatically install required tools on a new machine
- Clearly separate responsibilities across system tools, language runtimes, and ecosystem tools
- Offer one explicit, all-or-nothing platform desktop baseline on supported workstations without affecting server, WSL, or CI installs

## 2. Design Decision

Use the following layered model:

1. **chezmoi**: only manages configuration files and script orchestration
2. **System package manager**:
   - macOS uses `Homebrew`
   - Ubuntu / Debian / WSL use `apt`
   - Arch Linux family uses `pacman`
3. **Desktop asset installer**: when selected, installs the complete platform bundle from a separate manifest: Ghostty and Maple Mono NF CN everywhere supported, plus OrbStack on macOS
4. **mise**: manages runtime versions and binary-distributed tools such as Go / Node / Python / `golangci-lint` / `uv`
5. **Ecosystem tool installers**: manage language-specific tools
   - Go: `go install` (for tools such as `gopls` and `dlv`)
   - Python: `uv tool`
   - Node: global install only when truly necessary
6. **Shell asset installer**: manages shell frameworks and plugins that are explicit runtime dependencies of the dotfiles but are not a good fit for the system package manager
   - install `oh-my-zsh` and selected plugins

**Constraint: Do not use Homebrew on Linux / WSL.**

## 3. Responsibility Boundaries

### Managed by chezmoi

- Shell configuration
- Git configuration
- Editor configuration
- Ghostty configuration when the machine selects the desktop baseline
- Template files
- Installation script orchestration

### Managed by system package manager

- Core CLI utilities
- Build tools
- Common Unix utilities
- Ghostty on supported desktop platforms
- OrbStack on the selected macOS desktop baseline

Examples:

- `git`
- `curl`
- `wget`
- `bash-completion`
- `tmux`
- `jq`
- `ripgrep`
- `fzf`
- `direnv`
- `tree`
- `zip`
- `unzip`
- `build-essential` (Debian / Ubuntu) or `base-devel` (Arch Linux)

### Managed by mise

- `go`
- `golangci-lint`
- `node`
- `python`
- other runtimes

### Managed by ecosystem installers

- `gopls`
- `dlv`
- `ruff`
- `basedpyright`
- other language ecosystem tools

## 4. Repository Structure

Recommended structure:

```text
.
├── .chezmoi.toml.tmpl
├── .chezmoiscripts/
│   ├── run_once_before_10-bootstrap.sh.tmpl
│   ├── run_onchange_after_20-install-system-packages.sh.tmpl
│   ├── run_onchange_after_22-install-desktop-assets.sh.tmpl
│   ├── run_onchange_after_25-install-shell-assets.sh.tmpl
│   ├── run_onchange_after_30-install-mise.sh.tmpl
│   ├── run_after_35-apply-xdg-config.sh.tmpl
│   ├── run_onchange_after_40-install-runtimes.sh.tmpl
│   ├── run_onchange_after_50-sync-ecosystem-tools.sh.tmpl
│   ├── run_onchange_after_55-install-shell-completions.sh.tmpl
│   └── run_onchange_after_60-check.sh.tmpl
├── bootstrap/
│   ├── manifests/
│   │   ├── desktop/
│   │   │   ├── apt-packages.txt
│   │   │   ├── Brewfile
│   │   │   ├── maple-mono-nf-cn.env
│   │   │   └── pacman-packages.txt
│   │   ├── shell/
│   │   │   ├── completions.txt
│   │   │   └── oh-my-zsh-plugins.txt
│   │   ├── system/
│   │   │   ├── apt-packages.txt
│   │   │   ├── Brewfile
│   │   │   └── pacman-packages.txt
│   │   ├── ecosystem/
│   │   │   ├── go-tools.txt
│   │   │   └── uv-tools.txt
│   │   └── local-overlays.tsv
│   └── scripts/
│       ├── common.sh
│       ├── install-apt-packages.sh
│       ├── install-brew-packages.sh
│       ├── install-maple-mono-font.sh
│       ├── install-go-tools.sh
│       ├── install-oh-my-zsh-assets.sh
│       ├── install-pacman-packages.sh
│       ├── install-shell-completions.sh
│       ├── install-uv-tools.sh
│       ├── local-overlays.sh
│       ├── run-smoke-tests.sh
│       ├── uninstall.sh
│       └── xdg-config.sh
├── dot_local/share/oh-my-devenv/
│   └── xdg.sh
└── xdg_config/
    ├── fontconfig/conf.d/
    │   └── 99-oh-my-devenv-maple-mono-nf-cn.conf.tmpl
    ├── ghostty/
    │   └── config.ghostty.tmpl
    └── mise/
        └── config.toml.tmpl
```

## 5. Bootstrap Flow

New machine initialization flow:

1. Install minimum prerequisites: `git`, `curl`, `chezmoi`
2. Run `chezmoi init --apply <repo>`
3. Let `chezmoi` trigger follow-up scripts automatically:
   - Install system tools
   - Install selected desktop assets on supported workstations
   - Install shell assets
   - Install `mise`
   - Install runtimes
   - Install ecosystem tools
   - Run checks

Requirement: keep the bootstrap layer lightweight and avoid putting heavy installation logic directly in one place.

## 6. Script Order

Recommended execution order:

1. `run_once_before_10-bootstrap.sh.tmpl`
2. `run_onchange_after_20-install-system-packages.sh.tmpl`
3. `run_onchange_after_22-install-desktop-assets.sh.tmpl`
4. `run_onchange_after_25-install-shell-assets.sh.tmpl`
5. `run_onchange_after_30-install-mise.sh.tmpl`
6. `run_after_35-apply-xdg-config.sh.tmpl`
7. `run_onchange_after_40-install-runtimes.sh.tmpl`
8. `run_onchange_after_50-sync-ecosystem-tools.sh.tmpl`
9. `run_onchange_after_55-install-shell-completions.sh.tmpl`
10. `run_onchange_after_60-check.sh.tmpl`

Requirements:

- For `run_onchange_` scripts, use template hash (for example `{{ include "bootstrap/manifests/system/apt-packages.txt" | sha256sum }}`) as a trigger so list changes re-run the script
- Keep bootstrap manifests and scripts in a root-level `bootstrap/` directory, exclude that directory from the target state via `.chezmoiignore`, and call them from `.chezmoiscripts` via absolute paths built from `{{ .chezmoi.sourceDir }}`
- All scripts must be idempotent
- Use `bash` with `set -euo pipefail`
- Avoid unnecessary interactive prompts (such as apt or pacman confirmation); the Linux / WSL apt and pacman paths should preflight `sudo -v` once and run installs in noninteractive mode
- Print clear error messages on failure

## 7. Platform Strategy

### macOS

- Use Homebrew for system tools
- Manage package list with `Brewfile`
- Install via `brew bundle`
- When `desktopBaseline` is selected, install Ghostty, Maple Mono NF CN, and OrbStack together from the separate desktop `Brewfile`
- Install the OrbStack cask without claiming that first-launch setup, Docker runtime state, or licensing is complete
- Manage shell framework and plugins outside Homebrew via a dedicated shell asset script that uses `git clone`

### Ubuntu / Debian / WSL

- Use only `apt` for system tools
- Store package list in `apt-packages.txt`
- Do not introduce Homebrew
- Install `zsh` via `apt` when the shell layer depends on it
- Reuse the same shell asset script as macOS to install `oh-my-zsh` and plugins
- Only non-WSL Ubuntu 26.04+ participates in the selected desktop baseline: install Ghostty through apt and the pinned, verified Maple Mono archive in the user font directory
- Only on the supported Ubuntu desktop baseline, retain the Fontconfig workaround for Ghostty ignoring its explicit font-family setting; match `prgname=ghostty` and `monospace`. Other applications and platforms keep their font preferences. Elsewhere, or when disabled, the template renders empty and chezmoi does not manage the file; font validation checks registered faces rather than the system monospace alias

### Arch Linux Family

- Use only `pacman` for system tools
- Store package list in `pacman-packages.txt`
- Detect derivatives through `.chezmoi.osRelease.idLike`
- Install with `pacman -S --needed` against the existing synchronized databases; never refresh with `-Sy` alone, because a full system upgrade is a separate user action
- Install `zsh` via `pacman` when the shell layer depends on it
- Reuse the same shell asset script as macOS to install `oh-my-zsh` and plugins
- Non-WSL Arch participates in the selected desktop baseline: install Ghostty and Fontconfig through pacman and the pinned, verified Maple Mono archive in the user font directory; the Ubuntu Fontconfig workaround does not apply

### WSL

- Treated as a Linux subtype
- Only manage the environment inside WSL
- Never install the desktop baseline
- Do not manage native Windows software

## 8. Platform Detection

Use native `chezmoi` template variables for OS-level branching, and do not maintain an extra `detect-platform` script:

- Distinguish OS: `{{ if eq .chezmoi.os "darwin" }}` or `{{ if eq .chezmoi.os "linux" }}`
- Distinguish Linux distribution and release through `.chezmoi.osRelease.id` and `.chezmoi.osRelease.versionID`; route derivatives to a package manager through `.chezmoi.osRelease.idLike`
- Distinguish WSL by checking `.chezmoi.kernel.osrelease` for `microsoft`; no persisted custom platform flag is needed
- Treat macOS, the non-WSL Arch Linux family, or non-WSL Ubuntu with `versionID >= 26.04`, as an installation-supported desktop platform
- Use `XDG_CURRENT_DESKTOP`, `WAYLAND_DISPLAY`, or `DISPLAY` only to choose the initial prompt default on a supported Linux desktop. Persist the user's `desktopBaseline` answer and never infer it again during routine applies

## 9. Manifest File Conventions

### `apt-packages.txt`

- One package per line
- Empty lines allowed
- `#` comments allowed

Example:

```text
# Core
git
curl
wget
ca-certificates
bash-completion
build-essential
pkg-config

# CLI
tmux
jq
ripgrep
fzf
direnv
fd-find
bat
```

### `pacman-packages.txt`

- Use the same line format as `apt-packages.txt`
- List Arch package names; the installer rejects entries that are not valid pacman package names

### `go-tools.txt`

The current entries live in [`bootstrap/manifests/ecosystem/go-tools.txt`](../../bootstrap/manifests/ecosystem/go-tools.txt).

Notes:

- `go-tools.txt` uses native `go install` `module@version` syntax
- Pin exact versions so clean installs and existing machines converge
- Bump versions intentionally so the manifest hash triggers the ecosystem-tool hook
- Keep each tool compatible with the pinned Go runtime; gopls v0.22 and newer require Go 1.26

### `uv-tools.txt`

The current entries live in [`bootstrap/manifests/ecosystem/uv-tools.txt`](../../bootstrap/manifests/ecosystem/uv-tools.txt).

Notes:

- `uv-tools.txt` accepts standard Python requirement specifiers
- Prefer pinned versions for fast-moving CLI tools that directly affect diagnostics and local automation behavior

### `config.toml.tmpl`

- [`xdg_config/mise/config.toml.tmpl`](../../xdg_config/mise/config.toml.tmpl) pins each runtime and binary-distributed tool in its `[tools]` table
- The runtime, ecosystem-tool, and completion hooks include its hash, so a change re-runs them

## 10. Helper Script Responsibilities

### `install-apt-packages`

- Run only on Ubuntu / Debian / WSL
- Read `apt-packages.txt` from a source-only manifest path under `bootstrap/manifests/`
- Use a shared helper to preflight `sudo -v` and fail with an explicit error when credentials cannot be acquired
- Run `apt-get update` and batch installs in noninteractive mode

### `install-pacman-packages`

- Run only on the Arch Linux family
- Read `pacman-packages.txt` from a source-only manifest path under `bootstrap/manifests/`
- Validate every package name before calling pacman, and preflight `sudo -v` through the shared helper
- Run one batched `pacman -S --needed --noconfirm` against the existing databases and propagate its failure

### `install-brew-packages`

- Run only on macOS
- Validate `brew` exists
- Run `brew bundle` from a source-only `Brewfile` under `bootstrap/manifests/`
- Keep baseline CLI tools in the system `Brewfile` and the selected Ghostty/font/OrbStack bundle in the desktop `Brewfile`; unrelated GUI apps remain outside this repository's bootstrap contract

### `install-maple-mono-font`

- Run only from the supported Linux desktop path (the Arch Linux family and Ubuntu)
- Load the font family, required PostScript faces, pinned release URL, and SHA-256 digest from `bootstrap/manifests/desktop/maple-mono-nf-cn.env` through the shared loader in `common.sh`; the same manifest feeds the environment check and, through `xdg-config.sh` template data, the Ghostty and Fontconfig templates
- Reuse a compatible existing font installation instead of creating a duplicate
- Resume interrupted downloads, verify the digest and required PostScript names, and only replace a directory marked as baseline-owned
- Install under `${XDG_DATA_HOME:-$HOME/.local/share}/fonts` and refresh Fontconfig

### `install-oh-my-zsh-assets`

- Validate `zsh` is available before installing shell assets
- Ensure `oh-my-zsh` exists at `$HOME/.oh-my-zsh`
- Read plugin entries from `bootstrap/manifests/shell/oh-my-zsh-plugins.txt`
- Manage plugins with `git clone` / `git pull --ff-only`
- Skip updates for directories that contain local modifications to avoid overwriting user changes
- `dot_zshrc.tmpl` uses the same manifest to generate the enabled oh-my-zsh plugin list; keep `zsh-completions` as a special `fpath` case instead of adding it to `plugins=()`

### `install-shell-completions`

- Read `bootstrap/manifests/shell/completions.txt`, whose rows declare a command and the comma-separated platforms (`linux`, `darwin`) that generate its completion; leave a platform out when its package manager already ships the asset
- Apply one shell policy per platform: Linux receives Bash and Zsh assets, macOS receives Zsh assets only
- Keep the command-specific generator adapters in the script, because the CLIs expose completion generation through different subcommands and flags; `bat` copies the native package-owned completion on Arch or wraps the Debian package-owned `batcat` completion instead of running a generator
- Write each asset atomically so a failing generator leaves the previous valid file in place
- Stamp each generated file with a stable ownership marker (after `#compdef` in Zsh files); after every current entry installs, prune marked files in the two completion directories that no current entry targets, and never delete unmarked files or follow symlinks
- Serve `install`, `check`, and `list` from the same inventory; `check` reports obsolete owned files as stale, `list` appends them to the current targets, and `uninstall.sh` enumerates the assets through `list`

### `install-go-tools`

- Validate `go` is available
- Read `go-tools.txt` from a source-only manifest path under `bootstrap/manifests/`
- Call `setup_go_env` from `bootstrap/scripts/common.sh` to keep Go tools on a stable install path
- Default `GOBIN` to `$HOME/go/bin` when no override is provided
- Require every entry to pin an exact `module@vX.Y.Z` version and fail before installing anything otherwise
- Skip tools already installed at the pinned version unless `DOTFILES_FORCE_REINSTALL=1`
- Tool ownership follows the manifest that declares the tool: the mise configuration owns binary-distributed tools such as `golangci-lint`, and `go-tools.txt` owns `go install` tools

### `install-uv-tools`

- Read `uv-tools.txt` from a source-only manifest path under `bootstrap/manifests/`
- Install tools from the manifest using the declared requirement specifiers
- Skip tools already installed at the pinned version unless `DOTFILES_FORCE_REINSTALL=1`
- Rebuild an installed tool whose environment interpreter is missing or reports a different version than the environment records; uninstall it first, because `uv tool install --reinstall` keeps the stale environment
- Run again when the mise configuration changes, because the tools run on the mise-managed Python
- Repeated execution must be safe

### `run_onchange_after_60-check`

- Consume the same declared inventories as the installers instead of a second hard-coded tool list
- Validate apt manifests with `dpkg-query`, pacman manifests with `pacman -Q`, Brewfiles with `brew bundle check`, and the mise configuration with `mise ls --current --missing`
- Check ecosystem manifests by binary name, report uv tool environments that no longer run on the Python they were built on, the completion manifest through the installer's `check` action, and the font manifest's family and faces through Fontconfig on Linux or the user font directory on macOS
- Print the mise-managed toolchain from `mise current` so the summary follows the configuration

## 11. PATH and Compatibility

Dotfiles must ensure:

- `mise` is correctly activated
- `~/.local/bin` and `~/bin` are in `PATH`

For Debian/Ubuntu naming differences, keep compatibility handling minimal:

- Keep shell startup support packages such as `bash-completion` in the system package layer
- Generate official CLI completions once during bootstrap into the standard XDG Bash and Zsh directories; shell startup only discovers them
- Provide first-class Bash completion on Linux / WSL and intentionally limited Bash support on macOS
- Add Homebrew's standard site-functions directory on macOS and keep `zsh-completions` last in `fpath` as a fallback
- Use the current `fzf --bash` / `fzf --zsh` integration directly
- `fd-find` maps to `fd`
- Handle `bat` / `batcat` difference only when needed

Do not introduce a complex compatibility layer.

## 12. Implementation Constraints (for AI coding tools)

Implementation must follow these rules:

1. Do not introduce Homebrew on Linux / WSL
2. Do not replace `chezmoi`
3. Do not introduce extra systems such as Nix, Ansible, or Dev Containers
4. Prefer simple Bash scripts
5. Keep directory structure and responsibility boundaries clear
6. Keep scripts repeatable
7. Keep OS branch logic explicit
8. Prefer maintainability over over-abstraction

## 13. Acceptance Criteria

On a fresh machine, after execution, all of the following should hold:

1. `chezmoi apply` succeeds
2. System tools are installed
3. `mise` is installed and activated
4. Runtimes are installed
5. Ecosystem tools are installed
6. No obvious `command not found` errors on new shell startup
7. Re-running `chezmoi apply` does not break the environment

## 14. Final Summary

The final chosen approach is:

- `chezmoi` manages configuration and orchestration
- A nested chezmoi source manages configuration files directly under the absolute `XDG_CONFIG_HOME`, which defaults to `$HOME/.config`
- macOS uses Homebrew for system tools
- Optional vendor applications keep their shell and SSH initialization in user-owned local overlays
- Ubuntu / Debian / WSL use `apt` for system tools
- The Arch Linux family uses `pacman` for system tools
- `mise` manages language runtimes
- Language ecosystem tools are installed through native ecosystem methods
- The overall solution must stay lightweight, explicit, idempotent, and maintainable
