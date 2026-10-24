#!/usr/bin/env bash
# ---------- mihomo 一键安装脚本 ----------
# desc   : 安装 & 配置
# date   : 2026-10-24 11:01:48
# author : ChatGPT
# ver    : 1.5.7
# sync   : 与 mihomo.sh 共用 61 个同名函数，改动需同步两份

# 必须用 bash 运行：dash/sh 不支持 pipefail、[[ ]] 与进程替换，
# 提前拦截以给出明确提示，而不是抛出晦涩的 set 报错。
if [ -z "${BASH_VERSION:-}" ]; then
    echo "错误：请使用 bash 运行本脚本" >&2
    exit 1
fi

set -euo pipefail
umask 077

# ---------- 颜色 ----------
if [[ -t 1 ]]; then
    red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'
    blue=$'\033[34m'; cyan=$'\033[36m'; reset=$'\033[0m'
else
    red=''; green=''; yellow=''; blue=''; cyan=''; reset=''
fi

# ---------- 常量 ----------
SCRIPT_VERSION="1.5.7"

readonly ROOT_DIR="/root/mihomo"
readonly CONFIG_FILE="${ROOT_DIR}/config.yaml"
readonly BIN_FILE="${ROOT_DIR}/mihomo"
readonly VERSION_FILE="${ROOT_DIR}/version.txt"
readonly SHELL_FILE="/usr/bin/mihomo"
readonly SERVICE_SYSTEMD="/etc/systemd/system/mihomo.service"
readonly SERVICE_OPENRC="/etc/init.d/mihomo"
readonly SYSCTL_FILE="/etc/sysctl.d/99-ip-forward.conf"
readonly LOG_FILE="/var/log/mihomo-install.log"

readonly REPO_RAW="https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main"
readonly MIHOMO_RELEASE="https://github.com/MetaCubeX/mihomo/releases/download"
readonly MIHOMO_VERSION_URL="${MIHOMO_RELEASE}/Prerelease-Alpha/version.txt"
readonly MIHOMO_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
readonly MIHOMO_API_TAGS="https://api.github.com/repos/MetaCubeX/mihomo/releases/tags"
readonly CONFIG_URL="${REPO_RAW}/Config/mihomo.yaml"
readonly SERVICE_URL_SYSTEMD="${REPO_RAW}/Service/mihomo.service"
readonly SERVICE_URL_OPENRC="${REPO_RAW}/Service/mihomo.openrc"
readonly SHELL_URL="${REPO_RAW}/Script/mihomo_beta/mihomo.sh"
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
channel=""             # 空=未指定（交互询问，默认 stable）；stable=正式版 / alpha=测试版
ipv4=""
ipv6=""
use_cdn=false
url_prefix=""          # 空 = 直连；非空 = 已验证可用的镜像前缀
controller_secret=""   # 面板密钥，安装时本地生成并写入配置
SECRET_ENABLED=1       # 是否启用面板密钥：1=启用 0=禁用（由 ask_secret 决定）
TMP_FILES=()
SELF_INSTALLER=""      # 本次运行的安装脚本绝对路径，由 resolve_self_path 在 cd 之前填充

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

log() {
    log_trim "$LOG_FILE" || true
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" 2>/dev/null \
        >>"$LOG_FILE" 2>/dev/null || true
}
info() { printf '%s\n' "${cyan}$*${reset}"; log "INFO  $*"; }
ok()   { printf '%s\n' "${green}$*${reset}"; log "OK    $*"; }
warn() { printf '%s\n' "${yellow}$*${reset}" >&2; log "WARN  $*"; }
err()  { printf '%s\n' "${red}$*${reset}" >&2; log "ERROR $*"; }
die()  { err "$*"; err "详细日志：${LOG_FILE}"; exit 1; }

# ---------- 输出格式 ----------
# 统一交互规范：首尾信息块 + 40 字符分隔线 + 带序号的步骤标题。
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
STEP_TOTAL=10
STEP_CUR=0

# 打印 40 字符分隔线
hr() { printf '%s\n' "${blue}${HR}${reset}"; }

# 打印"标签: 值"行：标签统一青色，值按语义着色（成功绿/警告黄/错误红/默认色）
kv() { printf '  %s%s%s  %s\n' "$cyan" "$1" "$reset" "$2"; }

# 打印子命令说明行：命令绿色，说明默认色，命令列左对齐
cmd_row() { printf '    %s%-15s%s%s\n' "$green" "$1" "$reset" "$2"; }

# 打印带序号的步骤标题，序号自动递增
step() {
    STEP_CUR=$((STEP_CUR + 1))
    printf '\n%s\n' "${cyan}[${STEP_CUR}/${STEP_TOTAL}] $*${reset}"
}

