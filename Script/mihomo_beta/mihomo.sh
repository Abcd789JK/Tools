#!/usr/bin/env bash

# ----------------------------------------
# name   : mihomo.sh
# desc   : 管理 & 面板
# date   : 2026-10-26 18:49:15
# author : ChatGPT
# ver    : 1.7.5
# ----------------------------------------

# 与 install.sh 共用 65 个同名函数，改动需同步两份

# 必须用 bash 运行：dash/sh 不支持 pipefail、[[ ]] 与进程替换，
# 提前拦截以给出明确提示，而不是抛出晦涩的 set 报错。
if [ -z "${BASH_VERSION:-}" ]; then
    printf '%s\n' "错误：请使用 bash 运行本脚本" >&2
    exit 1
fi

set -euo pipefail
umask 077

# ---------- 颜色 ----------
# 颜色在初始化阶段一次性确定，避免对只读变量重复赋值。
# 仅在对应输出流连接到终端且 NO_COLOR 为空时启用；颜色只辅助表达状态，
# 不替代文字标签，机器可读输出与日志文件不会混入转义符。
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly COLOR_RESET=$'\033[0m'
    readonly COLOR_BLACK=$'\033[0;30m'
    readonly COLOR_RED=$'\033[0;31m'
    readonly COLOR_GREEN=$'\033[0;32m'
    readonly COLOR_YELLOW=$'\033[0;33m'
    readonly COLOR_BLUE=$'\033[0;34m'
    readonly COLOR_MAGENTA=$'\033[0;35m'
    readonly COLOR_CYAN=$'\033[0;36m'
    readonly COLOR_WHITE=$'\033[0;37m'
    readonly COLOR_BOLD=$'\033[1m'
else
    readonly COLOR_RESET=''
    readonly COLOR_BLACK=''
    readonly COLOR_RED=''
    readonly COLOR_GREEN=''
    readonly COLOR_YELLOW=''
    readonly COLOR_BLUE=''
    readonly COLOR_MAGENTA=''
    readonly COLOR_CYAN=''
    readonly COLOR_WHITE=''
    readonly COLOR_BOLD=''
fi

# 语义颜色：只表达状态，不改变具体色值
readonly COLOR_ERROR="$COLOR_RED"
readonly COLOR_SUCCESS="$COLOR_GREEN"
readonly COLOR_WARNING="$COLOR_YELLOW"
readonly COLOR_INFO="$COLOR_CYAN"

# 标准错误单独判断：stderr 重定向到日志时不着色
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    readonly STDERR_COLOR_ERROR=$'\033[0;31m'
    readonly STDERR_COLOR_WARNING=$'\033[0;33m'
    readonly STDERR_COLOR_RESET=$'\033[0m'
else
    readonly STDERR_COLOR_ERROR=''
    readonly STDERR_COLOR_WARNING=''
    readonly STDERR_COLOR_RESET=''
fi

# ---------- 输出格式 ----------
# 与 install.sh 保持同一套交互规范：统一 40 字符分隔线。
# 颜色规范（两个脚本保持一致，新增输出必须遵守）：
#   边框与分隔线（HR / HR_EQ）  blue
#   标题、步骤序号、标签         cyan
#   成功状态、菜单与选项序号     green
#   一般信息、交互提示语         cyan
#   警告                        yellow
#   错误                        red
#   普通说明文字                默认色（不着色）
readonly HR="----------------------------------------"
readonly HR_EQ="========================================"

# 打印分隔线：hr 单线 / hreq 双线
hr()   { printf '%s\n' "${COLOR_BLUE}${HR}${COLOR_RESET}"; }
# 打印等号分隔线
hreq() { printf '%s\n' "${COLOR_BLUE}${HR_EQ}${COLOR_RESET}"; }

# 打印"标签: 值"行：标签统一青色，值按语义着色（成功绿/警告黄/错误红/默认色）
kv() { printf '  %s%s%s  %s\n' "$COLOR_CYAN" "$1" "$COLOR_RESET" "$2"; }

# ---------- 常量 ----------
SCRIPT_VERSION="1.7.5"

readonly ROOT_DIR="/root/mihomo"
readonly CONFIG_FILE="${ROOT_DIR}/config.yaml"
readonly BIN_FILE="${ROOT_DIR}/mihomo"
readonly VERSION_FILE="${ROOT_DIR}/version.txt"
readonly SHELL_FILE="/usr/bin/mihomo"
readonly SERVICE_SYSTEMD="/etc/systemd/system/mihomo.service"
readonly SERVICE_OPENRC="/etc/init.d/mihomo"
readonly SYSCTL_FILE="/etc/sysctl.d/99-ip-forward.conf"
readonly LOG_FILE="/var/log/mihomo.log"
readonly INSTALL_LOG="/var/log/mihomo-install.log"
# 早期版本曾用定时任务清理日志，此处仅为卸载时清理残留而保留
readonly LOGCLEAN_SERVICE="/etc/systemd/system/mihomo-logclean.service"
readonly LOGCLEAN_TIMER="/etc/systemd/system/mihomo-logclean.timer"
readonly LOGCLEAN_PERIODIC="/etc/periodic/daily/mihomo-logclean"

readonly REPO_RAW="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main"
readonly MIHOMO_RELEASE="https://github.com/MetaCubeX/mihomo/releases/download"
readonly MIHOMO_VERSION_URL="${MIHOMO_RELEASE}/Prerelease-Alpha/version.txt"
readonly MIHOMO_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
readonly MIHOMO_API_TAGS="https://api.github.com/repos/MetaCubeX/mihomo/releases/tags"
readonly CONFIG_URL="${REPO_RAW}/Config/mihomo.yaml"
readonly SHELL_URL="${REPO_RAW}/Script/mihomo_beta/mihomo.sh"
readonly INSTALL_URL="${REPO_RAW}/Script/mihomo_beta/install.sh"
readonly WEBUI_URL="https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip"

readonly MIRRORS=("https://gh-proxy.com" "https://github.boki.moe")
# 探测顺序以 GitHub 自身可达性为准，Google 仅作通用连通性兜底
readonly PROBE_TARGETS=(
    "https://github.com/robots.txt"
    "https://www.gstatic.com/generate_204"
    "https://www.cloudflare.com/cdn-cgi/trace"
)

# ---------- 全局状态 ----------
distro="unknown"
pkg_mgr=""
init_sys=""
arch=""
arch_raw=""
version=""
channel=""             # stable=正式版(v1.19.32) / alpha=测试版(alpha-<哈希>)
ipv4=""
ipv6=""
use_cdn=false
url_prefix=""
controller_secret=""   # 面板密钥，重置配置时重新生成
SECRET_ENABLED=1       # 是否启用面板密钥：1=启用 0=禁用（由 ask_secret 决定）
provider_total=0       # select_provider 统计到的订阅总数
provider_num=""        # select_provider 选中的订阅编号
provider_target=""     # select_provider 选中的 provider 键名（如 provider_02:）
tmp_files=()

# ---------- 日志 ----------
# 日志：2>/dev/null 必须写在 >> 之前，否则重定向失败的错误会漏到终端
# 日志只由本套脚本写入、不会自行增长，因此不依赖定时任务：
# 每次落盘前检查大小，超过 1 MB 就地只保留最近 1000 行。
log_trim() { # $1=日志文件；返回 0=已截断 1=未超限或文件不存在 2=失败
    local f="$1" size limit=$((1024 * 1024)) keep=1000 tmp
    [[ -f "$f" ]] || return 1
    size=$(wc -c <"$f" 2>/dev/null) || return 2
    (( size > limit )) || return 1

    tmp="${f}.tmp"
    if ! tail -n "$keep" "$f" >"$tmp" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null || true
        return 2
    fi
    if ! mv -f -- "$tmp" "$f" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null || true
        return 2
    fi
    chmod 640 "$f" 2>/dev/null || true
    return 0
}

# ---------- 日志 ----------
# 统一日志输出：info/ok/warn/err 同时落盘，die 只报错不落盘。
# 落盘前先限重，避免长期运行后日志无限增长
log() {
    log_trim "$LOG_FILE" || true
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" 2>/dev/null \
        >>"$LOG_FILE" 2>/dev/null || true
}
# 输出普通信息日志
info() { printf '%s\n' "${COLOR_INFO}$*${COLOR_RESET}"; log "INFO  $*"; }
# 输出成功日志
ok()   { printf '%s\n' "${COLOR_SUCCESS}$*${COLOR_RESET}"; log "OK    $*"; }
# 输出警告日志（标准错误）
warn() { printf '%s\n' "${STDERR_COLOR_WARNING}$*${STDERR_COLOR_RESET}" >&2; log "WARN  $*"; }
# 输出错误日志（标准错误）
err()  { printf '%s\n' "${STDERR_COLOR_ERROR}$*${STDERR_COLOR_RESET}" >&2; log "ERROR $*"; }
# 输出错误并退出脚本
die()  { err "$*"; exit 1; }

# ---------- 清理 ----------
# 清理脚本运行期间登记的临时文件
cleanup() {
    local f
    for f in "${tmp_files[@]:-}"; do
        [[ -n "$f" && -e "$f" ]] && rm -rf -- "$f"
    done
    return 0   # 显式返回 0，避免 EXIT trap 污染脚本退出码
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------- 通用 ----------
# 检查指定命令是否可用
command_exists() { command -v "$1" >/dev/null 2>&1; }

# 是否处于交互终端：curl | bash 等管道场景下为假，
# 各交互点据此取默认值，避免 read 遇 EOF 直接退出
is_interactive() { [[ -t 0 ]]; }

# 原子替换文件：先写同目录临时文件再 mv，避免截断正在运行的脚本
atomic_install() { # $1=源 $2=目标 $3=权限
    local src="$1" dest="$2" mode="${3:-644}" stage
    stage="$(dirname "$dest")/.$(basename "$dest").new.$$"
    if ! cp -f -- "$src" "$stage" 2>/dev/null; then
        rm -f -- "$stage"
        return 1
    fi
    if ! chmod "$mode" "$stage" 2>/dev/null; then
        rm -f -- "$stage"
        return 1
    fi
    if ! mv -f -- "$stage" "$dest" 2>/dev/null; then
        rm -f -- "$stage"
        return 1
    fi
    return 0
}

# 安全读取：EOF(Ctrl+D) 时优雅退出，避免被 set -e 静默中断
read_input() { # $1=变量名 $2=提示语
    local __var="$1" __prompt="$2" __val=""
    if ! IFS= read -rp "$__prompt" __val; then
        printf '\n'
        err "输入已中断，退出"
        exit 130
    fi
    printf -v "$__var" '%s' "$__val"
}

# YAML 双引号值转义
sanitize_yaml() {
    local v="$1"
    v=${v//$'\r'/}
    v=${v//$'\n'/ }
    v=${v//$'\t'/ }
    v=${v//\\/\\\\}
    v=${v//\"/\\\"}
    printf '%s' "$v"
}

# 交互确认：回车或 y/Y 为是，其余为否
confirm() { # $1=提示语 $2=默认值
    local prompt="$1" def="${2:-n}" ans=""
    read_input ans "${COLOR_CYAN}${prompt}${COLOR_RESET} "
    ans=${ans:-$def}
    [[ "$ans" =~ ^[Yy] ]]
}

# 校验 root 权限，非 root 直接退出
require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "请以 root 身份运行本脚本"
    fi
}

# ---------- 系统检测 ----------
# 发行版识别：先按 ID 匹配，再按 ID_LIKE 回退，覆盖各发行版衍生版本。
# 未识别的发行版不再直接退出，而是降级为"不自动装依赖"，工具齐全时仍可安装。
detect_distro() {
    [[ -r /etc/os-release ]] || die "无法识别系统类型：缺少 /etc/os-release"
    # shellcheck disable=SC1091
    . /etc/os-release

    distro="${ID:-unknown}"
    pkg_mgr=""
    local cand
    # ID_LIKE 可能含多个值（如 "rhel centos fedora"），逐个尝试
    for cand in ${ID:-} ${ID_LIKE:-}; do
        case "$cand" in
            debian|ubuntu)
                pkg_mgr="apt" ;;
            fedora)
                pkg_mgr="dnf" ;;
            arch)
                pkg_mgr="pacman" ;;
            alpine)
                pkg_mgr="apk" ;;
            opensuse*|suse|sles)
                pkg_mgr="zypper" ;;
            *)
                continue ;;
        esac
        break
    done

    if [[ -z "$pkg_mgr" ]]; then
        pkg_mgr="none"
        warn "未识别的发行版：${distro}，将跳过依赖自动安装"
        warn "请自行确认已安装：curl 或 wget、unzip、gzip、jq、iproute2"
    fi

    detect_init
}

# init 系统识别：systemd 优先，其次 OpenRC；都识别不到时降级处理
detect_init() {
    if [[ -d /run/systemd/system ]] \
        || { command_exists systemctl && [[ -d /etc/systemd/system ]]; }; then
        init_sys="systemd"
    elif command_exists rc-service && command_exists rc-update; then
        init_sys="openrc"
    else
        init_sys="unknown"
        warn "无法识别 init 系统，服务将不会自动配置"
    fi
}

