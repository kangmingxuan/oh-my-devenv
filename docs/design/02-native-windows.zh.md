# 技术设计：原生 Windows 平台

状态：已接受。阶段 2（仅配置）已实现，阶段 3–5 尚未开始。

## 1. 概要

在本仓库中把原生 Windows 加为第四个平台。Windows 是精简平台：它与 macOS 和 Linux 共享基线数据，但不复刻 Unix shell 层。

- 所有平台使用同一个 chezmoi source。
- Windows 默认与 Unix 平台共享运行时、生态工具和 Git 数据。
- Windows hook 和辅助脚本用 PowerShell 7 实现。
- Windows 系统包用 winget 安装。
- 用 PowerShell profile 代替 Zsh 和 Bash。
- 桌面基线中用 Windows Terminal 代替 Ghostty。

WSL 不属于本设计。WSL 是 Linux 环境，继续走现有的 Linux 路径。

## 2. 决策与归属

除另有日期说明外，以下决策由用户于 2026-11-20 做出：

| 决策 | 说明 |
| --- | --- |
| 支持原生 Windows | 工作环境依赖原生 Windows，仅靠 WSL 不能满足需求。 |
| 使用当前仓库 | 不另开仓库。 |
| 平台保持一致，作为软规则 | Windows 默认使用相同的版本和工具清单。某个工具在 Windows 上不可用时，允许 Windows 例外。 |
| Windows 定位为通用开发环境基线 | Windows 内容保持公开、通用。雇主特定的内容不进入本仓库。 |
| Windows 工具盘点延后 | 用户尚未收集完整的 Windows 日常工具。以 macOS 和 Linux 基线为起点。 |
| 使用当前用户、所有宿主的 PowerShell profile | 由 Claude 提出，用户批准。 |
| 请 Gemini 4 Argon 和 Kimi K3.1 Pro 做设计评审 | 用户要求 Claude 把这两份评审与 Codex 的事实核查一起权衡。 |
| 把受管目录持久化写入用户 `Path` | 用户于 2026-11-21 做出这一决定，让 PowerShell 之外启动的应用也能找到受管工具。Claude 在第 7 节设计了具体机制。 |

本文其余决策均由 Claude 在上述范围内提出。第 16 节列出 Claude 采纳了哪些评审意见。每一项决策在实现前都等待用户审阅。

## 3. 目标与非目标

### 目标

- 在受支持的 Windows 机器上，`chezmoi init --apply` 部署 Windows 配置并运行 Windows hook。
- Windows hook 安装系统包、mise、运行时和生态工具，最后执行环境检查。
- 重复运行 `chezmoi apply` 是安全的。
- Windows 专属的目标和 hook 不会在 macOS 或 Linux 上部署、运行，也不会改变那里的渲染内容；Unix 专属的目标和 hook 也不会在 Windows 上部署或运行。由测试守住这条边界。
- 共享数据的改动（例如 mise 配置中的某个版本）可以让所有平台重跑 hook。这正是共享的预期效果。

### 非目标

- 在 Windows 上使用 Bash、Zsh 或 oh-my-zsh，包括把 Git Bash、MSYS2、Cygwin 作为本仓库 Bash 脚本的运行环境。
- 第一版不提供 Windows 的 shell 补全资产。
- Windows 上的 Ghostty 和 OrbStack。
- WSL 本身、Docker 或容器运行时的安装配置。
- Windows PowerShell 5.1。
- 需要管理员提权的 hook。优先使用用户级安装。
- 雇主特定的工具、feed、凭据或设备策略的绕行方案。

## 4. 仓库布局

```text
.gitattributes                         # 新增；source 使用 LF 换行
.chezmoiscripts/
├── run_..._NN-<name>.sh.tmpl          # Unix hook，不变
└── run_..._NN-<name>.ps1.tmpl         # 新增；Windows hook
bootstrap/
├── manifests/
│   ├── system/winget-packages.json    # 新增；Windows 系统包
│   ├── ecosystem/*.txt                # 共享，格式不变
│   └── desktop/maple-mono-nf-cn.env   # 共享的字体信息
├── scripts/                           # Unix Bash 辅助脚本，不变
└── windows/                           # 新增；PowerShell 辅助脚本与测试
dot_config/
├── mise/config.toml.tmpl              # 共享目标
└── oh-my-devenv/powershell/           # 新增；PowerShell profile 主体
AppData/Local/Microsoft/Windows Terminal/Fragments/oh-my-devenv/  # 新增；仅桌面基线
```

规则：

- 所有 PowerShell 辅助脚本放在 `bootstrap/windows/` 下。
- Bash 辅助脚本不调用 PowerShell 辅助脚本，PowerShell 辅助脚本也不调用 Bash 辅助脚本。
- 新 manifest 放在现有的分层目录（`system/`、`desktop/`、`ecosystem/`）中，以保持跨平台设计的分层模型。
- `bootstrap/` 仍然只存在于 source 中。现有的 `.chezmoiignore` 规则已经覆盖 `bootstrap/windows/`。
- Windows Terminal fragment 是唯一一个不在 home 目录下 dot 路径中的目标。smoke suite 断言每个受管目标都是 dot 路径。扩展这条断言，仅在 Windows 上放行这一个 fragment 目录，其他情况保持严格。

