#!/usr/bin/env bash

# --------------------------------------------------
# name   : mihomo.sh
# desc   : mihomo 内核与订阅配置的交互式管理脚本
# date   : 2026-11-03 20:34:00
# author : ChatGPT JK789
# ver    : 2.3.0
# --------------------------------------------------

# 与 install.sh 共用 68 个同名函数，改动需同步两份；
# main / print_header 因入口职责不同各自实现，不参与同步。
# 维护规则：只改 beta 通道（仓库根目录），正式版（mihomo/）在 beta 验证通过后同步，
# 两者差异只允许是版本号与仓库路径（beta 路径含 _beta，正式版不含）。

# 必须用 bash 运行：dash/sh 不支持 pipefail、[[ ]] 与进程替换。
# 该守卫必须早于 set -Eeuo pipefail，否则在 sh 下会先抛出晦涩的 set 报错，
# 因此刻意使用单括号 [ ]。
if [ -z "${BASH_VERSION:-}" ]; then
    printf '%s\n' '错误：请使用 bash 运行本脚本' >&2
    exit 1
fi

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

# 声明当前脚本版本，必须与文件头 ver 完全一致。
readonly SCRIPT_VERSION="2.3.0"

# 收紧新建文件的默认权限：配置、日志和临时文件只允许属主访问。
umask 077

# 脚本元数据：页头显示的名称、作者与使用说明统一从这里取值。
readonly SCRIPT_NAME="mihomo 管理脚本"
readonly SCRIPT_AUTHOR="ChatGPT JK789"
readonly USAGE_NOTE_1="重装或更新 mihomo 时，原有机场订阅会自动保留"
readonly USAGE_NOTE_2="添加订阅请用「配置管理」，勿直接编辑配置文件"

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
# 早期版本曾用定时任务清理日志，此处仅为卸载时清理残留而保留。
readonly LOGCLEAN_SERVICE="/etc/systemd/system/mihomo-logclean.service"
readonly LOGCLEAN_TIMER="/etc/systemd/system/mihomo-logclean.timer"
readonly LOGCLEAN_PERIODIC="/etc/periodic/daily/mihomo-logclean"

readonly REPO_RAW="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main"
readonly SHELL_REPO="Abcd789JK/Tools"
readonly MIHOMO_RELEASE="https://github.com/MetaCubeX/mihomo/releases/download"
readonly MIHOMO_VERSION_URL="${MIHOMO_RELEASE}/Prerelease-Alpha/version.txt"
readonly MIHOMO_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
readonly MIHOMO_API_TAGS="https://api.github.com/repos/MetaCubeX/mihomo/releases/tags"
readonly CONFIG_URL="${REPO_RAW}/Config/mihomo.yaml"
readonly SHELL_URL="${REPO_RAW}/Script/mihomo_beta/mihomo.sh"
readonly INSTALL_URL="${REPO_RAW}/Script/mihomo_beta/install.sh"
readonly WEBUI_URL="https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip"

readonly MIRRORS=("https://gh-proxy.com" "https://github.boki.moe")
# 探测顺序以 GitHub 自身可达性为准，Google 仅作通用连通性兜底。
readonly PROBE_TARGETS=(
    "https://github.com/robots.txt"
    "https://www.gstatic.com/generate_204"
    "https://www.cloudflare.com/cdn-cgi/trace"
)

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
secret_enabled=1       # 是否启用面板密钥：1=启用 0=禁用（由 ask_secret 决定）
provider_total=0       # select_provider 统计到的订阅总数
provider_num=""        # select_provider 选中的订阅编号
provider_target=""     # select_provider 选中的 provider 键名（如 provider_02:）
tmp_files=()

# 颜色常量由 setup_colors 按终端能力初始化，默认全部为空字符串，
# 以保证严格模式下取值安全，且非交互环境下不输出 ANSI 控制字符。
COLOR_RESET=''
COLOR_RED=''
COLOR_GREEN=''
COLOR_YELLOW=''
COLOR_BLUE=''
COLOR_CYAN=''
COLOR_GRAY=''

# 根据终端能力和 NO_COLOR 初始化颜色。
# stdout 与 stderr 都必须是交互终端才启用，避免任一输出流被重定向时把转义符写入文件；
# NO_COLOR 只要存在（包括空值）就禁用；TERM 为 dumb 或缺失时同样禁用。
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

# 日志文件超过 1 MB 时就地截断，只保留最近 1000 行。
# 参数：$1 表示日志文件路径。
# 返回：0 表示已截断或无需截断，1 表示截断失败。
log_trim() {
    local log_path="$1"
    local size_limit=$((1024 * 1024))
    local keep_lines=1000
    local size
    local temp_file

    [[ -f "$log_path" ]] || return 0
    if ! size="$(wc -c <"$log_path" 2>/dev/null)"; then
        return 1
    fi
    (( size > size_limit )) || return 0

    # 同目录 mktemp 保证临时文件与目标处于同一文件系统，mv 才能原子替换。
    if ! temp_file="$(mktemp "${log_path}.XXXXXX" 2>/dev/null)"; then
        return 1
    fi
    if ! tail -n "$keep_lines" "$log_path" >"$temp_file" 2>/dev/null; then
        rm -f -- "$temp_file"
        return 1
    fi
    # 权限收紧失败不影响截断结果，日志仍可正常使用。
    chmod 640 "$temp_file" 2>/dev/null || true
    if ! mv -f -- "$temp_file" "$log_path" 2>/dev/null; then
        rm -f -- "$temp_file"
        return 1
    fi
    return 0
}

# 把一条带级别标签的日志写入日志文件。
# 参数：$1 表示级别标签，其余参数为日志内容。
# 返回：始终返回 0；日志落盘属于辅助诊断，失败不得中断业务主流程。
log_append() {
    local level="$1"
    local timestamp
    shift

    # 截断失败只影响日志体积，不阻断本次写入。
    if ! log_trim "$LOG_FILE"; then
        :
    fi
    if ! timestamp="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"; then
        timestamp='unknown-time'
    fi
    # 整组重定向到 /dev/null：日志目录不可写时由 Bash 报告的失败信息不应漏到终端。
    if ! { printf '%s %-5s %s\n' "$timestamp" "$level" "$*" >>"$LOG_FILE"; } 2>/dev/null; then
        return 0
    fi
    return 0
}

# 输出普通信息日志；日志统一写入 stderr，避免污染可供管道消费的 stdout。
log_info() {
    printf '%s[INFO]%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$*" >&2
    log_append 'INFO' "$*"
}

# 输出成功日志；只有操作确认完成并验证成功后才允许调用。
log_success() {
    printf '%s[ OK ]%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*" >&2
    log_append 'OK' "$*"
}

# 输出警告日志；用于非致命问题与风险提示。
log_warn() {
    printf '%s[WARN]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2
    log_append 'WARN' "$*"
}

# 输出错误日志；用于操作失败与错误原因。
log_error() {
    printf '%s[ERROR]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
    log_append 'ERROR' "$*"
}

# 输出调试日志；仅在 MIHOMO_DEBUG=1 时启用，避免默认刷屏。
log_debug() {
    if [[ "${MIHOMO_DEBUG:-0}" == '1' ]]; then
        printf '%s[DEBUG]%s %s\n' "$COLOR_GRAY" "$COLOR_RESET" "$*" >&2
    fi
}

# 输出错误并立即终止脚本；仅脚本入口层允许调用。
# 副作用：向 stderr 输出错误、写入日志文件并以状态码 1 退出。
die() {
    log_error "$*"
    log_error "详细日志：${LOG_FILE}"
    exit 1
}

# 分隔线固定为 50 个可见 ASCII 字符，长度不含 ANSI 颜色控制字符。
readonly HR="--------------------------------------------------"
readonly HR_EQ="=================================================="

# 打印单线分隔线。
hr() {
    printf '%s\n' "${COLOR_BLUE}${HR}${COLOR_RESET}"
}

# 打印双线分隔线。
hreq() {
    printf '%s\n' "${COLOR_BLUE}${HR_EQ}${COLOR_RESET}"
}

# 打印“标签: 值”行；标签统一青色，值由调用方按语义选择颜色。
kv() {
    local label="${1:?kv 缺少标签参数}"
    local value="${2-}"

    printf '  %s%s%s  %s\n' "$COLOR_CYAN" "$label" "$COLOR_RESET" "$value"
}

