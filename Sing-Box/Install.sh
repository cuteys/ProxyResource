#!/bin/bash

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 定义常量
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_NAME="sing-box"
CLIENT_CONFIG_FILE="${CONFIG_DIR}/client.txt"
PROTOCOL_DIR="${CONFIG_DIR}/protocols"
CLIENT_DIR="${CONFIG_DIR}/clients"
REALITY_FRAGMENT_FILE="${PROTOCOL_DIR}/reality.json"
SHADOWTLS_FRAGMENT_FILE="${PROTOCOL_DIR}/shadowtls.json"
REALITY_CLIENT_FILE="${CLIENT_DIR}/reality.txt"
SHADOWTLS_CLIENT_FILE="${CLIENT_DIR}/shadowtls.txt"

# 检测是否为 Alpine Linux
IS_ALPINE=0
if [ -f /etc/alpine-release ]; then
    IS_ALPINE=1
fi

# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请使用 root 权限执行此脚本！${RESET}"
        exit 1
    fi
}

# 检查 sing-box 是否已安装
is_sing_box_installed() {
    if command -v sing-box &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# 检查 sing-box 运行状态
is_sing_box_running() {
    if [ "$IS_ALPINE" -eq 1 ]; then
        rc-service "${SERVICE_NAME}" status &> /dev/null
    else
        systemctl is-active --quiet "${SERVICE_NAME}"
    fi
    return $?
}

# 检查 ss 命令是否可用
check_ss_command() {
    if ! command -v ss &> /dev/null; then
        echo -e "${YELLOW}ss 命令未找到，正在尝试自动安装 iproute2 ${RESET}"

        # 检测包管理器并安装
        if [ "$IS_ALPINE" -eq 1 ]; then
            apk update && apk add iproute2
        elif command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y iproute2
        elif command -v yum &> /dev/null; then
            sudo yum install -y iproute
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y iproute
        elif command -v pacman &> /dev/null; then
            sudo pacman -Sy --noconfirm iproute2
        elif command -v zypper &> /dev/null; then
            sudo zypper install -y iproute2
        else
            echo -e "${RED}无法检测到支持的包管理器，请手动安装 iproute2 包${RESET}"
            exit 1
        fi

        # 再次检查是否安装成功
        if command -v ss &> /dev/null; then
            echo -e "${GREEN}iproute2 安装成功，ss 命令已可用${RESET}"
        else
            echo -e "${RED}自动安装失败，请手动安装 iproute2 / iproute 包${RESET}"
            exit 1
        fi
    else
        echo -e "${GREEN}ss 命令可用${RESET}"
    fi
}

# 检查端口是否被占用
is_port_in_use() {
    local port=$1
    if ss -tuln | grep -q ":$port "; then
        return 0
    else
        return 1
    fi
}

# 获取有效端口号
get_valid_port() {
    local port
    while true; do
        read -p "$1" port
        port=${port:-$((RANDOM % 50000 + 10000))}

        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            if is_port_in_use "$port"; then
                echo -e "${RED}端口 $port 已被占用，请选择其他端口。${RESET}"
            else
                echo "$port"
                return
            fi
        else
            echo -e "${RED}请输入一个有效的端口号（1-65535）${RESET}"
        fi
    done
}

url_encode() {
    local string="$1"
    local length=${#string}
    local encoded=""
    local pos char
    local hex

    for ((pos = 0; pos < length; pos++)); do
        char=${string:${pos}:1}
        case "${char}" in
            [a-zA-Z0-9.~_-])
                encoded+="${char}"
                ;;
            *)
                printf -v hex '%%%02X' "'${char}"
                encoded+="${hex}"
                ;;
        esac
    done

    echo "${encoded}"
}

ensure_state_dirs() {
    mkdir -p "${CONFIG_DIR}" "${PROTOCOL_DIR}" "${CLIENT_DIR}"
}

config_has_reality() {
    [ -f "${CONFIG_FILE}" ] && grep -q '"tag"[[:space:]]*:[[:space:]]*"vless-reality"' "${CONFIG_FILE}"
}

config_has_shadowtls() {
    [ -f "${CONFIG_FILE}" ] && grep -q '"type"[[:space:]]*:[[:space:]]*"shadowtls"' "${CONFIG_FILE}"
}

has_reality_protocol() {
    [ -f "${REALITY_FRAGMENT_FILE}" ] || config_has_reality
}

has_shadowtls_protocol() {
    [ -f "${SHADOWTLS_FRAGMENT_FILE}" ] || config_has_shadowtls
}