# 打印安装信息头（脚本名、版本、目录、日志路径）
print_header() {
    printf '\n'
    printf '%s\n' "${blue}${HR_EQ}${reset}"
    printf '%s\n' "${cyan}  mihomo 一键安装脚本  v${SCRIPT_VERSION}${reset}"
    kv "安装目录" "$ROOT_DIR"
    kv "日志文件" "$LOG_FILE"
    printf '%s\n' "${blue}${HR_EQ}${reset}"
}

# ---------- 清理 ----------
cleanup() {
    local f
    for f in "${TMP_FILES[@]:-}"; do
        [[ -n "$f" && -e "$f" ]] && rm -rf -- "$f"
    done
    return 0   # 显式返回 0，避免 EXIT trap 污染脚本退出码
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------- 通用 ----------
command_exists() { command -v "$1" >/dev/null 2>&1; }

# 是否处于交互终端：curl | bash 等管道场景下为假，
# 各交互点据此取默认值，避免 read 遇 EOF 直接退出
is_interactive() { [[ -t 0 ]]; }

# 把 $0 绝对化并缓存到 SELF_INSTALLER。
# 必须在任何 cd 之前调用：prepare_dirs 会 cd 到 ROOT_DIR，之后相对路径 $0 就失效了
resolve_self_path() {
    local p="${0:-}" dir
    [[ -n "$p" && "$p" != -* ]] || return 0
    dir=$(cd -- "$(dirname -- "$p")" 2>/dev/null && pwd -P) || return 0
    [[ -n "$dir" ]] || return 0
    SELF_INSTALLER="${dir}/$(basename -- "$p")"
}

# 安装成功后删除本次运行的安装脚本。
# 任一守卫不满足就跳过——宁可保留也不误删（尤其不能删掉仓库源码或调用者的脚本）
remove_installer() {
    local self="$SELF_INSTALLER" name
    [[ -n "$self" ]] || return 0

    # 必须是普通文件：排除 /dev/fd/63（bash <(...)）、目录、软链
    [[ -f "$self" && ! -L "$self" ]] || return 0

    # 排除被 source / bash -c 调用时 $0 指向 shell 本身的情况
    name=$(basename -- "$self")
    case "$name" in
        bash|sh|dash|-bash) return 0 ;;
    esac

    # 内容指纹自证：确认这个文件确实是本安装脚本
    grep -q 'mihomo 一键安装脚本' "$self" 2>/dev/null || return 0
    grep -q '^SCRIPT_VERSION=' "$self" 2>/dev/null || return 0

    # 源码目录保护：同目录存在 mihomo.sh 说明是仓库检出，删了会丢源文件
    if [[ -f "$(dirname -- "$self")/mihomo.sh" ]]; then
        info "检测到源码目录，保留 ${name}"
        return 0
    fi

    # 删除失败不影响安装结果：只提示，不 die、不污染退出码
    if rm -f -- "$self" 2>/dev/null; then
        info "已删除安装脚本：${self}"
    else
        warn "安装脚本未能自动删除（权限或只读文件系统），可手动执行：rm -f ${self}"
    fi
    return 0
}

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

# 是/否确认，默认值由 $2 决定（y 或 n）
confirm() { # $1=提示语 $2=默认值
    local prompt="$1" def="${2:-n}" ans=""
    read_input ans "${cyan}${prompt}${reset} "
    ans=${ans:-$def}
    [[ "$ans" =~ ^[Yy] ]]
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

# 按包管理器完整定义安装参数，避免尾部拼接 -qq
pkg_install() {
    case "$pkg_mgr" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" ;;
        dnf)
            if command_exists dnf; then
                dnf install -y -q "$@"
            else
                yum install -y -q "$@"
            fi
            ;;
        pacman) pacman -S --noconfirm --needed "$@" ;;
        apk)    apk add --no-cache "$@" ;;
        zypper) zypper --non-interactive install "$@" ;;
        *) return 1 ;;
    esac
}

# ip 命令所属包名：Fedora/RHEL 系为 iproute，其余为 iproute2
pkg_iproute_name() {
    case "$pkg_mgr" in
        dnf) printf 'iproute' ;;
        *)   printf 'iproute2' ;;
    esac
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

# 下载器守卫：curl 与 wget 至少要有其一，否则后续下载全部无法进行。
# 用户能把脚本取回来就说明有其中一个，缺哪个按包管理器提示。
require_downloader() {
    if command_exists curl || command_exists wget; then
        return 0
    fi
    local hint=""
    case "${pkg_mgr:-}" in
        apt)    hint="apt-get install -y curl（或 wget）" ;;
        dnf)    hint="dnf install -y curl（或 wget）" ;;
        pacman) hint="pacman -S curl（或 wget）" ;;
        apk)    hint="apk add curl（或 wget）" ;;
        zypper) hint="zypper install -y curl（或 wget）" ;;
    esac
    if [[ -n "$hint" ]]; then
        die "未检测到 curl / wget，本脚本的下载功能依赖其中之一，请先执行：${hint}"
    fi
    die "未检测到 curl / wget，本脚本的下载功能依赖其中之一，请先安装后重试"
}