# 清理脚本运行期间登记的临时文件与临时目录。
# 只删除 tmp_files 中登记且由本脚本创建的对象，避免误删用户既有文件。
cleanup() {
    local temp_path

    for temp_path in "${tmp_files[@]}"; do
        [[ -n "$temp_path" && -e "$temp_path" ]] || continue
        rm -rf -- "$temp_path"
    done
    return 0
}

# 注册退出与中断清理；信号退出后仍由 EXIT Trap 统一回收本次创建的资源。
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# 检查指定命令是否可用。
command_exists() { command -v "$1" >/dev/null 2>&1; }

# 是否处于交互终端：curl | bash 等管道场景下为假，
# 各交互点据此取默认值，避免 read 遇 EOF 直接退出。
is_interactive() { [[ -t 0 ]]; }

# 原子替换文件：先在同一目录生成唯一临时文件写入内容，再 mv 覆盖目标。
# 参数：$1 表示源文件，$2 表示目标文件，$3 表示目标权限（默认 644）。
# 返回：成功返回 0，任一步失败返回 1；失败时不会留下临时文件。
# 副作用：覆盖目标文件，调用方必须自行完成备份与内容校验。
atomic_install() {
    local source_file="$1"
    local target_file="$2"
    local target_mode="${3:-644}"
    local stage_file

    # mktemp 保证临时文件与目标同目录（同一文件系统），mv 才是原子替换。
    if ! stage_file="$(mktemp "$(dirname "$target_file")/.$(basename "$target_file").XXXXXX" 2>/dev/null)"; then
        return 1
    fi
    if ! cp -f -- "$source_file" "$stage_file" 2>/dev/null; then
        rm -f -- "$stage_file"
        return 1
    fi
    if ! chmod "$target_mode" "$stage_file" 2>/dev/null; then
        rm -f -- "$stage_file"
        return 1
    fi
    if ! mv -f -- "$stage_file" "$target_file" 2>/dev/null; then
        rm -f -- "$stage_file"
        return 1
    fi
    return 0
}

# 安全读取：EOF(Ctrl+D) 时优雅退出，避免被 set -e 静默中断。
read_input() { # $1=变量名 $2=提示语
    local target_var="$1" prompt_text="$2" input_value=""
    if ! IFS= read -rp "$prompt_text" input_value; then
        printf '\n'
        log_error "输入已中断，退出"
        exit 130
    fi
    printf -v "$target_var" '%s' "$input_value"
}

# YAML 双引号值转义。
sanitize_yaml() {
    local v="$1"
    v=${v//$'\r'/}
    v=${v//$'\n'/ }
    v=${v//$'\t'/ }
    v=${v//\\/\\\\}
    v=${v//\"/\\\"}
    printf '%s' "$v"
}

# 交互确认：回车或 y/Y 为是，其余为否。
confirm() { # $1=提示语 $2=默认值
    local prompt="$1" def="${2:-n}" ans=""
    read_input ans "${COLOR_CYAN}${prompt}${COLOR_RESET} "
    ans=${ans:-$def}
    [[ "$ans" =~ ^[Yy] ]]
}

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
        log_warn "未识别的发行版：${distro}，将跳过依赖自动安装"
        log_warn "请自行确认已安装：curl 或 wget、unzip、gzip、jq、iproute2"
    fi

    detect_init
}

# init 系统识别：systemd 优先，其次 OpenRC；都识别不到时降级处理。
detect_init() {
    if [[ -d /run/systemd/system ]] \
        || { command_exists systemctl && [[ -d /etc/systemd/system ]]; }; then
        init_sys="systemd"
    elif command_exists rc-service && command_exists rc-update; then
        init_sys="openrc"
    else
        init_sys="unknown"
        log_warn "无法识别 init 系统，服务将不会自动配置"
    fi
}

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
            log_error "当前 init 系统不受支持"
            return 1
            ;;
    esac
}

# 按 init 系统设置或取消开机自启。
service_enable_toggle() { # $1=enable|disable
    case "$init_sys" in
        systemd)
            # 单元文件可能刚写入，先重载再操作，避免按旧定义处理
            systemctl daemon-reload >/dev/null 2>&1 || true
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

# 判断服务是否处于运行状态。
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

# 判断是否已设置开机自启。
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

# 有 curl 用 curl，没有则退回 wget：两种工具的参数差异在本层屏蔽，
# 上层只描述"要什么"，不关心"用什么"。
# curl / wget 都不自动安装——用户能把脚本取回来，说明至少有一个；
# 两个都缺失时本层不会主动安装，只会在下载环节失败（管理脚本不承担装依赖的职责，
# 依赖由 install.sh 负责）。
# 有 curl 时走 curl 分支，保留原有的重试与超时策略。

# 取回内容写到标准输出：$1=URL $2=连接超时 $3=总超时。
http_get() {
    if command_exists curl; then
        curl -fsSL --connect-timeout "$2" --max-time "$3" "$1" 2>/dev/null
    else
        wget -qO- --timeout="$3" -t 1 "$1" 2>/dev/null
    fi
}

# 下载到文件：$1=URL $2=输出文件 $3=总超时。
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

# HEAD 探测：只取状态码、不取响应体，用于大资产的存在性判断。
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

# 取前 N 字节并报告实际大小：用于测速，以及大资产存在性的兜底判断。
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

# 读取重定向目标地址：正式版版本号的兜底获取方式。
# wget 的响应头行首有两个空格，且重定时会附 " [following]" 后缀，都要剥掉。
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

# 探测地址是否可达（小文件用）
probe_url() {
    http_probe "$1" 8
}

# 探测直连是否可用，据此决定优先走直连还是镜像。
check_network() {
    local t
    for t in "${PROBE_TARGETS[@]}"; do
        if probe_url "$t"; then
            use_cdn=false
            log_info "网络环境正常，优先直连"
            return 0
        fi
    done
    use_cdn=true
    log_warn "直连探测失败，优先尝试镜像加速"
}

# 地址解析：直连优先 → 镜像兜底，并缓存可用前缀。
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

# 实测下载速度（KB/s），返回 0 表示不可用。
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

# 按实测速度选源：直连够快就走直连，否则与镜像比速度取最快。
# 解决"GitHub 直连可用但很慢"的场景 —— 仅判断可达性会误选慢速直连。
pick_fastest_source() { # $1=样本 URL（建议传真实待下载文件）
    local sample="$1" d s m best="" best_speed=0

    log_info "正在测速以选择下载源..."
    d=$(measure_speed "$sample")

    if (( d >= 512 )); then
        use_cdn=false
        url_prefix=""
        log_info "直连速度 ${d} KB/s，使用直连"
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
        log_error "直连与镜像均不可用，请检查网络"
        return 1
    fi

    if [[ -n "$best" ]]; then
        url_prefix="$best"
        use_cdn=true
        log_warn "直连 ${d} KB/s，${best} ${best_speed} KB/s，已切换镜像"
    else
        url_prefix=""
        use_cdn=false
        log_warn "直连 ${d} KB/s（较慢），镜像未测得更快，仍使用直连"
    fi
}

# 单次下载尝试，成功且非空才算通过。
fetch_to() { # $1=url $2=输出文件
    local url="$1" out="$2"
    http_download "$url" "$out" 900 || return 1
    [[ -s "$out" ]]
}

# 统一下载：.part 临时文件 + 成功才 mv，直连失败自动换镜像重试。
# $4=探测函数，大资产（二进制、面板包）必须传 probe_asset，避免全量 GET 探测拖慢或误判。
download_file() { # $1=url $2=目标路径 $3=描述 $4=探测函数
    local url="$1" dest="$2" desc="${3:-文件}" probe="${4:-probe_url}" resolved m

    # 登记 .part，中断时由 cleanup 一并清理，避免残留半截文件
    tmp_files+=("${dest}.part")

    if ! resolved=$(resolve_url "$url" "$probe"); then
        log_error "${desc}地址解析失败：${url}"
        return 1
    fi
    log_append 'DOWNLOAD' "${desc} <- ${resolved}"

    if fetch_to "$resolved" "${dest}.part"; then
        mv -f -- "${dest}.part" "$dest"
        return 0
    fi

    # 测速选中直连但实际拉不动时，改用镜像兜底
    for m in "${MIRRORS[@]}"; do
        [[ "$resolved" == "${m}/"* ]] && continue
        log_warn "${desc}直连失败，改用镜像 ${m} 重试"
        if fetch_to "${m}/${url}" "${dest}.part"; then
            url_prefix="$m"
            use_cdn=true
            mv -f -- "${dest}.part" "$dest"
            log_success "${desc}已通过镜像下载完成"
            return 0
        fi
    done

    rm -f -- "${dest}.part"
    log_error "${desc}下载失败"
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

# 识别系统架构，不支持的架构给出明确提示。
detect_arch() {
    local toks
    arch_raw=$(uname -m)
    toks=$(arch_candidates "$arch_raw" || true)
    arch=${toks%%$'\n'*}
    if [[ -z "$arch" ]]; then
        log_error "不支持的架构：${arch_raw}"
        log_error "支持：x86_64 i686 aarch64 armv7l s390x"
        return 1
    fi
}

# 版本号既可能是 1.19.2 这类语义化版本，也可能是 alpha-94b13ae 这类构建标识，
# 因此只校验"可作为文件名且不含路径/引号/尖括号"，避免误杀合法版本。
valid_version() {
    local v="$1"
    [[ -n "$v" && ${#v} -le 64 ]] || return 1
    grep -Eq '^[0-9A-Za-z][0-9A-Za-z._-]*$' <<<"$v"
}

# 版本通道判定：alpha-<哈希> 为测试版，纯数字为正式版。
detect_channel() { # $1=版本号
    case "$1" in
        *alpha*) printf 'alpha' ;;
        *)       printf 'stable' ;;
    esac
}

# 版本通道 → 中文名。
channel_name() { # $1=通道 → 中文名
    [[ "$1" == "alpha" ]] && printf '测试版' || printf '正式版'
}

# 获取测试版版本号。
fetch_alpha_version() { # --fail + 格式校验
    local v resolved
    if ! resolved=$(resolve_url "$MIHOMO_VERSION_URL"); then
        return 1
    fi
    v=$(http_get "$resolved" 10 30) || return 1
    v=$(printf '%s' "$v" | tr -d '[:space:]')
    if ! valid_version "$v"; then
        log_error "获取到的版本号格式异常：${v:-<空>}"
        return 1
    fi
    printf '%s' "$v"
}

# 正式版版本号：优先 api.github.com 的 tag_name（v1.19.32 → 1.19.32）；
# 该域名在部分网络下不可达且未认证请求有 60 次/时限流，故增加。
# releases/latest 的 302 Location 兜底（走 github.com 本体，镜像可代理）。
# 获取正式版版本号。
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

    log_info "API 不可用，改用 releases/latest 重定向获取版本号..."
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
        log_error "获取正式版版本号失败（API 与重定向均不可用，可能触发 GitHub 限流）"
        return 1
    fi
    printf '%s' "$tag"
}

# 二进制自检：ELF 魔数 + 可执行。
verify_binary() {
    local bin="$1" magic
    [[ -f "$bin" ]] || { log_error "文件不存在：${bin}"; return 1; }
    magic=$(head -c 4 "$bin" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    if [[ "$magic" != "7f454c46" ]]; then
        log_error "下载内容不是有效的 ELF 可执行文件（可能是错误页）"
        return 1
    fi
    if ! "$bin" -v >/dev/null 2>&1; then
        log_error "二进制无法在当前架构上运行"
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
        log_warn "未找到 SHA256 校验工具，跳过完整性校验"
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
            log_warn "无法获取 checksums.txt，跳过完整性校验"
            return 0
        fi
    else
        # 正式版：上游不发布 checksums.txt，直接用 GitHub API 的 asset digest
        expect=$(fetch_asset_digest "$name" 2>/dev/null || true)
        if [[ -z "$expect" ]]; then
            log_warn "无法获取官方校验值（GitHub API 的 asset digest 不可用），已跳过 SHA256 校验"
            return 0
        fi
    fi

    case "$tool" in
        sha256sum) actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}') ;;
        shasum)    actual=$(shasum -a 256 "$file" 2>/dev/null | awk '{print $1}') ;;
        openssl)   actual=$(openssl dgst -sha256 "$file" 2>/dev/null | awk '{print $NF}') ;;
    esac

    if [[ "$actual" != "$expect" ]]; then
        log_error "SHA256 校验失败：期望 ${expect}，实际 ${actual:-<空>}"
        return 1
    fi
    log_success "SHA256 校验通过"
}

# 取本机对外 IPv4/IPv6，跳过 TUN 与容器虚拟网卡。
# 注意：TUN 模式下 `ip route get 1.1.1.1` 的 src 会返回 198.18.x.x 这类虚拟地址。
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

# 校验 mihomo 是否已安装。
check_installation() {
    if [[ ! -f "$BIN_FILE" ]]; then
        log_error "未检测到 mihomo，请先执行安装"
        return 1
    fi
    return 0
}

# 打印安装、运行、自启与版本等状态面板。
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
    # 脚本版本不在此展示：菜单页头（print_header）已显示一次，
    # 此处再显示会与页头同屏重复
    kv "更新时间" "${COLOR_GREEN}${update_time}${COLOR_RESET}"
}