extract_inbounds_to_fragment() {
    local protocol=$1
    local output_file=$2
    local tmp_file="${output_file}.tmp"

    awk -v protocol="${protocol}" '
        function count_char(text, char,    i, total) {
            total = 0
            for (i = 1; i <= length(text); i++) {
                if (substr(text, i, 1) == char) {
                    total++
                }
            }
            return total
        }
        function wanted(block) {
            if (protocol == "reality") {
                return block ~ /"tag"[[:space:]]*:[[:space:]]*"vless-reality"/
            }
            return block ~ /"tag"[[:space:]]*:[[:space:]]*"shadowsocks-in"/ || block ~ /"type"[[:space:]]*:[[:space:]]*"shadowtls"/
        }
        /"inbounds"[[:space:]]*:/ {
            in_inbounds = 1
            next
        }
        in_inbounds {
            if (capturing) {
                block = block "\n" $0
                depth += count_char($0, "{") - count_char($0, "}")
                if (depth == 0) {
                    sub(/[[:space:]]*,[[:space:]]*$/, "", block)
                    if (wanted(block)) {
                        if (printed) {
                            print ","
                        }
                        print block
                        printed = 1
                    }
                    capturing = 0
                    block = ""
                }
                next
            }

            if ($0 ~ /^[[:space:]]*{/) {
                capturing = 1
                block = $0
                depth = count_char($0, "{") - count_char($0, "}")
                if (depth == 0) {
                    sub(/[[:space:]]*,[[:space:]]*$/, "", block)
                    if (wanted(block)) {
                        if (printed) {
                            print ","
                        }
                        print block
                        printed = 1
                    }
                    capturing = 0
                    block = ""
                }
                next
            }

            if ($0 ~ /^[[:space:]]*]/) {
                exit
            }
        }
        END {
            if (!printed) {
                exit 1
            }
        }
    ' "${CONFIG_FILE}" > "${tmp_file}"

    if [ $? -ne 0 ] || [ ! -s "${tmp_file}" ]; then
        rm -f "${tmp_file}"
        echo -e "${RED}无法从现有配置导入 ${protocol} 入站配置，已停止以避免覆盖原配置。${RESET}"
        exit 1
    fi

    mv "${tmp_file}" "${output_file}"
}

import_marked_client_section() {
    local start_marker=$1
    local end_marker=$2
    local output_file=$3

    awk -v start_marker="${start_marker}" -v end_marker="${end_marker}" '
        $0 == start_marker {
            in_section = 1
            next
        }
        $0 == end_marker {
            in_section = 0
            found = 1
            next
        }
        in_section {
            print
        }
        END {
            if (!found) {
                exit 1
            }
        }
    ' "${CLIENT_CONFIG_FILE}" > "${output_file}.tmp"

    if [ $? -eq 0 ] && [ -s "${output_file}.tmp" ]; then
        mv "${output_file}.tmp" "${output_file}"
    else
        rm -f "${output_file}.tmp"
    fi
}

import_existing_clients() {
    if [ ! -f "${CLIENT_CONFIG_FILE}" ]; then
        return
    fi

    if grep -q '^===== BEGIN VLESS Reality =====$' "${CLIENT_CONFIG_FILE}"; then
        [ -f "${REALITY_CLIENT_FILE}" ] || import_marked_client_section "===== BEGIN VLESS Reality =====" "===== END VLESS Reality =====" "${REALITY_CLIENT_FILE}"
        [ -f "${SHADOWTLS_CLIENT_FILE}" ] || import_marked_client_section "===== BEGIN ShadowTLS + Shadowsocks =====" "===== END ShadowTLS + Shadowsocks =====" "${SHADOWTLS_CLIENT_FILE}"
        return
    fi

    if config_has_reality && ! config_has_shadowtls && [ ! -f "${REALITY_CLIENT_FILE}" ]; then
        cp "${CLIENT_CONFIG_FILE}" "${REALITY_CLIENT_FILE}"
    elif config_has_shadowtls && ! config_has_reality && [ ! -f "${SHADOWTLS_CLIENT_FILE}" ]; then
        cp "${CLIENT_CONFIG_FILE}" "${SHADOWTLS_CLIENT_FILE}"
    fi
}

import_existing_protocols() {
    ensure_state_dirs

    if [ ! -f "${CONFIG_FILE}" ]; then
        return
    fi

    if config_has_reality && [ ! -f "${REALITY_FRAGMENT_FILE}" ]; then
        echo -e "${CYAN}检测到现有 VLESS Reality 配置，正在导入以便合并管理...${RESET}"
        extract_inbounds_to_fragment "reality" "${REALITY_FRAGMENT_FILE}"
    fi

    if config_has_shadowtls && [ ! -f "${SHADOWTLS_FRAGMENT_FILE}" ]; then
        echo -e "${CYAN}检测到现有 ShadowTLS 配置，正在导入以便合并管理...${RESET}"
        extract_inbounds_to_fragment "shadowtls" "${SHADOWTLS_FRAGMENT_FILE}"
    fi

    import_existing_clients
}

