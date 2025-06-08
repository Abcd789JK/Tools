#!/bin/bash

# ---------------------------------
# script : sing-box 一键安装脚本
# desc   : 安装 Xray 或 sing-box，支持多种安全协议（VMess, Shadowsocks, VLESS, Trojan, Hysteria2）
# date   : 2025-06-08 11:07:07
# author : Grok 3
# ---------------------------------

# 颜色定义
red='\033[0;31m'
green='\033[0;32m'
reset='\033[0m'

# 配置参数
CONFIG_XRAY="/usr/local/etc/xray/config.json"
CONFIG_SB="/etc/sing-box/config.json"
SB="/usr/bin/sing-box"
XRAY="/usr/local/bin/xray"
UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
CERT_DIR="/etc/ssl/sing-box"
CERT_FILE="$CERT_DIR/cert.pem"
KEY_FILE="$CERT_DIR/key.pem"
DOWNLOAD_DIR="/tmp"
CONFIG_DOWNLOAD="$DOWNLOAD_DIR/config-$(date +%Y%m%d%H%M%S).json"

# 随机 WebSocket 路径（6位随机大小写字母和数字）
generate_ws_path() {
    WS_PATH="/$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 6)"
}

# 函数定义
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${red}本脚本需要以 root 用户执行，请使用 sudo 或以 root 用户执行。${reset}"
        exit 1
    fi
}

# 判断系统
check_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            debian|ubuntu)
                distro="$ID"
                PKG_UPDATE="apt update && apt upgrade -y"
                PKG_INSTALL="apt install -y"
                UUID_PKG="uuid-runtime"
                ;;
            centos|rhel|fedora)
                distro="$ID"
                PKG_UPDATE="yum update -y || dnf update -y"
                PKG_INSTALL="yum install -y || dnf install -y"
                UUID_PKG="libuuid"
                ;;
            *)
                echo -e "${red}不支持的系统：${ID}${reset}"
                exit 1
                ;;
        esac
    else
        echo -e "${red}无法识别当前系统类型${reset}"
        exit 1
    fi
}

# 检查网络连接
check_network() {
    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        echo -e "${red}无法连接到网络，请检查网络设置。${reset}"
        exit 1
    fi
}

# 更新系统 & 安装必要工具
update_system() {
    echo "更新系统并安装必要工具..."
    eval "$PKG_UPDATE"
    eval "$PKG_INSTALL curl git gzip wget nano iptables tzdata jq unzip yq openssl net-tools $UUID_PKG"
    if [[ $? -ne 0 ]]; then
        echo -e "${red}依赖安装失败，请检查网络或包管理器配置。${reset}"
        echo -e "${red}建议：确保包管理器源有效（例如，Debian/Ubuntu 检查 /etc/apt/sources.list）。${reset}"
        exit 1
    fi
    if ! command -v uuidgen >/dev/null 2>&1 && [ ! -f /proc/sys/kernel/random/uuid ]; then
        echo -e "${red}无法生成 UUID，uuidgen 安装失败且缺少 /proc/sys/kernel/random/uuid。${reset}"
        exit 1
    fi
}

# 检查端口是否被占用
check_port() {
    local port=$1
    echo "检查端口 $port 是否可用..."
    if command -v ss >/dev/null 2>&1; then
        if ss -tuln | grep -q ":$port\b"; then
            echo "端口 $port 被占用（ss 检测）。"
            return 1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tuln | grep -q ":$port\b"; then
            echo "端口 $port 被占用（netstat 检测）。"
            return 1
        fi
    else
        echo -e "${red}未找到 ss 或 netstat，假设端口 $port 可用，但可能不准确。${reset}"
        return 0
    fi
    echo "端口 $port 可用。"
    return 0
}

# 生成不冲突的随机端口
generate_port() {
    local max_attempts=50
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        PORT=$((RANDOM % 40001 + 20000))  # 20000-60000
        if check_port $PORT; then
            echo "使用端口: $PORT"
            return 0
        fi
        ((attempt++))
    done
    echo -e "${red}无法找到可用端口，请检查端口范围或系统状态。${reset}"
    echo -e "${red}建议：使用 'ss -tuln' 或 'netstat -tuln' 检查端口占用，或释放 20000-60000 范围内的端口。${reset}"
    exit 1
}