# ---------- 服务后端 ----------
# 按 init 系统执行 start / stop / restart
service_do() { # $1=start|stop|restart
    case "$init_sys" in
        systemd)
            if [[ "$1" == "restart" ]]; then
                systemctl daemon-reload >/dev/null 2>&1 || true
            fi
            systemctl "$1" mihomo
            ;;
        openrc)
            rc-service mihomo "$1"
            ;;
        *)
            err "当前 init 系统不受支持"
            return 1
            ;;
    esac
}

# 按 init 系统设置或取消开机自启
service_enable_toggle() { # $1=enable|disable
    case "$init_sys" in
        systemd)
            systemctl "$1" mihomo >/dev/null 2>&1
            ;;
        openrc)
            if [[ "$1" == "enable" ]]; then
                rc-update add mihomo default >/dev/null 2>&1
            else
                rc-update del mihomo >/dev/null 2>&1
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

# 判断服务是否处于运行状态
service_is_active() {
    local pid=""
    case "$init_sys" in
        systemd)
            systemctl is-active --quiet mihomo
            ;;
        openrc)
            [[ -f /run/mihomo.pid ]] && pid=$(cat /run/mihomo.pid 2>/dev/null || true)
            [[ -n "$pid" && -d "/proc/${pid}" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

# 等待服务进入运行状态：systemd 处于 activating 时 is-active 返回非 0，
# 启动稍慢就被单次判定为失败会导致配置被无谓回滚，故改为轮询。
wait_active() { # $1=最多等待秒数，默认 10
    local i limit="${1:-10}"
    for ((i = 0; i < limit; i++)); do
        if service_is_active; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# 判断是否已设置开机自启
service_is_enabled() {
    local out=""
    case "$init_sys" in
        systemd)
            systemctl is-enabled --quiet mihomo 2>/dev/null
            ;;
        openrc)
            out=$(rc-status default 2>/dev/null || true)
            [[ "$out" == *mihomo* ]]
            ;;
        *)
            return 1
            ;;
    esac
}

# ---------- HTTP 入口 ----------
# 有 curl 用 curl，没有则退回 wget：两种工具的参数差异在本层屏蔽，
# 上层只描述"要什么"，不关心"用什么"。
# curl / wget 都不自动安装——用户能把脚本取回来，说明至少有一个；
# 两个都缺失时本层不会主动安装，只会在下载环节失败（管理脚本不承担装依赖的职责，
# 依赖由 install.sh 负责）。
# 有 curl 时走 curl 分支，保留原有的重试与超时策略。

# 取回内容写到标准输出：$1=URL $2=连接超时 $3=总超时
http_get() {
    if command_exists curl; then
        curl -fsSL --connect-timeout "$2" --max-time "$3" "$1" 2>/dev/null
    else
        wget -qO- --timeout="$3" -t 1 "$1" 2>/dev/null
    fi
}

# 下载到文件：$1=URL $2=输出文件 $3=总超时
http_download() {
    if command_exists curl; then
        curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time "$3" \
            -sS -o "$2" "$1"
    else
        wget -q --tries=3 --timeout="$3" -O "$2" "$1"
    fi
}

# 探测可达性：完整请求但丢弃响应体。
# 不用 HEAD，是因为部分服务器不支持 HEAD 会直接返回错误，反而误判为不可达。
http_probe() { # $1=URL $2=总超时
    if command_exists curl; then
        curl -fsS -o /dev/null --connect-timeout 3 --max-time "$2" "$1" 2>/dev/null
    else
        wget -q -O /dev/null --timeout="$2" -t 1 "$1" 2>/dev/null
    fi
}

# HEAD 探测：只取状态码、不取响应体，用于大资产的存在性判断
http_head() { # $1=URL $2=总超时
    if command_exists curl; then
        local code
        code=$(curl -sSL -I -o /dev/null -w '%{http_code}' \
                   --connect-timeout 5 --max-time "$2" "$1" 2>/dev/null || true)
        [[ "$code" == "200" || "$code" == "206" ]]
    else
        wget -q --spider --timeout="$2" -t 1 "$1" 2>/dev/null
    fi
}

# 取前 N 字节并报告实际大小：用于测速，以及大资产存在性的兜底判断
http_range_size() { # $1=URL $2=字节数 $3=总超时
    local tmp n last
    last=$(( $2 - 1 ))
    tmp=$(mktemp 2>/dev/null) || { printf '0'; return 0; }
    if command_exists curl; then
        curl -fsSL --connect-timeout 4 --max-time "$3" --range "0-${last}" \
            -o "$tmp" "$1" 2>/dev/null || true
    else
        wget -q --timeout="$3" -t 1 --header="Range: bytes=0-${last}" \
            -O "$tmp" "$1" 2>/dev/null || true
    fi
    n=$(wc -c <"$tmp" 2>/dev/null) || n=0
    rm -f -- "$tmp"
    printf '%s' "${n// /}"
}

# 读取重定向目标地址：正式版版本号的兜底获取方式
# wget 的响应头行首有两个空格，且重定时会附 " [following]" 后缀，都要剥掉
http_redirect() { # $1=URL $2=总超时
    if command_exists curl; then
        curl -sSI -o /dev/null -w '%{redirect_url}' \
            --connect-timeout 8 --max-time "$2" "$1" 2>/dev/null || true
    else
        local loc
        loc=$(wget --max-redirect=0 --server-response --spider "$1" 2>&1 \
                | sed -n 's/^[[:space:]]*[Ll]ocation: *//p' | tr -d '\r' || true)
        printf '%s' "${loc%%[[:space:]]*}"
    fi
}

# ---------- 网络探测 ----------
# 探测地址是否可达（小文件用）
probe_url() {
    http_probe "$1" 8
}

# 探测直连是否可用，据此决定优先走直连还是镜像
check_network() {
    local t
    for t in "${PROBE_TARGETS[@]}"; do
        if probe_url "$t"; then
            use_cdn=false
            ok "网络环境正常，优先直连"
            return 0
        fi
    done
    use_cdn=true
    warn "直连探测失败，优先尝试镜像加速"
}

# 地址解析：直连优先 → 镜像兜底，并缓存可用前缀
# $2=探测函数，默认 probe_url。probe_url 是全量 GET 且只等 8 秒，
# 仅适用于小文件；大资产（内核二进制、面板压缩包）必须传 probe_asset，
# 用 HEAD + Range 探测，否则慢速网络下会把可达地址误判为不可达。
resolve_url() { # $1=url $2=探测函数
    local url="$1" probe="${2:-probe_url}" cand m
    if [[ -n "$url_prefix" ]]; then
        cand="${url_prefix}/${url}"
        if "$probe" "$cand"; then
            printf '%s' "$cand"
            return 0
        fi
        url_prefix=""
    fi
    if [[ "$use_cdn" == true ]]; then
        for m in "${MIRRORS[@]}"; do
            cand="${m}/${url}"
            if "$probe" "$cand"; then
                url_prefix="$m"
                printf '%s' "$cand"
                return 0
            fi
        done
    fi
    if "$probe" "$url"; then
        printf '%s' "$url"
        return 0
    fi
    for m in "${MIRRORS[@]}"; do
        cand="${m}/${url}"
        if "$probe" "$cand"; then
            url_prefix="$m"
            printf '%s' "$cand"
            return 0
        fi
    done
    return 1
}

# 实测下载速度（KB/s），返回 0 表示不可用
# curl 分支用 --range 限取 1MB 并直接读取传输耗时；wget 不汇报耗时，
# 改用 1 秒限时代理：取到的字节数即约等于 KB/s。
measure_speed() { # $1=url
    local url="$1" res got
    if command_exists curl; then
        res=$(curl -fsSL --connect-timeout 4 --max-time 4 --range 0-1048575 \
                  -o /dev/null -w '%{size_download} %{time_total}' "$url" 2>/dev/null || true)
        [[ -n "$res" ]] || { printf '0'; return 0; }
        awk -v s="${res%% *}" -v t="${res##* }" \
            'BEGIN { if (t + 0 <= 0) { print 0; exit } printf "%d", (s + 0) / 1024 / t }'
        return 0
    fi
    got=$(http_range_size "$url" 1048576 1)
    [[ "$got" =~ ^[0-9]+$ ]] || got=0
    printf '%d' "$(( got / 1024 ))"
}

# 按实测速度选源：直连够快就走直连，否则与镜像比速度取最快
# 解决"GitHub 直连可用但很慢"的场景 —— 仅判断可达性会误选慢速直连
pick_fastest_source() { # $1=样本 URL（建议传真实待下载文件）
    local sample="$1" d s m best="" best_speed=0

    info "正在测速以选择下载源..."
    d=$(measure_speed "$sample")

    if (( d >= 512 )); then
        use_cdn=false
        url_prefix=""
        ok "直连速度 ${d} KB/s，使用直连"
        return 0
    fi

    best_speed="$d"
    for m in "${MIRRORS[@]}"; do
        s=$(measure_speed "${m}/${sample}")
        if (( s > best_speed )); then
            best_speed="$s"
            best="$m"
        fi
    done

    if (( best_speed == 0 )); then
        err "直连与镜像均不可用，请检查网络"
        return 1
    fi

    if [[ -n "$best" ]]; then
        url_prefix="$best"
        use_cdn=true
        warn "直连 ${d} KB/s，${best} ${best_speed} KB/s，已切换镜像"
    else
        url_prefix=""
        use_cdn=false
        warn "直连 ${d} KB/s（较慢），镜像未测得更快，仍使用直连"
    fi
}

# 单次下载尝试，成功且非空才算通过
fetch_to() { # $1=url $2=输出文件
    local url="$1" out="$2"
    http_download "$url" "$out" 900 || return 1
    [[ -s "$out" ]]
}

# 统一下载：.part 临时文件 + 成功才 mv，直连失败自动换镜像重试
# $4=探测函数，大资产（二进制、面板包）必须传 probe_asset，避免全量 GET 探测拖慢或误判
download_file() { # $1=url $2=目标路径 $3=描述 $4=探测函数
    local url="$1" dest="$2" desc="${3:-文件}" probe="${4:-probe_url}" resolved m

    # 登记 .part，中断时由 cleanup 一并清理，避免残留半截文件
    tmp_files+=("${dest}.part")

    if ! resolved=$(resolve_url "$url" "$probe"); then
        err "${desc}地址解析失败：${url}"
        return 1
    fi
    log "DOWNLOAD ${desc} <- ${resolved}"

    if fetch_to "$resolved" "${dest}.part"; then
        mv -f -- "${dest}.part" "$dest"
        return 0
    fi

    # 测速选中直连但实际拉不动时，改用镜像兜底
    for m in "${MIRRORS[@]}"; do
        [[ "$resolved" == "${m}/"* ]] && continue
        warn "${desc}直连失败，改用镜像 ${m} 重试"
        if fetch_to "${m}/${url}" "${dest}.part"; then
            url_prefix="$m"
            use_cdn=true
            mv -f -- "${dest}.part" "$dest"
            ok "${desc}已通过镜像下载完成"
            return 0
        fi
    done

    rm -f -- "${dest}.part"
    err "${desc}下载失败"
    return 1
}

# 探测资产是否存在：先 HEAD 取状态码，不把 20MB+ 的响应体拉下来。
# 不用 --range 打头，是因为部分镜像/CDN 忽略 Range 而直接返回整包，
# 20MB+ 的响应会在 --max-time 内超时，反而把存在的资产误判为不存在。
probe_asset() {
    local url="$1"
    http_head "$url" 12 && return 0
    # 部分镜像不支持 HEAD，退回范围请求兜底
    [[ "$(http_range_size "$url" 1 15)" != "0" ]]
}

# ---------- 架构 ----------
# uname -m → mihomo 资产架构标识（可能有多个候选，按优先级逐行输出）。
# 仅保留主流架构：x86_64 / i686 / aarch64 / armv7l / s390x。
# amd64 使用 compatible 变体，兼容不支持 v2/v3 指令集的老 CPU；
# arm64 官方无 compatible 变体；armv8l 是 32 位用户空间的 ARMv8，仍取 armv7 资产。
arch_candidates() {
    case "$1" in
        x86_64|amd64)          printf 'amd64\n' ;;
        i386|i486|i586|i686)   printf '386\n' ;;
        aarch64|arm64)         printf 'arm64\n' ;;
        armv8l|armv7l|armv7)   printf 'armv7\n' ;;
        s390x)                 printf 's390x\n' ;;
        *) return 1 ;;
    esac
}

# 识别系统架构，不支持的架构给出明确提示
detect_arch() {
    local toks
    arch_raw=$(uname -m)
    toks=$(arch_candidates "$arch_raw" || true)
    arch=${toks%%$'\n'*}
    if [[ -z "$arch" ]]; then
        err "不支持的架构：${arch_raw}"
        err "支持：x86_64 i686 aarch64 armv7l s390x"
        return 1
    fi
}