## 5. 平台分派

平台判断放在 Unix 平台已在使用的同一组位置：

- `.chezmoi.os` 为 `windows` 时，`.chezmoitemplates/system-package-manager` 返回 `winget`。
- `.chezmoitemplates/desktop-platform-supported` 在 Windows 上返回 `true`。
- `.chezmoi.toml.tmpl` 在 Windows 上把桌面基线提示的默认值设为是，提示文字写明 Windows 上的内容：Windows Terminal 设置和 Maple Mono NF CN。

hook 和部署文件都通过 `.chezmoiignore` 做门控：

- ignore 规则写成相对于 home 目录的目标路径，而不是 source 路径。脚本的目标名会去掉 `run_` 属性和 `.tmpl` 后缀，所以 `.chezmoiscripts/*.ps1` 能匹配所有 Windows hook。Claude 用 chezmoi v2.73.2 在一个临时 fixture 上确认了这条规则。
- 在 Windows 上，忽略 `.chezmoiscripts/*.sh` 和 Unix 专属目标：Zsh 和 Bash 文件、`.local/share/oh-my-devenv/xdg.sh`、Fontconfig 和 Ghostty。
- 在 Windows 之外，忽略 `.chezmoiscripts/*.ps1` 和 Windows 专属目标：PowerShell profile 主体和 Windows Terminal fragment。
- 不为这个门控修改现有的 Unix hook 模板。`.chezmoiignore` 把门控集中在一处，而不是分散在十个模板里。chezmoi 对渲染后的脚本计算哈希，所以外包条件只有在改变渲染结果时才会让 Unix hook 重跑；但每个被修改的模板都是门控可能产生偏差的地方。

## 6. Hook 对应关系

沿用 Unix hook 编号，使各层在所有平台上的顺序一致。

| 编号 | Unix hook | Windows hook | 阶段 |
| --- | --- | --- | --- |
| 00 | Banner 与 XDG 根目录检查 | `run_before_`：banner；解释器不是 PowerShell 7.6 或更高版本时失败 | 2 |
| 10 | 前置条件与首次运行备份 | `run_once_before_`：检查 `git`，首次运行备份 | 2 |
| 15 | — | `run_after_`，每次 apply：确保 profile 中有 dot-source 行（第 9 节，阶段 2），并确保持久化用户 `Path` 中有受管条目（第 7 节，阶段 4） | 2 |
| 20 | 系统包 | 检查 `winget`，然后从 `winget-packages.json` 执行 `winget import` | 3 |
| 22 | 桌面资产 | 检查 Windows Terminal，然后把 Maple Mono NF CN 装到用户字体目录 | 3 |
| 25 | oh-my-zsh 资产 | 无 | — |
| 30 | 安装 mise | `mise` 不在 `PATH` 上时，用 winget 安装 mise | 4 |
| 40 | 运行时 | `mise install` | 4 |
| 50 | 生态工具 | 按共享 manifest 安装 Go 和 uv 工具 | 4 |
| 55 | Shell 补全 | 第一版无 | 5 |
| 60 | 环境检查 | `check.ps1` | 2 |

哈希触发方式与 Unix 相同。每个 Windows `run_onchange_` hook 都包含其 manifest 和辅助脚本的哈希。

hook 30 使用 winget，让 mise 与其他系统工具来自同一个包管理器，这与 macOS 上的 Homebrew 路线一致。mise 文档推荐的是它自己的 PowerShell 安装脚本：winget 上的版本可能滞后，而且 mise 对 winget 安装会关闭 `mise self-update`。用 `winget upgrade jdx.mise` 升级 mise。与 Unix hook 一样，`mise` 已在 `PATH` 上时，hook 30 跳过安装。

## 7. PowerShell 规则

- 在第一次 `chezmoi init --apply` 之前，要求 PowerShell 7.6 或更高版本与 `git`、`chezmoi` 一起作为前置条件。7.6 是当前的 LTS 分支。PowerShell 支持生命周期表给出的支持结束日期是 2028-11-14，7.4 和 7.5 是 2026-11-10。Microsoft Lifecycle 目录显示的日期各晚一天；本设计采用较早的日期。本设计用到的所有 PowerShell 功能在 7.6 中都有。
- 快速开始用 `winget install --id Microsoft.PowerShell --exact --source winget` 安装 PowerShell。在使用不受限 winget 源的全新客户端上，省略 `--version` 会选择最高的适用版本，它可能是非 LTS 版本。已有安装和源策略可能改变结果或导致安装失败。检查过的 winget 目录中没有单独的 LTS 包 ID。
- Windows hook 和辅助脚本只面向 PowerShell 7.6 或更高版本编写。
- 理由：chezmoi 用 `pwsh` 运行 `.ps1` 脚本，`pwsh` 不可用时回退到 Windows PowerShell。在首次 apply 中安装 `pwsh` 的 hook 帮不了同一次 apply 中后续的 hook，因为正在运行的 chezmoi 进程保留原来的 `PATH`。设一个前置条件，比让每个 hook 都兼容 5.1 更简单。
- 正在运行的 PowerShell 版本低于 7.6 时，hook 00 失败。这只是兼容性下限；hook 00 不检查支持状态。与其他前置条件一样，由用户让 PowerShell 保持在受支持的版本并装上最新的服务更新。把最低版本写进 `AGENTS.md`，与 Bash 3.2 规则并列。
- 每个脚本以 `Set-StrictMode -Version Latest` 和 `$ErrorActionPreference = 'Stop'` 开头。
- 检查每个原生命令的退出码。默认情况下，原生命令失败时 `$ErrorActionPreference` 不会中止执行。