# 安装运行依赖，按实际需要裁剪（curl/wget 由 require_downloader 保证有其一，
# 都不自动安装；也不含 yq/git/nano）
install_dependencies() {
    local core=(unzip gzip jq ca-certificates iptables)
    local miss=() t

    if [[ "$pkg_mgr" == "none" ]]; then
        warn "跳过依赖安装（未识别的包管理器）"
    else
        info "正在安装依赖：${core[*]}"
        pkg_install "${core[@]}" || warn "部分依赖安装失败，后续步骤可能受影响"
        # 时区数据：openSUSE 包名为 timezone，缺失仅影响日志时间显示
        pkg_install tzdata >/dev/null 2>&1 || pkg_install timezone >/dev/null 2>&1 || true
        # ip 命令以功能探测为准：Alpine 自带的 busybox ip 不支持 -o 输出
        if ! ip -o -4 addr show scope global >/dev/null 2>&1; then
            pkg_install "$(pkg_iproute_name)" >/dev/null 2>&1 || true
        fi
    fi

    # 下载器已由 require_downloader 保证有其一，这里只校验其余实际用到的命令
    for t in unzip gzip jq; do
        command_exists "$t" || miss+=("$t")
    done
    if (( ${#miss[@]} )); then
        warn "缺少必要工具：${miss[*]}，请手动安装后重试"
    else
        ok "运行依赖已就绪"
    fi
}

# ---------- HTTP 入口 ----------
# 有 curl 用 curl，没有则退回 wget：两种工具的参数差异在本层屏蔽，
# 上层只描述"要什么"，不关心"用什么"。
# curl / wget 都不自动安装——用户能把脚本取回来，说明至少有一个；
# 两个都没有时由 require_downloader 提前中止并给出安装命令。
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
    TMP_FILES+=("${dest}.part")

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

# 获取本机 IPv4：优先 ip route get，退回 hostname -I
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

# ---------- IP 转发 ----------
sysctl_get() {
    sysctl -n "$1" 2>/dev/null || printf '0'
}

# 开启 IPv4/IPv6 转发，并写入 sysctl 持久化文件
check_ip_forward() {
    local pair key val pat persist_ok=true sysctl_dir

    # 持久化目录不可写时降级为仅本次生效，而不是直接崩溃。
    # 用目录可写性判断，避免像 `: >>"$SYSCTL_FILE"` 那样探测时反而创建空文件。
    sysctl_dir=$(dirname "$SYSCTL_FILE")
    if [[ ! -d "$sysctl_dir" || ! -w "$sysctl_dir" ]]; then
        persist_ok=false
        warn "无法写入 ${sysctl_dir}，IP 转发配置仅在本次运行生效"
    fi

    # 运行时值与持久化解耦：运行时已开启（如 Docker 宿主）只跳过 sysctl -w，
    # 持久化文件仍要写，否则卸载 docker 或重启后转发丢失
    for pair in "net.ipv4.ip_forward=1" "net.ipv6.conf.all.forwarding=1"; do
        key="${pair%%=*}"
        val="${pair##*=}"
        if [[ "$(sysctl_get "$key")" == "$val" ]]; then
            info "${key} 已开启"
        elif ! sysctl -w "${key}=${val}" >/dev/null 2>&1; then
            warn "设置 ${key} 失败（系统可能不支持 IPv6），已跳过"
            continue
        else
            ok "${key} 已开启"
        fi
        # 用 POSIX 字符类，避免 BusyBox grep 不识别 \s
        pat="^[[:space:]]*${key//./\\.}[[:space:]]*=[[:space:]]*${val}[[:space:]]*$"
        if [[ "$persist_ok" == true ]] && \
           ! grep -Eq "$pat" "$SYSCTL_FILE" 2>/dev/null; then
            printf '%s=%s\n' "$key" "$val" >>"$SYSCTL_FILE" 2>/dev/null || true
        fi
    done

    if [[ "$persist_ok" == true ]]; then
        sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    fi

    if [[ ! -e /dev/net/tun ]]; then
        warn "未检测到 /dev/net/tun，TUN 模式可能不可用"
    fi

    # 配置中的 tun.auto-redirect 依赖 nftables，缺失时启动会直接报错
    if ! command_exists nft || ! nft list ruleset >/dev/null 2>&1; then
        warn "未检测到可用的 nftables，若启动失败请将配置中的 tun.auto-redirect 改为 false"
    fi
}

# ---------- 服务管理 ----------
service_enable() {
    case "$init_sys" in
        systemd)
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable mihomo >/dev/null 2>&1
            ;;
        openrc)
            rc-update add mihomo default >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

# 重启服务（systemd / OpenRC）
service_restart() {
    case "$init_sys" in
        systemd)
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl restart mihomo
            ;;
        openrc)
            rc-service mihomo restart
            ;;
        *)
            err "当前 init 系统不受支持，无法重启服务"
            return 1
            ;;
    esac
}

