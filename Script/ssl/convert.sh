#!/usr/bin/env bash

# --------------------------------------------------
# name   : convert.sh
# desc   : 批量将 Loon 插件转换为 Surge 模块，支持多 JSON 订阅源、并发与增量转换
# date   : 2026-11-04 16:24:06
# author : ChatGPT JK789
# ver    : 2.2.1
# --------------------------------------------------

# 启用 Bash 严格模式。
set -Eeuo pipefail

# 检查并确认当前进程具备 Root 权限。
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
# 必须与文件头 ver 完全一致；声明格式统一见 AGENTS.md 20.6.14.2。
# shellcheck disable=SC2034 # 供版本管理工具静态读取，脚本无需运行时展示版本。
readonly SCRIPT_VERSION="2.2.1"

# 全局常量与默认配置。
# SCRIPT_NAME 为标题使用的简体中文显示名称，须根据脚本用途概括，不使用文件名；
# SCRIPT_DESCRIPTION 与文件头 desc 保持一致，供统一启动标题使用。
readonly SCRIPT_NAME='Loon 插件转 Surge 模块脚本'
readonly SCRIPT_DESCRIPTION='批量将 Loon 插件转换为 Surge 模块，支持多 JSON 订阅源、并发与增量转换'
readonly DEFAULT_OUTPUT_DIR='./output'
readonly DEFAULT_CONCURRENCY=5
readonly DEFAULT_CONVERT_TYPE='loon-plugin'
readonly DEFAULT_CONVERT_TARGET='surge-module'
readonly DEFAULT_TIMEOUT=30
# 转换进度提示的步长：每完成该数量报告一次进度，避免逐条刷屏。
readonly PROGRESS_STEP=25
# 统一双线分隔符，固定 50 个可见 ASCII 字符。
readonly HR_EQ="=================================================="

# 颜色变量先初始化为空字符串，避免严格模式下因未定义而退出。
COLOR_RESET=''
COLOR_RED=''
COLOR_GREEN=''
COLOR_YELLOW=''
COLOR_BLUE=''
COLOR_CYAN=''
COLOR_GRAY=''

# 根据终端能力和 NO_COLOR 环境变量初始化日志颜色。
# stdout 与 stderr 均须为交互式终端才启用颜色，避免颜色码写入重定向流。
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

# 统一日志函数，全部写入 stderr，避免污染 stdout 数据流。
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

# 打印双线分隔符。
hreq() {
    printf '%s\n' "${COLOR_BLUE}${HR_EQ}${COLOR_RESET}"
}

# 输出非管理脚本统一启动标题。
# 名称与版本使用青色，前后双线使用蓝色；用途说明使用默认终端颜色。
# 标题中不显示任何路径。
print_script_header() {
    hreq
    printf '  %s%s  v%s%s\n' \
        "$COLOR_CYAN" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$COLOR_RESET"
    printf '  %s\n' "$SCRIPT_DESCRIPTION"
    hreq
}

# 加载 .env 配置文件。
# 返回：成功返回 0；文件不存在返回非 0。
load_config() {
    local env_file="$1"

    if [[ ! -f "$env_file" ]]; then
        log_error "配置文件不存在：$env_file"
        return 1
    fi

    # shellcheck disable=SC1090,SC1091
    # 豁免说明：.env 路径由调用方运行时传入，非静态常量，
    # ShellCheck 无法静态跟踪 source 目标；.env 是用户维护的配置
    # 文件（非项目代码），按项目约定由 load_config 统一加载，风险可控。
    source "$env_file"
}

# 检查依赖命令是否已安装。
# 参数：$1... 表示一个或多个命令名称。
# 返回：全部存在返回 0；任意一个缺失返回非 0。
check_dependencies() {
    local dependency_name

    for dependency_name in "$@"; do
        if ! command -v "$dependency_name" >/dev/null 2>&1; then
            log_error "缺少依赖：$dependency_name"
            return 1
        fi
    done
}

# 从 URL 中提取域名（去掉协议前缀和路径部分）。
# 参数：$1 表示完整 URL。
# 输出：stdout 输出域名。
get_domain() {
    local url="$1"

    url="${url#http://}"
    url="${url#https://}"
    url="${url%%/*}"
    printf '%s\n' "$url"
}