# ---------- 版本获取 ----------
# 版本号既可能是 1.19.2 这类语义化版本，也可能是 alpha-94b13ae 这类构建标识，
# 因此只校验"可作为文件名且不含路径/引号/尖括号"，避免误杀合法版本
valid_version() {
    local v="$1"
    [[ -n "$v" && ${#v} -le 64 ]] || return 1
    grep -Eq '^[0-9A-Za-z][0-9A-Za-z._-]*$' <<<"$v"
}

# 版本通道判定：alpha-<哈希> 为测试版，纯数字为正式版
detect_channel() { # $1=版本号
    case "$1" in
        *alpha*) printf 'alpha' ;;
        *)       printf 'stable' ;;
    esac
}

# 版本通道 → 中文名
channel_name() { # $1=通道 → 中文名
    [[ "$1" == "alpha" ]] && printf '测试版' || printf '正式版'
}

# 获取测试版版本号
fetch_alpha_version() { # --fail + 格式校验
    local v resolved
    if ! resolved=$(resolve_url "$MIHOMO_VERSION_URL"); then
        return 1
    fi
    v=$(http_get "$resolved" 10 30) || return 1
    v=$(printf '%s' "$v" | tr -d '[:space:]')
    if ! valid_version "$v"; then
        err "获取到的版本号格式异常：${v:-<空>}"
        return 1
    fi
    printf '%s' "$v"
}

# 正式版版本号：优先 api.github.com 的 tag_name（v1.19.32 → 1.19.32）；
# 该域名在部分网络下不可达且未认证请求有 60 次/时限流，故增加
# releases/latest 的 302 Location 兜底（走 github.com 本体，镜像可代理）。
# 获取正式版版本号
fetch_latest_version() { # 校验 null 与空值
    local v raw resolved tag m
    if resolved=$(resolve_url "$MIHOMO_API" 2>/dev/null); then
        raw=$(http_get "$resolved" 10 30 2>/dev/null || true)
        v=$(printf '%s' "$raw" | jq -r '.tag_name // empty' 2>/dev/null || true)
        v=${v#v}
        if [[ -n "$v" && "$v" != "null" ]] && valid_version "$v"; then
            printf '%s' "$v"
            return 0
        fi
    fi

    info "API 不可用，改用 releases/latest 重定向获取版本号..."
    tag=$(http_redirect "https://github.com/MetaCubeX/mihomo/releases/latest" 20)
    if [[ -z "$tag" ]]; then
        for m in "${MIRRORS[@]}"; do
            tag=$(http_redirect "${m}/https://github.com/MetaCubeX/mihomo/releases/latest" 20)
            [[ -n "$tag" ]] && break
        done
    fi
    tag=${tag##*/}
    tag=${tag#v}
    if [[ -z "$tag" ]] || ! valid_version "$tag"; then
        err "获取正式版版本号失败（API 与重定向均不可用，可能触发 GitHub 限流）"
        return 1
    fi
    printf '%s' "$tag"
}

# 二进制自检：ELF 魔数 + 可执行
verify_binary() {
    local bin="$1" magic
    [[ -f "$bin" ]] || { err "文件不存在：${bin}"; return 1; }
    magic=$(head -c 4 "$bin" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    if [[ "$magic" != "7f454c46" ]]; then
        err "下载内容不是有效的 ELF 可执行文件（可能是错误页）"
        return 1
    fi
    if ! "$bin" -v >/dev/null 2>&1; then
        err "二进制无法在当前架构上运行"
        return 1
    fi
}

# 从 GitHub Release API 取正式版资产的官方 SHA256（asset.digest，形如 "sha256:..."）。
# 上游正式版并未发布 checksums.txt，这是当前唯一权威的校验值来源，且与二进制同源。
# 仅用于正式版；测试版仍走 Prerelease-Alpha/checksums.txt。
# 输出小写十六进制摘要；jq 缺失、API 不可达、字段为空时输出空串。
fetch_asset_digest() { # $1=资产名（如 mihomo-linux-amd64-compatible-v1.19.33.gz）
    local name="$1" resolved raw d
    command_exists jq || return 0

    resolved=$(resolve_url "${MIHOMO_API_TAGS}/v${version}" 2>/dev/null) || return 0
    raw=$(http_get "$resolved" 10 30 2>/dev/null || true)
    [[ -n "$raw" ]] || return 0

    d=$(printf '%s' "$raw" | jq -r --arg n "$name" \
        '.assets[]? | select(.name == $n) | .digest // empty' 2>/dev/null | head -n1 || true)
    d="${d#sha256:}"
    [[ "$d" =~ ^[0-9a-fA-F]{64}$ ]] || return 0
    printf '%s' "${d,,}"
}

# 完整性校验：两个版本通道各有各的权威来源，互不影响。
#   正式版 → GitHub API 的 asset.digest（上游未发布 checksums.txt）
#   测试版 → Prerelease-Alpha/checksums.txt（沿用原方案）
# 两者都不可用时降级为告警而不阻断安装，避免镜像/限流导致装不上。
verify_checksum() { # $1=本地文件 $2=资产文件名（如 mihomo-linux-amd64-compatible-v1.19.32.gz）
    local file="$1" name="$2" sums_url="" sums="" expect="" actual="" tool=""

    if command_exists sha256sum; then
        tool="sha256sum"
    elif command_exists shasum; then
        tool="shasum"
    elif command_exists openssl; then
        tool="openssl"
    else
        warn "未找到 SHA256 校验工具，跳过完整性校验"
        return 0
    fi

    if [[ "$channel" == "alpha" ]]; then
        # 测试版：上游 Prerelease-Alpha 提供 checksums.txt，沿用原方案，不做改动
        sums_url="${MIHOMO_RELEASE}/Prerelease-Alpha/checksums.txt"
        sums=$(http_get "$sums_url" 8 30 2>/dev/null || true)
        if [[ -z "$sums" ]]; then
            local resolved
            if resolved=$(resolve_url "$sums_url" 2>/dev/null); then
                sums=$(http_get "$resolved" 8 30 2>/dev/null || true)
            fi
        fi
        # 兼容常见格式：<hash>  <file>、<hash> *<file>、<hash>  ./<file>；
        # 并去掉行尾 CR（上游校验文件可能是 CRLF，否则 $NF 会带上 \r 导致匹配失败）
        if [[ -n "$sums" ]]; then
            expect=$(printf '%s\n' "$sums" | awk -v n="$name" '
                {
                    sub(/\r$/, "")
                    f = $NF
                    sub(/^\*/, "", f)
                    sub(/^\.\//, "", f)
                    if (f == n) { print tolower($1); exit }
                }
            ')
        fi
        if [[ -z "$expect" ]]; then
            warn "无法获取 checksums.txt，跳过完整性校验"
            return 0
        fi
    else
        # 正式版：上游不发布 checksums.txt，直接用 GitHub API 的 asset digest
        expect=$(fetch_asset_digest "$name" 2>/dev/null || true)
        if [[ -z "$expect" ]]; then
            warn "无法获取官方校验值（GitHub API 的 asset digest 不可用），已跳过 SHA256 校验"
            return 0
        fi
    fi

    case "$tool" in
        sha256sum) actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}') ;;
        shasum)    actual=$(shasum -a 256 "$file" 2>/dev/null | awk '{print $1}') ;;
        openssl)   actual=$(openssl dgst -sha256 "$file" 2>/dev/null | awk '{print $NF}') ;;
    esac

    if [[ "$actual" != "$expect" ]]; then
        err "SHA256 校验失败：期望 ${expect}，实际 ${actual:-<空>}"
        return 1
    fi
    ok "SHA256 校验通过"
}

# ---------- 网络信息 ----------
# 取本机对外 IPv4/IPv6，跳过 TUN 与容器虚拟网卡。
# 注意：TUN 模式下 `ip route get 1.1.1.1` 的 src 会返回 198.18.x.x 这类虚拟地址
# （mihomo 的 Meta 网卡），直接使用会得到无法访问面板的错误 IP。
detect_network_info() {
    local iface cidr

    ipv4=""
    while read -r iface cidr; do
        [[ -n "$iface" && -n "$cidr" ]] || continue
        case "$iface" in
            lo|lo:*|Meta|meta|tun*|utun*|tap*|wg*|docker*|veth*|br-*|virbr*|cni*|flannel*)
                continue
                ;;
        esac
        ipv4="${cidr%%/*}"
        break
    done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2, $4}')

    # 枚举失败时退回路由查询（无 TUN 干扰时结果正确）
    if [[ -z "$ipv4" ]]; then
        ipv4=$(ip route get 1.1.1.1 2>/dev/null \
            | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}' || true)
    fi
    [[ -n "$ipv4" ]] || ipv4="127.0.0.1"

    ipv6=""
    while read -r iface cidr; do
        [[ -n "$iface" && -n "$cidr" ]] || continue
        case "$iface" in
            lo|lo:*|Meta|meta|tun*|utun*|tap*|wg*|docker*|veth*|br-*|virbr*|cni*|flannel*)
                continue
                ;;
        esac
        ipv6="${cidr%%/*}"
        break
    done < <(ip -o -6 addr show scope global 2>/dev/null | awk '{print $2, $4}')
}

# ---------- 安装检查 ----------
# 校验 mihomo 是否已安装
check_installation() {
    if [[ ! -f "$BIN_FILE" ]]; then
        err "未检测到 mihomo，请先执行安装"
        return 1
    fi
    return 0
}

# ---------- 状态 ----------
# 打印安装、运行、自启与版本等状态面板
show_status() {
    local install_status run_status auto_start software_version update_time script_path
    detect_network_info

    script_path=$(command -v mihomo 2>/dev/null || true)
    [[ -n "$script_path" ]] || script_path="$SHELL_FILE"

    # 失败不再拖垮整个状态页
    # 一次性剥掉 "# date   : " 前缀，兼容 "2026-10-20" 与 "2026-10-20 20:33:09" 两种写法
    # 旧实现连用两次 ${var#*:}，会把 "2025-11-23 11:25:43" 截成 "25:43"
    update_time=""
    if [[ -f "$script_path" ]]; then
        update_time=$(awk '/^#[[:space:]]*date[[:space:]]*:/ {
            sub(/^#[[:space:]]*date[[:space:]]*:[[:space:]]*/, "")
            print
            exit
        }' "$script_path" 2>/dev/null || true)
        update_time=${update_time%"${update_time##*[![:space:]]}"}
    fi
    [[ -n "$update_time" ]] || update_time="未知"

    if [[ ! -f "$BIN_FILE" ]]; then
        install_status="${COLOR_RED}未安装${COLOR_RESET}"
        run_status="${COLOR_RED}未运行${COLOR_RESET}"
        auto_start="${COLOR_RED}未设置${COLOR_RESET}"
        software_version="${COLOR_RED}未安装${COLOR_RESET}"
    else
        install_status="${COLOR_GREEN}已安装${COLOR_RESET}"
        if service_is_active; then
            run_status="${COLOR_GREEN}已运行${COLOR_RESET}"
        else
            run_status="${COLOR_RED}未运行${COLOR_RESET}"
        fi
        if service_is_enabled; then
            auto_start="${COLOR_GREEN}已设置${COLOR_RESET}"
        else
            auto_start="${COLOR_RED}未设置${COLOR_RESET}"
        fi
        if [[ -f "$VERSION_FILE" ]]; then
            software_version=$(cat "$VERSION_FILE" 2>/dev/null || true)
            [[ -n "$software_version" ]] || software_version="未知"
        else
            software_version="未知"
        fi
    fi

    kv "安装状态" "$install_status"
    kv "运行状态" "$run_status"
    kv "开机自启" "$auto_start"
    kv "当前系统" "${COLOR_GREEN}${distro}${COLOR_RESET}"
    kv "软件版本" "${COLOR_GREEN}${software_version}${COLOR_RESET}"
    if [[ -f "$BIN_FILE" && -f "$VERSION_FILE" && "$software_version" != "未知" ]]; then
        local chan
        chan=$(channel_name "$(detect_channel "$software_version")")
        kv "版本通道" "${COLOR_GREEN}${chan}${COLOR_RESET}"
    fi
    kv "本机IPv4" "${COLOR_GREEN}${ipv4}${COLOR_RESET}"
    # 无 IPv6 时用默认色：绿色是成功色，"无"不是成功状态
    if [[ -n "${ipv6:-}" ]]; then
        kv "本机IPv6" "${COLOR_GREEN}${ipv6}${COLOR_RESET}"
    else
        kv "本机IPv6" "无"
    fi
    if [[ -f "$CONFIG_FILE" ]]; then
        kv "面板地址" "${COLOR_GREEN}$(panel_url)${COLOR_RESET}"
    else
        kv "面板地址" "${COLOR_RED}未安装${COLOR_RESET}"
    fi
    # 脚本版本不在此展示：菜单页头与 status 子命令页头（print_header）各显示一次，
    # 此处再显示会与页头同屏重复
    kv "更新时间" "${COLOR_GREEN}${update_time}${COLOR_RESET}"
}

# status 子命令入口：页头 + 状态面板 + 收尾分隔线。
# 页头保证子命令路径也能看到脚本版本，面板内不再重复展示
status_cmd() {
    print_header
    show_status
    hreq
}

# ---------- 服务操作 ----------
# 执行服务操作并打印结果
service_action() { # $1=start|stop|restart|enable|disable
    local action="$1" text
    case "$action" in
        start)   text="启动"         ;;
        stop)    text="停止"         ;;
        restart) text="重启"         ;;
        enable)  text="设置开机自启" ;;
        disable) text="取消开机自启" ;;
        *) err "未知操作：${action}"; return 1 ;;
    esac

    check_installation || return 1

    if [[ "$action" == "enable" || "$action" == "disable" ]]; then
        if [[ "$action" == "enable" ]] && service_is_enabled; then
            warn "已${text}，无需重复操作"
            return 0
        fi
        if [[ "$action" == "disable" ]] && ! service_is_enabled; then
            warn "已${text}，无需重复操作"
            return 0
        fi
        info "正在${text}，请等待..."
        if service_enable_toggle "$action"; then
            ok "${text}成功"
            return 0
        fi
        err "${text}失败"
        return 1
    fi

    if [[ "$action" == "start" ]] && service_is_active; then
        warn "已${text}，无需重复操作"
        return 0
    fi
    if [[ "$action" == "stop" ]] && ! service_is_active; then
        warn "已${text}，无需重复操作"
        return 0
    fi

    info "正在${text}，请等待..."
    sleep 1
    # 直接判断命令返回码，不再依赖 $?（set -e 下不可达）
    if ! service_do "$action"; then
        err "${text}失败"
        return 1
    fi
    if [[ "$action" == "stop" ]]; then
        if service_is_active; then
            err "${text}失败：进程仍在运行"
            return 1
        fi
        ok "${text}成功"
        return 0
    fi
    if wait_active 10; then
        ok "${text}成功"
    else
        err "${text}失败，请查看日志：journalctl -u mihomo -n 50"
        return 1
    fi
}

