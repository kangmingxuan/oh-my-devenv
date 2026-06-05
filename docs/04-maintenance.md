# Maintenance Guide

This document describes how this repository is maintained day to day. It complements `CONTRIBUTING.md`, which covers the contributor-facing workflow.

The repository is maintained on a **best-effort** basis by a single maintainer. The goal is a useful shared baseline with cheap validation, not a platform-grade environment product.

## Principles

1. **Single baseline.** This repository ships a single shared default. There is no `personal` vs. `work` mode, and no per-user branches.
2. **Conservative defaults.** A default lands here only if it is useful for most engineers and safe on a fresh machine. Team- or project-specific tweaks stay in local overlays.
3. **No private data.** No personal emails, usernames, internal IP ranges, or credentials. Host-specific corporate or private infrastructure details stay in overlays or user-owned config.
4. **Reproducible bootstrap.** Every change must keep `bash bootstrap/scripts/run-smoke-tests.sh` passing and keep a clean-machine bootstrap working on macOS, Ubuntu/Debian, and WSL.

## Roles

- **Maintainers**: merge merge requests, cut releases, own the CI and governance files.
- **Contributors**: open review changes that follow `CONTRIBUTING.md` and the repository's current review workflow.

For now this repository does not require a formal maintainer rotation. The maintainer is whoever currently owns the baseline. If ownership later splits across areas (bootstrap vs docs vs CI, or the owner becomes a group), update the repository's ownership metadata and this note together.

## Managing The Public/Internal Split

This repository now operates as a **public core** plus an **internal overlay**.

- The public GitHub repository is the source of truth for shared bootstrap logic, shared docs, and other public-safe defaults.
- The internal GitLab repository is the source of truth for internal-only defaults, internal workflow files, and internal operational docs.
- When a change is in scope for both distributions, land it in the public repo first and sync it into the internal repo after review.

### Decide Where To Edit First

Use this rule before opening a branch:

1. If the change benefits both distributions or changes shared runtime behavior, start in the public worktree.
2. If the change depends on internal hosts, internal identity rules, or GitLab-only workflow, start in the internal worktree.
3. If the change starts from an internal use case but the mechanism is reusable, upstream the mechanism to public and keep only the values or policy internal.

Examples of **public-first** changes:

- bootstrap script fixes
- manifest updates for broadly useful tools
- shared shell/template behavior
- public-safe documentation clarifications
- changes to the public quick-start or contribution flow

Examples of **internal-only** changes:

- built-in rewrites for internal Git hosts
- internal CI / issue / MR workflow files
- internal corporate-network instructions
- guardrails tied to internal email domains or internal remotes

### Recommended Local Layout

The current maintainer workflow uses two local worktrees with different Git identities and push defaults:

- **Public worktree**: branch `public-upstream`, tracking `public/main`
- **Internal worktree**: branch `main`, tracking `origin/main`

That split keeps public commits on a public identity and internal commits on an internal identity while reducing the chance of pushing the right code to the wrong remote.

### Syncing Shared Changes From Public Into Internal

After a shared change lands on GitHub `main`, sync it into the internal repo from the internal worktree:

1. Fetch both remotes:

   ```bash
   git fetch --multiple public origin --prune
   ```

2. Cut a short-lived sync branch from internal `main`:

   ```bash
   git switch -c sync/public-<date> origin/main
   ```

3. Merge the latest public core:

   ```bash
   git merge --no-ff public/main
   ```

4. Resolve conflicts using the boundary rules below.
5. Run the validation checklist below.
6. Open a GitLab review branch / MR back into internal `main`.

Do **not** edit `public-upstream` directly from the internal worktree. Treat it as the public history anchor, not as a scratch branch.

### Known Internal Overlay-Owned Paths

The internal repository intentionally owns a small set of paths that may differ from the public core. When a sync touches one of these, assume the internal side needs a deliberate review instead of accepting the merge blindly.

- `.gitlab-ci.yml`
- `.gitlab/**`
- `AGENTS.md`
- `CODEOWNERS`
- `.chezmoi.toml.tmpl`
- `.chezmoiscripts/run_onchange_after_60-check.sh.tmpl`
- `dot_gitconfig.tmpl`
- `docs/02-corp-network-integration.md`
- `docs/local-overlay-examples/git-pre-push.example`
- `bootstrap/scripts/run-smoke-tests.sh`

If a shared improvement belongs in one of those files, extract the reusable part into the public repo first and then re-apply the internal-only part on top.

### Validation After A Public->Internal Sync

Use the strongest practical checks that match the change:

1. Always run:

   ```bash
   bash bootstrap/scripts/run-smoke-tests.sh
   ```