# 下载 URL 内容到 stdout。
# 参数：$1 表示 URL。
# 输出：stdout 输出响应内容；失败返回非 0。
download_to_stdout() {
    local url="$1"

    # 静默 stderr 以避免批量运行刷屏；-f 使 HTTP 错误返回非零，失败由调用方显式处理。
    if [[ "$DOWNLOADER" == 'curl' ]]; then
        curl -fsSL --max-time "$DOWNLOAD_TIMEOUT" "$url" 2>/dev/null
    else
        wget -qO- --timeout="$DOWNLOAD_TIMEOUT" "$url" 2>/dev/null
    fi
}

# 下载 URL 内容到指定文件。
# 参数：$1 表示 URL；$2 表示输出文件路径。
# 返回：成功返回 0；失败返回非 0。
download_to_file() {
    local url="$1"
    local output_file="$2"

    # 静默 stderr 以避免批量运行刷屏；-f 使 HTTP 错误返回非零，失败由调用方显式处理。
    if [[ "$DOWNLOADER" == 'curl' ]]; then
        curl -fsSL --max-time "$DOWNLOAD_TIMEOUT" "$url" -o "$output_file" 2>/dev/null
    else
        wget -qO "$output_file" --timeout="$DOWNLOAD_TIMEOUT" "$url" 2>/dev/null
    fi
}

# 将本地文件的修改时间格式化为 HTTP-date，供 If-Modified-Since 条件请求使用。
# 参数：$1 表示本地文件路径。
# 输出：stdout 输出 HTTP-date 字符串（如 Wed, 21 Oct 2026 07:28:00 GMT）。
# 返回：成功返回 0；文件不存在或时间读取失败返回非 0。
get_http_condition_time() {
    local file_path="$1"
    local epoch
    local http_date

    if [[ ! -f "$file_path" ]]; then
        return 1
    fi

    # 兼容 GNU stat（-c %Y）与 BSD stat（-f %m）；容器为 Alpine/GNU 环境。
    epoch="$(stat -c '%Y' "$file_path" 2>/dev/null || stat -f '%m' "$file_path" 2>/dev/null)" || return 1

    # 兼容 GNU date（-d @epoch）与 BSD date（-r epoch）；输出英文 HTTP-date。
    http_date="$(date -u -d "@${epoch}" '+%a, %d %b %Y %H:%M:%S GMT' 2>/dev/null || date -u -r "$epoch" '+%a, %d %b %Y %H:%M:%S GMT')" || return 1

    printf '%s\n' "$http_date"
}

# 检查上游插件是否有更新（HTTP 条件请求 If-Modified-Since 对比本地文件时间）。
# 参数：$1 表示上游插件 URL；$2 表示本地已保存的 .sgmodule 文件路径。
# 返回：0=需要转换（本地无文件/已更新/无法判断，保守转换）；1=上游未更新，跳过。
check_plugin_updated() {
    local source_url="$1"
    local output_file="$2"
    local if_modified_since
    local http_code

    # 本地尚无文件时，直接转换。
    if [[ ! -f "$output_file" ]]; then
        return 0
    fi

    # 本地文件时间无法读取时，保守转换。
    if ! if_modified_since="$(get_http_condition_time "$output_file")"; then
        return 0
    fi

    if [[ "$DOWNLOADER" == 'curl' ]]; then
        # curl 直接输出响应状态码；-L 跟随重定向以与 wget 行为一致。
        http_code="$(curl -sIL --max-time "$DOWNLOAD_TIMEOUT" -H "If-Modified-Since: ${if_modified_since}" -o /dev/null -w '%{http_code}' "$source_url" 2>/dev/null || true)"
    else
        # wget 无直接状态码输出，解析 --spider 响应头中的状态行。
        http_code="$(wget --spider -S --timeout="$DOWNLOAD_TIMEOUT" --header="If-Modified-Since: ${if_modified_since}" "$source_url" 2>&1 | grep -oE 'HTTP/[0-9.]+ [0-9]{3}' | tail -n 1 | awk '{print $2}' || true)"
    fi

    # 状态码无法获取（网络错误、服务器不支持 HEAD 等）时保守转换，避免漏更新。
    # 304=Not Modified，表示上游未比本地文件更新，跳过。
    if [[ "$http_code" == '304' ]]; then
        return 1
    fi
    return 0
}

