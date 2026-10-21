#!/bin/bash
# ---------------------------------
# script : mihomo 一键安装脚本
# desc   : 安装 & 配置
# date   : 2026-10-21 20:19:13
# author : ChatGPT
# ver    : 1.5.0
# ---------------------------------

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
sh_ver="1.5.0"

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
TMP_FILES=()

# ---------- 日志 ----------
# 日志：2>/dev/null 必须写在 >> 之前，否则重定向失败的错误会漏到终端
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" 2>/dev/null >>"$LOG_FILE" 2>/dev/null || true; }
info() { printf '%s\n' "${cyan}$*${reset}"; log "INFO  $*"; }
ok()   { printf '%s\n' "${green}$*${reset}"; log "OK    $*"; }
warn() { printf '%s\n' "${yellow}$*${reset}" >&2; log "WARN  $*"; }
err()  { printf '%s\n' "${red}$*${reset}" >&2; log "ERROR $*"; }
die()  { err "$*"; err "详细日志：${LOG_FILE}"; exit 1; }

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
have() { command -v "$1" >/dev/null 2>&1; }

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

# 安全读取：EOF(Ctrl+D) 时优雅退出，避免被 set -e 静默中断 [A-03]
read_input() { # $1=变量名 $2=提示语
    local __var="$1" __prompt="$2" __val=""
    if ! IFS= read -rp "$__prompt" __val; then
        printf '\n'
        err "输入已中断，退出"
        exit 130
    fi
    printf -v "$__var" '%s' "$__val"
}

# YAML 双引号值转义 [D-03]
sanitize_yaml() {
    local v="$1"
    v=${v//$'\r'/}
    v=${v//$'\n'/ }
    v=${v//$'\t'/ }
    v=${v//\\/\\\\}
    v=${v//\"/\\\"}
    printf '%s' "$v"
}

require_root() { # [B-02]
    if [[ "$(id -u)" -ne 0 ]]; then
        die "请以 root 身份运行本脚本"
    fi
}

# ---------- 系统检测 [F-04] ----------
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
        warn "请自行确认已安装：curl wget unzip gzip jq iproute2"
    fi

    detect_init
}

# init 系统识别：systemd 优先，其次 OpenRC；都识别不到时降级处理
detect_init() {
    if [[ -d /run/systemd/system ]] || { have systemctl && [[ -d /etc/systemd/system ]]; }; then
        init_sys="systemd"
    elif have rc-service && have rc-update; then
        init_sys="openrc"
    else
        init_sys="unknown"
        warn "无法识别 init 系统，服务将不会自动配置"
    fi
}

pkg_refresh() { # 仅刷新索引，不做全系统升级 [B-03]
    case "$pkg_mgr" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get update -qq ;;
        dnf)    if have dnf; then dnf makecache -q; else yum makecache -q; fi ;;
        pacman) pacman -Sy --noconfirm ;;
        apk)    apk update ;;
        zypper) zypper --non-interactive refresh ;;
        *) return 1 ;;
    esac
}

pkg_install() { # 按包管理器完整定义参数，避免尾部拼接 -qq [B-04]
    case "$pkg_mgr" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" ;;
        dnf)    if have dnf; then dnf install -y -q "$@"; else yum install -y -q "$@"; fi ;;
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

# 探测资产是否存在：优先用 HEAD 取状态码。
# 不用 --range 打头，是因为部分镜像/CDN 忽略 Range 而直接返回整包，
# 20MB+ 的响应会在 --max-time 内超时，反而把存在的资产误判为不存在。
probe_asset() {
    local url="$1" code
    code=$(curl -sSL -I -o /dev/null -w '%{http_code}' \
               --connect-timeout 5 --max-time 12 "$url" 2>/dev/null || true)
    if [[ "$code" == "200" || "$code" == "206" ]]; then
        return 0
    fi
    # 部分镜像不支持 HEAD，退回范围请求兜底
    curl -fsSL -o /dev/null --connect-timeout 5 --max-time 15 --range 0-0 "$url" 2>/dev/null
}