# 实时查看服务日志
logs_mihomo() {
    case "$init_sys" in
        systemd)
            info "正在实时查看 mihomo 日志，按 Ctrl+C 退出"
            journalctl -u mihomo -o cat -f
            ;;
        openrc)
            err "OpenRC 暂不支持通过本脚本查看日志，请使用：logread | grep mihomo"
            return 1
            ;;
        *)
            err "当前 init 系统不受支持，无法查看日志"
            return 1
            ;;
    esac
}

# ---------- 日志清理 ----------
# 日常上限由 log() 里的 log_trim 保证，这里只是手动兜底入口：
# 日志被其他程序写大、或需要立即压缩时使用。
log_clean() {
    local f rc cleaned=0
    for f in "$LOG_FILE" "$INSTALL_LOG"; do
        [[ -f "$f" ]] || continue
        rc=0
        log_trim "$f" || rc=$?
        case "$rc" in
            0) cleaned=1; ok "已清理 ${f}：保留最近 1000 行" ;;
            2) err "清理 ${f} 失败" ;;
        esac
    done
    (( cleaned )) || info "日志均未超过 1 MB，无需清理"
}

# ---------- 配置公共 ----------
# 面板鉴权：远程配置不含 secret，而 external-controller 默认监听 0.0.0.0:9090，
# 不加密钥等于把控制 API 无鉴权暴露到公网，因此是否启用由用户决定。
ask_secret() {
    # 非交互（管道安装）时无法询问，默认启用密钥，避免面板无鉴权暴露
    if ! is_interactive; then
        SECRET_ENABLED=1
        info "非交互环境，面板密钥默认启用"
        return 0
    fi
    if confirm "是否为面板启用密钥鉴权？(Y/n):" "y"; then
        SECRET_ENABLED=1
    else
        SECRET_ENABLED=0
        warn_secret_disabled
    fi
}

# 未启用密钥时的统一警告，安装、重置、禁用三处共用
warn_secret_disabled() {
    local host="${ipv4:-127.0.0.1}"
    warn "⚠ 面板未启用密钥：http://${host}:9090/ui 任何人可访问"
    warn "  任何能访问该端口的人都可以修改你的配置。"
    warn "  建议用防火墙限制来源，或改用 SSH 隧道访问。"
}

# 移除配置中的 secret 行，用于禁用与重新生成
strip_controller_secret() { # $1=配置文件
    local f="$1" tmp
    [[ -f "$f" ]] || return 1
    tmp=$(mktemp "${ROOT_DIR}/.secret.XXXXXX")
    tmp_files+=("$tmp")
    awk '!/^secret:/' "$f" >"$tmp"
    mv -f -- "$tmp" "$f"
    controller_secret=""
}

# 读取配置中的面板密钥，仅在非空时输出
read_controller_secret() { # $1=配置文件
    local q=$'\x27'
    awk -v q="$q" '
        /^secret:[[:space:]]*/ {
            v = $0
            sub(/^secret:[[:space:]]*/, "", v)
            gsub("[[:space:]\"" q "]", "", v)
            if (v != "") print v
            exit
        }
    ' "$1" 2>/dev/null || true
}

# 注入面板密钥：已有非空 secret 时保留用户设置，重复执行不会重复插入
# $2=需要沿用旧密钥时传入（如重装保留订阅），避免用户已保存的密钥失效
ensure_controller_secret() { # $1=配置文件 $2=沿用旧密钥（可选），输出最终密钥
    local f="$1" reuse="${2:-}" cur new tmp q
    q=$'\x27'

    cur=$(read_controller_secret "$f")
    if [[ -n "$cur" ]]; then
        controller_secret="$cur"
        printf '%s' "$cur"
        return 0
    fi

    new="$reuse"
    if [[ -z "$new" ]]; then
        new=$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24 || true)
        [[ -n "$new" ]] || new="mihomo$(date +%s)$$"
    fi

    # 必须整体读入后再决定插入位置：secret 可能出现在 external-controller 之前，
    # 单趟流式处理会先命中 controller 分支而漏掉占位空值，导致出现重复 secret 键。
    tmp=$(mktemp "${ROOT_DIR}/.secret.XXXXXX")
    tmp_files+=("$tmp")
    awk -v s="$new" -v q="$q" '
        { lines[NR] = $0 }
        END {
            s_idx = 0; s_empty = 0; c_idx = 0
            for (i = 1; i <= NR; i++) {
                if (s_idx == 0 && lines[i] ~ /^secret:[[:space:]]*/) {
                    s_idx = i
                    v = lines[i]
                    sub(/^secret:[[:space:]]*/, "", v)
                    sub(/[[:space:]]+$/, "", v)
                    if (v == "" || v == "\"\"" || v == q q) s_empty = 1
                }
                if (c_idx == 0 && lines[i] ~ /^external-controller:/) c_idx = i
            }

            if (s_idx > 0 && !s_empty) {           # 已有有效密钥，原样输出
                for (i = 1; i <= NR; i++) print lines[i]
                exit
            }
            if (s_idx > 0) {                       # 替换 secret 占位空值
                for (i = 1; i <= NR; i++) {
                    if (i == s_idx) print "secret: \"" s "\""
                    else print lines[i]
                }
                exit
            }
            if (c_idx > 0) {                       # 插到 external-controller 之后
                for (i = 1; i <= NR; i++) {
                    print lines[i]
                    if (i == c_idx) print "secret: \"" s "\""
                }
                exit
            }
            for (i = 1; i <= NR; i++) print lines[i]
            print "secret: \"" s "\""
        }
    ' "$f" >"$tmp"

    mv -f -- "$tmp" "$f"
    controller_secret="$new"
    printf '%s' "$new"
}

# 从配置读取面板监听地址，拼成可访问的 URL
# 监听 0.0.0.0 / :: 表示所有网卡，对外应显示本机 IPv4，而不是 0.0.0.0
panel_url() {
    local addr host port

    [[ -n "$ipv4" ]] || detect_network_info

    addr=$(awk '
        /^[[:space:]]*external-controller:/ {
            sub(/^[[:space:]]*external-controller:[[:space:]]*/, "")
            gsub(/["'"'"']/, "")
            sub(/[[:space:]]+$/, "")
            print
            exit
        }
    ' "$CONFIG_FILE" 2>/dev/null || true)

    port="9090"
    host="$addr"
    if [[ "$addr" == \[*\]:* ]]; then
        host="${addr#\[}"
        host="${host%%\]*}"
        port="${addr##*:}"
    elif [[ "$addr" == *:* ]]; then
        host="${addr%%:*}"
        port="${addr##*:}"
    fi

    case "$host" in
        ""|0.0.0.0|"::") host="${ipv4:-127.0.0.1}" ;;
    esac

    printf 'http://%s:%s/ui' "$host" "$port"
}

# 备份当前配置，固定覆盖同一份 .bak，不累积时间戳文件
backup_config() {
    local bak="${CONFIG_FILE}.bak"
    [[ -f "$CONFIG_FILE" ]] || return 0
    if ! cp -f -- "$CONFIG_FILE" "$bak"; then
        err "配置备份失败，已中止写入"
        return 1
    fi
    chmod 600 "$bak"
    printf '%s' "$bak"
}

