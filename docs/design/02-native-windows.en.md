# Technical Design: Native Windows Platform

Status: accepted. Phases 3 and 4 passed the hosted Windows smoke and apply jobs. Phase 4 remains unverified on a clean standard-user Windows client. Phase 5 has not started.

## 1. Summary

Add native Windows as a fourth platform in this repository. Windows is a reduced platform: it shares the baseline data with macOS and Linux, but it does not reproduce the Unix shell layer.

- Keep one chezmoi source for all platforms.
- Share the runtime, ecosystem-tool, and Git data with the Unix platforms by default.
- Implement Windows hooks and helpers in PowerShell 7.
- Install Windows system packages with winget.
- Use a PowerShell profile instead of Zsh and Bash.
- Use Windows Terminal instead of Ghostty in the desktop baseline.

WSL is not part of this design. WSL is a Linux environment and keeps the existing Linux path.

## 2. Decisions and Ownership

The user made these decisions on 2026-11-20, except where another date is stated:

| Decision | Detail |
| --- | --- |
| Support native Windows | The work environment depends on native Windows, so WSL alone does not meet the need. |
| Use the current repository | Do not start a separate repository. |
| Share runtimes and ecosystem tools | On 2026-11-21, the user confirmed that Windows uses the shared mise language versions and ecosystem tool manifests. Select Windows system packages for their usefulness on Windows. |
| Install Oh My Posh by default | On 2026-11-21, the user chose Oh My Posh as the PowerShell counterpart of oh-my-zsh. |
| Approve the Windows system inventory | On 2026-11-21, the user approved Claude's five-package proposal in section 10. Claude selected tools that are useful on Windows, run well there, and are widely used. |
| Scope Windows as a general development baseline | Windows content stays public and general. Employer-specific content stays out of the repository. |
| Defer the Windows tool inventory | The user has not collected the full set of daily Windows tools yet. Start with the approved Windows system inventory. |
| Use the current-user, all-hosts PowerShell profile | Claude proposed this target and the user approved it. |
| Ask for design reviews from Gemini 4 Argon and Kimi K3.1 Pro | The user asked Claude to weigh these reviews together with the Codex fact-checks. |
| Persist the managed directories in the user `Path` | The user decided this on 2026-11-21, so that applications started outside PowerShell find the managed tools. Claude designed the mechanism in section 7. |

Claude proposed every other decision in this document within the scope above. Section 16 lists which review findings Claude adopted. The user approved phase 3 on 2026-11-21 and deferred the first live Windows apply until after all planned phases. Claude decided the installation scope, installer and checker behavior, device-policy handling, desktop installation and validation, and the phase-3 uninstall boundary within that approval.

The user approved phase 4 on 2026-11-22 after PR #66 merged. The shared inventories
and persistent user `Path` implement the user's decisions above. Within the
phase-4 approval, Claude chose the WinGet command, runtime hook and hash
inputs, shared tool eligibility, ecosystem installer behavior, user `Path`
ownership, uninstall, checker, path-length diagnostics, and hosted CI tests
(items 1–9 in the implementation brief).

## 3. Goals and Non-Goals

### Goals

- `chezmoi init --apply` on a supported Windows machine deploys the Windows configuration and runs the Windows hooks.
- The Windows hooks install system packages, mise, runtimes, and ecosystem tools, and end with an environment check.
- Re-running `chezmoi apply` is safe.
- Windows-only targets and hooks do not deploy, run, or change rendered content on macOS or Linux, and Unix-only targets and hooks do not deploy or run on Windows. Tests enforce this boundary.
- A change to shared data, such as a version in the mise config, can rerun hooks on every platform. This is the intended effect of sharing.

### Non-goals

- Bash, Zsh, or oh-my-zsh on Windows, including Git Bash, MSYS2, and Cygwin as run environments for this repository's Bash scripts.
- Shell completion assets for Windows in the first version.
- Ghostty and OrbStack on Windows.
- Setup of WSL itself, Docker, or container runtimes.
- Windows PowerShell 5.1.
- Hooks that require administrator elevation. Prefer user-scope installs.
- Employer-specific tools, feeds, credentials, or device policy workarounds.

## 4. Repository Layout

```text
.gitattributes                         # new; LF line endings for the source
.chezmoiscripts/
├── run_..._NN-<name>.sh.tmpl          # Unix hooks, unchanged
└── run_..._NN-<name>.ps1.tmpl         # new; Windows hooks
bootstrap/
├── manifests/
│   ├── system/winget-packages.json    # new; Windows system packages
│   ├── ecosystem/*.txt                # shared, unchanged format
│   ├── desktop/winget-packages.json   # Windows desktop packages
│   └── desktop/maple-mono-nf-cn.env   # shared font facts
├── scripts/                           # Unix Bash helpers, unchanged
└── windows/                           # new; PowerShell helpers and tests
dot_config/
├── mise/config.toml.tmpl              # shared target
└── oh-my-devenv/powershell/           # new; PowerShell profile body and theme
AppData/Local/Microsoft/Windows Terminal/Fragments/oh-my-devenv/  # new; desktop only
```

Rules:

- Put every PowerShell helper under `bootstrap/windows/`.
- Do not let a Bash helper call a PowerShell helper, and do not let a PowerShell helper call a Bash helper.
- Put new manifests in the existing layer directories (`system/`, `desktop/`, `ecosystem/`). This keeps the layer model of the cross-platform design.
- `bootstrap/` stays source-only. The existing `.chezmoiignore` rule already covers `bootstrap/windows/`.
- The Windows Terminal fragment is the only target outside a dot-path under the home directory. The smoke suite asserts that every managed target is a dot-path. Extend that assertion to allow exactly the fragment directory on Windows, and keep it strict everywhere else.

## 5. Platform Dispatch

Keep the platform decisions in the same places that the Unix platforms use:

- `.chezmoitemplates/system-package-manager` returns `winget` when `.chezmoi.os` is `windows`.
- `.chezmoitemplates/desktop-platform-supported` returns `true` on Windows.
- `.chezmoi.toml.tmpl` defaults the desktop-baseline prompt to yes on Windows, and its prompt text names the Windows contents (PowerToys, Windows Terminal settings, and Maple Mono NF CN).

Gate both hooks and deployed files through `.chezmoiignore`:

- Write ignore patterns as target paths relative to the home directory, not as source paths. A script's target name drops its `run_` attributes and `.tmpl` suffix, so `.chezmoiscripts/*.ps1` matches every Windows hook. Claude confirmed this pattern with chezmoi v2.73.2 on a disposable fixture.
- On Windows, ignore `.chezmoiscripts/*.sh` and the Unix-only targets: Zsh and Bash files, `.local/share/oh-my-devenv/xdg.sh`, Fontconfig, and Ghostty.
- Outside Windows, ignore `.chezmoiscripts/*.ps1` and the Windows-only targets: the PowerShell profile, Oh My Posh theme, and Windows Terminal fragment.
- Do not edit the existing Unix hook templates for this gate. `.chezmoiignore` keeps the gate in one place instead of ten templates. chezmoi hashes the rendered script, so a wrapper reruns a Unix hook only when it changes the rendered output, but each edited template is still a place where the gate can drift.

## 6. Hook Mapping

Keep the Unix hook numbers, so the order of the layers is the same on every platform.

| No. | Unix hook | Windows hook | Phase |
| --- | --- | --- | --- |
| 00 | Banner and XDG root check | `run_before_`: banner; fail when the interpreter is not PowerShell 7.6 or later | 2 |
| 10 | Prerequisites and first-run backup | `run_once_before_`: check `git`, first-run backup | 2 |
| 15 | — | `run_after_`, every apply: ensure the profile dot-source line (section 9, phase 2) and the persistent user `Path` entries (section 7, phase 4) | 2 |
| 20 | System packages | Check `winget`, then `winget import` from `winget-packages.json` | 3 |
| 22 | Desktop assets | Check Windows Terminal, import the desktop packages, and install Maple Mono NF CN in the user font directory | 3 |
| 25 | oh-my-zsh assets | None | — |
| 30 | Install mise | Install mise with winget when `mise` is not on `PATH` | 4 |
| 40 | Runtimes | `mise install` | 4 |
| 50 | Ecosystem tools | Go and uv tools from the shared manifests | 4 |
| 55 | Shell completions | None in the first version | 5 |
| 60 | Environment check | `check.ps1` | 2 |

Hash triggers work as on Unix. Each `run_onchange_` Windows hook includes the hashes of its manifest and its helper scripts.