# 生成自签名证书
generate_cert() {
    if [[ "$USE_TLS" == "y" && ( ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ) ]]; then
        echo "生成自签名证书..."
        mkdir -p "$CERT_DIR"
        DOMAINS=("xiaomi.com" "apple.com" "bing.com" "google.com" "microsoft.com")
        RANDOM_DOMAIN=${DOMAINS[$RANDOM % ${#DOMAINS[@]}]}
        openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=$RANDOM_DOMAIN" >/dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            echo -e "${red}证书生成失败，请检查 openssl 配置。${reset}"
            exit 1
        fi
        chmod 600 "$KEY_FILE"
        chmod 644 "$CERT_FILE"
        echo "使用域名 $RANDOM_DOMAIN 生成证书"
    fi
}

# 安装 Xray
install_xray() {
    if ! command -v xray &> /dev/null; then
        echo "安装 Xray..."
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Xray 安装失败，请检查错误信息并重试。${reset}"
            exit 1
        fi
    else
        echo "Xray 已安装，跳过。"
    fi
}

# 安装 sing-box
install_singbox() {
    if ! command -v sing-box &> /dev/null; then
        echo "安装 sing-box..."
        if ! command -v curl >/dev/null 2>&1; then
            echo -e "${red}curl 未安装，请确保 curl 已正确安装。${reset}"
            exit 1
        fi
        echo "正在下载 sing-box 安装脚本..."
        if ! curl -fsSL https://sing-box.app/install.sh -o /tmp/sing-box-install.sh; then
            echo -e "${red}无法下载 sing-box 安装脚本，请检查网络或 URL 是否有效。${reset}"
            exit 1
        fi
        echo "执行 sing-box 安装脚本..."
        if ! bash /tmp/sing-box-install.sh > /tmp/sing-box-install.log 2>&1; then
            echo -e "${red}sing-box 安装失败，错误日志如下：${reset}"
            cat /tmp/sing-box-install.log
            echo -e "${red}请检查以上错误信息并重试。${reset}"
            rm -f /tmp/sing-box-install.sh /tmp/sing-box-install.log
            exit 1
        fi
        rm -f /tmp/sing-box-install.sh /tmp/sing-box-install.log
    else
        echo "sing-box 已安装，跳过。"
    fi
}

# 生成 Shadowsocks 密码
generate_ss_password() {
    case $SS_METHOD in
        "2022-blake3-aes-256-gcm"|"2022-blake3-chacha20-poly1305")
            PASSWORD=$(openssl rand -base64 32)
            ;;
        "2022-blake3-aes-128-gcm")
            PASSWORD=$(openssl rand -base64 16)
            ;;
        *)
            PASSWORD=$(openssl rand -base64 12)
            ;;
    esac
}

# 验证配置文件
validate_config() {
    local config_file=$1
    if [[ ! -f "$config_file" ]]; then
        echo -e "${red}配置文件 $config_file 不存在${reset}"
        return 1
    fi
    if ! jq . "$config_file" >/dev/null 2>&1; then
        echo -e "${red}配置文件 $config_file 格式无效${reset}"
        return 1
    fi
    return 0
}

# 下载配置文件
download_config() {
    local config_file=$1
    cp "$config_file" "$CONFIG_DOWNLOAD"
    echo "配置文件已保存至: $CONFIG_DOWNLOAD"
    echo "可以通过以下方式下载："
    echo "- 本地: cp $CONFIG_DOWNLOAD /your/destination/path"
    echo "- 远程: scp root@$(hostname -I | awk '{print $1}'):$CONFIG_DOWNLOAD /your/local/path"
    echo "- 或者使用 HTTP (需安装 web 服务器)："
    echo "  1. 安装 web 服务器：$PKG_INSTALL nginx"
    echo "  2. 复制到 web 目录：cp $CONFIG_DOWNLOAD /var/www/html/"
    echo "  3. 下载：curl http://$(hostname -I | awk '{print $1')}/$(basename $CONFIG_DOWNLOAD)"
}

