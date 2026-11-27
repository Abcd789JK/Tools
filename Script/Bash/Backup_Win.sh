#!/usr/bin/env bash

# --------------------------------------------------
# name   : Backup_Win.sh
# desc   : Windows 版 GitHub 仓库自动同步脚本，拉取更新并提交本地变更
# date   : 2026-11-27 18:48:34
# author : ChatGPT JK789
# ver    : 0.9.5
# --------------------------------------------------

# 解释器守卫：必须早于 set -u 等 Bash 专有选项，给出可读错误提示。
if [ -z "${BASH_VERSION:-}" ]; then
    printf '%s\n' '错误：请使用 bash 运行本脚本' >&2
    exit 1
fi

# 启用 Bash 严格模式。
set -Eeuo pipefail

# 要求 Bash 4.0+（使用 [[ ]]、local、read -d '' 等特性）。
if (( BASH_VERSINFO[0] < 4 )); then
    printf '[ERROR] 需要 Bash 4.0 及以上版本，当前版本：%s\n' "$BASH_VERSION" >&2
    exit 1
fi

# 平台检测：MINGW*/MSYS*/CYGWIN* 为 Windows Git Bash。
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) IS_WIN=1 ;;
    *)                    IS_WIN=0 ;;
esac

# 本脚本仅支持 Windows Git Bash；原生 Linux 请使用 Backup.sh。
if (( IS_WIN == 0 )); then
    printf '[ERROR] 本脚本仅支持 Windows Git Bash 环境，当前系统不匹配。\n' >&2
    exit 1
fi

# 声明当前脚本版本。
readonly SCRIPT_VERSION="0.9.5"

# 脚本加载含凭据的 .env，收紧默认文件权限，避免新建文件被 group/other 读取。
umask 077

# ==================================================
# 全局常量与默认配置
# ==================================================

readonly SCRIPT_NAME="GitHub 仓库本地变更同步脚本"
readonly SCRIPT_AUTHOR="ChatGPT JK789"
readonly SCRIPT_DESCRIPTION="拉取 GitHub 仓库更新并检测本地变更，自动提交推送"

# 交互菜单标题（仅 --menu 模式显示）。
readonly MENU_NAME="GitHub 仓库同步管理脚本"

# 分隔线固定为 50 个可见 ASCII 字符。
readonly HR="--------------------------------------------------"
readonly HR_EQ="=================================================="

# 仓库操作锁的失效时间（秒）：超过该时长视为残留锁，可安全清理。
readonly STALE_LOCK_SECONDS=3600

# 脚本所在目录，用于定位同目录下的 .env 配置文件。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# 默认环境变量文件路径（与脚本同目录）。
readonly DEFAULT_ENV_FILE="${SCRIPT_DIR}/.env"

# ACCOUNTS 行的第 4 段可选参数解析结果（由 parse_repo_options 写入，每个仓库重置）。
# REPO_EXPECT_BRANCH：锁定分支，非空时仓库必须停在该分支上，否则整仓跳过。
# REPO_RELEASE_BRANCH：发布目标分支，非空表示该仓库启用发布管理。
# REPO_IDENTITY_MODE：身份策略，keep 表示保留仓库已配置的 Git 身份。
REPO_EXPECT_BRANCH=''
REPO_RELEASE_BRANCH=''
REPO_IDENTITY_MODE=''

# ACCOUNTS 解析后的仓库条目（由 load_repo_entries 填充，下标一一对应）。
# REPO_ENTRY_NAME 由远程地址解析得到；别名与仓库名都允许重复，仓库身份由「远程地址 + 本地目录」共同确定。
REPO_ENTRY_ALIAS=()
REPO_ENTRY_NAME=()
REPO_ENTRY_URL=()
REPO_ENTRY_DIR=()
REPO_ENTRY_BRANCH=()
REPO_ENTRY_RELEASE=()
REPO_ENTRY_IDENTITY=()
REPO_ENTRY_DUPLICATE=()

# 菜单显示文本（由 build_entry_labels 填充，重复展示时自动追加本地目录以区分）。
ENTRY_LABEL=()

# 当前持有的仓库锁目录，空表示未持锁；由 trap 在退出时释放。
REPO_LOCK_DIR=''

# 菜单输入结果（由 read_menu_choice 写入，避免提示文本被命令替换吞掉）。
MENU_INPUT=''

# ==================================================
# 颜色初始化与日志函数
# ==================================================

COLOR_RESET=''
COLOR_RED=''
COLOR_GREEN=''
COLOR_YELLOW=''
COLOR_BLUE=''
COLOR_CYAN=''
COLOR_GRAY=''

# 根据终端能力和 NO_COLOR 设置日志颜色。
setup_colors() {
    if [[ -t 1 && -t 2 && -z "${NO_COLOR+x}" && -n "${TERM:-}" && "$TERM" != 'dumb' ]]; then
        COLOR_RESET=$'\033[0m'
        COLOR_RED=$'\033[31m'
        COLOR_GREEN=$'\033[32m'
        COLOR_YELLOW=$'\033[33m'
        COLOR_BLUE=$'\033[34m'
        COLOR_CYAN=$'\033[36m'
        COLOR_GRAY=$'\033[90m'
    fi
}

log_info() {
    printf '%s[INFO]%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$*" >&2
}

log_success() {
    printf '%s[ OK ]%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*" >&2
}

log_warn() {
    printf '%s[WARN]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2
}

log_error() {
    printf '%s[ERROR]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
}

log_debug() {
    if [[ "${APP_DEBUG:-0}" == '1' ]]; then
        printf '%s[DEBUG]%s %s\n' "$COLOR_GRAY" "$COLOR_RESET" "$*" >&2
    fi
}

# 打印单线分隔线。
hr() {
    printf '%s\n' "${COLOR_BLUE}${HR}${COLOR_RESET}"
}

# 打印双线分隔线。
hreq() {
    printf '%s\n' "${COLOR_BLUE}${HR_EQ}${COLOR_RESET}"
}

# 打印"标签: 值"行；标签按 6 个显示列对齐（与 [INFO]/[ OK ] 等日志级别标签同宽），
# 再补 1 个空格让正文与日志正文同从第 8 列开始。
kv() {
    local label="${1:?kv 缺少标签参数}"
    local value="${2-}"

    printf '%s%s%s %s\n' \
        "$COLOR_CYAN" "$label" "$COLOR_RESET" "$value"
}

