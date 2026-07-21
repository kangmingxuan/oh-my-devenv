# 技术设计：基于 chezmoi 的跨平台开发环境引导方案

## 1. 目标

为以下环境提供一套可重复执行、可维护的开发环境初始化方案：

- macOS
- Ubuntu / Debian
- Windows WSL

要求：

- 使用 `chezmoi` 统一管理 dotfiles
- 新机器上可自动安装所需工具
- 明确区分“系统工具”“语言运行时”“生态工具”的管理职责
- 在受支持的工作站上提供一套显式选择、全有或全无的平台桌面基线，同时不影响服务器、WSL 或 CI 安装

## 2. 设计结论

采用以下分层：

1. **chezmoi**：只负责配置文件和脚本编排
2. **系统包管理器**：
   - macOS 使用 `Homebrew`
   - Ubuntu / Debian / WSL 使用 `apt`
3. **桌面资产安装器**：用户选择后，从独立清单安装完整的平台包：所有受支持平台包含 Ghostty 与 Maple Mono NF CN，macOS 额外包含 OrbStack
4. **mise**：负责语言运行时与二进制分发工具的版本管理，如 Go / Node / Python / `golangci-lint` / `uv`
5. **生态工具安装器**：负责语言生态内工具
   - Go：`go install`（如 `gopls`、`dlv`）
   - Python：`uv tool`
   - Node：仅在确有必要时使用全局安装
6. **Shell 资产安装器**：负责 shell 配置显式依赖、但不适合交给系统包管理器的框架与插件
   - 安装 `oh-my-zsh` 与指定插件

**约束：Linux / WSL 不使用 Homebrew。**

## 3. 职责边界

### chezmoi 负责

- shell 配置
- Git 配置
- 编辑器配置
- 机器选择桌面基线时的 Ghostty 配置
- 模板文件
- 安装脚本编排

### 系统包管理器负责

- 基础 CLI 工具
- 构建工具
- 常用 Unix 工具
- 受支持桌面平台上的 Ghostty
- 已选择的 macOS 桌面基线中的 OrbStack

示例：

- `git`
- `curl`
- `wget`
- `bash-completion`
- `tmux`
- `jq`
- `ripgrep`
- `fzf`
- `direnv`
- `tree`
- `zip`
- `unzip`
- `build-essential`（Linux）

### mise 负责

- `go`
- `golangci-lint`
- `node`
- `python`
- 其他运行时

### 生态安装器负责

- `gopls`
- `dlv`
- `ruff`
- `basedpyright`
- 其他语言生态工具

## 4. 仓库结构

建议目录结构如下：

```text
.
├── .chezmoi.toml.tmpl
├── .chezmoiscripts/
│   ├── run_once_before_10-bootstrap.sh.tmpl
│   ├── run_onchange_after_20-install-system-packages.sh.tmpl
│   ├── run_onchange_after_22-install-desktop-assets.sh.tmpl
│   ├── run_onchange_after_25-install-shell-assets.sh.tmpl
│   ├── run_onchange_after_30-install-mise.sh.tmpl
│   ├── run_after_35-apply-xdg-config.sh.tmpl
│   ├── run_onchange_after_40-install-runtimes.sh.tmpl
│   ├── run_onchange_after_50-sync-ecosystem-tools.sh.tmpl
│   └── run_onchange_after_60-check.sh.tmpl
├── bootstrap/
│   ├── manifests/
│   │   ├── desktop/
│   │   │   ├── apt-packages.txt
│   │   │   ├── Brewfile
│   │   │   └── maple-mono-nf-cn.env
│   │   ├── shell/
│   │   │   └── oh-my-zsh-plugins.txt
│   │   ├── system/
│   │   │   ├── apt-packages.txt
│   │   │   └── Brewfile
│   │   └── ecosystem/
│   │       ├── go-tools.txt
│   │       └── uv-tools.txt
│   └── scripts/
│       ├── common.sh
│       ├── go-env.sh
│       ├── install-apt-packages.sh
│       ├── install-brew-packages.sh
│       ├── install-maple-mono-font.sh
│       ├── install-go-tools.sh
│       ├── install-oh-my-zsh-assets.sh
│       ├── install-uv-tools.sh
│       └── xdg-config.sh
├── dot_local/share/oh-my-devenv/
│   └── xdg.sh
└── xdg_config/
    ├── fontconfig/conf.d/
    │   └── 99-oh-my-devenv-maple-mono-nf-cn.conf.tmpl
    ├── ghostty/
    │   └── config.ghostty.tmpl
    └── mise/
        └── config.toml.tmpl
```

