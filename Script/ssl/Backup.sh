#!/usr/bin/env bash

# --------------------------------------------------
# name   : Backup.sh
# desc   : GitHub 仓库自动同步与备份脚本，拉取远程更新并打包备份
# date   : 2026-11-05 16:01:01
# author : ChatGPT JK789
# ver    : 0.4.2
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

# 本脚本仅支持原生 Linux；Windows 环境请使用 Backup_Win.sh。
if (( IS_WIN == 1 )); then
    printf '[ERROR] 本脚本仅支持原生 Linux 环境，Windows Git Bash 请使用 Backup_Win.sh。\n' >&2
    exit 1
fi

# 检查并确认当前进程具备 Root 权限（仅原生 Linux 校验 EUID）。
if (( EUID != 0 )); then
    printf '[ERROR] 此脚本必须以 root 权限运行。\n' >&2
    printf '请使用以下命令重新运行（已保留原有参数）：\n  sudo -- bash %q' "$0" >&2
    if (( $# > 0 )); then
        printf ' %q' "$@" >&2
    fi
    printf '\n' >&2
    exit 1
fi

# 声明当前脚本版本。
readonly SCRIPT_VERSION="0.4.2"

# 脚本加载含凭据的 .env，收紧默认文件权限，避免新建文件被 group/other 读取。
umask 077

# ==================================================
# 全局常量与默认配置
# ==================================================

readonly SCRIPT_NAME="GitHub 仓库自动同步备份脚本"
readonly SCRIPT_DESCRIPTION="批量拉取 GitHub 仓库更新，有更新时打包 /root/GitHub 仓库目录（排除 .git）并通过 Telegram 通知结果"

# 分隔线固定为 50 个可见 ASCII 字符。
readonly HR="--------------------------------------------------"
readonly HR_EQ="=================================================="

# 备份保留数量。
readonly BACKUP_KEEP_COUNT=5

# 备份源目录：打包该目录下所有被同步的 GitHub 仓库，自动排除各仓库的 .git。
readonly BACKUP_SOURCE_DIR="/root/GitHub"

# 脚本所在目录，用于定位同目录下的 .env 配置文件。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# 默认环境变量文件路径（与脚本同目录）。
readonly DEFAULT_ENV_FILE="${SCRIPT_DIR}/.env"

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

# 打印"标签: 值"行。
kv() {
    local label="${1:?kv 缺少标签参数}"
    local value="${2-}"

    printf '  %s%s%s  %s\n' \
        "$COLOR_CYAN" "$label" "$COLOR_RESET" "$value"
}

# 计算文本的终端显示宽度：ASCII 1 字节宽 1，CJK/全角 3 字节宽 2，4 字节字符（如 emoji）按宽 2 估算。
# 宽度 = (字符数 + 字节数) / 2。
# 参数：$1 文本。stdout 输出显示宽度数值。
_display_width() {
    local text="$1"
    local byte_count char_count
    byte_count=$(printf '%s' "$text" | wc -c)
    char_count=$(printf '%s' "$text" | LC_ALL=C.UTF-8 wc -m)
    printf '%s' $(( (char_count + byte_count) / 2 ))
}

# 按终端显示宽度折行打印文本，自动在空格边界断行。
# 参数：$1 缩进空格数；$2 ANSI 颜色码（可空，空则用终端默认色）；$3 文本。
# 可用正文宽度 = 50 - 缩进，续行保持相同缩进。
print_wrapped_text() {
    local indent="$1"
    local color="${2:-}"
    local text="$3"
    local max_width=$(( 50 - indent ))
    local line="" line_width=0 word word_width first=1

    for word in $text; do
        word_width=$(_display_width "$word")
        if (( first )); then
            line="$word"
            line_width=$word_width
            first=0
        elif (( line_width + 1 + word_width > max_width )); then
            printf '%*s%s%s%s\n' "$indent" '' "$color" "$line" "$COLOR_RESET"
            line="$word"
            line_width=$word_width
        else
            line="$line $word"
            line_width=$(( line_width + 1 + word_width ))
        fi
    done
    if (( line_width > 0 )); then
        printf '%*s%s%s%s\n' "$indent" '' "$color" "$line" "$COLOR_RESET"
    fi
}

# 打印启动横幅（50 列双线，见 BASH_AGENTS.md 10.06.06）。
print_script_header() {
    hreq
    # 名称行 2 空格缩进，显示中文用途名与版本号；说明行 4 空格缩进，按显示宽度折行。
    print_wrapped_text 2 "$COLOR_CYAN" "$SCRIPT_NAME  v$SCRIPT_VERSION"
    print_wrapped_text 4 '' "$SCRIPT_DESCRIPTION"
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

说明：
  批量拉取 GitHub 仓库更新，有更新时在脚本目录创建 tar.gz 备份，
  并通过 Telegram 通知结果。需要以 root 权限运行。
EOF
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

    # 环境文件会被 source 执行，必须确认归属与权限，防止加载被篡改的配置。
    if [[ ! -O "$env_file" ]]; then
        log_error "环境变量文件不属于当前用户，拒绝加载：$env_file"
        return 1
    fi

    # 检查 group/other 是否拥有写权限，存在则拒绝加载。
    if [[ -n "$(find "$env_file" -maxdepth 0 -type f \( -perm -g=w -o -perm -o=w \) -print 2>/dev/null)" ]]; then
        log_error "环境变量文件 group/other 可写，拒绝加载：$env_file"
        return 1
    fi

    # shellcheck source=/dev/null
    source "$env_file"
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

# 发送 Telegram 通知。
# 参数：$1 通知消息内容。
# 副作用：发送 HTTP 请求到 Telegram API。
send_telegram_message() {
    local message="${1:?缺少通知消息内容}"

    # 检查必要的环境变量是否配置。
    if [[ -z "${TELEGRAM_TOKEN:-}" || -z "${CHAT_ID:-}" ]]; then
        log_debug "未配置 TELEGRAM_TOKEN 或 CHAT_ID，跳过 Telegram 发送"
        return 0
    fi

    # 使用 .env 中定义的 TG_API 作为 API 基础地址，由 curl --data-urlencode 自动完成 URL 编码。
    local api_base="${TG_API:-https://api.telegram.org}"
    # --fail 使 HTTP 4xx/5xx 返回非零退出码；通知属于辅助功能，失败仅警告不中断主流程。
    if ! curl --fail -s -o /dev/null -X POST "${api_base}/bot${TELEGRAM_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${message}" \
        --max-time 10; then
        log_warn "Telegram 通知发送失败"
    fi
}

# 处理单个仓库的同步操作。
# 参数：$1 仓库别名，$2 仓库 URL，$3 本地项目目录。
# 副作用：可能克隆仓库、拉取远程更新、修改本地 .git/config。
process_repo() {
    local repo_alias="${1:?缺少仓库别名}"
    local repo_url="${2:?缺少仓库 URL}"
    local project_dir="${3:?缺少本地项目目录}"

    hr
    kv "仓库" "$repo_alias"
    log_info "开始处理仓库：$repo_alias"

    local remote_status="无远程更新"

    # 检查本地项目目录是否存在。
    if [[ ! -d "$project_dir/.git" ]]; then
        log_info "本地仓库不存在，开始克隆：$project_dir"
        if ! git clone "$repo_url" "$project_dir"; then
            log_error "仓库克隆失败：$repo_url"
            return 1
        fi
        log_success "仓库克隆完成：$project_dir"
        update_occurred=1
    else
        log_debug "本地仓库已存在：$project_dir"
    fi

    # 配置远程仓库地址（使用 git -C 避免切换工作目录）。
    if ! git -C "$project_dir" remote | grep -q '^origin$'; then
        git -C "$project_dir" remote add origin "$repo_url"
        log_debug "已添加远程仓库 origin：$repo_url"
    else
        git -C "$project_dir" remote set-url origin "$repo_url"
        log_debug "已更新远程仓库 origin 地址：$repo_url"
    fi

    # 配置仓库级 Git 身份（不污染全局配置），统一使用规定的 Bot 身份。
    git -C "$project_dir" config --local user.name "github-actions[bot]"
    git -C "$project_dir" config --local user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git -C "$project_dir" config --local core.autocrlf input

    # 获取远程最新信息。
    log_info "正在获取远程更新：$repo_alias"
    if ! git -C "$project_dir" fetch origin; then
        log_error "获取远程更新失败：$repo_alias"
        return 1
    fi

    # 解析默认分支，避免硬编码 main。
    local default_branch
    default_branch="$(resolve_default_branch "$project_dir")"

    # 比较本地与远程提交。
    local local_commit remote_commit
    local_commit=$(git -C "$project_dir" rev-parse HEAD 2>/dev/null || printf '')
    remote_commit=$(git -C "$project_dir" rev-parse "origin/$default_branch" 2>/dev/null || printf '')

    if [[ -n "$remote_commit" && "$local_commit" != "$remote_commit" ]]; then
        log_info "检测到远程更新，正在拉取：$repo_alias"
        if ! git -C "$project_dir" pull --rebase --autostash origin "$default_branch"; then
            log_error "拉取远程更新失败：$repo_alias"
            return 1
        fi
        remote_status="已拉取远程更新"
        update_occurred=1
        log_success "远程更新已同步：$repo_alias"
    else
        log_debug "远程仓库无更新：$repo_alias"
    fi

    # 累积状态消息，使用真实换行符。
    local repo_status
    repo_status="【$repo_alias】$remote_status"
    ALL_STATUS_MSG+=$'\n'"$repo_status"

    log_success "仓库同步完成：$repo_alias"
    hr
    printf '\n'
}

# 创建备份压缩包。
# 副作用：打包备份源目录下所有仓库（排除 .git），创建备份目录和压缩文件，清理旧备份。
create_backup() {
    local backup_dir
    local timestamp
    local backup_file

    if [[ ! -d "$BACKUP_SOURCE_DIR" ]]; then
        log_error "备份源目录不存在：$BACKUP_SOURCE_DIR"
        return 1
    fi

    backup_dir="${SCRIPT_DIR}/backups"
    timestamp=$(date +'%Y%m%d_%H%M%S')
    backup_file="${backup_dir}/backup_${timestamp}.tar.gz"

    mkdir -p "$backup_dir"

    log_info "正在备份目录：$BACKUP_SOURCE_DIR"
    # 打包整个备份源目录，排除各仓库的 .git 版本控制目录。
    if ! tar -czf "$backup_file" -C "$BACKUP_SOURCE_DIR" \
        --exclude='.git' \
        -- .; then
        log_error "备份创建失败"
        return 1
    fi

    log_success "备份创建完成：$backup_file"

    # 清理旧备份，按修改时间降序排列，仅保留最近 N 个。
    local backup_index=0
    local _timestamp filepath
    while IFS=' ' read -r -d '' _timestamp filepath; do
        backup_index=$((backup_index + 1))
        if (( backup_index > BACKUP_KEEP_COUNT )); then
            rm -f -- "$filepath"
            log_debug "已删除旧备份：$filepath"
        fi
    done < <(find "$backup_dir" -maxdepth 1 -name 'backup_*.tar.gz' -type f -printf '%T@ %p\0' | sort -z -rn)
}

# ==================================================
# 主入口
# ==================================================

main() {
    setup_colors

    # 解析命令行参数（--help/--version 也先经过 Root 检查）。
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
            *)
                log_error "未知参数：$1"
                return 2
                ;;
        esac
    done

    # 集中检查必要依赖。
    check_dependencies git curl tar find grep sort date wc uname

    # 记录 git 可执行路径与版本，便于排查环境差异（DEBUG 级）。
    log_debug "git 路径：$(command -v git)；版本：$(git --version 2>/dev/null || printf '未知')"

    print_script_header
    printf '\n'

    # 加载环境变量。
    load_env_file "$DEFAULT_ENV_FILE"

    # 检查 ACCOUNTS 变量是否已定义。
    if [[ -z "${ACCOUNTS:-}" ]]; then
        log_error "ACCOUNTS 变量未定义，请在环境变量文件中配置"
        exit 1
    fi

    # 初始化状态消息与更新标志。
    ALL_STATUS_MSG=""
    update_occurred=0

    # 遍历 ACCOUNTS 并处理每个仓库。
    local repo_alias repo_url project_dir
    while IFS=',' read -r repo_alias repo_url project_dir || [[ -n "$repo_alias" ]]; do
        # 跳过空行和注释行。
        [[ -z "$repo_alias" || "$repo_alias" =~ ^[[:space:]]*# ]] && continue
        # 校验必填字段，缺 URL 或目录时跳过该行。
        if [[ -z "$repo_url" || -z "$project_dir" ]]; then
            log_warn "账号行字段不完整，已跳过：$repo_alias"
            continue
        fi
        process_repo "$repo_alias" "$repo_url" "$project_dir" || log_warn "仓库处理失败：$repo_alias"
    done <<< "$ACCOUNTS"

    # 有更新才创建备份，无更新则跳过。
    local backup_status
    if (( update_occurred == 1 )); then
        create_backup
        backup_status="备份：已创建"
    else
        log_info "未检测到更新，跳过备份"
        backup_status="备份：无更新，跳过"
    fi

    # 构建 Telegram 通知消息（printf 解析真实换行符）。
    local notify_message
    printf -v notify_message 'GitHub 仓库同步完成\n时间：%s\n%s\n%s' \
        "$(date +'%Y-%m-%d %H:%M:%S')" \
        "$ALL_STATUS_MSG" \
        "$backup_status"

    # 发送通知。
    send_telegram_message "$notify_message"

    hreq
    log_success "全部任务执行完成"
    hreq
}

main "$@"