# 卸载服务
uninstall_service() {
    echo "请选择要卸载的内核："
    echo "1. Xray"
    echo "2. Sing-Box"
    read -p "请输入选项 (1-2): " uninstall_choice
    case $uninstall_choice in
        1)
            SERVICE="xray"
            CONFIG="$CONFIG_XRAY"
            BINARY="$XRAY"
            ;;
        2)
            SERVICE="sing-box"
            CONFIG="$CONFIG_SB"
            BINARY="$SB"
            ;;
        *)
            echo -e "${red}无效选择，请重试。${reset}"
            exit 1
            ;;
    esac

    echo "停止 $SERVICE 服务..."
    systemctl stop "$SERVICE" 2>/dev/null
    echo "禁用 $SERVICE 服务..."
    systemctl disable "$SERVICE" 2>/dev/null
    rm -f "/lib/systemd/system/$SERVICE.service" "/etc/systemd/system/$SERVICE.service"
    systemctl daemon-reload
    echo "删除配置文件 $CONFIG..."
    rm -rf "$(dirname "$CONFIG")"
    echo "删除二进制文件 $BINARY..."
    rm -f "$BINARY"
    echo "删除证书目录 $CERT_DIR..."
    rm -rf "$CERT_DIR"
    echo -e "${green}$SERVICE 已卸载！${reset}"
    exit 0
}

# 生成 VMess 配置 (sing-box)
generate_vmess_sb_config() {
    cat > "$CONFIG_SB" << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "name": "user",
          "uuid": "$UUID",
          "alterId": 0
        }
      ]$(if [[ "$USE_WS" == "y" ]]; then
          echo -e ",\n      \"transport\": {\n        \"type\": \"ws\",\n        \"path\": \"$WS_PATH\"\n      }"
        fi)$(if [[ "$USE_TLS" == "y" ]]; then
          echo -e ",\n      \"tls\": {\n        \"enabled\": true,\n        \"certificate_path\": \"$CERT_FILE\",\n        \"key_path\": \"$KEY_FILE\"\n      }"
        fi),
      "tcp_fast_open": true,
      "multiplex": {
        "enabled": true
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
}

# 生成 Shadowsocks 配置 (sing-box)
generate_shadowsocks_sb_config() {
    cat > "$CONFIG_SB" << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": $PORT,
      "method": "$SS_METHOD",
      "password": "$PASSWORD",
      "tcp_fast_open": true,
      "multiplex": {
        "enabled": true
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
}

# 生成 VLESS 配置 (sing-box)
generate_vless_sb_config() {
    cat > "$CONFIG_SB" << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "name": "user",
          "uuid": "$UUID"
        }
      ]$(if [[ "$USE_WS" == "y" ]]; then
          echo -e ",\n      \"transport\": {\n        \"type\": \"ws\",\n        \"path\": \"$WS_PATH\"\n      }"
        fi)$(if [[ "$USE_TLS" == "y" ]]; then
          echo -e ",\n      \"tls\": {\n        \"enabled\": true,\n        \"certificate_path\": \"$CERT_FILE\",\n        \"key_path\": \"$KEY_FILE\"\n      }"
        fi),
      "tcp_fast_open": true,
      "multiplex": {
        "enabled": true
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
}

# 生成 Trojan 配置 (sing-box)
generate_trojan_sb_config() {
    cat > "$CONFIG_SB" << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "name": "user",
          "password": "$PASSWORD"
        }
      ]$(if [[ "$USE_WS" == "y" ]]; then
          echo -e ",\n      \"transport\": {\n        \"type\": \"ws\",\n        \"path\": \"$WS_PATH\"\n      }"
        fi),
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_FILE",
        "key_path": "$KEY_FILE"
      },
      "tcp_fast_open": true,
      "multiplex": {
        "enabled": false
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
}

