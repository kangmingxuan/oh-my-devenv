# macOS Preflight Checklist

The `smoke-tests-macos` GitHub Actions job runs the smoke suite on
`macos-latest` using the system `/bin/bash` (Bash 3.2). It renders and
syntax-checks templates, validates contracts and deployment boundaries, and
exercises selected behavior with stubs and temporary roots. What CI still does **not** do on macOS is a complete install: it never
runs `brew bundle`, installs mise runtimes, or builds the Go/uv tools. Personal
Macs are intentionally not mounted as self-hosted runners.

Under the canonical local validation policy, one contributor runs the steps
below on a real Mac when a change affects a macOS-specific installation,
package, or runtime path, or leaves a concrete Mac installation concern that
lighter checks cannot resolve. The contributor then pastes the signoff template
into the review description.

> Authorization: this checklist applies the review source to the real home
> directory and may change the installed toolchain. Run it only with explicit
> authorization for those live mutations. Source edits, targeted review, smoke
> tests, and other authorized diagnosis should continue while this signoff is
> pending; record the preflight as not run and hold merge readiness rather than
> broadening the authorized scope.

## When You Need To Run This

Use the canonical [`CONTRIBUTING.md` validation
policy](../CONTRIBUTING.md#local-validation) to select checks. Run the full
preflight for changed macOS-specific installation, package, or runtime behavior
such as:

- Homebrew package manifests or package-install behavior.
- The Homebrew mise installation path or macOS-specific runtime activation.
- Executable `darwin` branches, macOS-specific PATH activation, or `brew
  shellenv` behavior.

Shared version pins, runtime configuration, installers, ecosystem sync hooks,
and post-install checks do not automatically require this preflight. Use it when
such a change modifies one of the macOS-specific paths above or leaves a
concrete Mac installation concern that lighter checks cannot resolve. A change
to the `60-check` hook that does not affect installation behavior is not by
itself a trigger.

Pure prose, links, comments, and render-only configuration changes use the
lighter checks in the policy even when they mention or target macOS. If the
full preflight is not required, use the short signoff template.

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

Answer the three `chezmoi init` prompts (Git author name, email address, and the desktop-baseline choice) with the values you actually use on this machine. Select the desktop baseline so this checklist exercises the complete macOS bundle: Ghostty, Maple Mono NF CN, and OrbStack. The explicit `--prompt` makes this preflight re-exercise all three choices even on an existing setup; normal first-run and update commands keep reusing the persisted answers.

Expected outcome: `.chezmoiscripts/run_onchange_after_60-check.sh` runs last and reports `All checks passed.` If it exits non-zero, capture the failing line and hold the signoff and merge. Continue authorized diagnosis, source repair, and safe retesting; do not treat the failure as authorization for additional live mutations.

## 3. Hand-Validate Brewfile Dependencies

`60-check.sh` already runs `brew bundle check --no-upgrade` natively against
each Brewfile the baseline selects and fails when a declared dependency is
missing. This step re-runs the same validation by hand so the signoff records
the native verbose output rather than relying on the hook's pass/fail summary:

```bash
cd "$(chezmoi source-path)"
brew bundle check --no-upgrade --file=bootstrap/manifests/system/Brewfile --verbose
brew bundle check --no-upgrade --file=bootstrap/manifests/desktop/Brewfile --verbose
```

Expected outcome: both commands report `The Brewfile's dependencies are
satisfied.` This proves the declared dependencies are present. It does not prove
that the machine has no extra formulae or casks, and it does not detect or clean
up software removed from a Brewfile. Record command failures in the signoff; do
not add cleanup commands to this checklist.

## 4. Hand-Validate The Desktop Baseline

The desktop Brewfile check in step 3 already proves that the declared desktop
casks are installed. This step validates Ghostty's behavior with the managed
configuration:

```bash
ghostty_cli="$(command -v ghostty || true)"
: "${ghostty_cli:=/Applications/Ghostty.app/Contents/MacOS/ghostty}"
test -x "$ghostty_cli"
"$ghostty_cli" +validate-config
```

Expected outcome: Ghostty accepts the effective managed configuration,
including any machine-local `$XDG_CONFIG_HOME/ghostty/config.local.ghostty`
overrides. This check does not launch OrbStack or assert Docker daemon,
context, socket, or license readiness; first-launch setup remains a user action.

## 5. Hand-Validate mise Runtime State

`60-check.sh` already asks mise natively which configured tools are not
installed (`mise ls --current --missing`) and fails when any are reported. On a
Mac, mise itself is installed via Homebrew rather than `https://mise.run`. The
commands below record the underlying diagnostics for the signoff and validate
the deployed managed baseline separately from mise's effective configuration,
which may also include the supported machine-local overlay and project
configuration:

```bash
bash bootstrap/scripts/xdg-config.sh status  # empty means the managed files match this checkout
mise config ls   # active managed, local-overlay, and project config sources
mise current     # effective tool selection in this directory
mise list        # installed versions, per tool
mise doctor      # mise's own self-check; warnings are usually cosmetic, errors are not
```

Expected outcome: `xdg-config.sh status` prints nothing, confirming that the
managed baseline deployed from this checkout is current. `mise config ls`
identifies the sources that contribute to the effective configuration, and
`mise current` reports the expected effective selection for those sources.
Machine-local or project configuration may add tools or override baseline
versions, so exact equality with
[`xdg_config/mise/config.toml.tmpl`](../xdg_config/mise/config.toml.tmpl) is not
required. Record the active sources, selected versions, and any unexplained
deviation. This is evidence for the effective overlay-enabled setup; it does
not prove that every baseline-only version was installed. When baseline-only
runtime coverage is required, use an explicitly authorized isolated environment
without user overlays. Do not disable or delete overlays on the contributor's
machine for this check.

## 6. Hand-Validate go / uv Tool State

`60-check.sh` already checks that every command declared in
[`bootstrap/manifests/ecosystem/go-tools.txt`](../bootstrap/manifests/ecosystem/go-tools.txt)
and
[`bootstrap/manifests/ecosystem/uv-tools.txt`](../bootstrap/manifests/ecosystem/uv-tools.txt)
is on `PATH`, and it reports uv tool environments that no longer run on the
Python they were built on. It does not execute the tools. Run each declared
tool once from the repository root so a corrupt, wrong-architecture, or crashing
binary cannot pass the preflight:

```bash
/bin/bash -c '
  source bootstrap/scripts/common.sh
  setup_go_env
  export_tool_path "$GOBIN"
  failed=0
  while IFS="|" read -r parser manifest; do
    while IFS= read -r entry; do
      tool="$("$parser" "$entry")"
      if "$tool" --help >/dev/null 2>&1; then
        printf "[ok] %s\n" "$tool"
      else
        printf "[failed] %s\n" "$tool" >&2
        failed=1
      fi
    done < <(manifest_entries "$manifest")
  done <<EOF
go_tool_binary_name|bootstrap/manifests/ecosystem/go-tools.txt
uv_tool_binary_name|bootstrap/manifests/ecosystem/uv-tools.txt
EOF
  exit "$failed"
'
```

Expected outcome: step 2 reported `All checks passed.`, and this probe prints
`[ok]` for every declared tool and exits 0. A missing command means
`50-sync-ecosystem-tools.sh` did not finish cleanly on this machine. A
`[failed]` tool is installed but does not start; run it by hand to see the
error. Capture the log and hold the signoff and merge while authorized
diagnosis, source repair, and safe retesting continue.

## 7. Confirm The Local Smoke Suite

Run the smoke suite to catch macOS-only issues the Linux CI will never see (for
example a Darwin-only template arm that ShellCheck would not render on Linux):

```bash
bash bootstrap/scripts/run-smoke-tests.sh
```

If a newer Bash is first on `PATH`, use the
[system Bash check in `CONTRIBUTING.md`](../CONTRIBUTING.md#templates-and-rendering)
to verify Bash 3.2 compatibility.

Expected outcome: `Smoke tests passed.` You may reuse a passing local Mac result
for the same reviewed source and relevant check environment, or the
`smoke-tests-macos` result at the same SHA when it covers the concern. Record
which result supplied the evidence. Run it again only if the source or relevant
environment changed, a prior check failed, or an unresolved concern requires
more evidence. A Linux-only result cannot substitute for this step. If the
suite fails on a Mac but passes in Linux CI, you have found a macOS-specific
regression.

## 8. Paste The Signoff Into The Review

Copy the template below verbatim into the review description (append to the existing validation section) and fill in each field. The wall of `[x]` entries is the point: reviewers can scan it in five seconds to know the change is macOS-safe.

```markdown
## macOS Preflight Signoff

- [ ] MR SHA validated: `<git rev-parse HEAD output>`
- [ ] Hardware / OS: `<arm64 | x86_64>` — macOS `<version>`
- [ ] `chezmoi init --apply` completed; `60-check.sh` reported `All checks passed.`
- [ ] Both `brew bundle check` commands reported `The Brewfile's dependencies are satisfied.` (declared dependencies only)
- [ ] `ghostty +validate-config` succeeds
- [ ] Managed XDG status is clean; active mise config sources and effective versions recorded
- [ ] The ecosystem tool probe printed `[ok]` for every declared tool
- [ ] macOS smoke passed: `<local Mac | smoke-tests-macos CI run>`
- Deviations / notes: `<free-form, or "none">`
- Preflight run by: `@<your-handle>` on `<YYYY-MM-DD>`
```

If the validation policy does not require the full macOS preflight, paste this
shorter line instead:

```markdown
## macOS Preflight Signoff

- Not required under the local validation policy: `<reason; lighter checks used>`
```

## When Full macOS Install Validation Is Wired

The `smoke-tests-macos` job already covers source-level contracts and safe
fixture behavior. Promoting CI to also validate a real macOS *install* is an
additive change:

1. Add a job (or step) that runs a real `chezmoi init --apply` on a macOS runner, provides install coverage comparable to `apply-linux`, and asserts the final environment check passes.
2. Add the macOS Brewfile dependency-satisfaction, desktop-baseline, and mise-runtime checks from this checklist (steps 3 through 5) as scripted assertions.
3. Update `docs/03-maintenance.md` "Review Expectations" to describe the expanded CI surface, and update this document's introduction.
4. Keep the preflight checklist itself — it remains the right document for MRs that touch macOS surface in ways a single CI shape cannot cover (new hardware, OS upgrade, Xcode CLT jumps).

## Related Documents

- [`README.md`](../README.md) — user-facing bootstrap instructions.
- [`docs/03-maintenance.md`](03-maintenance.md) — day-to-day maintenance model and CI job list.