render_config() {
    local first=1
    ensure_state_dirs

    # 准备日志配置
    if [ "$IS_ALPINE" -eq 1 ]; then
        LOG_CONFIG='  "log": {
    "level": "info",
    "timestamp": true,
    "output": "/var/log/sing-box.log"
  },'
    else
        LOG_CONFIG='  "log": {
    "level": "info",
    "timestamp": true
  },'
    fi

    {
        cat << EOF
{
${LOG_CONFIG}
  "dns": {
    "servers": [
      {
        "tag": "cloudflare",
        "type": "https",
        "server": "1.1.1.1"
      },
      {
        "tag": "google",
        "type": "https",
        "server": "8.8.8.8"
      }
    ]
  },
  "route": {
    "default_domain_resolver": "cloudflare"
  },
  "inbounds": [
EOF

        for fragment_file in "${REALITY_FRAGMENT_FILE}" "${SHADOWTLS_FRAGMENT_FILE}"; do
            if [ -f "${fragment_file}" ]; then
                if [ "${first}" -eq 0 ]; then
                    echo ","
                fi
                cat "${fragment_file}"
                first=0
            fi
        done

        cat << EOF

  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    } > "${CONFIG_FILE}"
}

render_client_config() {
    ensure_state_dirs

    {
        if [ -f "${REALITY_CLIENT_FILE}" ]; then
            echo "===== BEGIN VLESS Reality ====="
            cat "${REALITY_CLIENT_FILE}"
            echo "===== END VLESS Reality ====="
            echo ""
        fi

        if [ -f "${SHADOWTLS_CLIENT_FILE}" ]; then
            echo "===== BEGIN ShadowTLS + Shadowsocks ====="
            cat "${SHADOWTLS_CLIENT_FILE}"
            echo "===== END ShadowTLS + Shadowsocks ====="
        fi
    } > "${CLIENT_CONFIG_FILE}"
}

setup_logrotate_for_alpine() {
    if [ "$IS_ALPINE" -eq 1 ]; then
        echo -e "${CYAN}检测到 Alpine 环境，正在配置 logrotate 自动清理日志...${RESET}"
        apk add logrotate > /dev/null 2>&1
        cat > /etc/logrotate.d/sing-box << EOF
/var/log/sing-box.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF
    fi
}

# 安装 sing-box
install_sing_box_binary() {
    check_ss_command

    if is_sing_box_installed; then
        echo -e "${GREEN}sing-box 已安装，跳过核心安装${RESET}"
        return
    fi

    echo -e "${CYAN}正在安装 sing-box${RESET}"

    # 根据系统安装 sing-box
    if [ "$IS_ALPINE" -eq 1 ]; then
        echo -e "${YELLOW}检测到 Alpine Linux，使用 apk 安装...${RESET}"
        for repo in community testing; do
            if ! grep -q "edge/$repo" /etc/apk/repositories; then
                echo "https://dl-cdn.alpinelinux.org/alpine/edge/$repo" >> /etc/apk/repositories
            fi
        done
        apk update
        apk add sing-box
        if [ $? -ne 0 ]; then
            echo -e "${RED}sing-box 安装失败，请检查错误信息${RESET}"
            exit 1
        fi
    else
        # 标准 Linux 安装
        bash <(curl -fsSL https://sing-box.app/deb-install.sh) || {
            echo -e "${RED}sing-box 安装失败！请检查网络连接或安装脚本来源。${RESET}"
            exit 1
        }
    fi
}

enable_sing_box_service() {
    # 启用 sing-box 服务
    if [ "$IS_ALPINE" -eq 1 ]; then
        rc-update add "${SERVICE_NAME}" default || {
            echo -e "${RED}无法启用 ${SERVICE_NAME} 服务！${RESET}"
            exit 1
        }
    else
        systemctl enable "${SERVICE_NAME}" || {
            echo -e "${RED}无法启用 ${SERVICE_NAME} 服务！${RESET}"
            exit 1
        }
    fi
}

reload_sing_box_service() {
    enable_sing_box_service

    if is_sing_box_running; then
        restart_sing_box
    else
        start_sing_box
    fi

    # 检查服务状态
    if ! is_sing_box_running; then
        echo -e "${RED}${SERVICE_NAME} 服务未成功启动！${RESET}"
        if [ "$IS_ALPINE" -eq 1 ]; then rc-service "${SERVICE_NAME}" status; else systemctl status "${SERVICE_NAME}"; fi
        exit 1
    fi
}

write_reality_fragment() {
    cat > "${REALITY_FRAGMENT_FILE}" << EOF
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": ${listen_port},
      "users": [
        {
          "uuid": "${uuid}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${sni}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${sni}",
            "server_port": 443
          },
          "private_key": "${private_key}",
          "short_id": ["${short_id}"]
        }
      }
    }
EOF
}

write_reality_client() {
    {
        echo -e "${PURPLE}=============== 明文参数 ===============${RESET}"
        echo "节点类型  : VLESS"
        echo "服务器IP  : ${host_ip}"
        echo "监听端口  : ${listen_port}"
        echo "UUID      : ${uuid}"
        echo "流控(flow): xtls-rprx-vision"
        echo "传输协议  : tcp"
        echo "伪装域名  : ${sni}"
        echo "安全配置  : reality"
        echo "公钥(pbk) : ${public_key}"
        echo "指纹(fp)  : chrome"

        echo -e "\n${CYAN}=============== 通用分享链接 ===============${RESET}"
        echo -e "${YELLOW}vless://${uuid}@${host_ip}:${listen_port}?security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&type=tcp&flow=xtls-rprx-vision#${ip_country}-VLESS-Reality${RESET}"

        echo -e "\n${GREEN}=============== Sub-Store ===============${RESET}"
        echo -e "${YELLOW}${ip_country}-VLESS = VLESS,${host_ip},${listen_port},\"${uuid}\",transport=tcp,flow=xtls-rprx-vision,public-key=\"${public_key}\",udp=true,block-quic=false,over-tls=true,sni=${sni}${RESET}"
        echo -e "${GREEN}================================================================${RESET}"
    } > "${REALITY_CLIENT_FILE}"
}

