# Changelog

All notable user-visible changes to this repository are documented here. The
format follows [Keep a Changelog 1.1](https://keepachangelog.com/en/1.1.0/); the
versioning and release policy lives in
[`docs/design/01-release-and-versioning.en.md`](docs/design/01-release-and-versioning.en.md).

## [Unreleased]

### Changed

- The desktop hook's warning on an unsupported platform now states that no
  desktop assets were installed and points to `docs/02-reference.md` for the
  supported platforms instead of restating the support rule.

## [0.1.0] - 2026-10-10

### Changed

- **Breaking:** Install oh-my-zsh and its plugins only in `~/.oh-my-zsh`. The
  installer, the managed `~/.zshrc`, the environment check, and `uninstall.sh`
  now ignore inherited `ZSH` and `ZSH_CUSTOM` values. Move an installation from
  a custom location, or let bootstrap install a new copy in `~/.oh-my-zsh`.
- **Breaking:** Shell overlays must call `path_reorder_front` to order `PATH`.
  The `path_prepend` and `path_remove` helpers are removed without aliases;
  update local `env.sh` overlays that call them.
- Move the Go toolchain off the unsupported 1.25 line to Go 1.27.1, with
  gopls 0.23.0, Delve 1.27.2, and golangci-lint 2.14.0. The selected tools
  support Go 1.27; Go 1.26 remains a supported alternative, but the shared
  development baseline follows the current toolchain. Go 1.27 requires macOS
  13 or later. See the [Go support
  policy](https://go.dev/doc/devel/release#policy),
  [gopls release notes](https://go.dev/gopls/release/v0.23.0), and
  [golangci-lint changelog](https://golangci-lint.run/docs/product/changelog/).
- Update Node.js within the existing LTS line to 24.21.0 and Python within the
  existing branch to
  [3.13.16](https://www.python.org/downloads/release/python-31316/),
  including its security fixes. Retain Python 3.13 for broader compatibility:
  the October 5, 2026 package review found Python 3.14 wheels for NumPy, SciPy,
  pandas, and PyTorch, but not for stable
  [TensorFlow 2.21.0](https://pypi.org/project/tensorflow/2.21.0/#files).
  This is a compatibility choice, not a claim about overall usage share;
  Python 3.13 now moves into security-only support and needs continued review.
- Update uv to 0.11.33 and Ruff to 0.15.22 within their existing release lines.
  Defer [uv 0.12](https://github.com/astral-sh/uv/releases/tag/0.12.0) project
  discovery, initialization, and resolver changes, and
  [Ruff 0.16](https://github.com/astral-sh/ruff/releases/tag/0.16.0)
  default-rule
  expansion and Markdown formatting, to separately validated migrations.
  These deferrals do not imply LTS or guaranteed backports: reassess them at
  the next baseline review or sooner for a relevant security fix.
- Update basedpyright to 1.40.2, pre-commit to 4.6.2, and usage to 6.12.0 for
  maintained tooling and fixes. basedpyright now requires Python 3.10 or later;
  usage completion fixes take effect after completion regeneration and a new
  shell.
- Document monthly baseline reviews with ecosystem-specific version selection
  and validation,
  including timely security, support-lifecycle, and blocking fixes.

### Added

- Add the repository skill `refresh-devenv-baseline` for baseline maintenance.
  Keep its files in Git and exclude them from chezmoi deployment.
- One-command bootstrap for macOS, Debian/Ubuntu, Arch Linux, and WSL through
  ordered chezmoi hooks: system packages (Homebrew, apt, or pacman), oh-my-zsh
  assets, mise runtimes, Go and uv tools, shell completions, and a final
  environment check.
- A first-run backup of every pre-existing managed file, prompted once for the
  Git identity and the desktop-baseline choice.
- Opt-in, all-or-nothing desktop baseline for macOS, non-WSL Arch Linux, and
  Ubuntu 26.04+: Ghostty, Maple Mono NF CN, managed Ghostty defaults, a
  Ghostty-specific Fontconfig rule on Ubuntu, and OrbStack on macOS.
- `XDG_CONFIG_HOME` as the single root for managed mise, Ghostty, and Fontconfig
  files, applied through a dedicated chezmoi subsource.
- Declarative manifests for every layer, including `completions.txt` for
  generated Bash and Zsh completions with ownership markers and pruning, and
  `local-overlays.tsv` for the user-owned overlay slots that uninstall protects.
- Local overlays for persistent shell environment (`env.sh`), bootstrap-only
  settings (`bootstrap.env`), interactive secrets, shell, Git, SSH, npm, mise,
  and Ghostty.
- An environment check that validates the same manifests the installers consume.
- `uninstall.sh`, a dry-run-by-default teardown for disposable environments.
- Smoke, apply, and secret-scan CI on Linux, macOS, and Arch Linux, plus
  Dependabot for GitHub Actions.
- English and Chinese landing pages, onboarding, reference, maintenance, and
  design documentation.

### Fixed

- Rebuild uv tools whose environment no longer runs on the Python it was built
  on, such as after a mise Python upgrade. The ecosystem tool hook now runs
  again when the mise configuration changes, and the environment check reports
  stale uv tool environments.

[Unreleased]: https://github.com/kangmingxuan/oh-my-devenv/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/kangmingxuan/oh-my-devenv/releases/tag/v0.1.0
