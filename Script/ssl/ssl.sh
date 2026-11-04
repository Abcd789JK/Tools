#!/usr/bin/env bash

# --------------------------------------------------
# name   : ssl.sh
# desc   : 基于 acme.sh + Cloudflare DNS 的 SSL 证书一键申请（DNS-01 验证）
# date   : 2026-11-03 20:56:24
# author : ChatGPT JK789
# ver    : 0.3.1
# --------------------------------------------------

# 必须用 bash 运行：dash 等 shell 不支持 pipefail / [[ ]] / =~ 等语法。
# 本段使用 POSIX 兼容写法，确保在非 bash 环境下也能输出友好提示后退出。
if [ -z "${BASH_VERSION:-}" ]; then
    _c=''
    _r=''
    if [ -t 2 ]; then
        _c=$(printf '\033[31m')
        _r=$(printf '\033[0m')
    fi
    printf '%s\n' "${_c}[错误] 请使用 bash 运行本脚本: bash ssl.sh${_r}" >&2
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

# 私钥必须在创建瞬间就是 600：--install-cert 落盘后再 chmod 存在 644 的窗口期。
umask 077

# 声明当前脚本版本。
# 必须与文件头 ver 完全一致，供 --version 与启动标题统一读取。
readonly SCRIPT_VERSION="0.3.1"

# ---------- 常量 ----------
readonly SCRIPT_NAME="Cloudflare DNS 证书申请脚本"      # 脚本中文显示名称，仅在启动标题中使用
readonly SCRIPT_DESCRIPTION="仅支持 DNS-01 验证，适用于未开放 80/443 端口的家庭服务器"
readonly ACME_BIN="/root/.acme.sh/acme.sh"             # acme.sh 可执行文件路径
readonly SSL_DIR="/root/ssl"                           # 证书输出目录
readonly DEFAULT_CA="letsencrypt"                      # 默认证书颁发机构
readonly HR="--------------------------------------------------"
readonly HR_EQ="=================================================="

# ---------- 全局状态 ----------
domain=""            # 要申请证书的域名，由 get_cloudflare_info 填写
cf_token=""          # Cloudflare API Token
cf_account_id=""     # Cloudflare Account ID
distro="unknown"     # 发行版 ID，由 detect_distro 填写
pkg_mgr=""           # 包管理器：apt / dnf / pacman / apk / zypper / none
tmp_files=()         # 临时文件清单，退出时由 cleanup 统一清理

# ---------- 颜色 ----------
# ANSI 颜色常量，由 setup_colors 根据终端环境初始化。
COLOR_RESET=''
COLOR_RED=''
COLOR_GREEN=''
COLOR_YELLOW=''
COLOR_BLUE=''
COLOR_CYAN=''
COLOR_GRAY=''