# 执行服务操作并打印结果。
service_action() { # $1=start|stop|restart|enable|disable
    local action="$1" text
    case "$action" in
        start)   text="启动"         ;;
        stop)    text="停止"         ;;
        restart) text="重启"         ;;
        enable)  text="设置开机自启" ;;
        disable) text="取消开机自启" ;;
        *) log_error "未知操作：${action}"; return 1 ;;
    esac

    check_installation || return 1

    if [[ "$action" == "enable" || "$action" == "disable" ]]; then
        if [[ "$action" == "enable" ]] && service_is_enabled; then
            log_warn "已${text}，无需重复操作"
            return 0
        fi
        if [[ "$action" == "disable" ]] && ! service_is_enabled; then
            log_warn "已${text}，无需重复操作"
            return 0
        fi
        log_info "正在${text}，请等待..."
        if service_enable_toggle "$action"; then
            log_success "${text}成功"
            return 0
        fi
        log_error "${text}失败"
        return 1
    fi

    if [[ "$action" == "start" ]] && service_is_active; then
        log_warn "已${text}，无需重复操作"
        return 0
    fi
    if [[ "$action" == "stop" ]] && ! service_is_active; then
        log_warn "已${text}，无需重复操作"
        return 0
    fi

    log_info "正在${text}，请等待..."
    sleep 1
    # 直接判断命令返回码，不再依赖 $?（set -e 下不可达）
    if ! service_do "$action"; then
        log_error "${text}失败"
        return 1
    fi
    if [[ "$action" == "stop" ]]; then
        if service_is_active; then
            log_error "${text}失败：进程仍在运行"
            return 1
        fi
        log_success "${text}成功"
        return 0
    fi
    if wait_active 10; then
        log_success "${text}成功"
    else
        log_error "${text}失败，请查看日志：journalctl -u mihomo -n 50"
        return 1
    fi
}

# 实时查看服务日志。
logs_mihomo() {
    case "$init_sys" in
        systemd)
            log_info "正在实时查看 mihomo 日志，按 Ctrl+C 退出"
            journalctl -u mihomo -o cat -f
            ;;
        openrc)
            log_error "OpenRC 暂不支持通过本脚本查看日志，请使用：logread | grep mihomo"
            return 1
            ;;
        *)
            log_error "当前 init 系统不受支持，无法查看日志"
            return 1
            ;;
    esac
}

# 日常上限由 log_append() 里的 log_trim 保证，这里只是手动兜底入口：
# 日志被其他程序写大、或需要立即压缩时使用。
log_clean() {
    local f rc cleaned=0
    for f in "$LOG_FILE" "$INSTALL_LOG"; do
        [[ -f "$f" ]] || continue
        rc=0
        log_trim "$f" || rc=$?
        case "$rc" in
            0) cleaned=1; log_success "已清理 ${f}：保留最近 1000 行" ;;
            2) log_error "清理 ${f} 失败" ;;
        esac
    done
    (( cleaned )) || log_info "日志均未超过 1 MB，无需清理"
}

