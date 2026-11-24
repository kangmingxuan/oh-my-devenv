# 技术设计：原生 Windows 平台

状态：已接受。阶段 3、阶段 4 和阶段 5 已通过托管 Windows smoke 和 apply 作业。首次实机验证中，解决 Delve 构建和 uv 索引问题后，apply 在一台 Windows ARM64 客户端上完成。测试账户属于 Administrators 组，以非提升权限运行（第 17 节）。第二次实机 apply 在一台已装有 mise 的 Windows 11 x64 客户端上于新开的终端中重跑完成；过期 `GOROOT` 导致的失败随后由 PR #79 修复。该账户同样属于 Administrators 组，以非提升权限运行。标准用户账户不在目标范围内，未经验证。在全新客户端上的首次 apply 仍待验证。

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
| 共享运行时和生态工具 | 用户于 2026-11-21 确认，Windows 使用共享的 mise 语言版本和生态工具清单。按工具在 Windows 上的实用性选定系统包。 |
| 默认安装 Oh My Posh | 用户于 2026-11-21 选用 Oh My Posh，作为 PowerShell 中对应 oh-my-zsh 的提示符工具。 |
| 批准 Windows 系统包清单 | 用户于 2026-11-21 批准第 10 节中 Claude 提出的五个系统包。Claude 选择了对 Windows 实用、运行良好且广泛使用的工具。 |
| Windows 定位为通用开发环境基线 | Windows 内容保持公开、通用。雇主特定的内容不进入本仓库。 |
| Windows 工具盘点延后 | 用户尚未收集完整的 Windows 日常工具。以已批准的 Windows 系统包清单为起点。 |
| 使用当前用户、所有宿主的 PowerShell profile | 由 Claude 提出，用户批准。 |
| 请 Gemini 4 Argon 和 Kimi K3.1 Pro 做设计评审 | 用户要求 Claude 把这两份评审与 Codex 的事实核查一起权衡。 |
| 把受管目录持久化写入用户 `Path` | 用户于 2026-11-21 做出这一决定，让 PowerShell 之外启动的应用也能找到受管工具。Claude 在第 7 节设计了具体机制。 |
| 以 Windows 默认账户为目标，不以标准用户账户为目标 | 用户于 2026-11-24 做出这一决定。用户和大多数同事使用 Windows 在以 Microsoft 账户首次登录时创建的账户。该账户属于 Administrators 组，以非提升权限运行。hook 仍在用户范围内安装，不请求提升权限。标准用户账户不在目标范围内，未经验证。 |

本文其余决策均由 Claude 在上述范围内提出。第 16 节列出 Claude 采纳了哪些评审意见。用户于 2026-11-21 批准阶段 3，并将首次 Windows 实机 apply 安排在所有计划阶段完成后。Claude 在授权范围内确定了阶段 3 的安装范围、安装与检查行为、设备策略处理、桌面安装与验证，以及卸载边界。

PR #66 合并后，用户于 2026-11-22 批准阶段 4。共享清单和持久化用户 `Path`
落实上表中的用户决策。Claude 在阶段 4 授权范围内确定了 WinGet 命令、运行时
hook 和哈希输入、共享工具的适用规则、生态安装器行为、用户 `Path` 归属、卸载、
检查器、路径长度诊断和托管 CI 测试（实施 brief 的第 1–9 项）。

PR #67 合并后，用户于 2026-11-22 批准阶段 5。Claude 在授权范围内确定了阶段 5
实施简报中的第 1–6 项决策，涵盖卸载范围、字体归属、hook 55、profile 加载、
检查器与卸载器的集成，以及 Windows CI 检查。

## 3. 目标与非目标

### 目标

- 在受支持的 Windows 机器上，`chezmoi init --apply` 部署 Windows 配置并运行 Windows hook。
- Windows hook 安装系统包、mise、运行时和生态工具，最后执行环境检查。
- 重复运行 `chezmoi apply` 是安全的。
- Windows 专属的目标和 hook 不会在 macOS 或 Linux 上部署、运行，也不会改变那里的渲染内容；Unix 专属的目标和 hook 也不会在 Windows 上部署或运行。由测试守住这条边界。
- 共享数据的改动（例如 mise 配置中的某个版本）可以让所有平台重跑 hook。这正是共享的预期效果。

### 非目标

