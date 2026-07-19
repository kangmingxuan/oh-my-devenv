# macOS Preflight Checklist

The `smoke-tests-macos` GitHub Actions job runs the smoke suite on `macos-latest`, so the `darwin` template arms are rendered and shell-checked on every change. What CI still does **not** do on macOS is a real install: it never runs `brew bundle`, never installs mise runtimes, and never builds the Go/uv tools. Personal Macs are intentionally not mounted as self-hosted runners.

Because the macOS job is render-only, a review change that touches macOS *install* behaviour is validated by one contributor running the steps below on a real Mac and pasting the signoff template into the review description.

> Scope: run this when a review change touches either `Brewfile`, any `darwin`-branched chezmoi template, `bootstrap/scripts/install-brew-packages.sh`, macOS-specific PATH wiring, or anything else that only runs on macOS. Linux-only changes do not require it.

## When You Need To Run This

Run the full preflight when the MR diff includes any of:

- `bootstrap/manifests/system/Brewfile`
- `bootstrap/manifests/desktop/Brewfile`
- `bootstrap/scripts/install-brew-packages.sh`
- Any `.chezmoiscripts/*.sh.tmpl` block gated on `eq .chezmoi.os "darwin"`
- macOS-specific PATH or `brew shellenv` wiring in `dot_zprofile.tmpl`, `dot_zshrc.tmpl`, `dot_bashrc.tmpl`, or `dot_profile`
- mise Homebrew install path in `.chezmoiscripts/run_onchange_after_30-install-mise.sh.tmpl`
- Anything in `README.md` or `docs/*.md` whose instructions target macOS readers

If none of the above changed, paste the short "macOS: not exercised" line from the signoff template instead of running the full checklist.

## Prerequisites

A reasonably clean Mac is ideal but not required. The checklist tolerates an already-bootstrapped machine — on a second run, `chezmoi apply` will only re-execute scripts whose dependent manifest hashes changed.

```bash
xcode-select --install   # if not already installed
command -v brew          # should print /opt/homebrew/bin/brew (Apple Silicon) or /usr/local/bin/brew (Intel)
command -v chezmoi       # should print a path; if missing: brew install chezmoi
```

## 1. Check Out The Review Branch

Point chezmoi at the review working tree so the preflight measures exactly what is under review, not an older `main`.

```bash
# From anywhere you have cloned the repo. `--source` makes subsequent
# chezmoi commands treat this directory as the source of truth.
git fetch origin
git checkout <review-source-branch>
git rev-parse HEAD   # record this SHA -- goes into the signoff
```

## 2. Run chezmoi init --apply

This is the same command every macOS contributor runs for a fresh bootstrap. The preflight deliberately uses the interactive form so you exercise the prompt path end-to-end.

```bash
chezmoi init --prompt --apply --source="$(pwd)"
```

Answer the three `chezmoi init` prompts (Git author name, email address, and the desktop-baseline choice) with the values you actually use on this machine. Select the desktop baseline so this checklist exercises Ghostty and Maple Mono. The explicit `--prompt` makes this preflight re-exercise all three choices even on an existing setup; normal first-run and update commands keep reusing the persisted answers.

Expected outcome: `.chezmoiscripts/run_onchange_after_60-check.sh` runs last and reports `All checks passed.` If it exits non-zero, capture the failing line, attach it to the review, and stop — the change is not ready to merge.

## 3. Hand-Validate Brewfile State

`60-check.sh` only checks that the binaries the baseline installs are callable. It does not catch Brewfile drift (for example, a cask you removed that is still installed). Verify Brewfile parity explicitly:

```bash
cd "$(chezmoi source-path)"
brew bundle check --file=bootstrap/manifests/system/Brewfile --verbose
brew bundle check --file=bootstrap/manifests/desktop/Brewfile --verbose
```

Expected outcome: both commands report `The Brewfile's dependencies are satisfied.` Any line starting with `->` means the manifest and the machine disagree. That is either a real MR bug or a pre-existing drift you should note in the signoff.

## 4. Hand-Validate The Desktop Baseline