install_reality_protocol() {
    if [ -f "${REALITY_FRAGMENT_FILE}" ]; then
        echo -e "${YELLOW}VLESS Reality 已存在，跳过安装${RESET}"
        return
    fi

    # 获取配置参数
    listen_port=$(get_valid_port "请输入 VLESS 监听端口 (默认随机，回车确认): ")

    read -p "请输入伪装域名 SNI (默认: www.yahoo.com): " sni
    sni=${sni:-www.yahoo.com}

    echo -e "${CYAN}正在生成 UUID...${RESET}"
    uuid=$(sing-box generate uuid)

    # 生成密钥对并提取公私钥
    keys=$(sing-box generate reality-keypair)
    private_key=$(echo "$keys" | grep "PrivateKey" | awk '{print $2}')
    public_key=$(echo "$keys" | grep "PublicKey" | awk '{print $2}')

    # 获取本机 IP 地址和所在国家
    host_ip=$(curl -s --max-time 5 http://checkip.amazonaws.com)
    ip_country=$(curl -s --max-time 5 http://ipinfo.io/${host_ip}/country)

    write_reality_fragment
    write_reality_client
    PROTOCOL_CHANGED=1
}

write_shadowtls_fragment() {
    cat > "${SHADOWTLS_FRAGMENT_FILE}" << EOF
    {
      "type": "shadowsocks",
      "tag": "shadowsocks-in",
      "listen": "::",
      "listen_port": ${ssport},
      "method": "2022-blake3-aes-128-gcm",
      "password": "${ss_password}",
      "multiplex": {
        "enabled": true
      }
    },
    {
      "type": "shadowtls",
      "listen": "::",
      "listen_port": ${sport},
      "detour": "shadowsocks-in",
      "version": 3,
      "users": [
        {
          "password": "${password}"
        }
      ],
      "handshake": {
        "server": "www.bing.com",
        "server_port": 443
      },
      "strict_mode": true
    }
EOF
}

write_shadowtls_client() {
    local encoded_ss_password
    local encoded_plugin

    encoded_ss_password=$(url_encode "${ss_password}")
    encoded_plugin=$(url_encode "shadow-tls;host=www.bing.com;passwd=${password};v3")

    {
        echo -e "${PURPLE}=============== 明文参数 ===============${RESET}"
        echo "节点类型        : ShadowTLS + Shadowsocks"
        echo "服务器IP        : ${host_ip}"
        echo "ShadowTLS 端口  : ${sport}"
        echo "Shadowsocks 端口: ${ssport}"
        echo "加密方法        : 2022-blake3-aes-128-gcm"
        echo "Shadowsocks 密码: ${ss_password}"
        echo "ShadowTLS 密码  : ${password}"
        echo "伪装域名        : www.bing.com"
        echo "ShadowTLS 版本  : 3"
        echo "指纹(fp)        : chrome"

        echo -e "\n${CYAN}=============== Clash Meta ===============${RESET}"
        cat << EOF
  - name: ${ip_country}
    type: ss
    server: ${host_ip}
    port: ${sport}
    cipher: 2022-blake3-aes-128-gcm
    password: ${ss_password}
    udp: true
    plugin: shadow-tls
    client-fingerprint: chrome
    plugin-opts:
      mode: tls
      host: www.bing.com
      password: ${password}
      version: 3
    smux:
      enabled: true
EOF

        echo -e "\n${CYAN}=============== 通用分享链接 ===============${RESET}"
        echo -e "${YELLOW}ss://2022-blake3-aes-128-gcm:${encoded_ss_password}@${host_ip}:${sport}/?plugin=${encoded_plugin}#${ip_country}-ShadowTLS${RESET}"

        echo -e "\n${GREEN}=============== Sub-Store ===============${RESET}"
        echo -e "${YELLOW}${ip_country} = Shadowsocks,${host_ip},${sport},2022-blake3-aes-128-gcm,\"${ss_password}\",shadow-tls-password=${password},shadow-tls-sni=www.bing.com,shadow-tls-version=3,udp-port=${ssport},fast-open=false,udp=true${RESET}"
        echo -e "${GREEN}================================================================${RESET}"
    } > "${SHADOWTLS_CLIENT_FILE}"
}

install_shadowtls_protocol() {
    if [ -f "${SHADOWTLS_FRAGMENT_FILE}" ]; then
        echo -e "${YELLOW}ShadowTLS 已存在，跳过安装${RESET}"
        return
    fi

    # 获取端口参数
    sport=$(get_valid_port "请输入 ShadowTLS 监听端口 (默认随机，回车确认): ")
    ssport=$(get_valid_port "请输入 Shadowsocks 监听端口 (默认随机，回车确认): ")

    # 生成密码
    ss_password=$(sing-box generate rand 16 --base64)
    password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)

    # 获取本机 IP 地址和所在国家
    host_ip=$(curl -s --max-time 5 http://checkip.amazonaws.com)
    ip_country=$(curl -s --max-time 5 http://ipinfo.io/${host_ip}/country)

    write_shadowtls_fragment
    write_shadowtls_client
    PROTOCOL_CHANGED=1
}

install_protocols() {
    PROTOCOL_CHANGED=0

    install_sing_box_binary
    setup_logrotate_for_alpine
    import_existing_protocols

    for protocol in "$@"; do
        case "${protocol}" in
            reality)
                install_reality_protocol
                ;;
            shadowtls)
                install_shadowtls_protocol
                ;;
        esac
    done

    if [ "${PROTOCOL_CHANGED}" -eq 1 ]; then
        render_config
        render_client_config
        reload_sing_box_service
        echo -e "${GREEN}sing-box 协议配置更新成功！${RESET}"
        echo ""
        cat "${CLIENT_CONFIG_FILE}"
    else
        echo -e "${YELLOW}没有新增协议配置${RESET}"
    fi
}

uninstall_sing_box() {
    read -p "$(echo -e "${RED}确定要卸载 sing-box 并删除全部协议配置吗? (Y/n) ${RESET}")" choice
    choice=${choice:-Y}
    case "${choice}" in
        y|Y)
            echo -e "${CYAN}正在卸载 sing-box${RESET}"

            if [ "$IS_ALPINE" -eq 1 ]; then
                rc-service "${SERVICE_NAME}" stop || echo -e "${RED}停止 sing-box 服务失败。${RESET}"
                rc-update del "${SERVICE_NAME}" default || echo -e "${RED}禁用 sing-box 服务失败。${RESET}"
                apk del sing-box || echo -e "${YELLOW}无法通过 apk 卸载 sing-box。${RESET}"
            else
                systemctl stop "${SERVICE_NAME}" || echo -e "${RED}停止 sing-box 服务失败。${RESET}"
                systemctl disable "${SERVICE_NAME}" || echo -e "${RED}禁用 sing-box 服务失败。${RESET}"
                dpkg --purge sing-box || echo -e "${YELLOW}可能未通过 apt 安装，跳过 dpkg 卸载。${RESET}"
                systemctl daemon-reload
            fi

            # 删除配置文件及附属日志
            rm -rf "${CONFIG_DIR}"
            rm -f /var/log/sing-box.log*
            rm -f /etc/logrotate.d/sing-box

            # 删除遗留的可执行文件
            if [ -f "/usr/local/bin/sing-box" ]; then
                rm /usr/local/bin/sing-box
            fi

            echo -e "${GREEN}sing-box 卸载成功${RESET}"
            ;;
        *)
            echo -e "${YELLOW}已取消卸载操作${RESET}"
            ;;
    esac
}

