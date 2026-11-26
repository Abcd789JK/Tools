#!/usr/bin/env bash

# --------------------------------------------------
# name   : convert.sh
# desc   : 批量将 Loon 插件转换为 Surge 模块，支持多 JSON 订阅源、并发与增量转换
# date   : 2026-11-26 20:17:04
# author : ChatGPT JK789
# ver    : 2.4.4
# --------------------------------------------------

# 启用 Bash 严格模式。
set -Eeuo pipefail

# 任务结果通知状态（内部状态，不参与业务配置，也不写入日志）。
TASK_ERROR_MSG=''
TASK_SUMMARY=''
TASK_DETAIL=''
TASK_CHANGED=''
TASK_TMP_DIR=''
# 来源显示顺序：按 JSON_SOURCES 配置顺序记录，供通知的“变更详细”稳定展示。
SOURCE_NAMES=()

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

# 声明当前脚本版本，须与文件头 ver 一致，供启动标题读取。
readonly SCRIPT_VERSION="2.4.4"

# 全局常量与默认配置。
# SCRIPT_NAME 为标题使用的简体中文显示名称，须根据脚本用途概括，不使用文件名；
# SCRIPT_DESCRIPTION 与文件头 desc 保持一致，供统一启动标题使用。
readonly SCRIPT_NAME='Loon 插件转 Surge 模块脚本'
readonly SCRIPT_DESCRIPTION='批量将 Loon 插件转换为 Surge 模块，支持多 JSON 订阅源、并发与增量转换'
readonly SCRIPT_AUTHOR='ChatGPT JK789'

# ==================================================
# 内置默认配置（保留空白，用户可按需填写）
# 同目录存在 .env 时，以 .env 中的同名项为准；否则使用下面填写的内置值。
# 内置值与 .env 均为空时，脚本会给出明确错误并退出。
# ==================================================
# Script-Hub Docker 服务地址（不带结尾斜杠），示例：http://localhost:9100
readonly DEFAULT_SCRIPT_HUB_URL=''
# 转换参数：type=源格式（loon-plugin / qx-rewrite / surge-module）
#          target=目标格式（surge-module / shadowrocket-module / stash）
readonly DEFAULT_CONVERT_TYPE=''
readonly DEFAULT_CONVERT_TARGET=''
# 输出目录（转换后的 .sgmodule 文件保存位置）
readonly DEFAULT_OUTPUT_DIR=''
# 并发数（同时转换多少个插件，建议 5-10，太高可能压垮 Script-Hub）
readonly DEFAULT_CONCURRENCY=''
# 增量转换检测：始终启用。仅当检测到上游插件更新时才替换本地文件；
# 上游未更新时直接跳过并保留本地文件，不再提供“每次全量替换”模式。
# 该变量保留仅为兼容旧版 .env 的配置项，其值不再影响是否检测更新。
readonly DEFAULT_CHECK_UPDATED='true'
# JSON 订阅源：每行一个地址，自动拉取并解析其中所有插件地址。
# 三种写法（可混用）：
#   "https://example.com/list.json"          → 子目录取域名 example.com（默认）
#   "我的插件|https://example.com/list.json"  → 子目录用自定义名称
#   "|https://example.com/list.json"          → 不建子目录，模块直接放输出目录
# 自定义名称中的 / 和 \ 会替换为 _；名称留空即平铺。
readonly DEFAULT_JSON_SOURCES=()
# 下载超时（秒，内置固定值）
readonly DEFAULT_TIMEOUT=30
# Telegram 执行结果通知（可选）：凭据为空时跳过通知，不影响转换流程。
# 键名与同目录 Backup.sh 一致；.env 中的同名项优先，缺失时回退到下列内置值。
readonly DEFAULT_TELEGRAM_TOKEN=''
readonly DEFAULT_CHAT_ID=''
readonly DEFAULT_TG_API='https://api.telegram.org'