# 停止服务，尽力而为：任何 init 下都返回 0，避免裸调用点中断流程
service_stop() {
    case "$init_sys" in
        systemd) systemctl stop mihomo >/dev/null 2>&1 || true ;;
        openrc)  rc-service mihomo stop >/dev/null 2>&1 || true ;;
        *)       return 0 ;;
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

# ---------- 版本与二进制 ----------
# 版本号既可能是 1.19.2 这类语义化版本，也可能是 alpha-94b13ae 这类构建标识，
# 因此只校验"可作为文件名且不含路径/引号/尖括号"，避免误杀合法版本
valid_version() {
    local v="$1"
    [[ -n "$v" && ${#v} -le 64 ]] || return 1
    grep -Eq '^[0-9A-Za-z][0-9A-Za-z._-]*$' <<<"$v"
}

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

# 安装二进制，带旧版本备份与失败回滚
install_binary() { # $1=新二进制路径
    local src="$1" bak="${BIN_FILE}.bak"
    if [[ -f "$BIN_FILE" ]]; then
        cp -f -- "$BIN_FILE" "$bak" || warn "备份旧二进制失败"
        service_stop
    fi
    if ! mv -f -- "$src" "$BIN_FILE"; then
        err "替换二进制失败"
        if [[ -f "$bak" ]]; then
            cp -f -- "$bak" "$BIN_FILE"
            chmod +x "$BIN_FILE"
        fi
        return 1
    fi
    chmod +x "$BIN_FILE"
    printf '%s\n' "$version" >"$VERSION_FILE"
}

# 下载、校验并安装 mihomo 内核
download_mihomo_binary() {
    local -a cands=()
    local base="" c url gz

    if [[ "$channel" == "alpha" ]]; then
        version=$(fetch_alpha_version) || die "获取测试版版本号失败，请检查网络"
    else
        version=$(fetch_latest_version) || die "获取正式版版本号失败，请检查网络"
    fi
    ok "获取软件版本：${version}（$(channel_name "$channel")）"

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
    ok "匹配资产：${base}.gz"

    url=$(binary_asset_url "${base}.gz")
    gz="${ROOT_DIR}/${base}.gz"

    pick_fastest_source "$url" || return 1
    info "开始下载 mihomo 二进制..."
    download_file "$url" "$gz" "mihomo 二进制" probe_asset || return 1

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

    # 覆盖安装时，新内核必须能解析现有配置；首次安装无 config.yaml，条件自然跳过
    if [[ -f "$CONFIG_FILE" ]] && "$BIN_FILE" -t -f "$CONFIG_FILE" >/dev/null 2>&1; then
        if ! "${ROOT_DIR}/${base}" -t -f "$CONFIG_FILE" >/dev/null 2>&1; then
            err "新内核无法解析现有配置，已中止安装（当前版本未改动）"
            rm -f -- "${ROOT_DIR}/${base}"
            return 1
        fi
    fi

    install_binary "${ROOT_DIR}/${base}"
    ok "mihomo 二进制已就绪"
}

# ---------- 服务文件 ----------
install_service() {
    local dest url
    case "$init_sys" in
        systemd)
            dest="$SERVICE_SYSTEMD"
            url="$SERVICE_URL_SYSTEMD"
            ;;
        openrc)
            dest="$SERVICE_OPENRC"
            url="$SERVICE_URL_OPENRC"
            ;;
        *)
            warn "无法识别 init 系统，跳过服务配置"
            warn "请手动创建服务，或直接运行：${BIN_FILE} -d ${ROOT_DIR}"
            return 0
            ;;
    esac

    # 先下载到同目录临时文件并校验，通过后才原子替换：
    # 上游文件异常时旧单元保持不动，也不会把坏文件留在系统里
    local tmp
    tmp=$(mktemp "$(dirname "$dest")/.svc.XXXXXX")
    TMP_FILES+=("$tmp")
    if ! download_file "$url" "$tmp" "系统服务文件"; then
        rm -f -- "$tmp"
        return 1
    fi

    case "$init_sys" in
        systemd)
            if ! grep -q '^\[Unit\]' "$tmp"; then
                err "systemd 单元文件格式异常，已保留原文件"
                rm -f -- "$tmp"
                return 1
            fi
            chmod 644 "$tmp"
            ;;
        openrc)
            if ! grep -q '^#!' "$tmp"; then
                err "OpenRC 服务文件格式异常，已保留原文件"
                rm -f -- "$tmp"
                return 1
            fi
            chmod 755 "$tmp"
            ;;
    esac

    if ! mv -f -- "$tmp" "$dest"; then
        err "写入 ${dest} 失败（原文件保持不变）"
        rm -f -- "$tmp"
        return 1
    fi

    ok "系统服务已安装：${dest}"
    service_enable || warn "设置开机自启失败"
}

# ---------- 管理面板 ----------
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

