#!/bin/bash
# ---------------------------------
# script : mihomo 一键安装脚本
# desc   : 安装 & 配置
# date   : 2026-10-20 20:04:27
# author : ChatGPT
# ver    : 1.3.0
# ---------------------------------
#
# 本文件与 mihomo.sh 存在刻意重复的公共函数（颜色、系统检测、网络探测、
# 下载、架构识别等）。两者独立部署，修改其中一处时请同步另一处，并在
# 对应函数上方标注 [SYNC] 以便检索。
#
# 变更记录（对应 OPTIMIZATION.md 编号）：
#   A-01~A-07 执行控制与错误处理
#   B-01~B-06 安装前置与依赖
#   C-01~C-08 网络探测与下载
#   D-01~D-11 配置写入安全
#   E-01~E-08 安装/升级/卸载
#   F/G      结构与可观测性
# ---------------------------------

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
sh_ver="1.3.0"

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
readonly SHELL_URL="${REPO_RAW}/Script/mihomo/mihomo.sh"
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
arch=""
arch_raw=""
version=""
channel=""             # 空=未指定（交互询问，默认 stable）；stable=正式版 / alpha=测试版
ipv4=""
use_cdn=false
url_prefix=""          # 空 = 直连；非空 = 已验证可用的镜像前缀
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
detect_distro() {
    [[ -r /etc/os-release ]] || die "无法识别系统类型：缺少 /etc/os-release"
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) distro="$ID";       pkg_mgr="apt"    ;;
        fedora)        distro="fedora";    pkg_mgr="dnf"    ;;
        arch)          distro="arch";      pkg_mgr="pacman" ;;
        alpine)        distro="alpine";    pkg_mgr="apk"    ;;
        *) die "不支持的系统：${ID:-unknown}" ;;
    esac
}

pkg_refresh() { # 仅刷新索引，不做全系统升级 [B-03]
    case "$pkg_mgr" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get update -qq ;;
        dnf)    dnf makecache -q ;;
        pacman) pacman -Sy --noconfirm ;;
        apk)    apk update ;;
        *) return 1 ;;
    esac
}

pkg_install() { # 按包管理器完整定义参数，避免尾部拼接 -qq [B-04]
    case "$pkg_mgr" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" ;;
        dnf)    dnf install -y -q "$@" ;;
        pacman) pacman -S --noconfirm --needed "$@" ;;
        apk)    apk add --no-cache "$@" ;;
        *) return 1 ;;
    esac
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
    local pkgs=(curl wget unzip gzip jq ca-certificates tzdata iptables)
    info "正在安装依赖：${pkgs[*]}"
    pkg_install "${pkgs[@]}" || warn "部分依赖安装失败，后续步骤可能受影响"
    if ! have ip; then # [B-06]
        pkg_install iproute2 >/dev/null 2>&1 || warn "iproute2 安装失败，IP 信息可能无法显示"
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
detect_ipv4() {
    local out
    out=$(ip route get 1.1.1.1 2>/dev/null || true)
    ipv4=$(awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}' <<<"$out")
    if [[ -z "$ipv4" ]]; then
        ipv4=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi
    [[ -n "$ipv4" ]] || ipv4="127.0.0.1"
}

# ---------- 架构 ----------
detect_arch() {
    arch_raw=$(uname -m)
    case "$arch_raw" in
        x86_64)              arch="amd64" ;;
        i386|i486|i586|i686) arch="386"   ;;
        aarch64|arm64)       arch="arm64" ;;
        armv7l)              arch="armv7" ;;
        s390x)               arch="s390x" ;;
        *) die "不支持的架构：${arch_raw}" ;;
    esac
}

# ---------- IP 转发 ----------
sysctl_get() {
    sysctl -n "$1" 2>/dev/null || printf '0'
}

check_ip_forward() {
    local pair key val persist_ok=true

    # 持久化文件不可写时降级为仅本次生效，而不是直接崩溃
    if ! : 2>/dev/null >>"$SYSCTL_FILE"; then
        persist_ok=false
        warn "无法写入 ${SYSCTL_FILE}，IP 转发配置仅在本次运行生效"
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
}

