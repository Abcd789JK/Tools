#!/usr/bin/env bash
# ---------- ssl.sh ----------
# desc   : 基于 acme.sh + Cloudflare DNS 的 SSL 证书一键申请（DNS-01 验证）
# date   : 2026-10-24 10:14:31
# author : ChatGPT
# ver    : 1.3.2
#
# 适用于未开放 80/443 端口的家庭服务器，支持通配符证书。
# 支持 Debian/Ubuntu、Fedora/RHEL/CentOS、Arch、Alpine、openSUSE 等主流发行版，需 root 运行。

# 必须用 bash 运行：dash 等 shell 不支持 pipefail / [[ ]] / =~ 等语法
if [ -z "${BASH_VERSION:-}" ]; then
    printf '%s\n' $'\033[31m[错误] 请使用 bash 运行本脚本: bash ssl.sh\033[0m' >&2
    exit 1
fi

# ---------- 安全选项 ----------
# -e 命令失败即退出；-u 引用未定义变量即退出；pipefail 管道任一命令失败即整体失败；
# -E 让 ERR trap 继承进函数与子 shell，否则 err_report 永远不会触发
set -Eeuo pipefail

# 私钥必须在创建瞬间就是 600：--install-cert 落盘后再 chmod 存在 644 的窗口期
umask 077

# ---------- 常量 ----------
SCRIPT_VERSION="1.3.2"            # 脚本版本
readonly ACME_BIN="/root/.acme.sh/acme.sh" # acme.sh 可执行文件路径
readonly SSL_DIR="/root/ssl"               # 证书输出目录
readonly DEFAULT_CA="letsencrypt"          # 默认证书颁发机构
readonly HR="----------------------------------------"
readonly HR_EQ="========================================"

# ---------- 颜色 ----------
# 颜色规范（与 mihomo 脚本保持一致）：边框 blue / 标题 cyan / 成功 green /
# 警告 yellow / 错误 red / 普通文字默认色。非终端输出（管道、重定向）时自动禁用，
# 避免日志文件里混入转义符。
if [[ -t 1 ]]; then
    readonly red=$'\033[31m'
    readonly green=$'\033[32m'
    readonly yellow=$'\033[33m'
    readonly blue=$'\033[34m'
    readonly cyan=$'\033[36m'
    readonly reset=$'\033[0m'
else
    readonly red='' green='' yellow='' blue='' cyan='' reset=''
fi

# ---------- 全局状态 ----------
domain=""            # 要申请证书的域名，由 get_cloudflare_info 填写
cf_token=""          # Cloudflare API Token
cf_account_id=""     # Cloudflare Account ID
distro="unknown"     # 发行版 ID，由 detect_distro 填写
pkg_mgr=""           # 包管理器：apt / dnf / pacman / apk / zypper / none
TMP_FILES=()         # 临时文件清单，退出时由 cleanup 统一清理