# 从 JSON 订阅源提取插件 URL 并填入全局插件映射。
# 参数：$1 表示 JSON 源 URL。
# 副作用：写入全局关联数组 PLUGIN_MAP，key=插件URL，value="子目录|名称"。
collect_plugins_from_json() {
    local json_url="$1"
    local subdir
    local json_content
    local plugin_urls
    local count=0
    local purl
    local name

    subdir="$(get_domain "$json_url")"
    log_info "解析 JSON 源：$json_url"
    log_info "子目录：$subdir"

    if ! json_content="$(download_to_stdout "$json_url")"; then
        log_warn "JSON 源下载失败，已跳过：$json_url"
        return 0
    fi

    # grep 无匹配时返回 1，属预期行为（该源可能没有 .lpx/.plugin 插件）。
    plugin_urls="$(printf '%s\n' "$json_content" | grep -oE 'https?://[^"]+\.(lpx|plugin)' | sort -u || true)"

    if [[ -z "$plugin_urls" ]]; then
        log_warn "JSON 源中未找到插件 URL，已跳过：$json_url"
        return 0
    fi

    while IFS= read -r purl; do
        [[ -z "$purl" ]] && continue
        # 从 URL 提取文件名并去掉后缀；_remove_ads 缩短为 _ads。
        name="$(basename "$purl")"
        name="${name%.*}"
        name="${name//_remove_ads/_ads}"
        PLUGIN_MAP["$purl"]="${subdir}|${name}"
        count=$((count + 1))
    done <<< "$plugin_urls"

    log_success "提取到 ${count} 个插件 → ${subdir}/"
}

# 转换单个插件（在子 Shell 中执行，供并发调度）。
# 参数：$1 表示子目录；$2 表示插件名称；$3 表示插件源 URL。
# 输出：stdout 输出 "ok" 或 "fail"，供并发结果统计。
convert_one() {
    local subdir="$1"
    local name="$2"
    local source_url="$3"
    local convert_url
    local output_file
    local output_dir="${OUTPUT_DIR}/${subdir}"

    mkdir -p "$output_dir"

    # Script-Hub 转换接口路径：/file/_start_/{源URL}/_end_/{名称}.sgmodule
    convert_url="${SCRIPT_HUB_URL}/file/_start_/${source_url}/_end_/${name}.sgmodule?type=${CONVERT_TYPE}&target=${CONVERT_TARGET}&del=true&jqEnabled=true"
    output_file="${output_dir}/${name}.sgmodule"

    # 增量转换：启用 CHECK_UPDATED 且上游未更新时跳过，不替换已保存的模块。
    if [[ "${CHECK_UPDATED:-true}" == 'true' ]]; then
        if ! check_plugin_updated "$source_url" "$output_file"; then
            printf 'skip\n'
            return 0
        fi
    fi

    if download_to_file "$convert_url" "$output_file"; then
        # 校验产物：文件非空且不是错误页（grep 无匹配返回 1 属预期，表示校验通过）。
        if [[ -s "$output_file" ]] && ! head -5 "$output_file" | grep -qi 'error\|404\|not found'; then
            printf 'ok\n'
            return 0
        fi
    fi

    rm -f "$output_file"
    printf 'fail\n'
}

