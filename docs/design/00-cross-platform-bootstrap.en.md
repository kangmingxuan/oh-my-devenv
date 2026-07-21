# Technical Design: Cross-Platform Development Environment Bootstrap with chezmoi

## 1. Goals

Provide a repeatable and maintainable development environment bootstrap plan for:

- macOS
- Ubuntu / Debian
- Windows WSL

Requirements:

- Use `chezmoi` as the single source of truth for dotfiles
- Automatically install required tools on a new machine
- Clearly separate responsibilities across system tools, language runtimes, and ecosystem tools
- Offer one explicit, portable desktop-terminal baseline on supported workstations without affecting server, WSL, or CI installs

## 2. Design Decision

Use the following layered model:

1. **chezmoi**: only manages configuration files and script orchestration
2. **System package manager**:
   - macOS uses `Homebrew`
   - Ubuntu / Debian / WSL use `apt`
3. **Desktop asset installer**: when selected, installs Ghostty and Maple Mono NF CN from a separate platform-specific manifest
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
- `build-essential` (Linux)

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
│   └── run_onchange_after_60-check.sh.tmpl
├── bootstrap/
│   ├── manifests/
│   │   ├── desktop/
│   │   │   ├── apt-packages.txt
│   │   │   ├── Brewfile
│   │   │   └── maple-mono-nf-cn.env
│   │   ├── shell/
│   │   │   └── oh-my-zsh-plugins.txt
│   │   ├── system/
│   │   │   ├── apt-packages.txt
│   │   │   └── Brewfile
│   │   └── ecosystem/
│   │       ├── go-tools.txt
│   │       └── uv-tools.txt
│   └── scripts/
│       ├── common.sh
│       ├── go-env.sh
│       ├── install-apt-packages.sh
│       ├── install-brew-packages.sh
│       ├── install-maple-mono-font.sh
│       ├── install-go-tools.sh
│       ├── install-oh-my-zsh-assets.sh
│       ├── install-uv-tools.sh
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
9. `run_onchange_after_60-check.sh.tmpl`

Requirements:

- For `run_onchange_` scripts, use template hash (for example `{{ include "bootstrap/manifests/system/apt-packages.txt" | sha256sum }}`) as a trigger so list changes re-run the script
- Keep bootstrap manifests and scripts in a root-level `bootstrap/` directory, exclude that directory from the target state via `.chezmoiignore`, and call them from `.chezmoiscripts` via absolute paths built from `{{ .chezmoi.sourceDir }}`
- All scripts must be idempotent
- Use `bash` with `set -euo pipefail`
- Avoid unnecessary interactive prompts (such as apt confirmation); the Linux / WSL apt path should preflight `sudo -v` once and run installs in noninteractive mode
- Print clear error messages on failure

## 7. Platform Strategy

### macOS

- Use Homebrew for system tools
- Manage package list with `Brewfile`
- Install via `brew bundle`
- When `desktopBaseline` is selected, install Ghostty and Maple Mono NF CN from the separate desktop `Brewfile`
- Keep OrbStack as an optional local integration in `Brewfile.optional`; it is not installed by the baseline unless the user sets `DOTFILES_INSTALL_REPO_OPTIONAL_BREWFILE=1`
- Allow first-bootstrap local Brewfile opt-ins through `DOTFILES_EXTRA_BREWFILES`; local changes after bootstrap are synced manually with `brew bundle install --file=...`
- Manage shell framework and plugins outside Homebrew via a dedicated shell asset script that uses `git clone`

### Ubuntu / Debian / WSL

- Use only `apt` for system tools
- Store package list in `apt-packages.txt`
- Do not introduce Homebrew
- Install `zsh` via `apt` when the shell layer depends on it
- Reuse the same shell asset script as macOS to install `oh-my-zsh` and plugins
- Only non-WSL Ubuntu 26.04+ participates in the selected desktop baseline: install Ghostty through apt and the pinned, verified Maple Mono archive in the user font directory
- On that Linux desktop baseline, manage a strong generic `monospace` Fontconfig preference for Maple Mono NF CN; render the fragment as a valid no-op when the choice is disabled so previously enabled machines converge cleanly

### WSL

- Treated as a Linux subtype
- Only manage the environment inside WSL
- Never install the desktop baseline
- Do not manage native Windows software

## 8. Platform Detection

Use native `chezmoi` template variables for OS-level branching, and do not maintain an extra `detect-platform` script:

- Distinguish OS: `{{ if eq .chezmoi.os "darwin" }}` or `{{ if eq .chezmoi.os "linux" }}`
- Distinguish Linux distribution and release through `.chezmoi.osRelease.id` and `.chezmoi.osRelease.versionID`
- Distinguish WSL by checking `.chezmoi.kernel.osrelease` for `microsoft`; no persisted custom platform flag is needed
- Treat macOS, or non-WSL Ubuntu with `versionID >= 26.04`, as an installation-supported desktop platform
- Use `XDG_CURRENT_DESKTOP`, `WAYLAND_DISPLAY`, or `DISPLAY` only to choose the initial Ubuntu prompt default. Persist the user's `desktopBaseline` answer and never infer it again during routine applies

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