# ---------- 管理脚本 ----------
install_manager() {
    local tmp
    tmp=$(mktemp /tmp/mihomo-sh.XXXXXX)
    TMP_FILES+=("$tmp")

    info "开始下载管理脚本..."
    download_file "$SHELL_URL" "$tmp" "管理脚本" || return 1

    # 替换前必须校验，避免把错误页写成管理脚本
    if ! bash -n "$tmp" 2>/dev/null; then
        err "管理脚本语法校验失败，已放弃安装（现有脚本保持不变）"
        return 1
    fi
    if ! grep -q '^#!' "$tmp"; then
        err "管理脚本缺少 shebang，已放弃安装"
        return 1
    fi

    if ! atomic_install "$tmp" "$SHELL_FILE" 755; then
        err "写入 ${SHELL_FILE} 失败（现有脚本保持不变）"
        return 1
    fi
    hash -r 2>/dev/null || true
    ok "管理脚本已安装：${SHELL_FILE}"
}

# ---------- 配置 ----------
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

# 交互收集单个机场信息，输出 provider 配置块
read_subscription() { # $1=序号
    local idx="$1" url name
    while true; do
        read_input url "${cyan}请输入第 ${idx} 个机场的订阅链接: ${reset}"
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
    read_input name "${cyan}请输入机场名称（留空使用默认名）: ${reset}"
    [[ -z "$name" ]] && name="机场${idx}"

    printf '  provider_%02d:\n' "$idx"
    printf '    url: "%s"\n' "$(sanitize_yaml "$url")"
    printf '    type: http\n'
    printf '    interval: 86400\n'
    printf '    health-check: {enable: true, url: "https://www.gstatic.com/generate_204", interval: 300}\n'
    printf '    override:\n'
    printf '      additional-prefix: "[%s]"\n' "$(sanitize_yaml "$name")"
}

