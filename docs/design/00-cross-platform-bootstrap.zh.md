# 技术设计：基于 chezmoi 的跨平台开发环境引导方案

## 1. 目标

为以下环境提供一套可重复执行、可维护的开发环境初始化方案：

- macOS
- Ubuntu / Debian
- Arch Linux 家族
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
   - Arch Linux 家族使用 `pacman`
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
- `build-essential`（Debian / Ubuntu）或 `base-devel`（Arch Linux）

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
│   ├── run_onchange_after_55-install-shell-completions.sh.tmpl
│   └── run_onchange_after_60-check.sh.tmpl
├── bootstrap/
│   ├── manifests/
│   │   ├── desktop/
│   │   │   ├── apt-packages.txt
│   │   │   ├── Brewfile
│   │   │   ├── maple-mono-nf-cn.env
│   │   │   └── pacman-packages.txt
│   │   ├── shell/
│   │   │   ├── completions.txt
│   │   │   └── oh-my-zsh-plugins.txt
│   │   ├── system/
│   │   │   ├── apt-packages.txt
│   │   │   ├── Brewfile
│   │   │   └── pacman-packages.txt
│   │   ├── ecosystem/
│   │   │   ├── go-tools.txt
│   │   │   └── uv-tools.txt
│   │   └── local-overlays.tsv
│   └── scripts/
│       ├── common.sh
│       ├── install-apt-packages.sh
│       ├── install-brew-packages.sh
│       ├── install-maple-mono-font.sh
│       ├── install-go-tools.sh
│       ├── install-oh-my-zsh-assets.sh
│       ├── install-pacman-packages.sh
│       ├── install-shell-completions.sh
│       ├── install-uv-tools.sh
│       ├── local-overlays.sh
│       ├── run-smoke-tests.sh
│       ├── uninstall.sh
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
9. `run_onchange_after_55-install-shell-completions.sh.tmpl`
10. `run_onchange_after_60-check.sh.tmpl`

要求：

- 对于 `run_onchange_` 脚本，必须利用 template hash（比如 `{{ include "bootstrap/manifests/system/apt-packages.txt" | sha256sum }}`）作为触发器，确保清单变更时能重新执行
- bootstrap 的 manifest 与脚本都放在 source 根目录下的 `bootstrap/`，并通过 `.chezmoiignore` 保持 source-only；运行时由 `.chezmoiscripts` 基于 `{{ .chezmoi.sourceDir }}` 调用
- 所有脚本必须幂等
- 使用 `bash` 和 `set -euo pipefail`
- 避免不必要的交互式提示（如 apt 或 pacman 询问）；Linux / WSL 的 apt 与 pacman 路径应先统一执行 `sudo -v`，并以非交互模式运行安装命令
- 失败时输出清晰错误信息

## 7. 平台策略

### macOS

- 系统工具使用 Homebrew
- 通过 `Brewfile` 管理包清单
- 使用 `brew bundle` 安装
- 选择 `desktopBaseline` 后，从独立的桌面 `Brewfile` 一起安装 Ghostty、Maple Mono NF CN 与 OrbStack
- 安装 OrbStack cask，但不声称首次启动设置、Docker runtime 状态或许可证已经就绪
- shell 框架和插件不走 Homebrew，改由独立 shell 资产脚本通过 `git clone` 管理

### Ubuntu / Debian / WSL

- 系统工具只使用 `apt`
- 包清单存放于 `apt-packages.txt`
- 不引入 Homebrew
- 当 shell 层依赖 zsh 时，通过 `apt` 安装 `zsh`
- 复用与 macOS 相同的 shell 资产脚本安装 `oh-my-zsh` 与插件
- 只有非 WSL 的 Ubuntu 26.04+ 参与已选择的桌面基线：Ghostty 通过 apt 安装，固定并校验过的 Maple Mono 归档安装到用户字体目录
- 仅在受支持的 Ubuntu 桌面基线保留 Ghostty 未遵守显式字体设置的 Fontconfig 补丁，同时匹配 `prgname=ghostty` 和 `monospace`；其他应用和平台保留自己的字体偏好。其他环境或关闭桌面基线时模板渲染为空，chezmoi 不管理该文件；字体检查验证已注册的字体样式，不要求改变系统等宽字体

### Arch Linux 家族

- 系统工具只使用 `pacman`
- 包清单存放于 `pacman-packages.txt`
- 通过 `.chezmoi.osRelease.idLike` 识别衍生发行版
- 使用 `pacman -S --needed` 基于已同步的数据库安装；绝不单独用 `-Sy` 刷新，因为完整系统升级是单独的用户操作
- 当 shell 层依赖 zsh 时，通过 `pacman` 安装 `zsh`
- 复用与 macOS 相同的 shell 资产脚本安装 `oh-my-zsh` 与插件
- 非 WSL 的 Arch 参与已选择的桌面基线：Ghostty 与 Fontconfig 通过 pacman 安装，固定并校验过的 Maple Mono 归档安装到用户字体目录；Ubuntu 的 Fontconfig 补丁不适用