# 锚定 proxy-providers 段统计订阅数量
count_providers() { # $1=文件，缺省为当前配置
    awk '
        /^proxy-providers:[[:space:]]*$/ { f = 1; next }
        f && /^[^[:space:]#]/            { f = 0 }
        f && /^[[:space:]]+provider_[0-9]+:/ { c++ }
        END { print c + 0 }
    ' "${1:-$CONFIG_FILE}"
}

# 计算下一个可用的订阅编号
next_provider_index() {
    local max
    max=$(awk '
        /^proxy-providers:[[:space:]]*$/ { f = 1; next }
        f && /^[^[:space:]#]/            { f = 0 }
        f && /^[[:space:]]+provider_[0-9]+:/ {
            v = $1
            sub(/^provider_/, "", v)
            sub(/:.*$/, "", v)
            if (v + 0 > max) max = v + 0
        }
        END { print max + 0 }
    ' "$CONFIG_FILE")
    printf '%d' "$((max + 1))"
}

# 列出订阅：必须覆盖没有 additional-prefix 的条目（例如手工编辑过的 provider），
# 否则这些编号不会出现在列表中，用户无法选中它们做修改或删除。
list_providers() {
    awk '
        function show() {
            if (cur != "") {
                printf "  %s  %s\n", cur, (pname == "" ? "<未命名>" : pname)
                cur = ""
                pname = ""
            }
        }
        /^proxy-providers:[[:space:]]*$/ { f = 1; next }
        f && /^[^[:space:]#]/            { show(); f = 0 }
        f && /^  provider_[0-9]+:/ {
            show()
            cur = $1
            sub(/^provider_/, "", cur)
            sub(/:$/, "", cur)
            next
        }
        f && cur != "" && /additional-prefix:/ {
            v = $0
            sub(/.*additional-prefix:[[:space:]]*/, "", v)
            gsub(/["\[\]]/, "", v)
            pname = v
            next
        }
        END { show() }
    ' "$CONFIG_FILE"
}

# 判断指定编号的机场订阅是否已存在
provider_exists() { # $1=编号
    local num
    num=$(printf '%02d' "$1")
    grep -q "^  provider_${num}:" "$CONFIG_FILE"
}

# 段外是否存在 provider 编号引用（如 proxy-groups 的 use:）
# 存在时不可重编号，否则引用会失效
has_provider_refs() { # $1=文件
    awk '
        /^proxy-providers:[[:space:]]*$/ { in_pp = 1; next }
        in_pp && /^[^[:space:]#]/ { in_pp = 0 }
        !in_pp && /provider_[0-9]/ { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$1"
}

# 兼容层：修正上游默认配置中的布尔值笔误（如 tcp-concurrent: tru）
# 上游已于 2026-10-20 修复该行；保留此函数用于应对镜像/CDN 缓存旧文件的场景，
# 只匹配 4 种确定拼写，不会掩盖其他类型的配置错误（那些由 config_test 拦截）。
# 若确认镜像缓存均已刷新，可连同调用处一并删除。
normalize_config() { # $1=配置文件
    local f="$1" tmp rc=0
    tmp=$(mktemp "${ROOT_DIR}/.norm.XXXXXX")
    tmp_files+=("$tmp")

    awk '
        {
            sub(/\r$/, "")
            if ($0 ~ /^[[:space:]]*[A-Za-z0-9_-]+:[[:space:]]*(tru|ture)[[:space:]]*$/) {
                sub(/(tru|ture)[[:space:]]*$/, "true")
                fixed = 1
            } else if ($0 ~ /^[[:space:]]*[A-Za-z0-9_-]+:[[:space:]]*(flase|fasle)[[:space:]]*$/) {
                sub(/(flase|fasle)[[:space:]]*$/, "false")
                fixed = 1
            }
            print
        }
        END { exit(fixed ? 3 : 0) }
    ' "$f" >"$tmp" || rc=$?

    case "$rc" in
        0)
            mv -f -- "$tmp" "$f"
            ;;
        3)
            mv -f -- "$tmp" "$f"
            warn "已修正上游默认配置中的布尔值笔误（如 tcp-concurrent: tru → true）"
            ;;
        *)
            rm -f -- "$tmp"
            err "配置规范化失败"
            return 1
            ;;
    esac
    return 0
}

# 用 mihomo 自身校验配置，失败时打印原因
config_test() { # $1=配置文件
    local out
    if ! out=$("$BIN_FILE" -t -f "$1" 2>&1); then
        printf '%s\n' "$out" | tail -n 20 >&2
        return 1
    fi
    return 0
}

# 校验 + 重启 + 失败回滚
apply_config() { # $1=备份路径
    local bak="${1:-}"
    if ! config_test "$CONFIG_FILE"; then
        err "配置校验未通过"
        if [[ -n "$bak" && -f "$bak" ]]; then
            cp -f -- "$bak" "$CONFIG_FILE"
            err "已回滚到备份：${bak}"
        fi
        return 1
    fi

    # init 未知（如 runit/s6 系统）时无法托管服务，只保证配置有效。
    # 缺少此分支会让 service_do 返回 1，导致每次写配置都被误判为失败并回滚。
    if [[ "$init_sys" == "unknown" ]]; then
        warn "未识别 init 系统，跳过服务重启"
        warn "请手动重启使配置生效：${BIN_FILE} -d ${ROOT_DIR}"
        return 0
    fi

    if ! service_do restart; then
        err "服务重启失败"
        if [[ -n "$bak" && -f "$bak" ]]; then
            cp -f -- "$bak" "$CONFIG_FILE"
            err "已回滚到备份：${bak}"
            service_do restart >/dev/null 2>&1 || true
        fi
        return 1
    fi
    sleep 1
    if ! wait_active 10; then
        err "服务未处于运行状态"
        if [[ -n "$bak" && -f "$bak" ]]; then
            cp -f -- "$bak" "$CONFIG_FILE"
            err "已回滚到备份：${bak}"
            service_do restart >/dev/null 2>&1 || true
        fi
        return 1
    fi
    ok "配置已生效，服务运行中"
}

# 落盘并应用新配置：写入 → 收紧权限 → 校验并重启，失败自动回滚
commit_config() { # $1=新文件 $2=备份路径 $3=描述
    local new="$1" bak="$2" desc="$3"
    if ! mv -f -- "$new" "$CONFIG_FILE"; then
        err "${desc}失败：无法写入配置"
        return 1
    fi
    chmod 600 "$CONFIG_FILE"
    if ! apply_config "$bak"; then
        err "${desc}失败"
        return 1
    fi
    ok "${desc}完成"
}

# 交互收集单个机场信息，输出 provider 配置块
read_subscription() { # $1=序号
    local idx="$1" url name
    while true; do
        read_input url "${COLOR_CYAN}请输入第 ${idx} 个机场的订阅链接: ${COLOR_RESET}"
        if [[ -z "$url" ]]; then
            warn "订阅链接不能为空"
            continue
        fi
        if ! grep -Eq '^https?://[^[:space:]"]+$' <<<"$url"; then
            warn "订阅链接格式不正确（需以 http:// 或 https:// 开头，且不含空格与引号）"
            continue
        fi
        break
    done
    read_input name "${COLOR_CYAN}请输入机场名称（留空使用默认名）: ${COLOR_RESET}"
    [[ -z "$name" ]] && name="机场${idx}"

    printf '  provider_%02d:\n' "$idx"
    printf '    url: "%s"\n' "$(sanitize_yaml "$url")"
    printf '    type: http\n'
    printf '    interval: 86400\n'
    printf '    health-check: {enable: true, url: "https://www.gstatic.com/generate_204", interval: 300}\n'
    printf '    override:\n'
    printf '      additional-prefix: "[%s]"\n' "$(sanitize_yaml "$name")"
}

# 把 provider 块写入 src，结果输出到 dst，带数量校验
# 已有 proxy-providers 段时追加到段末，并把整段缩进重排为 2/4/6 的规范层级、
# 去掉段内空行，保证多次追加后条目始终连续且彼此对齐；
# 仅有 # 机场配置 标记时补全段头；两者皆无则追加到文件末尾。
# 三个分支都会顺带清掉 CR，避免 Windows 编辑过的配置把 \r 带进 YAML 值。
# 注意：必须接收文件路径而非 stdin —— 管道会让函数在子 shell 中执行，
# 导致 tmp_files 无法被 trap 清理。
inject_providers() { # $1=块文件 $2=源配置 $3=输出文件
    local block_file="$1" src="$2" dst="$3" before after

    if [[ ! -s "$block_file" ]]; then
        err "没有可写入的订阅内容"
        return 1
    fi

    before=$(count_providers "$src")

    if grep -q '^proxy-providers:[[:space:]]*$' "$src"; then
        # 追加到段末，并把整段重排为规范缩进（provider 键 2 空格、子键 4 空格、
        # additional-prefix 6 空格），段内空行一律去掉。
        # 这样无论原文件是脚本生成还是手工编辑过缩进，追加后都能与既有条目对齐，
        # 也不会出现段头与下一个顶层键之间的空行被夹到两个 provider 之间。
        awk -v bf="$block_file" '
            function lead(s,    n) {
                n = 0
                while (substr(s, n + 1, 1) == " ") n++
                return n
            }
            # 按缩进单位重算：键统一到 2 空格，子层按 (2,4,6,...) 逐级归一
            function reindent(s, ind, unit,    cur, n) {
                cur = lead(s)
                if (cur <= ind) return s
                n = int((cur - ind) / unit) * 2
                return sprintf("%" (2 + n) "s%s", "", substr(s, cur + 1))
            }
            { sub(/\r$/, ""); lines[NR] = $0 }
            END {
                s = 0; e = 0
                for (i = 1; i <= NR; i++) {
                    if (s == 0 && lines[i] ~ /^proxy-providers:[[:space:]]*$/) { s = i; continue }
                    if (s > 0 && lines[i] ~ /^[^[:space:]#]/) { e = i; break }
                }
                if (s == 0) { for (i = 1; i <= NR; i++) print lines[i]; exit }
                if (e == 0) e = NR + 1

                for (i = 1; i < s; i++) print lines[i]
                print "proxy-providers:"

                nb = 0
                for (i = s + 1; i < e; i++) {
                    ln = lines[i]
                    if (ln ~ /^[[:space:]]*$/) continue
                    if (ln ~ /^[[:space:]]*provider_[0-9]+:/) {
                        nb++
                        blk[nb, 0] = ln
                        cnt[nb] = 1
                    } else if (nb == 0) {
                        pre[++np] = ln
                    } else {
                        blk[nb, cnt[nb]] = ln
                        cnt[nb]++
                    }
                }
                for (i = 1; i <= np; i++) print pre[i]
                for (b = 1; b <= nb; b++) {
                    ind = lead(blk[b, 0])
                    unit = 0
                    for (j = 1; j < cnt[b]; j++) {
                        c = lead(blk[b, j])
                        if (c > ind && (unit == 0 || c - ind < unit)) unit = c - ind
                    }
                    if (unit <= 0) unit = 2
                    print "  " substr(blk[b, 0], ind + 1)
                    for (j = 1; j < cnt[b]; j++) print reindent(blk[b, j], ind, unit)
                }
                while ((getline line < bf) > 0) {
                    sub(/\r$/, "", line)
                    if (line ~ /^[[:space:]]*$/) continue
                    print line
                }
                close(bf)
                # 段内不空行，但保留与下一个顶层键之间的一个空行作为分隔
                if (e <= NR) print ""
                for (i = e; i <= NR; i++) print lines[i]
            }
        ' "$src" >"$dst"
    elif grep -q '^# 机场配置' "$src"; then
        awk -v bf="$block_file" '
            /^# 机场配置/ {
                sub(/\r$/, "")
                print
                print "proxy-providers:"
                while ((getline line < bf) > 0) {
                    sub(/\r$/, "", line)
                    if (line ~ /^[[:space:]]*$/) continue
                    print line
                }
                close(bf)
                skip = 1
                next
            }
            # 吞掉原有空行，改为在块后补一个空行，与"追加"分支的输出保持一致
            skip && /^[[:space:]]*$/ { next }
            {
                if (skip) { print ""; skip = 0 }
                sub(/\r$/, ""); print
            }
        ' "$src" >"$dst"
        # 默认配置本就没有 proxy-providers 段，走标记分支是正常路径，不提示
    else
        awk -v bf="$block_file" '
            { sub(/\r$/, ""); print }
            END {
                print ""
                print "proxy-providers:"
                while ((getline line < bf) > 0) {
                    sub(/\r$/, "", line)
                    if (line ~ /^[[:space:]]*$/) continue
                    print line
                }
                close(bf)
            }
        ' "$src" >"$dst"
        warn "配置中既无 proxy-providers 段也无标记，已追加到文件末尾"
    fi

    if ! grep -q '^proxy-providers:' "$dst"; then
        err "写入失败：结果中缺少 proxy-providers 段"
        return 1
    fi

    after=$(count_providers "$dst")
    if (( after <= before )); then
        err "写入失败：订阅数量未增加（${before} → ${after}）"
        return 1
    fi
    return 0
}

# ---------- 新增订阅 ----------
# 交互新增一个或多个机场订阅
add_provider() {
    check_installation || return 1
    if [[ ! -f "$CONFIG_FILE" ]]; then
        err "配置文件不存在：${CONFIG_FILE}"
        return 1
    fi

    local bak block_file tmp idx ans block="" before
    bak=$(backup_config) || return 1
    before=$(count_providers)
    idx=$(next_provider_index)
    ok "当前共有 ${before} 个订阅，新增编号从 $(printf '%02d' "$idx") 开始"

    while true; do
        block+=$(read_subscription "$idx")
        block+=$'\n'
        idx=$((idx + 1))
        read_input ans "${COLOR_CYAN}是否继续添加？回车继续，输入 n/N 结束: ${COLOR_RESET}"
        [[ "$ans" =~ ^[nN]$ ]] && break
    done

    block_file=$(mktemp "${ROOT_DIR}/.block.XXXXXX")
    tmp_files+=("$block_file")
    printf '%s' "$block" >"$block_file"

    tmp=$(mktemp "${ROOT_DIR}/.config.XXXXXX")
    tmp_files+=("$tmp")
    # inject_providers 内部已做空块校验、段存在校验与数量校验
    if ! inject_providers "$block_file" "$CONFIG_FILE" "$tmp"; then
        err "新增订阅失败，现有配置未改动"
        return 1
    fi

    commit_config "$tmp" "$bak" "新增订阅"
}

# ---------- 修改订阅 ----------
# 交互修改指定订阅的链接与名称
modify_provider() {
    check_installation || return 1

    # 选号在前、备份在后：订阅为空时 select_provider 直接返回，不产生无用备份
    select_provider "修改" || return 1
    local bak url name tmp target="$provider_target"
    bak=$(backup_config) || return 1

    while true; do
        read_input url "${COLOR_CYAN}新的订阅链接: ${COLOR_RESET}"
        if grep -Eq '^https?://[^[:space:]"]+$' <<<"$url"; then
            break
        fi
        warn "订阅链接格式不正确"
    done
    read_input name "${COLOR_CYAN}新的机场名称（留空保留原名）: ${COLOR_RESET}"

    tmp=$(mktemp "${ROOT_DIR}/.config.XXXXXX")
    tmp_files+=("$tmp")

    # 名称留空时不改 additional-prefix：name 传空串，awk 内据此跳过该分支
    awk -v target="$target" \
        -v url="$(sanitize_yaml "$url")" \
        -v name="$(sanitize_yaml "$name")" '
        BEGIN { in_pp = 0; in_blk = 0 }
        /^proxy-providers:[[:space:]]*$/ { in_pp = 1; print; next }
        in_pp && /^[^[:space:]#]/ { in_pp = 0; in_blk = 0 }
        in_pp {
            if ($0 ~ /^  provider_[0-9]+:/) {
                in_blk = ($1 == target)
                print
                next
            }
            if (in_blk && $0 ~ /^[[:space:]]+url:/) {
                print "    url: \"" url "\""
                next
            }
            if (name != "" && in_blk && $0 ~ /^[[:space:]]+additional-prefix:/) {
                print "      additional-prefix: \"[" name "]\""
                next
            }
        }
        { print }
    ' "$CONFIG_FILE" >"$tmp"

    if ! grep -q "^  ${target}" "$tmp"; then
        err "写入失败：目标订阅在结果中丢失，已中止"
        return 1
    fi

    commit_config "$tmp" "$bak" "修改订阅 $(printf '%02d' "$provider_num")"
}

# 列出订阅并交互选择编号：结果写入全局 provider_total / provider_num / provider_target
select_provider() { # $1=动作词（修改/删除），用于提示语
    local num
    provider_total=$(count_providers)
    if (( provider_total == 0 )); then
        err "当前没有任何订阅可供$1"
        return 1
    fi

    ok "当前共有 ${provider_total} 个订阅："
    list_providers
    printf '\n'

    while true; do
        read_input num "${COLOR_CYAN}请输入要$1的编号（如 01）: ${COLOR_RESET}"
        num=${num#provider_}
        num=${num%:}
        if ! grep -Eq '^[0-9]+$' <<<"$num"; then
            warn "请输入纯数字编号"
            continue
        fi
        if ! provider_exists "$num"; then
            warn "未找到编号为 $(printf '%02d' "$num") 的订阅"
            continue
        fi
        break
    done
    provider_num="$num"
    provider_target="provider_$(printf '%02d' "$num"):"
}

# ---------- 删除订阅 ----------
# 交互删除指定订阅，必要时重编号
delete_provider() {
    check_installation || return 1
    local total
    total=$(count_providers)
    if (( total == 0 )); then
        err "当前没有任何订阅可供删除"
        return 1
    fi
    # 删除前校验，避免删空
    if (( total <= 1 )); then
        err "至少需要保留一个订阅，当前仅剩 ${total} 个，无法删除"
        return 1
    fi

    local bak tmp tmp2 target
    bak=$(backup_config) || return 1
    select_provider "删除" || return 1
    target="$provider_target"

    tmp=$(mktemp "${ROOT_DIR}/.config.XXXXXX")
    tmp_files+=("$tmp")
    awk -v target="$target" '
        BEGIN { in_pp = 0; skipping = 0 }
        /^proxy-providers:[[:space:]]*$/ { in_pp = 1; print; next }
        in_pp && /^[^[:space:]#]/ { in_pp = 0; skipping = 0 }
        in_pp {
            if ($0 ~ /^  provider_[0-9]+:/) {
                if ($1 == target) { skipping = 1; next }
                skipping = 0
                print
                next
            }
            if (skipping) next
            print
            next
        }
        { print }
    ' "$CONFIG_FILE" >"$tmp"

    tmp2=$(mktemp "${ROOT_DIR}/.config.XXXXXX")
    tmp_files+=("$tmp2")
    if has_provider_refs "$tmp"; then
        # 有外部引用时不重编号，保留编号空档以维持引用有效
        warn "配置中存在 provider 编号引用（如 use:），跳过重编号"
        cp -f -- "$tmp" "$tmp2"
    else
        awk '
            BEGIN { in_pp = 0; n = 0 }
            /^proxy-providers:[[:space:]]*$/ { in_pp = 1; print; next }
            in_pp && /^[^[:space:]#]/ { in_pp = 0 }
            in_pp && /^  provider_[0-9]+:/ {
                n++
                sub(/provider_[0-9]+:/, sprintf("provider_%02d:", n))
            }
            { print }
        ' "$tmp" >"$tmp2"
    fi

    if ! grep -q '^proxy-providers:' "$tmp2"; then
        err "写入失败：结果中缺少 proxy-providers 段，已中止"
        return 1
    fi
    if [[ "$(count_providers "$tmp2")" -ne "$((total - 1))" ]]; then
        err "写入失败：订阅数量异常，已中止"
        return 1
    fi

    commit_config "$tmp2" "$bak" "删除订阅 $(printf '%02d' "$provider_num")"
    ok "当前剩余 $(count_providers) 个订阅"
}

# ---------- 重置配置 ----------
# 用默认配置覆盖当前配置并重建订阅
reset_config() {
    check_installation || return 1
    if ! confirm "重置将用默认配置覆盖当前配置（已自动备份），确认？(y/N):" "n"; then
        warn "已取消重置"
        return 0
    fi
    ask_secret

    local bak idx=1 ans block="" block_file tmp merged
    bak=$(backup_config) || return 1
    [[ -n "$bak" ]] && ok "原配置已备份：${bak}"

    check_network
    tmp=$(mktemp "${ROOT_DIR}/.config.XXXXXX")
    tmp_files+=("$tmp")
    # 先下到临时文件，校验后再替换，避免 -O 先截断
    if ! download_file "$CONFIG_URL" "$tmp" "默认配置"; then
        err "默认配置下载失败，现有配置未改动"
        return 1
    fi
    if [[ ! -s "$tmp" ]]; then
        err "下载的配置为空，现有配置未改动"
        return 1
    fi
    normalize_config "$tmp" || { err "配置规范化失败，现有配置未改动"; return 1; }

    # 先校验上游配置本身，不通过就中止，现有配置保持不动
    if ! config_test "$tmp"; then
        err "上游默认配置未通过 mihomo 校验，已中止（现有配置未改动）"
        return 1
    fi

    while true; do
        block+=$(read_subscription "$idx")
        block+=$'\n'
        idx=$((idx + 1))
        read_input ans "${COLOR_CYAN}是否继续添加？回车继续，输入 n/N 结束: ${COLOR_RESET}"
        [[ "$ans" =~ ^[nN]$ ]] && break
    done

    block_file=$(mktemp "${ROOT_DIR}/.block.XXXXXX")
    tmp_files+=("$block_file")
    printf '%s' "$block" >"$block_file"

    merged=$(mktemp "${ROOT_DIR}/.config.XXXXXX")
    tmp_files+=("$merged")
    if ! inject_providers "$block_file" "$tmp" "$merged"; then
        err "订阅写入失败（现有配置未改动）"
        return 1
    fi

    # 面板密钥必须在校验前注入，避免把非法配置写进正式文件；
    # 未启用时不得调用注入函数，否则它会把空 secret 占位填上值
    if (( SECRET_ENABLED )); then
        ensure_controller_secret "$merged" >/dev/null
    else
        controller_secret=""
    fi

    if ! config_test "$merged"; then
        err "写入订阅后配置校验失败，已中止（现有配置未改动）"
        return 1
    fi

    commit_config "$merged" "$bak" "重置配置" || return 1

    detect_network_info
    echo
    hreq
    kv "面板地址" "${COLOR_GREEN}$(panel_url)${COLOR_RESET}"
    if [[ -n "$controller_secret" ]]; then
        kv "面板密钥" "${COLOR_GREEN}${controller_secret}${COLOR_RESET}"
    else
        kv "面板密钥" "${COLOR_YELLOW}未启用（面板无鉴权）${COLOR_RESET}"
    fi
    printf '%s\n' "  ${COLOR_YELLOW}注意：mixed-port 7890 不受密钥保护，建议用防火墙限制来源${COLOR_RESET}"
    hreq
}

# ---------- 面板密钥 ----------
# 非交互执行：启用 / 禁用 / 重新生成，全部走 commit_config 以复用校验与失败回滚
secret_set() { # $1=on|off|reset
    check_installation || return 1
    local action="$1" tmp bak
    tmp=$(mktemp "${ROOT_DIR}/.config.XXXXXX")
    tmp_files+=("$tmp")
    cp -f -- "$CONFIG_FILE" "$tmp"

    case "$action" in
        on|reset)
            strip_controller_secret "$tmp"
            ensure_controller_secret "$tmp" >/dev/null
            bak=$(backup_config) || return 1
            commit_config "$tmp" "$bak" "面板密钥" || return 1
            # 密钥只上屏、不落盘：kv 是纯 printf，ok 会经 log 写入 /var/log/mihomo.log
            kv "面板密钥" "${COLOR_GREEN}${controller_secret}${COLOR_RESET}"
            ;;
        off)
            strip_controller_secret "$tmp"
            bak=$(backup_config) || return 1
            commit_config "$tmp" "$bak" "禁用面板密钥" || return 1
            warn_secret_disabled
            ;;
        *)
            err "未知操作：${action}（可选 on / off / reset）"
            return 1
            ;;
    esac
}

# 面板密钥子命令入口：无参数进交互菜单
secret_cmd() { # $1=on|off|reset（可选）
    case "${1:-}" in
        on|off|reset) secret_set "$1" ;;
        "")           manage_secret ;;
        *)            err "未知参数：$1（可选 on / off / reset）"; return 1 ;;
    esac
}

# 交互式管理面板密钥
manage_secret() {
    check_installation || return 1
    local cur choice=""
    cur=$(awk '
        /^secret:[[:space:]]*/ {
            v = $0
            sub(/^secret:[[:space:]]*/, "", v)
            gsub(/[[:space:]"]/, "", v)
            print v
            exit
        }
    ' "$CONFIG_FILE" 2>/dev/null || true)

    printf '\n'
    hreq
    if [[ -n "$cur" ]]; then
        kv "面板密钥" "${COLOR_GREEN}已启用  ${cur}${COLOR_RESET}"
    else
        kv "面板密钥" "${COLOR_YELLOW}未启用（面板无鉴权）${COLOR_RESET}"
    fi
    kv "面板地址" "${COLOR_GREEN}$(panel_url)${COLOR_RESET}"
    hr
    printf '%s\n' "${COLOR_GREEN}1${COLOR_RESET}. 启用并生成新密钥"
    printf '%s\n' "${COLOR_GREEN}2${COLOR_RESET}. 禁用（移除密钥）"
    printf '%s\n' "${COLOR_GREEN}3${COLOR_RESET}. 重新生成密钥"
    hr

    read_input choice "${COLOR_CYAN}请输入选项 (1/2/3): ${COLOR_RESET}"
    case "$choice" in
        1) secret_set on ;;
        2) secret_set off ;;
        3) secret_set reset ;;
        *) warn "无效选项"; return 1 ;;
    esac
}

# ---------- 管理面板 ----------
# 面板子命令入口：无参数进交互菜单，install/update 非交互直接安装
panel_cmd() { # $1=install|update（可选）
    case "${1:-}" in
        install|update) panel_install ;;
        "")             panel_menu ;;
        *)              err "未知参数：$1（可选 install / update）"; return 1 ;;
    esac
}