has_any_protocol_fragment() {
    [ -f "${REALITY_FRAGMENT_FILE}" ] || [ -f "${SHADOWTLS_FRAGMENT_FILE}" ]
}

remove_protocols() {
    local removed=0

    import_existing_protocols

    for protocol in "$@"; do
        case "${protocol}" in
            reality)
                if [ -f "${REALITY_FRAGMENT_FILE}" ]; then
                    rm -f "${REALITY_FRAGMENT_FILE}" "${REALITY_CLIENT_FILE}"
                    removed=1
                    echo -e "${GREEN}已删除 VLESS Reality 协议配置${RESET}"
                else
                    echo -e "${YELLOW}VLESS Reality 未安装，跳过删除${RESET}"
                fi
                ;;
            shadowtls)
                if [ -f "${SHADOWTLS_FRAGMENT_FILE}" ]; then
                    rm -f "${SHADOWTLS_FRAGMENT_FILE}" "${SHADOWTLS_CLIENT_FILE}"
                    removed=1
                    echo -e "${GREEN}已删除 ShadowTLS 协议配置${RESET}"
                else
                    echo -e "${YELLOW}ShadowTLS 未安装，跳过删除${RESET}"
                fi
                ;;
        esac
    done

    if [ "${removed}" -eq 0 ]; then
        echo -e "${YELLOW}没有删除任何协议配置${RESET}"
        return
    fi

    if has_any_protocol_fragment; then
        render_config
        render_client_config
        reload_sing_box_service
        echo -e "${GREEN}剩余协议配置已生效${RESET}"
        check_sing_box
    else
        read -p "$(echo -e "${YELLOW}已没有剩余协议，是否同时卸载 sing-box 服务与配置? (Y/n) ${RESET}")" cleanup_choice
        cleanup_choice=${cleanup_choice:-Y}
        case "${cleanup_choice}" in
            y|Y)
                choice=Y
                echo -e "${CYAN}正在卸载 sing-box${RESET}"
                if [ "$IS_ALPINE" -eq 1 ]; then
                    rc-service "${SERVICE_NAME}" stop || echo -e "${RED}停止 sing-box 服务失败。${RESET}"
                    rc-update del "${SERVICE_NAME}" default || echo -e "${RED}禁用 sing-box 服务失败。${RESET}"
                    apk del sing-box || echo -e "${YELLOW}无法通过 apk 卸载 sing-box。${RESET}"
                else
                    systemctl stop "${SERVICE_NAME}" || echo -e "${RED}停止 sing-box 服务失败。${RESET}"
                    systemctl disable "${SERVICE_NAME}" || echo -e "${RED}禁用 sing-box 服务失败。${RESET}"
                    dpkg --purge sing-box || echo -e "${YELLOW}可能未通过 apt 安装，跳过 dpkg 卸载。${RESET}"
                    systemctl daemon-reload
                fi
                rm -rf "${CONFIG_DIR}"
                rm -f /var/log/sing-box.log*
                rm -f /etc/logrotate.d/sing-box
                if [ -f "/usr/local/bin/sing-box" ]; then
                    rm /usr/local/bin/sing-box
                fi
                echo -e "${GREEN}sing-box 卸载成功${RESET}"
                ;;
            *)
                render_config
                render_client_config
                stop_sing_box
                echo -e "${YELLOW}已保留 sing-box，当前没有启用任何协议${RESET}"
                ;;
        esac
    fi
}