### hook 中的环境

在 chezmoi 进程中运行的每个 hook，都继承 chezmoi 启动时的 `PATH`。安装器修改持久化的用户或机器 `Path`，不会改变这个进程环境。因此，一个共享辅助函数在每个 hook 开始时构建 hook 环境：

1. 读取当前的机器 `Path` 和用户 `Path`。
2. 把受管目录放到最前面：`%LOCALAPPDATA%\mise` 下的 mise shims 目录、`~/.local/bin` 和 `$GOBIN`。
3. 把 `GOPATH` 和 `GOBIN` 设为与 Unix env 模板相同的默认值（`~/go` 和 `$GOPATH/bin`）。

### 持久化用户 Path

用户决定把受管目录加入持久化的用户 `Path`（第 2 节）。从 Windows shell 启动的应用（例如从开始菜单启动的 IDE）不会加载 PowerShell profile。持久化条目让这些应用也能找到受管工具。

- hook 15 在每次 apply 时，把 mise shims 目录、`~/.local/bin` 和 `$GOBIN` 加入 `HKCU\Environment` 中的用户 `Path`。这从阶段 4 开始，因为这些目录中的工具在阶段 4 才安装。
- 只添加缺失的条目。绝不重复添加同一条目。保留其他所有条目及其顺序。
- 写入解析后的目录路径。不要新增 `%GOBIN%` 引用，因为 `GOBIN` 不持久化。
- 把基线实际添加的每个条目记录到 oh-my-devenv 数据目录下的一个状态文件中。重复 apply 保留这份记录。首次 apply 前已存在的条目不记录，也不受管。
- 保留注册表值的类型和未展开的条目，例如 `%USERPROFILE%` 引用。不要把展开后的值写回。
- 通知正在运行的应用环境已变更。已经在运行、且不处理该通知的应用，要重启后才能看到变更。
- 不修改机器 `Path`，因为它需要提权。
- 不持久化 `GOPATH` 或 `GOBIN`，因为它们的值与 Go 的默认值相同。
- 卸载只移除已记录的条目。保留首次 apply 前已存在的同路径条目，以及所有其他条目。卸载不恢复整个 `Path` 的旧快照。
- 用户 `Path` 缺少上述三个必需目录中的任意一个时，`check.ps1` 失败，包括首次 apply 前已有条目所指的目录。归属记录只决定卸载可以移除哪些条目，不决定要检查哪些目录。
- `Path` 的写入、读取和卸载辅助函数把注册表目标作为显式参数。smoke test 传入 fixture 目标并模拟变更通知，因为临时 home 不会隔离 `HKCU`。真实 apply job 检查并恢复 runner 账户的用户 `Path`。
- profile 保留自己的 `PATH` 设置。它决定 PowerShell 会话中的顺序，且不依赖持久化条目。

`check.ps1` 还通过一个新启动、会加载 profile 的 PowerShell 检查命令解析。子进程会继承父进程的环境，所以检查从不含 hook 附加项的机器与用户环境构建子进程环境。在加载 profile 前，检查从合并后的子进程 `Path` 中移除受管目录的每一次出现，包括来自机器 `Path` 的条目。检查不修改持久化值。否则，hook 环境或已有条目可能掩盖 profile 没有把某个工具加入 `PATH` 的问题。一个负向测试从 fixture profile 中去掉一个必需路径，并期望检查失败。第二个负向测试通过 fixture 机器 `Path` 提供同一目录。

在阶段 2，新进程检查受管 profile 主体是否运行完毕，以及它是否加入了受管目录。
smoke fixture 要求两种情况报错：profile 在受管行之前返回，或者报告运行完毕却没有加入必需路径。

### 首次运行备份

hook 10 在文件内容上沿用 Unix 的约定：首次 apply 覆盖目标之前，把每个已存在的受管文件和符号链接目标复制到带时间戳的备份目录；任何错误都要明确失败。Unix hook 还用 `cp -p` 保留文件模式和时间；在 Windows 上保留最后写入时间，但不声称保留 ACL。

