#!/usr/bin/env bash

# --------------------------------------------------
# name   : Backup_Win.sh
# desc   : Windows 版 GitHub 仓库自动同步脚本，拉取更新并提交本地变更
# date   : 2026-11-04 19:48:44
# author : ChatGPT JK789
# ver    : 0.5.0
# 更新时间: 2026-11-04 19:48:44
# --------------------------------------------------

# 启用 Bash 严格模式。
set -Eeuo pipefail

# Windows Git Bash 环境无 Root 概念，跳过 Root 检查。
# 本脚本仅在 Windows Git Bash 环境运行，不涉及系统级特权操作。

# 声明当前脚本版本。
readonly SCRIPT_VERSION="0.5.0"

# ==================================================
# 全局常量与默认配置
# ==================================================

readonly SCRIPT_NAME="GitHub 仓库自动同步脚本"
readonly SCRIPT_DESCRIPTION="Windows 版，拉取 GitHub 仓库更新并检测本地变更，自动提交推送"

# 分隔线固定为 50 个可见 ASCII 字符。
readonly HR="--------------------------------------------------"
readonly HR_EQ="=================================================="

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
  批量拉取 GitHub 仓库更新，检测到本地变更时自动提交并推送，
  同时更新脚本文件头中的日期。在 Windows Git Bash 环境运行。
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
    repo_root="$(git -C "$repo_dir" rev-parse --show-toplevel)"

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
    done < <(git -C "$repo_dir" diff --name-only --diff-filter=M -z)
}

# 检测本地变更并提交推送。
# 参数：$1 仓库别名，$2 仓库目录。
# 副作用：更新文件头日期、提交并推送本地变更。
commit_local_changes() {
    local alias="${1:?缺少仓库别名}"
    local project_dir="${2:?缺少仓库目录}"

    if [[ -n "$(git -C "$project_dir" status --porcelain)" ]]; then
        log_info "检测到本地变更，正在提交：$alias"
        update_header_date "$project_dir"
        git -C "$project_dir" add -A

        # 显式检查提交结果，失败时返回明确错误。
        if ! git -C "$project_dir" commit -m "chore: auto sync $(date +'%Y-%m-%d %H:%M:%S')"; then
            log_error "提交本地变更失败：$alias"
            return 1
        fi

        log_info "正在推送本地变更：$alias"
        if ! git -C "$project_dir" push origin main; then
            log_error "推送本地变更失败：$alias"
            return 1
        fi
        log_success "本地变更已提交并推送：$alias"
    else
        log_debug "本地仓库无变更：$alias"
    fi
}

# 处理单个仓库的同步操作。
# 参数：$1 仓库别名，$2 仓库 URL，$3 本地项目目录。
# 副作用：可能克隆仓库、拉取远程更新、修改本地 .git/config、提交并推送。
process_repo() {
    local alias="${1:?缺少仓库别名}"
    local repo_url="${2:?缺少仓库 URL}"
    local project_dir="${3:?缺少本地项目目录}"

    hr
    kv "仓库" "$alias"
    log_info "开始处理仓库：$alias"

    # 检查本地项目目录是否存在。
    if [[ ! -d "$project_dir/.git" ]]; then
        log_info "本地仓库不存在，开始克隆：$project_dir"
        if ! git clone "$repo_url" "$project_dir"; then
            log_error "仓库克隆失败：$repo_url"
            return 1
        fi
        log_success "仓库克隆完成：$project_dir"
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
    log_info "正在获取远程更新：$alias"
    if ! git -C "$project_dir" fetch origin; then
        log_error "获取远程更新失败：$alias"
        return 1
    fi

    # 比较本地与远程提交。
    local local_commit remote_commit
    local_commit=$(git -C "$project_dir" rev-parse HEAD 2>/dev/null || printf '')
    remote_commit=$(git -C "$project_dir" rev-parse origin/main 2>/dev/null || printf '')

    if [[ -n "$remote_commit" && "$local_commit" != "$remote_commit" ]]; then
        log_info "检测到远程更新，正在拉取：$alias"
        if ! git -C "$project_dir" pull --rebase --autostash origin main; then
            log_error "拉取远程更新失败：$alias"
            return 1
        fi
        log_success "远程更新已同步：$alias"
    else
        log_debug "远程仓库无更新：$alias"
    fi

    # 检测并提交本地变更。
    commit_local_changes "$alias" "$project_dir"

    log_success "仓库同步完成：$alias"
    hr
    printf '\n'
}

# ==================================================
# 主入口
# ==================================================

main() {
    setup_colors

    # 解析命令行参数。
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
    check_dependencies git grep sed date find

    hreq
    printf '  %s%s  v%s%s\n' "$COLOR_CYAN" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$COLOR_RESET"
    printf '  %s\n' "$SCRIPT_DESCRIPTION"
    hreq
    printf '\n'

    # 加载环境变量。
    load_env_file "$DEFAULT_ENV_FILE"

    # 检查 ACCOUNTS 变量是否已定义。
    if [[ -z "${ACCOUNTS:-}" ]]; then
        log_error "ACCOUNTS 变量未定义，请在环境变量文件中配置"
        exit 1
    fi

    # 遍历 ACCOUNTS 并处理每个仓库。
    local alias repo_url project_dir
    while IFS=',' read -r alias repo_url project_dir || [[ -n "$alias" ]]; do
        # 跳过空行和注释行。
        [[ -z "$alias" || "$alias" =~ ^[[:space:]]*# ]] && continue
        process_repo "$alias" "$repo_url" "$project_dir" || log_warn "仓库处理失败：$alias"
    done <<< "$ACCOUNTS"

    hreq
    log_success "全部任务执行完成"
    hreq
}

main "$@"