# 引导阶段先确保 curl/wget 存在，否则后续网络探测无法进行 [B-01]
ensure_bootstrap_tools() {
    local missing=()
    have curl || missing+=(curl)
    have wget || missing+=(wget)
    if (( ${#missing[@]} == 0 )); then
        return 0
    fi
    info "缺少基础工具：${missing[*]}，正在安装..."
    pkg_refresh || warn "刷新软件源失败，继续尝试安装"
    if ! pkg_install "${missing[@]}"; then
        die "基础工具安装失败，请手动安装 ${missing[*]} 后重试"
    fi
    have curl || die "curl 安装失败，无法继续"
}

install_dependencies() { # [B-05] 按实际依赖裁剪，移除 yq/git/nano
    local core=(curl wget unzip gzip jq ca-certificates iptables)
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

    for t in curl wget unzip gzip jq; do
        have "$t" || miss+=("$t")
    done
    if (( ${#miss[@]} )); then
        warn "缺少必要工具：${miss[*]}，请手动安装后重试"
    fi
}

# ---------- 网络探测 [C-01] ----------
probe_url() {
    curl -fsS -o /dev/null --connect-timeout 3 --max-time 8 "$1" 2>/dev/null
}

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

# 地址解析：直连优先 → 镜像兜底，并缓存可用前缀 [C-02][C-03]
resolve_url() {
    local url="$1" cand m
    if [[ -n "$url_prefix" ]]; then
        cand="${url_prefix}/${url}"
        if probe_url "$cand"; then
            printf '%s' "$cand"
            return 0
        fi
        url_prefix=""
    fi
    if [[ "$use_cdn" == true ]]; then
        for m in "${MIRRORS[@]}"; do
            cand="${m}/${url}"
            if probe_url "$cand"; then
                url_prefix="$m"
                printf '%s' "$cand"
                return 0
            fi
        done
    fi
    if probe_url "$url"; then
        printf '%s' "$url"
        return 0
    fi
    for m in "${MIRRORS[@]}"; do
        cand="${m}/${url}"
        if probe_url "$cand"; then
            url_prefix="$m"
            printf '%s' "$cand"
            return 0
        fi
    done
    return 1
}

# 实测下载速度（KB/s），返回 0 表示不可用
# 用 --range 限取 1MB、--max-time 4 兜底，避免为测速拉完整文件
measure_speed() { # $1=url
    local url="$1" res size time
    res=$(curl -fsSL --connect-timeout 4 --max-time 4 --range 0-1048575 \
              -o /dev/null -w '%{size_download} %{time_total}' "$url" 2>/dev/null || true)
    [[ -n "$res" ]] || { printf '0'; return 0; }
    size=${res%% *}
    time=${res##* }
    awk -v s="${size:-0}" -v t="${time:-0}" \
        'BEGIN { if (t + 0 <= 0) { print 0; exit } printf "%d", (s + 0) / 1024 / t }'
}

# 按实测速度选源：直连够快就走直连，否则与镜像比速度取最快 [C-09]
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
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 900 \
              -sS -o "$out" "$url"; then
        return 1
    fi
    [[ -s "$out" ]]
}

# 统一下载：.part 临时文件 + 成功才 mv，直连失败自动换镜像重试 [C-04][C-10]
download_file() { # $1=url $2=目标路径 $3=描述
    local url="$1" dest="$2" desc="${3:-文件}" resolved m

    # 登记 .part，中断时由 cleanup 一并清理，避免残留半截文件
    TMP_FILES+=("${dest}.part")

    if ! resolved=$(resolve_url "$url"); then
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

# 获取本机 IPv4：优先 ip route get，退回 hostname -I [B-06]
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
# 依据官方 release 资产命名：
#   linux-{amd64,386,arm64,armv5,armv6,armv7,s390x,riscv64,loong64,ppc64le,mips,mipsle,mips64,mips64le}
# armv8l 是 32 位用户空间的 ARMv8，仍应取 armv7 资产。
# mips 系按 softfloat 优先探测，官方对无 FPU 的设备单独出包。
arch_candidates() {
    case "$1" in
        x86_64|amd64)          printf 'amd64\n' ;;
        i386|i486|i586|i686)   printf '386\n' ;;
        aarch64|arm64)         printf 'arm64\n' ;;
        armv8l|armv7l|armv7)   printf 'armv7\n' ;;
        armv6l)                printf 'armv6\n' ;;
        armv5tel|armv5l|armv5) printf 'armv5\n' ;;
        s390x)                 printf 's390x\n' ;;
        riscv64)               printf 'riscv64\n' ;;
        loongarch64|loong64)   printf 'loong64\n' ;;
        ppc64le)               printf 'ppc64le\n' ;;
        mips)                  printf 'mips-softfloat\nmips\n' ;;
        mipsel)                printf 'mipsle-softfloat\nmipsle\n' ;;
        mips64)                printf 'mips64\n' ;;
        mips64el)              printf 'mips64le\n' ;;
        *) return 1 ;;
    esac
}