# 并发批量转换全部插件。
# 副作用：将转换结果写入 OUTPUT_DIR 下各子目录；统计成功与失败数量并打印。
convert_all() {
    local source_url
    local info
    local subdir
    local name
    local running=0
    local done_count=0
    local last_report=0
    local total_count=${#PLUGIN_MAP[@]}
    local success
    local failed
    local skipped
    local tmp_dir
    local results_file

    # 创建临时目录并显式检查退出状态，避免创建失败时结果写入根目录。
    tmp_dir="$(mktemp -d)" || { log_error "创建临时目录失败"; return 1; }
    results_file="${tmp_dir}/results"

    # 异常退出时清理临时目录。
    trap 'rm -rf "$tmp_dir"' EXIT

    log_info "开始转换：共 ${total_count} 个插件（并发 ${CONCURRENCY}）"

    for source_url in "${!PLUGIN_MAP[@]}"; do
        info="${PLUGIN_MAP[$source_url]}"
        subdir="${info%%|*}"
        name="${info#*|}"

        # 并发控制：达到上限时等待任意一个子任务结束，并按固定步长报告进度。
        while (( running >= CONCURRENCY )); do
            wait -n
            running=$((running - 1))
            done_count=$((done_count + 1))
            if (( done_count >= last_report + PROGRESS_STEP )); then
                log_info "转换进度：${done_count} / ${total_count}"
                last_report=$done_count
            fi
        done

        (convert_one "$subdir" "$name" "$source_url" >> "$results_file") &
        running=$((running + 1))
    done

    # 等待所有剩余子任务完成，同样按步长报告进度。
    while (( running > 0 )); do
        wait -n
        running=$((running - 1))
        done_count=$((done_count + 1))
        if (( done_count >= last_report + PROGRESS_STEP )); then
            log_info "转换进度：${done_count} / ${total_count}"
            last_report=$done_count
        fi
    done

    # grep -c 无匹配时返回 1 且输出 0，属预期行为。
    success="$(grep -c '^ok$' "$results_file" || true)"
    failed="$(grep -c '^fail$' "$results_file" || true)"
    skipped="$(grep -c '^skip$' "$results_file" || true)"

    rm -rf "$tmp_dir"
    trap - EXIT

    if [[ "${CHECK_UPDATED:-true}" == 'true' ]]; then
        log_success "转换完成：成功 ${success} / 失败 ${failed} / 跳过 ${skipped}（共 ${total_count}）"
    else
        log_success "转换完成：成功 ${success} / 失败 ${failed}（共 ${total_count}）"
    fi
    log_info "输出目录：${OUTPUT_DIR}/"
}

# 主入口：加载配置、解析插件列表并批量转换。
main() {
    local script_dir
    local env_file
    local total
    local json_url

    # 基于 BASH_SOURCE 定位脚本目录，避免依赖当前工作目录。
    # 定位脚本所在目录并显式检查退出状态，失败时无法加载同目录 .env。
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || { log_error "无法定位脚本目录"; return 1; }
    env_file="${script_dir}/.env"

    setup_colors

    # 统一启动标题：业务前的第一组终端输出。
    print_script_header

    if ! load_config "$env_file"; then
        return 1
    fi

    # 配置校验：必填项缺失时给出明确错误并退出。
    : "${SCRIPT_HUB_URL:?请在 .env 中设置 SCRIPT_HUB_URL}"
    CONVERT_TYPE="${CONVERT_TYPE:-$DEFAULT_CONVERT_TYPE}"
    CONVERT_TARGET="${CONVERT_TARGET:-$DEFAULT_CONVERT_TARGET}"
    OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
    CONCURRENCY="${CONCURRENCY:-$DEFAULT_CONCURRENCY}"
    # 外部输入校验（AGENTS.md 6.19）：CONCURRENCY 须为无前导零的 1-50 整数，
    # 避免用户输入被当作算术表达式执行、前导零触发八进制错误或压垮 Script-Hub。
    if [[ ! "$CONCURRENCY" =~ ^[1-9][0-9]*$ ]] || (( CONCURRENCY < 1 || CONCURRENCY > 50 )); then
        log_error "CONCURRENCY 必须为 1-50 的整数（当前值：${CONCURRENCY}）"
        return 1
    fi
    CHECK_UPDATED="${CHECK_UPDATED:-true}"
    if [[ "$CHECK_UPDATED" != 'true' && "$CHECK_UPDATED" != 'false' ]]; then
        log_error "CHECK_UPDATED 只能为 true 或 false（当前值：${CHECK_UPDATED}）"
        return 1
    fi
    JSON_SOURCES=("${JSON_SOURCES[@]:-}")

    SCRIPT_HUB_URL="${SCRIPT_HUB_URL%/}"
    DOWNLOAD_TIMEOUT="$DEFAULT_TIMEOUT"

    # 检测下载工具：优先 curl，其次 wget（Alpine 容器常无 curl）。
    if command -v curl >/dev/null 2>&1; then
        DOWNLOADER='curl'
    elif command -v wget >/dev/null 2>&1; then
        DOWNLOADER='wget'
    else
        log_error "系统中既没有 curl 也没有 wget，请先安装其中一个"
        return 1
    fi

    # 声明全局插件映射。
    declare -A PLUGIN_MAP

    mkdir -p "$OUTPUT_DIR"

    log_info "Script-Hub：$SCRIPT_HUB_URL"
    log_info "输出目录：$OUTPUT_DIR"
    log_info "下载工具：$DOWNLOADER"
    printf '\n'

    for json_url in "${JSON_SOURCES[@]}"; do
        # 去除首尾空白，使用参数展开避免 xargs 对含引号 URL 解析失败。
        json_url="${json_url#"${json_url%%[![:space:]]*}"}"
        json_url="${json_url%"${json_url##*[![:space:]]}"}"
        [[ -z "$json_url" || "$json_url" == \#* ]] && continue
        collect_plugins_from_json "$json_url"
    done

    # 空关联数组在旧版 Bash 下直接取长度会触发 unbound variable，改用遍历计数。
    total=0
    for _ in "${PLUGIN_MAP[@]}"; do
        total=$((total + 1))
    done
    printf '\n'
    log_info "共 ${total} 个插件待转换（并发 ${CONCURRENCY}）"
    printf '\n'

    if (( total == 0 )); then
        log_warn "没有需要转换的插件，退出。"
        return 0
    fi

    convert_all
}

main "$@"
