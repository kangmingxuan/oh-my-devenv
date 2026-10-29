# macOS Preflight Checklist

The `smoke-tests-macos` GitHub Actions job runs source-level checks on
`macos-latest` with the system `/bin/bash` (Bash 3.2). The `apply-macos` job
runs a full apply with `desktopBaseline=true` on `macos-latest`. It installs and
checks the system and desktop Brewfiles, mise runtimes, Go/uv tools, Ghostty,
Maple Mono NF CN, and the OrbStack cask. It does not launch OrbStack. It also
runs `bootstrap/scripts/check.sh` directly after the apply.

Use this manual checklist only for a concrete concern that the hosted runner
cannot cover. Examples include specific hardware, a different macOS or Xcode CLT
version, and existing-machine state or overlays. Require the relevant CI jobs to
pass at the reviewed SHA before manual preflight. Paste the signoff into the
review description.

> Authorization: this checklist applies the review source to the real home
> directory and may change the installed toolchain. Run it only with explicit
> authorization for those live mutations. Source edits, targeted review, smoke
> tests, and other authorized diagnosis should continue while this signoff is
> pending; record the preflight as not run and hold merge readiness rather than
> broadening the authorized scope.

## When You Need To Run This

Use the canonical [`CONTRIBUTING.md` validation
policy](../CONTRIBUTING.md#local-validation) to select checks. Identify the
concern that `apply-macos` cannot cover before running the full checklist.

Routine Homebrew manifest, installer, runtime, activation, and post-install
check changes do not require manual preflight when `apply-macos` covers them.
The same rule applies to shared version pins and ecosystem sync hooks.

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

This is the same command every macOS contributor runs for a fresh bootstrap. The
preflight deliberately uses the interactive form so you exercise the prompt
path end-to-end.

```bash
chezmoi init --prompt --apply --source="$(pwd)"
```

Answer the three `chezmoi init` prompts (Git author name, email address, and the
desktop-baseline choice) with the values you actually use on this machine.
Select the desktop baseline so this checklist exercises the complete macOS
bundle: Ghostty, Maple Mono NF CN, and OrbStack. The explicit `--prompt` makes
this preflight re-exercise all three choices even on an existing setup.

Run the shared check directly after initialization. Do not rely on hook 60
rerunning when its hashed inputs are unchanged.

```bash
bash bootstrap/scripts/check.sh
```

Expected outcome: `bootstrap/scripts/check.sh` reports `All checks passed.` The
script checks both selected Brewfiles with verbose `brew bundle check` output.
It also runs `ghostty +validate-config`. If initialization or the check fails,
capture the failure and hold the signoff and merge. Continue authorized
diagnosis, source repair, and safe retesting. Do not treat the failure as
authorization for additional live mutations. The check does not launch OrbStack.

## 3. Hand-Validate mise Runtime State

`bootstrap/scripts/check.sh` already asks mise natively which configured tools
are not installed (`mise ls --current --missing`) and fails when any are
reported. On a Mac, mise itself is installed via Homebrew rather than
`https://mise.run`. The commands below record the underlying diagnostics for the
signoff and validate
the deployed managed baseline separately from mise's effective configuration,
which may also include the supported machine-local overlay and project
configuration:

```bash
chezmoi status ~/.config  # empty means the managed files match this checkout
mise config ls   # active managed, local-overlay, and project config sources
mise current     # effective tool selection in this directory
mise list        # installed versions, per tool
mise doctor      # mise's own self-check; warnings are usually cosmetic, errors are not
```

Expected outcome: `chezmoi status ~/.config` prints nothing, confirming that the
managed baseline deployed from this checkout is current. `mise config ls`
identifies the sources that contribute to the effective configuration, and
`mise current` reports the expected effective selection for those sources.
Machine-local or project configuration may add tools or override baseline
versions, so exact equality with
[`dot_config/mise/config.toml.tmpl`](../dot_config/mise/config.toml.tmpl) is not
required. Record the active sources, selected versions, and any unexplained
deviation. This is evidence for the effective overlay-enabled setup; it does
not prove that every baseline-only version was installed. When baseline-only
runtime coverage is required, use an explicitly authorized isolated environment
without user overlays. Do not disable or delete overlays on the contributor's
machine for this check.

## 4. Hand-Validate go / uv Tool State

`bootstrap/scripts/check.sh` already checks that every command declared in
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

## 5. Confirm The Local Smoke Suite

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

## 6. Paste The Signoff Into The Review

Copy the template below verbatim into the review description (append to the existing validation section) and fill in each field. The wall of `[x]` entries is the point: reviewers can scan it in five seconds to know the change is macOS-safe.

```markdown
## macOS Preflight Signoff

- [ ] MR SHA validated: `<git rev-parse HEAD output>`
- [ ] Hardware / OS: `<arm64 | x86_64>` — macOS `<version>`
- [ ] `chezmoi init --apply` completed; `bootstrap/scripts/check.sh` reported `All checks passed.`
- [ ] Managed XDG status is clean; active mise config sources and effective versions recorded
- [ ] The ecosystem tool probe printed `[ok]` for every declared tool
- [ ] macOS smoke passed: `<local Mac | smoke-tests-macos CI run>`
- [ ] macOS full-apply CI passed at the reviewed SHA: `<run URL>`
- Deviations / notes: `<free-form, or "none">`
- Preflight run by: `@<your-handle>` on `<YYYY-MM-DD>`
```

If the validation policy does not require the full macOS preflight, paste this
shorter line instead:

```markdown
## macOS Preflight Signoff

- Not required under the local validation policy: `<reason; lighter checks used>`
```

## Coverage Boundary

The `apply-macos` job covers a clean hosted macOS installation with the complete
desktop baseline. It validates packages, runtimes, ecosystem tools, Ghostty
configuration, fonts, and the shared environment check. It installs the OrbStack
cask but never launches OrbStack.

The hosted job does not cover every hardware model, macOS or Xcode CLT version,
or existing-machine state. Use this checklist only when one of those boundaries
leaves a concrete concern.

## Related Documents

- [`README.md`](../README.md) — user-facing bootstrap instructions.
- [`docs/03-maintenance.md`](03-maintenance.md) — day-to-day maintenance model and CI job list.