detect_arch() {
    local toks
    arch_raw=$(uname -m)
    toks=$(arch_candidates "$arch_raw" || true)
    arch=${toks%%$'\n'*}
    if [[ -z "$arch" ]]; then
        err "不支持的架构：${arch_raw}"
        err "支持：x86_64 i686 aarch64 armv7l armv6l armv5tel riscv64 ppc64le s390x loongarch64 mips(el) mips64(el)"
        return 1
    fi
}

# ---------- IP 转发 ----------
sysctl_get() {
    sysctl -n "$1" 2>/dev/null || printf '0'
}

check_ip_forward() {
    local pair key val persist_ok=true sysctl_dir

    # 持久化目录不可写时降级为仅本次生效，而不是直接崩溃。
    # 用目录可写性判断，避免像 `: >>"$SYSCTL_FILE"` 那样探测时反而创建空文件。
    sysctl_dir=$(dirname "$SYSCTL_FILE")
    if [[ ! -d "$sysctl_dir" || ! -w "$sysctl_dir" ]]; then
        persist_ok=false
        warn "无法写入 ${sysctl_dir}，IP 转发配置仅在本次运行生效"
    fi

    for pair in "net.ipv4.ip_forward=1" "net.ipv6.conf.all.forwarding=1"; do
        key="${pair%%=*}"
        val="${pair##*=}"
        if [[ "$(sysctl_get "$key")" == "$val" ]]; then
            warn "${key} 已开启，跳过"
            continue
        fi
        if ! sysctl -w "${key}=${val}" >/dev/null 2>&1; then
            warn "设置 ${key} 失败（系统可能不支持 IPv6），已跳过"
            continue
        fi
        # 用 POSIX 字符类，避免 BusyBox grep 不识别 \s
        if [[ "$persist_ok" == true ]] && \
           ! grep -Eq "^[[:space:]]*${key//./\\.}[[:space:]]*=[[:space:]]*${val}[[:space:]]*$" "$SYSCTL_FILE" 2>/dev/null; then
            printf '%s=%s\n' "$key" "$val" >>"$SYSCTL_FILE" 2>/dev/null || true
        fi
        ok "${key} 已开启"
    done

    if [[ "$persist_ok" == true ]]; then
        sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    fi

    if [[ ! -e /dev/net/tun ]]; then
        warn "未检测到 /dev/net/tun，TUN 模式可能不可用"
    fi

    # 配置中的 tun.auto-redirect 依赖 nftables，缺失时启动会直接报错
    if ! have nft || ! nft list ruleset >/dev/null 2>&1; then
        warn "未检测到可用的 nftables，若启动失败请将配置中的 tun.auto-redirect 改为 false"
    fi
}

# ---------- 服务管理 [F-04] ----------
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

service_stop() { # 尽力而为，任何 init 都返回 0（裸调用点不应中断流程）
    case "$init_sys" in
        systemd) systemctl stop mihomo >/dev/null 2>&1 || true ;;
        openrc)  rc-service mihomo stop >/dev/null 2>&1 || true ;;
        *)       return 0 ;;
    esac
}

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