# 兼容层：修正上游默认配置中的布尔值笔误（如 tcp-concurrent: tru）
# 上游已于 2026-10-20 修复该行；保留此函数用于应对镜像/CDN 缓存旧文件的场景，
# 只匹配 4 种确定拼写，不会掩盖其他类型的配置错误（那些由 config_test 拦截）。
# 若确认镜像缓存均已刷新，可连同调用处一并删除。
normalize_config() { # $1=配置文件
    local f="$1" tmp rc=0
    tmp=$(mktemp "${ROOT_DIR}/.norm.XXXXXX")
    TMP_FILES+=("$tmp")

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

# 把 provider 块写入 src，结果输出到 dst，带数量校验
# 已有 proxy-providers 段时追加到段末，并把整段缩进重排为 2/4/6 的规范层级、
# 去掉段内空行，保证多次追加后条目始终连续且彼此对齐；
# 仅有 # 机场配置 标记时补全段头；两者皆无则追加到文件末尾。
# 三个分支都会顺带清掉 CR，避免 Windows 编辑过的配置把 \r 带进 YAML 值。
# 注意：必须接收文件路径而非 stdin —— 管道会让函数在子 shell 中执行，
# 导致 TMP_FILES 无法被 trap 清理。
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

# 校验 + 重启 + 失败回滚
apply_config() { # $1=备份路径
    local bak="${1:-}"
    if ! config_test "$CONFIG_FILE"; then
        err "配置校验未通过，已回滚"
        if [[ -n "$bak" && -f "$bak" ]]; then
            cp -f -- "$bak" "$CONFIG_FILE"
        fi
        return 1
    fi

    # init 未知（如 runit/s6 系统）时无法托管服务，只保证配置有效
    if [[ "$init_sys" == "unknown" ]]; then
        warn "未识别 init 系统，跳过服务重启"
        warn "请手动启动：${BIN_FILE} -d ${ROOT_DIR}"
        return 0
    fi

    if ! service_restart; then
        err "服务重启失败，已回滚配置"
        if [[ -n "$bak" && -f "$bak" ]]; then
            cp -f -- "$bak" "$CONFIG_FILE"
        fi
        service_restart >/dev/null 2>&1 || true
        return 1
    fi
    sleep 1
    if ! wait_active 10; then
        err "服务未处于运行状态，已回滚配置"
        err "排查：journalctl -u mihomo -n 50"
        if [[ -n "$bak" && -f "$bak" ]]; then
            cp -f -- "$bak" "$CONFIG_FILE"
        fi
        service_restart >/dev/null 2>&1 || true
        return 1
    fi
    ok "配置已生效，服务运行中"
}

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
    TMP_FILES+=("$tmp")
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

# 抽取现有配置的 proxy-providers 段体（不含段头行），供重装时保留订阅。
# 只取段体：inject_providers 的标记分支会自行补 proxy-providers: 段头，
# 这里若带上段头会与它形成重复键，导致 YAML 解析失败。
extract_providers() { # $1=配置文件；无该段时输出为空
    awk '
        /^proxy-providers:[[:space:]]*$/ { f = 1; next }
        f && /^[^[:space:]#]/            { exit }
        f                               { print }
    ' "$1"
}

# 交互收集机场订阅并写入配置文件；重装时保留现有订阅，不再要求重新输入
config_mihomo() {
    local bak idx=1 ans block="" block_file base merged keep=0 old_secret=""

    ask_secret

    bak=$(backup_config) || die "配置备份失败，已中止"
    [[ -n "$bak" ]] && ok "原配置已备份：${bak}"

    # 覆盖安装时保留现有机场订阅，避免重装一次就要重输全部链接
    if [[ -f "$CONFIG_FILE" ]]; then
        keep=$(count_providers "$CONFIG_FILE")
    fi

    info "开始下载默认配置文件..."
    base=$(mktemp "${ROOT_DIR}/.config.XXXXXX")
    TMP_FILES+=("$base")
    download_file "$CONFIG_URL" "$base" "默认配置" || die "配置文件下载失败"
    normalize_config "$base" || die "配置规范化失败"

    # 先校验上游配置本身：不通过就中止，现有配置保持不动
    if ! config_test "$base"; then
        err "上游默认配置未通过 mihomo 校验，已中止（现有配置未改动）"
        err "可自行准备配置文件放到 ${CONFIG_FILE} 后重启服务"
        return 1
    fi

    block_file=$(mktemp "${ROOT_DIR}/.block.XXXXXX")
    TMP_FILES+=("$block_file")

    if (( keep > 0 )); then
        if ! extract_providers "$CONFIG_FILE" >"$block_file" || [[ ! -s "$block_file" ]]; then
            err "抽取现有订阅失败（现有配置未改动）"
            return 1
        fi
        ok "已保留 ${keep} 个机场订阅"
        # 旧密钥一并沿用：extract_providers 只抽订阅段，secret 不在其中，
        # 不单独带过去的话每次重装都会重新生成，用户已保存的密钥随之失效
        old_secret=$(read_controller_secret "$CONFIG_FILE")
    else
        while true; do
            block+=$(read_subscription "$idx")
            block+=$'\n'
            idx=$((idx + 1))
            read_input ans "${cyan}是否继续添加订阅？回车继续，输入 n/N 结束: ${reset}"
            [[ "$ans" =~ ^[nN]$ ]] && break
        done
        printf '%s' "$block" >"$block_file"
    fi

    merged=$(mktemp "${ROOT_DIR}/.config.XXXXXX")
    TMP_FILES+=("$merged")
    if ! inject_providers "$block_file" "$base" "$merged"; then
        err "订阅写入失败（现有配置未改动）"
        return 1
    fi

    # 面板密钥必须在校验前注入，避免把非法配置写进正式文件；
    # 未启用时不得调用注入函数，否则它会把空 secret 占位填上值
    if (( SECRET_ENABLED )); then
        ensure_controller_secret "$merged" "$old_secret" >/dev/null
    else
        controller_secret=""
    fi

    # 写入订阅后再校验一次，仍不通过则完全不落地
    if ! config_test "$merged"; then
        err "写入订阅后配置校验失败，已中止（现有配置未改动）"
        return 1
    fi

    mv -f -- "$merged" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    apply_config "$bak" || return 1

    detect_network_info
    printf '\n'
    hr
    ok "配置完成：${CONFIG_FILE}"
    ok "mihomo 已启动并设置为开机自启"
    kv "面板地址" "${green}$(panel_url)${reset}"
    if [[ -n "$controller_secret" ]]; then
        kv "面板密钥" "${green}${controller_secret}${reset}"
        printf '%s\n' "  ${yellow}面板已开启鉴权，首次访问需填写该密钥${reset}"
    else
        kv "面板密钥" "${yellow}未启用（面板无鉴权）${reset}"
    fi
    printf '%s\n' "  ${yellow}注意：mixed-port 7890 不受密钥保护，建议用防火墙限制来源${reset}"
    hr
}

# 跳过订阅时仍要落地一份可用配置：
# 否则 $CONFIG_FILE 从未创建，服务无法启动，"systemctl restart mihomo" 必然失败。
install_default_config_only() {
    local base bak old_secret=""
    ask_secret

    bak=$(backup_config) || { err "配置备份失败，已中止"; return 1; }
    [[ -n "$bak" ]] && ok "原配置已备份：${bak}"

    # 沿用旧密钥：此路径不保留订阅，但密钥没有必要每次重装都变
    if [[ -f "$CONFIG_FILE" ]]; then
        old_secret=$(read_controller_secret "$CONFIG_FILE")
    fi

    info "正在下载默认配置文件..."
    base=$(mktemp "${ROOT_DIR}/.config.XXXXXX")
    TMP_FILES+=("$base")
    if ! download_file "$CONFIG_URL" "$base" "默认配置"; then
        err "默认配置下载失败"
        return 1
    fi
    if ! normalize_config "$base"; then
        err "配置规范化失败"
        return 1
    fi

    # 未启用密钥时不得调用注入函数，否则它会把空 secret 占位填上值
    if (( SECRET_ENABLED )); then
        ensure_controller_secret "$base" "$old_secret" >/dev/null
    else
        controller_secret=""
    fi

    if ! config_test "$base"; then
        err "默认配置未通过 mihomo 校验"
        return 1
    fi

    mv -f -- "$base" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    if [[ "$init_sys" == "unknown" ]]; then
        warn "未识别 init 系统，跳过服务启动"
        warn "请手动启动：${BIN_FILE} -d ${ROOT_DIR}"
        return 0
    fi

    if ! service_restart; then
        err "服务启动失败，请查看日志：journalctl -u mihomo -n 50"
        return 1
    fi
    if ! wait_active 10; then
        err "服务未处于运行状态，请查看日志：journalctl -u mihomo -n 50"
        return 1
    fi

    detect_network_info
    printf '\n'
    hr
    ok "已使用默认配置启动（尚未添加机场订阅）"
    kv "面板地址" "${green}$(panel_url)${reset}"
    if [[ -n "$controller_secret" ]]; then
        kv "面板密钥" "${green}${controller_secret}${reset}"
    else
        kv "面板密钥" "${yellow}未启用（面板无鉴权）${reset}"
    fi
    kv "下一步" "执行 ${green}mihomo${reset} → 配置管理 → 添加机场订阅"
    hr
    return 0
}

# ---------- 安装目录 ----------
# 准备安装目录，覆盖安装前先备份配置并确认
prepare_dirs() {
    if [[ -d "$ROOT_DIR" ]]; then
        warn "检测到已存在的安装目录：${ROOT_DIR}"
        local bak ans=""
        if ! is_interactive; then
            info "非交互环境，继续覆盖安装（现有机场订阅将保留）"
        else
            read_input ans "${cyan}继续将覆盖安装（订阅将保留，配置会先备份），是否继续？(y/N): ${reset}"
            case "$ans" in
                [Yy]*) ;;
                *) info "已取消安装"; exit 0 ;;
            esac
        fi

        bak=$(backup_config) || die "配置备份失败，已中止安装"
        [[ -n "$bak" ]] && ok "原配置已备份：${bak}"

        # 不在此处停服务、删二进制：下载与校验全部在旧内核运行时完成，
        # 真正的替换由 install_binary 负责（自带备份与失败回滚）。
        # 否则下载失败会把机器留在"无内核"状态。
    fi
    mkdir -p "$ROOT_DIR"
    cd "$ROOT_DIR" || die "无法进入 ${ROOT_DIR}"
}