2. Also run this when Linux/WSL conditionals or `.chezmoi.toml.tmpl` changed:

   ```bash
   DOTFILES_FORCE_WSL=1 bash bootstrap/scripts/run-smoke-tests.sh
   ```

3. Follow [docs/03-macos-preflight.md](03-macos-preflight.md) if the synced change touches macOS-specific surface.
4. Re-check internal-only behavior if the sync touched any overlay-owned path listed above.

### Conflict Rules

When a sync conflicts, use these default rules:

- **Shared behavior wins in the public repo first.** If the conflict is really about shared runtime behavior, update the public repo and sync again instead of inventing a one-off internal patch.
- **Internal-only policy wins in the internal repo.** Keep internal hosts, internal identity rules, and GitLab-only workflow local to the internal branch.
- **Do not hide uncertainty inside a merge conflict resolution.** If you cannot explain why a line belongs on one side, stop and classify the change again.

## Documentation Boundaries

Keep the doc set opinionated and non-overlapping:

- `README.md`: landing page, quick start, concise repository tour, and the first links a new reader sees on the repository host.
- `docs/README.md`: the documentation index and "which page should I read?" router.
- `docs/01-onboarding.md`: the ordered first-run journey from a clean machine to a working baseline.
- `docs/local-overlay-examples/`: copyable machine-local templates that deliberately do not deploy through `chezmoi`.
- `docs/03-macos-preflight.md`: manual review steps for review changes that touch macOS-specific behavior.
- `docs/design/`: rationale and technical design, not operational steps.
- `docs/04-maintenance.md`: maintainer workflow, validation expectations, dependency hygiene, and release discipline.

When adding new documentation, pick one canonical home and make other pages link to it instead of copying long instructions in multiple places.

## Branching Model

- `main` is the only long-lived branch. It must remain in a deployable state.
- All work happens on short-lived feature branches branched from `main`.
- Changes into `main` go through the repository's normal review workflow with a green CI pipeline.
- Force pushes to `main` are not allowed. Rewrites live only on feature branches before review.

## Review Expectations

A reviewable change is ready to merge when all of the following hold:

- The CI pipeline is green. Every reviewable change runs two automatic smoke jobs, plus one manual macOS stub:
  - `smoke-tests-linux` — the default Linux shape on a shared-runner `ubuntu:24.04` image.
  - `smoke-tests-wsl-shaped` — the same smoke suite with `DOTFILES_FORCE_WSL=1` so the WSL branch in `.chezmoi.toml.tmpl` is exercised.
   - `smoke-tests-macos-manual` — placeholder, manually triggered, that points the contributor at [`docs/03-macos-preflight.md`](03-macos-preflight.md). No shared macOS runner is wired to this project yet; review changes that touch macOS-specific surface are validated by the preflight checklist and a pasted signoff.
- At least one maintainer has approved the change.
- The review description follows the repository's normal template and the change is in scope for the baseline.
- No unresolved review threads remain.

## Release / Rollout

Engineers pull the latest `main` through `chezmoi update`. Because changes reach users immediately, prefer:

- Small, reviewable merge requests.
- Behavior changes behind an opt-in environment variable when feasible (for example `NO_LOGO`, `NO_EMOJI`).
- A note in the merge request description when a change is expected to be user-visible.

Milestones cut annotated git tags (`v0.<M>.0`). After a milestone's final MR merges, the maintainer pushes the tag manually to keep tagging a deliberate act. Tag messages follow the `v<version> — <milestone-name>` convention. See `CHANGELOG.md` for the versioning policy and the full history.

## Dependencies

Third-party dependencies pulled in by this repository fall into these categories:

- **System packages** (`apt`, Homebrew): bump the manifest files (`bootstrap/manifests/system/apt-packages.txt`, `bootstrap/manifests/system/Brewfile`). Prefer stable distro names over version pins.
- **Shell assets** (oh-my-zsh and plugins): managed by explicit Git clone/update. The upstream repository is captured in `bootstrap/manifests/shell/oh-my-zsh-plugins.txt`.
- **Runtimes** (mise): pinned in `dot_config/mise/config.toml.tmpl`. Bump intentionally.
- **Binary-distributed tools** (for example `golangci-lint`, `uv`, and `usage`): pinned via mise alongside the runtimes.
- **Go tools** (`bootstrap/manifests/ecosystem/go-tools.txt`): `@latest` by default, pin only when a regression is known.
- **Python tools** (`bootstrap/manifests/ecosystem/uv-tools.txt`): prefer pinned versions.

When bumping a pinned dependency, keep the bump isolated in its own merge request and include a short note in the MR description explaining why.

If you touch the install flow itself, keep the change scoped and review the relevant entrypoint under `bootstrap/scripts/install-*.sh` before merging.

## Removing Things

Removing a default is as significant as adding one. Before removing:

- Confirm the default is not used by bootstrap scripts or smoke tests.
- Add a note to the merge request describing what engineers should do on machines that already installed it.

## Validating The Shared Work Env Overlay

`${XDG_CONFIG_HOME:-$HOME/.config}/work/env.sh` is the one shared non-secret env slot that Bash, Zsh, and bootstrap all read. Use it for values like `GOPRIVATE`, `GONOSUMDB`, `GONOPROXY`, and `DOTFILES_*` mirror controls.

To validate that all three consumers agree:

1. Create the file from [`docs/local-overlay-examples/work-env.sh.example`](local-overlay-examples/work-env.sh.example) and add a test export such as `export GOPRIVATE='<private-module-prefixes>'`.
2. Open a fresh Zsh and confirm it is visible:

   ```bash
   zsh -lc 'source "$HOME/.zsh/env.zsh"; printf "%s\n" "${GOPRIVATE:-<unset>}"'
   ```

3. Open a fresh Bash and confirm it is visible:

   ```bash
   bash -lc 'source "$HOME/.bash/env.bash"; printf "%s\n" "${GOPRIVATE:-<unset>}"'
   ```

4. Confirm bootstrap sees the same value:

   ```bash
   bash -lc 'source bootstrap/scripts/common.sh; printf "%s\n" "${GOPRIVATE:-<unset>}"'
   ```

If those three values differ, the contract drifted and the change is not ready to merge.

## Validating A Mirror Override

Re-running the full bootstrap to confirm that a `DOTFILES_<KEY>` override points at a working mirror is overkill. To validate a single override without touching the rest of the system:

1. Open a fresh shell session so nothing from a previous `chezmoi apply` leaks in.
2. Export the override you want to verify (or place the same value in `${XDG_CONFIG_HOME:-$HOME/.config}/work/env.sh` and open a fresh shell):

   ```bash
   export DOTFILES_MIRROR_MODE=internal
   export DOTFILES_GOPROXY='https://goproxy.internal.example'
   ```

3. Ask `mirrors.sh` to materialize its view of the environment:

   ```bash
   source bootstrap/scripts/common.sh
   dotfiles_apply_mirror_env
   env | grep -E '^(GOPROXY|UV_INDEX_URL|HOMEBREW_|DOTFILES_)'
   ```

   Only the keys you overrode should appear. Keys without a `DOTFILES_*` override will emit a `WARNING` line instead of exporting the manifest's `<placeholder>` value.

4. Exercise the one consumer whose endpoint you changed. Example for `GOPROXY`:

   ```bash
   bash bootstrap/scripts/install-go-tools.sh bootstrap/manifests/ecosystem/go-tools.txt
   ```

   If the mirror is unreachable or rejects the request, the failure surfaces immediately with the usual `go install` error instead of being buried under the full bootstrap output.

5. When done, unset the overrides or close the shell. The next `chezmoi apply` returns to the mode encoded in your shell init files.

`bash bootstrap/scripts/run-smoke-tests.sh` still runs only under the implicit `external` mode, because the CI runner has no way to reach any internal endpoint. The assertions verify the mode-switch logic and defend the `external` defaults in the manifest; they do not try to dial the mirrors themselves.

## Validating The WSL Branch

`.chezmoi.toml.tmpl` detects WSL by grepping `/proc/version` for `microsoft`. That probe is invisible on macOS and often invisible on native Linux, so the isWsl branch silently rots unless exercised. The `smoke-tests-wsl-shaped` CI job covers this in lockstep with the default shape, but to reproduce it locally:

1. Export the escape hatch:

   ```bash
   export DOTFILES_FORCE_WSL=1
   ```

2. Re-run the smoke suite. It should still pass, with every template rendered under the `isWsl = true` shape:

   ```bash
   bash bootstrap/scripts/run-smoke-tests.sh
   ```

3. Unset the variable when done:

   ```bash
   unset DOTFILES_FORCE_WSL
   ```

`DOTFILES_FORCE_WSL` accepts `1`, `true`, or `yes` to force WSL on; `0`, `false`, or `no` to force WSL off; and falls through to the `/proc/version` probe for any other value. Use it when the probe misfires (tmux/ssh sessions that strip the kernel banner, Linux containers meant to behave like a WSL runtime, CI jobs that need to pin behaviour). It does nothing on macOS because the non-Linux branch already sets isWsl to `false`.

## Security