# ---------- 清理 ----------
# 脚本退出时清理临时文件（正常退出与异常退出都会触发）
cleanup() {
    (( ${#TMP_FILES[@]} )) || return 0
    rm -f -- "${TMP_FILES[@]}"
}
trap cleanup EXIT

# ---------- 日志 ----------
# 统一日志输出：info 信息 / warn 警告 / error 错误（warn 与 error 走 stderr，与 mihomo 一致）
info()  { printf '%s\n' "${green}[信息] $*${reset}"; }
warn()  { printf '%s\n' "${yellow}[警告] $*${reset}" >&2; }
error() { printf '%s\n' "${red}[错误] $*${reset}" >&2; }
die()   { error "$*"; exit 1; }

# 打印 40 字符分隔线
hr()   { printf '%s\n' "${blue}${HR}${reset}"; }
hreq() { printf '%s\n' "${blue}${HR_EQ}${reset}"; }

# 脚本异常退出时报告出错行号，便于排查
err_report() { # $1=出错行号
    error "脚本在第 $1 行执行失败，请检查上方错误信息。"
}
trap 'err_report ${LINENO}' ERR

# ---------- 欢迎信息 ----------
# 打印脚本横幅：名称、版本与适用场景
print_banner() {
    hreq
    printf '%s\n' "${cyan}  Cloudflare DNS 证书申请脚本  v${SCRIPT_VERSION}${reset}"
    printf '%s\n' "  仅支持 DNS-01 验证，适用于未开放 80/443 端口的家庭服务器"
    hreq
}

# ---------- 通用 ----------
# 判断命令是否存在
command_exists() { command -v "$1" >/dev/null 2>&1; }

# ---------- 环境检查 ----------
# 校验 root 权限，非 root 直接退出
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        error "请以 root 用户运行此脚本!"
        exit 1
    fi
}

# ---------- 系统检测 ----------
# 识别发行版与包管理器，覆盖主流发行版：
#   Debian / Ubuntu 及其衍生版（Mint、Kali、Armbian 等）→ apt
#   Fedora / RHEL / CentOS / Rocky / AlmaLinux            → dnf（无 dnf 时退回 yum）
#   Arch / Manjaro / EndeavourOS                           → pacman
#   Alpine                                                 → apk
#   openSUSE / SLES                                        → zypper
# 未识别时不中断：跳过自动装依赖，改为校验工具是否齐全
detect_distro() {
    if [[ ! -r /etc/os-release ]]; then
        die "无法识别系统类型：缺少 /etc/os-release"
    fi
    # shellcheck disable=SC1091
    . /etc/os-release

    distro="${ID:-unknown}"
    pkg_mgr=""
    local cand
    # ID_LIKE 可能含多个值（如 "rhel centos fedora"），逐个尝试
    for cand in ${ID:-} ${ID_LIKE:-}; do
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
        warn "未识别的发行版：${distro}，将跳过依赖自动安装"
        warn "请自行确认已安装：socat、curl、git"
    fi
    info "系统：${distro}    包管理器：${pkg_mgr}"
}

# 安装软件包：按包管理器分流
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

# 刷新软件包索引
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

# 安装运行依赖（socat / curl / git）
# git 是 acme.sh 默认安装方式（克隆仓库）的前提，见 install_acme 的说明
install_dependencies() {
    local -a miss=()
    local t

    # 先看缺什么：全部就绪就整个跳过包管理器。
    # 否则每次重跑都要刷新索引，软件源临时不可用时会把脚本打断，
    # 而实际上一个包都不用装。
    for t in socat curl git; do
        command_exists "$t" || miss+=("$t")
    done
    (( ${#miss[@]} )) || { info "运行依赖已就绪"; return 0; }

    if [[ "$pkg_mgr" == "none" ]]; then
        error "缺少依赖：${miss[*]}，当前发行版无法自动安装，请手动安装后重试。"
        exit 1
    fi

    info "正在安装缺失的依赖 (${miss[*]})..."
    pkg_refresh || warn "刷新软件源失败，继续尝试安装"
    pkg_install "${miss[@]}" || warn "部分依赖安装失败，继续校验"

    # 装完再确认一次，安装静默失败时明确报错，而不是带着缺失的工具往下走
    miss=()
    for t in socat curl git; do
        command_exists "$t" || miss+=("$t")
    done
    if (( ${#miss[@]} )); then
        error "依赖未安装完整：${miss[*]}，请手动安装后重试。"
        exit 1
    fi
    info "运行依赖已就绪"
}

# 安装或升级 acme.sh，并把默认颁发机构设为 Let's Encrypt
install_acme() {
    local tmp
    if [[ ! -x "$ACME_BIN" ]]; then
        info "未检测到 acme.sh，开始安装..."
        # 必须先落盘再执行，不能写成 `curl ... | sh -s ...`：管道形式下 `--` 在
        # bash 与 dash 中行为不一致——bash 靠它终止选项解析，dash 却把它当位置
        # 参数传进去，安装器二次转发时与 --install-online 拼成 ----install-online，
        # 报 "Unknown parameter" 后安装失败。
        # 也不传 --install-online：默认的 git 克隆安装是官方主推方式，不需要任何
        # 参数，从根上避开传参问题（git 已在 install_dependencies 中装好）。
        tmp=$(mktemp /tmp/acme-install.XXXXXX)
        TMP_FILES+=("$tmp")
        if ! curl -fsSL -o "$tmp" https://get.acme.sh || [[ ! -s "$tmp" ]]; then
            error "acme.sh 安装脚本下载失败，请检查网络。"
            exit 1
        fi
        sh "$tmp"
    else
        info "检测到 acme.sh，尝试升级至最新版本..."
        # 升级失败不阻断流程：本机已有可用版本，签证书并不依赖最新版。
        # 若让 set -e 在这里中断，网络抖动时明明有可用 acme.sh 却签不了证书。
        if ! "$ACME_BIN" --upgrade; then
            warn "acme.sh 升级失败（可能网络不通），继续使用当前版本"
        fi
    fi

    # 安装失败时明确报错，避免带着错误的路径继续往下执行
    if [[ ! -x "$ACME_BIN" ]]; then
        error "acme.sh 安装失败，请检查网络或参照 https://github.com/acmesh-official/acme.sh 手动安装。"
        exit 1
    fi

    "$ACME_BIN" --set-default-ca --server "$DEFAULT_CA"
    info "默认颁发机构已设置为 Let's Encrypt"
}

# ---------- 用户输入 ----------
# 交互收集 Cloudflare API Token、Account ID 与域名，并导出 acme.sh 所需环境变量
get_cloudflare_info() {
    local re
    # 裸域名格式：example.com / a.example.com，不接受通配符与协议前缀
    re='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'

    # 非交互环境（管道 / cron / </dev/null）下 read 必然 EOF；提前给出可执行的提示
    [[ -t 0 ]] || die "本脚本需要交互式终端输入，请直接运行：bash $0"

    printf '%s' "${green}请输入 Cloudflare API Token (输入内容不显示): ${reset}"
    read -rs cf_token || { printf '\n'; die "读取 API Token 失败（输入被中断）"; }
    printf '\n'
    printf '%s' "${green}请输入 Cloudflare Account ID: ${reset}"
    read -r cf_account_id || die "读取 Account ID 失败（输入被中断）"
    printf '%s' "${green}请输入要申请证书的域名 (如 example.com): ${reset}"
    read -r domain || die "读取域名失败（输入被中断）"

    # 输入校验：三项均不能为空
    if [[ -z "$cf_token" || -z "$cf_account_id" || -z "$domain" ]]; then
        error "API Token、Account ID 与域名均不能为空。"
        exit 1
    fi
    # 输入校验：域名格式
    if [[ ! "$domain" =~ $re ]]; then
        error "域名格式不正确: ${domain} (请输入裸域名，示例: example.com)"
        exit 1
    fi

    # acme.sh dns_cf 所需环境变量
    export CF_Token="$cf_token"
    export CF_Account_ID="$cf_account_id"
}

# ---------- 证书申请 ----------
# 申请证书并安装到 SSL_DIR，同时注册续期时的自动复制
issue_cert() {
    local -a d_args=()
    local wildcard=0 ans=""

    # 域名分级：仅凭点的个数无法区分 sub.example.com（子域）与 example.co.uk（可注册域），
    # 后者同样该签通配符。两级域名沿用原行为直接签通配符；三级及以上不再猜测，改为询问。
    if [[ "$domain" == *.*.* ]]; then
        printf '%s' "${green}是否为 ${domain} 一并申请通配符证书 *.${domain}？(y/N): ${reset}"
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

    # 目录先收紧到 700：umask 只对新建目录生效，已存在的目录需显式 chmod
    mkdir -p -- "$SSL_DIR"
    chmod 700 -- "$SSL_DIR"

    info "正在申请证书 (DNS-01 验证，请稍候)..."
    "$ACME_BIN" --issue --dns dns_cf "${d_args[@]}"

    info "证书签发成功，正在安装到 ${SSL_DIR} ..."
    # 使用 --install-cert 注册续期时的自动复制，续期后文件会自动更新
    "$ACME_BIN" --install-cert -d "$domain" \
        --key-file "$SSL_DIR/$domain.key" \
        --fullchain-file "$SSL_DIR/$domain.crt"

    # 收紧权限：目录 700，私钥 600
    chmod 700 "$SSL_DIR"
    chmod 600 "$SSL_DIR/$domain.key"

    hr
    info "证书安装完成!"
    printf '%s\n' "${cyan}私钥: $SSL_DIR/$domain.key${reset}"
    printf '%s\n' "${cyan}证书: $SSL_DIR/$domain.crt${reset}"
    warn "acme.sh 已自动注册续期任务，证书到期前将自动续期并同步以上文件，无需额外操作。"
    hr
}

# ---------- 主流程 ----------
# 脚本入口：横幅 → 环境检查 → 装依赖 → 装 acme.sh → 收集输入 → 申请证书
main() {
    print_banner
    check_root
    detect_distro
    install_dependencies
    install_acme
    get_cloudflare_info
    issue_cert
}

main "$@"
