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

## 2. Design Decision

Use the following layered model:

1. **chezmoi**: only manages configuration files and script orchestration
2. **System package manager**:
   - macOS uses `Homebrew`
   - Ubuntu / Debian / WSL use `apt`
3. **mise**: manages runtime versions and binary-distributed tools such as Go / Node / Python / `golangci-lint` / `usage`
4. **Ecosystem tool installers**: manage language-specific tools
   - Go: `go install` (for tools such as `gopls` and `dlv`)
   - Python: `uv tool`
   - Node: global install only when truly necessary
5. **Shell asset installer**: manages shell frameworks and plugins that are explicit runtime dependencies of the dotfiles but are not a good fit for the system package manager
   - install `oh-my-zsh` and selected plugins

**Constraint: Do not use Homebrew on Linux / WSL.**

## 3. Responsibility Boundaries

### Managed by chezmoi

- Shell configuration
- Git configuration
- Editor configuration
- Template files
- Installation script orchestration

### Managed by system package manager

- Core CLI utilities
- Build tools
- Common Unix utilities

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
│   ├── run_onchange_after_25-install-shell-assets.sh.tmpl
│   ├── run_onchange_after_30-install-mise.sh.tmpl
│   ├── run_onchange_after_40-install-runtimes.sh.tmpl
│   ├── run_onchange_after_50-sync-ecosystem-tools.sh.tmpl
│   └── run_onchange_after_60-check.sh.tmpl
├── bootstrap/
│   ├── manifests/
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
│       ├── install-go-tools.sh
│       ├── install-oh-my-zsh-assets.sh
│       └── install-uv-tools.sh
└── dot_config/
   └── mise/
      └── config.toml.tmpl
```

## 5. Bootstrap Flow

New machine initialization flow:

1. Install minimum prerequisites: `git`, `curl`, `chezmoi`
2. Run `chezmoi init --apply <repo>`
3. Let `chezmoi` trigger follow-up scripts automatically:
   - Install system tools
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
3. `run_onchange_after_25-install-shell-assets.sh.tmpl`
4. `run_onchange_after_30-install-mise.sh.tmpl`
5. `run_onchange_after_40-install-runtimes.sh.tmpl`
6. `run_onchange_after_50-sync-ecosystem-tools.sh.tmpl`
7. `run_onchange_after_60-check.sh.tmpl`

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
- Keep OrbStack as an optional local integration in `Brewfile.optional`; it is not installed by the baseline unless the user sets `DOTFILES_INSTALL_REPO_OPTIONAL_BREWFILE=1`
- Allow first-bootstrap local Brewfile opt-ins through `DOTFILES_EXTRA_BREWFILES`; local changes after bootstrap are synced manually with `brew bundle install --file=...`
- Manage shell framework and plugins outside Homebrew via a dedicated shell asset script that uses `git clone`

### Ubuntu / Debian / WSL

- Use only `apt` for system tools
- Store package list in `apt-packages.txt`
- Do not introduce Homebrew
- Install `zsh` via `apt` when the shell layer depends on it
- Reuse the same shell asset script as macOS to install `oh-my-zsh` and plugins

### WSL

- Treated as a Linux subtype
- Only manage the environment inside WSL
- Do not manage native Windows software

## 8. Platform Detection

Use native `chezmoi` template variables for OS-level branching, and do not maintain an extra `detect-platform` script:

- Distinguish OS: `{{ if eq .chezmoi.os "darwin" }}` or `{{ if eq .chezmoi.os "linux" }}`
- Distinguish Linux distro: `{{ if eq .chezmoi.osRelease.id "ubuntu" "debian" }}`
- Distinguish WSL: detect and set a custom variable in `.chezmoi.toml.tmpl` during initialization, for example by checking whether `/proc/version` contains `microsoft`, then expose it to template context

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
golang.org/x/tools/gopls@latest
github.com/go-delve/delve/cmd/dlv@latest
```

Notes:

- `go-tools.txt` uses native `go install` `module@version` syntax
- Keep `@latest` by default
- Pin only when you need to hold a known-good version because of a regression or compatibility issue

### `uv-tools.txt`

```text
ruff==0.15.5
basedpyright==1.38.2
pre-commit==4.5.1
```

Notes:

- `uv-tools.txt` accepts standard Python requirement specifiers
- Prefer pinned versions for fast-moving CLI tools that directly affect diagnostics and local automation behavior

### `config.toml.tmpl`

```toml
[tools]
go = "1.25"
golangci-lint = "v2.11.2"
node = "24"
python = "3.13"
usage = "2.18.2"
uv = "0.10.9"
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
- Keep baseline CLI tools in `Brewfile`; GUI app casks such as OrbStack stay in `Brewfile.optional`
- After the baseline Brewfile, install repo optional and user-owned Brewfiles only when explicit macOS opt-in environment variables are set

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
8. Implement `dot_config/mise/config.toml.tmpl`
9. Add bootstrap usage instructions to `README.md`

## 15. Final Summary

The final chosen approach is:

- `chezmoi` manages configuration and orchestration
- macOS uses Homebrew for system tools
- OrbStack is optional on macOS; if installed through the opt-in Homebrew path, initialization is handled by the login-shell layer
- Ubuntu / Debian / WSL use `apt` for system tools
- `mise` manages language runtimes
- Language ecosystem tools are installed through native ecosystem methods
- The overall solution must stay lightweight, explicit, idempotent, and maintainable