# 生成 Hysteria2 配置 (sing-box)
generate_hysteria2_sb_config() {
    cat > "$CONFIG_SB" << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hysteria2-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "password": "$PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_FILE",
        "key_path": "$KEY_FILE"
      },
      "obfuscation": {
        "type": "salamander",
        "password": "$PASSWORD"
      },
      "tcp_fast_open": true
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
}

# 生成 VMess 配置 (Xray)
generate_vmess_xray_config() {
    cat > "$CONFIG_XRAY" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": [
      "8.8.8.8",
      "1.1.1.1"
    ]
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "alterId": 0
          }
        ]
      }$(if [[ "$USE_WS" == "y" || "$USE_TLS" == "y" ]]; then
          echo -e ",\n      \"streamSettings\": {\n        \"network\": \"$(if [[ "$USE_WS" == "y" ]]; then echo "ws"; else echo "tcp"; fi)\","
          if [[ "$USE_WS" == "y" ]]; then
            echo -e "        \"wsSettings\": {\n          \"path\": \"$WS_PATH\"\n        }"
          fi
          if [[ "$USE_TLS" == "y" ]]; then
            echo -e "$(if [[ "$USE_WS" == "y" ]]; then echo ","; fi)\n        \"security\": \"tls\",\n        \"tlsSettings\": {\n          \"certificates\": [\n            {\n              \"certificateFile\": \"$CERT_FILE\",\n              \"keyFile\": \"$KEY_FILE\"\n            }\n          ]\n        }"
          fi
          echo -e "\n      }"
        fi)
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {}
    }
  ]
}
EOF
}

# 生成 Shadowsocks 配置 (Xray)
generate_shadowsocks_xray_config() {
    cat > "$CONFIG_XRAY" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": [
      "8.8.8.8",
      "1.1.1.1"
    ]
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "shadowsocks",
      "settings": {
        "method": "$SS_METHOD",
        "password": "$PASSWORD",
        "network": "tcp,udp"
      }$(if [[ "$USE_TLS" == "y" ]]; then
          echo -e ",\n      \"streamSettings\": {\n        \"network\": \"tcp\",\n        \"security\": \"tls\",\n        \"tlsSettings\": {\n          \"certificates\": [\n            {\n              \"certificateFile\": \"$CERT_FILE\",\n              \"keyFile\": \"$KEY_FILE\"\n            }\n          ]\n        }\n      }"
        fi)
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {}
    }
  ]
}
EOF
}

# 生成 VLESS 配置 (Xray)
generate_vless_xray_config() {
    cat > "$CONFIG_XRAY" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": [
      "8.8.8.8",
      "1.1.1.1"
    ]
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID"
          }
        ],
        "decryption": "none"
      }$(if [[ "$USE_WS" == "y" || "$USE_TLS" == "y" ]]; then
          echo -e ",\n      \"streamSettings\": {\n        \"network\": \"$(if [[ "$USE_WS" == "y" ]]; then echo "ws"; else echo "tcp"; fi)\","
          if [[ "$USE_WS" == "y" ]]; then
            echo -e "        \"wsSettings\": {\n          \"path\": \"$WS_PATH\"\n        }"
          fi
          if [[ "$USE_TLS" == "y" ]]; then
            echo -e "$(if [[ "$USE_WS" == "y" ]]; then echo ","; fi)\n        \"security\": \"tls\",\n        \"tlsSettings\": {\n          \"certificates\": [\n            {\n              \"certificateFile\": \"$CERT_FILE\",\n              \"keyFile\": \"$KEY_FILE\"\n            }\n          ]\n        }"
          fi
          echo -e "\n      }"
        fi)
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {}
    }
  ]
}
EOF
}

# 生成 Trojan 配置 (Xray)
generate_trojan_xray_config() {
    cat > "$CONFIG_XRAY" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": [
      "8.8.8.8",
      "1.1.1.1"
    ]
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "$PASSWORD"
          }
        ]
      },
      "streamSettings": {
        "network": "$(if [[ "$USE_WS" == "y" ]]; then echo "ws"; else echo "tcp"; fi)",
        $(if [[ "$USE_WS" == "y" ]]; then
          echo -e "\"wsSettings\": {\n          \"path\": \"$WS_PATH\"\n        },"
        fi)
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "$CERT_FILE",
              "keyFile": "$KEY_FILE"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {}
    }
  ]
}
EOF
}