### WSL

- 视为 Linux 子类处理
- 只管理 WSL 内部环境
- 不安装桌面基线
- 不负责 Windows 原生软件安装

## 8. 平台识别

直接使用 `chezmoi` 原生模板变量来做系统级别区分，不再维护额外的 `detect-platform`：

- 区分操作系统：`{{ if eq .chezmoi.os "darwin" }}` 或 `{{ if eq .chezmoi.os "linux" }}`
- 通过 `.chezmoi.osRelease.id` 与 `.chezmoi.osRelease.versionID` 区分 Linux 发行版及版本；通过 `.chezmoi.osRelease.idLike` 将衍生发行版路由到对应的包管理器
- 检查 `.chezmoi.kernel.osrelease` 是否包含 `microsoft` 来识别 WSL；无需持久化额外的平台标志
- 将 macOS、非 WSL 的 Arch Linux 家族，或 `versionID >= 26.04` 且非 WSL 的 Ubuntu，视为支持自动安装的桌面平台
- `XDG_CURRENT_DESKTOP`、`WAYLAND_DISPLAY` 与 `DISPLAY` 只用于决定受支持 Linux 桌面上首次提示的默认值；用户的 `desktopBaseline` 答案会持久化，日常 apply 不再重新推断

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

### `pacman-packages.txt`

- 使用与 `apt-packages.txt` 相同的行格式
- 列出 Arch 包名；安装器会拒绝不是合法 pacman 包名的条目

### `go-tools.txt`

当前条目见 [`bootstrap/manifests/ecosystem/go-tools.txt`](../../bootstrap/manifests/ecosystem/go-tools.txt)。

说明：

- `go-tools.txt` 直接使用 `go install` 的 `module@version` 语法
- 固定精确版本，让全新安装与已有机器收敛到相同结果
- 有意升级版本，使 manifest hash 能触发生态工具安装 hook
- 确保每个工具都兼容固定的 Go runtime；gopls v0.22 及以上版本要求 Go 1.26

### `uv-tools.txt`

当前条目见 [`bootstrap/manifests/ecosystem/uv-tools.txt`](../../bootstrap/manifests/ecosystem/uv-tools.txt)。

说明：

- `uv-tools.txt` 允许使用标准 Python requirement specifier
- 对变化较快、会直接影响诊断与本地自动化行为的 CLI 工具，优先固定版本

### `config.toml.tmpl`

- [`xdg_config/mise/config.toml.tmpl`](../../xdg_config/mise/config.toml.tmpl) 在 `[tools]` 表中固定每个运行时与二进制分发工具的版本
- 运行时、生态工具与补全 hook 都包含它的 hash，因此修改它会重新运行这些 hook

## 10. helper script 职责

### `install-apt-packages`

- 仅在 Ubuntu / Debian / WSL 中运行
- 从 `bootstrap/manifests/` 中的 source-only manifest 路径读取 `apt-packages.txt`
- 通过 shared helper 统一预热 `sudo -v`，在权限不足时给出明确错误提示
- 使用非交互模式执行 `apt-get update` 与批量安装

### `install-pacman-packages`

- 仅在 Arch Linux 家族中运行
- 从 `bootstrap/manifests/` 中的 source-only manifest 路径读取 `pacman-packages.txt`
- 调用 pacman 前校验每个包名，并通过 shared helper 预热 `sudo -v`
- 基于已有数据库执行一次批量的 `pacman -S --needed --noconfirm`，并传递其失败状态

### `install-brew-packages`

- 仅在 macOS 中运行
- 校验 `brew` 存在
- 从 `bootstrap/manifests/` 中的 source-only `Brewfile` 执行 `brew bundle`
- baseline CLI 工具保留在系统 `Brewfile`，已选择的 Ghostty/字体/OrbStack 组合保留在桌面 `Brewfile`；无关 GUI 应用不属于本仓库的引导契约

### `install-maple-mono-font`

- 仅由受支持的 Linux 桌面路径（Arch Linux 家族与 Ubuntu）调用
- 通过 `common.sh` 中的共享加载函数，从 `bootstrap/manifests/desktop/maple-mono-nf-cn.env` 读取字体族、所需 PostScript 字面、固定版本的发布 URL 与 SHA-256 摘要；同一份清单也供环境检查使用，并经由 `xdg-config.sh` 作为模板数据传给 Ghostty 与 Fontconfig 模板
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

### `install-shell-completions`