## 5. 引导流程

新机器初始化流程：

1. 安装最小前置依赖：`git`、`curl`、`chezmoi`
2. 执行 `chezmoi init --apply <repo>`
3. 由 `chezmoi` 自动触发后续脚本：
   - 安装系统工具
   - 在受支持工作站上安装已选择的桌面资产
   - 安装 shell 资产
   - 安装 `mise`
   - 安装运行时
   - 安装生态工具
   - 执行检查

要求：bootstrap 本身保持轻量，不直接塞入大量安装逻辑。

## 6. 脚本顺序

建议按以下顺序执行：

1. `run_once_before_10-bootstrap.sh.tmpl`
2. `run_onchange_after_20-install-system-packages.sh.tmpl`
3. `run_onchange_after_22-install-desktop-assets.sh.tmpl`
4. `run_onchange_after_25-install-shell-assets.sh.tmpl`
5. `run_onchange_after_30-install-mise.sh.tmpl`
6. `run_after_35-apply-xdg-config.sh.tmpl`
7. `run_onchange_after_40-install-runtimes.sh.tmpl`
8. `run_onchange_after_50-sync-ecosystem-tools.sh.tmpl`
9. `run_onchange_after_60-check.sh.tmpl`

要求：

- 对于 `run_onchange_` 脚本，必须利用 template hash（比如 `{{ include "bootstrap/manifests/system/apt-packages.txt" | sha256sum }}`）作为触发器，确保清单变更时能重新执行
- bootstrap 的 manifest 与脚本都放在 source 根目录下的 `bootstrap/`，并通过 `.chezmoiignore` 保持 source-only；运行时由 `.chezmoiscripts` 基于 `{{ .chezmoi.sourceDir }}` 调用
- 所有脚本必须幂等
- 使用 `bash` 和 `set -euo pipefail`
- 避免不必要的交互式提示（如 apt 询问）；Linux / WSL 的 apt 路径应先统一执行 `sudo -v`，并以非交互模式运行安装命令
- 失败时输出清晰错误信息

## 7. 平台策略

### macOS

- 系统工具使用 Homebrew
- 通过 `Brewfile` 管理包清单
- 使用 `brew bundle` 安装
- 选择 `desktopBaseline` 后，从独立的桌面 `Brewfile` 一起安装 Ghostty、Maple Mono NF CN 与 OrbStack
- 系统包 hook 运行时，若固定路径 `$XDG_CONFIG_HOME/oh-my-devenv/Brewfile.local` 存在则读取它；首次之后的本地清单变更用 `brew bundle install --file=...` 手动同步
- 安装 OrbStack cask，但不声称首次启动设置、Docker runtime 状态或许可证已经就绪
- shell 框架和插件不走 Homebrew，改由独立 shell 资产脚本通过 `git clone` 管理

### Ubuntu / Debian / WSL

- 系统工具只使用 `apt`
- 包清单存放于 `apt-packages.txt`
- 不引入 Homebrew
- 当 shell 层依赖 zsh 时，通过 `apt` 安装 `zsh`
- 复用与 macOS 相同的 shell 资产脚本安装 `oh-my-zsh` 与插件
- 只有非 WSL 的 Ubuntu 26.04+ 参与已选择的桌面基线：Ghostty 通过 apt 安装，固定并校验过的 Maple Mono 归档安装到用户字体目录
- 在该 Linux 桌面基线下，通过受管 Fontconfig 片段将通用 `monospace` 强优先到 Maple Mono NF CN；关闭桌面基线时将片段渲染为合法的空配置，使曾经启用过的机器也能正确收敛

### WSL

- 视为 Linux 子类处理
- 只管理 WSL 内部环境
- 不安装桌面基线
- 不负责 Windows 原生软件安装

