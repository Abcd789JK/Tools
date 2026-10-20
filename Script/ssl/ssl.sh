#!/usr/bin/env bash
# ==============================================================================
# 脚本名称 : ssl.sh
# 功能描述 : 基于 acme.sh + Cloudflare DNS 的 SSL 证书一键申请脚本 (DNS-01 验证)
#           适用于未开放 80/443 端口的家庭服务器, 支持通配符证书
# 作者     : ChatGPT
# 版本     : 1.1.0
# 更新日期 : 2026-10-20
# ==============================================================================

# ------------------------------ Bash 运行守卫 ------------------------------
# dash 等 shell 不支持 pipefail / [[ ]] / =~ 等语法, 直接拒绝并提示
if [ -z "${BASH_VERSION:-}" ]; then
    printf '%b' '\033[31m[错误] 请使用 bash 运行本脚本: bash ssl.sh\033[0m\n' >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 安全选项:
#   -e            命令执行失败即退出
#   -u            引用未定义变量即退出
#   -o pipefail   管道中任意命令失败即视为整条管道失败
# ------------------------------------------------------------------------------
set -euo pipefail

# ------------------------------ 配置区 ------------------------------
SCRIPT_VERSION="1.1.0"                 # 脚本版本
ACME_BIN="/root/.acme.sh/acme.sh"      # acme.sh 可执行文件路径
SSL_DIR="/root/ssl"                    # 证书输出目录
DEFAULT_CA="letsencrypt"               # 默认证书颁发机构

# ------------------------------ 颜色定义 ------------------------------
readonly RED="\033[31m"    # 红色   - 错误
readonly GREEN="\033[32m"  # 绿色   - 信息/成功
readonly YELLOW="\033[33m" # 黄色   - 警告
readonly CYAN="\033[36m"   # 青色   - 标题/结果
readonly RESET="\033[0m"   # 重置颜色

# ------------------------------ 日志函数 ------------------------------
# 统一日志输出: info 信息 / warn 警告 / error 错误(输出到 stderr)
info()  { printf '%b' "${GREEN}[信息] $*${RESET}\n"; }
warn()  { printf '%b' "${YELLOW}[警告] $*${RESET}\n"; }
error() { printf '%b' "${RED}[错误] $*${RESET}\n" >&2; }

# 脚本异常退出时报告出错行号, 便于排查
err_report() {
    error "脚本在第 ${1} 行执行失败, 请检查上方错误信息。"
}
trap 'err_report ${LINENO}' ERR

# ------------------------------ 欢迎信息 ------------------------------
print_banner() {
    printf '%b' "${CYAN}############################################${RESET}\n"
    printf '%b' "${GREEN}欢迎使用 Cloudflare DNS 证书申请脚本 v${SCRIPT_VERSION}${RESET}\n"
    printf '%b' "${GREEN}仅支持 DNS-01 验证方式, 适用于未开放 80/443 端口的家庭服务器${RESET}\n"
    printf '%b' "${CYAN}############################################${RESET}\n"
}

# ------------------------------ 环境检查 ------------------------------
# 检查 root 权限
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        error "请以 root 用户运行此脚本!"
        exit 1
    fi
}

# 检查系统类型 (仅支持 Debian/Ubuntu 等 apt 系发行版)
check_os() {
    if ! command -v apt-get >/dev/null 2>&1; then
        error "未检测到 apt-get, 本脚本仅支持 Debian/Ubuntu 等 apt 系发行版。"
        exit 1
    fi
}

# 安装依赖 (socat/curl)
install_dependencies() {
    info "正在更新软件包索引并安装依赖 (socat, curl)..."
    apt-get update -y
    apt-get install -y socat curl
}

# 安装或升级 acme.sh
install_acme() {
    if [[ ! -x "$ACME_BIN" ]]; then
        info "未检测到 acme.sh, 开始安装..."
        curl -sS https://get.acme.sh | sh -s -- --install-online
    else
        info "检测到 acme.sh, 正在升级至最新版本..."
        "$ACME_BIN" --upgrade
    fi

    # 安装失败时明确报错, 避免带着错误的路径继续往下执行
    if [[ ! -x "$ACME_BIN" ]]; then
        error "acme.sh 安装失败, 请检查网络或参照 https://github.com/acmesh-official/acme.sh 手动安装。"
        exit 1
    fi

    "$ACME_BIN" --set-default-ca --server "$DEFAULT_CA"
    info "默认颁发机构已设置为 Let's Encrypt"
}

# ------------------------------ 用户输入 ------------------------------
get_cloudflare_info() {
    printf '%b' "${GREEN}请输入 Cloudflare API Token (输入内容不显示): ${RESET}"
    read -rs cf_token
    printf '\n'
    printf '%b' "${GREEN}请输入 Cloudflare Account ID: ${RESET}"
    read -r cf_account_id
    printf '%b' "${GREEN}请输入要申请证书的域名 (如 example.com): ${RESET}"
    read -r domain

    # 输入校验: 三项均不能为空
    if [[ -z "$cf_token" || -z "$cf_account_id" || -z "$domain" ]]; then
        error "API Token、Account ID 与域名均不能为空。"
        exit 1
    fi
    # 输入校验: 域名格式 (仅接受裸域名, 如 example.com 或 a.example.com)
    if [[ ! "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
        error "域名格式不正确: ${domain} (请输入裸域名, 示例: example.com)"
        exit 1
    fi

    # acme.sh dns_cf 所需环境变量
    export CF_Token="$cf_token"
    export CF_Account_ID="$cf_account_id"
}

# ------------------------------ 证书申请 ------------------------------
issue_cert() {
    local -a d_args=()

    # 二级域名: 申请主域名 + 通配符域名; 三级及以上域名: 仅申请该域名
    if [[ "$domain" == *.*.* ]]; then
        d_args+=("-d" "$domain")
    else
        d_args+=("-d" "$domain" "-d" "*.$domain")
    fi

    mkdir -p "$SSL_DIR"

    info "正在申请证书 (DNS-01 验证, 请稍候)..."
    "$ACME_BIN" --issue --dns dns_cf "${d_args[@]}"

    info "证书签发成功, 正在安装到 ${SSL_DIR} ..."
    # 使用 --install-cert 注册续期时的自动复制, 续期后文件会自动更新
    "$ACME_BIN" --install-cert -d "$domain" \
        --key-file "$SSL_DIR/$domain.key" \
        --fullchain-file "$SSL_DIR/$domain.crt"

    # 收紧权限: 目录 700, 私钥 600
    chmod 700 "$SSL_DIR"
    chmod 600 "$SSL_DIR/$domain.key"

    printf '%b' "${CYAN}--------------------------------------------${RESET}\n"
    info "证书安装完成!"
    printf '%b' "${CYAN}私钥: $SSL_DIR/$domain.key${RESET}\n"
    printf '%b' "${CYAN}证书: $SSL_DIR/$domain.crt${RESET}\n"
    warn "acme.sh 已自动注册续期任务, 证书到期前将自动续期并同步以上文件, 无需额外操作。"
    printf '%b' "${CYAN}--------------------------------------------${RESET}\n"
}

# ------------------------------ 主流程 ------------------------------
main() {
    print_banner
    check_root
    check_os
    install_dependencies
    install_acme
    get_cloudflare_info
    issue_cert
}

main "$@"