# 安装/更新管理面板：与安装流程共用 install_webui，重装即更新（幂等）
panel_install() {
    check_installation || return 1
    if ! command_exists unzip; then
        err "缺少 unzip，无法解压面板（Debian/Ubuntu: apt install unzip；Alpine: apk add unzip）"
        return 1
    fi
    install_webui
}

# 面板交互菜单：状态与地址一览，可触发安装/更新
panel_menu() {
    check_installation || return 1
    local choice=""
    printf '\n'
    hreq
    kv "面板地址" "${COLOR_GREEN}$(panel_url)${COLOR_RESET}"
    if [[ -d "${ROOT_DIR}/ui" ]]; then
        kv "面板状态" "${COLOR_GREEN}已安装${COLOR_RESET}"
    else
        kv "面板状态" "${COLOR_YELLOW}未安装${COLOR_RESET}"
    fi
    hr
    printf '%s\n' "${COLOR_GREEN}1${COLOR_RESET}. 安装/更新面板"
    printf '%s\n' "${COLOR_GREEN}2${COLOR_RESET}. 显示访问地址"
    printf '%s\n' "${COLOR_GREEN}0${COLOR_RESET}. 返回"
    hr

    read_input choice "${COLOR_CYAN}请输入选项 (0/1/2): ${COLOR_RESET}"
    case "$choice" in
        1) panel_install ;;
        2) panel_addresses ;;
        0) return 0 ;;
        *) warn "无效选项"; return 1 ;;
    esac
}

# 面板访问地址三行展示：本机 / 内网 / 公网提示
# （借鉴 nelvko/clashctl 的 clashui：公网能否访问取决于放线与鉴权，脚本只提示不代决）
panel_addresses() {
    detect_network_info
    local lan rest port
    lan=$(panel_url)
    rest="${lan#*://}"
    rest="${rest%%/*}"
    port="${rest##*:}"
    printf '\n'
    hreq
    kv "本机访问" "${COLOR_GREEN}http://127.0.0.1:${port}/ui${COLOR_RESET}"
    kv "内网访问" "${COLOR_GREEN}${lan}${COLOR_RESET}"
    printf '%s\n' "  ${COLOR_YELLOW}公网访问需放行 ${port} 端口并确认面板已启用鉴权${COLOR_RESET}"
    hreq
}