- 与 Unix hook 一样，用正在运行的 apply 所用的同一个 chezmoi 可执行文件、配置、源目录和目标目录列出受管文件和符号链接。列表命令使用独立的临时持久化状态，传入 `--format=`，并在 `finally` 中删除临时状态。分别捕获 stdout 和 stderr，使错误信息永远不会被当作备份路径。读取列表前先检查退出码。
- 在本设计检查过的 chezmoi 版本中，普通本地盘路径使用正斜杠和盘符，例如 `C:/Users/Example/.ssh/config`。chezmoi 也能识别 UNC 路径；本设计遇到 UNC 和设备路径时给出明确错误。
- 备份根目录：实际生效的 LocalApplicationData 文件夹下的 `oh-my-devenv\chezmoi-first-run-backup`。通过 known folder API 解析该文件夹，结果为空时失败。XDG 仍只用于 Unix。
- 备份辅助函数把备份根目录作为显式参数。生产环境传入 LocalApplicationData 路径；每个测试传入其 fixture 根目录下的目录，这样测试绝不会写入 runner 账户真实的备份根目录。
- 把每个路径映射为本次运行目录下的 `drives\<盘符>\<路径其余部分>`，这样冒号被去掉，不同盘符也不会冲突。验证映射后的路径仍在本次运行目录内。
- 只在确有文件需要复制时才创建本次运行目录。绝不复用之前的运行目录。
- 只跳过已确认不存在的文件和已确认悬空的链接，并为每个跳过的悬空链接记录日志。访问错误、无法读取的元数据、链接循环和不支持的路径类型都视为失败。不要从一次为假的存在性检查推断文件不存在。
- 用 `Copy-Item -LiteralPath` 把文件内容复制成一个新的普通文件。在检查过的 PowerShell 7.6 实现中，复制本地文件符号链接时复制的是目标内容，与 `cp -L` 相同。遇到目录或指向目录的链接时失败，不递归复制。
- 逐个回读副本：把长度和内容哈希与源文件比较。哈希比较能发现复制期间的大多数变化，但备份不是原子快照。
- 列表、映射、复制或回读出错时，报告源路径和目标路径，并在 chezmoi 写入目标之前以非零状态退出。保留部分完成的备份以便检查。
- 输出完成的备份目录，或报告无需复制。卸载保留这些备份。
- 移除受管配置后，卸载重置 apply 配置所用的 `scriptState` 和 `entryState`。下次 apply 会重新运行 hook 10。卸载预览会列出这两个状态桶。
- 备份中可能含有密钥。与 Unix hook 一样，备份不检查也不修改权限。

测试：

- 路径映射和备份辅助函数的 Pester fixture：空格、Unicode、通配符字符、多个盘符、普通文件、文件符号链接、悬空链接、目录链接、读写被拒、列表失败与为空、路径包含检查，以及运行目录冲突。阶段 2 验收前，在选定的 PowerShell 和 chezmoi 版本下运行这些测试。
- 一次可丢弃的 Windows apply，故意让备份复制失败。期望非零退出，且旧目标保持不变。

### 辅助脚本中的 Windows 细节