# 面板鉴权：远程配置不含 secret，而 external-controller 默认监听 0.0.0.0:9090，
# 不加密钥等于把控制 API 无鉴权暴露到公网，因此是否启用由用户决定。
ask_secret() {
    # 非交互（管道安装）时无法询问，默认启用密钥，避免面板无鉴权暴露
    if ! is_interactive; then
        secret_enabled=1
        log_info "非交互环境，面板密钥默认启用"
        return 0
    fi
    if confirm "是否为面板启用密钥鉴权？(Y/n):" "y"; then
        secret_enabled=1
    else
        secret_enabled=0
        warn_secret_disabled
    fi
}

# 未启用密钥时的统一警告，安装、重置、禁用三处共用。
# 只提示监听范围，不拼访问地址：访问地址由状态面板的「面板地址」给出，
# 避免探测不到本机 IPv4 时把回环地址当成对外地址显示。
warn_secret_disabled() {
    local host port disp
    read -r host port <<<"$(controller_parts)"
    disp="${host:-0.0.0.0}"
    # 通配监听在配置里写作 ::，展示时补回方括号，避免拼成 :::9090
    [[ "$disp" == "::" ]] && disp="[::]"

    log_warn "⚠ 面板未启用密钥"
    case "$host" in
        ""|0.0.0.0|"::")
            log_warn "  监听 ${disp}:${port} 覆盖所有网卡，同网段与公网均可直连"
            ;;
        *)
            log_warn "  当前仅监听 ${disp}:${port}，实际仅本机可访问"
            ;;
    esac
    log_warn "  任何能访问该端口的人都可以修改你的配置。"
    log_warn "  建议用防火墙限制来源，或改用 SSH 隧道访问。"
}

# 移除配置中的 secret 行，用于禁用与重新生成。
strip_controller_secret() { # $1=配置文件
    local f="$1" tmp
    [[ -f "$f" ]] || return 1
    tmp=$(mktemp "${ROOT_DIR}/.secret.XXXXXX")
    tmp_files+=("$tmp")
    awk '!/^secret:/' "$f" >"$tmp"
    mv -f -- "$tmp" "$f"
    controller_secret=""
}

# 读取配置中的面板密钥，仅在非空时输出。
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

# 注入面板密钥：已有非空 secret 时保留用户设置，重复执行不会重复插入。
# $2=需要沿用旧密钥时传入（如重装保留订阅），避免用户已保存的密钥失效。
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

# 解析配置里的 external-controller，输出「监听主机 端口」两段。
# 主机已剥离 IPv6 方括号；配置缺失时按默认 0.0.0.0:9090 处理。
controller_parts() {
    local addr host port

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

    printf '%s %s' "${host:-0.0.0.0}" "$port"
}

# 从配置读取面板监听地址，拼成可访问的 URL
# 监听 0.0.0.0 / :: 表示所有网卡，对外应显示本机 IPv4，而不是 0.0.0.0
panel_url() {
    local host port
    read -r host port <<<"$(controller_parts)"

    case "$host" in
        ""|0.0.0.0|"::")
            [[ -n "$ipv4" ]] || detect_network_info
            host="${ipv4:-127.0.0.1}"
            ;;
    esac

    printf 'http://%s:%s/ui' "$host" "$port"
}

# 备份当前配置，固定覆盖同一份 .bak，不累积时间戳文件。
backup_config() {
    local bak="${CONFIG_FILE}.bak"
    [[ -f "$CONFIG_FILE" ]] || return 0
    if ! cp -f -- "$CONFIG_FILE" "$bak"; then
        log_error "配置备份失败，已中止写入"
        return 1
    fi
    chmod 600 "$bak"
    printf '%s' "$bak"
}

# 锚定 proxy-providers 段统计订阅数量。
count_providers() { # $1=文件，缺省为当前配置
    awk '
        /^proxy-providers:[[:space:]]*$/ { f = 1; next }
        f && /^[^[:space:]#]/            { f = 0 }
        f && /^[[:space:]]+provider_[0-9]+:/ { c++ }
        END { print c + 0 }
    ' "${1:-$CONFIG_FILE}"
}

# 计算下一个可用的订阅编号。
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

# 判断指定编号的机场订阅是否已存在。
provider_exists() { # $1=编号
    local num
    num=$(printf '%02d' "$1")
    grep -q "^  provider_${num}:" "$CONFIG_FILE"
}

# 段外是否存在 provider 编号引用（如 proxy-groups 的 use:）
# 存在时不可重编号，否则引用会失效。
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
            log_warn "已修正上游默认配置中的布尔值笔误（如 tcp-concurrent: tru → true）"
            ;;
        *)
            rm -f -- "$tmp"
            log_error "配置规范化失败"
            return 1
            ;;
    esac
    return 0
}

# 用 mihomo 自身校验配置，失败时打印原因。
config_test() { # $1=配置文件
    local out
    if ! out=$("$BIN_FILE" -t -f "$1" 2>&1); then
        printf '%s\n' "$out" | tail -n 20 >&2
        return 1
    fi
    return 0
}

# 校验 + 重启 + 失败回滚。
apply_config() { # $1=备份路径
    local bak="${1:-}"
    if ! config_test "$CONFIG_FILE"; then
        log_error "配置校验未通过"
        if [[ -n "$bak" && -f "$bak" ]]; then
            cp -f -- "$bak" "$CONFIG_FILE"
            log_error "已回滚到备份：${bak}"
        fi
        return 1
    fi

    # init 未知（如 runit/s6 系统）时无法托管服务，只保证配置有效。
    # 缺少此分支会让 service_do 返回 1，导致每次写配置都被误判为失败并回滚。
    if [[ "$init_sys" == "unknown" ]]; then
        log_warn "未识别 init 系统，跳过服务重启"
        log_warn "请手动重启使配置生效：${BIN_FILE} -d ${ROOT_DIR}"
        return 0
    fi

    if ! service_do restart; then
        log_error "服务重启失败"
        if [[ -n "$bak" && -f "$bak" ]]; then
            cp -f -- "$bak" "$CONFIG_FILE"
            log_error "已回滚到备份：${bak}"
            # 回滚后的重启属于失败补救：此处失败不再覆盖上面的原始错误，只由调用方返回失败。
            service_do restart >/dev/null 2>&1 || true
        fi
        return 1
    fi
    sleep 1
    if ! wait_active 10; then
        log_error "服务未处于运行状态"
        log_error "排查：journalctl -u mihomo -n 50"
        if [[ -n "$bak" && -f "$bak" ]]; then
            cp -f -- "$bak" "$CONFIG_FILE"
            log_error "已回滚到备份：${bak}"
            # 回滚后的重启属于失败补救：此处失败不再覆盖上面的原始错误，只由调用方返回失败。
            service_do restart >/dev/null 2>&1 || true
        fi
        return 1
    fi
    log_success "配置已生效，服务运行中"
}

# 落盘并应用新配置：写入 → 收紧权限 → 校验并重启，失败自动回滚。
commit_config() { # $1=新文件 $2=备份路径 $3=描述
    local new="$1" bak="$2" desc="$3"
    if ! mv -f -- "$new" "$CONFIG_FILE"; then
        log_error "${desc}失败：无法写入配置"
        return 1
    fi
    chmod 600 "$CONFIG_FILE"
    if ! apply_config "$bak"; then
        log_error "${desc}失败"
        return 1
    fi
    log_success "${desc}完成"
}

