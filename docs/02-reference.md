# Reference

A lookup page for the things you reach for after the first install: the bootstrap
hooks, what actually gets installed, the day-to-day commands, and every
environment variable the baseline understands.

For the guided first-run story, read [`01-onboarding.md`](01-onboarding.md). For
copy-paste customization, see [`local-overlay-examples/README.md`](local-overlay-examples/README.md).

## Bootstrap hooks

`chezmoi apply` renders your dotfiles and then runs ordered hooks from
`.chezmoiscripts/`. The `run_onchange_*` hooks only re-run when their dependent
manifest changes (chezmoi tracks a content hash), so routine re-applies are cheap.

| Order | Hook | What it does |
|-------|------|--------------|
| 0 | `run_before_00-banner` | Prints the startup banner. Suppress with `NO_LOGO=1`. |
| 1 | `run_once_before_10-bootstrap` | One-time setup: backs up any pre-existing managed files, then prompts once for your Git author name and email. |
| 2 | `run_onchange_after_20-install-system-packages` | Installs system packages — `apt` on Linux / WSL, Homebrew on macOS. Honors the macOS Brewfile opt-ins below. |
| 3 | `run_onchange_after_25-install-shell-assets` | Installs oh-my-zsh and the plugins from the shell manifest. |
| 4 | `run_onchange_after_30-install-mise` | Installs [mise](https://mise.jdx.dev/) (Homebrew on macOS, installer script on Linux). |
| 5 | `run_onchange_after_40-install-runtimes` | Runs `mise install` to fetch the pinned runtimes. |
| 6 | `run_onchange_after_50-sync-ecosystem-tools` | Installs the Go tools (`go install`) and Python tools (`uv tool`). |
| 7 | `run_onchange_after_60-check` | Final environment check. On success prints **`All checks passed.`**, a core-tool version list, and a short next-steps block. |

The first-run backups land under
`${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi-first-run-backup/<timestamp>/`.

## What gets installed

Each layer is driven by a manifest. The lists below name the tools; the manifest
is the source of truth for exact packages and pinned versions.

| Layer | Installed by | Manifest | Includes |
|-------|--------------|----------|----------|
| System packages | `apt` (Linux / WSL) | [`bootstrap/manifests/system/apt-packages.txt`](../bootstrap/manifests/system/apt-packages.txt) | git, curl, wget, zsh, tmux, jq, ripgrep, fzf, direnv, fd-find, bat, tree, zip, unzip, shellcheck, shfmt, build-essential, pkg-config |
| System packages | Homebrew (macOS) | [`bootstrap/manifests/system/Brewfile`](../bootstrap/manifests/system/Brewfile) | the same CLI set plus yq, gnupg, pinentry-mac, and gh |
| Runtimes | [mise](https://mise.jdx.dev/) | [`dot_config/mise/config.toml.tmpl`](../dot_config/mise/config.toml.tmpl) | go, node, python, golangci-lint, uv, usage (versions pinned here) |
| Go tools | `go install` | [`bootstrap/manifests/ecosystem/go-tools.txt`](../bootstrap/manifests/ecosystem/go-tools.txt) | gopls, dlv |
| Python tools | `uv tool` | [`bootstrap/manifests/ecosystem/uv-tools.txt`](../bootstrap/manifests/ecosystem/uv-tools.txt) | ruff, basedpyright, pre-commit |
| Shell assets | git clone | [`bootstrap/manifests/shell/oh-my-zsh-plugins.txt`](../bootstrap/manifests/shell/oh-my-zsh-plugins.txt) | oh-my-zsh + zsh-autosuggestions, zsh-completions, zsh-syntax-highlighting |

macOS GUI apps are never installed by default. OrbStack lives in
[`bootstrap/manifests/system/Brewfile.optional`](../bootstrap/manifests/system/Brewfile.optional)
and only installs when you opt in (see the Brewfile flags below).

## Day-to-day commands

```bash
# Pull the latest source and reapply it
chezmoi update

# Re-render managed files from your local source checkout (no fetch)
chezmoi apply

# First-time bootstrap on a clean machine
chezmoi init --apply https://github.com/kangmingxuan/oh-my-devenv.git

# Where is the source tree?
chezmoi source-path

# Runtime status (versions and what is installed)
mise current
mise list

# macOS: sync a local Brewfile after the first bootstrap
brew bundle install --file="${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/Brewfile.local"

# Preview an uninstall of only what this baseline applied (dry-run; add --confirm to act)
bash bootstrap/scripts/uninstall.sh
```

## Environment variables and flags

Set these in the shell before `chezmoi apply`, or persist them in
`${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/env.sh` (see
[`env.sh.example`](local-overlay-examples/env.sh.example)) so every new shell and
the bootstrap all agree.

### Output

| Variable | Default | Effect |
|----------|---------|--------|
| `NO_LOGO=1` | off | Hide the startup banner. |
| `NO_EMOJI=1` | off | Disable emoji in bootstrap output. |
| `NO_COLOR=1` | off | Disable colored output. |

### Mirror mode (restricted networks)

Mirror mode only rewrites the endpoints wired through `dotfiles_apply_mirror_env`:
`GOPROXY`, `UV_INDEX_URL`, the Homebrew API/bottle domains, the mise installer URL,
and the oh-my-zsh main-repo URL. It does **not** rewrite apt sources, mise runtime
downloads, or oh-my-zsh plugin repos. See
[`03-maintenance.md`](03-maintenance.md#validating-a-mirror-override) for how to
validate a single override.

| Variable | Default | Effect |
|----------|---------|--------|
| `DOTFILES_MIRROR_MODE` | `external` | `external`, `internal`, or `auto`. Selects which endpoint set to apply. |
| `DOTFILES_INTERNAL_PROBE_URL` | unset | URL probed when mode is `auto` to decide internal vs external. |
| `DOTFILES_GOPROXY` | — | Override the Go module proxy. |
| `DOTFILES_UV_INDEX_URL` | — | Override the uv package index. |
| `DOTFILES_HOMEBREW_API_DOMAIN` | — | Override the Homebrew API domain. |
| `DOTFILES_HOMEBREW_BOTTLE_DOMAIN` | — | Override the Homebrew bottle domain. |
| `DOTFILES_MISE_INSTALL_URL` | — | Override the mise installer URL. |
| `DOTFILES_OH_MY_ZSH_GIT_URL` | — | Override the oh-my-zsh main-repo clone URL. |

### macOS package opt-ins

| Variable | Default | Effect |
|----------|---------|--------|
| `DOTFILES_INSTALL_REPO_OPTIONAL_BREWFILE=1` | off | Also install `Brewfile.optional` (OrbStack) during the first bootstrap. |
| `DOTFILES_EXTRA_BREWFILES` | unset | Colon-separated **absolute** paths to extra Brewfiles applied on first bootstrap. Missing files fail the run. |

### Tool installation

| Variable | Default | Effect |
|----------|---------|--------|
| `DOTFILES_FORCE_REINSTALL=1` | off | Skip the idempotency probe and reinstall the Go / Python tools. |

### mise

| Variable | Default | Effect |
|----------|---------|--------|
| `MISE_GITHUB_ATTESTATIONS` | `false` | GitHub artifact attestation verification. Off by default for reliability on shared-egress networks. |
| `MISE_AQUA_GITHUB_ATTESTATIONS` | `false` | Same, for mise's aqua backend. |
| `MISE_PYTHON_GITHUB_ATTESTATIONS` | inherits `MISE_GITHUB_ATTESTATIONS` | Python-specific override. |
| `MISE_SHIMS_DIR` | `$HOME/.local/share/mise/shims` | Shim directory placed on `PATH`. |

To opt back into attestation verification for a run:

```bash
MISE_GITHUB_ATTESTATIONS=true MISE_AQUA_GITHUB_ATTESTATIONS=true chezmoi apply
```

## Machine-local overlay slots

The baseline reads a small set of user-owned files that it never deploys. The full
table — real location, what reads it, and a copyable `.example` — is in
[`local-overlay-examples/README.md`](local-overlay-examples/README.md). The most
common slots:

- `${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/env.sh` — non-secret exports shared by Bash, Zsh, and bootstrap.
- `${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/secrets.sh` — secrets read by interactive shells only.
- `~/.gitconfig.local` — user-owned Git preferences on top of the managed identity.
- `~/.ssh/config.d/*.conf` — extra SSH hosts.

## Related documents

- [`01-onboarding.md`](01-onboarding.md) — the guided first-run walkthrough.
- [`local-overlay-examples/README.md`](local-overlay-examples/README.md) — customization templates.
- [`03-maintenance.md`](03-maintenance.md) — maintainer workflow, mirror validation, and dependency hygiene.
- [`design/00-cross-platform-bootstrap.en.md`](design/00-cross-platform-bootstrap.en.md) — why the layered model looks the way it does.