## 8. 平台识别

直接使用 `chezmoi` 原生模板变量来做系统级别区分，不再维护额外的 `detect-platform`：

- 区分操作系统：`{{ if eq .chezmoi.os "darwin" }}` 或 `{{ if eq .chezmoi.os "linux" }}`
- 通过 `.chezmoi.osRelease.id` 与 `.chezmoi.osRelease.versionID` 区分 Linux 发行版及版本
- 检查 `.chezmoi.kernel.osrelease` 是否包含 `microsoft` 来识别 WSL；无需持久化额外的平台标志
- 将 macOS，或 `versionID >= 26.04` 且非 WSL 的 Ubuntu，视为支持自动安装的桌面平台
- `XDG_CURRENT_DESKTOP`、`WAYLAND_DISPLAY` 与 `DISPLAY` 只用于决定 Ubuntu 首次提示的默认值；用户的 `desktopBaseline` 答案会持久化，日常 apply 不再重新推断

## 9. 清单文件规范

### `apt-packages.txt`

- 一行一个包
- 支持空行
- 支持 `#` 注释

示例：

```text
# Core
git
curl
wget
ca-certificates
bash-completion
build-essential
pkg-config

# CLI
tmux
jq
ripgrep
fzf
direnv
fd-find
bat
```

### `go-tools.txt`

```text
golang.org/x/tools/gopls@v0.21.1
github.com/go-delve/delve/cmd/dlv@v1.27.0
```

说明：

- `go-tools.txt` 直接使用 `go install` 的 `module@version` 语法
- 固定精确版本，让全新安装与已有机器收敛到相同结果
- 有意升级版本，使 manifest hash 能触发生态工具安装 hook
- 确保每个工具都兼容固定的 Go runtime；gopls v0.22 及以上版本要求 Go 1.26

### `uv-tools.txt`

```text
ruff==0.15.21
basedpyright==1.39.9
pre-commit==4.6.0
```

说明：

- `uv-tools.txt` 允许使用标准 Python requirement specifier
- 对变化较快、会直接影响诊断与本地自动化行为的 CLI 工具，优先固定版本

### `config.toml.tmpl`

```toml
[tools]
go = "1.25.12"
golangci-lint = "v2.12.2"
node = "24.18.0"
python = "3.13.14"
uv = "0.11.28"
```

## 10. helper script 职责

### `install-apt-packages`

- 仅在 Ubuntu / Debian / WSL 中运行
- 从 `bootstrap/manifests/` 中的 source-only manifest 路径读取 `apt-packages.txt`
- 通过 shared helper 统一预热 `sudo -v`，在权限不足时给出明确错误提示
- 使用非交互模式执行 `apt-get update` 与批量安装

### `install-brew-packages`

- 仅在 macOS 中运行
- 校验 `brew` 存在
- 从 `bootstrap/manifests/` 中的 source-only `Brewfile` 执行 `brew bundle`
- baseline CLI 工具保留在系统 `Brewfile`；已选择的 Ghostty/字体/OrbStack 组合保留在桌面 `Brewfile`；其他 GUI 应用放入用户自己的 `Brewfile.local`
- 系统 Brewfile 之后，仅在固定路径的本地 Brewfile 存在时安装它

### `install-maple-mono-font`

- 仅由受支持的 Ubuntu 桌面路径调用
- 从 `bootstrap/manifests/desktop/maple-mono-nf-cn.env` 读取固定版本的发布 URL 与 SHA-256 摘要
- 复用兼容的已有字体安装，避免制造副本
- 支持断点续传，校验摘要与所需 PostScript 名称，并且只替换带 baseline 所有权标记的目录
- 安装到 `${XDG_DATA_HOME:-$HOME/.local/share}/fonts` 并刷新 Fontconfig

### `install-oh-my-zsh-assets`

