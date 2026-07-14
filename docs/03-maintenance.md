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

## Documentation Boundaries

Keep the doc set opinionated and non-overlapping:

- `README.md`: landing page, quick start, concise repository tour, and the first links a new reader sees on the repository host.
- `docs/README.md`: the documentation index and "which page should I read?" router.
- `docs/01-onboarding.md`: the ordered first-run journey from a clean machine to a working baseline.
- `docs/02-reference.md`: lookup tables for bootstrap hooks, installed tools, day-to-day commands, and environment variables / flags.
- `docs/local-overlay-examples/`: copyable machine-local templates that deliberately do not deploy through `chezmoi`.
- `docs/04-macos-preflight.md`: manual review steps for review changes that touch macOS-specific behavior.
- `docs/design/`: rationale and technical design, not operational steps.
- `docs/03-maintenance.md`: maintainer workflow, validation expectations, dependency hygiene, and release discipline.

When adding new documentation, pick one canonical home and make other pages link to it instead of copying long instructions in multiple places.

## Branching Model

- `main` is the only long-lived branch. It must remain in a deployable state.
- All work happens on short-lived feature branches branched from `main`.
- Changes into `main` go through the repository's normal review workflow with a green CI pipeline.
- Force pushes to `main` are not allowed. Rewrites live only on feature branches before review.

## Review Expectations

A reviewable change is ready to merge when all of the following hold:

- The CI pipeline is green. Every reviewable change runs these GitHub Actions jobs:
  - `smoke-tests-linux` — renders and syntax-checks the baseline on `ubuntu-latest`.
  - `smoke-tests-macos` — the same smoke suite on `macos-latest`, so the `darwin` template arms are rendered and shell-checked instead of going untested.
  - `apply-linux` — a real `chezmoi init --apply` end to end on `ubuntu-latest`, asserting the final environment check prints `All checks passed.`
  - `secret-scan` — a full `gitleaks` scan of the repository tree.

  Full macOS *install* validation (Brewfile parity, mise runtimes, Go/uv tools) still relies on the manual [`docs/04-macos-preflight.md`](04-macos-preflight.md) checklist and a pasted signoff; the `smoke-tests-macos` job only covers rendering and syntax.
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

- **System packages** (`apt`, Homebrew): bump the manifest files (`bootstrap/manifests/system/apt-packages.txt`, `bootstrap/manifests/system/Brewfile`). Prefer stable distro names over version pins. macOS GUI apps and personal CLIs stay opt-in through `Brewfile.optional` or user-owned `DOTFILES_EXTRA_BREWFILES` paths, not baseline defaults.
- **Shell assets** (oh-my-zsh and plugins): managed by explicit Git clone/update. The upstream repository is captured in `bootstrap/manifests/shell/oh-my-zsh-plugins.txt`. That manifest uses a strict two-field, order-sensitive contract shared by four readers (`dot_zshrc.tmpl`, `install-oh-my-zsh-assets.sh`, the `60-check` hook, and `run-smoke-tests.sh`); adding a field or special case means updating all four.
- **Runtimes** (mise): pinned to complete versions in `dot_config/mise/config.toml.tmpl`. Bump intentionally.
- **Binary-distributed tools** (for example `golangci-lint` and `uv`): pinned via mise alongside the runtimes.
- **Go tools** (`bootstrap/manifests/ecosystem/go-tools.txt`): pin exact module versions so clean installs and existing machines converge.
- **Python tools** (`bootstrap/manifests/ecosystem/uv-tools.txt`): prefer pinned versions.

Related low-risk dependency updates may share a merge request when they use the
same validation path and remain easy to review and roll back. Keep major,
breaking, or independently risky upgrades isolated, and explain the grouping
and validation in the merge request description.

If you touch the install flow itself, keep the change scoped and review the relevant entrypoint under `bootstrap/scripts/install-*.sh` before merging.

For macOS Homebrew opt-ins, remember that `DOTFILES_EXTRA_BREWFILES` is a
first-bootstrap convenience rather than an always-on sync loop. Document manual
`brew bundle install --file=...` commands for any local Brewfile workflow you
introduce.

## Removing Things

Removing a default is as significant as adding one. Before removing:

- Confirm the default is not used by bootstrap scripts or smoke tests.
- Add a note to the merge request describing what engineers should do on machines that already installed it.

## Validating The Shared Local Env Overlay

`${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/env.sh` is the one shared non-secret env slot that Bash, Zsh, and bootstrap all read. Use it for values like `GOPRIVATE`, `GONOSUMDB`, `GONOPROXY`, and `DOTFILES_*` mirror controls.

To validate that all three consumers agree:

1. Create the file from [`docs/local-overlay-examples/env.sh.example`](local-overlay-examples/env.sh.example) and add a test export such as `export GOPRIVATE='<private-module-prefixes>'`.
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