# 根据终端能力和 NO_COLOR 设置日志颜色。
# 颜色只辅助表达状态，不替代文字标签；禁用颜色时标签和文字仍然完整。
setup_colors() {
    # NO_COLOR 只要存在就禁用颜色；TERM=dumb 也不启用颜色。
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

# ---------- 日志 ----------
# 统一日志输出函数；全部写入标准错误，避免污染 stdout 数据流。
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

# 记录致命错误并立即终止脚本。
# 参数：$1... 表示错误信息文本。
# 副作用：以退出码 1 结束当前进程，触发 EXIT 清理。
die() {
    log_error "$*"
    exit 1
}

# ---------- 分隔线与键值输出 ----------
# 打印单线分隔线。
hr() {
    printf '%s\n' "${COLOR_BLUE}${HR}${COLOR_RESET}"
}

# 打印双线分隔线。
hreq() {
    printf '%s\n' "${COLOR_BLUE}${HR_EQ}${COLOR_RESET}"
}

# 打印“标签: 值”行；标签统一青色，值由调用方按语义选择颜色。
# 参数：$1 表示标签，$2 表示值。
kv() {
    local label="${1:?kv 缺少标签参数}"
    local value="${2-}"

    printf '  %s%s%s  %s\n' \
        "$COLOR_CYAN" "$label" "$COLOR_RESET" "$value"
}

# ---------- 清理 ----------
# 脚本退出时清理临时文件（正常退出与异常退出都会触发）。
# 只删除记录在 tmp_files 中的文件，不涉及用户数据。
cleanup() {
    (( ${#tmp_files[@]} )) || return 0
    rm -f -- "${tmp_files[@]}"
}

# 脚本异常退出时报告出错行号，便于排查。
# 参数：$1 表示出错行号。
err_report() {
    log_error "脚本在第 ${1} 行执行失败，请检查上方错误信息。"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'err_report ${LINENO}' ERR

# ---------- 通用 ----------
# 判断命令是否存在。
# 参数：$1 表示命令名称。
# 返回：存在时返回 0；不存在时返回非 0。
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ---------- 用法 ----------
# 打印帮助。--help / --version 遵循项目统一 Root 启动要求，需以 root 运行。
usage() {
    cat <<EOF
用法：bash $(basename -- "$0") [选项]

选项：
  -v, --version    显示版本
  -h, --help       显示本帮助

说明：本脚本为全交互式流程，无其他命令行参数；执行后会依次完成
      环境检查 → 安装依赖 → 安装 acme.sh → 收集 Cloudflare 凭据 → 申请证书。
      证书输出到 ${SSL_DIR}，由 acme.sh 自动续期。需 root 运行（含 --help / --version）。
EOF
}

# 解析命令行参数。
# 本脚本只接受 0 或 1 个参数；-v / -h 处理后直接退出，未知参数按参数错误退出。
parse_args() {
    case "${1:-}" in
        '')
            return 0
            ;;
        -v|--version)
            printf '%s\n' "ssl.sh v${SCRIPT_VERSION}"
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "未知参数：$1（--help 查看用法）"
            exit 2
            ;;
    esac
}

# ---------- 系统检测 ----------
# 识别发行版与包管理器，覆盖主流发行版：
#   Debian / Ubuntu 及其衍生版（Mint、Kali、Armbian 等）→ apt
#   Fedora / RHEL / CentOS / Rocky / AlmaLinux → dnf（无 dnf 时退回 yum）
#   Arch / Manjaro / EndeavourOS → pacman
#   Alpine → apk
#   openSUSE / SLES → zypper
# 未识别时不中断：跳过自动装依赖，改为校验工具是否齐全。
detect_distro() {
    local -a id_list=()
    local cand

    if [[ ! -r /etc/os-release ]]; then
        die "无法识别系统类型：缺少 /etc/os-release"
    fi
    # shellcheck disable=SC1091 # /etc/os-release 为发行版官方只读文件，来源可信。
    . /etc/os-release

    distro="${ID:-unknown}"
    pkg_mgr=""
    # ID_LIKE 可能含多个值（如 "rhel centos fedora"），拆分为数组逐个匹配。
    read -r -a id_list <<< "${ID:-} ${ID_LIKE:-}"
    for cand in "${id_list[@]}"; do
        case "$cand" in
            debian|ubuntu)      pkg_mgr="apt" ;;
            fedora)             pkg_mgr="dnf" ;;
            arch)               pkg_mgr="pacman" ;;
            alpine)             pkg_mgr="apk" ;;
            opensuse*|suse|sles) pkg_mgr="zypper" ;;
            *) continue ;;
        esac
        break
    done

    if [[ -z "$pkg_mgr" ]]; then
        pkg_mgr="none"
        log_warn "未识别的发行版：${distro}，将跳过依赖自动安装"
        log_warn "请自行确认已安装：socat、curl、git"
    fi
    log_info "系统：${distro}    包管理器：${pkg_mgr}"
}

# 安装软件包：按包管理器分流。
# 参数：$1... 表示要安装的软件包名称。
# 返回：安装成功或无需安装时返回 0；包管理器不支持时返回 1。
pkg_install() {
    case "$pkg_mgr" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" ;;
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

# 刷新软件包索引。
# 返回：刷新成功或无需刷新时返回 0；包管理器不支持时返回 1。
pkg_refresh() {
    case "$pkg_mgr" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get update -qq ;;
        dnf)    if command_exists dnf; then dnf makecache -q; else yum makecache -q; fi ;;
        pacman) pacman -Sy --noconfirm ;;
        apk)    apk update ;;
        zypper) zypper --non-interactive refresh ;;
        *) return 1 ;;
    esac
}