# 去掉字符串首尾空白（不用 extglob，避免依赖 shopt 状态）。
# 参数：$1 原始字符串。stdout：修剪后的结果。
trim() {
    local value="${1-}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# 打印启动横幅：双线 → 名称/作者（标签青色）→ 单线 → 说明（标签青色）→ 说明文本 → 双线。
print_script_header() {
    hreq
    printf '%s名  称%s %s v%s\n' "$COLOR_CYAN" "$COLOR_RESET" "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf '%s作  者%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$SCRIPT_AUTHOR"
    hr
    printf '%s说  明%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$SCRIPT_DESCRIPTION"
    hreq
}

# ==================================================
# 依赖检查与帮助信息
# ==================================================

# 检查指定命令是否已安装。
# 参数：$1... 表示一个或多个命令名称。
# 返回：全部命令均存在时返回 0；任意一个缺失时返回非 0。
check_dependencies() {
    local dependency_name

    for dependency_name in "$@"; do
        if ! command -v "$dependency_name" >/dev/null 2>&1; then
            log_error "缺少依赖：$dependency_name"
            return 1
        fi
    done
}

# 显示帮助信息。
show_help() {
    cat <<EOF
用法：bash ${0} [选项]

选项：
  -h, --help       显示此帮助信息并退出
      --version    显示脚本版本并退出
      --menu       进入交互式管理菜单

说明：
  无参数运行时按配置批量同步全部仓库：拉取远程更新，检测到本地变更后自动
  提交并推送，同时更新脚本文件头中的日期；不弹出菜单、不等待输入，可供定时任务调用。
  带 --menu 时进入交互式菜单，可同步全部仓库、从列表中选择单个仓库同步，
  或将指定仓库的源分支发布到目标分支。

配置（同目录 .env 中的 ACCOUNTS，每行一个仓库）：
  别名,远程地址,本地目录[,可选参数]

  仓库数量不限，别名允许重复；仓库名称从远程地址解析，
  仓库身份由「远程地址 + 本地目录」确定，两项都相同才算重复配置。

  可选参数用分号分隔：
    branch=<分支名>    日常同步分支：仓库未停在该分支上时整仓跳过，
                       拉取与推送也只针对该分支
    release=<分支名>   发布目标分支：与 branch 同时配置后该仓库启用发布管理，
                       可将源分支最新提交快进发布到目标分支
    identity=keep      保留仓库已配置的 Git 身份，不改成 Bot

  示例：别名,git@github.com:owner/repo.git,/path/to/repo,branch=dev;release=stable;identity=keep

注意：
  本地存在未推送提交时，该仓库会停止自动提交与推送，请先手动检查处理。
  发布只做快进更新，不修改、不删除源分支，也不使用强制推送。
EOF
}

# ==================================================
# 通用工具函数
# ==================================================

# 读取仓库当前分支名。
# 参数：$1 仓库目录。stdout：分支名；游离 HEAD 或空仓库时输出为空。
current_branch() {
    local repo_dir="${1:?缺少仓库目录}"
    git -C "$repo_dir" symbolic-ref --short -q HEAD 2>/dev/null || printf ''
}

# 读取 origin 远程地址。
# 参数：$1 仓库目录。stdout：远程地址；未配置时输出为空。
remote_url() {
    local repo_dir="${1:?缺少仓库目录}"
    git -C "$repo_dir" remote get-url origin 2>/dev/null || printf ''
}

# 归一化仓库地址/目录，用于判断"配置地址与 origin 地址是否同一个仓库"。
# 处理三类无害差异：末尾斜杠、.git 后缀、Windows 本地路径的写法
# （Git for Windows 会把 /d/foo 存成 D:/foo，两者指向同一目录）。
# 参数：$1 原始字符串。stdout：归一化结果。
normalize_repo_ref() {
    local value="${1-}"

    value="${value//\\//}"
    while [[ "$value" == */ ]]; do
        value="${value%/}"
    done
    [[ "$value" == *.git ]] && value="${value%.git}"
    value="${value,,}"

    # 仅对本地盘符路径归一：/d/foo 与 d:/foo 视为同一路径；ssh/https 地址不受影响。
    if [[ "$value" =~ ^/([a-z])/(.*)$ ]]; then
        value="${BASH_REMATCH[1]}:/${BASH_REMATCH[2]}"
    fi

    printf '%s' "$value"
}

# 判断远程跟踪分支是否存在。
# 参数：$1 仓库目录，$2 分支名。返回：存在返回 0，否则返回 1。
remote_branch_exists() {
    local repo_dir="${1:?缺少仓库目录}"
    local branch="${2-}"

    [[ -n "$branch" ]] || return 1
    git -C "$repo_dir" rev-parse --verify --quiet "refs/remotes/origin/${branch}" >/dev/null 2>&1
}

# 判断本地分支是否存在。
# 参数：$1 仓库目录，$2 分支名。返回：存在返回 0，否则返回 1。
local_branch_exists() {
    local repo_dir="${1:?缺少仓库目录}"
    local branch="${2-}"

    [[ -n "$branch" ]] || return 1
    git -C "$repo_dir" rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null 2>&1
}

# 输出提交身份参数：未配置 keep 时使用 GitHub Actions 机器人身份。
# 参数：$1 身份策略。stdout：每行一个参数，供 git 命令在本次提交前临时使用。
# 说明：只对单次提交生效，不写入仓库或全局 Git 配置（GIT_AGENTS 第五节）。
git_identity_args() {
    local identity_mode="${1-}"

    [[ "$identity_mode" == 'keep' ]] && return 0
    printf '%s\n' \
        '-c' 'user.name=github-actions[bot]' \
        '-c' 'user.email=41898282+github-actions[bot]@users.noreply.github.com'
}

# 按配置身份执行 git commit，避免持久化修改仓库 Git 配置。
# 参数：$1 仓库目录，$2 身份策略，其余参数原样传给 git commit。
run_git_commit() {
    local project_dir="${1:?缺少仓库目录}"
    local identity_mode="${2-}"
    shift 2

    local -a identity_args=()
    mapfile -t identity_args < <(git_identity_args "$identity_mode")

    if (( ${#identity_args[@]} > 0 )); then
        git -C "$project_dir" "${identity_args[@]}" commit "$@"
    else
        git -C "$project_dir" commit "$@"
    fi
}

# 校验 Git 分支名是否合法。
# 参数：$1 分支名。返回：合法返回 0，否则报告并返回 1。
validate_branch_name() {
    local branch_name="${1-}"

    if [[ -z "$branch_name" ]]; then
        log_error "分支名为空"
        return 1
    fi
    if ! git check-ref-format --branch "$branch_name" >/dev/null 2>&1; then
        log_error "分支名不合法：$branch_name"
        return 1
    fi
}

# 询问用户确认，默认拒绝。
# 参数：$1 提示文本。返回：输入 y/Y 返回 0，其余（含空输入、读取失败）返回 1。
confirm_action() {
    local prompt_text="${1:?缺少确认提示}"
    local answer=''

    printf '%s' "$prompt_text"
    if ! IFS= read -r answer; then
        printf '\n'
        return 1
    fi
    [[ "$(trim "${answer,,}")" == 'y' ]]
}

# ==================================================
# 仓库锁（同一仓库的同步与发布互斥）
# ==================================================

# 释放当前持有的仓库锁；未持锁时直接返回。
release_repo_lock() {
    [[ -z "$REPO_LOCK_DIR" ]] && return 0

    rm -f "${REPO_LOCK_DIR}/pid" "${REPO_LOCK_DIR}/time" 2>/dev/null || true
    rmdir "$REPO_LOCK_DIR" 2>/dev/null || true
    REPO_LOCK_DIR=''
}

# 获取仓库锁，避免多个脚本实例同时修改同一仓库。
# 参数：$1 仓库目录，$2 仓库别名。
# 返回：0 已持锁；1 被其他实例占用（已输出原因）。
acquire_repo_lock() {
    local repo_dir="${1:?缺少仓库目录}"
    local repo_alias="${2-}"
    local lock_dir="${repo_dir}/.git/backup-sync.lock"
    local pid_file="${lock_dir}/pid"
    local time_file="${lock_dir}/time"

    if mkdir "$lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" >"$pid_file" 2>/dev/null || true
        printf '%s\n' "$(date +%s)" >"$time_file" 2>/dev/null || true
        REPO_LOCK_DIR="$lock_dir"
        return 0
    fi

    # 锁已存在：只在确认是残留锁（超过 STALE_LOCK_SECONDS）时才清理，避免抢占运行中的实例。
    local locked_at=''
    local now age
    read -r locked_at <"$time_file" 2>/dev/null || locked_at=''
    now="$(date +%s)"
    if [[ "$locked_at" =~ ^[0-9]+$ ]]; then
        age=$(( now - locked_at ))
    else
        age=$(( STALE_LOCK_SECONDS + 1 ))
    fi

    if (( age > STALE_LOCK_SECONDS )); then
        log_warn "清理残留锁（超过 $(( STALE_LOCK_SECONDS / 60 )) 分钟）：$lock_dir"
        rm -f "$pid_file" "$time_file" 2>/dev/null || true
        rmdir "$lock_dir" 2>/dev/null || true
        if mkdir "$lock_dir" 2>/dev/null; then
            printf '%s\n' "$$" >"$pid_file" 2>/dev/null || true
            printf '%s\n' "$(date +%s)" >"$time_file" 2>/dev/null || true
            REPO_LOCK_DIR="$lock_dir"
            return 0
        fi
    fi

    log_error "仓库正被其他实例操作，已跳过：${repo_alias:-$repo_dir}"
    return 1
}

# ==================================================
# 业务函数
# ==================================================

# 加载环境变量文件。
# 参数：$1 环境变量文件路径。
# 返回：文件存在、权限合法且加载成功时返回 0；否则返回非 0。
load_env_file() {
    local env_file="${1:?缺少环境变量文件路径}"

    if [[ ! -f "$env_file" ]]; then
        log_error "环境变量文件不存在：$env_file"
        return 1
    fi

    # 环境文件按 shell 配置加载（允许条件分支与 heredoc，例如按 OSTYPE 选择 ACCOUNTS），
    # 故不限制文件内容的语法，只做文件级校验：拒绝符号链接、校验属主与 group/other 可写权限。
    # Windows ACL 下权限位映射不完整（实测 chmod 666 后 stat/find 仍报 644），该校验为尽力而为。
    if [[ -L "$env_file" ]]; then
        log_error "环境变量文件是符号链接，拒绝加载：$env_file"
        return 1
    fi

    if [[ ! -O "$env_file" ]]; then
        log_error "环境变量文件不属于当前用户，拒绝加载：$env_file"
        return 1
    fi

    # 检查 group/other 是否拥有写权限，存在则拒绝加载（Windows 下为尽力而为）。
    if [[ -n "$(find "$env_file" -maxdepth 0 -type f \( -perm -g=w -o -perm -o=w \) -print 2>/dev/null)" ]]; then
        log_error "环境变量文件 group/other 可写，拒绝加载：$env_file"
        return 1
    fi

    # 同一份 .env 常被 Windows 与 Linux 共用；CRLF 直接 source 时，原生 Linux 下
    # heredoc 结束标记会带 CR 而失配，简单赋值的值末尾也会残留 CR。
    # 这里仅在内存中规范化换行，不改动用户原文件。
    local env_content
    if ! env_content="$(<"$env_file")"; then
        log_error "读取环境变量文件失败：$env_file"
        return 1
    fi
    env_content="${env_content//$'\r'/}"

    # shellcheck source=/dev/stdin
    source /dev/stdin <<< "$env_content"
    log_debug "已加载环境变量文件：$env_file"
}

# 解析仓库默认分支：优先 origin/HEAD 符号引用；缺失时依次探测远端 main/master；均不可用时回退 main。
# 参数：$1 仓库目录。stdout 输出分支名。
resolve_default_branch() {
    local repo_dir="${1:?缺少仓库目录}"
    local branch candidate

    # 1) 读取 origin/HEAD 符号引用；--short 对 remote-tracking 引用会保留 origin/ 前缀，取最后一段得到纯分支名。
    local head_ref
    head_ref="$(git -C "$repo_dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || printf '')"
    branch="${head_ref##*/}"

    # 2) origin/HEAD 未设置时，探测远端已存在的 main / master 跟踪分支。
    if [[ -z "$branch" ]]; then
        for candidate in main master; do
            if git -C "$repo_dir" rev-parse --verify --quiet "origin/$candidate" >/dev/null 2>&1; then
                branch="$candidate"
                break
            fi
        done
    fi

    # 3) 仍无法确定时回退 main，交由后续 git 命令给出明确错误。
    [[ -z "$branch" ]] && branch="main"
    printf '%s' "$branch"
}

# 解析 ACCOUNTS 行第 4 段可选参数：分号分隔的 key=value。
# 参数：$1 可选参数串，可为空。
# 输出：写入全局 REPO_EXPECT_BRANCH / REPO_RELEASE_BRANCH / REPO_IDENTITY_MODE。
# 返回：0 解析成功；1 存在未知键、重复键、缺少取值或组合非法（调用方应跳过该仓库，
#       避免保护性参数写错后被静默忽略）。
parse_repo_options() {
    local raw="${1-}"

    # 每个仓库重新开始，防止上一行的配置残留到下一行。
    REPO_EXPECT_BRANCH=''
    REPO_RELEASE_BRANCH=''
    REPO_IDENTITY_MODE=''

    # 去掉全部空白后为空视为未配置。
    [[ -z "${raw//[[:space:]]/}" ]] && return 0

    local item key value
    local has_branch=0 has_release=0 has_identity=0
    local -a items=()
    IFS=';' read -r -a items <<< "$raw"

    for item in "${items[@]}"; do
        item="${item//[[:space:]]/}"
        [[ -z "$item" ]] && continue

        if [[ "$item" != *=* ]]; then
            log_error "可选参数缺少等号：$item（格式 branch=<分支名>、release=<分支名> 或 identity=keep）"
            return 1
        fi

        key="${item%%=*}"
        value="${item#*=}"

        case "$key" in
            branch)
                if (( has_branch )); then
                    log_error "可选参数 branch 重复：$item"
                    return 1
                fi
                has_branch=1
                if [[ -z "$value" ]]; then
                    log_error "可选参数 branch 缺少分支名：$item"
                    return 1
                fi
                validate_branch_name "$value" || return 1
                REPO_EXPECT_BRANCH="$value"
                ;;
            release)
                if (( has_release )); then
                    log_error "可选参数 release 重复：$item"
                    return 1
                fi
                has_release=1
                if [[ -z "$value" ]]; then
                    log_error "可选参数 release 缺少分支名：$item"
                    return 1
                fi
                validate_branch_name "$value" || return 1
                REPO_RELEASE_BRANCH="$value"
                ;;
            identity)
                if (( has_identity )); then
                    log_error "可选参数 identity 重复：$item"
                    return 1
                fi
                has_identity=1
                if [[ "$value" != 'keep' ]]; then
                    log_error "可选参数 identity 仅支持 keep：$item"
                    return 1
                fi
                REPO_IDENTITY_MODE='keep'
                ;;
            *)
                log_error "未知的可选参数：$item（当前支持 branch=<分支名>、release=<分支名>、identity=keep）"
                return 1
                ;;
        esac
    done

    # 发布参数必须成套出现：缺少 branch 时无法确定发布源，branch 与 release 相同则无发布意义。
    if [[ -n "$REPO_RELEASE_BRANCH" ]]; then
        if [[ -z "$REPO_EXPECT_BRANCH" ]]; then
            log_error "配置 release 时必须同时配置 branch：$raw"
            return 1
        fi
        if [[ "$REPO_RELEASE_BRANCH" == "$REPO_EXPECT_BRANCH" ]]; then
            log_error "可选参数 branch 与 release 不能相同：$raw"
            return 1
        fi
    fi

    return 0
}