# 下载并安装管理面板（zashboard），失败只告警不影响内核
install_webui() {
    local zip="${ROOT_DIR}/gh-pages.zip"
    local tmpdir="${ROOT_DIR}/.webui-tmp"
    local -a dirs=()

    info "开始下载管理面板..."
    download_file "$WEBUI_URL" "$zip" "管理面板" probe_asset || return 1

    rm -rf -- "$tmpdir"
    if ! unzip -oq "$zip" -d "$tmpdir"; then
        rm -f -- "$zip"
        err "面板压缩包解压失败"
        return 1
    fi
    rm -f -- "$zip"

    shopt -s nullglob
    dirs=("${tmpdir}"/*-gh-pages)
    shopt -u nullglob

    if (( ${#dirs[@]} == 0 )); then
        rm -rf -- "$tmpdir"
        err "面板压缩包结构异常，未找到 gh-pages 目录"
        return 1
    fi

    rm -rf -- "${ROOT_DIR}/ui"
    if ! mv -f -- "${dirs[0]}" "${ROOT_DIR}/ui"; then
        rm -rf -- "$tmpdir"
        err "面板目录安装失败"
        return 1
    fi
    rm -rf -- "$tmpdir"
    chmod -R a+rX "${ROOT_DIR}/ui"
    ok "管理面板已安装"
}

# ---------- 配置菜单 ----------
# 配置管理菜单入口
config_mihomo() {
    check_installation || return 1
    hreq
    printf '%s\n' "${COLOR_CYAN}  操作说明${COLOR_RESET}"
    printf '%s\n' "    1. 订阅编号从 01 开始依次排列"
    printf '%s\n' "    2. 订阅不能全部删除，至少保留一个"
    printf '%s\n' "    3. 所有写操作前自动备份配置${COLOR_RESET}"
    hr
    printf '%s\n' "${COLOR_GREEN}1${COLOR_RESET}. 新增机场订阅"
    printf '%s\n' "${COLOR_GREEN}2${COLOR_RESET}. 修改机场订阅"
    printf '%s\n' "${COLOR_GREEN}3${COLOR_RESET}. 删除机场订阅"
    printf '%s\n' "${COLOR_GREEN}4${COLOR_RESET}. 重置配置文件"
    printf '%s\n' "${COLOR_GREEN}5${COLOR_RESET}. 面板密钥（启用/禁用/更换）"
    hr

    local choice=""
    read_input choice "${COLOR_CYAN}输入选项数字: ${COLOR_RESET}"
    case "$choice" in
        1) add_provider     ;;
        2) modify_provider  ;;
        3) delete_provider  ;;
        4) reset_config     ;;
        5) manage_secret    ;;
        *) warn "无效选项" ;;
    esac
}

# ---------- 重装（下载并调用 install.sh）----------
# 注意：本函数与 install.sh 中的同名 install_mihomo 语义不同，故不复用该名字——
# 此处只负责"取回安装脚本并执行"，真正的安装编排在 install.sh 内部。
reinstall_mihomo() {
    check_network

    local old="${ROOT_DIR}.old" tmp
    if [[ -d "$ROOT_DIR" ]]; then
        warn "检测到已存在的安装：${ROOT_DIR}"
        if ! confirm "重新安装将重建程序目录（原目录暂存为 ${old}，安装成功后仍保留，需你确认后手动删除），确认？(y/N):" "n"; then
            warn "已取消安装"
            return 0
        fi
        # 先停服务，再把旧目录整体暂存，失败可恢复。
        # 服务单元文件不在此处删除：若后续下载或校验安装脚本失败，
        # 提前删除会让机器重启后彻底失去自启；由 install.sh 覆盖写入即可。
        service_do stop >/dev/null 2>&1 || true
        # 上次重装保留的旧目录不静默删除：里面可能有用户尚未取回的订阅
        if [[ -d "$old" ]]; then
            warn "检测到上次保留的旧安装目录：${old}"
            if ! confirm "删除该目录以继续？(y/N):" "n"; then
                err "已取消：请先取回 ${old}/config.yaml 或手动删除后重试"
                return 1
            fi
            rm -rf -- "$old" || { err "无法删除 ${old}，已取消"; return 1; }
        fi
        if ! mv -f -- "$ROOT_DIR" "$old"; then
            err "无法暂存旧安装目录，已取消"
            return 1
        fi
        ok "旧安装已暂存：${old}"
    fi

    tmp=$(mktemp /tmp/mihomo-install.XXXXXX)
    tmp_files+=("$tmp")

    # 先下载再校验，最后才执行
    if ! download_file "$INSTALL_URL" "$tmp" "安装脚本"; then
        err "安装脚本下载失败"
        [[ -d "$old" && ! -d "$ROOT_DIR" ]] && mv -f -- "$old" "$ROOT_DIR" && ok "已恢复原目录"
        return 1
    fi
    if ! bash -n "$tmp" 2>/dev/null; then
        err "安装脚本语法校验失败，已放弃执行"
        [[ -d "$old" && ! -d "$ROOT_DIR" ]] && mv -f -- "$old" "$ROOT_DIR" && ok "已恢复原目录"
        return 1
    fi

    if bash "$tmp"; then
        rm -f -- "$tmp"
        # 旧目录保留：其中的 config.yaml 可能含用户尚未取回的订阅，交由用户确认后删除
        if [[ -d "$old" ]]; then
            info "旧安装目录已保留：${old}"
            info "确认新版本运行正常后，可手动删除：rm -rf -- ${old}"
        fi
        # 管理脚本可能已被覆盖，重新加载以避免继续执行旧文件残留
        if [[ -x "$SHELL_FILE" ]]; then
            ok "安装完成，重新加载管理脚本..."
            exec "$SHELL_FILE"
        fi
    else
        err "安装流程未完成"
        # 安装器可能已建了半个 ROOT_DIR，先移除再恢复暂存的旧安装，
        # 否则机器处于"有服务单元、无可用二进制"的状态，重启后自启必然失败
        if [[ -d "$old" ]]; then
            if [[ -d "$ROOT_DIR" ]]; then
                rm -rf -- "$ROOT_DIR" || true
            fi
            if mv -f -- "$old" "$ROOT_DIR"; then
                ok "已恢复原安装：${ROOT_DIR}"
                info "请执行 ${BIN_FILE} -t -d ${ROOT_DIR} 验证后重启服务"
            else
                err "自动恢复失败，请手动执行：mv -f ${old} ${ROOT_DIR}"
            fi
        fi
        return 1
    fi
}

# ---------- 下载并切换版本 ----------
# 生成候选资产基名（不含 .gz），按优先级逐行输出。
# 两种通道的命名差异：
#   正式版 mihomo-linux-amd64-compatible-v1.19.32
#   测试版 mihomo-linux-amd64-compatible-alpha-94b13ae
# amd64 优先 compatible 变体（兼容不支持 v2/v3 指令集的老 CPU），
# 官方未发布该变体时回退到普通 amd64；arm64 无 compatible 变体，
# 其余架构同样不带该后缀。
binary_asset_candidates() {
    local tok
    while IFS= read -r tok; do
        [[ -n "$tok" ]] || continue
        if [[ "$tok" == "amd64" ]]; then
            if [[ "$channel" == "alpha" ]]; then
                printf 'mihomo-linux-amd64-compatible-%s\n' "$version"
                printf 'mihomo-linux-amd64-%s\n' "$version"
            else
                printf 'mihomo-linux-amd64-compatible-v%s\n' "$version"
                printf 'mihomo-linux-amd64-v%s\n' "$version"
            fi
            continue
        fi
        if [[ "$channel" == "alpha" ]]; then
            printf 'mihomo-linux-%s-%s\n' "$tok" "$version"
        else
            printf 'mihomo-linux-%s-v%s\n' "$tok" "$version"
        fi
    done < <(arch_candidates "$arch_raw" || true)
}

# 资产下载地址：正式版走 /v<版本>/，测试版走 /Prerelease-Alpha/
binary_asset_url() { # $1=资产文件名
    if [[ "$channel" == "alpha" ]]; then
        printf '%s/Prerelease-Alpha/%s' "$MIHOMO_RELEASE" "$1"
    else
        printf '%s/v%s/%s' "$MIHOMO_RELEASE" "$version" "$1"
    fi
}

# 下载指定通道的内核并替换：校验 → 自检 → 停服替换 → 启动失败回滚
download_and_install() { # $1=alpha|stable
    local -a cands=()
    local base="" c url gz bak

    channel="$1"
    detect_arch || return 1
    check_network

    if [[ "$channel" == "alpha" ]]; then
        version=$(fetch_alpha_version) || { err "获取测试版版本失败"; return 1; }
    else
        version=$(fetch_latest_version) || { err "获取正式版版本失败"; return 1; }
    fi

    while IFS= read -r c; do
        [[ -n "$c" ]] && cands+=("$c")
    done < <(binary_asset_candidates)

    if (( ${#cands[@]} == 0 )); then
        err "不支持的架构：${arch_raw}"
        return 1
    fi

    # 逐个候选探测：应对 mips 浮点变体、loong64 ABI 等无法从 uname 判定的差异
    for c in "${cands[@]}"; do
        url=$(binary_asset_url "${c}.gz")
        if probe_asset "$url" || probe_asset "${MIRRORS[0]}/${url}"; then
            base="$c"
            break
        fi
    done
    if [[ -z "$base" ]]; then
        err "未找到匹配当前架构（${arch_raw}）的安装包"
        err "候选：${cands[*]}"
        err "amd64 已同时尝试 compatible 与普通变体，仍失败说明该版本未发布此架构资产"
        return 1
    fi

    url=$(binary_asset_url "${base}.gz")
    gz="${ROOT_DIR}/${base}.gz"

    pick_fastest_source "$url" || return 1
    info "开始下载 mihomo ${version}..."
    if ! download_file "$url" "$gz" "mihomo 二进制" probe_asset; then
        return 1
    fi
    if ! verify_checksum "$gz" "${base}.gz"; then
        rm -f -- "$gz"
        return 1
    fi
    if ! gzip -t "$gz" 2>/dev/null; then
        rm -f -- "$gz"
        err "压缩包完整性校验失败"
        return 1
    fi
    gunzip -f "$gz" || { err "解压失败"; return 1; }

    if [[ ! -f "${ROOT_DIR}/${base}" ]]; then
        err "解压后未找到可执行文件：${base}"
        return 1
    fi
    chmod +x "${ROOT_DIR}/${base}"
    if ! verify_binary "${ROOT_DIR}/${base}"; then
        rm -f -- "${ROOT_DIR}/${base}"
        return 1
    fi

    # 新内核必须能解析现有配置；若现有配置本身已不合法，则不阻断升级
    if [[ -f "$CONFIG_FILE" ]] && "$BIN_FILE" -t -f "$CONFIG_FILE" >/dev/null 2>&1; then
        if ! "${ROOT_DIR}/${base}" -t -f "$CONFIG_FILE" >/dev/null 2>&1; then
            err "新内核无法解析现有配置，已中止升级（当前版本未改动）"
            rm -f -- "${ROOT_DIR}/${base}"
            return 1
        fi
    fi

    # 停服务 → 备份 → 替换 → 启动 → 失败回滚
    bak="${BIN_FILE}.bak"
    cp -f -- "$BIN_FILE" "$bak" || { err "备份现有二进制失败"; return 1; }
    service_do stop >/dev/null 2>&1 || true
    if ! mv -f -- "${ROOT_DIR}/${base}" "$BIN_FILE"; then
        err "替换二进制失败"
        cp -f -- "$bak" "$BIN_FILE"
        service_do start >/dev/null 2>&1 || true
        return 1
    fi
    chmod +x "$BIN_FILE"

    # init 未知时无法托管服务，替换完直接结束
    if [[ "$init_sys" == "unknown" ]]; then
        warn "未识别 init 系统，跳过服务重启；请手动重启以生效"
        printf '%s\n' "$version" >"$VERSION_FILE"
        ok "更新完成，当前版本：${version}（$(channel_name "$channel")）"
        return 0
    fi

    if ! service_do start; then
        err "新版本启动失败，正在回滚"
        cp -f -- "$bak" "$BIN_FILE"
        chmod +x "$BIN_FILE"
        service_do start >/dev/null 2>&1 || true
        return 1
    fi
    sleep 1
    if ! wait_active 10; then
        err "新版本未正常运行，正在回滚"
        cp -f -- "$bak" "$BIN_FILE"
        chmod +x "$BIN_FILE"
        service_do start >/dev/null 2>&1 || true
        return 1
    fi

    printf '%s\n' "$version" >"$VERSION_FILE"
    ok "更新完成，当前版本：${version}（$(channel_name "$channel")）"
}

# 检查并更新 mihomo 内核
update_mihomo() {
    check_installation || return 1
    local current latest
    if [[ ! -f "$VERSION_FILE" ]]; then
        err "缺少版本记录文件：${VERSION_FILE}"
        return 1
    fi
    current=$(cat "$VERSION_FILE" 2>/dev/null || true)
    if [[ -z "$current" ]]; then
        err "版本记录为空，请重新安装"
        return 1
    fi

    channel=$(detect_channel "$current")

    info "当前版本：${current}（$(channel_name "$channel")），正在检查更新..."
    check_network
    if [[ "$channel" == "alpha" ]]; then
        latest=$(fetch_alpha_version) || { err "获取最新版本失败，请检查网络"; return 1; }
    else
        latest=$(fetch_latest_version) || { err "获取最新版本失败，请检查网络"; return 1; }
    fi

    if [[ "$current" == "$latest" ]]; then
        ok "当前已是最新版本，无需更新"
        return 0
    fi

    ok "检测到新版本：${latest}（当前 ${current}）"
    if ! confirm "是否升级到最新版本？(y/N):" "n"; then
        warn "已取消升级"
        return 0
    fi
    download_and_install "$channel"
}

# ---------- 版本切换 ----------
# 在正式版与测试版之间切换内核
switch_version() {
    check_installation || return 1
    local current choice=""
    if [[ ! -f "$VERSION_FILE" ]]; then
        err "缺少版本记录文件，请重新安装"
        return 1
    fi
    current=$(cat "$VERSION_FILE" 2>/dev/null || true)
    channel=$(detect_channel "$current")

    hreq
    printf '当前版本: %s（%s）\n' "$current" "$(channel_name "$channel")"
    hr
    printf '%s\n' "${COLOR_GREEN}1${COLOR_RESET}. 测试版 (Alpha，如 alpha-94b13ae)"
    printf '%s\n' "${COLOR_GREEN}2${COLOR_RESET}. 正式版 (Release，如 v1.19.32)"
    hr

    read_input choice "${COLOR_CYAN}请输入选项 (1/2): ${COLOR_RESET}"
    case "$choice" in
        1)
            if [[ "$channel" == "alpha" ]]; then
                warn "当前已是测试版，无需重复操作"
                return 0
            fi
            ok "准备切换到测试版"
            download_and_install alpha
            ;;
        2)
            if [[ "$channel" == "stable" ]]; then
                warn "当前已是正式版，无需重复操作"
                return 0
            fi
            ok "准备切换到正式版"
            download_and_install stable
            ;;
        *) warn "无效选项" ;;
    esac
}

# ---------- 卸载 ----------
# 卸载 mihomo 及其服务、面板与管理脚本
uninstall_mihomo() {
    # 卸载不依赖安装完整性：二进制丢失或安装中断后仍需能够清理残留
    local old="${ROOT_DIR}.old"
    if [[ ! -d "$ROOT_DIR" && ! -d "$old" && ! -f "$SERVICE_SYSTEMD" \
          && ! -f "$SERVICE_OPENRC" && ! -f "$SHELL_FILE" ]]; then
        warn "未检测到任何 mihomo 残留，无需卸载"
        return 0
    fi
    err "警告：卸载将删除 ${ROOT_DIR} 下全部内容（含配置文件与订阅）"
    if ! confirm "确认卸载 mihomo？(y/N):" "n"; then
        warn "已取消卸载"
        return 0
    fi
    # 订阅链接是高价数据：重装尚且保留，卸载也应给机会。默认 N——卸载是显式
    # destructive 操作，静默往外写文件比丢失更糟
    local keep_config="n" keep_path
    if [[ -f "$CONFIG_FILE" ]] && confirm "是否保留订阅配置文件？(y/N):" "n"; then
        keep_config="y"
    fi

    local failures=0
    if [[ "$init_sys" == "unknown" ]]; then
        warn "未识别 init 系统，跳过服务停止与自启处理"
    else
        info "正在停止服务..."
        service_do stop >/dev/null 2>&1 || failures=$((failures + 1))
        service_enable_toggle disable >/dev/null 2>&1 || true
    fi

    # 尽力而为，不因单步失败中断
    if [[ "$init_sys" == "systemd" ]]; then
        systemctl disable --now mihomo-logclean.timer >/dev/null 2>&1 || true
    fi
    rm -f -- "$LOGCLEAN_SERVICE" "$LOGCLEAN_TIMER" "$LOGCLEAN_PERIODIC" || true
    rm -f -- "$SERVICE_SYSTEMD" || failures=$((failures + 1))
    rm -f -- "$SERVICE_OPENRC" || failures=$((failures + 1))
    # 保留订阅配置：落在 ROOT_DIR 同级，不随 rm -rf 丢失；失败只警告，不阻断卸载
    if [[ "$keep_config" == "y" ]]; then
        keep_path="$(dirname "$ROOT_DIR")/mihomo-config.yaml.bak"
        if cp -f -- "$CONFIG_FILE" "$keep_path" 2>/dev/null; then
            chmod 600 "$keep_path" 2>/dev/null || true
            info "订阅配置已保留：${keep_path}（含面板密钥，注意保密）"
        else
            warn "订阅配置保留失败，仍将删除 ${ROOT_DIR}"
        fi
    fi
    # 防误删护栏：只删除至少两层的绝对路径。ROOT_DIR 目前是常量 /root/mihomo，
    # 若将来改为可配置，这道判断能挡住 /、/root、/usr 这类顶层目录
    if [[ "$ROOT_DIR" == /*/* ]]; then
        rm -rf -- "$ROOT_DIR" || failures=$((failures + 1))
    else
        err "拒绝删除危险路径：${ROOT_DIR}"
    fi
    # 重装时暂存的旧目录（成功安装后也会保留，可能含用户旧配置），随卸载一并清除
    if [[ -d "$old" ]]; then
        rm -rf -- "$old" || failures=$((failures + 1))
        info "已移除暂存目录：${old}"
    fi
    if [[ -f "$SYSCTL_FILE" ]]; then
        rm -f -- "$SYSCTL_FILE" || failures=$((failures + 1))
        warn "已移除 ${SYSCTL_FILE}（如需保留 IP 转发请自行恢复）"
    fi
    if [[ "$init_sys" == "systemd" ]]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    sleep 1
    if (( failures == 0 )) && [[ ! -d "$ROOT_DIR" && ! -d "$old" ]]; then
        ok "mihomo 卸载完成"
        printf '\n%s\n' "后续清理（如需）："
        printf '%s\n' "  rm -f ${SHELL_FILE} ${SHELL_FILE}.bak    # 删除本脚本及其备份"
        printf '%s\n' "  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY"
    else
        err "卸载未完全成功（失败步骤 ${failures} 个），请手动检查残留"
        return 1
    fi
}