# ---------- 主流程 ----------
install_mihomo() {
    step "检测系统环境"
    detect_distro
    require_downloader
    ok "系统: ${distro}    包管理器: ${pkg_mgr}    init: ${init_sys}"

    step "检测网络连通性"
    check_network

    step "安装运行依赖"
    install_dependencies

    step "检查 IP 转发"
    check_ip_forward

    step "检测系统架构"
    detect_arch
    ok "架构：${arch_raw} → ${arch}"

    step "下载 mihomo 内核"
    prepare_dirs
    download_mihomo_binary || die "mihomo 安装失败"

    step "安装系统服务"
    install_service || die "系统服务安装失败"

    step "安装管理面板"
    install_webui || warn "管理面板安装失败，不影响内核运行"

    step "安装管理脚本"
    install_manager || die "管理脚本安装失败"

    step "写入配置"
    if (( $(count_providers "$CONFIG_FILE" 2>/dev/null || printf '0') > 0 )); then
        info "检测到已有机场订阅，将保留并刷新默认配置"
        config_mihomo || die "配置写入失败，请检查日志 ${LOG_FILE}"
    else
        printf '%s\n' "  ${green}y${reset}  下载默认配置并添加机场订阅"
        printf '%s\n' "  ${green}n${reset}  仅安装默认配置，稍后再添加订阅"

        local ans="y"
        if is_interactive; then
            read_input ans "  请选择 [y/n，默认 y]: "
        else
            info "非交互环境，默认下载默认配置并添加订阅"
        fi
        ans=${ans:-y}
        case "$ans" in
            [Yy]*)
                config_mihomo || die "配置写入失败，请检查日志 ${LOG_FILE}"
                ;;
            *)
                warn "已跳过订阅配置，仅安装默认配置"
                if ! install_default_config_only; then
                    warn "默认配置安装失败，服务可能无法启动"
                    info "请手动准备配置放到 ${CONFIG_FILE} 后执行：systemctl restart mihomo"
                fi
                ;;
        esac
    fi

    printf '\n'
    hr
    ok "安装完成"
    kv "安装目录" "$ROOT_DIR"
    kv "日志文件" "$LOG_FILE"
    kv "面板地址" "${green}$(panel_url)${reset}"
    if [[ -n "$controller_secret" ]]; then
        kv "面板密钥" "${green}${controller_secret}${reset}"
    else
        kv "面板密钥" "${yellow}未启用（面板无鉴权）${reset}"
    fi
    hr
    printf '%s\n' "${cyan}  常用命令${reset}"
    cmd_row "mihomo"          "进入交互菜单"
    cmd_row "mihomo status"   "查看运行状态与面板地址"
    cmd_row "mihomo config"   "配置管理（机场订阅 / 面板密钥）"
    cmd_row "mihomo update"   "更新 mihomo 内核"
    cmd_row "mihomo switch"   "切换正式版 / 测试版"
    cmd_row "mihomo logs"     "查看实时日志"
    cmd_row "mihomo help"     "查看全部命令"
    hr

    # 只在成功横幅打印完之后删除自身：失败路径要保留脚本以便重试，
    # 且不能靠退出码判定——取消安装 / --help / Ctrl+D 也都是 exit 0
    remove_installer
}