# 选择 Shadowsocks 加密方法
select_ss_method() {
    echo "请选择 Shadowsocks 加密方法："
    echo "1. aes-128-gcm"
    echo "2. aes-256-gcm"
    echo "3. chacha20-ietf-poly1305"
    echo "4. 2022-blake3-aes-128-gcm (sing-box 专用)"
    echo "5. 2022-blake3-aes-256-gcm (sing-box 专用)"
    echo "6. 2022-blake3-chacha20-poly1305 (sing-box 专用)"
    read -p "请输入选项 (1-6): " method_choice
    case $method_choice in
        1) SS_METHOD="aes-128-gcm";;
        2) SS_METHOD="aes-256-gcm";;
        3) SS_METHOD="chacha20-ietf-poly1305";;
        4) SS_METHOD="2022-blake3-aes-128-gcm";;
        5) SS_METHOD="2022-blake3-aes-256-gcm";;
        6) SS_METHOD="2022-blake3-chacha20-poly1305";;
        *) 
            if [[ "$kernel_choice" == "1" ]]; then
                echo -e "${red}无效选择，Xray 默认使用 chacha20-ietf-poly1305${reset}"
                SS_METHOD="chacha20-ietf-poly1305"
            else
                echo -e "${red}无效选择，sing-box 默认使用 2022-blake3-aes-128-gcm${reset}"
                SS_METHOD="2022-blake3-aes-128-gcm"
            fi
            ;;
    esac
    if [[ "$kernel_choice" == "1" && "$SS_METHOD" =~ ^2022-blake3 ]]; then
        echo -e "${red}Xray 不支持 $SS_METHOD 加密方法，自动切换到 chacha20-ietf-poly1305${reset}"
        SS_METHOD="chacha20-ietf-poly1305"
    fi
}

# 选择协议
select_protocol() {
    echo "请选择协议："
    echo "1. VMess"
    echo "2. Shadowsocks"
    echo "3. VLESS"
    echo "4. Trojan"
    if [[ "$kernel_choice" == "2" ]]; then
        echo "5. Hysteria2 (sing-box 专用)"
        max_option=5
    else
        max_option=4
    fi
    read -p "请输入选项 (1-$max_option): " protocol_choice
    case $protocol_choice in
        1) PROTOCOL="VMess";;
        2) PROTOCOL="Shadowsocks"; select_ss_method; generate_ss_password;;
        3) PROTOCOL="VLESS";;
        4) PROTOCOL="Trojan"; generate_ss_password; USE_TLS="y";;
        5) 
            if [[ "$kernel_choice" == "2" ]]; then
                PROTOCOL="Hysteria2"; generate_ss_password; USE_TLS="y"
            else
                echo -e "${red}无效选择，Hysteria2 仅限 sing-box${reset}"
                exit 1
            fi
            ;;
        *)
            echo -e "${red}无效选择，请重试。${reset}"
            exit 1
            ;;
    esac
}

# 配置 WebSocket 和 TLS 选项
configure_transport() {
    if [[ "$PROTOCOL" == "VMess" || "$PROTOCOL" == "VLESS" || "$PROTOCOL" == "Trojan" ]]; then
        read -p "是否启用 WebSocket 传输？(y/n): " USE_WS
        USE_WS=${USE_WS:-n}
        if [[ "$USE_WS" == "y" ]]; then
            generate_ws_path
        fi
    else
        USE_WS="n"
    fi
    if [[ "$PROTOCOL" == "Shadowsocks" ]]; then
        USE_TLS="n"  # 强制禁用 Shadowsocks 的 TLS
    elif [[ "$PROTOCOL" != "Trojan" && "$PROTOCOL" != "Hysteria2" ]]; then
        read -p "是否启用 TLS？(y/n): " USE_TLS
        USE_TLS=${USE_TLS:-n}
    fi
}