# ---------- 脚本更新 ----------
# 下载校验并更新管理脚本自身
update_shell() {
    local tmp newver
    tmp=$(mktemp /tmp/mihomo-sh.XXXXXX)
    tmp_files+=("$tmp")

    check_network
    info "正在检查脚本更新..."
    if ! download_file "$SHELL_URL" "$tmp" "管理脚本"; then
        err "脚本下载失败，更新取消"
        return 1
    fi
    # 覆盖前必须校验，避免损坏现有脚本
    if ! bash -n "$tmp" 2>/dev/null; then
        err "下载的脚本语法校验失败，已取消更新"
        return 1
    fi
    # 语法过不代表能跑：冒烟执行 version 子命令。main() 的 version 分支在 require_root
    # 之前，不需要 root 与系统环境；顶级错误（CRLF 行尾、函数定义笔误、set 选项冲突等）
    # 在此拦截，避免把"能解析、一跑就崩"的脚本装进系统——与内核更新的启动回滚对称
    if ! bash "$tmp" version >/dev/null 2>&1; then
        err "下载的脚本冒烟测试失败，已取消更新"
        return 1
    fi
    # 同时兼容 SCRIPT_VERSION="x" 与 SCRIPT_VERSION='x'，避免上游改用单引号后解析为空
    newver=$(sed -n "s/^SCRIPT_VERSION=[\"']\(.*\)[\"']\$/\1/p" \
                  "$tmp" 2>/dev/null | head -n1 || true)
    if [[ -z "$newver" ]]; then
        err "无法解析新脚本版本号，已取消更新"
        return 1
    fi

    if [[ "$SCRIPT_VERSION" == "$newver" ]]; then
        ok "当前已是最新版本（${SCRIPT_VERSION}）"
        return 0
    fi
    ok "检测到新版本：${newver}（当前 ${SCRIPT_VERSION}）"
    if ! confirm "是否升级？(y/N):" "n"; then
        warn "已取消升级"
        return 0
    fi

    cp -f -- "$SHELL_FILE" "${SHELL_FILE}.bak" 2>/dev/null || true
    if ! atomic_install "$tmp" "$SHELL_FILE" 755; then
        err "写入失败，已保留原脚本"
        return 1
    fi
    # 刷新脚本头的 date 行，让状态面板「更新时间」反映本次升级日期。
    # 只替换 # 注释行，不碰 SCRIPT_VERSION，版本比对与后续升级不受影响
    sed -i "s/^#[[:space:]]*date[[:space:]]*:.*/# date   : $(date +%Y-%m-%d)/" \
        "$SHELL_FILE" 2>/dev/null || true
    hash -r 2>/dev/null || true
    ok "更新完成，当前版本：${newver}"
    info "如新版异常，回滚命令：cp -f ${SHELL_FILE}.bak ${SHELL_FILE}"
    info "3 秒后重新加载新脚本..."
    sleep 3
    # exec 替换进程镜像，不会再执行 EXIT trap，tmp_files 里的 $tmp 必须在这里删掉
    rm -f -- "$tmp" 2>/dev/null || true
    exec "$SHELL_FILE"
}

# ---------- 主菜单 ----------
# 等待用户按回车返回主菜单
pause_menu() {
    local _=""
    printf '\n%s' "${COLOR_CYAN}按回车返回主菜单${COLOR_RESET}"
    IFS= read -r _ || true
}

# 页头：交互菜单与 status 子命令共用。
# 脚本版本只在此处出现，show_status 面板不再重复展示
print_header() {
    hreq
    printf '%s\n' "${COLOR_CYAN}  mihomo 一键管理脚本  v${SCRIPT_VERSION}${COLOR_RESET}"
    kv "作者" "ChatGPT JK789"
    hr
}

# 渲染交互主菜单
menu() {
    local input=""
    while true; do
        clear 2>/dev/null || true
        print_header
        printf '%s\n' "${COLOR_CYAN}  使用说明${COLOR_RESET}"
        printf '%s\n' "    1. 重装 mihomo 会保留原有机场订阅"
        printf '%s\n' "    2. 机场订阅请通过配置管理添加，勿直接编辑配置"
        kv "子命令" "mihomo status / config / update 等，详见 mihomo help"
        hr
        printf '%s\n' "${COLOR_GREEN} 1${COLOR_RESET}. 安装 mihomo"
        printf '%s\n' "${COLOR_GREEN} 2${COLOR_RESET}. 更新 mihomo"
        printf '%s\n' "${COLOR_GREEN} 3${COLOR_RESET}. 卸载 mihomo"
        hr
        printf '%s\n' "${COLOR_GREEN} 4${COLOR_RESET}. 启动 mihomo"
        printf '%s\n' "${COLOR_GREEN} 5${COLOR_RESET}. 停止 mihomo"
        printf '%s\n' "${COLOR_GREEN} 6${COLOR_RESET}. 重启 mihomo"
        hr
        printf '%s\n' "${COLOR_GREEN} 7${COLOR_RESET}. 添加开机自启"
        printf '%s\n' "${COLOR_GREEN} 8${COLOR_RESET}. 关闭开机自启"
        printf '%s\n' "${COLOR_GREEN} 9${COLOR_RESET}. 切换软件版本"
        hr
        printf '%s\n' "${COLOR_GREEN}10${COLOR_RESET}. 配置管理"
        printf '%s\n' "${COLOR_GREEN}11${COLOR_RESET}. 查看日志"
        printf '%s\n' "${COLOR_GREEN}12${COLOR_RESET}. 更新脚本"
        printf '%s\n' "${COLOR_GREEN} 0${COLOR_RESET}. 退出脚本"
        hreq
        show_status
        hreq

        read_input input "${COLOR_CYAN}请输入上面选项: ${COLOR_RESET}"
        # 20/30 分别是 10（配置管理）/ 11（查看日志）的快捷别名，保留既有输入习惯
        case "$input" in
            1)  reinstall_mihomo       || true ;;
            2)  update_mihomo           || true ;;
            3)  uninstall_mihomo        || true ;;
            4)  service_action start    || true ;;
            5)  service_action stop     || true ;;
            6)  service_action restart  || true ;;
            7)  service_action enable   || true ;;
            8)  service_action disable  || true ;;
            9)  switch_version          || true ;;
            10|20) config_mihomo        || true ;;
            11|30) logs_mihomo          || true ;;
            12) update_shell            || true ;;
            0|q|Q|exit) exit 0 ;;
            *)  warn "无效选项，请重新选择"; continue ;;
        esac
        pause_menu
    done
}

# ---------- 命令行入口 ----------
# 输出命令行帮助
usage() {
    cat <<EOF
mihomo 一键管理脚本 v${SCRIPT_VERSION}

用法: mihomo [子命令]
      mihomo                 进入交互菜单

子命令:
  status              查看运行状态
  start               启动服务
  stop                停止服务
  restart             重启服务
  enable              设置开机自启
  disable             取消开机自启
  logs                实时查看日志
  config              配置管理（交互）
  secret [on|off|reset]  面板密钥：启用 / 禁用 / 重新生成
  panel [install|update]  管理面板：安装 / 更新 / 查看访问地址
  log-clean           立即清理日志（超过 1 MB 时压缩）
  update              更新 mihomo 内核
  switch              切换正式版 / 测试版
  install             安装 / 重装
  uninstall           卸载
  update-shell        更新本管理脚本
  version             显示脚本版本
  help                显示本帮助

说明:
  安装目录 ${ROOT_DIR}
  日志文件 ${LOG_FILE}
EOF
}

# 脚本入口
main() {
    # 帮助与版本不依赖系统环境，优先处理
    case "${1:-}" in
        -v|--version|version)   printf 'mihomo.sh v%s\n' "$SCRIPT_VERSION"; exit 0 ;;
        -h|--help|help)         usage; exit 0 ;;
    esac

    require_root          # 全局守卫：除帮助与版本外，一律要求 root
    detect_distro

    case "${1:-}" in
        "")                     menu ;;
        status)                 status_cmd ;;
        start)                  service_action start ;;
        stop)                   service_action stop ;;
        restart)                service_action restart ;;
        enable)                 service_action enable ;;
        disable)                service_action disable ;;
        logs)                   logs_mihomo ;;
        config)                 config_mihomo ;;
        secret)                 secret_cmd "${2:-}" ;;
        panel)                  panel_cmd "${2:-}" ;;
        log-clean)              log_clean ;;
        update)                 update_mihomo ;;
        switch)                 switch_version ;;
        install)                reinstall_mihomo ;;
        uninstall)              uninstall_mihomo ;;
        update-shell)           update_shell ;;
        *)                      err "未知子命令：$1"; usage; exit 1 ;;
    esac
}

main "$@"
