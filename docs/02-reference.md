# Reference

A lookup page for the things you reach for after the first install: the bootstrap
hooks, what actually gets installed, the day-to-day commands, and every
environment variable the baseline understands.

For the guided first-run story, read [`01-onboarding.md`](01-onboarding.md). For
copy-paste customization, see [`local-overlay-examples/README.md`](local-overlay-examples/README.md).

## Bootstrap hooks

`chezmoi apply` renders your dotfiles and then runs ordered hooks from
`.chezmoiscripts/`. The `run_onchange_*` hooks only re-run when their hashed
inputs change (chezmoi tracks a content hash), including their manifests,
installers, and shared bootstrap code, so routine re-applies are cheap.

| Order | Hook | What it does |
|-------|------|--------------|
| 0 | `run_before_00-banner` | Rejects unsupported `XDG_CONFIG_HOME` before target updates, then prints the startup banner. Suppress the banner with `NO_LOGO=1`. |
| 1 | `run_once_before_10-bootstrap` | One-time setup: backs up any pre-existing managed files and ensures minimum prerequisites. |
| 2 | `run_onchange_after_20-install-system-packages` | Installs shared system packages — `apt` on Debian / Ubuntu, `pacman` on Arch Linux and Homebrew on macOS. |
| 3 | `run_onchange_after_22-install-desktop-assets` | When selected, installs the platform desktop bundle: Ghostty and Maple Mono NF CN everywhere supported, plus OrbStack on macOS. |
| 4 | `run_onchange_after_25-install-shell-assets` | Installs oh-my-zsh and the plugins from the shell manifest. |
| 5 | `run_onchange_after_30-install-mise` | Installs [mise](https://mise.jdx.dev/) (Homebrew on macOS, installer script on Linux). |
| 6 | `run_onchange_after_40-install-runtimes` | Runs `mise install` to fetch the pinned runtimes. |
| 7 | `run_onchange_after_50-sync-ecosystem-tools` | Installs the Go tools (`go install`) and Python tools (`uv tool`). |
| 8 | `run_onchange_after_55-install-shell-completions` | Generates official CLI completion assets in the standard Bash and Zsh user data directories. |
| 9 | `run_onchange_after_60-check` | Change-triggered wrapper around `bootstrap/scripts/check.sh`. It passes the active chezmoi config to the shared check and prints the apply-time next-steps block. The shared check prints **`All checks passed.`** and a core-tool version list on success. |

The main source manages configuration through `dot_config/` at `$HOME/.config`.
It manages the config directory as 0755 and the three config files as 0644.
The first-run backup copies pre-existing main-source file and symlink targets,
skipping dangling symlinks, to the same
absolute path beneath
`${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi-first-run-backup/<timestamp>/`.
Ghostty and Fontconfig templates render empty when inactive. chezmoi then removes
previously deployed files. Local overlays remain user-owned.

## What gets installed

Each layer is driven by a manifest. The lists below name the tools; the manifest
is the source of truth for exact packages and pinned versions.

| Layer | Installed by | Manifest | Includes |
|-------|--------------|----------|----------|
| System packages | `apt` (Debian / Ubuntu) | [`bootstrap/manifests/system/apt-packages.txt`](../bootstrap/manifests/system/apt-packages.txt) | git, curl, wget, zsh, tmux, jq, ripgrep, fzf, direnv, fd-find, bat, tree, zip, unzip, shellcheck, shfmt, build-essential, pkg-config |
| System packages | Homebrew (macOS) | [`bootstrap/manifests/system/Brewfile`](../bootstrap/manifests/system/Brewfile) | the same CLI set plus yq, gnupg, pinentry-mac, and gh |
| System packages | `pacman` (Arch families) | [`bootstrap/manifests/system/pacman-packages.txt`](../bootstrap/manifests/system/pacman-packages.txt) | Arch names such as base-devel, pkgconf, and fd |
| Desktop assets | Homebrew (macOS) | [`bootstrap/manifests/desktop/Brewfile`](../bootstrap/manifests/desktop/Brewfile) | Ghostty, Maple Mono NF CN, and OrbStack |
| Desktop packages | `pacman` (Arch Linux outside WSL) | [`bootstrap/manifests/desktop/pacman-packages.txt`](../bootstrap/manifests/desktop/pacman-packages.txt) | Ghostty and Fontconfig |
| Desktop terminal | `apt` + managed config (Ubuntu 26.04+) | [`bootstrap/manifests/desktop/apt-packages.txt`](../bootstrap/manifests/desktop/apt-packages.txt) | Ghostty, Fontconfig support, and a Ghostty-specific font-discovery workaround |
| Desktop font | verified archive (Arch Linux / Ubuntu 26.04+) | [`bootstrap/manifests/desktop/maple-mono-nf-cn.env`](../bootstrap/manifests/desktop/maple-mono-nf-cn.env) | the font family and required faces shared with the check and the Ghostty/Fontconfig templates, plus the pinned Linux release installed under the user data directory |
| Runtimes and binary tools | [mise](https://mise.jdx.dev/) | [`dot_config/mise/config.toml.tmpl`](../dot_config/mise/config.toml.tmpl) | go, node, python, golangci-lint, uv, usage (versions pinned here) |
| Go tools | `go install` | [`bootstrap/manifests/ecosystem/go-tools.txt`](../bootstrap/manifests/ecosystem/go-tools.txt) | gopls, dlv |
| Python tools | `uv tool` | [`bootstrap/manifests/ecosystem/uv-tools.txt`](../bootstrap/manifests/ecosystem/uv-tools.txt) | ruff, basedpyright, pre-commit |
| Shell assets | git clone | [`bootstrap/manifests/shell/oh-my-zsh-plugins.txt`](../bootstrap/manifests/shell/oh-my-zsh-plugins.txt) | oh-my-zsh + zsh-autosuggestions, zsh-completions, zsh-syntax-highlighting |
| Shell completions | native assets or CLI generators | [`bootstrap/manifests/shell/completions.txt`](../bootstrap/manifests/shell/completions.txt) | Bash and Zsh assets on Linux, Zsh assets on macOS, for the listed commands |

The desktop layer is controlled by the persisted `desktopBaseline` machine
choice. It is an all-or-nothing, platform-specific bundle supported on macOS
and on Arch Linux and Ubuntu 26.04+ outside WSL. Other environments render no
Ghostty config and install no desktop assets. A `microsoft` kernel always
excludes the desktop baseline, even when WSLg sets `DISPLAY`. The macOS bundle
includes Ghostty, Maple Mono NF CN, and OrbStack. Installing the OrbStack cask
does not complete its first-launch setup or licensing; those remain user
actions. Using OrbStack for freelance, business, or professional work requires
a paid [OrbStack license](https://docs.orbstack.dev/licensing).

Ghostty selects the manifest font through its own `font-family` configuration.
On supported Ubuntu 26.04+ desktops outside WSL only,
`$XDG_CONFIG_HOME/fontconfig/conf.d/99-oh-my-devenv-maple-mono-nf-cn.conf` works
around an observed failure to honor that setting. The rule matches both
`prgname=ghostty` and `monospace`; it leaves other applications and explicitly
preferred font families alone. Elsewhere the template renders empty, so chezmoi
does not manage the file. The final check verifies
Ghostty's configuration and the installed faces declared in
`bootstrap/manifests/desktop/maple-mono-nf-cn.env`, without imposing a system
`monospace` preference. Ubuntu rendering remains the manual acceptance check
for this narrowly scoped workaround.

## Day-to-day commands

```bash
# Pull the latest source and reapply it
chezmoi update

# Re-render managed files from your local source checkout (no fetch)
chezmoi apply

# Check the current environment without applying or installing changes
bash "$(chezmoi source-path)/bootstrap/scripts/check.sh"

# Select an explicit chezmoi config for the environment check
bash "$(chezmoi source-path)/bootstrap/scripts/check.sh" /path/to/chezmoi.toml

# Inspect managed configuration through the main source
chezmoi status ~/.config
chezmoi diff ~/.config

# First-time bootstrap on a clean machine
chezmoi init --apply https://github.com/kangmingxuan/oh-my-devenv.git

# Change this machine's persisted desktop-baseline choice:
# edit [data].desktopBaseline, then apply
chezmoi edit-config
chezmoi apply

# Where is the source tree?
chezmoi source-path

# Runtime status (versions and what is installed)
mise current
mise list

# Preview an uninstall of only what this baseline applied (dry-run; add --confirm to act)
bash bootstrap/scripts/uninstall.sh
```

The environment check resolves the repository from the script location. Run it
from any directory. It reads the platform rules and persisted `desktopBaseline`
choice through chezmoi. Omit the config argument to use chezmoi's normal config
selection. The script exits non-zero and prints diagnostic hints when a check
fails. Hook 60 uses the same script. Only the hook prints the next-steps block.

Confirmed uninstall keeps the source checkout and local overlays. It backs up
removed files, including dangling symlinks, unless `--no-backup` is passed.
It clears the main chezmoi `scriptState` and `entryState` buckets after removal
so a later `chezmoi apply` or `chezmoi init --apply` can rerun the bootstrap hooks.
The dry run reports these state resets without performing them.

## Environment variables and flags

Persistent tool environment belongs in `$XDG_CONFIG_HOME/oh-my-devenv/env.sh`
and is read by Bash and Zsh. Bootstrap-only `DOTFILES_*` settings belong in
`$XDG_CONFIG_HOME/oh-my-devenv/bootstrap.env` and are read only by bootstrap
scripts. See the matching examples under [`local-overlay-examples/`](local-overlay-examples/).
For a one-off setting not persisted in `bootstrap.env`, export it before
`chezmoi apply`.

### Configuration root

| Variable | Default | Effect |
|----------|---------|--------|
| `XDG_CONFIG_HOME` | `$HOME/.config` | Fixed root for managed configuration and the local overlays under it. Leave it unset or set it to exactly `$HOME/.config`. Apply and `check.sh` reject all other values, including empty and relative values. Managed shells warn once and use `$HOME/.config`. Local env files must not change it. |
| `XDG_DATA_HOME` | `$HOME/.local/share` | Absolute root for generated Bash and Zsh completion assets, the default mise data directory, and other user data. Export it before starting the shell or running `chezmoi`; local env files must not change it. Relative values are ignored with a warning. |

### Shell completion contract

Linux provides first-class Bash and Zsh completion. macOS provides
first-class Zsh completion; its system Bash receives only the basic managed
environment. The manifest lists one command per line. The installer detects
native files per command and shell: Homebrew's `share/zsh/site-functions` on
macOS, both `/usr/share/zsh/site-functions` and
`/usr/share/zsh/vendor-completions` on Linux, and
`/usr/share/bash-completion/completions` for Linux Bash. It resolves the Homebrew
prefix through `HOMEBREW_PREFIX` or the shared `brew` lookup. It does not
generate an asset that a native file covers, and leaves native files in place.
Debian `batcat` wrappers expose completion as `bat`; where native `bat` files
exist, as in the Arch package, no `bat` asset is generated.
The 55 hook installs generated assets under:

- `$XDG_DATA_HOME/bash-completion/completions/<command>.bash`
- `$XDG_DATA_HOME/zsh/site-functions/_<command>`

Zsh puts the user site-functions directory before system and Homebrew sources
when oh-my-zsh initializes completion. The `zsh-completions` plugin remains
installed but is appended last, so it acts only as a fallback. Machine-local
completion files use the same standard directories; no project-specific loader
or glob convention is required.

Every generated file carries an ownership comment marker. A leading `#compdef`
line is preserved and the marker follows it; otherwise the marker is the first
line. When a command leaves the manifest or a native completion replaces a
generated asset, the next `install` prunes its marked files after the current
entries install. `check` reports them as `[stale]`, and `list` includes existing owned files at
current and obsolete targets so `uninstall.sh` can remove them. Uninstall
rechecks ownership before deletion. Uninstall and obsolete-file cleanup leave
unmarked files and symlinks in those directories untouched.

### Output

| Variable | Default | Effect |
|----------|---------|--------|
| `NO_LOGO=1` | off | Hide the startup banner. |
| `NO_EMOJI=1` | off | Disable emoji in bootstrap output. |
| `NO_COLOR=1` | off | Disable colored output. |

### Restricted networks

Export each tool's native variable in
`$XDG_CONFIG_HOME/oh-my-devenv/bootstrap.env`; every bootstrap script sources it
through `bootstrap/scripts/common.sh`, and shells never read it. Examples are
`GOPROXY`, `UV_INDEX_URL`, `HOMEBREW_API_DOMAIN`, and `HOMEBREW_BOTTLE_DOMAIN`.
Two downloads have no native variable, so the baseline reads its own:

| Variable | Default | Effect |
|----------|---------|--------|
| `DOTFILES_MISE_INSTALL_URL` | `https://mise.run` | Linux mise installer URL. |
| `DOTFILES_OH_MY_ZSH_GIT_URL` | `https://github.com/ohmyzsh/ohmyzsh.git` | oh-my-zsh clone URL. Plugin repositories always clone from github.com. |

oh-my-zsh always lives in `~/.oh-my-zsh`, with plugins in its `custom/`
directory. The installer, the managed `~/.zshrc`, the environment check, and
`uninstall.sh` ignore inherited `ZSH` and `ZSH_CUSTOM` values.

### Pinned artifact downloads

| Variable | Default | Effect |
|----------|---------|--------|
| `DOTFILES_MAPLE_MONO_URL` | pinned upstream release URL | Alternate URL on supported Linux desktops for the exact Maple Mono archive named in the manifest. The fixed SHA-256 digest still has to match. |

### Tool installation

| Variable | Default | Effect |
|----------|---------|--------|
| `DOTFILES_FORCE_REINSTALL=1` | off | Skip the idempotency probe and rebuild the installed uv tools. Go tools are always reinstalled when their hook runs. |

### mise

| Variable | Default | Effect |
|----------|---------|--------|
| `MISE_DATA_DIR` | `$XDG_DATA_HOME/mise` | mise's data root. Its `shims` subdirectory is the default shim directory. |
| `MISE_SHIMS_DIR` | `$MISE_DATA_DIR/shims` | mise's shim directory. The managed shells and the bootstrap hooks put it on `PATH`. |

The shells and hooks resolve the shim directory with mise's own precedence:
`MISE_SHIMS_DIR`, then `MISE_DATA_DIR`, then `XDG_DATA_HOME`. Export these
variables before starting the shell or running `chezmoi`, or put them in
`bootstrap.env` for the hooks. The shell `env.sh` overlay loads after the
baseline builds `PATH`, so a value set only there does not move the shim
directory on `PATH`.

The managed `$XDG_CONFIG_HOME/mise/config.toml` disables GitHub attestation
verification (`github_attestations` and `aqua.github_attestations`) because
shared egress IPs exhaust GitHub's anonymous API rate limit. mise's own
environment variables override it for a single run:

```bash
MISE_GITHUB_ATTESTATIONS=true MISE_AQUA_GITHUB_ATTESTATIONS=true chezmoi apply
```

## Machine-local overlay slots

The baseline reads a small set of user-owned files that it never deploys. The full
table — real location, what reads it, and a copyable `.example` — is in
[`local-overlay-examples/README.md`](local-overlay-examples/README.md). The most
common slots:

- `$XDG_CONFIG_HOME/oh-my-devenv/env.sh` — persistent non-secret exports and quiet shared initialization read by Bash and Zsh.
- `$XDG_CONFIG_HOME/oh-my-devenv/bootstrap.env` — non-secret settings read only by bootstrap scripts.
- `$XDG_CONFIG_HOME/oh-my-devenv/secrets.sh` — secrets read by interactive shells only.
- `$XDG_CONFIG_HOME/oh-my-devenv/git/config` — user-owned Git preferences on top of the managed identity.
- `$XDG_CONFIG_HOME/oh-my-devenv/git/hooks/*` — optional Git 2.54+ configured hooks that coexist with repository-local `.git/hooks/*`.
- `~/.ssh/config.d/*.conf` — extra SSH hosts.
- `$XDG_CONFIG_HOME/mise/config.local.toml` — machine-only mise tools and settings merged with the managed global baseline; overriding baseline keys requires mise 2026.8.5 or newer.
- `$XDG_CONFIG_HOME/ghostty/config.local.ghostty` — machine-only Ghostty overrides loaded after the managed baseline.

## Related documents

- [`01-onboarding.md`](01-onboarding.md) — the guided first-run walkthrough.
- [`local-overlay-examples/README.md`](local-overlay-examples/README.md) — customization templates.
- [`03-maintenance.md`](03-maintenance.md) — maintainer workflow and dependency hygiene.
- [`design/00-cross-platform-bootstrap.en.md`](design/00-cross-platform-bootstrap.en.md) — why the layered model looks the way it does.

### Arch Linux and Omarchy integration

Distribution routing uses `ID` and tokenized `ID_LIKE` from os-release. Arch
families use pacman, Debian/Ubuntu families use apt, and unsupported Linux
families fail in the before hook before managed files are replaced. Arch
package inventories are `bootstrap/manifests/{system,desktop}/pacman-packages.txt`.
The installer uses existing package databases and never runs `pacman -Sy`;
perform a full system upgrade before bootstrap. Only official repository
packages are used; there is no AUR helper dependency.

The optional desktop baseline supports Arch Linux and Ubuntu 26.04+ outside
WSL, plus macOS. Linux receives Ghostty, the verified Maple Mono user-font
archive, and managed Ghostty settings. The Fontconfig workaround is active only
for Ghostty on Ubuntu; Arch keeps its existing generic font preferences. This
does not configure Hyprland or change the default terminal.

The managed `.bash_profile` delegates to `.profile`, ensuring non-interactive
Bash login shells load `.bash/env.bash` and the shared `env.sh` overlay even
when `.bashrc` exits early. The first-run backup includes `.bash_profile`.
Zsh login and interactive shells load the same overlay through their shared
initializer. Plain non-login `bash -c` / `zsh -c` do not load that overlay.

On Omarchy, keep machine-specific integrations in the local `env.sh` (quiet
shared environment/function initialization) and `bashrc.bash` (interactive
preferences). Do not blindly source a second complete shell baseline: avoid
duplicate mise/fzf activation and review PATH order. No private machine
configuration is shipped in this repository. Local mise tool overrides belong
in its native `config.local.toml` overlay.