# 先用内置默认配置初始化工作变量；后续 .env 中的同名项会覆盖这些值。
# [@...:-] 形式兼容旧版 Bash 下空数组在 set -u 中的展开。
SCRIPT_HUB_URL="$DEFAULT_SCRIPT_HUB_URL"
CONVERT_TYPE="$DEFAULT_CONVERT_TYPE"
CONVERT_TARGET="$DEFAULT_CONVERT_TARGET"
OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
CONCURRENCY="$DEFAULT_CONCURRENCY"
CHECK_UPDATED="$DEFAULT_CHECK_UPDATED"
JSON_SOURCES=("${DEFAULT_JSON_SOURCES[@]:-}")
TELEGRAM_TOKEN="$DEFAULT_TELEGRAM_TOKEN"
CHAT_ID="$DEFAULT_CHAT_ID"
TG_API="$DEFAULT_TG_API"
# 转换进度提示的步长：每完成该数量报告一次进度，避免逐条刷屏。
readonly PROGRESS_STEP=50
# 统一分隔符，固定 50 个可见 ASCII 字符。
readonly HR="--------------------------------------------------"
readonly HR_EQ="=================================================="

# 颜色变量先初始化为空字符串，避免严格模式下因未定义而退出。
COLOR_RESET=''
COLOR_RED=''
COLOR_GREEN=''
COLOR_YELLOW=''
COLOR_BLUE=''
COLOR_CYAN=''

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
    # 记录最近一次错误文本，供退出时组装通知；不输出任何配置值。
    TASK_ERROR_MSG="$*"
    printf '%s[ERROR]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
}

# 将秒数格式化为易读耗时文本（<60s 显示 "N秒"，否则显示 "N分MM秒"），与 Backup.sh 保持一致。
format_duration() {
    local total_seconds="${1:-0}"
    local minutes=$((total_seconds / 60))
    local seconds=$((total_seconds % 60))

    if (( minutes > 0 )); then
        printf '%d分%02d秒' "$minutes" "$seconds"
    else
        printf '%d秒' "$seconds"
    fi
}

# 发送 Telegram 通知（辅助功能）：未配置凭据、缺少工具或发送失败时均静默跳过，
# 不改变主流程退出码；凭据仅用于请求，绝不写入日志。
# 参数：$1 通知正文。
send_telegram_message() {
    local message="$1"

    if [[ -z "${TELEGRAM_TOKEN:-}" || -z "${CHAT_ID:-}" ]]; then
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        log_warn "未检测到 curl，跳过 Telegram 通知"
        return 0
    fi

    local api_base="${TG_API:-$DEFAULT_TG_API}"
    local http_code=''
    local rc=0

    # token 位于 URL 中：不回显 URL、不透传 curl stderr，避免泄露配置值。
    # 仅用 -w 取 HTTP 状态码、用退出码区分网络错误，供失败时分类诊断。
    http_code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${api_base}/bot${TELEGRAM_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=${message}" \
        --max-time 10 2>/dev/null)" || rc=$?

    # HTTP 2xx 即发送成功。
    if (( rc == 0 )) && [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        return 0
    fi

    # 诊断信息只含状态码/退出码，不含 URL、token、chat_id。
    if [[ "$http_code" == '401' ]]; then
        log_warn "Telegram 通知发送失败：HTTP 401（token 无效或已撤销）"
    elif [[ "$http_code" == '404' ]]; then
        log_warn "Telegram 通知发送失败：HTTP 404（token 或 chat_id 不正确）"
    elif [[ "$http_code" == '400' ]]; then
        log_warn "Telegram 通知发送失败：HTTP 400（请求内容或格式被拒绝）"
    elif [[ "$http_code" == '429' ]]; then
        log_warn "Telegram 通知发送失败：HTTP 429（发送过于频繁）"
    elif [[ -n "$http_code" && "$http_code" != '000' ]]; then
        log_warn "Telegram 通知发送失败：HTTP ${http_code}"
    else
        # curl 网络层失败：http_code 为 000 或空，按退出码区分。
        case "$rc" in
            6)  log_warn "Telegram 通知发送失败：无法解析 TG_API 域名（检查网络/DNS）" ;;
            7)  log_warn "Telegram 通知发送失败：无法连接 TG_API（检查网络/代理/防火墙）" ;;
            28) log_warn "Telegram 通知发送失败：连接 TG_API 超时（检查网络/代理）" ;;
            *)  log_warn "Telegram 通知发送失败：网络错误（curl 退出码 ${rc}）" ;;
        esac
    fi
    return 0
}