# 从远程地址解析仓库名称：取最后一段路径并去掉 .git 后缀。
# 兼容 ssh（user@host:owner/repo.git）、https（https://host/owner/repo.git）与本地路径。
# 参数：$1 远程地址。stdout：仓库名称；无法解析时输出地址原文。
repo_display_name() {
    local url="${1-}"
    local name

    [[ -z "$url" ]] && return 0
    name="${url%.git}"
    name="${name%/}"
    name="${name##*[/:]}"
    [[ -z "$name" ]] && name="$url"
    printf '%s' "$name"
}

# 解析 ACCOUNTS 为仓库条目数组，作为全部同步与发布功能的唯一入口。
# 输出：填充 REPO_ENTRY_* 数组。
#   REPO_ENTRY_DUPLICATE=1：与前面条目完全重复（远程地址与本地目录都相同），跳过即可。
#   REPO_ENTRY_DUPLICATE=2：本地目录冲突（同一目录配置了不同远程地址），属于危险配置。
load_repo_entries() {
    REPO_ENTRY_ALIAS=()
    REPO_ENTRY_NAME=()
    REPO_ENTRY_URL=()
    REPO_ENTRY_DIR=()
    REPO_ENTRY_BRANCH=()
    REPO_ENTRY_RELEASE=()
    REPO_ENTRY_IDENTITY=()
    REPO_ENTRY_DUPLICATE=()

    local -A seen_pair=()
    local -A seen_dir=()
    local line_alias line_url line_dir line_opts norm_dir norm_url duplicate pair

    # 行格式：别名,远程地址,本地目录[,可选参数]；可选参数用分号分隔多个 key=value。
    while IFS=',' read -r line_alias line_url line_dir line_opts || [[ -n "$line_alias" ]]; do
        # 跳过空行和注释行。
        [[ -z "$line_alias" || "$line_alias" =~ ^[[:space:]]*# ]] && continue
        # 字段尾随空格（手写配置常见）统一去掉，避免把空格带进路径。
        line_alias="$(trim "$line_alias")"
        line_url="$(trim "$line_url")"
        line_dir="$(trim "$line_dir")"
        # 校验必填字段，缺 URL 或目录时跳过该行。
        if [[ -z "$line_url" || -z "$line_dir" ]]; then
            log_warn "账号行字段不完整，已跳过：${line_alias:-（无别名）}"
            continue
        fi
        # 可选参数解析失败时跳过该仓库：宁可不同步，也不在缺少分支保护的情况下写仓库。
        if ! parse_repo_options "${line_opts-}"; then
            log_warn "可选参数无效，已跳过：$line_alias"
            continue
        fi

        # 仓库身份 = 远程地址 + 本地目录：别名与仓库名重复不影响区分，只有这两项合起来才算同一个仓库。
        norm_dir="$(normalize_repo_ref "$line_dir")"
        norm_url="$(normalize_repo_ref "$line_url")"
        pair="${norm_url}|${norm_dir}"
        duplicate=0
        if [[ -n "${seen_pair["$pair"]+set}" ]]; then
            duplicate=1
        elif [[ -n "${seen_dir["$norm_dir"]+set}" ]]; then
            # 同一目录指向不同远程地址：后续操作会互相覆盖，不能静默按先到先得处理。
            duplicate=2
        fi
        seen_pair["$pair"]=1
        seen_dir["$norm_dir"]=1

        REPO_ENTRY_ALIAS+=("$line_alias")
        REPO_ENTRY_NAME+=("$(repo_display_name "$line_url")")
        REPO_ENTRY_URL+=("$line_url")
        REPO_ENTRY_DIR+=("$line_dir")
        REPO_ENTRY_BRANCH+=("$REPO_EXPECT_BRANCH")
        REPO_ENTRY_RELEASE+=("$REPO_RELEASE_BRANCH")
        REPO_ENTRY_IDENTITY+=("$REPO_IDENTITY_MODE")
        REPO_ENTRY_DUPLICATE+=("$duplicate")
    done <<< "${ACCOUNTS:-}"
}

# 生成仓库条目的菜单显示文本：别名 + 仓库名 + 分支（配置了 release 时显示发布关系）。
# 参数：$1 条目下标。stdout：显示文本（不含本地目录）。
entry_label() {
    local idx="${1:?缺少条目下标}"
    local label

    if [[ -n "${REPO_ENTRY_RELEASE[idx]}" ]]; then
        label="${REPO_ENTRY_ALIAS[idx]} | ${REPO_ENTRY_NAME[idx]}（${REPO_ENTRY_BRANCH[idx]} → ${REPO_ENTRY_RELEASE[idx]}）"
    elif [[ -n "${REPO_ENTRY_BRANCH[idx]}" ]]; then
        label="${REPO_ENTRY_ALIAS[idx]} | ${REPO_ENTRY_NAME[idx]}（${REPO_ENTRY_BRANCH[idx]}）"
    else
        label="${REPO_ENTRY_ALIAS[idx]} | ${REPO_ENTRY_NAME[idx]}"
    fi
    printf '%s' "$label"
}

# 预生成全部条目的菜单文本；展示文本相同的条目追加本地目录，避免多账号同名仓库无法区分。
build_entry_labels() {
    ENTRY_LABEL=()

    local -A same_label=()
    local idx label
    for idx in "${!REPO_ENTRY_DIR[@]}"; do
        label="$(entry_label "$idx")"
        same_label["$label"]=$(( ${same_label["$label"]:-0} + 1 ))
    done

    for idx in "${!REPO_ENTRY_DIR[@]}"; do
        label="$(entry_label "$idx")"
        if (( ${same_label["$label"]:-0} > 1 )); then
            ENTRY_LABEL[idx]="${label} | ${REPO_ENTRY_DIR[idx]}"
        else
            ENTRY_LABEL[idx]="$label"
        fi
    done
}

# 更新已修改脚本文件头中的日期与更新时间字段。
# 参数：$1 仓库目录。
# 副作用：原地修改匹配文件的字段，仅处理本地已修改、待推送的文件。
update_header_date() {
    local repo_dir="${1:?缺少仓库目录}"
    local now
    local repo_root
    local file abs_file

    now=$(date +'%Y-%m-%d %H:%M:%S')
    # 获取仓库根目录，将 diff 输出的相对路径转换为绝对路径，避免在错误目录查找文件。
    if ! repo_root="$(git -C "$repo_dir" rev-parse --show-toplevel)"; then
        log_error "获取仓库根目录失败：$repo_dir"
        return 1
    fi

    while IFS= read -r -d '' file; do
        abs_file="${repo_root}/${file}"
        [[ -f "$abs_file" ]] || continue

        if grep -qE '^(# *date[[:space:]]*:|#!date[[:space:]]*=|# *更新时间[[:space:]]*:)' "$abs_file"; then
            # 使用 -E 启用扩展正则，使括号作为捕获组，与 grep -E 的正则保持一致；
            # 同时区分 GNU sed 与 BSD sed 的原地修改参数。
            if sed --version >/dev/null 2>&1; then
                sed -E -i \
                    -e "s|^(# *date[[:space:]]*:[[:space:]]*).*$|\1$now|" \
                    -e "s|^(#!date[[:space:]]*=[[:space:]]*).*$|\1$now|" \
                    -e "s|^(# *更新时间[[:space:]]*:[[:space:]]*).*$|\1$now|" \
                    "$abs_file"
            else
                sed -E -i '' \
                    -e "s|^(# *date[[:space:]]*:[[:space:]]*).*$|\1$now|" \
                    -e "s|^(#!date[[:space:]]*=[[:space:]]*).*$|\1$now|" \
                    -e "s|^(# *更新时间[[:space:]]*:[[:space:]]*).*$|\1$now|" \
                    "$abs_file"
            fi
            log_debug "已更新文件日期与更新时间：$abs_file"
        fi
    # 相对 HEAD 对比，覆盖已暂存与未暂存的新增/复制/修改/重命名文件；删除文件由 -f 检查跳过。
    done < <(git -C "$repo_dir" diff --name-only --no-renames --diff-filter=ACMR HEAD -z)
}

# 判断仓库内相对路径是否属于禁止自动提交的敏感文件。
# 参数：$1 仓库内相对路径。返回 0 表示命中敏感模式，1 表示普通文件。
is_sensitive_path() {
    local path="${1:?缺少待检查路径}"
    local base="${path##*/}"

    case "$base" in
        .env|.env.*|*.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|id_rsa|id_ed25519|id_ecdsa|.netrc|.git-credentials|*credentials*|*secret*) return 0 ;;
    esac
    case "$path" in
        .ssh/*|*/.ssh/*|*credentials*|*secret*) return 0 ;;
    esac
    return 1
}

# 从 diff 文本中检测高置信度凭据特征，只输出规则名，不回显命中内容（GIT_AGENTS 6.7）。
# 参数：stdin 为 git diff 输出。返回：命中返回 0 并输出规则名；未命中返回 1。
detect_secret_rule() {
    local line

    while IFS= read -r line; do
        # 只检查新增行；'+++' 是文件头，直接跳过。
        case "$line" in
            +++*) continue ;;
            +*) ;;
            *) continue ;;
        esac

        # 真实私钥头形如 "-----BEGIN <算法名> PRIVATE KEY-----"：BEGIN 后必须是空格与算法名。
        # 用该结构匹配，避免把本函数里的检测规则字符串误判为私钥（规则文本里 BEGIN 后是引号）。
        if [[ "$line" =~ -----BEGIN[[:space:]]+[A-Za-z0-9[:space:]]*PRIVATE[[:space:]]KEY----- ]]; then
            printf '%s' '私钥内容'
            return 0
        fi
        if [[ "$line" =~ AKIA[0-9A-Z]{16} ]]; then
            printf '%s' 'AWS Access Key'
            return 0
        fi
        if [[ "$line" =~ gh[pousr]_[A-Za-z0-9]{36,} ]]; then
            printf '%s' 'GitHub Token'
            return 0
        fi
        if [[ "$line" =~ xox[baprs]-[A-Za-z0-9-]{10,} ]]; then
            printf '%s' 'Slack Token'
            return 0
        fi
        if [[ "$line" =~ [0-9]{6,12}:AA[A-Za-z0-9_-]{30,} ]]; then
            printf '%s' 'Telegram Bot Token'
            return 0
        fi
    done
    return 1
}

# 检测本地变更，按明确路径暂存并提交；AUTO_PUSH=1（默认）时推送到当前分支。
# 参数：$1 仓库别名，$2 仓库目录，$3 推送分支（空表示按当前分支解析），$4 身份策略。
# stdout：本次处理结果文本（无本地变更 / 已提交并推送本地变更 / 已提交本地变更（未推送））。
# 副作用：更新文件头日期、修改 .git 索引、创建提交、向远端推送。
commit_local_changes() {
    local repo_alias="${1:?缺少仓库别名}"
    local project_dir="${2:?缺少仓库目录}"
    local target_branch="${3-}"
    local identity_mode="${4-}"

    # 先显式检查状态命令退出码；仓库损坏或命令失败时不得误判为"无变更"。
    if ! git -C "$project_dir" status --porcelain >/dev/null 2>&1; then
        log_error "读取仓库状态失败：$repo_alias"
        return 1
    fi

    # 用 -z 取得精确路径清单：含空格/非 ASCII 的路径不被引号转义。
    # 重命名/复制记录后紧跟一条原路径，需一并消费。
    local -a changed_paths=()
    local record status_code path orig_path
    while IFS= read -r -d '' record; do
        status_code="${record:0:2}"
        path="${record:3}"
        if [[ -z "$path" ]]; then
            continue
        fi
        if [[ "$status_code" == *R* || "$status_code" == *C* ]]; then
            IFS= read -r -d '' orig_path || orig_path=''
        else
            orig_path=''
        fi
        changed_paths+=("$path")
        if [[ -n "$orig_path" ]]; then
            changed_paths+=("$orig_path")
        fi
    done < <(git -C "$project_dir" status --porcelain -z --untracked-files=all)

    if (( ${#changed_paths[@]} == 0 )); then
        log_debug "本地仓库无变更"
        printf '%s' '无本地变更'
        return 0
    fi

    # 敏感文件闸门：命中即中止，不暂存、不提交、不推送（GIT_AGENTS 13 / AGENTS 3.1）。
    local candidate
    for candidate in "${changed_paths[@]}"; do
        if is_sensitive_path "$candidate"; then
            log_error "检测到敏感文件，拒绝自动提交：$repo_alias / $candidate"
            return 1
        fi
    done

    # 推送分支与当前工作分支必须一致：否则会把当前分支的提交推到别的分支上。
    local default_branch
    default_branch="$(current_branch "$project_dir")"
    if [[ -z "$default_branch" ]]; then
        default_branch="$(resolve_default_branch "$project_dir")"
    fi
    # 调用方已确定推送分支（例如 ACCOUNTS 里 lock 的分支）时优先使用。
    [[ -n "$target_branch" ]] && default_branch="$target_branch"
    log_info "检测到本地变更，正在提交"
    update_header_date "$project_dir"

    # 提交前输出变更清单留痕，便于复核暂存范围（对应 GIT_AGENTS 5.1/5.2）。
    printf '    %s\n' "${changed_paths[@]}" >&2

    # 按明确路径暂存，避免盲目 git add -A 夹带无关文件（GIT_AGENTS 5.2）。
    if ! git -C "$project_dir" add -A -- "${changed_paths[@]}"; then
        log_error "暂存本地变更失败：$repo_alias"
        return 1
    fi

    # 复核暂存区：若夹带敏感文件，撤销本次暂存并中止。
    local staged_out staged_path
    if ! staged_out="$(git -C "$project_dir" diff --cached --name-only)"; then
        log_error "读取暂存区失败：$repo_alias"
        return 1
    fi
    while IFS= read -r staged_path; do
        if [[ -z "$staged_path" ]]; then
            continue
        fi
        if is_sensitive_path "$staged_path"; then
            log_error "暂存区含敏感文件，撤销暂存并中止：$repo_alias / $staged_path"
            if ! git -C "$project_dir" reset --mixed -- "${changed_paths[@]}" >/dev/null 2>&1; then
                log_warn "撤销暂存失败，请人工检查：$repo_alias"
            fi
            return 1
        fi
    done <<< "$staged_out"

    # 内容级检查：私钥、云厂商与 IM 平台令牌一旦进入提交即很难彻底清除。
    local secret_rule
    if secret_rule="$(git -C "$project_dir" diff --cached | detect_secret_rule)"; then
        log_error "暂存内容疑似包含敏感凭据（${secret_rule:-命中规则}），撤销暂存并中止：$repo_alias"
        if ! git -C "$project_dir" reset --mixed -- "${changed_paths[@]}" >/dev/null 2>&1; then
            log_warn "撤销暂存失败，请人工检查：$repo_alias"
        fi
        return 1
    fi

    # 显式检查提交结果，失败时返回明确错误。
    # git commit 的输出转到 stderr，保证 stdout 只承载状态文本（供调用方命令替换）。
    if ! run_git_commit "$project_dir" "$identity_mode" \
        -m "chore: auto sync $(date +'%Y-%m-%d %H:%M:%S')" >&2; then
        log_error "提交本地变更失败：$repo_alias"
        return 1
    fi

    # AUTO_PUSH=0 时只提交不推送，便于先复核再对外同步（AGENTS 3.2）。
    if [[ "${AUTO_PUSH:-1}" != '1' ]]; then
        log_warn "AUTO_PUSH 未启用，跳过推送：$repo_alias"
        log_success "本地变更已提交（未推送）"
        printf '%s' '已提交本地变更（未推送）'
        return 0
    fi

    log_info "正在推送本地变更"
    if ! git -C "$project_dir" push origin "$default_branch"; then
        log_error "推送本地变更失败：$repo_alias"
        return 1
    fi
    log_success "本地变更已提交并推送"
    printf '%s' '已提交并推送本地变更'
}

# 初始化仓库分支结构：在目标分支（未配置时用同步分支）建立基础提交，再从同一提交创建同步分支。
# 参数：$1 别名，$2 仓库目录，$3 同步分支，$4 正式分支（可空），$5 交互模式（1/0），$6 身份策略。
# 返回：0 初始化完成；1 失败；2 跳过（自动模式或用户取消）。
initialize_repo_layout() {
    local repo_alias="${1:?缺少仓库别名}"
    local project_dir="${2:?缺少仓库目录}"
    local expect_branch="${3:?缺少同步分支}"
    local release_branch="${4-}"
    local interactive="${5:-0}"
    local identity_mode="${6-}"
    local base_ref='' base_branch='' default_branch plan=''

    # 基础提交来源：优先正式分支，其次远程默认分支；都没有说明远程为空。
    if [[ -n "$release_branch" ]] && remote_branch_exists "$project_dir" "$release_branch"; then
        base_ref="origin/${release_branch}"
    else
        default_branch="$(resolve_default_branch "$project_dir")"
        if remote_branch_exists "$project_dir" "$default_branch"; then
            base_ref="origin/${default_branch}"
        fi
    fi

    if [[ -n "$base_ref" ]]; then
        plan="以 ${base_ref#origin/} 为基础创建分支 ${expect_branch}"
    else
        base_branch="${release_branch:-$expect_branch}"
        plan="远程为空，先在 ${base_branch} 建立空的基础提交，再创建分支 ${expect_branch}"
    fi

    log_warn "远程缺少分支：${expect_branch}（${repo_alias}）"
    printf '    初始化方案：%s\n' "$plan" >&2

    if (( interactive == 0 )); then
        log_warn "初始化需要人工确认，自动同步模式已跳过：${repo_alias}"
        return 2
    fi
    if ! confirm_action '确认执行上述初始化？[y/N]: '; then
        log_warn "已取消初始化：${repo_alias}"
        return 2
    fi

    # 切换分支前必须确认工作区干净，避免覆盖用户未提交的修改。
    if [[ -n "$(git -C "$project_dir" status --porcelain 2>/dev/null)" ]]; then
        log_error "工作区不干净，拒绝初始化：${repo_alias}"
        return 1
    fi

    if [[ -z "$base_ref" ]]; then
        # 空远程：基础提交保持空内容，禁止把同步分支的业务代码当作目标分支的初始内容。
        if ! git -C "$project_dir" symbolic-ref HEAD "refs/heads/${base_branch}"; then
            log_error "设置初始分支失败：${base_branch}"
            return 1
        fi
        if ! run_git_commit "$project_dir" "$identity_mode" --allow-empty -m 'chore: 初始化仓库' >&2; then
            log_error "创建基础提交失败：${repo_alias}（请确认已配置 Git 身份）"
            return 1
        fi
        if ! git -C "$project_dir" push -u origin "$base_branch"; then
            log_error "推送基础提交失败：origin/${base_branch}"
            return 1
        fi
        log_success "已建立基础提交并推送：origin/${base_branch}"
        base_ref='HEAD'
    fi

    # 从同一基础提交创建同步分支，保证分支历史同源、可快进。
    if [[ "$base_ref" == 'HEAD' ]]; then
        if ! git -C "$project_dir" checkout -b "$expect_branch" >&2; then
            log_error "创建分支失败：${expect_branch}"
            return 1
        fi
    else
        if ! git -C "$project_dir" checkout -b "$expect_branch" "$base_ref" >&2; then
            log_error "基于 ${base_ref} 创建分支失败：${expect_branch}"
            return 1
        fi
    fi

    if ! git -C "$project_dir" push -u origin "$expect_branch"; then
        log_error "推送分支失败：origin/${expect_branch}"
        return 1
    fi
    log_success "已创建并推送分支：origin/${expect_branch}"

    if [[ "$(current_branch "$project_dir")" != "$expect_branch" ]]; then
        log_error "初始化后未停在 ${expect_branch} 分支：${repo_alias}"
        return 1
    fi
}

# 让工作目录停在配置指定的同步分支；本地缺少该分支时按需创建。
# 参数：$1 别名，$2 仓库目录，$3 同步分支（空表示不锁定），$4 正式分支（可空），
#       $5 交互模式（1/0），$6 身份策略。
# 返回：0 已就绪；1 失败；2 跳过。
prepare_work_branch() {
    local repo_alias="${1:?缺少仓库别名}"
    local project_dir="${2:?缺少仓库目录}"
    local expect_branch="${3-}"
    local release_branch="${4-}"
    local interactive="${5:-0}"
    local identity_mode="${6-}"
    local current init_rc=0

    current="$(current_branch "$project_dir")"

    # 未锁定分支：沿用当前分支，保证拉取、提交与推送到同一个分支。
    if [[ -z "$expect_branch" ]]; then
        if [[ -n "$current" ]]; then
            log_debug "未锁定分支，沿用当前分支：$current"
            return 0
        fi
        # 游离 HEAD 无法确定推送目标，直接拒绝。
        if git -C "$project_dir" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
            log_error "当前处于游离 HEAD 状态，无法确定同步分支：${repo_alias}"
            return 1
        fi
        # 尚无提交：远程有默认分支则检出，否则按空仓库初始化。
        current="$(resolve_default_branch "$project_dir")"
        if remote_branch_exists "$project_dir" "$current"; then
            if ! git -C "$project_dir" checkout -b "$current" --track "origin/${current}" >&2; then
                log_error "检出分支失败：origin/${current}"
                return 1
            fi
            return 0
        fi
        initialize_repo_layout "$repo_alias" "$project_dir" "$current" '' "$interactive" "$identity_mode" || init_rc=$?
        return "$init_rc"
    fi

    # 已锁定分支且当前分支一致：正常同步。
    if [[ "$current" == "$expect_branch" ]]; then
        return 0
    fi

    # 本地已有该分支但当前停在其他分支：拒绝同步，绝不擅自切换。
    if local_branch_exists "$project_dir" "$expect_branch"; then
        log_warn "当前分支为 '${current:-detached}'，与配置分支 '${expect_branch}' 不符，拒绝同步"
        return 2
    fi

    # 本地缺少该分支且远程已有：直接检出，不覆盖任何本地文件。
    if remote_branch_exists "$project_dir" "$expect_branch"; then
        if [[ -n "$(git -C "$project_dir" status --porcelain 2>/dev/null)" ]]; then
            log_warn "工作区不干净，无法检出分支 '${expect_branch}'，已跳过：${repo_alias}"
            return 2
        fi
        if ! git -C "$project_dir" checkout -b "$expect_branch" --track "origin/${expect_branch}" >&2; then
            log_error "检出分支失败：origin/${expect_branch}"
            return 1
        fi
        log_success "已从 origin/${expect_branch} 建立本地分支"
        return 0
    fi

    # 本地与远程都缺少该分支：需要初始化。
    initialize_repo_layout "$repo_alias" "$project_dir" "$expect_branch" "$release_branch" \
        "$interactive" "$identity_mode" || init_rc=$?
    return "$init_rc"
}

# 处理单个仓库的同步操作。
# 参数：$1 仓库别名，$2 仓库 URL，$3 本地项目目录，$4 锁定分支（空表示不锁定），
#       $5 身份策略（keep 表示保留仓库已配置身份），$6 正式分支（可空），$7 交互模式（1/0）。
# 返回：0 完成；1 失败；2 跳过。
# 副作用：可能克隆仓库、建立分支、拉取远程更新、提交并推送。
process_repo() {
    local repo_alias="${1:?缺少仓库别名}"
    local repo_url="${2:?缺少仓库 URL}"
    local project_dir="${3:?缺少本地项目目录}"
    local expect_branch="${4-}"
    local identity_mode="${5-}"
    local release_branch="${6-}"
    local interactive="${7:-0}"

    hr
    kv "别  名" "$repo_alias"
    kv "仓库名" "$(repo_display_name "$repo_url")"
    # 分支紧随仓库名显示：优先用配置的锁定分支，其次读本地当前 HEAD；
    # 首次克隆等尚不可知的情况，留到实际检出后再补一行。
    local shown_branch=''
    if [[ -n "$expect_branch" ]]; then
        shown_branch="$expect_branch"
        kv "分  支" "$shown_branch"
    elif [[ -d "$project_dir/.git" ]]; then
        shown_branch="$(current_branch "$project_dir")"
        [[ -z "$shown_branch" ]] || kv "分  支" "$shown_branch"
    fi
    log_info "开始处理仓库"

    # 检查本地项目目录是否存在。
    if [[ ! -d "$project_dir/.git" ]]; then
        # 目录已存在且非空时拒绝克隆，避免覆盖用户文件。
        if [[ -e "$project_dir" && -n "$(ls -A "$project_dir" 2>/dev/null || true)" ]]; then
            log_error "目录已存在且非空，但不是 Git 仓库，拒绝覆盖：$project_dir"
            return 1
        fi
        log_info "本地仓库不存在，开始克隆：$project_dir"
        if ! git clone "$repo_url" "$project_dir"; then
            log_error "仓库克隆失败：$repo_url"
            return 1
        fi
        log_success "仓库克隆完成：$project_dir"
    else
        log_debug "本地仓库已存在：$project_dir"
    fi

    # 同一仓库的同步与发布必须互斥，避免两个实例同时改写工作区。
    if ! acquire_repo_lock "$project_dir" "$repo_alias"; then
        return 2
    fi

    # 配置远程仓库地址（使用 git -C 避免切换工作目录）。地址不一致时按配置纠正，
    # 但不回显地址内容，避免把含令牌的 URL 打到日志里。
    local current_url
    current_url="$(remote_url "$project_dir")"
    if [[ "$(normalize_repo_ref "$current_url")" != "$(normalize_repo_ref "$repo_url")" ]]; then
        if [[ -z "$current_url" ]]; then
            if ! git -C "$project_dir" remote add origin "$repo_url"; then
                log_error "添加远程仓库失败：$repo_alias"
                release_repo_lock
                return 1
            fi
            log_debug "已添加远程仓库 origin"
        else
            log_warn "远程地址与配置不一致，已按配置更新：$repo_alias"
            if ! git -C "$project_dir" remote set-url origin "$repo_url"; then
                log_error "更新远程仓库地址失败：$repo_alias"
                release_repo_lock
                return 1
            fi
        fi
    fi

    # 仓库级换行策略：检出与工作区统一使用 LF，避免脚本在 Linux 上执行时报 bash\r。
    git -C "$project_dir" config --local core.autocrlf input

    # 获取远程最新信息。
    log_info "正在获取远程更新"
    if ! git -C "$project_dir" fetch origin; then
        log_error "获取远程更新失败：$repo_alias"
        release_repo_lock
        return 1
    fi

    # 分支准备：锁定分支则停在锁定分支，缺失时检出或初始化。
    local branch_rc=0
    prepare_work_branch "$repo_alias" "$project_dir" "$expect_branch" "$release_branch" \
        "$interactive" "$identity_mode" || branch_rc=$?
    if (( branch_rc != 0 )); then
        release_repo_lock
        return "$branch_rc"
    fi

    local work_branch
    work_branch="$(current_branch "$project_dir")"
    if [[ -z "$work_branch" ]]; then
        log_error "无法确定当前工作分支：$repo_alias"
        release_repo_lock
        return 1
    fi
    log_debug "当前工作分支：$work_branch"
    # 块头未能预知分支（首次克隆）或与预期不一致时，在这里补报实际分支。
    if [[ "$work_branch" != "$shown_branch" ]]; then
        log_info "实际工作分支：$work_branch"
    fi

    # 本地已有未推送提交时停止本仓库的提交与推送：git push 会把这批历史提交一并带上，
    # 无法只推送本次新建的提交，交由用户先检查处理。
    local ahead_count
    ahead_count="$(git -C "$project_dir" rev-list --count "origin/${work_branch}..HEAD" 2>/dev/null || printf '0')"
    if [[ "${ahead_count:-0}" -gt 0 ]]; then
        log_warn "本地存在 ${ahead_count} 个未推送提交，已停止本仓库的提交与推送：$repo_alias"
        log_warn "请先检查并处理：git -C ${project_dir} log --oneline origin/${work_branch}..HEAD"
        release_repo_lock
        return 2
    fi

    # 比较本地与远程提交：此时已确认本地没有未推送提交，拉取只是快进或干净变基。
    local local_commit remote_commit
    local_commit=$(git -C "$project_dir" rev-parse HEAD 2>/dev/null || printf '')
    remote_commit=$(git -C "$project_dir" rev-parse "origin/${work_branch}" 2>/dev/null || printf '')

    if [[ -n "$remote_commit" && "$local_commit" != "$remote_commit" ]]; then
        log_info "检测到远程更新，正在拉取"
        if ! git -C "$project_dir" pull --rebase --autostash origin "$work_branch"; then
            log_error "拉取远程更新失败：$repo_alias"
            release_repo_lock
            return 1
        fi
        log_success "远程更新已同步"
    else
        log_debug "远程仓库无更新"
    fi

    # 检测并提交本地变更；失败时向上返回非零，避免主流程误报成功。
    log_info "正在检查本地变更"
    local local_change_status=''
    if ! local_change_status="$(commit_local_changes "$repo_alias" "$project_dir" "$work_branch" "$identity_mode")"; then
        release_repo_lock
        return 1
    fi
    log_debug "本地变更处理结果：$local_change_status"

    # 推送后校验本地与远程是否一致，避免"命令成功但没推上去"被当成完成。
    if [[ "$local_change_status" == '已提交并推送本地变更' ]]; then
        local head_sha remote_sha
        head_sha="$(git -C "$project_dir" rev-parse HEAD)"
        remote_sha="$(git -C "$project_dir" rev-parse "origin/${work_branch}" 2>/dev/null || printf '')"
        if [[ "$head_sha" != "$remote_sha" ]]; then
            log_error "推送后校验失败：本地 ${head_sha:0:8} 与 origin/${work_branch} ${remote_sha:0:8} 不一致：$repo_alias"
            release_repo_lock
            return 1
        fi
        log_success "已推送至 origin/${work_branch}（${head_sha:0:8}）"
    fi

    log_success "仓库同步完成"
    release_repo_lock
}

# 批量同步全部仓库（无参数模式与菜单 1 共用）。
# 返回：0 全部成功或跳过；1 存在失败仓库。
# 批量同步全部仓库（无参数模式与菜单共用）。
# 返回：0 全部成功或跳过；1 存在失败仓库。
sync_all_repos() {
    local ok_count=0 skip_count=0 fail_count=0
    local -a failed_aliases=()
    local idx result=0

    load_repo_entries

    if (( ${#REPO_ENTRY_DIR[@]} == 0 )); then
        log_error "ACCOUNTS 中没有可处理的仓库配置"
        return 1
    fi

    for idx in "${!REPO_ENTRY_DIR[@]}"; do
        # 完全重复的条目只处理第一条，避免同一仓库被连续改写两次。
        if (( REPO_ENTRY_DUPLICATE[idx] == 1 )); then
            log_warn "仓库配置重复，已跳过：${REPO_ENTRY_ALIAS[idx]}（${REPO_ENTRY_DIR[idx]}）"
            skip_count=$(( skip_count + 1 ))
            continue
        fi
        # 同一本地目录指向不同远程地址属于危险配置，跳过并提示修正。
        if (( REPO_ENTRY_DUPLICATE[idx] == 2 )); then
            log_error "本地目录已被其他条目占用，已跳过：${REPO_ENTRY_ALIAS[idx]}（${REPO_ENTRY_DIR[idx]}）"
            skip_count=$(( skip_count + 1 ))
            continue
        fi

        result=0
        process_repo "${REPO_ENTRY_ALIAS[idx]}" "${REPO_ENTRY_URL[idx]}" "${REPO_ENTRY_DIR[idx]}" \
            "${REPO_ENTRY_BRANCH[idx]}" "${REPO_ENTRY_IDENTITY[idx]}" \
            "${REPO_ENTRY_RELEASE[idx]}" 0 || result=$?

        case "$result" in
            0) ok_count=$(( ok_count + 1 )) ;;
            2) skip_count=$(( skip_count + 1 )) ;;
            *)
                fail_count=$(( fail_count + 1 ))
                failed_aliases+=("${REPO_ENTRY_ALIAS[idx]}（${REPO_ENTRY_NAME[idx]}）")
                log_warn "仓库处理失败：${REPO_ENTRY_ALIAS[idx]}（${REPO_ENTRY_NAME[idx]}）"
                ;;
        esac
    done

    print_sync_summary "${#REPO_ENTRY_DIR[@]}" "$ok_count" "$skip_count" "$fail_count"
    if (( fail_count > 0 )); then
        log_error "存在失败仓库：${failed_aliases[*]}"
        return 1
    fi
    log_success "全部任务执行完成"
}

# 输出同步统计：总数/成功/跳过/失败，标签与日志级别标签同宽。
# 参数：$1 总数，$2 成功，$3 跳过，$4 失败。
print_sync_summary() {
    local total_count="${1:-0}"
    local ok_count="${2:-0}"
    local skip_count="${3:-0}"
    local fail_count="${4:-0}"

    hr
    kv "总  数" "$total_count"
    kv "成  功" "$ok_count"
    kv "跳  过" "$skip_count"
    kv "失  败" "$fail_count"
    hr
}

# 同步单个仓库（菜单「同步指定仓库」调用，复用同一套 process_repo 逻辑）。
# 参数：$1 条目下标。返回：0 完成；1 失败；2 跳过。
sync_selected_repo() {
    local idx="${1:?缺少条目下标}"
    local result=0

    process_repo "${REPO_ENTRY_ALIAS[idx]}" "${REPO_ENTRY_URL[idx]}" "${REPO_ENTRY_DIR[idx]}" \
        "${REPO_ENTRY_BRANCH[idx]}" "${REPO_ENTRY_IDENTITY[idx]}" \
        "${REPO_ENTRY_RELEASE[idx]}" 1 || result=$?
    return "$result"
}

# 检查发布前置状态。
# 参数：$1 仓库目录，$2 源分支，$3 目标分支。
# 返回：0 通过；1 不通过（已输出原因）。
check_release_preconditions() {
    local project_dir="${1:?缺少仓库目录}"
    local source_branch="${2:?缺少源分支}"
    local target_branch="${3:?缺少目标分支}"
    local state_file current behind=0 ahead=0

    # 未完成的 Git 操作会让快进判断失真。
    for state_file in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG rebase-merge rebase-apply; do
        if [[ -e "${project_dir}/.git/${state_file}" ]]; then
            log_error "存在未完成的 Git 操作（${state_file}），请先处理后再发布"
            return 1
        fi
    done

    # 工作区/暂存区必须干净：发布不允许携带未经测试的本地修改。
    if [[ -n "$(git -C "$project_dir" status --porcelain 2>/dev/null)" ]]; then
        log_error "工作区或暂存区不干净，请先提交或同步本地变更后再发布"
        return 1
    fi

    current="$(current_branch "$project_dir")"
    if [[ "$current" != "$source_branch" ]]; then
        log_error "当前分支为 '${current:-detached}'，发布必须在 '${source_branch}' 分支进行"
        return 1
    fi

    if ! remote_branch_exists "$project_dir" "$source_branch"; then
        log_error "远程缺少发布源分支：origin/${source_branch}"
        return 1
    fi
    if ! remote_branch_exists "$project_dir" "$target_branch"; then
        log_error "远程缺少发布目标分支：origin/${target_branch}"
        return 1
    fi

    # 本地源分支必须与远程源分支完全一致：既不夹带未推送提交，也不落后于远程。
    read -r behind ahead < <(git -C "$project_dir" rev-list --left-right --count "origin/${source_branch}...HEAD")
    if (( ahead > 0 )); then
        log_error "本地 ${source_branch} 有 ${ahead} 个未推送提交，请先同步该仓库"
        return 1
    fi
    if (( behind > 0 )); then
        log_error "本地 ${source_branch} 落后远程 ${behind} 个提交，请先同步该仓库"
        return 1
    fi
    return 0
}

# 输出远程分支实际状态，用于发布失败后的如实汇报。
# 参数：$1 仓库目录，$2 源分支，$3 目标分支。
report_remote_state() {
    local project_dir="${1:?缺少仓库目录}"
    local source_branch="${2-}"
    local target_branch="${3-}"
    local source_sha target_sha

    git -C "$project_dir" fetch origin >/dev/null 2>&1 || log_warn "无法获取远程状态，以下信息可能不是最新"
    source_sha="$(git -C "$project_dir" rev-parse --short "origin/${source_branch}" 2>/dev/null || printf '未知')"
    target_sha="$(git -C "$project_dir" rev-parse --short "origin/${target_branch}" 2>/dev/null || printf '未知')"
    log_info "远程实际状态：origin/${source_branch}=${source_sha}，origin/${target_branch}=${target_sha}"
}

# 发布后验证：远程目标分支、远程源分支、本地工作分支都必须符合预期。
# 参数：$1 仓库目录，$2 源分支，$3 目标分支，$4 本次发布提交。
# 返回：0 验证通过；1 验证失败（已输出差异）。
verify_release_result() {
    local project_dir="${1:?缺少仓库目录}"
    local source_branch="${2:?缺少源分支}"
    local target_branch="${3:?缺少目标分支}"
    local release_commit="${4:?缺少发布提交}"
    local new_target new_source current verified=0

    if ! git -C "$project_dir" fetch origin; then
        log_error "发布后无法获取远程状态，结果未验证"
        report_remote_state "$project_dir" "$source_branch" "$target_branch"
        return 1
    fi

    new_target="$(git -C "$project_dir" rev-parse "origin/${target_branch}" 2>/dev/null || printf '')"
    new_source="$(git -C "$project_dir" rev-parse "origin/${source_branch}" 2>/dev/null || printf '')"
    current="$(current_branch "$project_dir")"

    if [[ "$new_target" != "$release_commit" ]]; then
        log_error "验证失败：origin/${target_branch} 为 ${new_target:0:8}，与待发布提交 ${release_commit:0:8} 不一致"
        verified=1
    fi
    if [[ -z "$new_source" ]]; then
        log_error "验证失败：origin/${source_branch} 分支不存在"
        verified=1
    elif [[ "$new_source" != "$release_commit" ]]; then
        log_error "验证失败：origin/${source_branch} 发生变化（${new_source:0:8}），源分支不应被发布修改"
        verified=1
    fi
    if [[ "$current" != "$source_branch" ]]; then
        log_error "验证失败：本地当前分支为 '${current:-detached}'，应停留在 ${source_branch}"
        verified=1
    fi

    if (( verified != 0 )); then
        report_remote_state "$project_dir" "$source_branch" "$target_branch"
        return 1
    fi

    log_success "远程 ${target_branch} 已更新至 ${release_commit:0:8}"
    log_success "远程 ${source_branch} 分支保留，提交历史完整"
    log_info "本地工作目录仍在 ${source_branch} 分支，可继续开发"
}

# 将远程源分支快进发布为目标分支（不切换本地分支、不改写历史、不强制推送）。
# 参数：$1 别名，$2 远程地址，$3 本地目录，$4 源分支，$5 目标分支。
# 返回：0 发布成功或已是最新；1 失败；2 用户取消。
publish_release() {
    local repo_alias="${1:?缺少仓库别名}"
    local repo_url="${2:?缺少仓库 URL}"
    local project_dir="${3:?缺少本地项目目录}"
    local source_branch="${4:?缺少源分支}"
    local target_branch="${5:?缺少目标分支}"
    local current_url release_commit target_commit commit_count

    hr
    kv "别  名" "$repo_alias"
    kv "仓库名" "$(repo_display_name "$repo_url")"
    log_info "开始检查发布条件"

    if [[ ! -d "${project_dir}/.git" ]]; then
        log_error "本地仓库不存在，无法发布：${project_dir}"
        return 1
    fi

    if ! acquire_repo_lock "$project_dir" "$repo_alias"; then
        return 1
    fi

    # 发布不修改 remote，地址与配置不一致时要求先同步，避免推错仓库。
    current_url="$(remote_url "$project_dir")"
    if [[ "$(normalize_repo_ref "$current_url")" != "$(normalize_repo_ref "$repo_url")" ]]; then
        log_error "远程地址与配置不一致，请先同步该仓库修正远程地址后再发布"
        release_repo_lock
        return 1
    fi

    # 先取远程最新状态，后续所有检查与 SHA 固定都基于同一次 fetch，避免用到过期引用。
    log_info "正在获取远程最新状态"
    if ! git -C "$project_dir" fetch origin; then
        log_error "获取远程状态失败，已停止发布"
        release_repo_lock
        return 1
    fi

    if ! check_release_preconditions "$project_dir" "$source_branch" "$target_branch"; then
        release_repo_lock
        return 1
    fi

    # 固定本次待发布提交：后续确认、复核、推送都以这个 SHA 为准。
    release_commit="$(git -C "$project_dir" rev-parse "origin/${source_branch}")"
    target_commit="$(git -C "$project_dir" rev-parse "origin/${target_branch}")"

    if [[ "$release_commit" == "$target_commit" ]]; then
        log_info "目标分支已是最新（${target_branch} 与 ${source_branch} 同为 ${release_commit:0:8}），无需重复发布"
        release_repo_lock
        return 0
    fi

    # 只允许快进：目标分支存在源分支未包含的提交时，发布可能覆盖他人改动。
    if ! git -C "$project_dir" merge-base --is-ancestor "$target_commit" "$release_commit"; then
        log_error "无法快进：${target_branch} 存在 ${source_branch} 未包含的独立提交，已停止发布"
        report_remote_state "$project_dir" "$source_branch" "$target_branch"
        release_repo_lock
        return 1
    fi

    # 待发布内容不得包含敏感文件或凭据。
    local changed_file rule
    while IFS= read -r changed_file; do
        [[ -z "$changed_file" ]] && continue
        if is_sensitive_path "$changed_file"; then
            log_error "待发布内容包含敏感文件，已停止发布：$changed_file"
            release_repo_lock
            return 1
        fi
    done < <(git -C "$project_dir" diff --name-only "$target_commit" "$release_commit")

    if rule="$(git -C "$project_dir" diff "$target_commit" "$release_commit" | detect_secret_rule)"; then
        log_error "待发布内容疑似包含敏感凭据（${rule:-命中规则}），已停止发布"
        release_repo_lock
        return 1
    fi

    commit_count="$(git -C "$project_dir" rev-list --count "${target_commit}..${release_commit}")"

    hr
    printf '当前目标 %s %s\n' \
        "${target_commit:0:8}" "$(git -C "$project_dir" log -1 --format=%s "$target_commit")"
    printf '待发布   %s %s\n' \
        "${release_commit:0:8}" "$(git -C "$project_dir" log -1 --format=%s "$release_commit")"
    printf '提交数量 %s 个\n' "$commit_count"
    printf '提交记录\n'
    git -C "$project_dir" log --format='    %h %s' -n 20 "${target_commit}..${release_commit}" >&2
    if (( commit_count > 20 )); then
        printf '    ...（其余 %s 条省略）\n' "$(( commit_count - 20 ))"
    fi
    printf '文件变更\n'
    local short_stat
    short_stat="$(git -C "$project_dir" diff --shortstat "$target_commit" "$release_commit")"
    short_stat="$(trim "$short_stat")"
    printf '    %s\n' "${short_stat:-无文件变更}"

    hr
    kv "别  名" "$repo_alias"
    kv "仓库名" "$(repo_display_name "$repo_url")"
    kv "源分支" "$source_branch"
    kv "目  标" "$target_branch"
    hr
    if ! confirm_action "确认将 ${source_branch} 最新提交发布到 ${target_branch}？[y/N]: "; then
        log_info "已取消发布，远程分支保持不变"
        release_repo_lock
        return 2
    fi

    # 确认后复核：远程分支在确认期间发生变化时停止，保证推送内容与确认内容一致。
    log_info "发布前复核远程状态"
    if ! git -C "$project_dir" fetch origin; then
        log_error "复核远程状态失败，已停止发布"
        release_repo_lock
        return 1
    fi
    if [[ "$(git -C "$project_dir" rev-parse "origin/${source_branch}" 2>/dev/null || printf '')" != "$release_commit" \
        || "$(git -C "$project_dir" rev-parse "origin/${target_branch}" 2>/dev/null || printf '')" != "$target_commit" ]]; then
        log_error "远程分支在确认期间发生变化，已停止发布，请重新检查"
        report_remote_state "$project_dir" "$source_branch" "$target_branch"
        release_repo_lock
        return 1
    fi

    log_info "正在推送发布提交：${release_commit:0:8} → origin/${target_branch}"
    if ! git -C "$project_dir" push origin "${release_commit}:refs/heads/${target_branch}"; then
        log_error "推送发布提交失败：$repo_alias（可能被分支保护规则拒绝）"
        report_remote_state "$project_dir" "$source_branch" "$target_branch"
        release_repo_lock
        return 1
    fi

    if ! verify_release_result "$project_dir" "$source_branch" "$target_branch" "$release_commit"; then
        release_repo_lock
        return 1
    fi

    log_success "发布完成：${source_branch} → ${target_branch}"
    release_repo_lock
    return 0
}

# ==================================================
# 交互菜单
# ==================================================

# 主菜单。
show_main_menu() {
    hreq
    printf '%s名  称%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$MENU_NAME"
    printf '%s作  者%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$SCRIPT_AUTHOR"
    hr
    printf '%s\n' '1. 同步全部仓库'
    printf '%s\n' '2. 同步指定仓库'
    hr
    printf '%s\n' '3. 发布正式版'
    hr
    printf '%s\n' '0. 退出'
    hreq
}

# 编号位宽：按当前条目数量自动计算十进制位数（一位数不补空格，两位数右对齐）。
# 参数：$1 条目数量。stdout：位宽。
menu_width_for() {
    local count="${1:-0}"
    printf '%s' "${#count}"
}

# 打印仓库选择菜单，编号按传入条目顺序自动生成。
# 参数：$1 标题，$2... 条目下标。
show_repo_menu() {
    local title="${1:?缺少菜单标题}"
    shift
    local -a indexes=("$@")
    local width n=0 idx

    width="$(menu_width_for "${#indexes[@]}")"

    hreq
    printf '%s名  称%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$title"
    hr
    for idx in "${indexes[@]}"; do
        n=$(( n + 1 ))
        printf '%*d. %s\n' "$width" "$n" "${ENTRY_LABEL[idx]}"
    done
    hr
    printf '%*d. %s\n' "$width" 0 '返回上级菜单'
    hreq
}

# 仓库选择菜单循环，选项与条目下标一一对应。
# 参数：$1 标题，$2 动作（sync/release），$3... 条目下标。
run_repo_menu() {
    local title="${1:?缺少菜单标题}"
    local action="${2:?缺少菜单动作}"
    shift 2
    local -a indexes=("$@")
    local total="${#indexes[@]}"
    local pick idx

    while true; do
        show_repo_menu "$title" "${indexes[@]}"
        if ! read_menu_choice "${COLOR_CYAN}请输入选项 (0-${total}): ${COLOR_RESET}"; then
            return 0
        fi
        # 只接受纯数字，避免把 0x/vim 风格的输入交给算术展开。
        if [[ ! "$MENU_INPUT" =~ ^[0-9]+$ ]]; then
            log_warn "无效的选项：${MENU_INPUT:-空}"
            printf '\n'
            continue
        fi
        # 10# 前缀按十进制解析，防止 "08" 被当成八进制。
        pick=$(( 10#$MENU_INPUT ))
        if (( pick == 0 )); then
            return 0
        fi
        if (( pick > total )); then
            log_warn "无效的选项：$MENU_INPUT"
            printf '\n'
            continue
        fi

        idx="${indexes[pick-1]}"
        case "$action" in
            sync) sync_selected_repo "$idx" || true ;;
            release)
                publish_release "${REPO_ENTRY_ALIAS[idx]}" "${REPO_ENTRY_URL[idx]}" \
                    "${REPO_ENTRY_DIR[idx]}" "${REPO_ENTRY_BRANCH[idx]}" \
                    "${REPO_ENTRY_RELEASE[idx]}" || true
                ;;
        esac
        printf '\n'
    done
}

# 「同步指定仓库」：候选条目由 ACCOUNTS 动态生成。
run_sync_menu() {
    load_repo_entries

    local -a indexes=()
    local idx
    for idx in "${!REPO_ENTRY_DIR[@]}"; do
        # 重复与目录冲突的条目不可选，避免选中后必然失败。
        (( REPO_ENTRY_DUPLICATE[idx] == 0 )) || continue
        indexes+=("$idx")
    done

    if (( ${#indexes[@]} == 0 )); then
        log_error "ACCOUNTS 中没有可同步的仓库配置"
        return 0
    fi

    build_entry_labels
    run_repo_menu '选择要同步的仓库' sync "${indexes[@]}"
}

# 「发布正式版」：候选条目只包含同时配置了 branch 与 release 的仓库。
run_publish_menu() {
    load_repo_entries

    local -a indexes=()
    local idx
    for idx in "${!REPO_ENTRY_DIR[@]}"; do
        (( REPO_ENTRY_DUPLICATE[idx] == 0 )) || continue
        [[ -n "${REPO_ENTRY_RELEASE[idx]}" && -n "${REPO_ENTRY_BRANCH[idx]}" ]] || continue
        indexes+=("$idx")
    done

    if (( ${#indexes[@]} == 0 )); then
        log_warn "当前没有启用发布管理的仓库（需同时配置 branch 与 release）"
        return 0
    fi

    build_entry_labels
    run_repo_menu '选择要发布的仓库' release "${indexes[@]}"
}

# 读取菜单选项，结果写入 MENU_INPUT；输入无效由调用方统一处理。
# 参数：$1 提示文本。返回：读取成功返回 0，遇到 EOF 返回 1。
read_menu_choice() {
    local prompt_text="${1:?缺少输入提示}"

    MENU_INPUT=''
    printf '%s' "$prompt_text"
    if ! IFS= read -r MENU_INPUT; then
        printf '\n'
        return 1
    fi
    MENU_INPUT="$(trim "$MENU_INPUT")"
}

# 主菜单循环。
run_main_menu() {
    while true; do
        show_main_menu
        if ! read_menu_choice "${COLOR_CYAN}请输入选项 (0/1/2/3): ${COLOR_RESET}"; then
            return 0
        fi
        case "$MENU_INPUT" in
            1) sync_all_repos || true ;;
            2) run_sync_menu ;;
            3) run_publish_menu ;;
            0) return 0 ;;
            *) log_warn "无效的选项：${MENU_INPUT:-空}" ;;
        esac
        printf '\n'
    done
}

# ==================================================
# 主入口
# ==================================================

main() {
    setup_colors
    # 退出与中断都释放仓库锁；INT/TERM 走正常退出路径，避免菜单被 Ctrl-C 打断后卡在原处。
    trap 'release_repo_lock' EXIT
    trap 'exit 130' INT TERM

    # 解析命令行参数。
    local interactive=0
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)
                show_help
                return 0
                ;;
            --version)
                printf '%s\n' "$SCRIPT_VERSION"
                return 0
                ;;
            --menu)
                interactive=1
                shift
                ;;
            *)
                log_error "未知参数：$1"
                return 2
                ;;
        esac
    done

    # 集中检查必要依赖。
    check_dependencies git grep sed date find uname ls

    # 记录 git 可执行路径与版本，便于排查环境差异（DEBUG 级）。
    log_debug "git 路径：$(command -v git)；版本：$(git --version 2>/dev/null || printf '未知')"

    # 加载环境变量。
    load_env_file "$DEFAULT_ENV_FILE"

    # 检查 ACCOUNTS 变量是否已定义。
    if [[ -z "${ACCOUNTS:-}" ]]; then
        log_error "ACCOUNTS 变量未定义，请在环境变量文件中配置"
        return 1
    fi

    # 交互模式：菜单代替横幅，不执行任何默认同步。
    if (( interactive == 1 )); then
        run_main_menu
        return 0
    fi

    print_script_header
    # 横幅与首个仓库块之间保留一个空行，便于区分；其余仓库块之间不加空行。
    printf '\n'

    sync_all_repos
}

main "$@"