# 安装运行依赖（socat / curl / git）。
# git 是 acme.sh 默认安装方式（克隆仓库）的前提，见 install_acme 的说明。
install_dependencies() {
    local -a miss=()
    local t

    # 先看缺什么：全部就绪就整个跳过包管理器。
    # 否则每次重跑都要刷新索引，软件源临时不可用时会把脚本打断，
    # 而实际上一个包都不用装。
    for t in socat curl git; do
        command_exists "$t" || miss+=("$t")
    done
    (( ${#miss[@]} )) || { log_info "运行依赖已就绪"; return 0; }

    if [[ "$pkg_mgr" == "none" ]]; then
        log_error "缺少依赖：${miss[*]}，当前发行版无法自动安装，请手动安装后重试。"
        exit 1
    fi

    log_info "正在安装缺失的依赖 (${miss[*]})..."
    pkg_refresh || log_warn "刷新软件源失败，继续尝试安装"
    pkg_install "${miss[@]}" || log_warn "部分依赖安装失败，继续校验"

    # 装完再确认一次，安装静默失败时明确报错，而不是带着缺失的工具往下走。
    miss=()
    for t in socat curl git; do
        command_exists "$t" || miss+=("$t")
    done
    if (( ${#miss[@]} )); then
        log_error "依赖未安装完整：${miss[*]}，请手动安装后重试。"
        exit 1
    fi
    log_success "运行依赖已就绪"
}

# 安装或升级 acme.sh，并把默认颁发机构设为 Let's Encrypt。
install_acme() {
    local tmp

    if [[ ! -x "$ACME_BIN" ]]; then
        log_info "未检测到 acme.sh，开始安装..."
        # 必须先落盘再执行，不能写成 `curl ... | sh -s ...`：管道形式下 `--` 在
        # bash 与 dash 中行为不一致——bash 靠它终止选项解析，dash 却把它当位置
        # 参数传进去，安装器二次转发时与 --install-online 拼成 ----install-online，
        # 报 "Unknown parameter" 后安装失败。
        # 也不传 --install-online：默认的 git 克隆安装是官方主推方式，不需要任何
        # 参数，从根上避开传参问题（git 已在 install_dependencies 中装好）。
        # 信任模型：安装脚本来自官方域名 get.acme.sh，仅走 HTTPS 并启用 TLS 校验；
        # 落盘后检查非空再执行。发布方未提供逐次安装脚本的校验和，无法做摘要验证，
        # 故以官方渠道 + 协议约束为信任边界。
        tmp=$(mktemp /tmp/acme-install.XXXXXX)
        tmp_files+=("$tmp")
        if ! curl \
            -fsSL \
            --proto '=https' \
            --connect-timeout 10 \
            --max-time 120 \
            -o "$tmp" \
            https://get.acme.sh || [[ ! -s "$tmp" ]]; then
            log_error "acme.sh 安装脚本下载失败，请检查网络。"
            exit 1
        fi
        sh "$tmp"
    else
        log_info "检测到 acme.sh，尝试升级至最新版本..."
        # 升级失败不阻断流程：本机已有可用版本，签证书并不依赖最新版。
        # 若让 set -e 在这里中断，网络抖动时明明有可用 acme.sh 却签不了证书。
        if ! "$ACME_BIN" --upgrade; then
            log_warn "acme.sh 升级失败（可能网络不通），继续使用当前版本"
        fi
    fi

    # 安装失败时明确报错，避免带着错误的路径继续往下执行。
    if [[ ! -x "$ACME_BIN" ]]; then
        log_error "acme.sh 安装失败，请检查网络或参照 https://github.com/acmesh-official/acme.sh 手动安装。"
        exit 1
    fi

    "$ACME_BIN" --set-default-ca --server "$DEFAULT_CA"
    log_success "默认颁发机构已设置为 Let's Encrypt"
}

# ---------- 用户输入 ----------
# 交互收集 Cloudflare API Token、Account ID 与域名，并导出 acme.sh 所需环境变量。
get_cloudflare_info() {
    local re

    # 裸域名格式：example.com / a.example.com，不接受通配符与协议前缀。
    re='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'

    # 非交互环境（管道 / cron / </dev/null）下 read 必然 EOF；提前给出可执行的提示。
    [[ -t 0 ]] || die "本脚本需要交互式终端输入，请直接运行：bash $0"

    printf '%s' "${COLOR_CYAN}请输入 Cloudflare API Token (输入内容不显示): ${COLOR_RESET}"
    read -rs cf_token || { printf '\n'; die "读取 API Token 失败（输入被中断）"; }
    printf '\n'
    printf '%s' "${COLOR_CYAN}请输入 Cloudflare Account ID: ${COLOR_RESET}"
    read -r cf_account_id || die "读取 Account ID 失败（输入被中断）"
    printf '%s' "${COLOR_CYAN}请输入要申请证书的域名 (如 example.com): ${COLOR_RESET}"
    read -r domain || die "读取域名失败（输入被中断）"

    # 输入校验：三项均不能为空。
    if [[ -z "$cf_token" || -z "$cf_account_id" || -z "$domain" ]]; then
        log_error "API Token、Account ID 与域名均不能为空。"
        exit 1
    fi
    # 输入校验：域名格式。
    if [[ ! "$domain" =~ $re ]]; then
        log_error "域名格式不正确: ${domain} (请输入裸域名，示例: example.com)"
        exit 1
    fi

    # acme.sh dns_cf 所需环境变量。
    export CF_Token="$cf_token"
    export CF_Account_ID="$cf_account_id"
}

# ---------- 证书申请 ----------
# 申请证书并安装到 SSL_DIR，同时注册续期时的自动复制。
issue_cert() {
    local -a d_args=()
    local wildcard=0
    local ans=""

    # 域名分级：仅凭点的个数无法区分 sub.example.com（子域）与 example.co.uk（可注册域），
    # 后者同样该签通配符。两级域名沿用原行为直接签通配符；三级及以上不再猜测，改为询问。
    if [[ "$domain" == *.*.* ]]; then
        printf '%s' "${COLOR_CYAN}是否为 ${domain} 一并申请通配符证书 *.${domain}？(y/N): ${COLOR_RESET}"
        read -r ans || die "读取输入失败（输入被中断）"
        if [[ "$ans" =~ ^[yY] ]]; then
            wildcard=1
        fi
    else
        wildcard=1
    fi

    if (( wildcard )); then
        d_args+=("-d" "$domain" "-d" "*.${domain}")
    else
        d_args+=("-d" "$domain")
    fi

    # 目录先收紧到 700：umask 只对新建目录生效，已存在的目录需显式 chmod。
    mkdir -p -- "$SSL_DIR"
    chmod 700 -- "$SSL_DIR"

    log_info "正在申请证书 (DNS-01 验证，请稍候)..."
    "$ACME_BIN" --issue --dns dns_cf "${d_args[@]}"

    log_info "证书签发成功，正在安装到 ${SSL_DIR} ..."
    # 使用 --install-cert 注册续期时的自动复制，续期后文件会自动更新。
    "$ACME_BIN" --install-cert -d "$domain" \
        --key-file "$SSL_DIR/$domain.key" \
        --fullchain-file "$SSL_DIR/$domain.crt"

    # 收紧权限：目录 700，私钥 600。
    chmod 700 "$SSL_DIR"
    chmod 600 "$SSL_DIR/$domain.key"

    hr
    log_success "证书安装完成!"
    kv "私钥" "$SSL_DIR/$domain.key"
    kv "证书" "$SSL_DIR/$domain.crt"
    log_warn "acme.sh 已自动注册续期任务，证书到期前将自动续期并同步以上文件，无需额外操作。"
    hr
}

# ---------- 启动标题 ----------
# 打印脚本横幅：名称、版本与适用场景。
# 名称与版本必须读取 SCRIPT_NAME / SCRIPT_VERSION 常量，不得多处硬编码。
print_script_header() {
    hreq
    printf '  %s%s  v%s%s\n' \
        "$COLOR_CYAN" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$COLOR_RESET"
    printf '  %s\n' "$SCRIPT_DESCRIPTION"
    hreq
}

# ---------- 主流程 ----------
# 脚本入口：参数解析 → 标题 → 环境检查 → 装依赖 → 装 acme.sh → 收集输入 → 申请证书。
main() {
    parse_args "$@"
    print_script_header
    detect_distro
    install_dependencies
    install_acme
    get_cloudflare_info
    issue_cert
}

# Root 检查已通过，初始化颜色后执行主流程。
setup_colors
main "$@"