# 按 Backup.sh 的版式组装并发送任务结果通知：标题 → 状态/时间/耗时/结果。
# 参数：$1 任务退出码（0=正常结束）。
notify_task_result() {
    local rc="$1"
    local status_icon status_text message

    # 与 Backup.sh 一致：只有“全部成功 / 存在失败”两种状态文案；
    # 失败与否由退出码与 TASK_ERROR_MSG 判定，失败数量体现在结果行中。
    if (( rc == 0 )) && [[ -z "$TASK_ERROR_MSG" ]]; then
        status_icon='✅'
        status_text='全部成功'
    else
        status_icon='❌'
        status_text='存在失败'
    fi

    printf -v message \
        '<b>📢 Debian 自动化任务通知</b>\n\n✉️ 标题：Loon 插件转 Surge 模块\n%s 状态：%s\n🕐 时间：%s\n⏱️ 耗时：%s\n📊 合计：%s\n\n📈 变更详细%s%s' \
        "$status_icon" "$status_text" \
        "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'unknown')" \
        "$(format_duration "${TASK_SECONDS:-0}")" \
        "${TASK_SUMMARY:-未完成统计}" \
        "${TASK_DETAIL:-}" \
        "${TASK_CHANGED:-}"

    send_telegram_message "$message"
    return 0
}

# 统一退出处理：清理可能残留的临时目录并发送结果通知，保留原退出码。
on_script_exit() {
    local rc=$?
    trap - EXIT
    if [[ -n "$TASK_TMP_DIR" ]]; then
        rm -rf "$TASK_TMP_DIR"
        TASK_TMP_DIR=''
    fi
    # 通知属于辅助功能：任何异常都不得改变原流程的退出码。
    TASK_SECONDS="$SECONDS"
    notify_task_result "$rc" || true
    exit "$rc"
}

# 打印单线分隔线。
hr() {
    printf '%s\n' "${COLOR_BLUE}${HR}${COLOR_RESET}"
}

# 打印双线分隔符。
hreq() {
    printf '%s\n' "${COLOR_BLUE}${HR_EQ}${COLOR_RESET}"
}

# 打印启动横幅：双线 → 名称/作者（标签青色）→ 单线 → 说明（标签青色）→ 双线。
print_script_header() {
    hreq
    printf '%s名  称%s %s v%s\n' "$COLOR_CYAN" "$COLOR_RESET" "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf '%s作  者%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$SCRIPT_AUTHOR"
    hr
    printf '%s说  明%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$SCRIPT_DESCRIPTION"
    hreq
}

