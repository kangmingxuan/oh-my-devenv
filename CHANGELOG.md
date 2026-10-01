# Changelog

All notable user-visible changes to this repository are documented here. The format follows [Keep a Changelog 1.1](https://keepachangelog.com/en/1.1.0/); the versioning and release policy lives in [`docs/design/01-release-and-versioning.en.md`](docs/design/01-release-and-versioning.en.md).

## [Unreleased]

### Added

- One-command bootstrap for macOS, Debian/Ubuntu, Arch Linux, and WSL through ordered chezmoi hooks: system packages (Homebrew, apt, or pacman), oh-my-zsh assets, mise runtimes, Go and uv tools, shell completions, and a final environment check.
- A first-run backup of every pre-existing managed file, prompted once for the Git identity and the desktop-baseline choice.
- Opt-in, all-or-nothing desktop baseline for macOS, non-WSL Arch Linux, and Ubuntu 26.04+: Ghostty, Maple Mono NF CN, managed Ghostty defaults, a Ghostty-specific Fontconfig rule on Ubuntu, and OrbStack on macOS.
- `XDG_CONFIG_HOME` as the single root for managed mise, Ghostty, and Fontconfig files, applied through a dedicated chezmoi subsource.
- Declarative manifests for every layer, including `completions.txt` for generated Bash and Zsh completions with ownership markers and pruning, and `local-overlays.tsv` for the user-owned overlay slots that uninstall protects.
- Local overlays for persistent shell environment (`env.sh`), bootstrap-only settings (`bootstrap.env`), interactive secrets, shell, Git, SSH, npm, mise, and Ghostty.
- An environment check that validates the same manifests the installers consume.
- `uninstall.sh`, a dry-run-by-default teardown for disposable environments.
- Smoke, apply, and secret-scan CI on Linux, macOS, and Arch Linux, plus Dependabot for GitHub Actions.
- English and Chinese landing pages, onboarding, reference, maintenance, and design documentation.