### `go-tools.txt`

```text
golang.org/x/tools/gopls@v0.21.1
github.com/go-delve/delve/cmd/dlv@v1.27.0
```

Notes:

- `go-tools.txt` uses native `go install` `module@version` syntax
- Pin exact versions so clean installs and existing machines converge
- Bump versions intentionally so the manifest hash triggers the ecosystem-tool hook
- Keep each tool compatible with the pinned Go runtime; gopls v0.22 and newer require Go 1.26

### `uv-tools.txt`

```text
ruff==0.15.21
basedpyright==1.39.9
pre-commit==4.6.0
```

Notes:

- `uv-tools.txt` accepts standard Python requirement specifiers
- Prefer pinned versions for fast-moving CLI tools that directly affect diagnostics and local automation behavior

### `config.toml.tmpl`

```toml
[tools]
go = "1.25.12"
golangci-lint = "v2.12.2"
node = "24.18.0"
python = "3.13.14"
uv = "0.11.28"
```

## 10. Helper Script Responsibilities

### `install-apt-packages`

- Run only on Ubuntu / Debian / WSL
- Read `apt-packages.txt` from a source-only manifest path under `bootstrap/manifests/`
- Use a shared helper to preflight `sudo -v` and fail with an explicit error when credentials cannot be acquired
- Run `apt-get update` and batch installs in noninteractive mode

### `install-brew-packages`

- Run only on macOS
- Validate `brew` exists
- Run `brew bundle` from a source-only `Brewfile` under `bootstrap/manifests/`
- Keep baseline CLI tools in the system `Brewfile`; keep the selected Ghostty/font pair in the desktop `Brewfile`; unrelated GUI app casks such as OrbStack stay in `Brewfile.optional`
- After the baseline Brewfile, install repo optional and user-owned Brewfiles only when explicit macOS opt-in environment variables are set

### `install-maple-mono-font`

- Run only from the supported Ubuntu desktop path
- Read a pinned release URL and SHA-256 digest from `bootstrap/manifests/desktop/maple-mono-nf-cn.env`
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

### `install-go-tools`

- Validate `go` is available
- Read `go-tools.txt` from a source-only manifest path under `bootstrap/manifests/`
- Source `bootstrap/scripts/go-env.sh` to keep Go tools on a stable install path
- Default `GOBIN` to `$HOME/go/bin` when no override is provided
- Run `go install`
- Fail fast if `golangci-lint` appears in the manifest and require managing it via `mise`

### `install-uv-tools`

- Read `uv-tools.txt` from a source-only manifest path under `bootstrap/manifests/`
- Install tools from the manifest using the declared requirement specifiers
- Reinstall tools so version changes in the manifest take effect on the next bootstrap run
- Repeated execution must be safe

## 11. PATH and Compatibility

Dotfiles must ensure:

- `mise` is correctly activated
- `~/.local/bin` and `~/bin` are in `PATH`

For Debian/Ubuntu naming differences, keep compatibility handling minimal:

- Keep shell startup support packages such as `bash-completion` in the system package layer
- Enable `mise` Bash completion only when the loaded `bash-completion` helper is new enough; generate Zsh completion into the user completion directory during bootstrap on Linux
- Generate `uv` Bash completion with `uv generate-shell-completion bash` and register it directly; generate Zsh completion into the user completion directory after `mise install`
- Prefer `fzf --bash` / `fzf --zsh` when available, and fall back to distro-provided completion and key-binding scripts for older fzf packages
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

## 14. AI Implementation Task List

Implement in this order:

1. Create directory structure
2. Implement `install-apt-packages`
3. Implement `install-brew-packages`
4. Implement `install-go-tools`
5. Implement `install-uv-tools`
6. Implement `.chezmoiscripts/*`
7. Implement `bootstrap/manifests/system/*.txt` and `bootstrap/manifests/ecosystem/*.txt`
8. Implement the independent `xdg_config/` source and `xdg_config/mise/config.toml.tmpl`
9. Add bootstrap usage instructions to `README.md`

## 15. Final Summary

The final chosen approach is:

- `chezmoi` manages configuration and orchestration
- A nested chezmoi source manages configuration files directly under the absolute `XDG_CONFIG_HOME`, which defaults to `$HOME/.config`
- macOS uses Homebrew for system tools
- OrbStack is optional on macOS; if installed through the opt-in Homebrew path, initialization is handled by the login-shell layer
- Ubuntu / Debian / WSL use `apt` for system tools
- `mise` manages language runtimes
- Language ecosystem tools are installed through native ecosystem methods
- The overall solution must stay lightweight, explicit, idempotent, and maintainable