# 加载 .env 配置文件（存在则以其中同名项覆盖内置默认配置）。
# .env 不存在不是错误：沿用脚本内置默认配置继续执行，返回 0。
load_config() {
    local env_file="$1"

    if [[ ! -f "$env_file" ]]; then
        log_info "未检测到 .env，使用脚本内置默认配置"
        return 0
    fi

    # shellcheck disable=SC1090,SC1091
    # 豁免说明：.env 路径由调用方运行时传入，非静态常量，
    # ShellCheck 无法静态跟踪 source 目标；.env 是用户维护的配置
    # 文件（非项目代码），按项目约定由 load_config 统一加载，风险可控。
    source "$env_file"
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

# 校验转换产物是否有效：非空，且前 5 行不含错误页特征。
# 参数：$1 表示待校验文件路径。
# 返回：0=有效；1=无效。
is_valid_module() {
    local file_path="$1"

    [[ -s "$file_path" ]] || return 1
    # grep 无匹配返回 1 属预期，表示未发现错误页特征，即校验通过。
    if head -5 "$file_path" | grep -qi 'error\|404\|not found'; then
        return 1
    fi
    return 0
}

# 比较转换结果与本地已有模块，决定是否替换。
# 转换结果已下载到临时文件并校验通过；内容一致则删除临时文件、本地文件完全不动
# （连 mtime 都不刷新，避免下游误判更新），内容不同则原子替换。
# 参数：$1 表示转换结果临时文件；$2 表示本地目标 .sgmodule 路径。
# 返回：0=已替换（内容有变更）；1=已跳过（内容一致）；非 0 其他值=写入失败。
install_or_skip() {
    local tmp_file="$1"
    local output_file="$2"

    # 本地已有模块且内容逐字节一致 → 跳过，不触碰本地文件。
    if [[ -f "$output_file" ]] && cmp -s "$tmp_file" "$output_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    # 内容不同或本地无文件 → 原子替换（同目录 mv），避免半截文件被读取。
    if mv -f "$tmp_file" "$output_file"; then
        return 0
    fi
    rm -f "$tmp_file"
    return 2
}

# 从 JSON 订阅源提取插件 URL 并填入全局插件映射。
# 参数：$1 表示 JSON 源 URL；$2 表示可选子目录（省略则取域名，空字符串表示平铺）。
# 副作用：写入全局关联数组 PLUGIN_MAP，key=插件URL，value="子目录|名称"。
collect_plugins_from_json() {
    local json_url="$1"
    local subdir="${2-}"
    local json_content
    local plugin_urls
    local count=0
    local purl
    local name

    # 未显式传入子目录时沿用域名；显式空字符串表示平铺到输出根目录。
    if (( $# < 2 )); then
        subdir="$(get_domain "$json_url")"
    fi
    # 按配置顺序记录来源显示名（去重）；即使该源没有插件也参与通知明细。
    local seen_source=0
    local existing
    for existing in "${SOURCE_NAMES[@]:-}"; do
        if [[ "$existing" == "$subdir" ]]; then
            seen_source=1
            break
        fi
    done
    (( seen_source == 1 )) || SOURCE_NAMES+=("$subdir")
    log_info "解析 JSON 源：$json_url"
    if [[ -n "$subdir" ]]; then
        log_info "子目录：$subdir"
    else
        log_info "子目录：（平铺到输出根目录）"
    fi

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

    if [[ -n "$subdir" ]]; then
        log_success "提取到 ${count} 个插件 → ${subdir}/"
    else
        log_success "提取到 ${count} 个插件 → 输出根目录"
    fi
}

# 转换单个插件（在子 Shell 中执行，供并发调度）。
# 参数：$1 表示子目录；$2 表示插件名称；$3 表示插件源 URL。
# 输出：stdout 输出 "状态|子目录|名称" 三列，状态为 new/change/skip/fail，
#       供 convert_all 分类统计与按来源汇总；不在终端逐条打印，避免刷屏。
convert_one() {
    local subdir="$1"
    local name="$2"
    local source_url="$3"
    local convert_url
    local output_file
    local output_dir="${OUTPUT_DIR}/${subdir}"
    local tmp_result
    local had_local=0
    local rc
    local status

    mkdir -p "$output_dir"

    # Script-Hub 转换接口路径：/file/_start_/{源URL}/_end_/{名称}.sgmodule
    convert_url="${SCRIPT_HUB_URL}/file/_start_/${source_url}/_end_/${name}.sgmodule?type=${CONVERT_TYPE}&target=${CONVERT_TARGET}&del=true&jqEnabled=true"
    output_file="${output_dir}/${name}.sgmodule"
    # 注意：不能用 `[[ -f ]] && had_local=1`，本地无文件时该表达式返回 1，
    # 在后台子 shell 的 set -e 下会直接终止子 shell。
    if [[ -f "$output_file" ]]; then
        had_local=1
    fi

    # 转换结果先写入同目录临时文件，绝不先覆盖本地正式模块。
    tmp_result="$(mktemp "${output_dir}/.${name}.XXXXXX")" || { printf 'fail|%s|%s\n' "$subdir" "$name"; return 0; }

    if ! download_to_file "$convert_url" "$tmp_result" || ! is_valid_module "$tmp_result"; then
        rm -f "$tmp_result"
        # 转换失败时保留本地已有文件，不删除。
        printf 'fail|%s|%s\n' "$subdir" "$name"
        return 0
    fi

    # 与本地模块逐字节比对：一致则跳过（本地文件含 mtime 完全不动）；不同才原子替换。
    # 用 `|| rc=$?` 捕获返回值：install_or_skip 跳过时返回 1，若直接调用会在 set -e 下
    # 立即终止子 shell，导致既无 skip 标记、又触发 wait -n 连锁退出。
    rc=0
    install_or_skip "$tmp_result" "$output_file" || rc=$?
    if (( rc == 1 )); then
        status='skip'
    elif (( rc == 0 )); then
        if (( had_local == 1 )); then
            status='change'
        else
            status='new'
        fi
    else
        status='fail'
    fi

    printf '%s|%s|%s\n' "$status" "$subdir" "$name"
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
    local new_count=0
    local change_count=0
    local fail_count=0
    local skip_count=0
    local tmp_dir
    local results_file
    local -a source_order=()
    local -A source_new=()
    local -A source_change=()
    local -A source_fail=()
    local -A changed_files=()
    local line status subdir name seen

    # 创建临时目录并显式检查退出状态，避免创建失败时结果写入根目录。
    tmp_dir="$(mktemp -d)" || { log_error "创建临时目录失败"; return 1; }
    results_file="${tmp_dir}/results"

    # 异常退出时由统一的 EXIT trap 清理临时目录并发送通知。
    TASK_TMP_DIR="$tmp_dir"

    log_info "开始转换：共 ${total_count} 个插件（并发 ${CONCURRENCY}）"

    for source_url in "${!PLUGIN_MAP[@]}"; do
        info="${PLUGIN_MAP[$source_url]}"
        subdir="${info%%|*}"
        name="${info#*|}"

        # 并发控制：达到上限时等待任意一个子任务结束，并按固定步长报告进度。
        # wait -n 会返回所等待任务的退出码；子任务异常退出时不让其终止主流程。
        while (( running >= CONCURRENCY )); do
            wait -n || true
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
        wait -n || true
        running=$((running - 1))
        done_count=$((done_count + 1))
        if (( done_count >= last_report + PROGRESS_STEP )); then
            log_info "转换进度：${done_count} / ${total_count}"
            last_report=$done_count
        fi
    done

    # 建立来源顺序：优先按 JSON_SOURCES 配置顺序（SOURCE_NAMES），
    # 再补充仅出现在 PLUGIN_MAP 中的来源，兼顾直接调用 convert_all 的场景。
    local -a configured_sources=("${SOURCE_NAMES[@]:-}")
    for subdir in "${configured_sources[@]}"; do
        [[ -n "$subdir" ]] || continue
        source_order+=("$subdir")
    done
    for source_url in "${!PLUGIN_MAP[@]}"; do
        info="${PLUGIN_MAP[$source_url]}"
        subdir="${info%%|*}"
        seen=0
        for name in "${source_order[@]:-}"; do
            if [[ "$name" == "$subdir" ]]; then
                seen=1
                break
            fi
        done
        (( seen == 1 )) || source_order+=("$subdir")
    done

    # 逐行解析结果："状态|子目录|名称"，累计总数、按来源分组数及变更文件清单。
    while IFS='|' read -r status subdir name; do
        [[ -n "$status" ]] || continue
        case "$status" in
            new)
                new_count=$((new_count + 1))
                source_new["$subdir"]=$(( ${source_new["$subdir"]:-0} + 1 ))
                changed_files["$name"]=1
                ;;
            change)
                change_count=$((change_count + 1))
                source_change["$subdir"]=$(( ${source_change["$subdir"]:-0} + 1 ))
                changed_files["$name"]=1
                ;;
            fail)
                fail_count=$((fail_count + 1))
                source_fail["$subdir"]=$(( ${source_fail["$subdir"]:-0} + 1 ))
                ;;
            skip)
                skip_count=$((skip_count + 1))
                ;;
        esac
    done < "$results_file"

    rm -rf "$tmp_dir"
    TASK_TMP_DIR=''

    # 合计摘要。
    TASK_SUMMARY="新增 ${new_count} / 更新 ${change_count} / 失败 ${fail_count} / 跳过 ${skip_count}（共 ${total_count}）"
    if (( fail_count > 0 )); then
        TASK_ERROR_MSG="共 ${fail_count} 个插件转换失败，详见运行日志"
    fi

    # 按来源分组的变更详细。
    TASK_DETAIL=''
    for subdir in "${source_order[@]:-}"; do
        TASK_DETAIL+=$'\n• '"${subdir}：新增 ${source_new["$subdir"]:-0} / 更新 ${source_change["$subdir"]:-0} / 失败 ${source_fail["$subdir"]:-0}"
    done

    # 变更文件清单（新增或变更过的 .sgmodule），仅在非空时组装。
    # 前置空行与"变更详细"分段；无变更时整段不出现，不留多余空行。
    TASK_CHANGED=''
    if (( ${#changed_files[@]} > 0 )); then
        TASK_CHANGED=$'\n\n📂 变更文件'
        for name in "${!changed_files[@]}"; do
            TASK_CHANGED+=$'\n🔄 '"${name}.sgmodule"
        done
    fi

    log_success "转换完成：${TASK_SUMMARY}"
    log_info "输出目录：${OUTPUT_DIR}/"
}

# 主入口：加载配置、解析插件列表并批量转换。
main() {
    local script_dir
    local env_file
    local total
    local json_url

    # 任务计时起点，供结束通知的“耗时”字段使用（与 Backup.sh 一致）。
    SECONDS=0

    # 基于 BASH_SOURCE 定位脚本目录，显式检查失败（否则无法加载同目录 .env）。
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || { log_error "无法定位脚本目录"; return 1; }
    env_file="${script_dir}/.env"

    setup_colors

    # 统一启动标题：业务前的第一组终端输出。
    print_script_header
    printf '\n'

    if ! load_config "$env_file"; then
        return 1
    fi

    # 配置校验：内置配置与 .env 均为空时，给出一次性明确提示并退出。
    if [[ -z "$SCRIPT_HUB_URL" && -z "$CONVERT_TYPE" && -z "$CONVERT_TARGET" && -z "$OUTPUT_DIR" && -z "$CONCURRENCY" && -z "$CHECK_UPDATED" && -z "${JSON_SOURCES[0]:-}" ]]; then
        log_error "未检测到任何有效配置：请在脚本内置默认配置中填写，或在同一目录创建 .env。"
        return 1
    fi
    # 必填项 SCRIPT_HUB_URL 单独校验，避免 set -u 下参数展开输出生硬错误。
    if [[ -z "$SCRIPT_HUB_URL" ]]; then
        log_error "SCRIPT_HUB_URL 未配置：请在脚本内置默认配置中填写，或在 .env 中设置。"
        return 1
    fi
    # Telegram 通知配置：.env 未设置的项回退到内置默认值（凭据为空即不启用通知）。
    TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-$DEFAULT_TELEGRAM_TOKEN}"
    CHAT_ID="${CHAT_ID:-$DEFAULT_CHAT_ID}"
    TG_API="${TG_API:-$DEFAULT_TG_API}"
    CONVERT_TYPE="${CONVERT_TYPE:-$DEFAULT_CONVERT_TYPE}"
    CONVERT_TARGET="${CONVERT_TARGET:-$DEFAULT_CONVERT_TARGET}"
    OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
    CONCURRENCY="${CONCURRENCY:-$DEFAULT_CONCURRENCY}"
    # 外部输入校验（AGENTS.md 6.19）：CONCURRENCY 须为无前导零的 1-50 整数，
    # 避免用户输入被当作算术表达式执行、前导零触发八进制错误或压垮 Script-Hub。
    if [[ ! "$CONCURRENCY" =~ ^[1-9][0-9]*$ ]] || (( CONCURRENCY > 50 )); then
        log_error "CONCURRENCY 必须为 1-50 的整数（当前值：${CONCURRENCY}）"
        return 1
    fi
    CHECK_UPDATED="${CHECK_UPDATED:-$DEFAULT_CHECK_UPDATED}"
    if [[ "$CHECK_UPDATED" != 'true' && "$CHECK_UPDATED" != 'false' ]]; then
        log_error "CHECK_UPDATED 只能为 true 或 false（当前值：${CHECK_UPDATED}）"
        return 1
    fi
    # 增量检测始终启用：旧配置中的 false 不再关闭检测，给出提示并规范化为 true。
    if [[ "$CHECK_UPDATED" == 'false' ]]; then
        log_warn "CHECK_UPDATED=false 已不再支持：更新检测始终启用，仅上游有更新时才替换本地文件。"
        CHECK_UPDATED='true'
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

    local entry custom_subdir
    for entry in "${JSON_SOURCES[@]}"; do
        # 去除首尾空白，使用参数展开避免 xargs 对含引号 URL 解析失败。
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [[ -z "$entry" || "$entry" == \#* ]] && continue

        # 可选写法 "子目录|URL"：显式指定输出子目录；"|URL" 表示平铺。
        # 未含 | 时保持原有行为（子目录取域名）。
        custom_subdir=''
        json_url="$entry"
        if [[ "$entry" == *"|"* ]]; then
            custom_subdir="${entry%%|*}"
            json_url="${entry#*|}"
        fi
        # 自定义名称仅限安全字符，防止路径穿越或误建多级目录。
        custom_subdir="${custom_subdir//[\/\\]/_}"
        json_url="${json_url#"${json_url%%[![:space:]]*}"}"
        json_url="${json_url%"${json_url##*[![:space:]]}"}"
        [[ -z "$json_url" ]] && { log_warn "JSON 源地址为空，已跳过：$entry"; continue; }

        if [[ "$entry" == *"|"* ]]; then
            collect_plugins_from_json "$json_url" "$custom_subdir"
        else
            collect_plugins_from_json "$json_url"
        fi
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
        TASK_SUMMARY="共 0 个插件，无需转换"
        return 0
    fi

    convert_all
}

# 安装统一退出处理：覆盖正常结束与各类失败路径；通知失败不改变原有退出码。
trap 'on_script_exit' EXIT

main "$@"
