# oh-my-devenv

Cross-platform development environment baseline managed by [chezmoi](https://www.chezmoi.io/).

Supports **macOS**, **Ubuntu / Debian**, and **Windows WSL**. On macOS, OrbStack can be added later as an optional local integration; it is not required by the baseline.

This repository is maintained on a **best-effort** basis by a single maintainer. Treat it as a shared baseline for laptops, VMs, and disposable notebook environments. It is meant to get a clean machine to a working shell, runtime, and CLI toolchain quickly, not to behave like a platform-grade environment product with hard guarantees for every runner or network path.

Machine-specific and team-specific settings still belong in local overlays, not in the shared baseline.

## Quick Start

This is the default first-run path for a clean machine. You should be able to finish it without opening another doc.

### 1. Install `git`, `curl`, and `chezmoi`

Use the block for your platform. Do not continue until the last line prints paths for `git`, `curl`, and `chezmoi` in this same shell. Once it does, `chezmoi` is already on `PATH` in the current shell session, so you can run Step 2 immediately below without opening a new terminal.

**macOS**

```bash
if ! command -v brew >/dev/null 2>&1; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi
brew install chezmoi
command -v git curl chezmoi
```

**Ubuntu / Debian / WSL**

```bash
sudo apt-get update
sudo apt-get install -y git curl
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
command -v git curl chezmoi
```

### 2. Bootstrap this baseline

Use the public GitHub URL below for the shared baseline. If you also maintain an internal mirror, use the corresponding local clone URL there instead.

**SSH**

```bash
chezmoi init --apply git@github.com:kangmingxuan/oh-my-devenv.git
```

**HTTPS**

```bash
chezmoi init --apply https://github.com/kangmingxuan/oh-my-devenv.git
```

### 3. Know what the first apply does

During the first `chezmoi init --apply`, the bootstrap will:

- back up any pre-existing managed files before overwrite under `${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi-first-run-backup/<timestamp>/`
- prompt for the Git author name and email address that should be the default machine-wide identity on this machine
- deploy the managed dotfiles and run the ordered bootstrap hooks for packages, shell assets, runtimes, and ecosystem tools
- finish with a short environment check; on success you should see `All checks passed.` and a list of core tool versions

### Exceptions before you run it

- If this machine already has another dotfiles baseline or a hand-managed shell setup you want to preserve, stop here and read [`docs/04-maintenance.md#disposable-environment-reset`](docs/04-maintenance.md#disposable-environment-reset).
- If you are on a restricted network and need mirrors, private package wiring, or host-specific overrides before the first apply, start from [`docs/local-overlay-examples/README.md`](docs/local-overlay-examples/README.md) and keep those values in local overlays.

### After first install

To pull the latest source changes and reapply them:

```bash
chezmoi update
```

If you are editing the local source checkout directly and only want to re-render the managed files:

```bash
chezmoi apply
```

## More Docs

- [`docs/01-onboarding.md`](docs/01-onboarding.md) for a deeper walkthrough of prompts, hook order, success signals, and troubleshooting around the first apply
- [`docs/local-overlay-examples/README.md`](docs/local-overlay-examples/README.md) for machine-only tweaks that do not belong in the shared baseline
- [`docs/README.md`](docs/README.md) for the full documentation map

If you are contributing to the baseline itself, use [`CONTRIBUTING.md`](CONTRIBUTING.md) for scope rules and secret hygiene.
