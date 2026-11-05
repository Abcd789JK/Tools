# 变更日志

本文件记录 `install.sh` 与 `mihomo.sh` 的用户可见变化。两个脚本共用同一套交互规范与
工具函数，因此按统一版本号维护；仅当脚本自身行为、参数或输出契约发生变化时才升级版本。

## 双通道版本策略

项目同时维护两个发布通道，两边的代码主体完全相同，差异只有仓库路径
（`Script/mihomo/` 与 `Script/mihomo_beta/`）和版本号：

| 通道 | 本地目录 | 发布路径 | 当前版本 |
| --- | --- | --- | --- |
| beta | `mihomo_beta/` | `Script/mihomo_beta/` | 2.5.0 |
| 正式版 | `mihomo/` | `Script/mihomo/` | 2.0.0（待同步） |

维护规则：

1. **只改 beta。** 日常开发、修复、试验全部在仓库根目录的两个脚本上进行。
2. **验证后再同步。** beta 测试通过并由维护者确认后，才把改动同步到 `mihomo/`。
3. **版本号恒低。** 正式版版本号始终低于 beta 一个 MINOR（2.0.0 < 2.1.0）。
4. **差异白名单。** 两边的差异只允许是版本号、仓库路径（beta 含 `_beta`，正式版不含）
   和正式版文件头的同步基线注释；出现其他差异即为同步事故。
5. 正式版文件头下方保留 `# 正式版同步基线：beta vX.Y.Z` 注释，用于核对同步来源。

## 2026-11-03 — 2.0.0（正式版通道）

与 beta 2.1.0 内容一致，仅版本号与仓库路径不同。同时修正了两个脚本版本号长期不一致的
历史问题（原 mihomo.sh 1.5.6、install.sh 1.7.11）。下列 2.1.0 的整改项、安全修复与
不兼容变更同样适用于正式版。

## 2026-11-04 — 2.5.0（beta 通道）

### Added

- 新增 `text_char_width` 与 `print_wrapped_text`：按 Unicode 终端显示宽度排版标题，
  全角/中文与常见表情按 2 列、组合符号按 0 列。纯 Bash 算术实现，不依赖 locale、
  外部命令或第三方宽度工具，也不按字节数截断文本。

### Changed

- 安装脚本标题的用途说明缩进由 2 空格改为 4 空格（AGENTS.md 10.6.6 第 10 条），
  名称行仍为 2 空格；用途说明超宽时自动换行，每行（含缩进）不超过 50 列。
- 换行只落在空格、ASCII 标点与汉字边界，不拆英文单词；单个超宽单词按字符边界硬断。
- 修正两脚本头注释：共用函数数量 68 → 65，并注明标题排版函数仅供非管理脚本使用。

## 2026-11-04 — 2.4.0（beta 通道）

### Changed

- 菜单第 12 项文案还原为 `更新脚本`，不再在菜单里重复显示当前版本（版本已在页头展示）。
- 更新成功后不再提示“下次启动生效”：等待 3 秒后直接以新脚本替换当前进程，
  菜单、函数与版本号一次性刷新，避免新旧代码混跑。

### Notes

- 替换进程前会先回收本次的临时目录并解除 EXIT Trap（`exec` 不会触发 Trap）。
- `exec` 失败时保留当前进程并提示手动运行路径，不会让终端直接断掉。

## 2026-11-04 — 2.3.1（beta 通道）

### Changed

- 本地目录结构调整为 `mihomo_beta/`（beta）与 `mihomo/`（正式版）并列。

### Fixed

- `update_shell` 不再硬性要求 `jq`：缺少 `jq` 或 GitHub 接口不可达时，改为提示后用分支地址
  下载，而不是直接中止更新。`jq` 仅用于把下载地址锁定到具体提交。

### 升级说明（重要）

从 1.7.x 及更早版本升级到 2.x **无法通过菜单「更新管理脚本」完成**。旧版用
`sed -n 's/^SCRIPT_VERSION=...'` 解析候选脚本版本，而 2.x 按规范改为
`readonly SCRIPT_VERSION="x.y.z"`，旧逻辑解析为空后会报“无法解析新脚本版本号，已取消更新”。