Mirror mode currently covers the consumers wired through `dotfiles_apply_mirror_env`: Go tools (`GOPROXY`), uv tools (`UV_INDEX_URL`), Homebrew API/bottles, the mise installer URL, and the oh-my-zsh main repo URL. It does not rewrite apt sources, mise runtime downloads, or oh-my-zsh plugin repositories.

1. Open a fresh shell session so nothing from a previous `chezmoi apply` leaks in.
2. Export the override you want to verify (or place the same value in `${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/env.sh` and open a fresh shell):

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

## Security

- `gitleaks` scans staged diffs on every commit via `pre-commit`. Bootstrap smoke tests run in CI only (see CI section below), not as a pre-commit hook.
- Secrets and credentials never live in this repository. They stay in local overlays or user-owned stores (`${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/secrets.sh`, `~/.gitconfig.local`, `~/.config/git/hooks/pre-push`, `~/.ssh/config.d/*.conf`, `uv auth`, `~/.npmrc`).
- `bootstrap/scripts/common.sh` deliberately reads only `${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/env.sh`, never `secrets.sh`. If Codex, Claude Code, or another automation needs tokens, launch it from a shell that explicitly sourced `secrets.sh` or use that tool's own secret/env injection.
- The baseline's managed `mise` config defaults GitHub Artifact Attestations verification to off, and the runtime-install hook exports the same default for first bootstrap. This is a reliability tradeoff for shared egress environments (OrbStack VMs, shared CI runners, corp NAT) where anonymous GitHub API rate limits can otherwise break a clean install before the toolchain is usable.
- To validate or dogfood the stricter path, opt back in explicitly with `MISE_GITHUB_ATTESTATIONS=true MISE_AQUA_GITHUB_ATTESTATIONS=true chezmoi apply`. Python follows the global setting unless `MISE_PYTHON_GITHUB_ATTESTATIONS` is set separately.
- Report suspected exposed secrets privately to the maintainer; do not open a public issue or MR.

## CI

The repository CI pipeline is intentionally lightweight:

- `smoke-tests-linux` and `smoke-tests-macos` render and syntax-check the baseline on `ubuntu-latest` and `macos-latest`; running on both means the `darwin` template arms are exercised, not just the Linux ones.
- `apply-linux` runs a real `chezmoi init --apply` end to end on `ubuntu-latest` and asserts the final environment check passes, covering installer semantics the render-only smoke suite cannot.
- `secret-scan` runs `gitleaks` over the repository tree to catch committed secrets.
- The pipeline is allowed to be simple and occasionally imperfect. It should catch obvious repo regressions, not model every clean-machine install path on every platform.

The smoke suite is scoped to executable bootstrap behavior: template rendering, shell syntax, manifest parsing, deployability boundaries, mirror mode, and `shellcheck`. It deliberately does not freeze README prose, onboarding headings, changelog markers, badges, ownership wording, or retired CI lanes; those stay governed by review and the documentation boundaries above.

If a change needs heavier confidence than the smoke jobs provide, validate it manually on a real machine or disposable VM and record that in the review description.

## Disposable environment reset

Use `bootstrap/scripts/uninstall.sh` when you need to tear down **only** what this baseline's `chezmoi apply` put on disk — for example a throwaway Linux container, a CI scratch image, or a VM you are about to re-image. The script is intentionally narrow: it does **not** remove apt/Homebrew packages, mise shims, or language runtimes the bootstrap installed; it only reverses chezmoi-managed destination files plus a short whitelist of bootstrap-owned directories (`~/.oh-my-zsh`, `~/.local/state/chezmoi-first-run-backup/`, and the chezmoi source tree under `~/.local/share/` when that is the canonical data path).

**Defaults and flags**

- **Dry-run by default.** Running the script with no flags prints `[would-remove]` / `[would-skip]` lines and exits `0` without deleting anything. Read the preview end-to-end before you add `--confirm`.
- **`--confirm`** performs the deletions after an optional backup tarball under `~/.local/state/chezmoi-uninstall-backup/<UTC-timestamp>/` (unless `--no-backup` is also passed — intended for scripted CI where the filesystem is ephemeral anyway).
- **`--no-backup`** only makes sense together with `--confirm`; it skips the pre-delete archive.

**Overlays are never deleted**

The script skips (and logs `[would-skip] overlay-protected`) for the local overlay slots documented in the README: `${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/env.sh`, `${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/secrets.sh`, `${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/zshrc.zsh`, `${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/bashrc.bash`, `~/.gitconfig.local`, `~/.config/git/hooks/pre-push`, `~/.npmrc`, and `~/.ssh/config.d/*.conf`. If a path is both managed and an overlay (it should not be), the overlay rule wins.

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
- `docs/02-reference.md` — bootstrap hooks, installed tools, day-to-day commands, and the full environment-variable / flag reference.
- `CONTRIBUTING.md` — contributor workflow and scope rules.
- `docs/design/01-release-and-versioning.en.md` — release and versioning policy.
- `CHANGELOG.md` — human-readable release history per milestone, plus the semver / tagging policy. Every PR that ships a user-visible change updates its `[Unreleased]` section.