- 在 Windows 上使用 Bash、Zsh 或 oh-my-zsh，包括把 Git Bash、MSYS2、Cygwin 作为本仓库 Bash 脚本的运行环境。
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
│   ├── desktop/winget-packages.json   # Windows 桌面包
│   └── desktop/maple-mono-nf-cn.env   # 共享的字体信息
├── scripts/                           # Unix Bash 辅助脚本，不变
└── windows/                           # 新增；PowerShell 辅助脚本与测试
dot_config/
├── mise/config.toml.tmpl              # 共享目标
└── oh-my-devenv/powershell/           # PowerShell profile、环境辅助脚本、补全加载器和主题
AppData/Local/Microsoft/Windows Terminal/Fragments/oh-my-devenv/  # 新增；仅桌面基线
```

规则：

- 引导阶段的 PowerShell 辅助脚本放在 `bootstrap/windows/` 下。profile 所需的辅助脚本与 profile 一起部署。
- Bash 辅助脚本不调用 PowerShell 辅助脚本，PowerShell 辅助脚本也不调用 Bash 辅助脚本。
- 新 manifest 放在现有的分层目录（`system/`、`desktop/`、`ecosystem/`）中，以保持跨平台设计的分层模型。
- `bootstrap/` 仍然只存在于 source 中。现有的 `.chezmoiignore` 规则已经覆盖 `bootstrap/windows/`。
- Windows Terminal fragment 是唯一一个不在 home 目录下 dot 路径中的目标。smoke suite 断言每个受管目标都是 dot 路径。扩展这条断言，仅在 Windows 上放行这一个 fragment 目录，其他情况保持严格。

## 5. 平台分派

平台判断放在 Unix 平台已在使用的同一组位置：

- `.chezmoi.os` 为 `windows` 时，`.chezmoitemplates/system-package-manager` 返回 `winget`。
- `.chezmoitemplates/desktop-platform-supported` 在 Windows 上返回 `true`。
- `.chezmoi.toml.tmpl` 在 Windows 上把桌面基线提示的默认值设为是，提示文字写明 Windows 上的内容：PowerToys、Windows Terminal 设置和 Maple Mono NF CN。

hook 和部署文件都通过 `.chezmoiignore` 做门控：

- ignore 规则写成相对于 home 目录的目标路径，而不是 source 路径。脚本的目标名会去掉 `run_` 属性和 `.tmpl` 后缀，所以 `.chezmoiscripts/*.ps1` 能匹配所有 Windows hook。Claude 用 chezmoi v2.73.2 在一个临时 fixture 上确认了这条规则。
- 在 Windows 上，忽略 `.chezmoiscripts/*.sh` 和 Unix 专属目标：Zsh 和 Bash 文件、`.local/share/oh-my-devenv/xdg.sh`、Fontconfig 和 Ghostty。
- 在 Windows 之外，忽略 `.chezmoiscripts/*.ps1` 和 Windows 专属目标：PowerShell profile、Oh My Posh 主题和 Windows Terminal fragment。
- 不为这个门控修改现有的 Unix hook 模板。`.chezmoiignore` 把门控集中在一处，而不是分散在十个模板里。chezmoi 对渲染后的脚本计算哈希，所以外包条件只有在改变渲染结果时才会让 Unix hook 重跑；但每个被修改的模板都是门控可能产生偏差的地方。

## 6. Hook 对应关系

沿用 Unix hook 编号，使各层在所有平台上的顺序一致。

| 编号 | Unix hook | Windows hook | 阶段 |
| --- | --- | --- | --- |
| 00 | Banner 与 XDG 根目录检查 | `run_before_`：banner；解释器不是 PowerShell 7.6 或更高版本时失败 | 2 |
| 10 | 前置条件与首次运行备份 | `run_once_before_`：检查 `git`，首次运行备份 | 2 |
| 15 | — | `run_after_`，每次 apply：确保 profile 中有 dot-source 行（第 9 节，阶段 2），并确保持久化用户 `Path` 中有受管条目（第 7 节，阶段 4） | 2 |
| 20 | 系统包 | 检查 `winget`，然后从 `winget-packages.json` 执行 `winget import` | 3 |
| 22 | 桌面资产 | 检查 Windows Terminal，导入桌面包，再把 Maple Mono NF CN 装到用户字体目录 | 3 |
| 25 | oh-my-zsh 资产 | 无 | — |
| 30 | 安装 mise | `mise` 不在 `PATH` 上时，用 winget 安装 mise | 4 |
| 40 | 运行时 | `mise install` | 4 |
| 50 | 生态工具 | 按共享 manifest 安装 Go 和 uv 工具 | 4 |
| 55 | Shell 补全 | `run_after_`，每次 apply。根据共享 shell 清单和当前 `PATH` 更新 PowerShell 补全。 | 5 |
| 60 | 环境检查 | `check.ps1` | 2 |

哈希触发方式与 Unix 相同。每个 Windows `run_onchange_` hook 都包含其 manifest 和辅助脚本的哈希。

hook 30 使用 winget，让 mise 与其他系统工具来自同一个包管理器，这与 macOS 上的 Homebrew 路线一致。mise 文档推荐的是它自己的 PowerShell 安装脚本：winget 上的版本可能滞后，而且 mise 对 winget 安装会关闭 `mise self-update`。用 `winget upgrade jdx.mise` 升级 mise。`mise` 已在 `PATH` 上时，hook 30 跳过安装。否则从 `winget` 源按精确 ID 以用户
范围安装 `jdx.mise`，刷新 hook 环境后确认 `mise --version`。WinGet 报错时，按
hook 20 的设备策略规则停止 apply。
[WinGet 包清单](https://github.com/microsoft/winget-pkgs/blob/master/manifests/j/jdx/mise/2026.11.12/jdx.mise.installer.yaml)

每次 apply 时，hook 55 读取共享的逐行命令清单
[`bootstrap/manifests/shell/completions.txt`](../../bootstrap/manifests/shell/completions.txt)。
安装器创建缺失的脚本，并替换输入指纹已变化的受管脚本。输入指纹涵盖共享清单、安装器及
辅助脚本、Windows 系统包清单、mise 配置，以及 Go 和 uv 清单。安装器将指纹写入每个
脚本的归属标记。对于仍在清单中且在 `PATH` 上可用的命令，指纹相同时保留受管文件，也跳过对应的生成器。
若 `PATH` 上的命令需要创建或替换补全脚本，优先使用上游安装位置
`%LOCALAPPDATA%\PowerShell\completions` 中现有的 PowerShell 补全。无现有脚本时，
使用该命令的生成器。安装和检查要求清单中的每个命令都有 PowerShell 生成器适配器。
已知命令的应用程序不在 `PATH` 上时，记录原因。
带归属标记的脚本存放在 `%LOCALAPPDATA%\oh-my-devenv\completions\powershell`。
命令从清单移除或在 `PATH` 上变为不可用时，安装器清除对应的受管脚本。
检查会报告缺失或过时的脚本。列表会为卸载返回所有受管脚本，包括过时条目。
[mise 补全配置](https://mise.jdx.dev/shell-setup.html#completions)

## 7. PowerShell 规则

- 在第一次 `chezmoi init --apply` 之前，要求 PowerShell 7.6 或更高版本与 `git`、`chezmoi` 一起作为前置条件。7.6 是当前的 LTS 分支。PowerShell 支持生命周期表给出的支持结束日期是 2028-11-14，7.4 和 7.5 是 2026-11-10。Microsoft Lifecycle 目录显示的日期各晚一天；本设计采用较早的日期。本设计用到的所有 PowerShell 功能在 7.6 中都有。
- 快速开始用 `winget install --id Microsoft.PowerShell --exact --source winget` 安装 PowerShell。在使用不受限 winget 源的全新客户端上，省略 `--version` 会选择最高的适用版本，它可能是非 LTS 版本。已有安装和源策略可能改变结果或导致安装失败。检查过的 winget 目录中没有单独的 LTS 包 ID。
- Windows hook 和辅助脚本只面向 PowerShell 7.6 或更高版本编写。
- 在 Windows 上，`.chezmoi.toml.tmpl` 将 `[interpreters.ps1]` 设为 `pwsh -NoLogo -NoProfile -File`。hook 独立于用户的 PowerShell profile 运行。hook 15 维护 profile 的受管行，hook 60 在单独的 shell 中验证启动。已有配置时，在 apply 前运行 `chezmoi init` 刷新配置。[chezmoi 解释器配置](https://www.chezmoi.io/reference/configuration-file/interpreters/)。
- 在启动 chezmoi 前安装 `pwsh`，让每个 hook 都能从初始 `PATH` 找到解释器。
- WinGet 的 `jdx.mise` 包需要与其架构（x64 或 ARM64）匹配的 Microsoft Visual C++ 2015+ Redistributable。该运行库在机器范围安装。设备缺少该运行库时，必须在 apply 前由管理员安装；hook 不请求提升权限。WinGet 失败时，hook 30 停止。
- 正在运行的 PowerShell 版本低于 7.6 时，hook 00 失败。这只是兼容性下限；hook 00 不检查支持状态。与其他前置条件一样，由用户让 PowerShell 保持在受支持的版本并装上最新的服务更新。把最低版本写进 `AGENTS.md`，与 Bash 3.2 规则并列。
- 每个脚本以 `Set-StrictMode -Version Latest` 和 `$ErrorActionPreference = 'Stop'` 开头。
- 检查每个原生命令的退出码。默认情况下，原生命令失败时 `$ErrorActionPreference` 不会中止执行。

### hook 中的环境

在 chezmoi 进程中运行的每个 hook，都继承 chezmoi 启动时的 `PATH`。安装器修改持久化的用户或机器 `Path`，不会改变这个进程环境。因此，一个共享辅助函数在每个 hook 开始时构建 hook 环境：

1. 读取当前的机器 `Path` 和用户 `Path`。
2. 把受管目录放到最前面：`%LOCALAPPDATA%\mise` 下的 mise shims 目录、`~/.local/bin` 和 `$GOBIN`。
3. 保留已有的 `GOPATH` 和 `GOBIN` 值。`GOPATH` 为空时设为 `~/go`。`GOBIN` 为空时设为第一个 `GOPATH` 条目下的 `bin` 目录。

阶段 3 的 hook 辅助函数合并进程、机器和当前用户的 `Path`。WinGet 把用户级便携包路径写入
`HKCU\Environment\Path`。支持符号链接时，使用
`%LOCALAPPDATA%\Microsoft\WinGet\Links`。否则 WinGet 可以加入包目录。
检查器在 hook 20 之后重读这些值。hook 30、40、50 和检查器也会把受管目录放到本进程的 `PATH` 前面。它们保留已有的 `GOPATH` 和 `GOBIN` 值，只在变量为空时设置默认值。
[WinGet 便携包安装器](https://github.com/microsoft/winget-cli/blob/master/src/AppInstallerCLICore/PortableInstaller.cpp)、
[WinGet Path 注册表实现](https://github.com/microsoft/winget-cli/blob/master/src/AppInstallerCommonCore/PathVariable.cpp)。

### 持久化用户 Path

用户决定把受管目录加入持久化的用户 `Path`（第 2 节）。从 Windows shell 启动的应用（例如从开始菜单启动的 IDE）不会加载 PowerShell profile。持久化条目让这些应用也能找到受管工具。

- hook 15 在每次 apply 时，把 mise shims 目录、`~/.local/bin` 和 `$GOBIN` 加入 `HKCU\Environment` 中的用户 `Path`。这从阶段 4 开始，因为这些目录中的工具在阶段 4 才安装。
- 只添加缺失的条目。绝不重复添加同一条目。保留其他所有条目及其顺序。
- 写入解析后的目录路径。不要新增 `%GOBIN%` 引用，因为 `GOBIN` 不持久化。
- 写入注册表前，把每个缺失条目记录到有效 LocalApplicationData 目录下的 `oh-my-devenv/user-path.json`。重复 apply 保留这份记录，并添加仍然缺失的条目。apply 时已存在的条目不会因此新增到记录中。如果用户 `Path` 中之后不再有该受管目录，下一次 apply 会添加它；如果记录中尚无该条目，也会记录它。
- 保留注册表值的类型和未展开的条目，例如 `%USERPROFILE%` 引用。不要把展开后的值写回。
- 注册表值变更时，广播带有 `Environment` 的 `WM_SETTINGCHANGE`。已经在运行、且不处理该通知的应用，要重启后才能看到变更。
- 不修改机器 `Path`，因为它需要提权。
- 不持久化 `GOPATH` 或 `GOBIN`，因为它们的值与 Go 的默认值相同。
- 卸载预览列出用户 `Path` 中仍存在的已记录条目。执行卸载时，每个记录只移除一条完全相同的条目，并删除记录文件。保留首次 apply 前已存在的同路径条目，以及所有其他条目。卸载不恢复整个 `Path` 的旧快照。
- 用户 `Path` 缺少上述三个必需目录中的任意一个时，`check.ps1` 失败，包括首次 apply 前已有条目所指的目录。归属记录只决定卸载可以移除哪些条目，不决定要检查哪些目录。
- `Path` 的写入、读取和卸载辅助函数把注册表目标作为显式参数。smoke test 传入 fixture 目标并模拟变更通知，因为临时 home 不会隔离 `HKCU`。真实 apply job 检查并恢复 runner 账户的用户 `Path`。
- profile 保留自己的 `PATH` 设置。它决定 PowerShell 会话中的顺序，且不依赖持久化条目。

`check.ps1` 通过一个新启动、会加载 profile 的 PowerShell 检查命令解析。它用持久化的机器和用户 `Path` 构建子进程的 `Path`。它移除 profile 会恢复的目录的所有条目，以便发现 profile 遗漏的必需目录。托管测试显式向探针传入 fixture 中 Oh My Posh 可执行文件所在的目录。

在阶段 2，新进程检查受管 profile 主体是否运行完毕，以及它是否加入了受管目录。
smoke fixture 要求两种情况报错：profile 在受管行之前返回，或者报告运行完毕却没有加入必需路径。
阶段 4 还通过新进程验证所选的 mise 命令，以及共享清单中的 Go 和 uv 命令。
按不带扩展名的命令名查找时，第一项结果必须是预期的应用程序。

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
- mise 管理的 Go 以 `GOARCH=arm64` 为目标时，Go 安装器只在安装 Delve 时给 `go install` 传入 `-tags=exp.winarm64`。Delve v1.27.2 只有加上这个实验性标签才能为 Windows ARM64 构建。构建此版本的 ARM64 Delve 时，显式标签会替换通过 `GOFLAGS` 设置的构建标签。其他工具保留原有的构建参数。首次实机 apply 在一台 ARM64 设备上于 hook 50 构建 Delve 时失败并停止，用户于 2026-11-22 选择了这个方案。托管 x64 smoke 测试覆盖参数构造。随后首次实机 apply 在原生 ARM64 上用该标签构建并安装了 Delve。托管 ARM64 apply job 也会构建它（第 13 节）。[Delve Windows 架构检查](https://github.com/go-delve/delve/blob/v1.27.2/pkg/proc/native/support_sentinel_windows.go)
- 可执行文件带 `.exe` 后缀。比较解析到的命令与安装器所属二进制的遮蔽检查要包含这个后缀。
- 检查器用 `go version -m` 读取 Go 命令导入路径和模块版本，用 `uv tool list` 读取 uv 包版本。检查 uv 工具的解释器是否与记录版本及 mise 选定的 Python 一致。
- Unix 辅助脚本在 `/` 下运行全局 mise 命令，使调用方工作目录的项目配置不生效。PowerShell 辅助脚本出于同样的原因，在系统盘根目录（`$env:SystemDrive\`）下运行这些命令。mise 从当前目录向上查找项目配置，直到盘符根目录，所以用户 profile 下的临时目录不能隔离这些命令：父目录中的配置文件仍会生效。根目录本身的配置文件在 Unix 和 Windows 上都仍会生效。用户全局配置（默认是 `%USERPROFILE%\.config\mise\config.toml`）与这一查找无关，始终生效。Unix 上的默认系统配置目录 `/etc/mise` 是绝对路径；Windows 上它解析到当前目录所在的盘，所以在系统盘根目录下运行时，使用的是该盘上的 `\etc\mise`。

## 8. 共享数据

第 2 节中的软一致性规则按下表执行：

| 数据 | Windows 上的行为 |
| --- | --- |
| `dot_config/mise/config.toml.tmpl` | 目标相同，版本相同。mise 在 Windows 上从 `%USERPROFILE%\.config\mise` 读取全局配置。某个工具在 Windows 上不可用时，在模板中用 `.chezmoi.os` 条件把它排除。 |
| `ecosystem/go-tools.txt`、`ecosystem/uv-tools.txt` | Windows 安装器读取同一组文件，解析规则相同。 |
| `shell/completions.txt` | hook 55 读取共享命令名。各平台自行解析对应的 shell 补全脚本和生成命令。 |
| `dot_gitconfig.tmpl` | 同一个模板。出现具体需求时，在 Windows 分支中加入 Windows 专属设置。`check.ps1` 要求 Git 的全局配置路径包含受管的 `.gitconfig`。 |
| `private_dot_ssh/private_config.tmpl` | 同一个模板。Windows 分支去掉 `ControlMaster`、`ControlPath` 和 `ControlPersist`。Windows OpenSSH 会解析它们，但它的连接复用函数是空实现，而且 Unix 的 `ControlPath` 含有 `:`，这在 Windows 文件名中无效。保留 `Include`、`IdentitiesOnly`、`TCPKeepAlive`、`ServerAliveInterval` 和 `SendEnv`。Windows OpenSSH 会检查配置文件的所有者和 ACL，不安全时失败。chezmoi 不会把 `private_` 转换成 Windows ACL。`check.ps1` 回读所用 `ssh` 可执行文件的路径和版本，并检查受管文件位于该可执行文件的默认用户配置路径。随后不带 `-F`、用一个测试主机名运行 `ssh -v -G`，检查退出码，并检查调试输出中有针对受管文件的 `Reading configuration data` 行。输出中的设置值不能证明其来源，因为默认值和其他配置文件也可能给出同样的值。macOS 上的 OpenSSH 10.5p1 会输出这一调试行；阶段 2 的原生 fixture 在 Windows 上确认这一点。检查过的源码中，用 `-F` 指定的顶层文件跳过所有者和 ACL 检查，默认配置文件缺失时也被忽略。本地 drop-in 是可选的；检查覆盖实际存在的 drop-in。不要自动改写 ACL。这些结论来自公开的 Win32-OpenSSH 9.5p1 和 10.4 源码。实际的 Windows `ssh` 可执行文件及其版本可能不同，例如来自 Git for Windows 的版本，所以阶段 2 在隔离的 home 中用原生 fixture 确认它们：不安全的顶层 ACL 和不安全的 drop-in ACL 都必须导致失败。 |
| `desktop/maple-mono-nf-cn.env` | 相同的字体信息，包括钉死的 URL 和 SHA-256 摘要。显式解析带引号的值。 |
| 系统包 | 本质上按平台区分。Windows 有自己的 winget manifest。 |

现在不为生态 manifest 设计逐条目的平台标记。只有某个具体条目在 Windows 上失败时才加。届时针对该情况设计最小的标记，并按 `AGENTS.md` 的要求，在同一次改动中更新该 manifest 的所有读取方。

每个共享 manifest 有两个解析器：一个 Bash，一个 PowerShell。Pester 测试复用 Unix smoke suite 中这些解析器已有的测试用例。manifest 格式变化时，在同一次改动中更新两个解析器和两组测试用例。

## 9. 配置目标

### PowerShell profile

使用当前用户、所有宿主的 profile，即 `$PROFILE.CurrentUserAllHosts`。没有重定向时，它的路径是用户 home 目录下的 `Documents\PowerShell\profile.ps1`。加载标准 profile 的 PowerShell 7 宿主会读取此文件。VS Code PowerShell 扩展的 `powershell.enableProfileLoading` 设置开启时（默认开启）也包括在内。profile 加载可以被关闭（例如 `pwsh -NoProfile`），也可能被执行策略阻止。写入这个当前用户文件通常不需要提权。`$PROFILE` 本身的值是当前用户、当前宿主的 profile：它取决于由哪个宿主解析，其他宿主不会加载它。

profile 路径取决于 Documents 已知文件夹。OneDrive 文件夹重定向可能把该文件夹移走，用户修改 Documents 的位置也会。`Documents/PowerShell/...` 这样的 source 树名称只映射到一个固定的目标路径，不会跟随重定向。重定向文件夹中的云文件占位符按普通文件处理。

chezmoi 可以通过 `.chezmoiexternal` 用配置数据计算目标路径。Claude 选择了 stub，因为 profile 路径由 PowerShell 自己解析，stub 不需要额外的配置数据。

- chezmoi 把 profile 主体部署到 `~/.config/oh-my-devenv/powershell/profile.ps1`。
- hook 15 在 chezmoi 更新目标之后运行，每次 apply 都运行。它解析 `$PROFILE.CurrentUserAllHosts`，文件缺失时创建它，保留已有内容，受管行不存在时加入它。profile 不在 hook 10 的受管路径备份范围内。hook 15 向已有 profile 加入这一行之前，先把 profile 复制到备份根目录下的一个新目录，并像 hook 10 一样回读副本。复制或回读出错时，hook 在编辑 profile 之前停止。随后 hook 15 向文件追加内容，保留已有字节。文件末尾没有换行时，先加一个换行。带 UTF-16 BOM 的文件以 UTF-16 写入这一行。带 UTF-8 BOM 或没有 BOM 的文件以 UTF-8 写入。没有 BOM 的文件不是有效 UTF-8 时，hook 停止。没有 BOM 的文件可能同时符合多种编码，所以 hook 把这类文件当作 UTF-8 处理，并依靠编辑前的副本进行恢复。追加出错时，hook 报告 profile 和备份路径。hook 15 在 chezmoi 写入目标之后运行，所以它的失败不会撤销这些写入。fixture 测试覆盖每种支持的编码、末尾没有换行的文件、复制失败、追加失败，以及对保留内容的逐字节比较。这一行永远不会重复添加。每次 apply 都运行，就能修复被删除的行，也能跟随移动后的 Documents 文件夹。
- 受管行只在主体文件存在时才加载它，所以主体被删除时不会破坏 PowerShell 启动。
- profile 辅助函数把 profile 路径作为显式参数。生产环境传入 `$PROFILE.CurrentUserAllHosts`；测试传入 fixture 内的路径，因此测试永远不会写入 runner 用户的真实 profile。
- `$PROFILE.CurrentUserAllHosts` 所指的文件中没有受管行时，`check.ps1` 失败。

主体在适用于 Windows 的范围内对齐 Unix env 模板：

- 已加载 PSReadLine 时，先于其他初始化把编辑模式设为 Emacs，并把 Tab 绑定到 `MenuComplete`。交互式宿主在运行 profile 前加载 PSReadLine；脚本宿主跳过这一步。PSReadLine 在 Windows 上默认使用 Windows 编辑模式。Unix 基线使用 Oh My Zsh，它选用 Emacs 键位和菜单式补全。用户于 2026-11-23 做出这个选择。本地 overlay 可以覆盖这两项设置。[PSReadLine 选项](https://learn.microsoft.com/powershell/module/psreadline/set-psreadlineoption)、[PSReadLine 按键处理](https://learn.microsoft.com/powershell/module/psreadline/set-psreadlinekeyhandler)、[Oh My Zsh 键位](https://github.com/ohmyzsh/ohmyzsh/blob/master/lib/key-bindings.zsh)、[Oh My Zsh 补全](https://github.com/ohmyzsh/ohmyzsh/blob/master/lib/completion.zsh)
- `GOPATH` 默认为 `~/go`。`GOBIN` 默认为 `GOPATH` 中第一个分号分隔条目下的 `bin` 目录。
- 把 mise shims 目录、`~/.local/bin` 和 `$GOBIN` 放到 `PATH` 最前面。
- 把 `BAT_THEME` 设为与 Unix env 模板相同的值。
- 仅在 `mise` 位于 `PATH` 上时，用 `(&mise activate pwsh) | Out-String | Invoke-Expression` 激活 mise。Unix rc 文件也用同样方式保护激活。
- 激活 mise 后，查找 `PATH` 上第一个 `oh-my-posh` 应用程序。找到时，使用受管文件 `~/.config/oh-my-devenv/powershell/robbyrussell.omp.json` 初始化。这个本地主题沿用 Unix 的 `robbyrussell` 提示符。主题和 MIT 许可证声明来自 [Oh My Posh v33.0.0](https://github.com/JanDeDobbeleer/oh-my-posh/tree/v33.0.0)。
- 主题关闭自动升级和升级通知。在设备上运行 `oh-my-posh enable upgrade` 或 `oh-my-posh enable notice` 会覆盖主题中的这两项设置。主题不启用 `async`。在 async 模式下，Oh My Posh 在首次显示提示符时才加载模块，且这一次不返回提示符文本，因此 PowerShell 会先显示一次默认提示符。profile 使用 `init pwsh`。Oh My Posh 在 profile 启动期间加载渲染模块并注册提示符函数，因此第一个提示符就使用主题。主题从磁盘加载，路径和 Git 段读取本地状态。首次实机 apply 显示了默认的第一个提示符，用户于 2026-11-23 选择同步加载。[功能选择](https://github.com/JanDeDobbeleer/oh-my-posh/blob/v33.0.0/src/config/config.go#L144-L191)、[升级设置](https://github.com/JanDeDobbeleer/oh-my-posh/blob/v33.0.0/src/config/config.go#L246-L272)、[enable 命令](https://github.com/JanDeDobbeleer/oh-my-posh/blob/v33.0.0/src/cli/enable.go#L17-L54)、[PowerShell 初始化脚本生成器](https://github.com/JanDeDobbeleer/oh-my-posh/blob/v33.0.0/src/shell/init.go#L46-L63)、[加载命令](https://github.com/JanDeDobbeleer/oh-my-posh/blob/v33.0.0/src/shell/init.go#L229-L291)。
- 控制台输入或输出被重定向时，脚本宿主跳过提示符初始化，仍加载 profile 的其他部分和本地 overlay。检查器在新 PowerShell 进程中显式启用提示符初始化，以验证同一条初始化路径。
- 初始化脚本导出解析后的 `POSH_CONFIG` 和 `POSH_SESSION_ID`。生成的脚本注册提示符函数后，profile 在运行 overlay 前记录该配置路径。检查器在新 PowerShell 进程中清除继承值，并要求记录的路径与已部署主题一致。[会话变量](https://github.com/JanDeDobbeleer/oh-my-posh/blob/v33.0.0/src/shell/init.go#L315-L326)、[注册提示符](https://github.com/JanDeDobbeleer/oh-my-posh/blob/v33.0.0/src/shell/scripts/omp.ps1#L981-L996)。
- 在本地 overlay 之前，将受管 PowerShell 补全脚本 dot-source 到 profile 的会话作用域。补全运行时可以调用脚本定义的辅助函数。控制台输入和输出均未重定向，或 `OH_MY_DEVENV_PROBE_PROMPT=1` 时，加载补全脚本。检查器在有重定向的新 PowerShell 进程中设置此标志。profile 返回后，检查器用 `TabExpansion2` 验证 `chezmoi` 和 `uv` 的子命令补全。
- 本地 overlay `~/.config/oh-my-devenv/powershell/profile.local.ps1` 存在时加载它。overlay 可以覆盖提示符。
- 每次加载 profile 时，在可选的 overlay 步骤后，把缺失的受管目录放到 `PATH` 最前面，包括实际生效的 `GOBIN`。保留已有的 `PATH` 条目及其顺序。

profile 只影响 PowerShell 会话。从 Windows shell 启动的应用（例如从开始菜单启动的 IDE）不会加载它。持久化的用户 `Path` 条目覆盖这些应用（第 7 节）。

### Windows Terminal

基线不管理 Windows Terminal 的 `settings.json`，使用户在 Terminal 界面中修改的设置仍由用户掌控。基线改为部署一个 JSON fragment。

- 位置：`%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\oh-my-devenv\`。这是文档给出的用户级 fragment 位置。该文件夹不在 Documents 下，Documents 重定向不会移动它。
- 源路径 `AppData/Local/...` 映射到 chezmoi 的目标目录。启用桌面基线时，hook 00 在 chezmoi 写入 fragment 前，将该路径与实际生效的 LocalAppData 已知文件夹比较。hook 22 和 `check.ps1` 使用同一检查。
- fragment 可以添加 profile 和配色方案，也可以更新内置 profile 和动态 profile，但不能修改全局设置。
- fragment 用 `profiles[].updates` 指向首选的动态 PowerShell profile，其 GUID 为 `{574e775e-4f2a-5b96-ac1e-a2962a402336}`。它从 `desktop-font-family` 局部模板读取 `font.face`。[Fragment 格式](https://learn.microsoft.com/en-us/windows/terminal/json-fragment-extensions)、[PowerShell profile 生成器](https://github.com/microsoft/terminal/blob/main/src/cascadia/TerminalSettingsModel/PowershellCoreProfileGenerator.cpp)、[字体设置](https://learn.microsoft.com/en-us/windows/terminal/customize-settings/profile-appearance#font-face)。
- 仅在 `desktopBaseline` 为 true 时部署该 fragment。

### XDG

hook 00 的 XDG 根目录检查仍只用于 Unix。Windows 不导出 `XDG_*` 变量。Windows 目标直接使用字面路径 `~/.config`，这与 mise 在 Windows 上的默认值一致。

### 换行

在阶段 2 中添加 `.gitattributes`，内容为 `* text=auto eol=lf`，并把它列入 `.chezmoiignore`。这样 Windows checkout 也保持 LF 换行，在 Windows 上编辑本仓库时 Bash 脚本仍然有效，hook 哈希也与 Unix checkout 一致。PowerShell 7 可以运行 LF 换行的 `.ps1` 文件。

这个文件是必需的，不是可选项。Git for Windows 安装器默认在系统级 Git 配置中设置 `core.autocrlf=true`。没有仓库级 LF 规则时，实际生效的 `core.autocrlf=true` 可能以 CRLF 换行检出文本源文件。chezmoi 可能在受管输出中保留这些换行；模板也可能生成 LF 换行。

## 10. 系统包

使用 `winget import`，输入文件采用 `winget export` 产生的 JSON 格式。

- 使用 [WinGet 2.0 导出 schema](https://github.com/microsoft/winget-cli/blob/master/schemas/JSON/packages/packages.schema.2.0.json) 和内置 `winget` 源。验证源的名称、类型和标识符。每个条目设置 `Scope` 为 `user`，省略 `Version`。
- 导入时不出现交互提示，在命令行上接受各项协议。
- 传入 `--no-upgrade`。hook 20 只确保每个包存在；升级仍是用户单独执行的操作（`winget upgrade`）。安装器升级可能需要提权或重启，hook 不能触发这些。Arch Linux 路径同样把完整升级留给用户。
- WinGet 缺失、源打不开或安装失败时，hook 20 失败。错误指出源和清单条目，并保留 WinGet 诊断。设备策略可能限制源或安装。使用现有源。遇到策略限制时联系设备管理员。
- `check.ps1` 通过 `winget export --source winget` 导出已安装清单。它使用 JSON 中归属内置源的完整包 ID 与清单比较。它列出全部缺失 ID，并在导出失败时保留 WinGet 诊断。[WinGet export](https://learn.microsoft.com/en-us/windows/package-manager/winget/export)。

[系统包清单](../../bootstrap/manifests/system/winget-packages.json)保存了已批准的条目。

| 包 ID | 安装器 |
| --- | --- |
| `Git.Git` | 用户范围的 Inno 安装器 |
| `GitHub.cli` | ZIP 归档中的便携包 |
| `BurntSushi.ripgrep.MSVC` | ZIP 归档中的便携包 |
| `jqlang.jq` | 便携包 |
| `JanDeDobbeleer.OhMyPosh` | MSIX，在[目录](https://github.com/microsoft/winget-pkgs/blob/master/manifests/j/JanDeDobbeleer/OhMyPosh/33.0.0/JanDeDobbeleer.OhMyPosh.installer.yaml)中声明为 `appx` |

WinGet 将清单要求的用户范围应用到 Oh My Posh MSIX。
[安装器类型映射](https://github.com/microsoft/winget-cli/blob/v1.11.510/src/AppInstallerCommonCore/Manifest/ManifestCommon.cpp#L144-L151)、
[范围筛选](https://github.com/microsoft/winget-cli/blob/v1.11.510/src/AppInstallerCommonCore/Manifest/ManifestComparator.cpp#L469-L484)。

| 未纳入或待讨论的工具 | 原因 |
| --- | --- |
| `fd`、`bat`、`fzf` | `Get-ChildItem` 和 `Get-Content` 覆盖日常查找和读取文件。PowerShell 筛选覆盖日常选择。 |
| `yq`、`shellcheck`、`shfmt` | YAML 编辑和 Unix shell 维护在此 Windows 基线中的使用较少。 |
| Everything | 非提升权限下的 NTFS 快速索引依赖一项需要管理员权限才能安装的服务。[Everything 服务](https://www.voidtools.com/support/everything/everything_service/) |
| 7-Zip | Windows 11 24H2 的文件资源管理器可解压普通 7z 和 RAR 归档。[Microsoft 支持](https://support.microsoft.com/en-gb/windows/experience/storage-filemanagement/zip-and-unzip-files) |
| DevToys | 当前 DevToys 应用的目录条目是 2.0 预览版。[WinGet 目录](https://github.com/microsoft/winget-pkgs/tree/master/manifests/d/DevToys-app/DevToys) |
| `gsudo` | 提权超出基线范围。 |
| `zoxide`、`lazygit`、`delta` | 留待 mise 层单独讨论。 |
| `curl`、`wget`、`tree`、`zip`、`unzip` | Windows 提供 `curl.exe` 及内置的目录和归档工具。 |
| `ca-certificates`、`bash-completion`、`zsh` | 这些 Unix 包不适用于 Windows 基线。 |
| `direnv` | 它用 Bash 执行 `.envrc`。[上游实现](https://github.com/direnv/direnv#how-it-works) |
| 原生工具链、终端复用器、`gnupg`、`pinentry` | 完成 Windows 工具盘点后再决定。 |

## 11. 桌面基线

在 Windows 上，桌面基线包括 PowerToys、Maple Mono NF CN 和 Windows Terminal fragment。

- 启用 `desktopBaseline` 时，hook 22 导入[桌面包清单](../../bootstrap/manifests/desktop/winget-packages.json)。`Microsoft.PowerToys` 提供用户范围的 Burn 安装器。hook 22 复用 hook 20 的导入参数、源校验和失败处理。检查器通过一次导出验证两个已启用层的完整包 ID。[PowerToys 目录清单](https://github.com/microsoft/winget-pkgs/blob/master/manifests/m/Microsoft/PowerToys/0.102.3101/Microsoft.PowerToys.installer.yaml)。

- hook 22 从 `maple-mono-nf-cn.env` 读取 URL、摘要、字族和必需字面。先校验归档摘要，再提取必需的 TrueType 文件。已有文件的字节一致时保留原文件。
- 将字体复制到 `%LOCALAPPDATA%\Microsoft\Windows\Fonts`。在 `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts` 下为每个字面写入完整文件路径，值类型为字符串。字体为当前用户持久注册。如果当前会话无法使用字体，注销并重新登录。[Microsoft 字体安装器实现](https://github.com/microsoft/winget-cli/blob/master/src/AppInstallerCommonCore/Fonts.cpp)、[FontLab 用户级注册表实现](https://github.com/fontlaborg/fontlift-win-cli/blob/main/src/sys_utils.cpp)。
- 启用 `desktopBaseline` 时，hook 00、hook 22 和检查器要求目标目录的 `AppData/Local` 与实际生效的 LocalAppData 一致。它们还要求在 `PATH` 上找到 `wt.exe` 或 `WindowsTerminal.exe`。Windows 11 通常自带 Terminal。禁用别名时，需在 `PATH` 上提供可执行文件。
- 检查器要求每个字面的文件和注册项都存在。它解析已部署的 JSON，并验证 fragment 为 PowerShell 7 配置清单中的字体族。
- `desktopBaseline` 为 false 或缺省时，fragment 模板渲染为空，chezmoi 在 apply 时删除该文件。卸载也会移除受管 fragment。[Chezmoi 模板行为](https://www.chezmoi.io/reference/templates/)
- hook 22 在写入字体文件或新增注册值之前，将对应归属写入 `%LOCALAPPDATA%\oh-my-devenv\fonts.json`。已有的匹配文件和注册值保留原归属。遇到冲突的非受管文件或注册值时，字体安装停止。若非受管文件冲突，请删除或重命名该文件后重新 apply。检查器会校验已有的归属记录。安装、检查和卸载使用共享的路径规范化逻辑来比较注册表路径。
- 卸载预览并移除已记录的字体文件，以及仍指向这些文件的已记录 HKCU 注册值。文件和注册值分别清理。没有剩余受管项时，删除归属记录。若有项移除失败，归属记录仅保留剩余的受管项，并汇总报告错误。若字体被占用，请关闭使用它的应用后重试卸载。
- 卸载保留 WinGet 包、mise、mise 管理的运行时以及 Go 和 uv 工具。此规则沿用 Unix，因为 Git 等软件包可能已安装并由其他应用共享。Windows 保留首次运行备份。默认情况下，Unix 确认卸载时先将首次运行备份目录归档到删除前备份，再移除原目录。使用 `--confirm --no-backup` 时，卸载会移除原目录，但不创建该归档。

## 12. 本地 Overlay

以下现有 overlay 在 Windows 上同样适用：`gitconfig`、`git_hooks`、`ssh_config`、`npmrc` 和 `mise`。

以下 overlay 在 Windows 上不适用：`env`、`bootstrap_env`、`secrets`、`zshrc`、`bashrc` 和 `ghostty`。

在阶段 2 中，随加载它的 profile 一起新增一个 Windows overlay：`profile.local.ps1`（第 9 节）。把它加入 `local-overlays.tsv` 和 `docs/local-overlay-examples/`，并在同一次改动中更新 `local-overlays.tsv` 的所有读取方。

## 13. 验证

- Unix smoke tests：
  - 用 Windows 的 chezmoi 数据渲染 ignore 规则，断言没有任何 `.sh` hook 和 Unix 专属目标受管；用 macOS 和 Linux 数据渲染，断言没有任何 `.ps1` hook 和 Windows 专属目标受管。
  - 为各平台渲染共享的 Git 与 SSH 目标。解析渲染后的 Terminal fragment。验证关闭或省略桌面选项时，桌面 hook 被停用且 fragment 被删除。
- 在托管 Windows runner 上运行 Windows smoke job：
  - 用 PSScriptAnalyzer 检查 PowerShell 代码。
  - 为辅助脚本运行 Pester 测试，包括共享 manifest 的测试用例。
  - 在临时 home 中，用 WinGet、mise、Go 和 uv stub 执行 apply 和 reapply。使用 fixture 中的 profile 路径和注册表项，并用同一个注册表项检查卸载。用模拟下载以及隔离的字体目录和注册表位置单独测试桌面安装器。
- 托管 Windows apply job 要求 WinGet 和 Terminal 可用。它执行真实 WinGet 导入、桌面 hook 和检查器。托管 Windows Server 启动已注册的 Oh My Posh MSIX 时会卡住。fixture 将已安装的可执行文件复制到临时目录，再用副本验证真实提示符初始化。首次实机 apply 在客户端上确认了通过 Windows 应用执行别名启动；第 17 节记录了结果。测试后恢复字体文件和注册表值。
- 阶段 4 的 apply job 使用真实的 WinGet、mise、Go 和 uv。它检查首次 apply、
  无输入变化的 reapply 和按归属记录卸载。测试结束后恢复 runner 用户 `Path`
  的原始字节及注册表类型，并移除测试归属记录。作业记录每项 mise 工具的请求和
  安装版本、识别出的路径长度错误，以及 mise 数据和 uv 工具目录中的最长路径。
- 第二个托管 apply job 在原生 ARM64 的 Windows 11 runner 上运行同一个 fixture。预配前，ARM64 runner 的 `PATH` 上无法找到 WinGet，也没有安装 ARM64 VC++ 运行库。预装的 Windows Terminal 没有为 runner 用户提供 `wt.exe` 别名。fixture 运行前，工作流的一个步骤通过 `Microsoft.WinGet.Client` 模块预配 WinGet，并通过 WinGet 预配该运行库。该步骤为 runner 用户重新注册 Terminal。smoke job 只在 x64 上运行。
- 每个 Windows job 都像 README 一样用 WinGet 安装 chezmoi，并检查解析到的 chezmoi 与 runner 架构一致。
- 阶段 5 的 smoke 测试覆盖发行方补全脚本、生成补全、两次 apply 之间的命令可用性变化和字体归属。托管 apply 作业运行真实的 hook 55，并在新 PowerShell 进程中测量补全加载耗时。runner 提供无重定向控制台时，profile 探测使用 `TabExpansion2` 验证 `chezmoi` 和 `uv` 的子命令补全。作业检查卸载是否移除受管资产并保留已安装的软件包和工具，然后恢复 runner 的字体文件、字体注册值、用户 Path 和配置文件。
- 第 17 节记录托管作业的覆盖范围。托管作业没有验证干净客户端上的安装和 Oh My Posh 应用执行别名。第 17 节还记录了在所有计划阶段完成后进行的首次实机 apply，该次 apply 覆盖了应用执行别名。
- 两个 Windows job 都在与 Unix job 相同的 `needs-checks` 条件下运行，并汇入现有的单一 required check。这样不需要第二个路径分类器，避免共享文件改动后 Windows CI 被跳过。
- 在真实 Windows 机器上的实际安装，遵循与 Unix 平台相同的本地验证策略。

## 14. 阶段

| 阶段 | 范围 | 退出条件 |
| --- | --- | --- |
| 1 | Windows 工具盘点（用户） | 用户确认或修改第 10 节和第 8 节的起始清单。可与阶段 2 并行。 |
| 2 | 仅配置：平台分派，`.gitattributes`，hook 00、10、15、60，PowerShell profile 及其 overlay，共享的 Git、SSH、mise 目标，最小卸载（移除受管 profile 行和受管目标），Windows smoke 与 apply job，仓库规则 | 在 Windows 上 apply 能部署配置，`check.ps1` 对已交付的层通过；Unix 输出不变。 |
| 3 | 系统包与桌面基线 | hook 20 和 22 安装各自的 manifest，`check.ps1` 检查它们。 |
| 4 | mise、运行时与生态工具，以及持久化用户 `Path` 条目 | hook 30、40、50 安装共享清单。hook 15 添加用户 `Path` 条目，卸载移除它们。`check.ps1` 检查它们。 |
| 5 | 完整生命周期与 PowerShell 补全 | hook 55 在每次 apply 时更新补全。hook 60 检查脚本及新 profile 的补全结果。卸载涵盖受管配置、归属记录中的 Path 条目、补全和字体。保留已安装的软件包、工具和首次运行备份。 |

`check.ps1` 只检查当前阶段已交付的层。每个阶段加入其各层的检查。

## 15. 考虑过的替代方案

| 方案 | 结论 | 理由 |
| --- | --- | --- |
| 单独的仓库 | 否决（用户决策） | 共享数据会存在两份并逐渐偏离。 |
| 通过 Git Bash 或 MSYS2 复用 Bash 脚本 | 否决 | 路径、权限和包管理都不同，结果脆弱，而且仍需要一个 Windows 包管理层。 |
| 在每个模板内用 OS 条件门控 hook | 否决 | 它要修改每个 Unix hook 模板。`.chezmoiignore` 在一处完成 hook 门控。 |
| Scoop 代替 winget | 基线不采用 | 包层使用内置 winget 源，设备策略阻止时停止。 |
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

第 2、9、10 和 11 节记录了已批准的阶段 3 基线及其验证规则。

`905d27a` 的阶段 3 托管运行通过了所有作业。Windows smoke 通过 74 项 Pester 测试，跳过 1 项。Windows apply 完成了用户范围的 WinGet 导入，包括 PowerToys。它使用已安装的 Oh My Posh 可执行文件副本验证了受管提示符。单独运行的普通 `pwsh -File` 加载了 profile 和 overlay，随后正常退出。用户设备上的首次 apply 和 Oh My Posh 应用执行别名检查仍待进行。[完整 CI 运行](https://github.com/kangmingxuan/oh-my-devenv/actions/runs/44912366118)、[Windows smoke](https://github.com/kangmingxuan/oh-my-devenv/actions/runs/44912366118/job/136870704931)、[Windows apply](https://github.com/kangmingxuan/oh-my-devenv/actions/runs/44912366118/job/136870704962)。

`edde9e9` 的阶段 4 托管运行通过了所有作业。WinGet 在 x64 runner 上安装了 mise
2026.11.12。mise 安装了共享配置中的全部六项工具：Go 1.27.1、golangci-lint v2.14.0、
Node 24.21.0、Python 3.13.16、usage 6.12.0 和 uv 0.11.33。mise 数据目录和 uv 工具
目录中观察到的最长路径分别为 165 和 203 个字符。采集到的 apply 日志中没有与诊断模式匹配的路径长度错误。这些 runner 路径不能说明更长的客户端路径的行为。
[完整 CI 运行](https://github.com/kangmingxuan/oh-my-devenv/actions/runs/44985641100)、[Windows smoke](https://github.com/kangmingxuan/oh-my-devenv/actions/runs/44985641100/job/137095504120)、[Windows apply](https://github.com/kangmingxuan/oh-my-devenv/actions/runs/44985641100/job/137095504118)。

在全新 Windows 客户端上的首次 apply 仍待验证。WinGet 的 mise 包需要在机器范围安装架构
匹配的 Microsoft Visual C++ 2015+ Redistributable。缺少该运行库时，请在 apply 前
由设备管理员预装。

在依赖某一项的阶段开始前解决其余事项。

| 事项 | 阶段 |
| --- | --- |
| 实际生效的脚本执行策略是否允许 chezmoi 运行 `.ps1` hook，以及不允许时的停止条件。不绕过设备策略。PowerShell 7 与 Windows PowerShell 5.1 分开存储执行策略设置。组策略可以让它使用 Windows PowerShell 的策略设置，所以要在 `pwsh` 下检查实际生效的策略。 | 2 |
| 在满足第 7 节前置条件的全新 Windows 客户端（此前没有 mise 或运行时）上完成首次 apply。标准用户账户不在目标范围内（第 2 节）。 | 4 |

阶段 5 在 `c30194a` 上的托管运行通过了所有作业。Windows smoke 通过了 132 项 Pester
测试，跳过一项。Windows apply 作业安装了七个 PowerShell 补全。由于 `bat` 不在
`PATH` 上，作业跳过了它。新 PowerShell 进程加载补全增加的耗时为 227、233 和 238
毫秒，中位数为 233 毫秒。无重定向的 profile 探测在 profile 返回后完成了 `chezmoi` 和 `uv` 命令的补全。卸载移除了受管配置、
受管的用户 `Path` 条目、补全，以及桌面字体文件和注册值。WinGet 包、mise、运行时
以及 Go 和 uv 工具都保留。
[完整 CI 运行](https://github.com/kangmingxuan/oh-my-devenv/actions/runs/45017493063)、[Windows smoke](https://github.com/kangmingxuan/oh-my-devenv/actions/runs/45017493063/job/137192897238)、[Windows apply](https://github.com/kangmingxuan/oh-my-devenv/actions/runs/45017493063/job/137192897275)。

首次实机 apply 于 2026-11-22 至 2026-11-23 在一台 Windows Enterprise ARM64
客户端上进行，使用 PowerShell 7.7.0 和 chezmoi v2.74.1。该账户属于
Administrators 组，以非提升权限运行，因此全新的标准用户客户端当时仍待验证。
`pwsh` 的执行策略是来自 `LocalMachine` 的 `RemoteSigned`，chezmoi 运行了
`.ps1` hook。与架构匹配的 VC++ 运行库已在机器范围安装。

- hook 50 首次在构建 Delve 时停止。加入 Delve 标签后，它在原生 ARM64 上装好了 Go 工具。[PR #69](https://github.com/kangmingxuan/oh-my-devenv/pull/69)
- 设备网络策略拦截了公共 Python 包文件主机，因此 uv 工具安装停止。在用户级 uv 配置中把索引指向组织的包镜像后，问题解决。[上手指南](../01-onboarding.md#native-windows)说明了这项设置。
- 完成这些修改后，hook 60 输出 `All checks passed.`
- `oh-my-posh` 解析为 `%LOCALAPPDATA%\Microsoft\WindowsApps` 下的应用执行别名，profile 通过它加载了受管主题。
- 启用 `async` 时，每个新终端都先显示 PowerShell 默认提示符。主题现在同步加载。[PR #70](https://github.com/kangmingxuan/oh-my-devenv/pull/70)
- 合并 PR #70 后，启动耗时取三次运行的平均值。不加载 profile 的 `pwsh` 用时 251 ms。加载 profile 且输出被重定向时，会跳过提示符和补全，用时 620 ms。通过 `OH_MY_DEVENV_PROBE_PROMPT=1` 强制加载提示符和补全时，用时 1,403 ms。用户认为可以接受。
- 补全部分输入的 `mise` 子命令正常。在末尾空格之后，`mise <Tab>` 列出的是文件名，因为上游生成的补全脚本丢掉了末尾空格。[jdx/usage#1671](https://github.com/jdx/usage/issues/1671)

第二次实机 apply 于 2026-11-24 在一台个人 Windows 11 专业版 x64 客户端上运行，
版本 26H2，内部版本 26300.10075，使用 PowerShell 7.7.0 和 chezmoi v2.74.2。
测试账户属于 Administrators 组，以非提升权限运行。
这台电脑此前没有安装过 oh-my-devenv。mise 和 Go 曾手动安装，mise 把工具放在
`C:\.mise-installs` 下。

- 第一次 apply 在一个已激活旧 mise 配置的终端中运行。该终端带着 Go 1.25.12 的 `GOROOT`。apply 选定了 Go 1.27.1，hook 50 在第一个 `go install` 处停止，报错为 `compile: version "go1.25.12" does not match go tool version "go1.27.1"`。同样的 apply 在新开的终端中完成。Go 工具同步现在在两个平台上都忽略继承的 `GOROOT`。[PR #79](https://github.com/kangmingxuan/oh-my-devenv/pull/79)
- 重新运行后，hook 60 输出 `All checks passed.`，共 10 个核心工具。由于 `bat` 不在 `PATH` 上，它跳过了 `bat` 补全。
- Windows Terminal 正确显示了富文本 CLI 输出：banner 渐变色以及 `❯`、`✓`、`›` 标记。未检查旧版 conhost。[PR #77](https://github.com/kangmingxuan/oh-my-devenv/pull/77)

首次成功的托管 ARM64 apply job 在 `b46276c` 上运行。runner 镜像为
`win11-vs2026-arm64` 20261115.219.1，使用 PowerShell 7.6.10。工作流安装了
WinGet v1.29.380 和 ARM64 版 chezmoi v2.74.1。WinGet 安装了 `windows-arm64` 版
mise 2026.11.12。mise 安装了 `windows/arm64` 版 Go 1.27.1，hook 50 构建了 Delve
v1.27.2。hook 60 输出 `All checks passed.` 该作业以 runner 管理员身份运行，因此
不能替代在全新客户端上的首次 apply。[完整 CI 运行](https://github.com/kangmingxuan/oh-my-devenv/actions/runs/45130784147)、[Windows ARM64 apply](https://github.com/kangmingxuan/oh-my-devenv/actions/runs/45130784147/job/137545577528)。

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