# ---------- 服务管理 [F-04] ----------
service_enable() {
    if [[ "$distro" == "alpine" ]]; then
        rc-update add mihomo default >/dev/null 2>&1
    else
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable mihomo >/dev/null 2>&1
    fi
}

service_restart() {
    if [[ "$distro" == "alpine" ]]; then
        rc-service mihomo restart
    else
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl restart mihomo
    fi
}

service_stop() {
    if [[ "$distro" == "alpine" ]]; then
        rc-service mihomo stop >/dev/null 2>&1 || true
    else
        systemctl stop mihomo >/dev/null 2>&1 || true
    fi
}

service_is_active() {
    local pid=""
    if [[ "$distro" == "alpine" ]]; then
        [[ -f /run/mihomo.pid ]] && pid=$(cat /run/mihomo.pid 2>/dev/null || true)
        [[ -n "$pid" && -d "/proc/${pid}" ]]
    else
        systemctl is-active --quiet mihomo
    fi
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

# 正式版版本号取自 releases/latest 的 tag_name，形如 v1.19.32 → 去掉 v 得 1.19.32
fetch_latest_version() {
    local v raw resolved
    if ! resolved=$(resolve_url "$MIHOMO_API"); then
        return 1
    fi
    raw=$(curl -fsSL --connect-timeout 10 --max-time 30 "$resolved") || return 1
    v=$(printf '%s' "$raw" | jq -r '.tag_name // empty' 2>/dev/null || true)
    v=${v#v}
    if [[ -z "$v" || "$v" == "null" ]]; then
        err "获取正式版版本号失败（可能触发 GitHub API 限流）"
        return 1
    fi
    if ! valid_version "$v"; then
        err "正式版版本号格式异常：${v}"
        return 1
    fi
    printf '%s' "$v"
}

# 资产基名（不含 .gz）。两种通道命名差异：
#   正式版 mihomo-linux-amd64-compatible-v1.19.32
#   测试版 mihomo-linux-amd64-compatible-alpha-94b13ae
# amd64 使用 compatible 变体，兼容不支持较新指令集的 CPU
binary_asset_name() {
    local suffix=""
    [[ "$arch" == "amd64" ]] && suffix="-compatible"
    if [[ "$channel" == "alpha" ]]; then
        printf 'mihomo-linux-%s%s-%s' "$arch" "$suffix" "$version"
    else
        printf 'mihomo-linux-%s%s-v%s' "$arch" "$suffix" "$version"
    fi
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
    local base filename gz url

    if [[ "$channel" == "alpha" ]]; then
        version=$(fetch_alpha_version) || die "获取测试版版本号失败，请检查网络"
    else
        version=$(fetch_latest_version) || die "获取正式版版本号失败，请检查网络"
    fi
    ok "获取软件版本：${version}（$([[ "$channel" == "alpha" ]] && echo 测试版 || echo 正式版)）"

    base=$(binary_asset_name)
    filename="${base}.gz"
    url=$(binary_asset_url "$filename")
    gz="${ROOT_DIR}/${filename}"

    pick_fastest_source "$url" || return 1
    info "开始下载 mihomo 二进制..."
    download_file "$url" "$gz" "mihomo 二进制" || return 1

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
    if [[ "$distro" == "alpine" ]]; then
        dest="$SERVICE_OPENRC"
        url="$SERVICE_URL_OPENRC"
    else
        dest="$SERVICE_SYSTEMD"
        url="$SERVICE_URL_SYSTEMD"
    fi
    download_file "$url" "$dest" "系统服务文件" || return 1

    if [[ "$distro" == "alpine" ]]; then
        if ! grep -q '^#!' "$dest"; then
            err "OpenRC 服务文件格式异常"
            return 1
        fi
        chmod 755 "$dest"
    else
        if ! grep -q '^\[Unit\]' "$dest"; then
            err "systemd 单元文件格式异常"
            return 1
        fi
        chmod 644 "$dest"
    fi
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
backup_config() { # 输出备份路径 [D-01]
    local bak
    [[ -f "$CONFIG_FILE" ]] || return 0
    bak="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    if ! cp -f -- "$CONFIG_FILE" "$bak"; then
        err "配置备份失败，已中止写入"
        return 1
    fi
    chmod 600 "$bak"
    printf '%s' "$bak"
}

count_providers_in() { # $1=文件，锚定统计 [D-04]
    awk '
        /^proxy-providers:[[:space:]]*$/ { f = 1; next }
        f && /^[^[:space:]#]/            { f = 0 }
        f && /^  provider_[0-9]+:/       { c++ }
        END { print c + 0 }
    ' "$1"
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

# 修正上游默认配置中的已知笔误（实测上游第 19 行为 tcp-concurrent: tru）
# 上游文件随时可能变更，这里只处理会导致 mihomo 解析失败的布尔值拼写
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
# 注意：必须接收文件路径而非 stdin —— 管道会让函数在子 shell 中执行，
# 导致 TMP_FILES 无法被 trap 清理。
inject_providers() { # $1=块文件 $2=源配置 $3=输出文件
    local block_file="$1" src="$2" dst="$3" before after

    if [[ ! -s "$block_file" ]]; then
        err "没有可写入的订阅内容"
        return 1
    fi

    before=$(count_providers_in "$src")

    if grep -q '^proxy-providers:[[:space:]]*$' "$src"; then
        awk -v bf="$block_file" '
            function flush(   line) {
                while ((getline line < bf) > 0) print line
                close(bf)
            }
            /^proxy-providers:[[:space:]]*$/ { in_pp = 1; print; next }
            in_pp && /^[^[:space:]#]/ { flush(); in_pp = 0; print; next }
            { print }
            END { if (in_pp) flush() }
        ' "$src" >"$dst"
    elif grep -q '^# 机场配置' "$src"; then
        awk -v bf="$block_file" '
            /^# 机场配置/ {
                print
                print "proxy-providers:"
                while ((getline line < bf) > 0) print line
                close(bf)
                done = 1
                next
            }
            { print }
        ' "$src" >"$dst"
        warn "配置中缺少 proxy-providers 段，已按 # 机场配置 标记补全"
    else
        cp -f -- "$src" "$dst"
        printf '\nproxy-providers:\n' >>"$dst"
        cat "$block_file" >>"$dst"
        warn "配置中既无 proxy-providers 段也无标记，已追加到文件末尾"
    fi

    if ! grep -q '^proxy-providers:' "$dst"; then
        err "写入失败：结果中缺少 proxy-providers 段"
        return 1
    fi

    after=$(count_providers_in "$dst")
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
    if ! service_restart; then
        err "服务重启失败，已回滚配置"
        if [[ -n "$bak" && -f "$bak" ]]; then
            cp -f -- "$bak" "$CONFIG_FILE"
        fi
        service_restart >/dev/null 2>&1 || true
        return 1
    fi
    sleep 1
    if ! service_is_active; then
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

    # 写入订阅后再校验一次，仍不通过则完全不落地
    if ! config_test "$merged"; then
        err "写入订阅后配置校验失败，已中止（现有配置未改动）"
        return 1
    fi

    mv -f -- "$merged" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    apply_config "$bak" || return 1

    detect_ipv4
    echo
    ok "配置完成，文件位置：${CONFIG_FILE}"
    ok "mihomo 已启动并设置为开机自启"
    printf '%s\n' "${blue}=========================${reset}"
    printf '%s\n' "${green}$(controller_url)${reset}"
    printf '%s\n' "${green}输入 ${yellow}mihomo ${green}进入管理菜单${reset}"
    printf '%s\n' "${blue}=========================${reset}"
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
    ok "当前系统：${distro}（包管理器：${pkg_mgr}）"

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
    printf '%s\n' "${yellow}输入 y/Y 下载默认配置并添加订阅${reset}"
    printf '%s\n' "${yellow}输入 n/N 跳过，稍后自行上传配置到 ${CONFIG_FILE}${reset}"
    printf '%s\n' "${blue}=========================${reset}"

    local ans="y"
    read_input ans "${green}请选择 (y/n) [默认 y]: ${reset}"
    ans=${ans:-y}
    case "$ans" in
        [Yy]*)
            config_mihomo || die "配置写入失败，请检查日志 ${LOG_FILE}"
            ;;
        *)
            warn "已跳过配置下载"
            info "将配置放到 ${CONFIG_FILE} 后执行：systemctl restart mihomo"
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
  支持 Debian/Ubuntu、Fedora、Arch、Alpine，需 root 权限。
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