- `gitleaks` scans staged diffs on every commit via `pre-commit`. Bootstrap smoke tests run in CI only (see CI section below), not as a pre-commit hook.
- Secrets and credentials never live in this repository. They stay in local overlays or user-owned stores (`~/.gitconfig.local`, `~/.config/git/hooks/pre-push`, `~/.zshrc.secrets`, `~/.bashrc.secrets`, `~/.ssh/config.d/*.conf`, `uv auth`, `~/.npmrc`).
- The baseline's managed `mise` config defaults GitHub Artifact Attestations verification to off, and the runtime-install hook exports the same default for first bootstrap. This is a reliability tradeoff for shared egress environments (OrbStack VMs, shared CI runners, corp NAT) where anonymous GitHub API rate limits can otherwise break a clean install before the toolchain is usable.
- To validate or dogfood the stricter path, opt back in explicitly with `MISE_GITHUB_ATTESTATIONS=true MISE_AQUA_GITHUB_ATTESTATIONS=true chezmoi apply`. Python follows the global setting unless `MISE_PYTHON_GITHUB_ATTESTATIONS` is set separately.
- Report suspected exposed secrets privately to the maintainer; do not open a public issue or MR.

## CI

The repository CI pipeline is intentionally lightweight:

- `smoke-tests-linux` and `smoke-tests-wsl-shaped` are the only automatic Linux jobs.
- Both jobs prepare just enough tooling on a fresh `ubuntu:24.04` runner to execute `bootstrap/scripts/run-smoke-tests.sh`.
- The pipeline is allowed to be simple and occasionally imperfect. It should catch obvious repo regressions, not model every clean-machine install path end to end.

The smoke suite is scoped to executable bootstrap behavior: template rendering, shell syntax, manifest parsing, deployability boundaries, mirror mode, WSL detection, and `shellcheck`. It deliberately does not freeze README prose, onboarding headings, changelog markers, badges, ownership wording, or retired CI lanes; those stay governed by review and the documentation boundaries above.

If a change needs heavier confidence than the smoke jobs provide, validate it manually on a real machine or disposable VM and record that in the review description.

## Disposable environment reset

Use `bootstrap/scripts/uninstall.sh` when you need to tear down **only** what this baseline's `chezmoi apply` put on disk — for example a throwaway Linux container, a CI scratch image, or a VM you are about to re-image. The script is intentionally narrow: it does **not** remove apt/Homebrew packages, mise shims, or language runtimes the bootstrap installed; it only reverses chezmoi-managed destination files plus a short whitelist of bootstrap-owned directories (`~/.oh-my-zsh`, `~/.local/state/chezmoi-first-run-backup/`, and the chezmoi source tree under `~/.local/share/` when that is the canonical data path).

**Defaults and flags**

- **Dry-run by default.** Running the script with no flags prints `[would-remove]` / `[would-skip]` lines and exits `0` without deleting anything. Read the preview end-to-end before you add `--confirm`.
- **`--confirm`** performs the deletions after an optional backup tarball under `~/.local/state/chezmoi-uninstall-backup/<UTC-timestamp>/` (unless `--no-backup` is also passed — intended for scripted CI where the filesystem is ephemeral anyway).
- **`--no-backup`** only makes sense together with `--confirm`; it skips the pre-delete archive.

**Overlays are never deleted**

The script skips (and logs `[would-skip] overlay-protected`) for the local overlay slots documented in the README: `${XDG_CONFIG_HOME:-$HOME/.config}/work/env.sh`, `~/.zshrc.secrets`, `~/.bashrc.secrets`, `~/.zsh/work.zsh`, `~/.bash/work.bash`, `~/.gitconfig.local`, `~/.config/git/hooks/pre-push`, `~/.npmrc`, and `~/.ssh/config.d/*.conf`. If a path is both managed and an overlay (it should not be), the overlay rule wins.

User-owned Git hooks such as `~/.config/git/hooks/pre-push` also stay untouched.
They are outside the managed destination set, so `uninstall.sh` never removes
them as part of baseline cleanup.

**Chezmoi `--source` checkouts**

When your active `chezmoi source-path` points **outside** `~/.local/share/` (for example a `chezmoi init --apply --source=$PWD` workspace checkout), the script refuses to auto-delete that tree and prints a `[would-skip]` line instead — removing the working copy is never the safe default.

**CI**

`uninstall.sh` is no longer exercised in a dedicated CI job. Treat it as a maintainer-facing operational helper: validate it locally when you change it, and prefer dry-run output inspection before using `--confirm`.

## Related Documents

- `docs/README.md` — documentation index and reader routing.
- `README.md` — user-facing bootstrap instructions and repository tour.
- `docs/01-onboarding.md` — five-minute first-run walkthrough (ordered steps from clean laptop to baseline).
- `CONTRIBUTING.md` — contributor workflow and scope rules.
- `docs/design/01-public-github-core-and-internal-gitlab-overlay.en.md` — the design rationale for the current public/internal repository model.
- `CHANGELOG.md` — human-readable release history per milestone, plus the semver / tagging policy. Every MR that ships a user-visible change updates its `[Unreleased]` section.