# 启动 sing-box
start_sing_box() {
    if [ "$IS_ALPINE" -eq 1 ]; then
        rc-service "${SERVICE_NAME}" start
    else
        systemctl start "${SERVICE_NAME}"
    fi

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${SERVICE_NAME} 服务成功启动${RESET}"
    else
        echo -e "${RED}${SERVICE_NAME} 服务启动失败${RESET}"
    fi
}

# 停止 sing-box
stop_sing_box() {
    if [ "$IS_ALPINE" -eq 1 ]; then
        rc-service "${SERVICE_NAME}" stop
    else
        systemctl stop "${SERVICE_NAME}"
    fi

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${SERVICE_NAME} 服务成功停止${RESET}"
    else
        echo -e "${RED}${SERVICE_NAME} 服务停止失败${RESET}"
    fi
}

# 重启 sing-box
restart_sing_box() {
    if [ "$IS_ALPINE" -eq 1 ]; then
        rc-service "${SERVICE_NAME}" restart
    else
        systemctl restart "${SERVICE_NAME}"
    fi

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${SERVICE_NAME} 服务成功重启${RESET}"
    else
        echo -e "${RED}${SERVICE_NAME} 服务重启失败${RESET}"
    fi
}

# 查看 sing-box 状态
status_sing_box() {
    if [ "$IS_ALPINE" -eq 1 ]; then
        rc-service "${SERVICE_NAME}" status
    else
        systemctl status "${SERVICE_NAME}"
    fi
}

# 查看 sing-box 日志
log_sing_box() {
    echo -e "${CYAN}正在实时监控 sing-box 日志，按 Ctrl+C 退出${RESET}"
    if [ "$IS_ALPINE" -eq 1 ]; then
        if [ -f /var/log/sing-box.log ]; then
            tail -f /var/log/sing-box.log
        else
            echo -e "${YELLOW}未找到专属日志文件，尝试过滤系统日志...${RESET}"
            tail -f /var/log/messages | grep sing-box
        fi
    else
        journalctl -u sing-box -n 100 -f
    fi
}

# 查看 sing-box 配置
check_sing_box() {
    if [ -f "${CLIENT_CONFIG_FILE}" ]; then
        cat "${CLIENT_CONFIG_FILE}"
    else
        echo -e "${YELLOW}配置文件不存在: ${CLIENT_CONFIG_FILE}${RESET}"
    fi
}

# 更改 VLESS 监听端口
change_reality_port() {
    import_existing_protocols

    if [ ! -f "${REALITY_FRAGMENT_FILE}" ]; then
        echo -e "${RED}VLESS Reality 尚未安装${RESET}"
        return
    fi

    check_ss_command

    current_port=$(awk -F: '/"listen_port"/ { gsub(/[^0-9]/, "", $2); print $2; exit }' "${REALITY_FRAGMENT_FILE}")
    if [ -z "${current_port}" ]; then
        echo -e "${RED}无法从配置文件中读取当前监听端口${RESET}"
        return
    fi

    echo -e "${CYAN}当前 VLESS 监听端口: ${current_port}${RESET}"
    new_port=$(get_valid_port "请输入新的 VLESS 监听端口 (默认随机，回车确认): ")

    if [ "${new_port}" = "${current_port}" ]; then
        echo -e "${YELLOW}端口未变化，已取消修改${RESET}"
        return
    fi

    tmp_file="${REALITY_FRAGMENT_FILE}.tmp"
    if ! awk -v new_port="${new_port}" '
        /"listen_port"/ && changed == 0 {
            sub(/"listen_port"[[:space:]]*:[[:space:]]*[0-9]+/, "\"listen_port\": " new_port)
            changed = 1
        }
        { print }
    ' "${REALITY_FRAGMENT_FILE}" > "${tmp_file}"; then
        echo -e "${RED}更新服务端配置失败${RESET}"
        rm -f "${tmp_file}"
        return
    fi
    mv "${tmp_file}" "${REALITY_FRAGMENT_FILE}"

    if [ -f "${REALITY_CLIENT_FILE}" ]; then
        tmp_client_file="${REALITY_CLIENT_FILE}.tmp"
        if ! awk -v old_port="${current_port}" -v new_port="${new_port}" '
            {
                sub("监听端口[[:space:]]*:[[:space:]]*" old_port, "监听端口  : " new_port)
                gsub(":" old_port, ":" new_port)
                gsub("," old_port ",", "," new_port ",")
                print
            }
        ' "${REALITY_CLIENT_FILE}" > "${tmp_client_file}"; then
            echo -e "${RED}更新客户端配置失败${RESET}"
            rm -f "${tmp_client_file}"
            return
        fi
        mv "${tmp_client_file}" "${REALITY_CLIENT_FILE}"
    else
        echo -e "${YELLOW}客户端配置文件不存在，已仅更新服务端配置${RESET}"
    fi

    render_config
    render_client_config
    restart_sing_box
    if is_sing_box_running; then
        echo -e "${GREEN}VLESS 监听端口已从 ${current_port} 修改为 ${new_port}${RESET}"
        check_sing_box
    else
        echo -e "${RED}端口已写入配置，但 ${SERVICE_NAME} 服务未成功运行，请查看状态或日志${RESET}"
    fi
}