# 交互收集单个机场信息，输出 provider 配置块。
read_subscription() { # $1=序号
    local idx="$1" url name
    while true; do
        read_input url "${COLOR_CYAN}请输入第 ${idx} 个机场的订阅链接: ${COLOR_RESET}"
        if [[ -z "$url" ]]; then
            log_warn "订阅链接不能为空"
            continue
        fi
        if ! grep -Eq '^https?://[^[:space:]"]+$' <<<"$url"; then
            log_warn "订阅链接格式不正确（需以 http:// 或 https:// 开头，且不含空格与引号）"
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

# 把 provider 块写入 src，结果输出到 dst，带数量校验。
# 已有 proxy-providers 段时追加到段末，并把整段缩进重排为 2/4/6 的规范层级、
# 去掉段内空行，保证多次追加后条目始终连续且彼此对齐；
# 仅有 # 机场配置 标记时补全段头；两者皆无则追加到文件末尾。
# 三个分支都会顺带清掉 CR，避免 Windows 编辑过的配置把 \r 带进 YAML 值。
# 注意：必须接收文件路径而非 stdin —— 管道会让函数在子 shell 中执行，
# 导致 tmp_files 无法被 trap 清理。
inject_providers() { # $1=块文件 $2=源配置 $3=输出文件
    local block_file="$1" src="$2" dst="$3" before after

    if [[ ! -s "$block_file" ]]; then
        log_error "没有可写入的订阅内容"
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
        log_warn "配置中既无 proxy-providers 段也无标记，已追加到文件末尾"
    fi

    if ! grep -q '^proxy-providers:' "$dst"; then
        log_error "写入失败：结果中缺少 proxy-providers 段"
        return 1
    fi

    after=$(count_providers "$dst")
    if (( after <= before )); then
        log_error "写入失败：订阅数量未增加（${before} → ${after}）"
        return 1
    fi
    return 0
}

# 交互新增一个或多个机场订阅。
add_provider() {
    check_installation || return 1
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "配置文件不存在：${CONFIG_FILE}"
        return 1
    fi

    local bak block_file tmp idx ans block="" before
    bak=$(backup_config) || return 1
    before=$(count_providers)
    idx=$(next_provider_index)
    log_info "当前共有 ${before} 个订阅，新增编号从 $(printf '%02d' "$idx") 开始"

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
        log_error "新增订阅失败，现有配置未改动"
        return 1
    fi

    commit_config "$tmp" "$bak" "新增订阅"
}

# 交互修改指定订阅的链接与名称。
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
        log_warn "订阅链接格式不正确"
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
        log_error "写入失败：目标订阅在结果中丢失，已中止"
        return 1
    fi

    commit_config "$tmp" "$bak" "修改订阅 $(printf '%02d' "$provider_num")"
}

# 列出订阅并交互选择编号：结果写入全局 provider_total / provider_num / provider_target
select_provider() { # $1=动作词（修改/删除），用于提示语
    local num
    provider_total=$(count_providers)
    if (( provider_total == 0 )); then
        log_error "当前没有任何订阅可供$1"
        return 1
    fi

    log_info "当前共有 ${provider_total} 个订阅："
    list_providers
    printf '\n'

    while true; do
        read_input num "${COLOR_CYAN}请输入要$1的编号（如 01）: ${COLOR_RESET}"
        num=${num#provider_}
        num=${num%:}
        if ! grep -Eq '^[0-9]+$' <<<"$num"; then
            log_warn "请输入纯数字编号"
            continue
        fi
        if ! provider_exists "$num"; then
            log_warn "未找到编号为 $(printf '%02d' "$num") 的订阅"
            continue
        fi
        break
    done
    provider_num="$num"
    provider_target="provider_$(printf '%02d' "$num"):"
}

# 交互删除指定订阅，必要时重编号。
delete_provider() {
    check_installation || return 1
    local total
    total=$(count_providers)
    if (( total == 0 )); then
        log_error "当前没有任何订阅可供删除"
        return 1
    fi
    # 删除前校验，避免删空
    if (( total <= 1 )); then
        log_error "至少需要保留一个订阅，当前仅剩 ${total} 个，无法删除"
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
        log_warn "配置中存在 provider 编号引用（如 use:），跳过重编号"
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
        log_error "写入失败：结果中缺少 proxy-providers 段，已中止"
        return 1
    fi
    if [[ "$(count_providers "$tmp2")" -ne "$((total - 1))" ]]; then
        log_error "写入失败：订阅数量异常，已中止"
        return 1
    fi

    commit_config "$tmp2" "$bak" "删除订阅 $(printf '%02d' "$provider_num")"
    log_success "当前剩余 $(count_providers) 个订阅"
}

# 用默认配置覆盖当前配置并重建订阅。
reset_config() {
    check_installation || return 1
    if ! confirm "重置将用默认配置覆盖当前配置（已自动备份），确认？(y/N):" "n"; then
        log_warn "已取消重置"
        return 0
    fi
    ask_secret

    local bak idx=1 ans block="" block_file tmp merged
    bak=$(backup_config) || return 1
    [[ -n "$bak" ]] && log_success "原配置已备份：${bak}"

    check_network
    tmp=$(mktemp "${ROOT_DIR}/.config.XXXXXX")
    tmp_files+=("$tmp")
    # 先下到临时文件，校验后再替换，避免 -O 先截断
    if ! download_file "$CONFIG_URL" "$tmp" "默认配置"; then
        log_error "默认配置下载失败，现有配置未改动"
        return 1
    fi
    if [[ ! -s "$tmp" ]]; then
        log_error "下载的配置为空，现有配置未改动"
        return 1
    fi
    normalize_config "$tmp" || { log_error "配置规范化失败，现有配置未改动"; return 1; }

    # 先校验上游配置本身，不通过就中止，现有配置保持不动
    if ! config_test "$tmp"; then
        log_error "上游默认配置未通过 mihomo 校验，已中止（现有配置未改动）"
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
        log_error "订阅写入失败（现有配置未改动）"
        return 1
    fi

    # 面板密钥必须在校验前注入，避免把非法配置写进正式文件；
    # 未启用时不得调用注入函数，否则它会把空 secret 占位填上值
    if (( secret_enabled )); then
        ensure_controller_secret "$merged" >/dev/null
    else
        controller_secret=""
    fi

    if ! config_test "$merged"; then
        log_error "写入订阅后配置校验失败，已中止（现有配置未改动）"
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

# 非交互执行：启用 / 禁用 / 重新生成，全部走 commit_config 以复用校验与失败回滚。
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
            # 密钥只上屏、不落盘：kv 是纯 printf，log_success 会经 log_append 写入 /var/log/mihomo.log
            kv "面板密钥" "${COLOR_GREEN}${controller_secret}${COLOR_RESET}"
            ;;
        off)
            strip_controller_secret "$tmp"
            bak=$(backup_config) || return 1
            commit_config "$tmp" "$bak" "禁用面板密钥" || return 1
            warn_secret_disabled
            ;;
        *)
            log_error "未知操作：${action}（可选 on / off / reset）"
            return 1
            ;;
    esac
}

# 交互式管理面板密钥。
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
        *) log_warn "无效选项"; return 1 ;;
    esac
}

# 安装/更新管理面板：与安装流程共用 install_webui，重装即更新（幂等）
panel_install() {
    check_installation || return 1
    if ! command_exists unzip; then
        log_error "缺少 unzip，无法解压面板（Debian/Ubuntu: apt install unzip；Alpine: apk add unzip）"
        return 1
    fi
    install_webui
}

# 面板交互菜单：状态与地址一览，可触发安装/更新。
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
        *) log_warn "无效选项"; return 1 ;;
    esac
}

# 面板访问地址三行展示：本机 / 内网 / 公网提示。
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

