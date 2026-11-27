# Windows developer setup

These are optional native Windows developer setup steps.

## Git SSH on Windows

The baseline leaves Git's SSH client selection to Git and your settings. The
Windows checker reports the SSH executable it finds on `PATH` and checks
that the executable reads the managed SSH config. Inspect Git separately from
the repository and shell where you use it. Choose a remote that uses SSH.

```powershell
git remote get-url origin
git config --show-origin --show-scope --get core.sshCommand
git config --show-origin --show-scope --get ssh.variant
Get-Item Env:GIT_SSH_COMMAND, Env:GIT_SSH, Env:GIT_SSH_VARIANT -ErrorAction SilentlyContinue
Get-Command ssh -All
```

Git tries `GIT_SSH_COMMAND` first, then the effective `core.sshCommand`, then
`GIT_SSH`, then its default `ssh`. `GIT_SSH_VARIANT` overrides `ssh.variant`
when Git selects arguments for the client. From a temporary PowerShell session
in the same repository, set `$env:GIT_TRACE = '1'` and run
`git ls-remote origin`. Read the trace entry for the SSH command.
[Git SSH selection](https://raw.githubusercontent.com/git/git/master/connect.c),
[Git configuration](https://git-scm.com/docs/git-config#Documentation/git-config.txt-coresshCommand),
[Git tracing](https://git-scm.com/docs/git#Documentation/git.txt-GITTRACE)

If you want Git to use Windows OpenSSH, run the following in native
PowerShell. It writes a shell-quoted absolute command with forward slashes
to the user-owned [Git include](local-overlay-examples/README.md#git-configuration-and-hooks).

```powershell
$openSsh = Join-Path $env:SystemRoot 'System32/OpenSSH'
$ssh = Join-Path $openSsh 'ssh.exe'
if (-not (Test-Path -LiteralPath $ssh -PathType Leaf)) {
    throw "Windows OpenSSH client not found at $ssh."
}
$gitInclude = Join-Path $HOME '.config/oh-my-devenv/git/config'
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $gitInclude))
$sshCommand = "'" + $ssh.Replace('\', '/').Replace("'", "'\''") + "'"
git config --file $gitInclude core.sshCommand $sshCommand
if ($LASTEXITCODE -ne 0) {
    throw "Could not set core.sshCommand in $gitInclude."
}
```

Enabling and starting the Windows `ssh-agent` service is an administrator step
outside the baseline. If you use that agent, run `Get-Service ssh-agent` and
`& (Join-Path $env:SystemRoot 'System32/OpenSSH/ssh-add.exe') -l` to check the service and list its
loaded keys. Use that same `ssh-add.exe` with your private key path to load
a key. The Windows and Git for Windows clients can use different agents.
The managed SSH config sets `IdentitiesOnly yes`. For a key with a custom
filename, set `IdentityFile` in the host's local SSH config drop-in.
Rerun the Git trace and confirm that `git ls-remote` succeeds against your
SSH remote.
[Windows OpenSSH key management](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement),
[Git for Windows agent differences](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent?platform=windows),
[OpenSSH identity selection](https://man.openbsd.org/ssh_config#IdentitiesOnly)

## Native build prerequisites

Install native build tools when a project requires them. An administrator
must install Visual Studio Build Tools. The VC++ Redistributable supplies
runtime libraries. Build Tools provides the compiler and SDK components.
[Visual Studio installation permissions](https://learn.microsoft.com/en-us/visualstudio/install/install-visual-studio)

| Build | What to check |
| --- | --- |
| Python native extension | If no Windows wheel matches your Python version, ABI, and architecture, check the package's source-build instructions. A native CPython extension can require MSVC and a Windows SDK. A pure-Python source distribution can build without a C compiler. [Python extension builds](https://docs.python.org/3/extending/windows.html) |
| Node add-on using node-gyp | Use a supported Python version and the Visual Studio Desktop development with C++ workload. Run `node -p process.arch` to check the running Node architecture. A native ARM64 target also needs the ARM64 C++ compiler and libraries and ARM64 ATL. [node-gyp Windows requirements](https://github.com/nodejs/node-gyp#on-windows) |
| Go package using cgo | Run `go env GOOS GOARCH CGO_ENABLED CC`. Use a GCC/MinGW-w64 or Clang toolchain that meets the Go release's compiler requirements for the target. MSVC's `cl.exe` cannot serve as cgo's C compiler. [Go cgo documentation](https://pkg.go.dev/cmd/cgo), [Go compiler requirements](https://go.dev/wiki/MinimumRequirements#cgo) |

For an MSVC build, use the Visual Studio Installer copy of `vswhere.exe` to
look for the target compiler component. Run the line for the target you need.

```powershell
$vswhere = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw "Visual Studio Installer's vswhere.exe was not found."
}
# x64 target
& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
# ARM64 target
& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath
```

A path identifies an instance with that component. If the query succeeds and
prints no path, it found no matching instance. Verify the SDK and any extra
components with a project build in the developer shell for the target.
[vswhere location](https://github.com/microsoft/vswhere/wiki/Installing),
[vswhere compiler query](https://github.com/microsoft/vswhere/wiki/Find-VC),
[Build Tools component IDs](https://learn.microsoft.com/en-us/visualstudio/install/workload-component-id-vs-build-tools)

## Dev Drive caches

If you already have a writable Dev Drive, choose a separate absolute cache
directory per tool on that drive. The baseline leaves drive provisioning to
you. For uv, put the cache on the same filesystem as the Python environments
that use it so uv can link files. Across volumes, uv falls back to copying.
[Dev Drive](https://learn.microsoft.com/en-us/windows/dev-drive/),
[uv cache placement](https://docs.astral.sh/uv/concepts/cache/#cache-directory)

Choose the scope before you set the variables.

- **PowerShell and its children.** Set the variables in
  `~/.config/oh-my-devenv/powershell/profile.local.ps1`, for example
  `$env:UV_CACHE_DIR = 'D:\dev-cache\uv'`. The overlay runs after
  `mise activate`, so a `MISE_CACHE_DIR` assignment there applies to
  later mise invocations in that session. The hooks run with `-NoProfile`.
  They can inherit the launching process's variables.
- **Applications launched independently.** Set Windows user environment
  variables to cover PowerShell startup, hooks launched outside the profile,
  and IDEs. For example, run
  `[Environment]::SetEnvironmentVariable('UV_CACHE_DIR', 'D:\dev-cache\uv', 'User')`.
  Substitute your own path. Sign out and back in if a running launcher
  continues to pass the old environment.
  [Windows environment scopes](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_environment_variables)

Run each readback in the shell or application that will use the cache.

| Cache | Environment variable | Readback |
| --- | --- | --- |
| [mise cache](https://mise.jdx.dev/directories.html) | `MISE_CACHE_DIR` | `mise cache path` |
| [uv package cache](https://docs.astral.sh/uv/concepts/cache/) | `UV_CACHE_DIR` | `uv cache dir` |
| [Go module cache](https://pkg.go.dev/cmd/go#hdr-Environment_variables) | `GOMODCACHE` | `go env GOMODCACHE` |
| [Go build cache](https://pkg.go.dev/cmd/go#hdr-Environment_variables) | `GOCACHE` | `go env GOCACHE` |
| [npm cache](https://docs.npmjs.com/cli/v11/using-npm/config/#cache) | `npm_config_cache` | `npm config get cache` |

Leave `MISE_DATA_DIR`, `MISE_INSTALLS_DIR`, the mise shim directory,
`GOPATH`, `GOBIN`, `UV_TOOL_DIR`, and `UV_TOOL_BIN_DIR` outside this
cache setup. The baseline tracks its managed user `Path` entries for mise
shims, the Go binary directory, and `~/.local/bin`, the default for Windows
uv tool executables. Moving installed tool data or executables can disrupt
those entries or the tools they resolve.
[uv executable directories](https://docs.astral.sh/uv/reference/storage/#executable-directory)