```bash
brew list --cask ghostty font-maple-mono-nf-cn
ghostty_cli="$(command -v ghostty || true)"
: "${ghostty_cli:=/Applications/Ghostty.app/Contents/MacOS/Ghostty}"
test -x "$ghostty_cli"
"$ghostty_cli" +validate-config
```

Expected outcome: both casks are installed and Ghostty accepts the effective
managed configuration, including any machine-local
`~/.config/ghostty/config.local.ghostty` overrides.

## 5. Hand-Validate mise Runtime State

`60-check.sh` checks that each runtime binary is on PATH. It does not verify that the runtime version mise actually installed matches `dot_config/mise/config.toml.tmpl`. On a Mac, mise is installed via Homebrew rather than `https://mise.run`, so this is the single place where the runtime install path diverges from Linux — worth a direct inspection:

```bash
mise current     # pinned runtimes for the current project
mise list        # what is installed, per runtime
mise doctor      # mise's own self-check; warnings are usually cosmetic, errors are not
```

Expected outcome: `mise current` agrees exactly with
[`dot_config/mise/config.toml.tmpl`](../dot_config/mise/config.toml.tmpl). Any
mismatch goes into the signoff.

## 6. Hand-Validate go / uv Tool State

```bash
gopls version
dlv version
ruff --version
basedpyright --version
pre-commit --version
```

Expected outcome: each command prints a version and exits 0. A missing command means `50-sync-ecosystem-tools.sh` did not finish cleanly on this machine — capture the log and stop.

## 7. Run The Local Smoke Suite

Catch macOS-only issues the Linux CI will never see (for example a Darwin-only template arm that shellcheck would not render on Linux):

```bash
bash bootstrap/scripts/run-smoke-tests.sh
```

Expected outcome: `Smoke tests passed.` This is the same script CI runs; if it fails on a Mac but passes on the Linux CI, you have found a macOS-specific regression.

## 8. Paste The Signoff Into The Review

Copy the template below verbatim into the review description (append to the existing validation section) and fill in each field. The wall of `[x]` entries is the point: reviewers can scan it in five seconds to know the change is macOS-safe.

```markdown
## macOS Preflight Signoff

- [ ] MR SHA validated: `<git rev-parse HEAD output>`
- [ ] Hardware / OS: `<arm64 | x86_64>` — macOS `<version>`
- [ ] `chezmoi init --apply` completed; `60-check.sh` reported `All checks passed.`
- [ ] Both `brew bundle check` commands reported `The Brewfile's dependencies are satisfied.`
- [ ] Ghostty and Maple Mono casks are installed; `ghostty +validate-config` succeeds
- [ ] `mise current` agrees with `dot_config/mise/config.toml.tmpl`
- [ ] `gopls`, `dlv`, `ruff`, `basedpyright`, `pre-commit` all print versions
- [ ] `bash bootstrap/scripts/run-smoke-tests.sh` passed
- Deviations / notes: `<free-form, or "none">`
- Preflight run by: `@<your-handle>` on `<YYYY-MM-DD>`
```

If the MR does not touch any macOS-exercised surface, paste this shorter line instead:

```markdown
## macOS Preflight Signoff

- Not exercised: MR diff is macOS-neutral (no Brewfile / darwin template / mac-specific path changes).
```

## When Full macOS Install Validation Is Wired

The `smoke-tests-macos` job already covers rendering and syntax. Promoting CI to also validate a real macOS *install* is an additive change:

1. Add a job (or step) that runs a real `chezmoi init --apply` on a macOS runner, mirroring the `apply-linux` job, and asserts the final environment check passes.
2. Add the macOS Brewfile-parity, desktop-baseline, and mise-runtime checks from this checklist (steps 3 through 5) as scripted assertions.
3. Update `docs/03-maintenance.md` "Review Expectations" to describe the expanded CI surface, and update this document's introduction.
4. Keep the preflight checklist itself — it remains the right document for MRs that touch macOS surface in ways a single CI shape cannot cover (new hardware, OS upgrade, Xcode CLT jumps).

## Related Documents

- [`README.md`](../README.md) — user-facing bootstrap instructions.
- [`docs/03-maintenance.md`](03-maintenance.md) — day-to-day maintenance model and CI job list.