# 输出命令行帮助
usage() {
    cat <<EOF
mihomo 一键安装脚本 v${SCRIPT_VERSION}

安装方式（任选其一，curl 与 wget 都可以，有其中一个即可）:

  curl:
    curl -fsSL -o install.sh ${REPO_RAW}/Script/mihomo_beta/install.sh
    bash install.sh

  wget:
    wget -qO install.sh ${REPO_RAW}/Script/mihomo_beta/install.sh
    bash install.sh

  国内网络慢可换 jsDelivr CDN:
    curl -fsSL -o install.sh https://cdn.jsdelivr.net/gh/Abcd789JK/Tools@main/Script/mihomo_beta/install.sh
    bash install.sh

  也可以直接管道执行（非交互，全部取默认值）:
    curl -fsSL ${REPO_RAW}/Script/mihomo_beta/install.sh | bash

  安装成功后会删除本次运行的 install.sh（源码目录内运行、或管道执行时不会删）。

用法: bash install.sh [选项]

选项:
  -h, --help           显示帮助
  -v, --version        显示版本
  --channel stable     安装正式版（如 v1.19.32）
  --channel alpha      安装测试版（如 alpha-94b13ae）

说明:
  不指定 --channel 时会在安装前询问，默认正式版。
  安装成功后自动删除本次运行的 install.sh，避免残留；安装失败时保留以便重试。
  支持 apt / dnf(yum) / pacman / apk / zypper 系发行版：
    Debian、Ubuntu 及其衍生版（Mint、Kali、Armbian 等）
    Fedora、RHEL、CentOS、Rocky、AlmaLinux、Amazon Linux
    Arch、Manjaro、EndeavourOS
    Alpine
    openSUSE / SLES
  其余发行版将跳过依赖安装，工具齐全时仍可继续。
  支持架构：x86_64 i686 aarch64 armv7l s390x
  需 root 权限。
  安装目录 ${ROOT_DIR}
  日志文件 ${LOG_FILE}
EOF
}

# 解析命令行参数
parse_args() {
    while (( $# )); do
        case "$1" in
            -h|--help)    usage; exit 0 ;;
            -v|--version) printf 'install.sh v%s\n' "$SCRIPT_VERSION"; exit 0 ;;
            --channel)
                [[ -n "${2:-}" ]] || die "--channel 缺少参数（stable / alpha）"
                channel="$2"
                shift 2
                ;;
            --channel=*)
                channel="${1#*=}"
                shift
                ;;
            *)
                err "未知参数：$1"
                usage
                exit 1
                ;;
        esac
    done

    case "$channel" in
        ""|stable|alpha) ;;
        *) die "无效的通道：${channel}（可选 stable / alpha）" ;;
    esac
}

# 未通过 --channel 指定且处于交互终端时，询问安装通道
choose_channel() {
    [[ -n "$channel" ]] && return 0

    if ! is_interactive; then
        channel="stable"
        return 0
    fi

    printf '\n'
    hr
    printf '%s\n' "  ${cyan}请选择要安装的版本通道${reset}"
    printf '%s\n' "  ${green}1${reset}. 正式版 Release（默认，如 v1.19.32）"
    printf '%s\n' "  ${green}2${reset}. 测试版 Alpha（如 alpha-94b13ae）"
    hr

    local ans=""
    read_input ans "  请输入选项 [1]: "
    ans=${ans//[[:space:]]/}
    case "$ans" in
        2|a|A|alpha|Alpha) channel="alpha" ;;
        *)                 channel="stable" ;;
    esac
    ok "已选择：$(channel_name "$channel")（${channel}）"
}

# 脚本入口
main() {
    parse_args "$@"
    resolve_self_path     # 必须在任何 cd 之前解析 $0，供安装成功后自删除使用
    require_root          # 全局守卫：除帮助与版本外，一律要求 root
    print_header
    choose_channel        # 未指定 --channel 时交互询问，默认正式版
    install_mihomo
}

main "$@"