fetch_alpha_version() { # [C-07] --fail + 格式校验
    local v resolved
    if ! resolved=$(resolve_url "$MIHOMO_VERSION_URL"); then
        return 1
    fi
    v=$(curl -fsSL --connect-timeout 10 --max-time 30 "$resolved") || return 1
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
fetch_latest_version() { # [C-08] 校验 null 与空值
    local v raw resolved tag m
    if resolved=$(resolve_url "$MIHOMO_API" 2>/dev/null); then
        raw=$(curl -fsSL --connect-timeout 10 --max-time 30 "$resolved" 2>/dev/null || true)
        v=$(printf '%s' "$raw" | jq -r '.tag_name // empty' 2>/dev/null || true)
        v=${v#v}
        if [[ -n "$v" && "$v" != "null" ]] && valid_version "$v"; then
            printf '%s' "$v"
            return 0
        fi
    fi

    info "API 不可用，改用 releases/latest 重定向获取版本号..."
    tag=$(curl -sSI -o /dev/null -w '%{redirect_url}' \
              --connect-timeout 8 --max-time 20 \
              "https://github.com/MetaCubeX/mihomo/releases/latest" 2>/dev/null || true)
    if [[ -z "$tag" ]]; then
        for m in "${MIRRORS[@]}"; do
            tag=$(curl -sSI -o /dev/null -w '%{redirect_url}' \
                      --connect-timeout 8 --max-time 20 \
                      "${m}/https://github.com/MetaCubeX/mihomo/releases/latest" 2>/dev/null || true)
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

# 资产基名（不含 .gz）。两种通道命名差异：
#   正式版 mihomo-linux-amd64-compatible-v1.19.32
#   测试版 mihomo-linux-amd64-compatible-alpha-94b13ae
# amd64 使用 compatible 变体，兼容不支持较新指令集的 CPU
# 生成候选资产基名（不含 .gz），按优先级逐行输出。
# amd64 使用 compatible 变体（兼容不支持 v2/v3 指令集的老 CPU）；
# arm64 官方无 compatible 变体，其余架构同样不带该后缀。
binary_asset_candidates() {
    local tok compat
    while IFS= read -r tok; do
        [[ -n "$tok" ]] || continue
        compat=""
        [[ "$tok" == "amd64" ]] && compat="-compatible"
        if [[ "$channel" == "alpha" ]]; then
            printf 'mihomo-linux-%s%s-%s\n' "$tok" "$compat" "$version"
        else
            printf 'mihomo-linux-%s%s-v%s\n' "$tok" "$compat" "$version"
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

# 二进制自检：ELF 魔数 + 可执行 [C-06]
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

# 完整性校验：上游 Release 附带 checksums.txt，可用 SHA256 比对，防御镜像投毒。
# 镜像常不缓存该文件，取不到时降级为告警而不阻断安装，避免误伤。
verify_checksum() { # $1=本地文件 $2=资产文件名（如 mihomo-linux-amd64-compatible-v1.19.32.gz）
    local file="$1" name="$2" sums_url sums expect actual tool=""

    if have sha256sum; then
        tool="sha256sum"
    elif have shasum; then
        tool="shasum"
    elif have openssl; then
        tool="openssl"
    else
        warn "未找到 SHA256 校验工具，跳过完整性校验"
        return 0
    fi

    if [[ "$channel" == "alpha" ]]; then
        sums_url="${MIHOMO_RELEASE}/Prerelease-Alpha/checksums.txt"
    else
        sums_url="${MIHOMO_RELEASE}/v${version}/checksums.txt"
    fi

    sums=$(curl -fsSL --connect-timeout 8 --max-time 30 "$sums_url" 2>/dev/null || true)
    if [[ -z "$sums" ]]; then
        local resolved
        if resolved=$(resolve_url "$sums_url" 2>/dev/null); then
            sums=$(curl -fsSL --connect-timeout 8 --max-time 30 "$resolved" 2>/dev/null || true)
        fi
    fi
    if [[ -z "$sums" ]]; then
        warn "无法获取 checksums.txt，跳过完整性校验"
        return 0
    fi

    # checksums.txt 形如：<sha256>  <文件名>（二进制模式下为 <sha256> *<文件名>）
    expect=$(printf '%s\n' "$sums" \
        | awk -v n="$name" '$NF == n || $NF == "*" n { print $1; exit }')
    if [[ -z "$expect" ]]; then
        warn "校验文件中未包含 ${name}，跳过完整性校验"
        return 0
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

install_binary() { # $1=新二进制路径，带备份与回滚 [E-02][E-03]
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
        return 1
    fi
    ok "匹配资产：${base}.gz"

    url=$(binary_asset_url "${base}.gz")
    gz="${ROOT_DIR}/${base}.gz"

    pick_fastest_source "$url" || return 1
    info "开始下载 mihomo 二进制..."
    download_file "$url" "$gz" "mihomo 二进制" || return 1

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

    download_file "$url" "$dest" "系统服务文件" || return 1

    case "$init_sys" in
        systemd)
            if ! grep -q '^\[Unit\]' "$dest"; then
                err "systemd 单元文件格式异常"
                return 1
            fi
            chmod 644 "$dest"
            ;;
        openrc)
            if ! grep -q '^#!' "$dest"; then
                err "OpenRC 服务文件格式异常"
                return 1
            fi
            chmod 755 "$dest"
            ;;
    esac

    service_enable || warn "设置开机自启失败"
}

# ---------- 管理面板 ----------
install_webui() {
    local zip="${ROOT_DIR}/gh-pages.zip"
    local tmpdir="${ROOT_DIR}/.webui-tmp"
    local -a dirs=()

    info "开始下载管理面板..."
    download_file "$WEBUI_URL" "$zip" "管理面板" || return 1

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

    # 替换前必须校验，避免把错误页写成管理脚本 [C-05]
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
backup_config() { # 输出备份路径 [D-01]；固定覆盖同一份 .bak，不累积时间戳文件
    local bak="${CONFIG_FILE}.bak"
    [[ -f "$CONFIG_FILE" ]] || return 0
    if ! cp -f -- "$CONFIG_FILE" "$bak"; then
        err "配置备份失败，已中止写入"
        return 1
    fi
    chmod 600 "$bak"
    printf '%s' "$bak"
}

count_providers() { # [D-04] 锚定统计，$1=文件，缺省为当前配置
    awk '
        /^proxy-providers:[[:space:]]*$/ { f = 1; next }
        f && /^[^[:space:]#]/            { f = 0 }
        f && /^[[:space:]]+provider_[0-9]+:/ { c++ }
        END { print c + 0 }
    ' "${1:-$CONFIG_FILE}"
}

read_subscription() { # $1=序号，输出 provider 块 [D-03]
    local idx="$1" url name
    while true; do
        read_input url "${green}请输入第 ${idx} 个机场的订阅链接: ${reset}"
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
    read_input name "${blue}请输入机场名称（留空使用默认名）: ${reset}"
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

# 用 mihomo 自身校验配置，失败时打印原因 [D-02]
config_test() { # $1=配置文件
    local out
    if ! out=$("$BIN_FILE" -t -f "$1" 2>&1); then
        printf '%s\n' "$out" | tail -n 20 >&2
        return 1
    fi
    return 0
}

# 把 provider 块写入 src，结果输出到 dst，带数量校验 [D-07]
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
        warn "配置中缺少 proxy-providers 段，已按 # 机场配置 标记补全"
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

# 校验 + 重启 + 失败回滚 [D-02]
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

# 面板鉴权：远程配置不含 secret，而 external-controller 监听 0.0.0.0:9090，
# 等于把控制 API 无鉴权暴露到公网。安装时本地生成随机密钥注入配置；
# 已有非空 secret 时保留用户设置，重复执行不会重复插入。
ensure_controller_secret() { # $1=配置文件，输出最终密钥
    local f="$1" cur new tmp q
    q=$'\x27'

    cur=$(awk -v q="$q" '
        /^secret:[[:space:]]*/ {
            v = $0
            sub(/^secret:[[:space:]]*/, "", v)
            gsub("[[:space:]\"" q "]", "", v)
            print v
            exit
        }
    ' "$f" 2>/dev/null || true)

    if [[ -n "$cur" ]]; then
        controller_secret="$cur"
        printf '%s' "$cur"
        return 0
    fi

    new=$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24 || true)
    [[ -n "$new" ]] || new="mihomo$(date +%s)$$"

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

controller_url() { # 从配置读取面板地址
    local addr
    addr=$(awk -F': *' '
        /^[[:space:]]*external-controller:/ {
            gsub(/["'"'"']/, "", $2)
            print $2
            exit
        }
    ' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -z "$addr" ]]; then
        printf 'http://%s:9090/ui' "${ipv4:-127.0.0.1}"
        return 0
    fi
    case "$addr" in
        0.0.0.0:*) printf 'http://%s:%s/ui' "${ipv4:-127.0.0.1}" "${addr##*:}" ;;
        *:*)       printf 'http://%s/ui' "$addr" ;;
        *)         printf 'http://%s:9090/ui' "$addr" ;;
    esac
}

config_mihomo() {
    local bak idx=1 ans block="" block_file base merged
    bak=$(backup_config) || die "配置备份失败，已中止"
    [[ -n "$bak" ]] && ok "原配置已备份：${bak}"

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

    while true; do
        block+=$(read_subscription "$idx")
        block+=$'\n'
        idx=$((idx + 1))
        read_input ans "${yellow}是否继续添加订阅？回车继续，输入 n/N 结束: ${reset}"
        [[ "$ans" =~ ^[nN]$ ]] && break
    done

    block_file=$(mktemp "${ROOT_DIR}/.block.XXXXXX")
    TMP_FILES+=("$block_file")
    printf '%s' "$block" >"$block_file"

    merged=$(mktemp "${ROOT_DIR}/.config.XXXXXX")
    TMP_FILES+=("$merged")
    if ! inject_providers "$block_file" "$base" "$merged"; then
        err "订阅写入失败（现有配置未改动）"
        return 1
    fi

    # 面板密钥必须在校验前注入，避免把非法配置写进正式文件
    ensure_controller_secret "$merged" >/dev/null

    # 写入订阅后再校验一次，仍不通过则完全不落地
    if ! config_test "$merged"; then
        err "写入订阅后配置校验失败，已中止（现有配置未改动）"
        return 1
    fi

    mv -f -- "$merged" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    apply_config "$bak" || return 1

    detect_network_info
    echo
    ok "配置完成，文件位置：${CONFIG_FILE}"
    ok "mihomo 已启动并设置为开机自启"
    printf '%s\n' "${blue}=========================${reset}"
    printf '%s\n' "${green}面板地址：$(controller_url)${reset}"
    if [[ -n "$controller_secret" ]]; then
        printf '%s\n' "${green}面板密钥：${controller_secret}${reset}"
        printf '%s\n' "${yellow}面板已开启鉴权，首次访问需填写上述密钥${reset}"
    fi
    printf '%s\n' "${yellow}注意：mixed-port 7890 不受密钥保护，建议用防火墙限制来源${reset}"
    printf '%s\n' "${green}输入 ${yellow}mihomo ${green}进入管理菜单${reset}"
    printf '%s\n' "${blue}=========================${reset}"
}

# 跳过订阅时仍要落地一份可用配置：
# 否则 $CONFIG_FILE 从未创建，服务无法启动，"systemctl restart mihomo" 必然失败。
install_default_config_only() {
    local base bak
    bak=$(backup_config) || { err "配置备份失败，已中止"; return 1; }
    [[ -n "$bak" ]] && ok "原配置已备份：${bak}"

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

    ensure_controller_secret "$base" >/dev/null

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
    ok "已使用默认配置启动（尚未添加机场订阅）"
    printf '%s\n' "${green}面板地址：$(controller_url)${reset}"
    if [[ -n "$controller_secret" ]]; then
        printf '%s\n' "${green}面板密钥：${controller_secret}${reset}"
    fi
    printf '%s\n' "${green}执行 ${yellow}mihomo ${green}→ 配置管理 添加机场订阅${reset}"
    return 0
}

# ---------- 安装目录 ----------
prepare_dirs() { # [E-01] 不再无脑 rm -rf，先备份配置并确认
    if [[ -d "$ROOT_DIR" ]]; then
        warn "检测到已存在的安装目录：${ROOT_DIR}"
        local bak ans=""
        read_input ans "${yellow}继续将覆盖安装（程序文件被替换，配置会先备份），是否继续？(y/N): ${reset}"
        case "$ans" in
            [Yy]*) ;;
            *) info "已取消安装"; exit 0 ;;
        esac

        bak=$(backup_config) || die "配置备份失败，已中止安装"
        [[ -n "$bak" ]] && ok "原配置已备份：${bak}"

        service_stop
        rm -f -- "$BIN_FILE" "${ROOT_DIR}"/*.gz "${ROOT_DIR}"/gh-pages.zip
        rm -rf -- "${ROOT_DIR}/ui"
    fi
    mkdir -p "$ROOT_DIR"
    cd "$ROOT_DIR" || die "无法进入 ${ROOT_DIR}"
}

# ---------- 主流程 ----------
install_mihomo() {
    detect_distro
    ok "当前系统：${distro}（包管理器：${pkg_mgr}，init：${init_sys}）"

    ensure_bootstrap_tools
    check_network
    install_dependencies

    info "正在检查 IP 转发..."
    check_ip_forward

    detect_arch
    ok "当前架构：${arch_raw}（${arch}）"

    prepare_dirs
    download_mihomo_binary || die "mihomo 安装失败"
    install_service || die "系统服务安装失败"
    install_webui || warn "管理面板安装失败，不影响内核运行"
    install_manager || die "管理脚本安装失败"

    printf '%s\n' "${blue}=========================${reset}"
    ok "mihomo 已安装完成"
    printf '%s\n' "${yellow}输入 y/Y 下载默认配置并添加机场订阅${reset}"
    printf '%s\n' "${yellow}输入 n/N 仅安装默认配置，稍后再添加订阅${reset}"
    printf '%s\n' "${blue}=========================${reset}"

    local ans="y"
    read_input ans "${green}请选择 (y/n) [默认 y]: ${reset}"
    ans=${ans:-y}
    case "$ans" in
        [Yy]*)
            config_mihomo || die "配置写入失败，请检查日志 ${LOG_FILE}"
            ;;
        *)
            warn "已跳过订阅配置，将仅安装默认配置"
            if ! install_default_config_only; then
                warn "默认配置安装失败，服务可能无法启动"
                info "请手动准备配置放到 ${CONFIG_FILE} 后执行：systemctl restart mihomo"
            fi
            ;;
    esac

    info "安装日志：${LOG_FILE}"
}

usage() {
    cat <<EOF
mihomo 一键安装脚本 v${sh_ver}

用法: bash install.sh [选项]

选项:
  -h, --help           显示帮助
  -v, --version        显示版本
  --channel stable     安装正式版（如 v1.19.32）
  --channel alpha      安装测试版（如 alpha-94b13ae）

说明:
  不指定 --channel 时会在安装前询问，默认正式版。
  支持 apt / dnf(yum) / pacman / apk / zypper 系发行版：
    Debian、Ubuntu 及其衍生版（Mint、Kali、Armbian 等）
    Fedora、RHEL、CentOS、Rocky、AlmaLinux、Amazon Linux
    Arch、Manjaro、EndeavourOS
    Alpine
    openSUSE / SLES
  其余发行版将跳过依赖安装，工具齐全时仍可继续。
  支持架构：x86_64 i686 aarch64 armv7l armv6l armv5tel
            riscv64 ppc64le s390x loongarch64 mips(el) mips64(el)
  需 root 权限。
  安装目录 ${ROOT_DIR}
  日志文件 ${LOG_FILE}
EOF
}

parse_args() {
    while (( $# )); do
        case "$1" in
            -h|--help)    usage; exit 0 ;;
            -v|--version) printf 'install.sh v%s\n' "$sh_ver"; exit 0 ;;
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

    if [[ ! -t 0 ]]; then
        channel="stable"
        return 0
    fi

    printf '%s\n' "${blue}=========================${reset}"
    printf '%s\n' "请选择要安装的版本通道："
    printf '%s\n' "${green}1${reset}. 正式版 Release（默认，如 v1.19.32）"
    printf '%s\n' "${green}2${reset}. 测试版 Alpha（如 alpha-94b13ae）"
    printf '%s\n' "${blue}=========================${reset}"

    local ans=""
    read_input ans "${green}请输入选项 [1]: ${reset}"
    ans=${ans//[[:space:]]/}
    case "$ans" in
        2|a|A|alpha|Alpha) channel="alpha" ;;
        *)                 channel="stable" ;;
    esac
    ok "已选择：$(channel_name "$channel")"
}

main() {
    parse_args "$@"
    require_root          # 全局守卫：除帮助与版本外，一律要求 root
    choose_channel        # 未指定 --channel 时交互询问，默认正式版
    install_mihomo
}

main "$@"