# 更改 ShadowTLS / Shadowsocks 监听端口
change_shadowtls_port() {
    import_existing_protocols

    if [ ! -f "${SHADOWTLS_FRAGMENT_FILE}" ]; then
        echo -e "${RED}ShadowTLS 尚未安装${RESET}"
        return
    fi

    check_ss_command

    current_ports=$(awk -F: '/"listen_port"/ { gsub(/[^0-9]/, "", $2); ports[++i]=$2 } END { if (i >= 2) print ports[1], ports[2] }' "${SHADOWTLS_FRAGMENT_FILE}")
    set -- ${current_ports}
    current_ssport=$1
    current_sport=$2

    if [ -z "${current_ssport}" ] || [ -z "${current_sport}" ]; then
        echo -e "${RED}无法从配置文件中读取当前监听端口${RESET}"
        return
    fi

    echo -e "${CYAN}当前 ShadowTLS 端口  : ${current_sport}${RESET}"
    echo -e "${CYAN}当前 Shadowsocks 端口: ${current_ssport}${RESET}"
    echo "1. 更改 ShadowTLS 端口"
    echo "2. 更改 Shadowsocks 端口"
    echo "3. 同时更改两个端口"
    read -p "请输入选项编号: " port_choice

    new_sport=${current_sport}
    new_ssport=${current_ssport}

    case "${port_choice}" in
        1)
            new_sport=$(get_valid_port "请输入新的 ShadowTLS 监听端口 (默认随机，回车确认): ")
            ;;
        2)
            new_ssport=$(get_valid_port "请输入新的 Shadowsocks 监听端口 (默认随机，回车确认): ")
            ;;
        3)
            new_sport=$(get_valid_port "请输入新的 ShadowTLS 监听端口 (默认随机，回车确认): ")
            new_ssport=$(get_valid_port "请输入新的 Shadowsocks 监听端口 (默认随机，回车确认): ")
            ;;
        *)
            echo -e "${RED}无效的选项，已取消修改${RESET}"
            return
            ;;
    esac

    if [ "${new_sport}" = "${new_ssport}" ]; then
        echo -e "${RED}ShadowTLS 和 Shadowsocks 端口不能相同，已取消修改${RESET}"
        return
    fi

    if [ "${new_sport}" = "${current_sport}" ] && [ "${new_ssport}" = "${current_ssport}" ]; then
        echo -e "${YELLOW}端口未变化，已取消修改${RESET}"
        return
    fi

    tmp_file="${SHADOWTLS_FRAGMENT_FILE}.tmp"
    if ! awk -v new_ssport="${new_ssport}" -v new_sport="${new_sport}" '
        /"listen_port"/ {
            count++
            if (count == 1) {
                sub(/"listen_port"[[:space:]]*:[[:space:]]*[0-9]+/, "\"listen_port\": " new_ssport)
            } else if (count == 2) {
                sub(/"listen_port"[[:space:]]*:[[:space:]]*[0-9]+/, "\"listen_port\": " new_sport)
            }
        }
        { print }
    ' "${SHADOWTLS_FRAGMENT_FILE}" > "${tmp_file}"; then
        echo -e "${RED}更新服务端配置失败${RESET}"
        rm -f "${tmp_file}"
        return
    fi
    mv "${tmp_file}" "${SHADOWTLS_FRAGMENT_FILE}"

    if [ -f "${SHADOWTLS_CLIENT_FILE}" ]; then
        tmp_client_file="${SHADOWTLS_CLIENT_FILE}.tmp"
        if ! awk \
            -v old_sport="${current_sport}" \
            -v new_sport="${new_sport}" \
            -v old_ssport="${current_ssport}" \
            -v new_ssport="${new_ssport}" '
            {
                sub("ShadowTLS 端口[[:space:]]*:[[:space:]]*" old_sport, "ShadowTLS 端口  : " new_sport)
                sub("Shadowsocks 端口:[[:space:]]*" old_ssport, "Shadowsocks 端口: " new_ssport)
                sub("port: " old_sport "$", "port: " new_sport)
                gsub(":" old_sport "/[?]plugin=", ":" new_sport "/?plugin=")
                gsub(":" old_ssport "#", ":" new_ssport "#")
                gsub("," old_sport ",2022-blake3-aes-128-gcm", "," new_sport ",2022-blake3-aes-128-gcm")
                gsub("udp-port=" old_ssport, "udp-port=" new_ssport)
                print
            }
        ' "${SHADOWTLS_CLIENT_FILE}" > "${tmp_client_file}"; then
            echo -e "${RED}更新客户端配置失败${RESET}"
            rm -f "${tmp_client_file}"
            return
        fi
        mv "${tmp_client_file}" "${SHADOWTLS_CLIENT_FILE}"
    else
        echo -e "${YELLOW}客户端配置文件不存在，已仅更新服务端配置${RESET}"
    fi

    render_config
    render_client_config
    restart_sing_box
    if is_sing_box_running; then
        echo -e "${GREEN}ShadowTLS 端口已从 ${current_sport} 修改为 ${new_sport}${RESET}"
        echo -e "${GREEN}Shadowsocks 端口已从 ${current_ssport} 修改为 ${new_ssport}${RESET}"
        check_sing_box
    else
        echo -e "${RED}端口已写入配置，但 ${SERVICE_NAME} 服务未成功运行，请查看状态或日志${RESET}"
    fi
}