一次性升级办法（任选其一，均无需重装内核）：

```bash
# 方式一：重新执行安装脚本（会同时刷新管理脚本）
curl -fsSL https://raw.githubusercontent.com/Abcd789JK/Tools/main/Script/mihomo_beta/install.sh | bash

# 方式二：只替换管理脚本
tmp=$(mktemp) && curl -fsSL -o "$tmp" https://raw.githubusercontent.com/Abcd789JK/Tools/main/Script/mihomo_beta/mihomo.sh \
    && bash -n "$tmp" && install -m 755 "$tmp" /usr/bin/mihomo && rm -f "$tmp"
```

升级到 2.x 之后，后续版本可正常使用菜单更新。

## 2026-11-03 — 2.3.0（beta 通道）

对齐 AGENTS.md 新增的 10.6.4、10.6.5、10.6.6 三节要求。

### Added

- 两脚本新增脚本元数据常量：`SCRIPT_NAME`、`SCRIPT_AUTHOR`（仅管理脚本）、
  `SCRIPT_DESCRIPTION`（仅非管理脚本）、`USAGE_NOTE_1`、`USAGE_NOTE_2`（仅管理脚本）。
- `install.sh` 的 `print_header` 更名为 `print_script_header`，按非管理脚本模板输出。

### Changed

- `install.sh` 启动标题改为：双线分隔线 → `脚本名称  v版本号` → 用途说明 → 双线分隔线；
  删除标题中的“安装目录”行，标题不再包含任何文件系统路径。
- `mihomo.sh` 页头改为：双线 → 名称+版本 → 作者 → 单线 → 使用说明 → 单线，
  使用说明并入页头，菜单内不再重复输出。
- 安装完成摘要的“常用命令”改为“后续操作”，只保留 `mihomo` 进入交互菜单一项。
- 标题实现按 10.6.6 参考实现对齐：名称与版本共用青色分段着色，用途说明使用默认色；
  `mihomo.sh` 页头的版本号由蓝色改为青色，与 10.6.2 的标题语义一致。

### Removed

- `mihomo.sh` 移除全部命令行子命令（`status`、`start`、`stop`、`restart`、`enable`、
  `disable`、`logs`、`config`、`secret`、`panel`、`log-clean`、`update`、`switch`、
  `install`、`uninstall`、`update-shell`、`version`、`help`）及 `usage()`。
  按 10.6.5 第 3 条，管理脚本的管理操作统一由交互菜单提供。
- 删除仅服务于子命令的 `status_cmd`、`secret_cmd`、`panel_cmd` 三个包装函数。

### 不兼容变更

- `mihomo` 不再接受任何命令行参数。带参数运行（含 `mihomo status`、`mihomo --version`）
  会输出提示并以退出码 2 结束。对应功能全部保留在主菜单中：
  状态面板在菜单底部常驻显示，版本号显示在页头，配置/密钥/面板/日志/更新均在菜单选项内。

## 2026-11-03 — 2.2.0（beta 通道）

### Changed

- `install.sh` 不再生成 `/var/log/mihomo-install.log`：安装页头、完成摘要、`--help`
  都不再展示日志文件路径，`die` 也不再提示“详细日志”。
- 安装期间的错误、警告与进度全部直接输出到终端 stderr，终端输出即唯一诊断依据。
- 下载源地址由落盘日志改为 `MIHOMO_DEBUG=1` 时才输出的 `[DEBUG]` 行。

### Removed

- `install.sh` 中的 `LOG_FILE` 常量、`log_trim`、`log_append` 三个日志落盘实现。

### 影响

- 已安装机器的 `/var/log/mihomo-install.log` 不再产生新内容；`mihomo.sh` 的
  `log-clean` 仍会清理这份历史残留，`mihomo.sh` 自身的运行日志不受影响。

## 2026-11-03 — 2.1.0（beta 通道）