# 下载并安装管理面板（zashboard），失败只告警不影响内核。
install_webui() {
    local zip="${ROOT_DIR}/gh-pages.zip"
    local tmpdir="${ROOT_DIR}/.webui-tmp"
    local -a dirs=()

    log_info "开始下载管理面板..."
    download_file "$WEBUI_URL" "$zip" "管理面板" probe_asset || return 1

    rm -rf -- "$tmpdir"
    if ! unzip -oq "$zip" -d "$tmpdir"; then
        rm -f -- "$zip"
        log_error "面板压缩包解压失败"
        return 1
    fi
    rm -f -- "$zip"

    shopt -s nullglob
    dirs=("${tmpdir}"/*-gh-pages)
    shopt -u nullglob

    if (( ${#dirs[@]} == 0 )); then
        rm -rf -- "$tmpdir"
        log_error "面板压缩包结构异常，未找到 gh-pages 目录"
        return 1
    fi

    rm -rf -- "${ROOT_DIR}/ui"
    if ! mv -f -- "${dirs[0]}" "${ROOT_DIR}/ui"; then
        rm -rf -- "$tmpdir"
        log_error "面板目录安装失败"
        return 1
    fi
    rm -rf -- "$tmpdir"
    chmod -R a+rX "${ROOT_DIR}/ui"
    log_success "管理面板已安装"
}

# 配置管理菜单入口。
# 配置管理菜单入口。与 install.sh 的 config_mihomo 同名不同义，
# 那边是「生成并写入默认配置」，这边只是二级菜单，故改名以免混淆。
config_menu() {
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
        *) log_warn "无效选项" ;;
    esac
}

# 重装流程：下载并调用 install.sh 完成覆盖安装。
# 注意：本函数与 install.sh 中的同名 install_mihomo 语义不同，故不复用该名字——
# 此处只负责"取回安装脚本并执行"，真正的安装编排在 install.sh 内部。
reinstall_mihomo() {
    check_network

    local old="${ROOT_DIR}.old" tmp
    if [[ -d "$ROOT_DIR" ]]; then
        log_warn "检测到已存在的安装：${ROOT_DIR}"
        if ! confirm "重新安装将重建程序目录（原目录暂存为 ${old}，安装成功后仍保留，需你确认后手动删除），确认？(y/N):" "n"; then
            log_warn "已取消安装"
            return 0
        fi
        # 先停服务，再把旧目录整体暂存，失败可恢复。
        # 服务单元文件不在此处删除：若后续下载或校验安装脚本失败，
        # 提前删除会让机器重启后彻底失去自启；由 install.sh 覆盖写入即可。
        service_do stop >/dev/null 2>&1 || true
        # 上次重装保留的旧目录不静默删除：里面可能有用户尚未取回的订阅
        if [[ -d "$old" ]]; then
            log_warn "检测到上次保留的旧安装目录：${old}"
            if ! confirm "删除该目录以继续？(y/N):" "n"; then
                log_error "已取消：请先取回 ${old}/config.yaml 或手动删除后重试"
                return 1
            fi
            rm -rf -- "$old" || { log_error "无法删除 ${old}，已取消"; return 1; }
        fi
        if ! mv -f -- "$ROOT_DIR" "$old"; then
            log_error "无法暂存旧安装目录，已取消"
            return 1
        fi
        log_info "旧安装已暂存：${old}"
    fi

    tmp=$(mktemp /tmp/mihomo-install.XXXXXX)
    tmp_files+=("$tmp")

    # 先下载再校验，最后才执行
    if ! download_file "$INSTALL_URL" "$tmp" "安装脚本"; then
        log_error "安装脚本下载失败"
        [[ -d "$old" && ! -d "$ROOT_DIR" ]] && mv -f -- "$old" "$ROOT_DIR" && log_success "已恢复原目录"
        return 1
    fi
    if ! bash -n "$tmp" 2>/dev/null; then
        log_error "安装脚本语法校验失败，已放弃执行"
        [[ -d "$old" && ! -d "$ROOT_DIR" ]] && mv -f -- "$old" "$ROOT_DIR" && log_success "已恢复原目录"
        return 1
    fi

    if bash "$tmp"; then
        rm -f -- "$tmp"
        # 旧目录保留：其中的 config.yaml 可能含用户尚未取回的订阅，交由用户确认后删除
        if [[ -d "$old" ]]; then
            log_info "旧安装目录已保留：${old}"
            log_info "确认新版本运行正常后，可手动删除：rm -rf -- ${old}"
        fi
        # 管理脚本可能已被覆盖，重新加载以避免继续执行旧文件残留
        if [[ -x "$SHELL_FILE" ]]; then
            log_success "安装完成，重新加载管理脚本..."
            exec "$SHELL_FILE"
        fi
    else
        log_error "安装流程未完成"
        # 安装器可能已建了半个 ROOT_DIR，先移除再恢复暂存的旧安装，
        # 否则机器处于"有服务单元、无可用二进制"的状态，重启后自启必然失败
        if [[ -d "$old" ]]; then
            if [[ -d "$ROOT_DIR" ]]; then
                # 清理半成品目录：失败时下面的 mv 会失败并走手动恢复分支，错误信息不会丢失。
                rm -rf -- "$ROOT_DIR" || true
            fi
            if mv -f -- "$old" "$ROOT_DIR"; then
                log_success "已恢复原安装：${ROOT_DIR}"
                log_info "请执行 ${BIN_FILE} -t -d ${ROOT_DIR} 验证后重启服务"
            else
                log_error "自动恢复失败，请手动执行：mv -f ${old} ${ROOT_DIR}"
            fi
        fi
        return 1
    fi
}

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

# 下载指定通道的内核并替换：校验 → 自检 → 停服替换 → 启动失败回滚。
# 下载并校验 mihomo 二进制，解压到安装目录。
# 依赖全局 channel / arch_raw；成功时写入全局 version 与 base（资产名），返回 0
fetch_mihomo_binary() {
    local -a cands=()
    local c url gz
    base=""

    if [[ "$channel" == "alpha" ]]; then
        version=$(fetch_alpha_version) || { log_error "获取测试版版本号失败，请检查网络"; return 1; }
    else
        version=$(fetch_latest_version) || { log_error "获取正式版版本号失败，请检查网络"; return 1; }
    fi
    log_info "获取软件版本：${version}（$(channel_name "$channel")）"

    while IFS= read -r c; do
        [[ -n "$c" ]] && cands+=("$c")
    done < <(binary_asset_candidates)

    if (( ${#cands[@]} == 0 )); then
        log_error "不支持的架构：${arch_raw}"
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
        log_error "未找到匹配当前架构（${arch_raw}）的安装包"
        log_error "候选：${cands[*]}"
        log_error "amd64 已同时尝试 compatible 与普通变体，仍失败说明该版本未发布此架构资产"
        return 1
    fi
    log_info "匹配资产：${base}.gz"

    url=$(binary_asset_url "${base}.gz")
    gz="${ROOT_DIR}/${base}.gz"

    pick_fastest_source "$url" || return 1
    log_info "开始下载 mihomo ${version} 二进制..."
    download_file "$url" "$gz" "mihomo 二进制" probe_asset || return 1

    if ! verify_checksum "$gz" "${base}.gz"; then
        rm -f -- "$gz"
        return 1
    fi
    if ! gzip -t "$gz" 2>/dev/null; then
        rm -f -- "$gz"
        log_error "压缩包完整性校验失败"
        return 1
    fi
    gunzip -f "$gz" || { log_error "解压失败"; return 1; }

    if [[ ! -f "${ROOT_DIR}/${base}" ]]; then
        log_error "解压后未找到可执行文件：${base}"
        return 1
    fi
    chmod +x "${ROOT_DIR}/${base}"
    if ! verify_binary "${ROOT_DIR}/${base}"; then
        rm -f -- "${ROOT_DIR}/${base}"
        return 1
    fi

    # 新内核必须能解析现有配置；现有配置本身不合法时不阻断升级
    if [[ -f "$CONFIG_FILE" ]] && "$BIN_FILE" -t -f "$CONFIG_FILE" >/dev/null 2>&1; then
        if ! "${ROOT_DIR}/${base}" -t -f "$CONFIG_FILE" >/dev/null 2>&1; then
            log_error "新内核无法解析现有配置，已中止（当前版本未改动）"
            rm -f -- "${ROOT_DIR}/${base}"
            return 1
        fi
    fi
    return 0
}

# 更新 mihomo 内核：下载校验 → 替换 → 启动 → 失败回滚。
download_and_install() { # $1=alpha|stable
    local bak

    channel="$1"
    detect_arch || return 1
    check_network
    fetch_mihomo_binary || return 1

    # 停服务 → 备份 → 替换 → 启动 → 失败回滚
    bak="${BIN_FILE}.bak"
    cp -f -- "$BIN_FILE" "$bak" || { log_error "备份现有二进制失败"; return 1; }
    service_do stop >/dev/null 2>&1 || true
    if ! mv -f -- "${ROOT_DIR}/${base}" "$BIN_FILE"; then
        log_error "替换二进制失败"
        cp -f -- "$bak" "$BIN_FILE"
        service_do start >/dev/null 2>&1 || true
        return 1
    fi
    chmod +x "$BIN_FILE"

    # init 未知时无法托管服务，替换完直接结束
    if [[ "$init_sys" == "unknown" ]]; then
        log_warn "未识别 init 系统，跳过服务重启；请手动重启以生效"
        printf '%s\n' "$version" >"$VERSION_FILE"
        log_success "更新完成，当前版本：${version}（$(channel_name "$channel")）"
        return 0
    fi

    if ! service_do start; then
        log_error "新版本启动失败，正在回滚"
        cp -f -- "$bak" "$BIN_FILE"
        chmod +x "$BIN_FILE"
        service_do start >/dev/null 2>&1 || true
        return 1
    fi
    sleep 1
    if ! wait_active 10; then
        log_error "新版本未正常运行，正在回滚"
        cp -f -- "$bak" "$BIN_FILE"
        chmod +x "$BIN_FILE"
        service_do start >/dev/null 2>&1 || true
        return 1
    fi

    printf '%s\n' "$version" >"$VERSION_FILE"
    log_success "更新完成，当前版本：${version}（$(channel_name "$channel")）"
}

# 检查并更新 mihomo 内核。
update_mihomo() {
    check_installation || return 1
    local current latest
    if [[ ! -f "$VERSION_FILE" ]]; then
        log_error "缺少版本记录文件：${VERSION_FILE}"
        return 1
    fi
    current=$(cat "$VERSION_FILE" 2>/dev/null || true)
    if [[ -z "$current" ]]; then
        log_error "版本记录为空，请重新安装"
        return 1
    fi

    channel=$(detect_channel "$current")

    log_info "当前版本：${current}（$(channel_name "$channel")），正在检查更新..."
    check_network
    if [[ "$channel" == "alpha" ]]; then
        latest=$(fetch_alpha_version) || { log_error "获取最新版本失败，请检查网络"; return 1; }
    else
        latest=$(fetch_latest_version) || { log_error "获取最新版本失败，请检查网络"; return 1; }
    fi

    if [[ "$current" == "$latest" ]]; then
        log_info "当前已是最新版本，无需更新"
        return 0
    fi

    log_info "检测到新版本：${latest}（当前 ${current}）"
    if ! confirm "是否升级到最新版本？(y/N):" "n"; then
        log_warn "已取消升级"
        return 0
    fi
    download_and_install "$channel"
}

# 在正式版与测试版之间切换内核。
switch_version() {
    check_installation || return 1
    local current choice=""
    if [[ ! -f "$VERSION_FILE" ]]; then
        log_error "缺少版本记录文件，请重新安装"
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
                log_warn "当前已是测试版，无需重复操作"
                return 0
            fi
            log_info "准备切换到测试版"
            download_and_install alpha
            ;;
        2)
            if [[ "$channel" == "stable" ]]; then
                log_warn "当前已是正式版，无需重复操作"
                return 0
            fi
            log_info "准备切换到正式版"
            download_and_install stable
            ;;
        *) log_warn "无效选项" ;;
    esac
}

# 卸载 mihomo 及其服务、面板与管理脚本。
uninstall_mihomo() {
    # 卸载不依赖安装完整性：二进制丢失或安装中断后仍需能够清理残留
    local old="${ROOT_DIR}.old"
    if [[ ! -d "$ROOT_DIR" && ! -d "$old" && ! -f "$SERVICE_SYSTEMD" \
          && ! -f "$SERVICE_OPENRC" && ! -f "$SHELL_FILE" ]]; then
        log_warn "未检测到任何 mihomo 残留，无需卸载"
        return 0
    fi
    log_error "警告：卸载将删除 ${ROOT_DIR} 下全部内容（含配置文件与订阅）"
    if ! confirm "确认卸载 mihomo？(y/N):" "n"; then
        log_warn "已取消卸载"
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
        log_warn "未识别 init 系统，跳过服务停止与自启处理"
    else
        log_info "正在停止服务..."
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
            log_info "订阅配置已保留：${keep_path}（含面板密钥，注意保密）"
        else
            log_warn "订阅配置保留失败，仍将删除 ${ROOT_DIR}"
        fi
    fi
    # 防误删护栏：只删除至少两层的绝对路径。ROOT_DIR 目前是常量 /root/mihomo，
    # 若将来改为可配置，这道判断能挡住 /、/root、/usr 这类顶层目录
    if [[ "$ROOT_DIR" == /*/* ]]; then
        rm -rf -- "$ROOT_DIR" || failures=$((failures + 1))
    else
        log_error "拒绝删除危险路径：${ROOT_DIR}"
    fi
    # 重装时暂存的旧目录（成功安装后也会保留，可能含用户旧配置），随卸载一并清除
    if [[ -d "$old" ]]; then
        rm -rf -- "$old" || failures=$((failures + 1))
        log_info "已移除暂存目录：${old}"
    fi
    if [[ -f "$SYSCTL_FILE" ]]; then
        rm -f -- "$SYSCTL_FILE" || failures=$((failures + 1))
        log_warn "已移除 ${SYSCTL_FILE}（如需保留 IP 转发请自行恢复）"
    fi
    if [[ "$init_sys" == "systemd" ]]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    sleep 1
    if (( failures == 0 )) && [[ ! -d "$ROOT_DIR" && ! -d "$old" ]]; then
        log_success "mihomo 卸载完成"
        printf '\n%s\n' "后续清理（如需）："
        printf '%s\n' "  rm -f ${SHELL_FILE} ${SHELL_FILE}.bak    # 删除本脚本及其备份"
        printf '%s\n' "  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY"
    else
        log_error "卸载未完全成功（失败步骤 ${failures} 个），请手动检查残留"
        return 1
    fi
}