Hook 30 uses winget, so mise comes from the same package manager as the other system tools. This matches the Homebrew route on macOS. The mise documentation recommends its own PowerShell install script instead: winget releases can lag, and mise turns off `mise self-update` for winget installs. Upgrade mise with `winget upgrade jdx.mise`. Hook 30 skips the install when `mise` is already on `PATH`. Otherwise it installs the
exact `jdx.mise` package from the `winget` source with user scope and confirms
`mise --version` after refreshing the hook environment. A WinGet error stops
apply under the same device-policy rule as hook 20.
[WinGet package manifest](https://github.com/microsoft/winget-pkgs/blob/master/manifests/j/jdx/mise/2026.11.12/jdx.mise.installer.yaml)

## 7. PowerShell Rules

- Require PowerShell 7.6 or later before the first `chezmoi init --apply`, together with `git` and `chezmoi`. 7.6 is the current LTS branch. The PowerShell support lifecycle table gives its end of support as 2028-11-14, and gives 2026-11-10 for 7.4 and 7.5. The Microsoft Lifecycle catalog shows one day later for each; the design uses the earlier dates. Every PowerShell feature this design uses exists in 7.6.
- The quick start installs PowerShell with `winget install --id Microsoft.PowerShell --exact --source winget`. On a fresh client with the unrestricted winget source, omitting `--version` selects the highest applicable release, which can be a non-LTS release. Existing installs and source policy can change the result or make the install fail. The inspected winget catalog has no separate LTS package ID.
- Write Windows hooks and helpers for PowerShell 7.6 or later only.
- On Windows, `.chezmoi.toml.tmpl` sets `[interpreters.ps1]` to `pwsh -NoLogo -NoProfile -File`. Hooks run independently of the user's PowerShell profile. Hook 15 maintains the profile entry and hook 60 verifies startup in a separate shell. Run `chezmoi init` to refresh an existing configuration before apply. [chezmoi interpreter configuration](https://www.chezmoi.io/reference/configuration-file/interpreters/).
- Install `pwsh` before starting chezmoi so every hook can resolve the interpreter from the initial `PATH`.
- The WinGet `jdx.mise` package requires the Microsoft Visual C++ 2015+ Redistributable that matches its architecture (x64 or ARM64). The redistributable installs at machine scope. On a standard-user device that lacks it, ask the device administrator to provision it before apply. Hook 30 stops if WinGet fails.
- Hook 00 fails when the running PowerShell version is below 7.6. This is a compatibility floor only; hook 00 does not check support status. The user keeps PowerShell on a supported release with its latest servicing update, as for any other prerequisite. Record the minimum in `AGENTS.md` next to the Bash 3.2 rule.
- Start every script with `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`.
- Check the exit code of every native command. `$ErrorActionPreference` does not stop on a failed native command by default.

### Environment in hooks

Every hook that runs in the chezmoi process inherits the `PATH` that chezmoi started with. An installer that changes the persistent user or machine `Path` does not change that process environment. A shared helper therefore builds the hook environment at the start of each hook:

1. Read the current machine and user `Path` values.
2. Prepend the managed directories: the mise shims directory under `%LOCALAPPDATA%\mise`, `~/.local/bin`, and `$GOBIN`.
3. Set `GOPATH` and `GOBIN` to the same defaults that the Unix env templates use (`~/go` and `$GOPATH/bin`).

In phase 3, the hook helper merges the process, machine, and current user
`Path` values. WinGet writes user-scope portable paths to
`HKCU\Environment\Path`. With symlink support, it uses
`%LOCALAPPDATA%\Microsoft\WinGet\Links`. Without it, WinGet can
add the package directory. The checker reads those values again after
hook 20. Hooks 30, 40, 50, and the checker also prepend the managed directories and set the Go defaults for their own process.
[WinGet portable installer](https://github.com/microsoft/winget-cli/blob/master/src/AppInstallerCLICore/PortableInstaller.cpp),
[WinGet Path registry implementation](https://github.com/microsoft/winget-cli/blob/master/src/AppInstallerCommonCore/PathVariable.cpp).

### Persistent user Path

The user decided to add the managed directories to the persistent user `Path` (section 2). Applications started from the Windows shell, such as an IDE launched from the Start menu, do not load the PowerShell profile. The persistent entries let them find the managed tools.

- Hook 15 adds the mise shims directory, `~/.local/bin`, and `$GOBIN` to the user `Path` in `HKCU\Environment` on every apply. This starts in phase 4, when the tools in these directories arrive.
- Add only missing entries. Never add an entry twice. Keep every other entry and its order.
- Write the resolved directory paths. Do not add a new `%GOBIN%` reference, because `GOBIN` is not persisted.
- Record each missing entry in `oh-my-devenv/user-path.json` under the effective LocalApplicationData folder before writing the registry. Reapply keeps this record and adds any entries still missing. An entry that existed before the first apply is not recorded and is not managed.
- Keep the registry value type and the unexpanded entries, such as `%USERPROFILE%` references. Do not write the expanded value back.
- Broadcast `WM_SETTINGCHANGE` with `Environment` when the registry value changes. Applications that are already running and do not handle the notification see the change only after a restart.
- Do not change the machine `Path`. It needs elevation.
- Do not persist `GOPATH` or `GOBIN`. Their values match the Go defaults.
- The uninstall preview lists recorded entries still in the user `Path`. Apply removes one exact occurrence per recorded entry and deletes the record. It keeps matching entries that existed before the first apply and all other entries. It does not restore an old snapshot of the whole `Path`.
- `check.ps1` fails when the user `Path` lacks any of the three required directories listed above, including a directory whose entry existed before the first apply. The ownership record controls uninstall removal, not the set of directories to check.
- The `Path` writer, reader, and uninstaller take the registry target as an explicit parameter. Smoke tests pass a fixture target and mock the change notification, because a temporary home does not isolate `HKCU`. The real apply job checks and restores the runner account's user `Path`.
- The profile keeps its own `PATH` setup. It sets the order in PowerShell sessions and works without the persistent entries.

`check.ps1` checks command resolution through a newly started PowerShell that loads the profile. It builds the child `Path` from the persistent machine and user `Path` values. It removes every occurrence of the directories the profile restores. This lets the check detect a profile that omits a required directory. The hosted tests explicitly supply the directory that contains their Oh My Posh executable to the probe.

In phase 2, the fresh process checks that the managed profile body completed
and that it added the managed directories. The smoke fixtures reject a profile
that returns before the managed line and a profile that signals completion
without adding the required paths. Phase 4 also verifies that the fresh profile
resolves the selected mise commands and the Go and uv commands from their shared
manifests. The first result for each bare command name must be the expected
application.

### First-run backup

Hook 10 keeps the Unix contract for file content: before the first apply overwrites a target, copy each pre-existing managed file and symlink target into a timestamped backup directory, and fail visibly on any error. The Unix hook also keeps file mode and times with `cp -p`; on Windows, keep the last-write time and do not claim to keep ACLs.

- List the managed files and symlinks with the same chezmoi executable, config, source, and destination as the running apply, as the Unix hook does. Give the listing its own temporary persistent state, pass `--format=`, and delete the temporary state in `finally`. Capture stdout and stderr separately, so an error message never becomes a backup path. Check the exit code before reading the list.
- With the chezmoi version inspected for this design, ordinary local-drive paths use forward slashes and a drive letter, for example `C:/Users/Example/.ssh/config`. chezmoi also recognizes UNC paths; this design rejects UNC and device paths with a clear error.
- Backup root: `oh-my-devenv\chezmoi-first-run-backup` under the effective LocalApplicationData folder. Resolve the folder through the known-folder API, and fail when the result is empty. XDG stays Unix-only.
- The backup helpers take the backup root as an explicit parameter. Production passes the LocalApplicationData path; every test passes a directory inside its fixture root, so a test never writes the runner account's real backup root.
- Map each path to `drives\<drive letter>\<rest of the path>` under the run directory, so the colon disappears and different drives do not collide. Verify that the mapped path stays inside the run directory.
- Create the run directory only when a file needs a copy. Never reuse an earlier run directory.
- Skip only confirmed missing files and confirmed dangling links, and log each skipped dangling link. Treat access errors, unreadable metadata, link loops, and unsupported path kinds as failures. Do not infer absence from a false existence check.
- Copy file content with `Copy-Item -LiteralPath` to a new regular file. In the inspected PowerShell 7.6 implementation, copying a local file symlink copies the target content, like `cp -L`. Fail on a directory or a link to a directory; do not copy recursively.
- Read back each copy: compare its length and content hash with the source. The hash comparison detects most changes during the copy, but the backup is not an atomic snapshot.
- On any listing, mapping, copy, or readback error, report the source and destination and exit nonzero before chezmoi writes the targets. Keep partial backups for inspection.
- Print the completed backup directory, or report that no copy was needed. The uninstall keeps the backups.
- After removing the managed configuration, uninstall resets the apply configuration's `scriptState` and `entryState` buckets. The next apply runs hook 10 again. The uninstall preview lists both buckets.
- A backup can contain secrets. Like the Unix hook, the backup does not check or change permissions.

Tests:

- Pester fixtures for the path mapper and the backup helper: spaces, Unicode, wildcard characters, several drive letters, regular files, file symlinks, dangling links, directory links, denied reads and writes, failed and empty listings, path containment, and run-directory collisions. Run them under the selected PowerShell and chezmoi versions before phase 2 is accepted.
- A disposable Windows apply in which the backup copy fails on purpose. It expects a nonzero exit and an unchanged old target.

### Windows details in the helpers

- A uv tool environment keeps its interpreter at `Scripts\python.exe`, not `bin/python`.
- Executables have an `.exe` suffix. The shadow check that compares the resolved command with the installer-owned binary includes the suffix.
- The checker reads the Go command import path and module version with `go version -m` and the uv package version with `uv tool list`. It checks the uv tool interpreter against its recorded version and the mise-selected Python.
- The Unix helpers run global mise commands from `/`, so the project config of the caller's working directory does not apply. The PowerShell helpers run them from the root of the system drive (`$env:SystemDrive\`) for the same reason. mise searches for project config from the current directory up to the drive root, so a temporary directory under the user profile does not isolate the commands: a config file in a parent directory still applies. A config file in the root directory itself still applies, on Unix and on Windows. The user-global config, by default `%USERPROFILE%\.config\mise\config.toml`, applies independently of that search. On Unix the default system config directory `/etc/mise` is absolute; on Windows it resolves on the drive of the current directory, so running from the system drive root selects `\etc\mise` on that drive.

## 8. Shared Data

The soft consistency rule from section 2 works like this:

| Data | Windows behavior |
| --- | --- |
| `dot_config/mise/config.toml.tmpl` | Same target and same versions. mise reads its global config from `%USERPROFILE%\.config\mise` on Windows. When a tool does not work on Windows, exclude it in the template with a `.chezmoi.os` condition. |
| `ecosystem/go-tools.txt`, `ecosystem/uv-tools.txt` | The Windows installers read the same files with the same parsing rules. |
| `dot_gitconfig.tmpl` | Same template. Add Windows-only settings in a Windows branch when a concrete need appears. `check.ps1` requires Git's global configuration paths to include the managed `.gitconfig`. |
| `private_dot_ssh/private_config.tmpl` | Same template. The Windows branch leaves out `ControlMaster`, `ControlPath`, and `ControlPersist`. Windows OpenSSH parses them, but its connection multiplexing functions are empty stubs, and the Unix `ControlPath` contains a `:`, which is not valid in a Windows file name. Keep `Include`, `IdentitiesOnly`, `TCPKeepAlive`, `ServerAliveInterval`, and `SendEnv`. Windows OpenSSH checks the owner and ACL of the config files and fails on unsafe ones. chezmoi does not turn `private_` into a Windows ACL. `check.ps1` reads back the path and version of the `ssh` executable it uses, and checks that the managed file exists at that executable's default user config path. It then runs `ssh -v -G` with a test host name and no `-F`, checks the exit code, and checks that the debug output contains a `Reading configuration data` line for the managed file. A setting value in the output does not prove its source, because defaults and other config files can supply the same value. OpenSSH 10.5p1 on macOS prints that debug line; the phase-2 native fixture confirms it on Windows. The inspected source skips the owner and ACL check for a top-level file given with `-F`, and ignores a missing default config file. Local drop-ins are optional; the check covers the drop-ins that exist. Do not rewrite ACLs automatically. These statements come from the public Win32-OpenSSH 9.5p1 and 10.4 sources. The actual Windows `ssh` executable and its version can differ, for example one from Git for Windows, so phase 2 confirms them with native fixtures in an isolated home: an unsafe top-level ACL and an unsafe drop-in ACL must fail. |
| `desktop/maple-mono-nf-cn.env` | Same font facts, including the pinned URL and SHA-256 digest. Parse the quoted values explicitly. |
| System packages | Platform-specific by nature. Windows gets its own winget manifest. |

Do not design a per-entry platform marker for the ecosystem manifests now. Add one only when a concrete entry fails on Windows. Then design the smallest marker for that case and update every reader of the manifest in the same change, as `AGENTS.md` requires.

Two parsers, one in Bash and one in PowerShell, read each shared manifest. The Pester tests reuse the test cases that the Unix smoke suite already uses for these parsers. A change to a manifest format updates both parsers and both sets of test cases in the same change.

## 9. Configuration Targets

### PowerShell profile

Use the current-user, all-hosts profile, `$PROFILE.CurrentUserAllHosts`. Without redirection, its path is `Documents\PowerShell\profile.ps1` in the user's home directory. PowerShell 7 hosts that load the standard profiles read this file. This includes the VS Code PowerShell extension while its `powershell.enableProfileLoading` setting is on, which is the default. Profile loading can be turned off, for example with `pwsh -NoProfile`, or blocked by the execution policy. Writing this current-user file normally needs no elevation. The plain `$PROFILE` value is the current-user, current-host profile: it depends on the host that resolves it, and other hosts do not load it.

The profile path depends on the Documents known folder. OneDrive folder redirection can move that folder, and so can a user who changes the Documents location. A source-tree name such as `Documents/PowerShell/...` maps to one fixed target path, so it does not follow the redirection.

chezmoi could compute the target path from config data through `.chezmoiexternal`. Claude chose a stub instead, because PowerShell itself resolves the profile path and the stub needs no extra config data.

- chezmoi deploys the profile body to `~/.config/oh-my-devenv/powershell/profile.ps1`.
- Hook 15 runs after chezmoi updates the targets, on every apply. It resolves `$PROFILE.CurrentUserAllHosts`, creates the file when it is missing, keeps any existing content, and adds the managed line when it is not present. The profile is outside the managed-path backup of hook 10. Before hook 15 adds the line to an existing profile, it copies the profile into a new directory under the backup root and reads the copy back, as hook 10 does. Any copy or readback error stops the hook before it edits the profile. Hook 15 then appends to the file and keeps the existing bytes. It adds a line break first when the file does not end with one. A file with a UTF-16 BOM gets the line in UTF-16. A file with a UTF-8 BOM or with no BOM gets the line in UTF-8. The hook stops when a file without a BOM is not valid UTF-8. A file without a BOM can be valid in several encodings, so the hook treats such a file as UTF-8 and relies on the pre-edit copy for recovery. On an append error, the hook reports the profile and backup paths. Hook 15 runs after chezmoi writes the targets, so its failure does not undo them. Fixture tests cover each supported encoding, a file without a final line break, a failed copy, a failed append, and a byte-level comparison of the kept content. It never adds the line twice. Running on every apply repairs a deleted line and follows a moved Documents folder.
- The managed line loads the body only when the body file exists, so a removed body does not break PowerShell startup.
- The profile helper takes the profile path as an explicit parameter. Production passes `$PROFILE.CurrentUserAllHosts`; tests pass a path inside the fixture, so a test never writes the real profile of the runner user.
- `check.ps1` fails when the file at `$PROFILE.CurrentUserAllHosts` does not contain the managed line.

The body mirrors the Unix env templates where they apply on Windows:

- Default `GOPATH` to `~/go`. Default `GOBIN` to the `bin` directory under the first semicolon-separated `GOPATH` entry.
- Prepend the mise shims directory, `~/.local/bin`, and `$GOBIN` to `PATH`.
- Set `BAT_THEME` to the same value as the Unix env templates.
- Activate mise with `(&mise activate pwsh) | Out-String | Invoke-Expression`, only when `mise` is on `PATH`. The Unix rc files guard activation in the same way.
- After mise activation, resolve the first `oh-my-posh` application on `PATH`. When it exists, initialize it with the managed `~/.config/oh-my-devenv/powershell/robbyrussell.omp.json`. This local theme follows the Unix `robbyrussell` profile. The theme and its MIT notice are from [Oh My Posh v33.0.0](https://github.com/JanDeDobbeleer/oh-my-posh/tree/v33.0.0).
- The theme disables automatic upgrades and upgrade notices. It also enables `async` so Oh My Posh disables upgrade features even when its device cache enables them. The profile uses `init pwsh`. Oh My Posh registers its PowerShell prompt during startup and loads the rendering module on the first prompt draw. The theme loads from disk. Its path and Git segments use local state. [Feature selection](https://github.com/JanDeDobbeleer/oh-my-posh/blob/v33.0.0/src/config/config.go#L144-L191), [PowerShell init generator](https://github.com/JanDeDobbeleer/oh-my-posh/blob/v33.0.0/src/shell/init.go#L47-L76).
- A script host with redirected console input or output skips prompt initialization. It still loads the rest of the profile and the local overlay. The checker explicitly enables prompt initialization in its fresh PowerShell process so it can verify the same init path.
- The init script exports the resolved `POSH_CONFIG` and a `POSH_SESSION_ID`. After the generated script installs the prompt function, the profile records that config path before the overlay runs. The checker clears inherited values in its fresh PowerShell process and requires that recorded path to match the deployed theme. [Session variables](https://github.com/JanDeDobbeleer/oh-my-posh/blob/v33.0.0/src/shell/init.go#L315-L326), [deferred prompt](https://github.com/JanDeDobbeleer/oh-my-posh/blob/v33.0.0/src/shell/init.go#L270-L290).
- Load the local overlay at `~/.config/oh-my-devenv/powershell/profile.local.ps1` when it exists. It can override the prompt.
- After the optional overlay, prepend any missing managed directories, including the effective `GOBIN`, on every profile load. Preserve the existing `PATH` order and entries.

The profile affects PowerShell sessions only. Applications started from the Windows shell, such as an IDE launched from the Start menu, do not load it. The persistent user `Path` entries cover these applications (section 7).

### Windows Terminal

The baseline does not own Windows Terminal's `settings.json`, so the settings that the user changes in the Terminal UI stay under user control. The baseline deploys a JSON fragment instead.

- Location: `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\oh-my-devenv\`. This is the documented per-user fragment location. The folder is outside Documents, so Documents redirection does not move it.
- The source path `AppData/Local/...` maps to the chezmoi destination. With the desktop baseline enabled, hook 00 compares that path with the effective LocalAppData known folder before chezmoi writes the fragment. Hook 22 and `check.ps1` use the same check.
- A fragment can add profiles and color schemes, and it can update the built-in and dynamic profiles. It cannot change global settings.
- The fragment uses `profiles[].updates` with the preferred dynamic PowerShell profile GUID `{574e775e-4f2a-5b96-ac1e-a2962a402336}`. It sets `font.face` from the `desktop-font-family` partial. [Fragment format](https://learn.microsoft.com/en-us/windows/terminal/json-fragment-extensions), [PowerShell profile generator](https://github.com/microsoft/terminal/blob/main/src/cascadia/TerminalSettingsModel/PowershellCoreProfileGenerator.cpp), [Font settings](https://learn.microsoft.com/en-us/windows/terminal/customize-settings/profile-appearance#font-face).
- Deploy the fragment only when `desktopBaseline` is true.

### XDG

The XDG root check in hook 00 stays Unix-only. Windows does not export `XDG_*` variables. Windows targets use `~/.config` as a literal path, which matches the mise default on Windows.

### Line endings

Add a `.gitattributes` file with `* text=auto eol=lf` in phase 2, and list it in `.chezmoiignore`. A Windows checkout then keeps LF line endings, so the Bash scripts stay valid when the repository is edited on Windows, and the hook hashes match the Unix checkouts. PowerShell 7 runs `.ps1` files with LF line endings.

The file is required, not optional. The Git for Windows installer sets `core.autocrlf=true` in the system Git config by default. Without a repository LF rule, an effective `core.autocrlf=true` can check out text sources with CRLF line endings. chezmoi can preserve those endings in managed output; templates can also generate LF line endings.

## 10. System Packages

Use `winget import` with a JSON file in the format that `winget export` produces.

- Use the [WinGet 2.0 export schema](https://github.com/microsoft/winget-cli/blob/master/schemas/JSON/packages/packages.schema.2.0.json) with the built-in `winget` source. Validate its name, type, and identifier. Set `Scope` to `user` on each entry and omit `Version`.
- Run the import without interactive prompts and accept the agreements on the command line.
- Pass `--no-upgrade`. Hook 20 ensures that each package is present; upgrades stay a separate user action (`winget upgrade`). An installer upgrade can need elevation or a restart, which a hook must not trigger. The Arch Linux path also leaves a full upgrade to the user.
- Hook 20 fails when WinGet is missing, the source cannot be opened, or an install fails. The error identifies the source and manifest entries and includes the WinGet diagnostic. Device policy can block the source or installation. Use the existing source and contact the device administrator if policy blocks it.
- `check.ps1` exports the installed inventory with `winget export --source winget`. It compares complete package IDs in the JSON from the built-in source against the manifest. It reports all absent IDs and includes the native diagnostic if export fails. [WinGet export](https://learn.microsoft.com/en-us/windows/package-manager/winget/export).

The [system manifest](../../bootstrap/manifests/system/winget-packages.json) holds the approved list.

| Package ID | Installer |
| --- | --- |
| `Git.Git` | User-scope Inno |
| `GitHub.cli` | Portable in a ZIP archive |
| `BurntSushi.ripgrep.MSVC` | Portable in a ZIP archive |
| `jqlang.jq` | Portable |
| `JanDeDobbeleer.OhMyPosh` | MSIX, declared as `appx` in the [catalog](https://github.com/microsoft/winget-pkgs/blob/master/manifests/j/JanDeDobbeleer/OhMyPosh/33.0.0/JanDeDobbeleer.OhMyPosh.installer.yaml) |

WinGet applies the manifest's user scope to the Oh My Posh MSIX.
[Installer type mapping](https://github.com/microsoft/winget-cli/blob/v1.11.510/src/AppInstallerCommonCore/Manifest/ManifestCommon.cpp#L144-L151),
[scope filter](https://github.com/microsoft/winget-cli/blob/v1.11.510/src/AppInstallerCommonCore/Manifest/ManifestComparator.cpp#L469-L484).

| Excluded or deferred tools | Reason |
| --- | --- |
| `fd`, `bat`, `fzf` | `Get-ChildItem` and `Get-Content` cover routine file lookup and reading. PowerShell filtering covers routine selection. |
| `yq`, `shellcheck`, `shfmt` | YAML editing and Unix shell maintenance have limited use in this Windows baseline. |
| Everything | Fast NTFS indexing under a standard account uses a service that requires administrator rights to install. [Everything Service](https://www.voidtools.com/support/everything/everything_service/) |
| 7-Zip | Windows 11 24H2 extracts ordinary 7z and RAR archives in File Explorer. [Microsoft Support](https://support.microsoft.com/en-gb/windows/experience/storage-filemanagement/zip-and-unzip-files) |
| DevToys | The current DevToys app catalog entry is a 2.0 preview. [WinGet catalog](https://github.com/microsoft/winget-pkgs/tree/master/manifests/d/DevToys-app/DevToys) |
| `gsudo` | Elevation is outside the baseline. |
| `zoxide`, `lazygit`, `delta` | Discuss separately in the mise layer. |
| `curl`, `wget`, `tree`, `zip`, `unzip` | Windows supplies `curl.exe` and built-in directory and archive tools. |
| `ca-certificates`, `bash-completion`, `zsh` | These Unix packages do not apply to the Windows baseline. |
| `direnv` | It evaluates `.envrc` in Bash. [Upstream implementation](https://github.com/direnv/direnv#how-it-works) |
| Native toolchain, multiplexer, `gnupg`, `pinentry` | Decide after the Windows tool inventory. |

## 11. Desktop Baseline

On Windows, the desktop baseline includes PowerToys, Maple Mono NF CN, and the Windows Terminal fragment.

- Hook 22 imports the [desktop manifest](../../bootstrap/manifests/desktop/winget-packages.json) when `desktopBaseline` is enabled. `Microsoft.PowerToys` has a user-scope Burn installer. The hook uses the same import flags, source checks, and failure handling as hook 20. The checker uses one export to verify the complete IDs of both enabled layers. [PowerToys catalog manifest](https://github.com/microsoft/winget-pkgs/blob/master/manifests/m/Microsoft/PowerToys/0.102.3101/Microsoft.PowerToys.installer.yaml).

- Hook 22 reads the URL, digest, family, and required faces from `maple-mono-nf-cn.env`. It validates the archive digest before extracting the required TrueType files and keeps files whose bytes already match.
- Copy the files to `%LOCALAPPDATA%\Microsoft\Windows\Fonts`. Register each full file path as a string value under `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts`. This persists the fonts for the current user. If the fonts are unavailable in the current session, sign out and back in. [Microsoft's font installer implementation](https://github.com/microsoft/winget-cli/blob/master/src/AppInstallerCommonCore/Fonts.cpp), [FontLab's per-user registry implementation](https://github.com/fontlaborg/fontlift-win-cli/blob/main/src/sys_utils.cpp).
- With `desktopBaseline` enabled, hooks 00 and 22 and the checker require the destination's `AppData/Local` to match the effective LocalAppData. They also require Windows Terminal discoverable as `wt.exe` or `WindowsTerminal.exe` on `PATH`. Windows 11 normally provides Terminal. An installation with its alias disabled must expose its executable on `PATH`.
- The checker requires every face's file and registration. It parses the deployed JSON and verifies that the fragment sets the manifest family on the PowerShell 7 profile.
- When `desktopBaseline` is false or omitted, the fragment template renders empty and chezmoi removes that file on apply. Phase-3 uninstall also removes the managed fragment. Package and font removal belong to phase 5. [Chezmoi template behavior](https://www.chezmoi.io/reference/templates/).

## 12. Local Overlays

These existing overlays also apply on Windows: `gitconfig`, `git_hooks`, `ssh_config`, `npmrc`, and `mise`.

These overlays do not apply on Windows: `env`, `bootstrap_env`, `secrets`, `zshrc`, `bashrc`, and `ghostty`.

Add one Windows overlay, `profile.local.ps1` (section 9), in phase 2 together with the profile that loads it. Add it to `local-overlays.tsv` and `docs/local-overlay-examples/`, and update every reader of `local-overlays.tsv` in the same change.

## 13. Validation

- Unix smoke tests:
  - Render the ignore rules with Windows chezmoi data and assert that no `.sh` hook and no Unix-only target is managed. Render with macOS and Linux data and assert that no `.ps1` hook and no Windows-only target is managed.
  - Render the shared Git and SSH targets across platforms. Parse the rendered Terminal fragment. Check the desktop hook gate and fragment removal when the desktop option is disabled or omitted.
- Windows smoke job on a hosted Windows runner:
  - Lint the PowerShell code with PSScriptAnalyzer.
  - Run the Pester tests for the helpers, including the shared-manifest test cases.
  - Apply and reapply the main source in a temporary home with WinGet, mise, Go, and uv stubs. Use a fixture profile path and registry key. Check uninstall with the same key. Test the desktop installer separately with stubbed downloads and isolated font and registry targets.
- The hosted Windows apply job requires WinGet and Terminal. It runs the real WinGet import, desktop hook, and checker. The hosted Windows Server stalls when launching the registered Oh My Posh MSIX. The fixture copies the installed executable to a temporary directory and uses that copy for the real prompt probe. Launch through the Windows app execution alias still needs a Windows client signoff. The job restores the font files and registry values after testing.
- The phase-4 apply job runs the real WinGet, mise, Go, and uv paths. It checks
  the first apply, unchanged reapply, and ownership-based uninstall. It
  restores the original runner user `Path` bytes and registry type and removes
  the test ownership record. The job logs requested and installed versions for
  each mise tool, identified path-length errors, and the longest path found
  under the mise data and uv tool directories.
- A coverage gap in real installation requires live signoff before merge. Section 17 records hosted coverage. The user scheduled the first live apply after all planned phases.
- Run both Windows jobs under the same `needs-checks` condition as the Unix jobs, and feed them into the existing single required check. This avoids a second path classifier that could skip Windows CI after a change to a shared file.
- Live installs on a real Windows machine follow the same local validation policy as the Unix platforms.

## 14. Phases

| Phase | Scope | Exit criterion |
| --- | --- | --- |
| 1 | Windows tool inventory (user) | The user confirms the starting lists in sections 10 and 8, or changes them. This can run in parallel with phase 2. |
| 2 | Configuration only: platform dispatch, `.gitattributes`, hooks 00, 10, 15, and 60, PowerShell profile and its overlay, shared Git, SSH, and mise targets, minimal uninstall (remove the managed profile line and the managed targets), Windows smoke and apply jobs, repository rules | An apply on Windows deploys the configuration, and `check.ps1` passes for the delivered layers. Unix output does not change. |
| 3 | System packages and the desktop baseline | Hooks 20 and 22 install their manifests, and `check.ps1` checks them. |
| 4 | mise, runtimes, and ecosystem tools, and the persistent user `Path` entries | Hooks 30, 40, and 50 install the shared inventories. Hook 15 adds the user `Path` entries, and the uninstall removes them. `check.ps1` checks them. |
| 5 | Full lifecycle and PowerShell completions | The Windows uninstall covers every layer. Feature parity with the Unix lifecycle, apart from the non-goals. |

`check.ps1` checks only the layers that the current phase delivers. Each phase adds the checks for its layers.

## 15. Alternatives Considered

| Alternative | Result | Reason |
| --- | --- | --- |
| Separate repository | Rejected (user decision) | The shared data would exist twice and drift. |
| Reuse the Bash scripts through Git Bash or MSYS2 | Rejected | Paths, permissions, and package management differ. The result is fragile and still needs a Windows package layer. |
| Gate hooks with an OS condition inside each template | Rejected | It edits every Unix hook template. `.chezmoiignore` gates hooks in one place. |
| Scoop instead of winget | Rejected for the baseline | The package layer uses the built-in winget source and stops when device policy blocks it. |
| `winget configure` with a DSC file | Rejected for now | It adds a second configuration system. `winget import` covers the need. |
| Move cross-platform CLIs from the system layer to mise on every platform | Deferred | It would improve consistency, but it changes the Unix design. Evaluate it separately. |
| Copy the Windows Terminal fragment from hook 22 instead of deploying it as a target | Rejected | chezmoi then no longer tracks or removes the file, and the check and uninstall need their own logic for it. Allowing one exception in the dot-path assertion is smaller. |
| Shared fixture files for the Bash and PowerShell parsers | Rejected | The rules are small. Reusing the existing test cases in Pester is simpler. |

## 16. Review History

| Round | Reviewer | Result |
| --- | --- | --- |
| Fact-check 1–4 | Codex `gpt-6.1-sol` | All findings applied: execution policy in phase 2, existing-profile handling, scope of the chezmoi target-path claim, tmux rationale, target paths in ignore rules, conditional profile loading, the rendered-hash rationale for the hook gate, a clean child environment for the profile check, the LocalAppData location check. |
| Design review | Gemini 4 Argon | Adopted: ignore-based hook gate, hook `PATH` rebuild, the profile-repair requirement (Claude took the every-apply trigger from Kimi), `--no-upgrade`, `.gitattributes` in phase 2, per-phase `check.ps1`, Go and mise paths in the profile, overlay in phase 2, Windows helper details, multi-platform render of the Git and SSH templates, prompt text, Pester test cases, one `needs-checks` condition. Not adopted: copying the fragment from a hook; moving the CLIs to mise (kept as deferred). Left for the user: persisting `Path` for applications outside PowerShell. The user decided to persist it on 2026-11-21 (section 7). |
| Design review | Kimi K3.1 Pro | Adopted: narrowed isolation goal, `winget` check moved to hook 20, guarded mise activation, every-apply profile hook, `GOBIN` on `PATH`, test-only profile path, real Windows apply job and minimal uninstall in phase 2, Windows Terminal presence check. |
| Device probe | The user | The user ran a read-only probe on a Windows machine on 2026-11-21. Claude used the results for general findings only: the `core.autocrlf` reason for `.gitattributes`, the need to check execution policy under PowerShell 7, and the long-path question. The probe results are not part of the repository. |

The review files are not part of the repository.

## 17. Open Questions

The first hosted Windows smoke job ran PowerShell 7.6.10. Its effective
execution policy was `RemoteSigned` from `LocalMachine`. On that runner,
chezmoi rendered `.chezmoi.homeDir` and `.chezmoi.destDir` with forward slashes
and `joinPath` with backslashes. Neither Windows job in that run reached apply.
[Hosted run 44885242196](https://github.com/kangmingxuan/oh-my-devenv/actions/runs/44885242196)

The second hosted Windows apply job confirmed the Git include. Native Git
reported `C:\Users\runneradmin\.config\oh-my-devenv\git\config` as the origin
and returned the fixture value `loaded`. Windows OpenSSH 9.5p2 read the managed
default configuration and rejected unsafe ACLs on the top-level configuration
and a local drop-in. These results apply to the tools on that runner.
[Hosted apply job 136793367571](https://github.com/kangmingxuan/oh-my-devenv/actions/runs/44886671628/job/136793367571)

Sections 2, 9, 10, and 11 record the approved phase-3 baseline and its verification rules.

The hosted phase-3 run on `905d27a` passed all jobs. Windows smoke passed 74 Pester tests and skipped one. Windows apply completed the user-scope WinGet imports, including PowerToys. It verified the managed prompt using a copy of the installed Oh My Posh executable. A separate plain `pwsh -File` loaded the profile and overlay and exited. The first apply and Oh My Posh app execution alias check on a user device remain pending. [Full CI run](https://github.com/kangmingxuan/oh-my-devenv/actions/runs/44912366118), [Windows smoke](https://github.com/kangmingxuan/oh-my-devenv/actions/runs/44912366118/job/136870704931), [Windows apply](https://github.com/kangmingxuan/oh-my-devenv/actions/runs/44912366118/job/136870704962).

The hosted phase-4 run on `edde9e9` passed all jobs. WinGet installed mise
2026.11.12 on the x64 runner. mise installed all six shared tools: Go 1.27.1,
golangci-lint v2.14.0, Node 24.21.0, Python 3.13.16, usage 6.12.0, and uv 0.11.33.
The longest observed paths were 165 characters under the mise data directory
and 203 under the uv tools directory. The install log showed no path-length
error. [Full CI run](RUN_LINK), [Windows smoke](SMOKE_LINK), [Windows apply](APPLY_LINK).

A clean standard-user Windows client remains unverified. The WinGet mise
package requires the architecture-matched Microsoft Visual C++ 2015+
Redistributable at machine scope. If it is missing, ask the device
administrator to provision it before apply.

Resolve each remaining item before the phase that depends on it.

| Item | Phase |
| --- | --- |
| Whether the effective script execution policy lets chezmoi run the `.ps1` hooks, and the stop condition when it does not. Do not work around device policy. PowerShell 7 stores execution-policy settings separately from Windows PowerShell 5.1. Group Policy can make it use the Windows PowerShell policy settings, so check the effective policy under `pwsh`. | 2 |
| First apply on a clean standard-user Windows client with the prerequisite described in section 7. | 4 |

## 18. Sources

- chezmoi `.ps1` interpreter default and fallback: <https://www.chezmoi.io/reference/configuration-file/interpreters/>
- chezmoi scripts and their `run_`, `run_once_`, `run_onchange_`, and `after_` attributes: <https://www.chezmoi.io/user-guide/use-scripts-to-perform-actions/>
- chezmoi `.chezmoiignore`: <https://www.chezmoi.io/reference/special-files/chezmoiignore/>
- chezmoi `.chezmoiexternal` with `targetPath`: <https://www.chezmoi.io/reference/special-files/chezmoiexternal-format/>
- mise directories on Windows: <https://mise.jdx.dev/directories.html>
- mise installation on Windows: <https://mise.jdx.dev/installing-mise.html>
- mise activation in PowerShell: <https://mise.jdx.dev/shell-setup.html>
- `winget import`: <https://learn.microsoft.com/en-us/windows/package-manager/winget/import>
- Windows Terminal JSON fragments: <https://learn.microsoft.com/en-us/windows/terminal/json-fragment-extensions>
- PowerShell profile types and locations: <https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_profiles>
- PowerShell execution policies: <https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies>
- PowerShell support lifecycle: <https://learn.microsoft.com/en-us/powershell/scripting/install/powershell-support-lifecycle>
- Installing PowerShell with winget: <https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows#install-powershell-using-winget>
- Win32-OpenSSH project scope: <https://github.com/PowerShell/Win32-OpenSSH/wiki/Project-Scope>
- Win32-OpenSSH multiplexing stubs: <https://github.com/PowerShell/openssh-portable/blob/274893f8d1fe86c4d128b514c3af4bc10cdc0c99/contrib/win32/win32compat/no-ops.c>
- chezmoi on Windows: <https://www.chezmoi.io/user-guide/machines/windows/>