版本号由 1.8.0 提升到 2.1.0：本次改动包含不兼容变更（见下），按 SemVer 应以 2.0.0 为
正式版版本线，beta 作为先行版取 2.1.0。

### Added

- `mihomo.sh` 新增静态版本解析与比较函数：`is_semver`、`compare_semver`、
  `extract_script_version`、`extract_header_version`、`fetch_pinned_commit`。
- `mihomo.sh` 更新管理脚本时优先把下载地址锁定到远端具体提交，避免制品与版本错位。
- 新增 `MIHOMO_DEBUG=1` 调试日志开关，输出 `[DEBUG]` 级别信息。

### Changed

- 日志函数统一改名为 `log_info`、`log_success`、`log_warn`、`log_error`、`log_debug`，
  并统一带 `[INFO]`、`[ OK ]`、`[WARN]`、`[ERROR]`、`[DEBUG]` 标签。
- 所有日志改为写入 stderr，stdout 只保留菜单、状态面板与命令结果，便于管道消费。
- 分隔线长度由 40 字符统一为 50 字符，`HR`、`HR_EQ` 与 `hr()`、`hreq()`、`kv()` 输出
  格式与项目规范一致。
- 文件头分隔线补足为 50 字符，`author` 修正为 `ChatGPT JK789`，`desc` 改为具体用途描述。
- 启动顺序调整为：解释器守卫 → `set -Eeuo pipefail` → Root 检查 → `readonly SCRIPT_VERSION`。
- 颜色初始化收敛到 `setup_colors()`；颜色统一由 `NO_COLOR`（含空值）与 `TERM=dumb` 控制，
  并要求 stdout、stderr 同为终端才着色。
- `mihomo.sh` 菜单项改为「更新管理脚本（当前版本：x.y.z）」，与「更新 mihomo」明确区分。
- `atomic_install` 改用同目录 `mktemp` 生成唯一临时文件，替换过程中不再使用固定名称。

### Fixed

- 修复日志落盘时的多重 stderr 重定向竞争（ShellCheck SC2261）。
- 修复 `install.sh` 中未被使用的 IPv6 探测代码与 `ipv6` 变量。
- 修复 `install.sh` 自删除指纹仍按旧声明格式匹配、导致安装脚本无法自动清理的问题。
- 修复若干把中间状态（如「获取软件版本」「匹配资产」「发现新版本」）标记为成功的问题。

### Security

- `mihomo.sh` 更新管理脚本时不再执行刚下载的候选脚本（原实现以 Root 运行
  `bash <候选脚本> version`）。现在只做静态检查：`bash -n`、唯一 `SCRIPT_VERSION`
  声明、文件头 `ver` 一致性、SemVer 比较；替换后再次静态复核版本，复核失败自动回滚。
- 更新流程拒绝降级：远端版本低于本地时中止并报告。
- 更新所用临时文件改为在本次创建的私有临时目录中生成，退出时统一清理。

### 不兼容变更

- `--help`、`--version`（`mihomo.sh` 的 `help`、`version` 子命令）现在同样要求 Root 身份，
  非 Root 调用会被拒绝。这是项目规范对统一 Root 启动策略的要求。
- 日志输出由 stdout 改为 stderr，标签格式由纯文本改为 `[INFO]` 等固定前缀；依赖旧输出格式
  解析的包装脚本需要相应调整。
- 菜单与状态面板分隔线宽度由 40 字符改为 50 字符，界面排版会随之变化。
- 未知参数 / 未知子命令的退出码由 1 调整为 2（参数错误约定）。

### 迁移说明

- 无需迁移配置文件或订阅数据；`/root/mihomo/config.yaml` 与订阅格式保持不变。
- 若存在依赖旧日志行的外部脚本，请改为匹配 `^\[(INFO| OK |WARN|ERROR)\]` 或读取日志文件
  `/var/log/mihomo.log`、`/var/log/mihomo-install.log`。
- 回滚方式：`cp -f /usr/bin/mihomo.bak /usr/bin/mihomo`（升级时自动生成的备份）。