# 判断字符串是否为稳定版三段式 SemVer。
# 参数：$1 表示待校验字符串。
# 返回：合法返回 0，否则返回 1。
is_semver() {
    [[ "${1:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

# 按 SemVer 优先级比较两个稳定版三段式版本号。
# 参数：$1 表示左版本，$2 表示右版本。
# 输出：左大于右输出 1，相等输出 0，小于输出 -1。
# 返回：任一版本不合法时返回非 0，避免把不可比较的值当作可升级。
compare_semver() {
    local left_version="$1"
    local right_version="$2"
    local -a left_parts
    local -a right_parts
    local index

    is_semver "$left_version" || return 1
    is_semver "$right_version" || return 1

    IFS='.' read -r -a left_parts <<<"$left_version"
    IFS='.' read -r -a right_parts <<<"$right_version"

    for index in 0 1 2; do
        if (( left_parts[index] > right_parts[index] )); then
            printf '1'
            return 0
        fi
        if (( left_parts[index] < right_parts[index] )); then
            printf '%s' '-1'
            return 0
        fi
    done
    printf '0'
}

# 从未执行的候选脚本中静态提取唯一的顶层 SCRIPT_VERSION 声明。
# 参数：$1 表示候选脚本路径。
# 输出：校验通过的 X.Y.Z 版本号。
# 返回：文件无效、声明缺失、重复或格式不符时返回非 0。
extract_script_version() {
    local candidate_file="${1:-}"
    local candidate_version

    if [[ -z "$candidate_file" || ! -f "$candidate_file" || -L "$candidate_file" ]]; then
        return 1
    fi

    # 赋值统计必须锚定行首：候选脚本会包含本函数的实现，其中 awk 脚本字面量
    # （$0 ~ /...SCRIPT_VERSION.../）若按"任意位置出现"统计，会把检查器自身算成额外赋值。
    if ! candidate_version="$(awk '
        /^[[:space:]]*(readonly[[:space:]]+|declare[[:space:]]+|export[[:space:]]+)?SCRIPT_VERSION[[:space:]]*\+?=/ {
            assignment_count++
        }
        /^readonly SCRIPT_VERSION=/ {
            declaration_count++
            if ($0 !~ /^readonly SCRIPT_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$/) {
                invalid_declaration = 1
                next
            }
            version = $0
            sub(/^readonly SCRIPT_VERSION="/, "", version)
            sub(/"$/, "", version)
        }
        END {
            if (assignment_count != 1 || declaration_count != 1 || invalid_declaration) {
                exit 1
            }
            print version
        }
    ' "$candidate_file")"; then
        return 1
    fi

    printf '%s\n' "$candidate_version"
}

# 静态读取脚本文件头中的 ver 字段，用于与 SCRIPT_VERSION 交叉校验。
# 参数：$1 表示脚本文件路径。
# 输出：ver 字段的原始值。
# 返回：文件无效或字段缺失时返回非 0。
extract_header_version() {
    local script_file="${1:-}"
    local header_version

    if [[ -z "$script_file" || ! -f "$script_file" ]]; then
        return 1
    fi
    if ! header_version="$(awk '
        /^# ver[[:space:]]*:/ {
            line = $0
            sub(/^# ver[[:space:]]*:[[:space:]]*/, "", line)
            sub(/[[:space:]]+$/, "", line)
            print line
            exit
        }
    ' "$script_file")"; then
        return 1
    fi
    [[ -n "$header_version" ]] || return 1
    printf '%s\n' "$header_version"
}

# 取得仓库默认分支当前的提交 SHA，用于把下载地址锁定到不可变制品。
# 参数：$1 表示 OWNER/REPO 形式的仓库标识。
# 输出：40 位十六进制提交 SHA。
# 返回：依赖缺失、网络失败、接口限流或响应非法时返回非 0。
fetch_pinned_commit() {
    local repository="${1:-}"
    local api_url
    local response
    local commit_sha

    if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        return 1
    fi
    command_exists curl || return 1
    command_exists jq || return 1

    api_url="https://api.github.com/repos/${repository}/commits/main"
    if ! response="$(http_get "$api_url" 10 30)"; then
        return 1
    fi
    if ! commit_sha="$(jq -er '.sha | strings | select(test("^[0-9a-f]{40}$"))' <<<"$response" 2>/dev/null)"; then
        return 1
    fi
    printf '%s\n' "$commit_sha"
}

# 更新管理脚本自身：锁定地址 → 下载 → 静态校验 → 版本比较 → 备份 → 原子替换 → 复核。
# 返回：0 表示已是最新、用户取消或更新成功；1 表示任一校验或写入失败。
# 副作用：可能覆盖 $SHELL_FILE，并在同目录保留一份 .bak 备份。
update_shell() {
    local work_dir
    local candidate_file
    local source_url
    local pinned_commit
    local remote_version
    local header_version
    local installed_version
    local comparison

    check_network
    log_info "正在检查管理脚本更新..."

    if ! command_exists jq; then
        log_error "缺少必要依赖：jq，无法校验远端版本，更新取消"
        return 1
    fi

    # 候选脚本放在本次创建的私有临时目录中，由 EXIT Trap 统一回收。
    if ! work_dir="$(mktemp -d /tmp/mihomo-update.XXXXXX 2>/dev/null)"; then
        log_error "无法创建临时目录，更新取消"
        return 1
    fi
    tmp_files+=("$work_dir")
    candidate_file="${work_dir}/mihomo.sh"

    # 优先锁定到具体提交，避免"先查版本、再下载浮动地址"造成制品与版本错位。
    if pinned_commit="$(fetch_pinned_commit "$SHELL_REPO")"; then
        source_url="https://raw.githubusercontent.com/${SHELL_REPO}/${pinned_commit}/Script/mihomo_beta/mihomo.sh"
        log_info "已锁定远端提交：${pinned_commit}"
    else
        source_url="$SHELL_URL"
        log_warn "无法锁定远端提交，改用分支地址下载，本次制品不可复现"
    fi

    if ! download_file "$source_url" "$candidate_file" "管理脚本"; then
        log_error "管理脚本下载失败，更新取消"
        return 1
    fi

    # 候选文件属于不可信输入：只做静态检查，绝不 source、eval 或执行它。
    if ! bash -n "$candidate_file" 2>/dev/null; then
        log_error "候选脚本语法校验失败，更新取消"
        return 1
    fi
    if ! remote_version="$(extract_script_version "$candidate_file")"; then
        log_error "候选脚本缺少唯一且格式正确的 SCRIPT_VERSION 声明，更新取消"
        return 1
    fi
    if ! header_version="$(extract_header_version "$candidate_file")"; then
        log_error "候选脚本缺少文件头 ver 字段，更新取消"
        return 1
    fi
    if [[ "$header_version" != "$remote_version" ]]; then
        log_error "候选脚本版本元数据不一致（头部 ${header_version}，常量 ${remote_version}），更新取消"
        return 1
    fi

    if ! comparison="$(compare_semver "$remote_version" "$SCRIPT_VERSION")"; then
        log_error "版本号无法比较（远端 ${remote_version}，本地 ${SCRIPT_VERSION}），更新取消"
        return 1
    fi
    case "$comparison" in
        0)
            log_info "当前已是最新版本（${SCRIPT_VERSION}）"
            return 0
            ;;
        -1)
            log_warn "远端版本 ${remote_version} 低于本地 ${SCRIPT_VERSION}，已阻止降级"
            return 1
            ;;
    esac

    log_info "发现新版本：${remote_version}（当前 ${SCRIPT_VERSION}）"
    if ! confirm "是否更新管理脚本？(y/N):" "n"; then
        log_warn "已取消更新"
        return 0
    fi

    if ! cp -f -- "$SHELL_FILE" "${SHELL_FILE}.bak" 2>/dev/null; then
        log_error "备份现有脚本失败，更新取消"
        return 1
    fi
    if ! atomic_install "$candidate_file" "$SHELL_FILE" 755; then
        log_error "写入 ${SHELL_FILE} 失败，已保留原脚本"
        return 1
    fi

    # 复核安装结果：只静态读取版本，不以 root 身份执行刚下载的脚本。
    if ! installed_version="$(extract_script_version "$SHELL_FILE")" \
        || [[ "$installed_version" != "$remote_version" ]]; then
        log_error "安装后版本复核失败，正在回滚"
        if cp -f -- "${SHELL_FILE}.bak" "$SHELL_FILE" 2>/dev/null; then
            log_warn "已回滚到原版本 ${SCRIPT_VERSION}"
        else
            log_error "回滚失败，请手动恢复：cp -f ${SHELL_FILE}.bak ${SHELL_FILE}"
        fi
        return 1
    fi

    hash -r 2>/dev/null || true
    log_success "管理脚本已更新：${SCRIPT_VERSION} -> ${remote_version}"
    log_info "新版本将在下次启动时生效，当前进程仍运行旧代码"
    log_info "如新版异常，回滚命令：cp -f ${SHELL_FILE}.bak ${SHELL_FILE}"
}

# 等待用户按回车返回主菜单。
pause_menu() {
    local _=""
    printf '\n%s' "${COLOR_CYAN}按回车返回主菜单${COLOR_RESET}"
    IFS= read -r _ || true
}

# 打印管理脚本页头与使用说明；顺序与 10.6.4 固定布局一致。
# 脚本版本只在此处出现，show_status 面板不再重复展示。
print_header() {
    hreq
    printf '  %s%s  v%s%s\n' \
        "$COLOR_CYAN" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$COLOR_RESET"
    printf '%s\n' "${COLOR_BLUE}  作者  ${SCRIPT_AUTHOR}${COLOR_RESET}"
    hr
    printf '%s\n' "${COLOR_CYAN}  使用说明${COLOR_RESET}"
    printf '    1. %s\n' "$USAGE_NOTE_1"
    printf '    2. %s\n' "$USAGE_NOTE_2"
    hr
}

# 渲染交互主菜单。
menu() {
    local input=""
    while true; do
        clear 2>/dev/null || true
        print_header
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
        printf '%s\n' "${COLOR_GREEN}12${COLOR_RESET}. 更新管理脚本（当前版本：${SCRIPT_VERSION}）"
        printf '%s\n' "${COLOR_GREEN} 0${COLOR_RESET}. 退出脚本"
        hreq
        show_status
        hreq

        read_input input "${COLOR_CYAN}请输入上面选项: ${COLOR_RESET}"
        # 20/30 分别是 10（配置管理）/ 11（查看日志）的快捷别名，保留既有输入习惯
        case "$input" in
            1)  reinstall_mihomo        || true ;;
            2)  update_mihomo           || true ;;
            3)  uninstall_mihomo        || true ;;
            4)  service_action start    || true ;;
            5)  service_action stop     || true ;;
            6)  service_action restart  || true ;;
            7)  service_action enable   || true ;;
            8)  service_action disable  || true ;;
            9)  switch_version          || true ;;
            10) config_menu             || true ;;
            11) logs_mihomo             || true ;;
            12) update_shell            || true ;;
            0|q|Q|exit) exit 0 ;;
            *)  log_warn "无效选项，请重新选择"; continue ;;
        esac
        pause_menu
    done
}

# 脚本入口。
# 管理脚本不提供命令行子命令：所有管理操作统一由交互菜单提供。
main() {
    # 颜色必须在任何日志、菜单和分隔线输出之前完成初始化。
    setup_colors

    if (( $# > 0 )); then
        log_error "本脚本不提供命令行子命令，请直接运行 ${0##*/} 进入交互菜单"
        exit 2
    fi

    detect_distro
    menu
}

main "$@"