# 安装主函数
install() {
    echo "请选择内核："
    echo "1. Xray"
    echo "2. Sing-Box"
    read -p "请输入选项 (1-2): " kernel_choice
    case $kernel_choice in
        1)
            install_xray
            SERVICE="xray"
            CONFIG="$CONFIG_XRAY"
            ;;
        2)
            install_singbox
            SERVICE="sing-box"
            CONFIG="$CONFIG_SB"
            ;;
        *)
            echo -e "${red}无效选择，请重试。${reset}"
            exit 1
            ;;
    esac

    generate_port
    select_protocol
    configure_transport
    generate_cert

    case $PROTOCOL in
        VMess)
            if [[ "$kernel_choice" == "1" ]]; then
                generate_vmess_xray_config
            else
                generate_vmess_sb_config
            fi
            ;;
        Shadowsocks)
            if [[ "$kernel_choice" == "1" ]]; then
                generate_shadowsocks_xray_config
            else
                generate_shadowsocks_sb_config
            fi
            ;;
        VLESS)
            if [[ "$kernel_choice" == "1" ]]; then
                generate_vless_xray_config
            else
                generate_vless_sb_config
            fi
            ;;
        Trojan)
            if [[ "$kernel_choice" == "1" ]]; then
                generate_trojan_xray_config
            else
                generate_trojan_sb_config
            fi
            ;;
        Hysteria2)
            generate_hysteria2_sb_config
            ;;
    esac

    mkdir -p "$(dirname "$CONFIG")"
    validate_config "$CONFIG" || exit 1
    download_config "$CONFIG"

    echo "启用 $SERVICE 服务..."
    if ! systemctl enable "$SERVICE" >/tmp/service-enable.log 2>&1; then
        echo -e "${red}启用 $SERVICE 服务失败，错误日志：${reset}"
        cat /tmp/service-enable.log
        exit 1
    fi
    echo "重启 $SERVICE 服务..."
    if ! (systemctl daemon-reload && systemctl restart "$SERVICE") >/tmp/service-restart.log 2>&1; then
        echo -e "${red}服务启动失败，错误日志如下：${reset}"
        cat /tmp/service-restart.log
        echo -e "${red}服务状态：${reset}"
        systemctl status "$SERVICE" --no-pager
        echo -e "${red}最近的 $SERVICE 日志：${reset}"
        journalctl -u "$SERVICE" -n 50 --no-pager
        exit 1
    fi

    echo -e "${green}安装完成！${reset}"
    echo "配置文件: $CONFIG"
    echo "协议: $PROTOCOL"
    echo "端口: $PORT"
    if [[ "$PROTOCOL" == "VMess" || "$PROTOCOL" == "VLESS" || "$PROTOCOL" == "Trojan" ]]; then
        echo "WebSocket 启用: ${USE_WS:-n}"
        [[ "$USE_WS" == "y" ]] && echo "WebSocket 路径: $WS_PATH"
    fi
    if [[ "$PROTOCOL" == "VMess" || "$PROTOCOL" == "VLESS" ]]; then
        echo "UUID: $UUID"
    else
        echo "密码: $PASSWORD"
    fi
    [[ "$PROTOCOL" == "Shadowsocks" ]] && echo "加密方法: $SS_METHOD"
    echo "TLS 启用: ${USE_TLS:-n}"
    [[ "$USE_TLS" == "y" ]] && echo -e "TLS 证书: $CERT_FILE\nTLS 私钥: $KEY_FILE\n证书域名: $RANDOM_DOMAIN"
    [[ "$USE_TLS" == "y" ]] && echo -e "${red}注意：当前使用自签名证书，仅用于测试。生产环境中请替换为有效证书！${reset}"
    echo "下载的配置文件: $CONFIG_DOWNLOAD"
}

# 主程序
echo "请选择操作："
echo "1. 安装服务"
echo "2. 卸载服务"
read -p "请输入选项 (1-2): " action_choice
case $action_choice in
    1)
        check_root
        check_distro
        check_network
        update_system
        install
        ;;
    2)
        check_root
        uninstall_service
        ;;
    *)
        echo -e "${red}无效选择，请重试。${reset}"
        exit 1
        ;;
esac