- uv 工具环境的解释器位于 `Scripts\python.exe`，而不是 `bin/python`。
- 可执行文件带 `.exe` 后缀。比较解析到的命令与安装器所属二进制的遮蔽检查要包含这个后缀。
- Unix 辅助脚本在 `/` 下运行全局 mise 命令，使调用方工作目录的项目配置不生效。PowerShell 辅助脚本出于同样的原因，在系统盘根目录（`$env:SystemDrive\`）下运行这些命令。mise 从当前目录向上查找项目配置，直到盘符根目录，所以用户 profile 下的临时目录不能隔离这些命令：父目录中的配置文件仍会生效。根目录本身的配置文件在 Unix 和 Windows 上都仍会生效。用户全局配置（默认是 `%USERPROFILE%\.config\mise\config.toml`）与这一查找无关，始终生效。Unix 上的默认系统配置目录 `/etc/mise` 是绝对路径；Windows 上它解析到当前目录所在的盘，所以在系统盘根目录下运行时，使用的是该盘上的 `\etc\mise`。

## 8. 共享数据

第 2 节中的软一致性规则按下表执行：

| 数据 | Windows 上的行为 |
| --- | --- |
| `dot_config/mise/config.toml.tmpl` | 目标相同，版本相同。mise 在 Windows 上从 `%USERPROFILE%\.config\mise` 读取全局配置。某个工具在 Windows 上不可用时，在模板中用 `.chezmoi.os` 条件把它排除。 |
| `ecosystem/go-tools.txt`、`ecosystem/uv-tools.txt` | Windows 安装器读取同一组文件，解析规则相同。 |
| `dot_gitconfig.tmpl` | 同一个模板。出现具体需求时，在 Windows 分支中加入 Windows 专属设置。`check.ps1` 要求 Git 的全局配置路径包含受管的 `.gitconfig`。 |
| `private_dot_ssh/private_config.tmpl` | 同一个模板。Windows 分支去掉 `ControlMaster`、`ControlPath` 和 `ControlPersist`。Windows OpenSSH 会解析它们，但它的连接复用函数是空实现，而且 Unix 的 `ControlPath` 含有 `:`，这在 Windows 文件名中无效。保留 `Include`、`IdentitiesOnly`、`TCPKeepAlive`、`ServerAliveInterval` 和 `SendEnv`。Windows OpenSSH 会检查配置文件的所有者和 ACL，不安全时失败。chezmoi 不会把 `private_` 转换成 Windows ACL。`check.ps1` 回读所用 `ssh` 可执行文件的路径和版本，并检查受管文件位于该可执行文件的默认用户配置路径。随后不带 `-F`、用一个测试主机名运行 `ssh -v -G`，检查退出码，并检查调试输出中有针对受管文件的 `Reading configuration data` 行。输出中的设置值不能证明其来源，因为默认值和其他配置文件也可能给出同样的值。macOS 上的 OpenSSH 10.5p1 会输出这一调试行；阶段 2 的原生 fixture 在 Windows 上确认这一点。检查过的源码中，用 `-F` 指定的顶层文件跳过所有者和 ACL 检查，默认配置文件缺失时也被忽略。本地 drop-in 是可选的；检查覆盖实际存在的 drop-in。不要自动改写 ACL。这些结论来自公开的 Win32-OpenSSH 9.5p1 和 10.4 源码。实际的 Windows `ssh` 可执行文件及其版本可能不同，例如来自 Git for Windows 的版本，所以阶段 2 在隔离的 home 中用原生 fixture 确认它们：不安全的顶层 ACL 和不安全的 drop-in ACL 都必须导致失败。 |
| `desktop/maple-mono-nf-cn.env` | 相同的字体信息，包括钉死的 URL 和 SHA-256 摘要。显式解析带引号的值。 |
| 系统包 | 本质上按平台区分。Windows 有自己的 winget manifest。 |

现在不为生态 manifest 设计逐条目的平台标记。只有某个具体条目在 Windows 上失败时才加。届时针对该情况设计最小的标记，并按 `AGENTS.md` 的要求，在同一次改动中更新该 manifest 的所有读取方。

每个共享 manifest 有两个解析器：一个 Bash，一个 PowerShell。Pester 测试复用 Unix smoke suite 中这些解析器已有的测试用例。manifest 格式变化时，在同一次改动中更新两个解析器和两组测试用例。

## 9. 配置目标

### PowerShell profile

使用当前用户、所有宿主的 profile，即 `$PROFILE.CurrentUserAllHosts`。没有重定向时，它的路径是用户 home 目录下的 `Documents\PowerShell\profile.ps1`。加载标准 profile 的 PowerShell 7 宿主会读取此文件。VS Code PowerShell 扩展的 `powershell.enableProfileLoading` 设置开启时（默认开启）也包括在内。profile 加载可以被关闭（例如 `pwsh -NoProfile`），也可能被执行策略阻止。写入这个当前用户文件通常不需要提权。`$PROFILE` 本身的值是当前用户、当前宿主的 profile：它取决于由哪个宿主解析，其他宿主不会加载它。

profile 路径取决于 Documents 已知文件夹。OneDrive 文件夹重定向可能把该文件夹移走，用户修改 Documents 的位置也会。`Documents/PowerShell/...` 这样的 source 树名称只映射到一个固定的目标路径，不会跟随重定向。

chezmoi 可以通过 `.chezmoiexternal` 用配置数据计算目标路径。Claude 选择了 stub，因为 profile 路径由 PowerShell 自己解析，stub 不需要额外的配置数据。

- chezmoi 把 profile 主体部署到 `~/.config/oh-my-devenv/powershell/profile.ps1`。
- hook 15 在 chezmoi 更新目标之后运行，每次 apply 都运行。它解析 `$PROFILE.CurrentUserAllHosts`，文件缺失时创建它，保留已有内容，受管行不存在时加入它。profile 不在 hook 10 的受管路径备份范围内。hook 15 向已有 profile 加入这一行之前，先把 profile 复制到备份根目录下的一个新目录，并像 hook 10 一样回读副本。复制或回读出错时，hook 在编辑 profile 之前停止。随后 hook 15 向文件追加内容，保留已有字节。文件末尾没有换行时，先加一个换行。带 UTF-16 BOM 的文件以 UTF-16 写入这一行。带 UTF-8 BOM 或没有 BOM 的文件以 UTF-8 写入。没有 BOM 的文件不是有效 UTF-8 时，hook 停止。没有 BOM 的文件可能同时符合多种编码，所以 hook 把这类文件当作 UTF-8 处理，并依靠编辑前的副本进行恢复。追加出错时，hook 报告 profile 和备份路径。hook 15 在 chezmoi 写入目标之后运行，所以它的失败不会撤销这些写入。fixture 测试覆盖每种支持的编码、末尾没有换行的文件、复制失败、追加失败，以及对保留内容的逐字节比较。这一行永远不会重复添加。每次 apply 都运行，就能修复被删除的行，也能跟随移动后的 Documents 文件夹。
- 受管行只在主体文件存在时才加载它，所以主体被删除时不会破坏 PowerShell 启动。
- profile 辅助函数把 profile 路径作为显式参数。生产环境传入 `$PROFILE.CurrentUserAllHosts`；测试传入 fixture 内的路径，因此测试永远不会写入 runner 用户的真实 profile。
- `$PROFILE.CurrentUserAllHosts` 所指的文件中没有受管行时，`check.ps1` 失败。

主体在适用于 Windows 的范围内对齐 Unix env 模板：

- `GOPATH` 默认为 `~/go`。`GOBIN` 默认为 `GOPATH` 中第一个分号分隔条目下的 `bin` 目录。
- 把 mise shims 目录、`~/.local/bin` 和 `$GOBIN` 放到 `PATH` 最前面。
- 把 `BAT_THEME` 设为与 Unix env 模板相同的值。
- 仅在 `mise` 位于 `PATH` 上时，用 `(&mise activate pwsh) | Out-String | Invoke-Expression` 激活 mise。Unix rc 文件也用同样方式保护激活。
- 本地 overlay `~/.config/oh-my-devenv/powershell/profile.local.ps1` 存在时加载它。
- 运行 overlay 后，把缺失的受管目录放到 `PATH` 最前面，包括实际生效的 `GOBIN`。保留 overlay 中已有的 `PATH` 条目及其顺序。

profile 只影响 PowerShell 会话。从 Windows shell 启动的应用（例如从开始菜单启动的 IDE）不会加载它。持久化的用户 `Path` 条目覆盖这些应用（第 7 节）。

### Windows Terminal

基线不管理 Windows Terminal 的 `settings.json`，使用户在 Terminal 界面中修改的设置仍由用户掌控。基线改为部署一个 JSON fragment。

- 位置：`%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\oh-my-devenv\`。这是文档给出的用户级 fragment 位置。该文件夹不在 Documents 下，Documents 重定向不会移动它。
- source 路径 `AppData/Local/...` 映射到 home 目录下默认的 LocalAppData 位置。LocalAppData 是已知文件夹，可能位于别处。hook 22 和 `check.ps1` 比较实际生效的 LocalAppData 路径与默认路径，不一致时带着清晰的"不受支持状态"信息失败。
- fragment 可以添加 profile 和配色方案，也可以更新内置 profile 和动态 profile，但不能修改全局设置。
- fragment 在 PowerShell 7 profile 上设置字体，字体名取自 `desktop-font-family` 局部模板。
- 仅在 `desktopBaseline` 为 true 时部署该 fragment。

### XDG

hook 00 的 XDG 根目录检查仍只用于 Unix。Windows 不导出 `XDG_*` 变量。Windows 目标直接使用字面路径 `~/.config`，这与 mise 在 Windows 上的默认值一致。

### 换行

在阶段 2 中添加 `.gitattributes`，内容为 `* text=auto eol=lf`，并把它列入 `.chezmoiignore`。这样 Windows checkout 也保持 LF 换行，在 Windows 上编辑本仓库时 Bash 脚本仍然有效，hook 哈希也与 Unix checkout 一致。PowerShell 7 可以运行 LF 换行的 `.ps1` 文件。

这个文件是必需的，不是可选项。Git for Windows 安装器默认在系统级 Git 配置中设置 `core.autocrlf=true`。没有仓库级 LF 规则时，实际生效的 `core.autocrlf=true` 可能以 CRLF 换行检出文本源文件。chezmoi 可能在受管输出中保留这些换行；模板也可能生成 LF 换行。

## 10. 系统包

使用 `winget import`，输入文件采用 `winget export` 产生的 JSON 格式。

- 每个条目都不写 `Version` 字段。Unix 系统 manifest 同样不钉版本。
- 导入时不出现交互提示，在命令行上接受各项协议。
- 传入 `--no-upgrade`。hook 20 只确保每个包存在；升级仍是用户单独执行的操作（`winget upgrade`）。安装器升级可能需要提权或重启，hook 不能触发这些。Arch Linux 路径同样把完整升级留给用户。
- `winget` 不可用或某个条目安装失败时，hook 20 带着清晰的错误失败。不传 `--ignore-unavailable`。

起始清单，从 Unix 系统 manifest 推导而来。阶段 3 中用 `winget show` 逐个核实包 ID。

| Unix 条目 | Windows 决定 |
| --- | --- |
| `git` | 纳入 |
| `curl` | 跳过；Windows 自带 `curl.exe` |
| `wget` | 跳过；使用 `curl.exe` |
| `ca-certificates`、`bash-completion`、`zsh` | 不适用 |
| `build-essential`、`pkg-config` | 跳过；盘点后再决定原生工具链 |
| `tmux` | 跳过；盘点后再决定原生终端复用器 |
| `jq`、`yq`、`ripgrep`、`fzf`、`fd`、`bat` | 纳入 |
| `direnv` | 核实其 PowerShell hook 后才纳入 |
| `tree`、`zip`、`unzip` | 跳过；Windows 有内置的对应功能 |
| `shellcheck`、`shfmt` | 纳入，以便在 Windows 上编辑本仓库 |
| `gnupg`、`pinentry-mac` | 盘点后再决定 |
| `gh` | 纳入 |

## 11. 桌面基线

在 Windows 上，桌面基线是 Maple Mono NF CN 字体和 Windows Terminal fragment。

- 按用户安装字体，不提权。从 `maple-mono-nf-cn.env` 读取 URL、摘要和必需字面。
- 安装前校验摘要，与 Linux 安装器一致。
- Windows Terminal 随 Windows 11 提供，所以基线不安装它。但它仍可能缺失，例如被策略移除。`desktopBaseline` 为 true 时，hook 22 和 `check.ps1` 检查 Windows Terminal 是否已安装；未安装时带着清晰的"不受支持状态"信息失败。
- 在 `check.ps1` 中检查已安装的字面。

## 12. 本地 Overlay

以下现有 overlay 在 Windows 上同样适用：`gitconfig`、`git_hooks`、`ssh_config`、`npmrc` 和 `mise`。

以下 overlay 在 Windows 上不适用：`env`、`bootstrap_env`、`secrets`、`zshrc`、`bashrc` 和 `ghostty`。

在阶段 2 中，随加载它的 profile 一起新增一个 Windows overlay：`profile.local.ps1`（第 9 节）。把它加入 `local-overlays.tsv` 和 `docs/local-overlay-examples/`，并在同一次改动中更新 `local-overlays.tsv` 的所有读取方。

## 13. 验证

- Unix smoke tests：
  - 用 Windows 的 chezmoi 数据渲染 ignore 规则，断言没有任何 `.sh` hook 和 Unix 专属目标受管；用 macOS 和 Linux 数据渲染，断言没有任何 `.ps1` hook 和 Windows 专属目标受管。
  - 在现有的多平台渲染循环中，为每个平台（包括 Windows）渲染 `dot_gitconfig.tmpl` 和 `private_dot_ssh/private_config.tmpl`。目前 suite 只为宿主平台渲染它们。
- 在托管 Windows runner 上运行 Windows smoke job：
  - 用 PSScriptAnalyzer 检查 PowerShell 代码。
  - 为辅助脚本运行 Pester 测试，包括共享 manifest 的测试用例。
  - 仿照 Unix smoke suite，用 stub 安装器把主 source apply 到临时 home。向 profile 辅助函数传入 fixture 中的 profile 路径（第 9 节）。
- Windows apply job：在托管 Windows runner 上做一次真实的往返（apply、reapply、uninstall、restore），与 Unix apply job 相同。阶段 2 覆盖配置；阶段 3 和 4 把它扩展到真实的包、运行时和工具安装。如果托管 runner 无法完成真实安装，记录这个覆盖缺口，并要求合并前在真实机器上完成实机签核。
- 两个 Windows job 都在与 Unix job 相同的 `needs-checks` 条件下运行，并汇入现有的单一 required check。这样不需要第二个路径分类器，避免共享文件改动后 Windows CI 被跳过。
- 在真实 Windows 机器上的实际安装，遵循与 Unix 平台相同的本地验证策略。

## 14. 阶段

| 阶段 | 范围 | 退出条件 |
| --- | --- | --- |
| 1 | Windows 工具盘点（用户） | 用户确认或修改第 10 节和第 8 节的起始清单。可与阶段 2 并行。 |
| 2 | 仅配置：平台分派，`.gitattributes`，hook 00、10、15、60，PowerShell profile 及其 overlay，共享的 Git、SSH、mise 目标，最小卸载（移除受管 profile 行和受管目标），Windows smoke 与 apply job，仓库规则 | 在 Windows 上 apply 能部署配置，`check.ps1` 对已交付的层通过；Unix 输出不变。 |
| 3 | 系统包与桌面基线 | hook 20 和 22 安装各自的 manifest，`check.ps1` 检查它们。 |
| 4 | mise、运行时与生态工具，以及持久化用户 `Path` 条目 | hook 30、40、50 安装共享清单。hook 15 添加用户 `Path` 条目，卸载移除它们。`check.ps1` 检查它们。 |
| 5 | 完整生命周期与 PowerShell 补全 | Windows 卸载覆盖所有层。除非目标外，与 Unix 生命周期功能对等。 |

`check.ps1` 只检查当前阶段已交付的层。每个阶段加入其各层的检查。

## 15. 考虑过的替代方案

| 方案 | 结论 | 理由 |
| --- | --- | --- |
| 单独的仓库 | 否决（用户决策） | 共享数据会存在两份并逐渐偏离。 |
| 通过 Git Bash 或 MSYS2 复用 Bash 脚本 | 否决 | 路径、权限和包管理都不同，结果脆弱，而且仍需要一个 Windows 包管理层。 |
| 在每个模板内用 OS 条件门控 hook | 否决 | 它要修改每个 Unix hook 模板。`.chezmoiignore` 在一处完成 hook 门控。 |
| 用 Scoop 代替 winget | 保留为后备 | winget 是 Windows 11 的一部分。Scoop 按用户安装、无需提权。设备策略阻止 winget 时它可能有用，前提是同一策略允许 Scoop 及其下载。 |
| 用 `winget configure` 和 DSC 文件 | 暂时否决 | 它引入第二套配置系统。`winget import` 已能满足需求。 |
| 在所有平台上把跨平台 CLI 从系统层移到 mise | 延后 | 能提升一致性，但会改变 Unix 设计。单独评估。 |
| 由 hook 22 复制 Windows Terminal fragment，而不是作为目标部署 | 否决 | 那样 chezmoi 不再跟踪或删除该文件，检查和卸载都要为它单独写逻辑。在 dot 路径断言中放行一个例外更小。 |
| 为 Bash 和 PowerShell 解析器共享 fixture 文件 | 否决 | 规则很小。在 Pester 中复用现有测试用例更简单。 |

## 16. 评审记录

| 轮次 | 评审者 | 结果 |
| --- | --- | --- |
| 事实核查 1–4 | Codex `gpt-6.1-sol` | 所有发现均已采纳：执行策略提前到阶段 2、已有 profile 的处理、chezmoi 目标路径说法的范围、tmux 的理由、ignore 规则使用目标路径、profile 加载是有条件的、hook 门控的渲染哈希理由、profile 检查使用干净的子进程环境、LocalAppData 位置检查。 |
| 设计评审 | Gemini 4 Argon | 采纳：基于 ignore 的 hook 门控、hook 中重建 `PATH`、profile 修复需求（Claude 采用了 Kimi 提出的每次 apply 触发方式）、`--no-upgrade`、阶段 2 加入 `.gitattributes`、按阶段的 `check.ps1`、profile 中的 Go 和 mise 路径、overlay 提前到阶段 2、Windows 辅助脚本细节、Git 和 SSH 模板的多平台渲染、提示文字、Pester 测试用例、统一的 `needs-checks` 条件。未采纳：由 hook 复制 fragment；把 CLI 移到 mise（保持延后）。留给用户决定：为 PowerShell 之外的应用持久化 `Path`。用户于 2026-11-21 决定持久化（第 7 节）。 |
| 设计评审 | Kimi K3.1 Pro | 采纳：收窄隔离目标、`winget` 检查移到 hook 20、受保护的 mise 激活、每次 apply 运行的 profile hook、`GOBIN` 加入 `PATH`、仅供测试的 profile 路径、阶段 2 加入真实的 Windows apply job 和最小卸载、Windows Terminal 存在性检查。 |
| 设备探测 | 用户 | 用户于 2026-11-21 在一台 Windows 机器上运行了只读探测。Claude 只把结果用于通用结论：`.gitattributes` 的 `core.autocrlf` 理由、需要在 PowerShell 7 下检查执行策略、长路径待决项。探测结果不进入仓库。 |

评审文件不属于本仓库。

## 17. 待决问题

首轮托管 Windows smoke job 使用 PowerShell 7.6.10。实际生效的执行策略是
`LocalMachine` 范围的 `RemoteSigned`。在该 runner 上，chezmoi 用正斜杠
呈现 `.chezmoi.homeDir` 和 `.chezmoi.destDir`，用反斜杠呈现 `joinPath` 的结果。
该轮的两个 Windows job 都未进入 apply。
[托管运行 44885242196](https://github.com/kangmingxuan/oh-my-devenv/actions/runs/44885242196)

第二轮托管 Windows apply job 确认了 Git include。原生 Git 读回的配置来源为
`C:\Users\runneradmin\.config\oh-my-devenv\git\config`，fixture 值为 `loaded`。
Windows OpenSSH 9.5p2 读取了受管的默认配置，并拒绝了顶层配置和本地 drop-in
上的不安全 ACL。这些结果适用于该 runner 上的工具。
[托管 apply job 136793367571](https://github.com/kangmingxuan/oh-my-devenv/actions/runs/44886671628/job/136793367571)

在依赖某一项的阶段开始前解决该项。

| 事项 | 阶段 |
| --- | --- |
| 实际生效的脚本执行策略是否允许 chezmoi 运行 `.ps1` hook，以及不允许时的停止条件。不绕过设备策略。PowerShell 7 与 Windows PowerShell 5.1 分开存储执行策略设置。组策略可以让它使用 Windows PowerShell 的策略设置，所以要在 `pwsh` 下检查实际生效的策略。 | 2 |
| `check.ps1` 如何检查 winget manifest：通过 winget 按包 ID 检查，还是按命令是否存在检查 | 3 |
| 每个纳入工具的 winget 包 ID，以及能否不提权安装 | 3 |
| Windows 上按用户安装字体的方法 | 3 |
| 设备策略限制 winget 源时的行为 | 3 |
| mise 配置中的每个工具能否在 Windows 上安装 | 4 |
| 运行时和工具安装是否会碰到 Windows 路径长度限制。不要假定 Windows 长路径支持（`LongPathsEnabled`）已开启；开启需要提权。仅有这个设置不能保证每个安装器或工具都支持长路径；要验证它们的实际行为。Git 另有独立的 `core.longpaths` 设置。 | 4 |

## 18. 来源

- chezmoi 中 `.ps1` 的默认解释器与回退：<https://www.chezmoi.io/reference/configuration-file/interpreters/>
- chezmoi 脚本及其 `run_`、`run_once_`、`run_onchange_`、`after_` 属性：<https://www.chezmoi.io/user-guide/use-scripts-to-perform-actions/>
- chezmoi `.chezmoiignore`：<https://www.chezmoi.io/reference/special-files/chezmoiignore/>
- chezmoi `.chezmoiexternal` 与 `targetPath`：<https://www.chezmoi.io/reference/special-files/chezmoiexternal-format/>
- mise 在 Windows 上的目录：<https://mise.jdx.dev/directories.html>
- mise 在 Windows 上的安装：<https://mise.jdx.dev/installing-mise.html>
- mise 在 PowerShell 中的激活：<https://mise.jdx.dev/shell-setup.html>
- `winget import`：<https://learn.microsoft.com/en-us/windows/package-manager/winget/import>
- Windows Terminal JSON fragment：<https://learn.microsoft.com/en-us/windows/terminal/json-fragment-extensions>
- PowerShell profile 类型与位置：<https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_profiles>
- PowerShell 执行策略：<https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies>
- PowerShell 支持生命周期：<https://learn.microsoft.com/en-us/powershell/scripting/install/powershell-support-lifecycle>
- 用 winget 安装 PowerShell：<https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows#install-powershell-using-winget>
- Win32-OpenSSH 项目范围：<https://github.com/PowerShell/Win32-OpenSSH/wiki/Project-Scope>
- Win32-OpenSSH 连接复用空实现：<https://github.com/PowerShell/openssh-portable/blob/274893f8d1fe86c4d128b514c3af4bc10cdc0c99/contrib/win32/win32compat/no-ops.c>
- chezmoi 在 Windows 上：<https://www.chezmoi.io/user-guide/machines/windows/>
