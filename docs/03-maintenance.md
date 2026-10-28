# Maintenance Guide

This document describes how this repository is maintained day to day. It
complements `CONTRIBUTING.md`, which covers the contributor-facing workflow.

The repository is maintained on a **best-effort** basis by a single maintainer.
The goal is a coherent, opinionated personal environment with cheap validation,
published for anyone who wants the same choices; it is not a platform-grade
environment product.

## Principles

1. **Single opinionated baseline.** This repository ships the maintainer's
   current preferred design. There is no `personal` vs. `work` mode and no
   attempt to satisfy every workflow.
2. **Current design only.** Replace superseded paths and behavior directly. Do
   not retain compatibility aliases, fallback loaders, or legacy branches.
3. **No private data.** No personal emails, usernames, internal IP ranges, or
   credentials. Host-specific corporate or private infrastructure details stay
   in overlays or user-owned config.
4. **Reproducible bootstrap.** Changes to executable bootstrap behavior must
   keep the appropriate checks in the canonical [`CONTRIBUTING.md` validation
   policy](../CONTRIBUTING.md#local-validation) passing and keep a clean-machine
   bootstrap working on macOS, Ubuntu/Debian, and Arch Linux.
5. **Validate behavior, not duplicated facts.** Tests enforce parsing,
   rendering, syntax, permissions, boundaries, and behavior. They do not restate
   literal configuration values that already have a canonical source file.

## Roles

- **Maintainers**: merge merge requests, cut releases, own the CI and governance
  files.
- **Contributors**: open review changes that follow `CONTRIBUTING.md` and the
  repository's current review workflow.

For now this repository does not require a formal maintainer rotation. The
maintainer is whoever currently owns the baseline. If ownership later splits
across areas (bootstrap vs docs vs CI, or the owner becomes a group), update the
repository's ownership metadata and this note together.

## Documentation Boundaries

Keep the doc set opinionated and non-overlapping:

- `README.md`: landing page, quick start, concise repository tour, and the first
  links a new reader sees on the repository host.
- `docs/README.md`: the documentation index and "which page should I read?"
  router.
- `docs/01-onboarding.md`: the ordered first-run journey from a clean machine to
  a working baseline.
- `docs/02-reference.md`: lookup tables for bootstrap hooks, installed tools,
  day-to-day commands, and environment variables / flags.
- `docs/local-overlay-examples/`: copyable machine-local templates that
  deliberately do not deploy through `chezmoi`.
- `docs/04-macos-preflight.md`: manual review steps for macOS concerns that
  hosted CI cannot cover.
- `docs/design/`: rationale and technical design, not operational steps.
- `docs/03-maintenance.md`: maintainer workflow, validation expectations,
  dependency hygiene, and release discipline.

When adding new documentation, pick one canonical home and make other pages link
to it instead of copying long instructions in multiple places.

## Branching Model

- `main` is the only long-lived branch. It must remain in a deployable state.
- All work happens on short-lived feature branches branched from `main`.
- Changes into `main` go through the repository's normal review workflow with a
  green CI pipeline.
- Force pushes to `main` are not allowed. Rewrites live only on feature branches
  before review.

## Review Expectations

A reviewable change is ready to merge when all of the following hold:

- The CI pipeline is green. Every job in the [CI](#ci) section is a required
  status check on `main`.

  The `apply-macos` job covers routine macOS installation validation. Use the
  manual [`docs/04-macos-preflight.md`](04-macos-preflight.md) checklist only
  for concerns that the hosted runner cannot cover, as defined by the
  [validation policy](../CONTRIBUTING.md#local-validation).
- At least one maintainer has approved the change.
- The review description follows the repository's normal template and the change
  is in scope for the baseline.
- No unresolved review threads remain.

## Release / Rollout

Users pull the latest `main` through `chezmoi update`. Because changes reach
machines immediately, prefer:

- Small, reviewable merge requests.
- Direct replacement of superseded behavior, with no compatibility path left
  behind.
- A note in the merge request description when a change is expected to be
  user-visible.

Milestones cut annotated git tags (`v0.<M>.0`). After a milestone's final MR
merges, the maintainer pushes the tag manually to keep tagging a deliberate act.
Tag messages follow the `v<version> — <milestone-name>` convention. See
[`design/01-release-and-versioning.en.md`](design/01-release-and-versioning.en.md)
for the versioning policy.

## Dependencies

Third-party dependencies pulled in by this repository fall into these
categories:

- **System packages** (`apt`, `pacman`, Homebrew): bump the manifest files
  (`bootstrap/manifests/system/apt-packages.txt`,
  `bootstrap/manifests/system/pacman-packages.txt`,
  `bootstrap/manifests/system/Brewfile`). Prefer stable distro names over
  version pins.
- **Desktop assets**: keep the explicit, all-or-nothing platform bundle in
  `bootstrap/manifests/desktop/`. The macOS Brewfile owns Ghostty, its font
  cask, and OrbStack; the Ubuntu 26.04+ apt manifest and Arch pacman manifest
  own Ghostty and Fontconfig; `maple-mono-nf-cn.env` declares the font family
  and required faces shared by the Linux installer, the environment check, and
  the managed Ghostty and Fontconfig templates, and pins the Linux font archive
  URL and SHA-256 digest. Other GUI apps and personal CLIs stay outside this
  repository's bootstrap contract.
- **Shell assets** (oh-my-zsh and plugins): managed by explicit Git
  clone/update. The upstream repository is captured in
  `bootstrap/manifests/shell/oh-my-zsh-plugins.txt`. That manifest uses a strict
  two-field, order-sensitive contract shared by four readers (`dot_zshrc.tmpl`,
  `install-oh-my-zsh-assets.sh`, `bootstrap/scripts/check.sh`, and
  `run-smoke-tests.sh`); adding a field or special case means updating all four.
- **Shell completions**: `bootstrap/manifests/shell/completions.txt` is the
  single inventory of generated completion commands and the platforms that
  generate them. `install-shell-completions.sh` reads it for install, check, and
  list; uninstall enumerates assets through `list`; the 55 and 60 hooks hash it.
  Generated files carry an ownership marker, so removing a command or platform
  from the manifest makes the next install prune the marked files it no longer
  declares; unmarked files and symlinks are never removed. Package-manager
  assets stay package-owned. Generator adapters stay in the installer because
  the CLIs differ; a new command needs an adapter only when no existing one
  fits. Keep `zsh-completions` last in `fpath` as fallback precedence.
- **Runtimes** (mise): pinned to complete versions in
  `xdg_config/mise/config.toml.tmpl`. Bump intentionally.
- **Binary-distributed tools** (for example `golangci-lint` and `uv`): pinned
  via mise alongside the runtimes. Ownership follows the manifest that declares
  a tool; nothing else polices the split.
- **Go tools** (`bootstrap/manifests/ecosystem/go-tools.txt`): every entry pins
  an exact `module@vX.Y.Z` version so clean installs and existing machines
  converge; the installer rejects anything else.
- **Python tools** (`bootstrap/manifests/ecosystem/uv-tools.txt`): prefer pinned
  versions.

`bootstrap/scripts/check.sh` validates the same declared inventories the
installers consumed instead of a second tool list: apt manifests through
`dpkg-query`, pacman manifests through `pacman -Q`, Brewfiles through
`brew bundle check`, the mise configuration through `mise ls --missing`, the
ecosystem manifests by binary name, the completion manifest through the
installer's `check` action, and the font manifest's family and faces through
Fontconfig on Linux or the user font directory on macOS. Adding an ordinary
manifest entry therefore extends the check without editing it. Hook 60 calls
this script during apply.

Run `bash bootstrap/scripts/check.sh [config-file]` to check an existing
installation on demand. The optional argument selects the chezmoi config that
contains the persisted desktop choice. Omit it to use the normal chezmoi config.

Related low-risk dependency updates may share a merge request when they use the
same validation path and remain easy to review and roll back. Keep major,
breaking, or independently risky upgrades isolated, and explain the grouping
and validation in the merge request description.

If you touch the install flow itself, keep the change scoped and review the
relevant entrypoint under `bootstrap/scripts/install-*.sh` before merging.

### Baseline Refresh

Review the baseline monthly, during the first weekend of each month. A review
does not require changing every pin or adopting every new major release. Handle
relevant security fixes, approaching end of support, and defects that block
normal use without waiting for a routine refresh. Reassess the cadence if
upstream activity or validation cost changes substantially. This document
defines the maintenance policy; it does not create a scheduled job.

Follow each ecosystem's established version-selection practice rather than
uniformly choosing the newest release. Select a supported release line first,
then normally take its latest compatible patch. Use upstream recommendations,
support policies, and relevant ecosystem compatibility evidence; a release
listing alone does not establish community adoption. When adoption evidence is
unclear, retain the supported baseline unless there is a concrete reason to
change it. Record that uncertainty rather than calling a version mainstream.

- **Node.js**: Follow the [LTS
  recommendation](https://nodejs.org/en/about/previous-releases). Prefer Active
  LTS for the shared baseline; retain a supported Maintenance LTS line when
  ecosystem compatibility warrants it. A new LTS designation alone does not
  require a branch change.
- **Go**: Choose within the [supported stable
  lines](https://go.dev/doc/devel/release#policy), considering ecosystem
  adoption and support from gopls, Delve, and golangci-lint together. Do not
  invent an LTS policy or require the newest line.
- **Python**: Prefer a mature, broadly supported branch with [upstream
  maintenance](https://devguide.python.org/versions/), normally in bugfix
  support. Check relevant libraries and tooling before changing branches;
  neither the newest release nor a fixed one-version lag is the rule.
- **Development CLIs and validation tools**: Follow each project's recommended
  stable channel or maintained major line and its runtime requirements. Check
  release notes for breaking changes and known regressions, including minor
  releases of tools still at version 0.x; do not assume every latest release is
  suitable.
- **System packages and desktop assets**: Keep package-manager ownership. Check
  separately pinned assets against upstream releases; update the archive URL and
  digest together when needed.

#### Run the Review

Use the repository skill
[`refresh-devenv-baseline`](../.agents/skills/refresh-devenv-baseline/SKILL.md)
for the execution workflow. It covers the starting point, version decisions,
validation, authorized delivery, and result reporting.

Invoke it from a chat working in this repository:

```text
Use $refresh-devenv-baseline to review and refresh this repository's baseline.
```

Keep the execution host, schedule, notification destination, and standing
permissions in the task configuration. Have the task invoke this skill.
Run it manually before enabling recurring execution. Verify both the checks
and delivery to the intended destination. Creating the skill does not create
a schedule or authorize commits, pushes, PRs, merges, or live installation.

The skill files are repository metadata. Git includes them through a narrow
exception in `.gitignore`. `.chezmoiignore` keeps them out of the home
directory.

## Removing Things

Removing a default is as significant as adding one. Before removing:

- Confirm the default is not used by bootstrap scripts or smoke tests.

## Validating Local Environment Boundaries

`$XDG_CONFIG_HOME/oh-my-devenv/env.sh` holds persistent non-secret shell
environment such as `GOPRIVATE`, `GONOSUMDB`, and `GONOPROXY`. Bash and Zsh read
it; bootstrap does not. `$XDG_CONFIG_HOME/oh-my-devenv/bootstrap.env` holds
bootstrap-only controls such as `GOPROXY` or `DOTFILES_FORCE_REINSTALL`. Neither
file may change
`XDG_CONFIG_HOME` or `XDG_DATA_HOME`; export custom absolute roots before the
shell or chezmoi starts.

To validate the consumer boundary:

1. Create the file from
   [`docs/local-overlay-examples/env.sh.example`](local-overlay-examples/env.sh.example)
   and add a test export such as `export GOPRIVATE='<private-module-prefixes>'`.
2. Open a fresh Zsh and confirm it is visible:

   ```bash
   zsh -lc 'source "$HOME/.zsh/env.zsh"; printf "%s\n" "${GOPRIVATE:-<unset>}"'
   ```

3. Open a fresh Bash and confirm it is visible:

   ```bash
   bash -lc 'source "$HOME/.bash/env.bash"; printf "%s\n" "${GOPRIVATE:-<unset>}"'
   ```

4. Create `bootstrap.env` from its example, add a test export such as
   `export GOPROXY='https://goproxy.internal.example'`, and confirm bootstrap
   sees it:

   ```bash
   bash -lc 'source bootstrap/scripts/common.sh; printf "%s\n" "${GOPROXY:-<unset>}"'
   ```

The shell checks should agree with each other; the bootstrap check should
reflect
`bootstrap.env` independently.

## Security

- `gitleaks` scans staged diffs on every commit via `pre-commit`. Bootstrap
  smoke tests run in CI only (see CI section below), not as a pre-commit hook.
- Secrets and credentials never live in this repository. They stay in local
  overlays or user-owned stores (`$XDG_CONFIG_HOME/oh-my-devenv/secrets.sh`,
  `$XDG_CONFIG_HOME/oh-my-devenv/git/config`,
  `$XDG_CONFIG_HOME/oh-my-devenv/git/hooks/*`, `~/.ssh/config.d/*.conf`, `uv
  auth`, `~/.npmrc`).
- `bootstrap/scripts/common.sh` deliberately reads only
  `$XDG_CONFIG_HOME/oh-my-devenv/bootstrap.env`, never `env.sh` or `secrets.sh`.
  If Codex, Claude Code, or another automation needs tokens, launch it from a
  shell that explicitly sourced `secrets.sh` or use that tool's own secret/env
  injection.
- The baseline's managed `mise` config turns GitHub Artifact Attestations
  verification off. This is a reliability tradeoff for shared egress
  environments (OrbStack VMs, shared CI runners, corp NAT) where anonymous
  GitHub API rate limits can otherwise break a clean install before the
  toolchain is usable.
- The Linux font installer accepts a resumable alternate download URL on
  supported Arch and Ubuntu desktops, but always verifies the repository-pinned
  SHA-256 digest and required PostScript names before replacing a baseline-owned
  font directory.
- To validate or dogfood the stricter path, opt back in explicitly with
  `MISE_GITHUB_ATTESTATIONS=true MISE_AQUA_GITHUB_ATTESTATIONS=true chezmoi
  apply`.
- Report suspected exposed secrets privately to the maintainer; do not open a
  public issue or MR.

## CI

`.github/workflows/ci.yml` is the only workflow. It runs on every pull
request, on every push to `main`, once a week, and on manual dispatch. The
weekly run catches upstream drift in unpinned layers when nobody pushes. A new
push to a pull request cancels the previous run.

Every job below is a required status check on `main`. Keep the job names
stable; renaming one requires the same change in the branch protection rule.

- `secret-scan` runs `gitleaks` over the repository tree to catch committed
  secrets.
- `smoke-tests-linux`, `smoke-tests-macos`, and `smoke-tests-arch` run
  `run-smoke-tests.sh` on `ubuntu-latest`, on `macos-latest` with the system
  `/bin/bash` (Bash 3.2), and in an `archlinux:base` container. The suite
  renders and syntax-checks the baseline, validates contracts and deployment
  boundaries, and exercises selected behavior with stubs and temporary roots.
- `apply-linux`, `apply-ubuntu-desktop`, `apply-arch`, and `apply-macos` start
  only after every smoke job passes. Each runs
  `bootstrap/scripts/ci-apply.sh` on a clean runner:
  - `apply-linux` uses `ubuntu-latest` without the desktop baseline and with a
    custom `XDG_CONFIG_HOME`.
  - `apply-ubuntu-desktop` uses an `ubuntu:26.04` container,
    `apply-arch` uses an `archlinux:base` container, and `apply-macos` uses
    `macos-latest`. These three enable the desktop baseline. The macOS job
    installs the OrbStack cask without launching OrbStack.

`ci-apply.sh` runs the same round trip on every platform:

1. Seed pre-existing user files and render the chezmoi config at its default
   location.
2. Apply, then require `All checks passed.` from the final hook and a passing
   `bootstrap/scripts/check.sh`. Confirm the first-run backup and the
   preservation of unmanaged files.
3. Apply again without changes. The change-triggered final hook must not
   rerun, and the check must still pass.
4. Run `uninstall.sh --confirm`. The main chezmoi `scriptState` and
   `entryState` buckets must be empty, and the check must fail.
5. Apply again. The final hook must rerun, and the check must pass.

The script refuses to run unless `CI=true`, because it uninstalls from `$HOME`.

The smoke suite is scoped to source-level bootstrap behavior and safe fixture
operations. The [validation policy](../CONTRIBUTING.md#local-validation)
identifies the documentation fixtures that are part of that contract; other
documentation prose remains governed by targeted review. Hosted full-apply jobs
do not cover every hardware model, OS version, or existing-machine state.

Use [`docs/04-macos-preflight.md`](04-macos-preflight.md) when a concrete macOS
concern falls outside the hosted runner coverage. Record the result in the
review description.

## Disposable environment reset

Use `bootstrap/scripts/uninstall.sh` when you need to tear down **only** what
this baseline's `chezmoi apply` put on disk — for example a throwaway Linux
container, a CI scratch image, or a VM you are about to re-image. The script is
intentionally narrow: it does **not** remove apt/Homebrew packages, mise shims,
or language runtimes the bootstrap installed; it only reverses chezmoi-managed
destination files, the nested source's dedicated state file, the completion
assets enumerated by `install-shell-completions.sh list`, plus a short whitelist
of bootstrap-owned directories (`~/.oh-my-zsh`,
`~/.local/state/chezmoi-first-run-backup/`, the marker-owned Maple Mono
user-font directory). The source checkout always stays in place. Both
`chezmoi managed` calls request plain
line output explicitly with `--format=`, and a failing producer aborts the run
rather than shrinking the candidate list. Like the bootstrap hooks, the script
sources `bootstrap/scripts/common.sh`, so it resolves the XDG directories and
loads `bootstrap.env` before it computes any path.

### Defaults and flags

- **Dry-run by default.** Running the script with no flags prints
  `[would-remove]` / `[would-skip]` lines and exits `0` without deleting
  anything. It also prints `[would-reset]` for the main chezmoi `scriptState`
  and `entryState` buckets without clearing them. Read the preview end-to-end
  before you add `--confirm`.
- **`--confirm`** performs the deletions after an optional backup tarball under
  `~/.local/state/chezmoi-uninstall-backup/<UTC-timestamp>/` (unless
  `--no-backup` is also passed — intended for scripted CI where the filesystem
  is ephemeral anyway). The file archive includes dangling symlinks. After
  removal succeeds, the script clears the main chezmoi `scriptState` and
  `entryState` buckets using the same source and default configuration as its
  managed-file inventory. This permits `run_once_` and `run_onchange_` hooks to
  run again on a later `chezmoi apply` or `chezmoi init --apply`. Other state
  buckets remain unchanged.
- **`--no-backup`** only makes sense together with `--confirm`; it skips the
  pre-delete archive.

### Overlays are never deleted

The script reads
[`bootstrap/manifests/local-overlays.tsv`](../bootstrap/manifests/local-overlays.tsv)
and logs `[would-skip] overlay-protected` for every matching user-owned path. If
a path is both managed and an overlay (it should not be), the overlay rule wins.

Completion candidates must carry the installer's ownership marker at both
current and obsolete targets. The script rechecks ownership immediately before
deletion. It preserves unmarked files and symlinks in the completion directories.

### Chezmoi `--source` checkouts

Uninstall preserves the source checkout at every location, including
`~/.local/share/chezmoi`. Remove it manually if needed. Run `chezmoi apply` from
the retained checkout when you want to restore the baseline.

### CI Coverage

The smoke suite exercises the dry run, `--confirm`, and `--confirm --no-backup`
under isolated HOME and XDG roots (on Bash 3.2 in the macOS job). Each confirmed
run has a guard that rejects the real home directory. Tests inspect backup
archives, verify both script-state resets, and check that overlays, unowned
completions, unrelated files, and the source checkout survive. Inspect the dry
run before using `--confirm` on a real machine.

## Related Documents

- `docs/README.md` — documentation index and reader routing.
- `README.md` — user-facing bootstrap instructions and repository tour.
- `docs/01-onboarding.md` — five-minute first-run walkthrough (ordered steps
  from clean laptop to baseline).
- `docs/02-reference.md` — bootstrap hooks, installed tools, day-to-day
  commands, and the full environment-variable / flag reference.
- `CONTRIBUTING.md` — contributor workflow and scope rules.
- `docs/design/01-release-and-versioning.en.md` — release and versioning policy.
- `CHANGELOG.md` — human-readable release history. Every PR that ships a
  user-visible change updates its `[Unreleased]` section.