- 读取 `bootstrap/manifests/shell/completions.txt`，每行声明一个命令以及以逗号分隔、需要生成补全的平台（`linux`、`darwin`）；当平台的包管理器已经提供补全时不列出该平台
- 按平台应用统一的 shell 策略：Linux 生成 Bash 与 Zsh 资产，macOS 仅生成 Zsh 资产
- 各命令的生成适配器保留在脚本中，因为各 CLI 通过不同的子命令或参数暴露补全生成；`bat` 在 Arch 上复制包自带的原生补全，在 Debian 上包装包自带的 `batcat` 补全，而不运行生成器
- 以原子方式写入每个资产，生成失败时保留先前有效的文件
- 为每个生成文件写入稳定的归属标记（Zsh 文件放在 `#compdef` 之后）；所有当前条目安装成功后，清理两个补全目录中不再被当前条目指向的已标记文件，绝不删除未标记文件，也不跟随符号链接
- `install`、`check`、`list` 共用同一份清单；`check` 将过时的归属文件报告为 stale，`list` 在当前目标之后附加它们，`uninstall.sh` 通过 `list` 枚举资产

### `install-go-tools`

- 校验 `go` 可用
- 从 `bootstrap/manifests/` 中的 source-only manifest 路径读取 `go-tools.txt`
- 通过 `bootstrap/scripts/common.sh` 中的 `setup_go_env` 固定 Go 工具安装路径
- 在未显式覆盖时，将 `GOBIN` 默认设置为 `$HOME/go/bin`
- 要求每一项都固定为精确的 `module@vX.Y.Z` 版本，否则在安装任何工具之前直接失败
- 每次运行都安装全部工具：hook 只在输入变化时运行，Go 升级后必须重新构建工具，未变化的工具由 Go 构建缓存保证速度
- 工具归属由声明它的清单决定：mise 配置负责 `golangci-lint` 等二进制分发工具，`go-tools.txt` 负责 `go install` 工具

### `install-uv-tools`

- 从 `bootstrap/manifests/` 中的 source-only manifest 路径读取 `uv-tools.txt` 清单文件
- 按 manifest 中声明的 requirement 安装工具
- 已安装版本与固定版本一致时跳过，除非设置 `DOTFILES_FORCE_REINSTALL=1`
- 已安装工具的环境解释器缺失，或解释器版本与环境记录的版本不一致时，重建该工具；先卸载再安装，因为 `uv tool install --reinstall` 会保留过期的环境
- mise 配置变化时重新执行，因为这些工具运行在 mise 管理的 Python 上
- 重复执行必须安全

### `run_onchange_after_60-check`

- 复用安装器消费的同一份清单，而不是维护第二份硬编码工具列表
- 用 `dpkg-query` 校验 apt 清单，用 `pacman -Q` 校验 pacman 清单，用 `brew bundle check` 校验 Brewfile，用 `mise ls --current --missing` 校验 mise 配置
- 按二进制名称检查生态工具清单，报告不再运行在构建时 Python 上的 uv 工具环境，通过安装器的 `check` 动作检查补全清单，并在 Linux 上通过 Fontconfig、在 macOS 上通过用户字体目录检查字体清单声明的字体族与字面
- 用 `mise current` 输出 mise 管理的工具链，使摘要跟随配置变化

## 11. PATH 与兼容性

dotfiles 需要保证：

- `mise` 已正确激活
- `~/.local/bin`和`~/bin`已进入 `PATH`

对于 Debian/Ubuntu 中的命名差异，可做最小兼容处理：

- `bash-completion` 这类 shell 启动时直接依赖的支持包，继续由系统包管理器提供
- CLI 官方提供的补全在 bootstrap 阶段统一生成到标准 XDG Bash / Zsh 目录；shell 启动时只负责发现
- Linux / WSL 的 Bash 提供完整补全，macOS Bash 刻意只保留有限支持
- macOS 显式加入 Homebrew 标准 site-functions 目录，并将 `zsh-completions` 放在 `fpath` 最后作为 fallback
- 直接使用当前的 `fzf --bash` / `fzf --zsh` 集成
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

## 14. 最终方案摘要

最终采用的方案是：

- `chezmoi` 负责配置和编排
- 独立的 chezmoi 子 source 将配置文件直接管理到绝对路径 `XDG_CONFIG_HOME` 下，默认值为 `$HOME/.config`
- macOS 用 Homebrew 管系统工具
- 可选 vendor 应用的 shell 与 SSH 初始化保留在用户自有的本地 overlay 中
- Ubuntu / Debian / WSL 用 `apt` 管系统工具
- Arch Linux 家族用 `pacman` 管系统工具
- `mise` 管语言运行时
- 语言生态工具用各自原生方式安装
- 整体方案必须轻量、显式、幂等、易维护
