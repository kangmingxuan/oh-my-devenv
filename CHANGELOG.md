# Changelog

All notable user-visible changes to this repository are documented here. The
format follows [Keep a Changelog 1.1](https://keepachangelog.com/en/1.1.0/); the
versioning and release policy lives in
[`docs/design/01-release-and-versioning.en.md`](docs/design/01-release-and-versioning.en.md).

## [Unreleased]

## [0.4.1] - 2026-11-24

### Fixed

- Preserve Unicode status glyphs and diagnostic text on Windows console stderr
  at any console code page. The next apply reruns the enabled Windows hooks 20
  (system packages), 22 (desktop assets), 30 (mise), 40 (runtimes), and 50
  (ecosystem tools) because their helper hash changed. Hook 55 uses the new
  hash to refresh eligible PowerShell completions.
- Accept OneDrive cloud-file placeholders, and other Windows reparse points
  that are not links, as regular files. Previously, hook 15, the environment
  check, and `uninstall.ps1 -Apply` failed with "Unsupported reparse point" when
  the PowerShell profile sat in a OneDrive folder with Files On-Demand. Symbolic
  links and junctions are still followed; a link whose final target is such a
  placeholder now resolves to that file instead of failing. This fix adds no
  change-triggered hook reruns.

## [0.4.0] - 2026-11-24

### Breaking

- Remove the Unix `NO_EMOJI` switch. Bootstrap status messages show glyphs
  and color on eligible terminal streams and plain labels on redirected
  streams. Child commands such as installers control their own output.
- Any non-empty `NO_COLOR` selects plain status labels and an uncolored banner
  on Unix and Windows. On Unix, the previous `NO_COLOR=1` setting disabled
  banner color. A non-empty `CI` also selects plain labels and hides the banner.
- Update log parsers for the new output. The environment check summary adds a
  core tool count, for example `All checks passed. (10 core tools)`. In plain
  mode, Unix uninstall previews print `[would] remove`, `[would] skip`, and
  `[would] reset` instead of `[would-remove]`, `[would-skip]`, and
  `[would-reset]`.

### Added

- Warn when the Windows user `Path` contains direct mise tool installation
  directories. The environment check suggests removing the entries and using
  the managed shims.
- Run the Windows apply round trip on native ARM64 in CI.

### Changed

- Bootstrap output uses the same plain labels and terminal glyphs on Unix and
  Windows. The startup banner uses shared ASCII art on both platforms. On
  Windows it replaces the PowerShell version line and is hidden when stdout is
  redirected or `NO_LOGO=1` is set. On Unix, `TERM=dumb` now allows an
  uncolored banner on a terminal.
- Windows install hooks stream native installer output as it runs and keep
  the native exit code on failure. The runtime hook no longer prints a
  separate `mise list`; the final check reports versions.
- When upgrading from v0.3.0, the next apply reruns the enabled
  change-triggered hooks because their rendered contents changed. The Windows
  completion hook also refreshes eligible generated PowerShell completions.
  The next apply also reruns bootstrap hook 10 once on existing machines
  because its body changed. If managed files already exist, hook 10 creates
  one extra first-run backup directory and prints the backup warning.
- On native Windows, the managed PowerShell profile sets PSReadLine to Emacs
  line editing and binds Tab to a completion menu, matching the Unix Oh My Zsh
  baseline.
  PSReadLine previously used its Windows edit mode. Override either setting in
  `profile.local.ps1`.
- Windows CI installs chezmoi through WinGet and checks the binary
  architecture. The Bash smoke suite checks direct status output in bootstrap
  scripts. The Windows smoke suite enforces the `Write-Host` rule with
  exemptions for the renderer, tests, and the profile probe.

### Fixed

- Sync Go tools with the Go executable selected by mise on Unix and Windows.
  The installer ignores a stale `GOROOT` from the parent shell, and the Windows
  post-install check does the same when it reads Go tool versions.
- The Unix environment check reports failed version probes and prints success
  only after they pass. A failed `mise current` now fails the check.

## [0.3.0] - 2026-11-23

### Breaking

- Manage mise, Ghostty, and Fontconfig through the main `dot_config/` source at
  `~/.config`. Remove the nested source and hook 35. Leave `XDG_CONFIG_HOME`
  unset or set it to exactly `$HOME/.config`. Apply and `check.sh` reject all
  other values, including empty and relative values. Managed shells warn once
  and use `$HOME/.config`. `XDG_DATA_HOME` behavior is unchanged.
- The main source now manages `~/.config` as 0755. The old nested helper created
  that root as 0700 when absent and left existing root permissions alone.
  Config files remain 0644. The next apply can change the root's permissions.
- The next apply reruns bootstrap hook 10 and every onchange hook that renders for
  the installation, because their contents changed. Hook 10 can write a new first-run backup of existing
  managed files.

Before the next apply, migrate manually:

1. Remove the old nested state file at
   `${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/oh-my-devenv-xdg.boltdb`.
   Use the state root that the old installation's `bootstrap.env` selected.
2. If you used a custom config root, move its managed `mise/config.toml`,
   `ghostty/config.ghostty`, and
   `fontconfig/conf.d/99-oh-my-devenv-maple-mono-nf-cn.conf` files to the matching
   paths under `~/.config`. Move your `oh-my-devenv/`, mise, and Ghostty overlays
   there too. Preserve and merge any existing files at the destination. If you
   configured the Git identity-guard hook, rerun only its `git config` commands from
   `docs/local-overlay-examples/README.md`, because the overlay stores the old
   absolute hook path.
3. Move the active `chezmoi/chezmoi.toml` from the custom root to
   `~/.config/chezmoi/chezmoi.toml` if you used the default config selection.
4. Remove the custom `XDG_CONFIG_HOME` export from shell or session setup, and
   run `unset XDG_CONFIG_HOME` in the current shell. Review `chezmoi diff ~/.config`
   before applying. No automatic migration runs.

### Added

- Support native Windows as a fourth platform with PowerShell 7.6 or later. See
  the [Windows quick start](README.md#native-windows-quick-start), the
  [Windows onboarding notes](docs/01-onboarding.md#native-windows), and the
  [design](docs/design/02-native-windows.en.md). WSL keeps the Linux path.
  - Install the quick-start prerequisites first: `pwsh`, Git, OpenSSH, chezmoi,
    and WinGet on `PATH`. If you already use chezmoi, run `chezmoi init` before
    the next apply to pick up the Windows hook interpreter. If device policy
    blocks a hook, the `winget` source, or an installer, contact the device
    administrator.
  - Apply deploys the shared Git and mise configuration and a Windows OpenSSH
    configuration without connection multiplexing. The first apply backs up
    existing files at managed targets.
  - Apply keeps your existing PowerShell profile and adds a line that loads the
    managed profile. The managed profile activates mise and initializes the
    robbyrussell Oh My Posh theme before it loads your optional
    `profile.local.ps1`. In a new interactive `pwsh` terminal, the first prompt
    uses the theme unless your overlay overrides it.
  - Apply imports Git, GitHub CLI, ripgrep, jq, and Oh My Posh from the `winget`
    source at user scope and leaves installed versions in place. Update a package
    separately, for example with `winget upgrade --id Git.Git`. The
    desktop option is on by default and requires Windows Terminal on `PATH`. It
    adds PowerToys, Maple Mono NF CN for the current user, and a Windows Terminal
    profile fragment. Setting `desktopBaseline = false` and applying removes the
    fragment and keeps the installed packages and fonts.
  - Apply installs mise with WinGet when it is missing. The WinGet mise package
    needs the matching Microsoft Visual C++ 2015+ Redistributable at machine
    scope. Apply then installs the shared runtimes and the Go and uv tools. It
    also adds any missing mise shims, `~/.local/bin`, and Go binary directories
    to the user `Path`. When the mise Go targets Windows ARM64, Delve builds with
    its experimental `exp.winarm64` tag.
  - Apply installs PowerShell completions for inventory commands found on
    `PATH`. A new interactive `pwsh` terminal with profile loading enabled
    loads them. Known issue: the current mise completer offers file names after
    `mise ` plus Tab; type part of a subcommand first
    ([jdx/usage#1671](https://github.com/jdx/usage/issues/1671)).
  - Apply ends with `bootstrap/windows/check.ps1` and prints `All checks passed.`
    on success. Run the script on demand to recheck.
    `bootstrap/windows/uninstall.ps1` previews by default. With `-Apply`, it
    backs up files before removal and removes the managed configuration, the
    managed profile line, and the `Path` entries, completions, and fonts that
    this baseline added. It keeps user overlays, the first-run backups, and
    installed packages and tools.
  - Windows hooks do not read `bootstrap.env`. If public Python package files
    are blocked, set the uv index in `%APPDATA%\uv\uv.toml` to a mirror that
    serves both the index and the package files. uv does not read `pip.ini`.
  - When platform checks run, `ci-gate` also requires the Windows smoke and
    apply jobs.
- Fail the environment check when PATH selects an executable for a Go or uv
  manifest entry other than the one owned by its installer.

### Changed

- Speed up CI. Apply jobs reuse the Go build cache, except in the weekly run.
  ShellCheck runs once and now lints the Bash templates for every platform arm.
  Pull requests that change only listed prose paths skip the smoke and apply
  jobs. Every commit on `main` gets a complete run, and a newer run no longer
  cancels a pending one.
- Detect native shell completions per command and shell. Generate only missing
  assets and prune marked files superseded by native assets. The completion
  manifest now lists one command per line. Keep Debian `batcat` wrappers as `bat`.
- Run CI from one workflow, `ci.yml`, with one required check, `ci-gate`. Pull
  requests run each job at most once, a new push cancels the previous run, apply
  jobs run in parallel with the smoke jobs, and a weekly run catches upstream
  drift.
- Every macOS and Linux apply job now runs a clean-machine round trip through
  `bootstrap/scripts/ci-apply.sh`: apply, an unchanged reapply that must not
  rerun the final check hook, `uninstall.sh --confirm` with empty chezmoi state
  buckets afterward, and a restoring apply.

### Fixed

- Make the shell completion `list` command fail on a failed write instead of
  printing a shortened inventory. On Bash 3.2, a write could fail with `EINTR`
  under load. `uninstall.sh` could then leave a completion file behind, the
  installer could remove a current file, and `smoke-tests-macos` failed once for
  this reason.
- Make the shell completion `install` and `check` commands fail when the
  completion inventory fails. They previously ignored the failure, so `check.sh`
  could pass without checking every completion file.
- Rebuild uv tool environments when their Python version differs from the
  global mise-selected Python, and use that interpreter for every uv tool install.
  The standalone environment check now reports this mismatch.
- Derive Go tool binary names correctly for module paths with a major-version
  suffix such as `/v2`.
- Check and summarize the mise toolchain from the global mise configuration, so
  running the environment check from a project directory no longer reports the
  project's missing tools or prints its versions.

## [0.2.0] - 2026-10-26

### Added

- Add `bash bootstrap/scripts/check.sh` for on-demand environment validation
  without applying or installing changes. The final bootstrap hook uses the
  same check.
- Full `chezmoi apply` CI with the desktop baseline on Ubuntu 26.04, Arch
  Linux, and macOS, in addition to the non-desktop Ubuntu apply. Each job also
  runs the standalone environment check, and every job is required to merge.

### Changed

- **Breaking:** `uninstall.sh --confirm` no longer deletes the chezmoi source
  checkout. Remove it manually if you no longer need it.
- The README describes the baseline as declarative instead of reproducible.
  Only the runtime and tool layers pin versions; system packages, mise, and
  oh-my-zsh track upstream.
- Document WSL as a runtime environment rather than a separate platform. Keep
  the `microsoft`-kernel exclusion from the desktop baseline, including when
  WSLg sets `DISPLAY`.
- The desktop hook's warning on an unsupported platform now states that no
  desktop assets were installed and points to `docs/02-reference.md` for the
  supported platforms instead of restating the support rule.
- Install every Go tool each time the ecosystem hook runs instead of skipping
  tools that report the pinned version, so a Go upgrade rebuilds them.
  `DOTFILES_FORCE_REINSTALL` now applies only to uv tools.
- Rerun a bootstrap hook when an installer script it runs changes, not only
  when its manifest changes.
- Rerun every `run_onchange_` bootstrap hook when the shared bootstrap code in
  `bootstrap/scripts/common.sh` or `dot_local/share/oh-my-devenv/xdg.sh`
  changes. The mise hook now also reruns on these changes.
- `uninstall.sh --confirm` now clears the main chezmoi `scriptState` and
  `entryState` buckets after removal, so the next `chezmoi apply` reruns the
  bootstrap hooks and restores removed assets. The dry run lists both resets.
- On macOS, bootstrap hooks that run mise-managed tools now find a
  Homebrew-installed mise even when Homebrew is not on the parent `PATH`.

### Fixed

- `uninstall.sh` removes only generated shell completion files that carry the
  ownership marker. It no longer deletes a user file at a current completion
  path, and it rechecks ownership immediately before deletion.
- `uninstall.sh` now includes dangling symlinks in its pre-delete backup.
- A first-run backup failure now prints the bootstrap diagnostic hints.

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

[Unreleased]: https://github.com/kangmingxuan/oh-my-devenv/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/kangmingxuan/oh-my-devenv/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/kangmingxuan/oh-my-devenv/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/kangmingxuan/oh-my-devenv/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/kangmingxuan/oh-my-devenv/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/kangmingxuan/oh-my-devenv/releases/tag/v0.1.0