- 安装 shell 资产前校验 `zsh` 可用
- 确保 `oh-my-zsh` 位于 `$HOME/.oh-my-zsh`
- 从 `bootstrap/manifests/shell/oh-my-zsh-plugins.txt` 读取插件列表
- 通过 `git clone` / `git pull --ff-only` 管理插件
- 对已有本地改动的目录跳过更新，避免覆盖用户修改
- `dot_zshrc.tmpl` 使用同一份 manifest 生成启用的 oh-my-zsh 插件列表；`zsh-completions` 继续以 `fpath` 特殊处理，而不是加入 `plugins=()`

### `install-go-tools`

- 校验 `go` 可用
- 从 `bootstrap/manifests/` 中的 source-only manifest 路径读取 `go-tools.txt`
- 通过 `bootstrap/scripts/go-env.sh` 固定 Go 工具安装路径
- 在未显式覆盖时，将 `GOBIN` 默认设置为 `$HOME/go/bin`
- 执行 `go install`
- 如果清单中包含 `golangci-lint`，直接报错并要求改由 `mise` 管理

### `install-uv-tools`

- 从 `bootstrap/manifests/` 中的 source-only manifest 路径读取 `uv-tools.txt` 清单文件
- 按 manifest 中声明的 requirement 安装工具
- 使用重装模式确保版本变更在下一次 bootstrap 时生效
- 重复执行必须安全

## 11. PATH 与兼容性

dotfiles 需要保证：

- `mise` 已正确激活
- `~/.local/bin`和`~/bin`已进入 `PATH`

对于 Debian/Ubuntu 中的命名差异，可做最小兼容处理：

- `bash-completion` 这类 shell 启动时直接依赖的支持包，继续由系统包管理器提供
- `mise` 的 Bash 补全仅在已加载的 `bash-completion` helper 足够新时启用；Linux 下的 Zsh 补全在 bootstrap 阶段生成到用户 completion 目录
- `uv` 的 Bash 补全直接使用 `uv generate-shell-completion bash` 生成并注册；Zsh 补全在 `mise install` 后生成到用户 completion 目录
- `fzf` 优先使用 `fzf --bash` / `fzf --zsh`，旧版本回退到发行版提供的 completion 与 key-bindings 脚本
- `fd-find` 对应 `fd`
- `bat` / `batcat` 差异按需处理

不要引入复杂兼容层。

## 12. 实现约束（给 AI 编码工具）

实现时必须遵守：

1. 不要在 Linux / WSL 中引入 Homebrew
2. 不要替换 `chezmoi`
3. 不要引入 Nix、Ansible、Dev Container 等额外体系
4. 优先使用简单 Bash 脚本
5. 保持目录和职责边界清晰
6. 保持脚本可重复执行
7. OS 分支逻辑必须显式
8. 代码以可维护性优先，不要过度抽象

## 13. 验收标准

在一台全新机器上执行后，应满足：

1. `chezmoi apply` 成功
2. 系统工具安装完成
3. `mise` 安装并激活成功
4. 运行时安装完成
5. 生态工具安装完成
6. 新 shell 启动时无明显 `command not found` 错误
7. 重复执行 `chezmoi apply` 不会破坏环境

## 14. AI 实现任务清单

请按以下顺序落地：

1. 创建目录结构
2. 编写 `install-apt-packages`
3. 编写 `install-brew-packages`
4. 编写 `install-go-tools`
5. 编写 `install-uv-tools`
6. 编写 `.chezmoiscripts/*`
7. 编写 `bootstrap/manifests/system/*.txt` 与 `bootstrap/manifests/ecosystem/*.txt`
8. 编写独立的 `xdg_config/` source 与 `xdg_config/mise/config.toml.tmpl`
9. 编写 `README.md` 中的 bootstrap 使用说明

## 15. 最终方案摘要

最终采用的方案是：

- `chezmoi` 负责配置和编排
- 独立的 chezmoi 子 source 将配置文件直接管理到绝对路径 `XDG_CONFIG_HOME` 下，默认值为 `$HOME/.config`
- macOS 用 Homebrew 管系统工具
- 可选 vendor 应用的 shell 与 SSH 初始化保留在用户自有的本地 overlay 中
- Ubuntu / Debian / WSL 用 `apt` 管系统工具
- `mise` 管语言运行时
- 语言生态工具用各自原生方式安装
- 整体方案必须轻量、显式、幂等、易维护