protocol_status_text() {
    if "$1"; then
        echo -e "${GREEN}已配置${RESET}"
    else
        echo -e "${RED}未配置${RESET}"
    fi
}

# 显示菜单
show_menu() {
    clear
    is_sing_box_installed
    sing_box_installed=$?
    is_sing_box_running
    sing_box_running=$?

    echo -e "${GREEN}=== sing-box VLESS Reality / ShadowTLS 管理工具 ===${RESET}"
    if [ "$IS_ALPINE" -eq 1 ]; then
        echo -e "当前系统: ${YELLOW}Alpine Linux (OpenRC)${RESET}"
    else
        echo -e "当前系统: ${YELLOW}Standard Linux (Systemd)${RESET}"
    fi
    echo -e "安装状态: $(if [ ${sing_box_installed} -eq 0 ]; then echo -e "${GREEN}已安装${RESET}"; else echo -e "${RED}未安装${RESET}"; fi)"
    echo -e "运行状态: $(if [ ${sing_box_running} -eq 0 ]; then echo -e "${GREEN}已运行${RESET}"; else echo -e "${RED}未运行${RESET}"; fi)"
    echo -e "Reality : $(protocol_status_text has_reality_protocol)"
    echo -e "ShadowTLS: $(protocol_status_text has_shadowtls_protocol)"
    echo ""
    echo "1. 安装 VLESS Reality"
    echo "2. 安装 ShadowTLS"
    echo "3. 同时安装 VLESS Reality + ShadowTLS"
    echo "4. 删除 VLESS Reality"
    echo "5. 删除 ShadowTLS"
    echo "6. 删除全部协议并卸载 sing-box"
    if [ ${sing_box_installed} -eq 0 ]; then
        if [ ${sing_box_running} -eq 0 ]; then
            echo "7. 停止 sing-box 服务"
        else
            echo "7. 启动 sing-box 服务"
        fi
        echo "8. 重启 sing-box 服务"
        echo "9. 查看 sing-box 状态"
        echo "10. 查看 sing-box 日志"
        echo "11. 查看节点链接配置"
        echo "12. 更改 VLESS 监听端口"
        echo "13. 更改 ShadowTLS / Shadowsocks 监听端口"
    fi
    echo "0. 退出"
    echo -e "${GREEN}=====================================================${RESET}"
    read -p "请输入选项编号: " choice
    echo ""
}

# 捕获 Ctrl+C 信号
trap 'echo -e "\n${RED}已取消操作${RESET}"; exit' INT

# 主循环
check_root

while true; do
    show_menu
    case "${choice}" in
        1)
            install_protocols reality
            ;;
        2)
            install_protocols shadowtls
            ;;
        3)
            install_protocols reality shadowtls
            ;;
        4)
            remove_protocols reality
            ;;
        5)
            remove_protocols shadowtls
            ;;
        6)
            if [ ${sing_box_installed} -eq 0 ]; then
                uninstall_sing_box
            else
                echo -e "${YELLOW}sing-box 尚未安装！${RESET}"
            fi
            ;;
        7)
            if [ ${sing_box_installed} -eq 0 ]; then
                if [ ${sing_box_running} -eq 0 ]; then
                    stop_sing_box
                else
                    start_sing_box
                fi
            else
                echo -e "${RED}sing-box 尚未安装！${RESET}"
            fi
            ;;
        8)
            if [ ${sing_box_installed} -eq 0 ]; then
                restart_sing_box
            else
                echo -e "${RED}sing-box 尚未安装！${RESET}"
            fi
            ;;
        9)
            if [ ${sing_box_installed} -eq 0 ]; then
                status_sing_box
            else
                echo -e "${RED}sing-box 尚未安装！${RESET}"
            fi
            ;;
        10)
            if [ ${sing_box_installed} -eq 0 ]; then
                log_sing_box
            else
                echo -e "${RED}sing-box 尚未安装！${RESET}"
            fi
            ;;
        11)
            if [ ${sing_box_installed} -eq 0 ]; then
                check_sing_box
            else
                echo -e "${RED}sing-box 尚未安装！${RESET}"
            fi
            ;;
        12)
            if [ ${sing_box_installed} -eq 0 ]; then
                change_reality_port
            else
                echo -e "${RED}sing-box 尚未安装！${RESET}"
            fi
            ;;
        13)
            if [ ${sing_box_installed} -eq 0 ]; then
                change_shadowtls_port
            else
                echo -e "${RED}sing-box 尚未安装！${RESET}"
            fi
            ;;
        0)
            echo -e "${GREEN}已退出 sing-box 管理工具${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选项，请输入有效的编号 (0-13)${RESET}"
            ;;
    esac
    read -p "按 Enter 键继续..."
done
