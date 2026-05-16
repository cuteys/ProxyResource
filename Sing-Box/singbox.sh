#!/bin/bash

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
RESET='\033[0m'

# 定义常量
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_NAME="sing-box"
CLIENT_CONFIG_FILE="${CONFIG_DIR}/client.txt"
PROTOCOL_DIR="${CONFIG_DIR}/protocols"
CLIENT_DIR="${CONFIG_DIR}/clients"
CERT_DIR="${CONFIG_DIR}/certs"
REALITY_FRAGMENT_FILE="${PROTOCOL_DIR}/reality.json"
SHADOWTLS_FRAGMENT_FILE="${PROTOCOL_DIR}/shadowtls.json"
HY2_FRAGMENT_FILE="${PROTOCOL_DIR}/hy2.json"
HY2_STATE_FILE="${PROTOCOL_DIR}/hy2.env"
REALITY_CLIENT_FILE="${CLIENT_DIR}/reality.txt"
SHADOWTLS_CLIENT_FILE="${CLIENT_DIR}/shadowtls.txt"
HY2_CLIENT_FILE="${CLIENT_DIR}/hy2.txt"
HY2_CERT_FILE="${CERT_DIR}/hy2.crt"
HY2_KEY_FILE="${CERT_DIR}/hy2.key"
HY2_PORT_HOP_FILE="${CONFIG_DIR}/hy2-port-hop.sh"
HY2_PORT_HOP_SYSTEMD_SERVICE="/etc/systemd/system/sing-box-hy2-port-hop.service"
HY2_PORT_HOP_OPENRC_SERVICE="/etc/init.d/sing-box-hy2-port-hop"
FIREWALL_STATE_FILE="${CONFIG_DIR}/firewall.rules"
GEOIP_API_URL="https://geoip.icysn.com/api/json"
IP_INFO_LOADED=0
IPV4_GEOIP_JSON=""
IPV6_GEOIP_JSON=""

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

json_string_value() {
    local json=$1
    local key=$2
    echo "${json}" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

geoip_country_code() {
    echo "$1" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*{[^}]*"code"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

geoip_country_name() {
    echo "$1" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*{[^}]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

geoip_as_number() {
    echo "$1" | sed -n 's/.*"as"[[:space:]]*:[[:space:]]*{[^}]*"number"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p'
}

geoip_as_name() {
    echo "$1" | sed -n 's/.*"as"[[:space:]]*:[[:space:]]*{[^}]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

geoip_is_success() {
    echo "$1" | grep -q '"code"[[:space:]]*:[[:space:]]*0'
}

fetch_geoip_json() {
    local family=$1

    if ! command -v curl &> /dev/null; then
        return 1
    fi

    curl "-${family}" -fsSL --connect-timeout 4 --max-time 8 "${GEOIP_API_URL}" 2>/dev/null
}

load_startup_ip_info() {
    if [ "${IP_INFO_LOADED}" -eq 1 ]; then
        return
    fi

    IPV4_GEOIP_JSON=$(fetch_geoip_json 4 || true)
    IPV6_GEOIP_JSON=$(fetch_geoip_json 6 || true)
    IP_INFO_LOADED=1
}

print_geoip_summary() {
    local label=$1
    local json=$2
    local ip addr country_name country_code as_number as_name

    if [ -z "${json}" ] || ! geoip_is_success "${json}"; then
        echo -e "${label}: ${YELLOW}未获取到公网信息${RESET}"
        return
    fi

    ip=$(json_string_value "${json}" "ip")
    addr=$(json_string_value "${json}" "addr")
    country_name=$(geoip_country_name "${json}")
    country_code=$(geoip_country_code "${json}")
    as_number=$(geoip_as_number "${json}")
    as_name=$(geoip_as_name "${json}")

    echo -e "${label}: ${GREEN}${ip}${RESET}  ${country_name}(${country_code})  AS${as_number} ${as_name}"
    [ -n "${addr}" ] && echo -e "      网段: ${addr}"
}

show_startup_ip_info() {
    echo -e "${CYAN}公网出口信息${RESET}"
    print_geoip_summary "IPv4" "${IPV4_GEOIP_JSON}"
    print_geoip_summary "IPv6" "${IPV6_GEOIP_JSON}"
}

set_current_host_info() {
    local json

    load_startup_ip_info
    json="${IPV4_GEOIP_JSON}"
    if [ -z "$(json_string_value "${json}" "ip")" ]; then
        json="${IPV6_GEOIP_JSON}"
    fi

    host_ip=$(json_string_value "${json}" "ip")
    ip_country=$(geoip_country_code "${json}")

    if [ -z "${host_ip}" ]; then
        host_ip=$(curl -4 -s --max-time 5 http://checkip.amazonaws.com 2>/dev/null | tr -d '\r\n')
    fi

    host_ip=${host_ip:-YOUR_SERVER_IP}
    ip_country=${ip_country:-NODE}
}

format_host_for_uri() {
    local host=$1
    if echo "${host}" | grep -q ':'; then
        echo "[${host}]"
    else
        echo "${host}"
    fi
}

ensure_state_dirs() {
    mkdir -p "${CONFIG_DIR}" "${PROTOCOL_DIR}" "${CLIENT_DIR}" "${CERT_DIR}"
}

config_has_reality() {
    [ -f "${CONFIG_FILE}" ] && grep -q '"tag"[[:space:]]*:[[:space:]]*"vless-reality"' "${CONFIG_FILE}"
}

config_has_shadowtls() {
    [ -f "${CONFIG_FILE}" ] && grep -q '"type"[[:space:]]*:[[:space:]]*"shadowtls"' "${CONFIG_FILE}"
}

config_has_hy2() {
    [ -f "${CONFIG_FILE}" ] && grep -q '"tag"[[:space:]]*:[[:space:]]*"hy2-in"' "${CONFIG_FILE}"
}

has_reality_protocol() {
    [ -f "${REALITY_FRAGMENT_FILE}" ] || config_has_reality
}

has_shadowtls_protocol() {
    [ -f "${SHADOWTLS_FRAGMENT_FILE}" ] || config_has_shadowtls
}

has_hy2_protocol() {
    [ -f "${HY2_FRAGMENT_FILE}" ] || config_has_hy2
}

has_all_protocols() {
    has_reality_protocol && has_hy2_protocol && has_shadowtls_protocol
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
            if (protocol == "hy2") {
                return block ~ /"tag"[[:space:]]*:[[:space:]]*"hy2-in"/
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
        [ -f "${HY2_CLIENT_FILE}" ] || import_marked_client_section "===== BEGIN Hysteria2 =====" "===== END Hysteria2 =====" "${HY2_CLIENT_FILE}"
        [ -f "${SHADOWTLS_CLIENT_FILE}" ] || import_marked_client_section "===== BEGIN ShadowTLS + Shadowsocks =====" "===== END ShadowTLS + Shadowsocks =====" "${SHADOWTLS_CLIENT_FILE}"
        return
    fi

    if config_has_reality && ! config_has_hy2 && ! config_has_shadowtls && [ ! -f "${REALITY_CLIENT_FILE}" ]; then
        cp "${CLIENT_CONFIG_FILE}" "${REALITY_CLIENT_FILE}"
    elif config_has_hy2 && ! config_has_reality && ! config_has_shadowtls && [ ! -f "${HY2_CLIENT_FILE}" ]; then
        cp "${CLIENT_CONFIG_FILE}" "${HY2_CLIENT_FILE}"
    elif config_has_shadowtls && ! config_has_reality && ! config_has_hy2 && [ ! -f "${SHADOWTLS_CLIENT_FILE}" ]; then
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

    if config_has_hy2 && [ ! -f "${HY2_FRAGMENT_FILE}" ]; then
        echo -e "${CYAN}检测到现有 Hysteria2 配置，正在导入以便合并管理...${RESET}"
        extract_inbounds_to_fragment "hy2" "${HY2_FRAGMENT_FILE}"
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

        for fragment_file in "${REALITY_FRAGMENT_FILE}" "${HY2_FRAGMENT_FILE}" "${SHADOWTLS_FRAGMENT_FILE}"; do
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

        if [ -f "${HY2_CLIENT_FILE}" ]; then
            echo "===== BEGIN Hysteria2 ====="
            cat "${HY2_CLIENT_FILE}"
            echo "===== END Hysteria2 ====="
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

install_package_if_missing() {
    local command_name=$1
    local package_name=$2

    if command -v "${command_name}" &> /dev/null; then
        return
    fi

    echo -e "${YELLOW}${command_name} 未安装，正在尝试安装 ${package_name}...${RESET}"
    if [ "$IS_ALPINE" -eq 1 ]; then
        apk add "${package_name}"
    elif command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y "${package_name}"
    elif command -v yum &> /dev/null; then
        yum install -y "${package_name}"
    elif command -v dnf &> /dev/null; then
        dnf install -y "${package_name}"
    elif command -v pacman &> /dev/null; then
        pacman -Sy --noconfirm "${package_name}"
    elif command -v zypper &> /dev/null; then
        zypper install -y "${package_name}"
    else
        echo -e "${RED}无法检测到支持的包管理器，请手动安装 ${package_name}${RESET}"
        exit 1
    fi

    if ! command -v "${command_name}" &> /dev/null; then
        echo -e "${RED}${command_name} 安装失败，请手动安装 ${package_name}${RESET}"
        exit 1
    fi
}

get_valid_mbps() {
    local prompt=$1
    local default_value=$2
    local value

    while true; do
        read -p "${prompt}" value
        value=${value:-${default_value}}

        if [[ "${value}" =~ ^[0-9]+$ ]] && [ "${value}" -gt 0 ]; then
            echo "${value}"
            return
        fi

        echo -e "${RED}请输入大于 0 的整数 Mbps 数值${RESET}"
    done
}

get_valid_interval() {
    local prompt=$1
    local default_value=$2
    local value number

    while true; do
        read -p "${prompt}" value
        value=${value:-${default_value}}
        number=${value%s}

        if [[ "${number}" =~ ^[0-9]+$ ]] && [ "${number}" -ge 5 ]; then
            echo "${number}s"
            return
        fi

        echo -e "${RED}请输入不小于 5 秒的间隔，例如 30s${RESET}"
    done
}

get_valid_port_range() {
    local prompt=$1
    local default_value=$2
    local range start end

    while true; do
        read -p "${prompt}" range
        range=${range:-${default_value}}
        range=$(echo "${range}" | tr -d ' ' | tr '-' ':')

        if [[ "${range}" =~ ^([0-9]+):([0-9]+)$ ]]; then
            start=${BASH_REMATCH[1]}
            end=${BASH_REMATCH[2]}

            if [ "${start}" -ge 1 ] && [ "${end}" -le 65535 ] && [ "${start}" -lt "${end}" ]; then
                echo "${start}:${end}"
                return
            fi
        fi

        echo -e "${RED}请输入有效端口范围，例如 20000:50000${RESET}"
    done
}

range_colon_to_dash() {
    echo "$1" | tr ':' '-'
}

interval_to_seconds() {
    echo "${1%s}"
}

write_hy2_state() {
    cat > "${HY2_STATE_FILE}" << EOF
hy2_port='${hy2_port}'
hy2_password='${hy2_password}'
hy2_obfs_password='${hy2_obfs_password}'
hy2_sni='${hy2_sni}'
hy2_up_mbps='${hy2_up_mbps}'
hy2_down_mbps='${hy2_down_mbps}'
hy2_hop_enabled='${hy2_hop_enabled}'
hy2_hop_range='${hy2_hop_range}'
hy2_hop_interval='${hy2_hop_interval}'
EOF
}

load_hy2_state() {
    if [ ! -f "${HY2_STATE_FILE}" ]; then
        echo -e "${RED}缺少 HY2 状态文件，无法安全修改。建议删除后重新安装 HY2。${RESET}"
        return 1
    fi

    # shellcheck disable=SC1090
    . "${HY2_STATE_FILE}"
}

generate_hy2_certificate() {
    install_package_if_missing openssl openssl
    ensure_state_dirs

    if [ -f "${HY2_CERT_FILE}" ] && [ -f "${HY2_KEY_FILE}" ]; then
        return
    fi

    echo -e "${CYAN}正在生成 Hysteria2 自签证书...${RESET}"
    if ! openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "${HY2_KEY_FILE}" \
        -out "${HY2_CERT_FILE}" \
        -days 3650 \
        -subj "/CN=${hy2_sni}" \
        -addext "subjectAltName=DNS:${hy2_sni}" >/dev/null 2>&1; then
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "${HY2_KEY_FILE}" \
            -out "${HY2_CERT_FILE}" \
            -days 3650 \
            -subj "/CN=${hy2_sni}" >/dev/null 2>&1 || {
                echo -e "${RED}Hysteria2 证书生成失败${RESET}"
                exit 1
            }
    fi
}

write_hy2_port_hop_script() {
    cat > "${HY2_PORT_HOP_FILE}" << EOF
#!/bin/sh
BASE_PORT="${hy2_port}"
PORT_RANGE="${hy2_hop_range}"

apply_rule() {
    cmd="\$1"
    if ! command -v "\${cmd}" >/dev/null 2>&1; then
        return
    fi

    "\${cmd}" -t nat -D PREROUTING -p udp --dport "\${PORT_RANGE}" -j REDIRECT --to-ports "\${BASE_PORT}" 2>/dev/null || true
    "\${cmd}" -t nat -A PREROUTING -p udp --dport "\${PORT_RANGE}" -j REDIRECT --to-ports "\${BASE_PORT}" 2>/dev/null || true
}

remove_rule() {
    cmd="\$1"
    if ! command -v "\${cmd}" >/dev/null 2>&1; then
        return
    fi

    "\${cmd}" -t nat -D PREROUTING -p udp --dport "\${PORT_RANGE}" -j REDIRECT --to-ports "\${BASE_PORT}" 2>/dev/null || true
}

case "\${1:-apply}" in
    apply)
        apply_rule iptables
        apply_rule ip6tables
        ;;
    remove)
        remove_rule iptables
        remove_rule ip6tables
        ;;
    *)
        echo "Usage: \$0 {apply|remove}"
        exit 1
        ;;
esac
EOF

    chmod +x "${HY2_PORT_HOP_FILE}"
}

disable_hy2_port_hopping_runtime() {
    if [ "$IS_ALPINE" -eq 1 ]; then
        if [ -f "${HY2_PORT_HOP_OPENRC_SERVICE}" ]; then
            rc-service sing-box-hy2-port-hop stop >/dev/null 2>&1 || true
            rc-update del sing-box-hy2-port-hop default >/dev/null 2>&1 || true
            rm -f "${HY2_PORT_HOP_OPENRC_SERVICE}"
        fi
    else
        if [ -f "${HY2_PORT_HOP_SYSTEMD_SERVICE}" ]; then
            systemctl stop sing-box-hy2-port-hop.service >/dev/null 2>&1 || true
            systemctl disable sing-box-hy2-port-hop.service >/dev/null 2>&1 || true
            rm -f "${HY2_PORT_HOP_SYSTEMD_SERVICE}"
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
    fi

    if [ -x "${HY2_PORT_HOP_FILE}" ]; then
        "${HY2_PORT_HOP_FILE}" remove >/dev/null 2>&1 || true
    fi
    rm -f "${HY2_PORT_HOP_FILE}"
}

enable_hy2_port_hopping_runtime() {
    disable_hy2_port_hopping_runtime
    write_hy2_port_hop_script

    if [ "$IS_ALPINE" -eq 1 ]; then
        cat > "${HY2_PORT_HOP_OPENRC_SERVICE}" << EOF
#!/sbin/openrc-run
description="sing-box Hysteria2 port hopping rules"
command="${HY2_PORT_HOP_FILE}"

start() {
    ebegin "Applying sing-box HY2 port hopping rules"
    \${command} apply
    eend \$?
}

stop() {
    ebegin "Removing sing-box HY2 port hopping rules"
    \${command} remove
    eend \$?
}
EOF
        chmod +x "${HY2_PORT_HOP_OPENRC_SERVICE}"
        rc-update add sing-box-hy2-port-hop default >/dev/null 2>&1 || true
        rc-service sing-box-hy2-port-hop restart >/dev/null 2>&1 || "${HY2_PORT_HOP_FILE}" apply
    else
        cat > "${HY2_PORT_HOP_SYSTEMD_SERVICE}" << EOF
[Unit]
Description=sing-box Hysteria2 port hopping rules
After=network-online.target
Wants=network-online.target
Before=sing-box.service

[Service]
Type=oneshot
ExecStart=${HY2_PORT_HOP_FILE} apply
ExecStop=${HY2_PORT_HOP_FILE} remove
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable --now sing-box-hy2-port-hop.service >/dev/null 2>&1 || "${HY2_PORT_HOP_FILE}" apply
    fi
}

detect_firewall_backend() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "ufw"
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        echo "firewalld"
    elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q "hook input"; then
        echo "nftables"
    elif command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | awk '
        NR == 1 && $0 !~ /^-P INPUT ACCEPT$/ { active = 1 }
        NR > 1 { active = 1 }
        END { exit active ? 0 : 1 }
    '; then
        echo "iptables"
    else
        echo "none"
    fi
}

firewall_backend_label() {
    case "$(detect_firewall_backend)" in
        ufw) echo "ufw (active)" ;;
        firewalld) echo "firewalld (running)" ;;
        nftables) echo "nftables (detected)" ;;
        iptables) echo "iptables (active rules)" ;;
        *) echo "未检测到已启用的防火墙" ;;
    esac
}

firewall_port_for_backend() {
    local backend=$1
    local port=$2

    if [ "${backend}" = "firewalld" ] || [ "${backend}" = "nftables" ]; then
        range_colon_to_dash "${port}"
    else
        echo "${port}"
    fi
}

nft_input_chain() {
    nft -a list ruleset 2>/dev/null | awk '
        /^table[[:space:]]+/ {
            family = $2
            table = $3
            gsub(/[{}]/, "", table)
        }
        /^[[:space:]]*chain[[:space:]]+/ {
            chain = $2
            gsub(/[{}]/, "", chain)
        }
        /hook[[:space:]]+input/ && family != "" && table != "" && chain != "" {
            print family, table, chain
            exit
        }
    '
}

nft_rule_marker() {
    echo "singbox-managed $1/$2"
}

nft_delete_managed_rules() {
    local proto=$1
    local port=$2
    local marker

    marker=$(nft_rule_marker "${proto}" "${port}")
    nft -a list ruleset 2>/dev/null | awk -v marker="${marker}" '
        /^table[[:space:]]+/ {
            family = $2
            table = $3
            gsub(/[{}]/, "", table)
        }
        /^[[:space:]]*chain[[:space:]]+/ {
            chain = $2
            gsub(/[{}]/, "", chain)
        }
        index($0, "comment \"" marker "\"") && match($0, /# handle [0-9]+/) {
            handle = substr($0, RSTART + 9, RLENGTH - 9)
            print family, table, chain, handle
        }
    ' | while read -r family table chain handle; do
        [ -n "${handle}" ] && nft delete rule "${family}" "${table}" "${chain}" handle "${handle}" >/dev/null 2>&1 || true
    done
}

firewall_add_rule() {
    local backend=$1
    local proto=$2
    local port=$3
    local formatted_port current_status nft_family nft_table nft_chain

    formatted_port=$(firewall_port_for_backend "${backend}" "${port}")
    current_status=$(firewall_port_status "${backend}" "${proto}" "${port}")
    if [ "${current_status}" = "已放行" ] || [ "${current_status}" = "默认放行" ] || [ "${current_status}" = "未启用防火墙" ]; then
        return 0
    fi

    case "${backend}" in
        ufw)
            ufw allow "${formatted_port}/${proto}" >/dev/null 2>&1 || return 1
            ;;
        firewalld)
            firewall-cmd --permanent --add-port="${formatted_port}/${proto}" >/dev/null 2>&1 || return 1
            firewall-cmd --reload >/dev/null 2>&1 || true
            ;;
        iptables)
            iptables -C INPUT -p "${proto}" --dport "${port}" -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p "${proto}" --dport "${port}" -j ACCEPT >/dev/null 2>&1 || return 1
            if command -v ip6tables >/dev/null 2>&1; then
                ip6tables -C INPUT -p "${proto}" --dport "${port}" -j ACCEPT >/dev/null 2>&1 || ip6tables -I INPUT -p "${proto}" --dport "${port}" -j ACCEPT >/dev/null 2>&1 || true
            fi
            ;;
        nftables)
            set -- $(nft_input_chain)
            nft_family=$1
            nft_table=$2
            nft_chain=$3
            [ -n "${nft_family}" ] && [ -n "${nft_table}" ] && [ -n "${nft_chain}" ] || return 1
            nft_delete_managed_rules "${proto}" "${port}"
            nft insert rule "${nft_family}" "${nft_table}" "${nft_chain}" "${proto}" dport "${formatted_port}" accept comment "$(nft_rule_marker "${proto}" "${port}")" >/dev/null 2>&1 || return 1
            ;;
        *)
            return 1
            ;;
    esac

    echo "${backend}|${proto}|${port}" >> "${FIREWALL_STATE_FILE}"
}

firewall_remove_rule() {
    local backend=$1
    local proto=$2
    local port=$3
    local formatted_port

    formatted_port=$(firewall_port_for_backend "${backend}" "${port}")

    case "${backend}" in
        ufw)
            ufw --force delete allow "${formatted_port}/${proto}" >/dev/null 2>&1 || true
            ;;
        firewalld)
            firewall-cmd --permanent --remove-port="${formatted_port}/${proto}" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            ;;
        iptables)
            while iptables -D INPUT -p "${proto}" --dport "${port}" -j ACCEPT >/dev/null 2>&1; do :; done
            if command -v ip6tables >/dev/null 2>&1; then
                while ip6tables -D INPUT -p "${proto}" --dport "${port}" -j ACCEPT >/dev/null 2>&1; do :; done
            fi
            ;;
        nftables)
            nft_delete_managed_rules "${proto}" "${port}"
            ;;
    esac
}

firewall_port_status() {
    local backend=$1
    local proto=$2
    local port=$3
    local formatted_port

    formatted_port=$(firewall_port_for_backend "${backend}" "${port}")

    case "${backend}" in
        ufw)
            if ufw status 2>/dev/null | grep -F "${formatted_port}/${proto}" | grep -q "ALLOW"; then
                echo "已放行"
            else
                echo "未发现放行"
            fi
            ;;
        firewalld)
            if firewall-cmd --query-port="${formatted_port}/${proto}" >/dev/null 2>&1 || firewall-cmd --permanent --query-port="${formatted_port}/${proto}" >/dev/null 2>&1; then
                echo "已放行"
            else
                echo "未发现放行"
            fi
            ;;
        iptables)
            if iptables -C INPUT -p "${proto}" --dport "${port}" -j ACCEPT >/dev/null 2>&1; then
                echo "已放行"
            elif iptables -S INPUT 2>/dev/null | grep -q '^-P INPUT ACCEPT'; then
                echo "默认放行"
            else
                echo "未发现放行"
            fi
            ;;
        nftables)
            if nft list ruleset 2>/dev/null | grep -Fq "$(nft_rule_marker "${proto}" "${port}")"; then
                echo "已放行"
            elif nft list ruleset 2>/dev/null | grep -Eiq "${proto}[[:space:]]+dport[[:space:]]+(${formatted_port}|\\{[^}]*${formatted_port}[^}]*\\}).*accept"; then
                echo "已放行"
            else
                echo "未发现放行"
            fi
            ;;
        none)
            echo "未启用防火墙"
            ;;
        *)
            echo "未知"
            ;;
    esac
}

print_firewall_port_status() {
    local backend=$1
    local label=$2
    local proto=$3
    local port=$4
    local status color

    [ -z "${port}" ] && return

    status=$(firewall_port_status "${backend}" "${proto}" "${port}")
    case "${status}" in
        已放行|默认放行|未启用防火墙) color="${GREEN}" ;;
        未发现放行) color="${YELLOW}" ;;
        *) color="${GRAY}" ;;
    esac

    printf "  %-24s %-15s %b%s%b\n" "${label}" "${port}/${proto}" "${color}" "${status}" "${RESET}"
}

restore_managed_firewall_rules() {
    local backend proto port

    if [ -f "${FIREWALL_STATE_FILE}" ]; then
        while IFS='|' read -r backend proto port; do
            [ -n "${backend}" ] && firewall_remove_rule "${backend}" "${proto}" "${port}"
        done < "${FIREWALL_STATE_FILE}"
        rm -f "${FIREWALL_STATE_FILE}"
    fi

    disable_hy2_port_hopping_runtime
}

add_firewall_rule_once() {
    local backend=$1
    local proto=$2
    local port=$3
    local label=$4

    if firewall_add_rule "${backend}" "${proto}" "${port}"; then
        echo -e "${GREEN}已放行 ${label}: ${port}/${proto}${RESET}"
    else
        echo -e "${YELLOW}放行失败或不支持: ${label} ${port}/${proto}${RESET}"
    fi
}

apply_current_firewall_rules() {
    local backend reality_port hy2_current_port shadow_ports shadow_ssport shadow_sport

    ensure_state_dirs
    backend=$(detect_firewall_backend)

    if [ "${backend}" = "none" ]; then
        echo -e "${YELLOW}未检测到 ufw / firewalld / iptables，未修改防火墙。${RESET}"
        return
    fi

    restore_managed_firewall_rules
    : > "${FIREWALL_STATE_FILE}"

    echo -e "${CYAN}使用 ${backend} 自动放行当前协议端口...${RESET}"

    if [ -f "${REALITY_FRAGMENT_FILE}" ]; then
        reality_port=$(awk -F: '/"listen_port"/ { gsub(/[^0-9]/, "", $2); print $2; exit }' "${REALITY_FRAGMENT_FILE}")
        [ -n "${reality_port}" ] && add_firewall_rule_once "${backend}" "tcp" "${reality_port}" "Reality"
    fi

    if [ -f "${HY2_FRAGMENT_FILE}" ]; then
        if load_hy2_state >/dev/null 2>&1; then
            [ -n "${hy2_port}" ] && add_firewall_rule_once "${backend}" "udp" "${hy2_port}" "HY2"
            if [ "${hy2_hop_enabled}" = "true" ] && [ -n "${hy2_hop_range}" ]; then
                add_firewall_rule_once "${backend}" "udp" "${hy2_hop_range}" "HY2 端口跳跃范围"
                enable_hy2_port_hopping_runtime
                echo -e "${GREEN}HY2 端口跳跃重定向规则已应用${RESET}"
            fi
        fi
    fi

    if [ -f "${SHADOWTLS_FRAGMENT_FILE}" ]; then
        shadow_ports=$(awk -F: '/"listen_port"/ { gsub(/[^0-9]/, "", $2); ports[++i]=$2 } END { if (i >= 2) print ports[1], ports[2] }' "${SHADOWTLS_FRAGMENT_FILE}")
        set -- ${shadow_ports}
        shadow_ssport=$1
        shadow_sport=$2
        [ -n "${shadow_sport}" ] && add_firewall_rule_once "${backend}" "tcp" "${shadow_sport}" "ShadowTLS"
        if [ -n "${shadow_ssport}" ]; then
            add_firewall_rule_once "${backend}" "tcp" "${shadow_ssport}" "Shadowsocks"
            add_firewall_rule_once "${backend}" "udp" "${shadow_ssport}" "Shadowsocks"
        fi
    fi

    if [ ! -s "${FIREWALL_STATE_FILE}" ]; then
        rm -f "${FIREWALL_STATE_FILE}"
    fi
}

show_firewall_status() {
    local backend reality_port shadow_ports shadow_ssport shadow_sport printed_ports

    import_existing_protocols
    backend=$(detect_firewall_backend)
    echo -e "${CYAN}防火墙检测${RESET}"
    echo "后端: $(firewall_backend_label)"
    if [ -f "${FIREWALL_STATE_FILE}" ]; then
        echo -e "脚本管理规则: ${GREEN}已记录${RESET}"
        sed 's/^/  /' "${FIREWALL_STATE_FILE}"
    else
        echo -e "脚本管理规则: ${YELLOW}未记录${RESET}"
    fi

    if [ -f "${HY2_PORT_HOP_SYSTEMD_SERVICE}" ] || [ -f "${HY2_PORT_HOP_OPENRC_SERVICE}" ]; then
        echo -e "HY2 端口跳跃重定向: ${GREEN}已配置${RESET}"
    else
        echo -e "HY2 端口跳跃重定向: ${YELLOW}未配置${RESET}"
    fi

    echo ""
    echo -e "${CYAN}当前协议端口放行状态${RESET}"
    printed_ports=0

    if [ -f "${REALITY_FRAGMENT_FILE}" ]; then
        reality_port=$(awk -F: '/"listen_port"/ { gsub(/[^0-9]/, "", $2); print $2; exit }' "${REALITY_FRAGMENT_FILE}")
        print_firewall_port_status "${backend}" "Reality" "tcp" "${reality_port}"
        printed_ports=1
    fi

    if [ -f "${HY2_FRAGMENT_FILE}" ] && load_hy2_state >/dev/null 2>&1; then
        print_firewall_port_status "${backend}" "HY2" "udp" "${hy2_port}"
        printed_ports=1
        if [ "${hy2_hop_enabled}" = "true" ] && [ -n "${hy2_hop_range}" ]; then
            print_firewall_port_status "${backend}" "HY2 端口跳跃范围" "udp" "${hy2_hop_range}"
        fi
    fi

    if [ -f "${SHADOWTLS_FRAGMENT_FILE}" ]; then
        shadow_ports=$(awk -F: '/"listen_port"/ { gsub(/[^0-9]/, "", $2); ports[++i]=$2 } END { if (i >= 2) print ports[1], ports[2] }' "${SHADOWTLS_FRAGMENT_FILE}")
        set -- ${shadow_ports}
        shadow_ssport=$1
        shadow_sport=$2
        print_firewall_port_status "${backend}" "ShadowTLS" "tcp" "${shadow_sport}"
        print_firewall_port_status "${backend}" "Shadowsocks" "tcp" "${shadow_ssport}"
        print_firewall_port_status "${backend}" "Shadowsocks" "udp" "${shadow_ssport}"
        printed_ports=1
    fi

    if [ "${printed_ports}" -eq 0 ]; then
        echo -e "  ${YELLOW}当前没有已配置协议${RESET}"
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
    local uri_host
    uri_host=$(format_host_for_uri "${host_ip}")

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
        echo "Short ID  : ${short_id}"
        echo "指纹(fp)  : chrome"

        echo -e "\n${CYAN}=============== 通用分享链接 ===============${RESET}"
        echo -e "${YELLOW}vless://${uuid}@${uri_host}:${listen_port}?security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&flow=xtls-rprx-vision#${ip_country}-VLESS-Reality${RESET}"

        echo -e "\n${GREEN}=============== Sub-Store ===============${RESET}"
        echo -e "${YELLOW}${ip_country}-VLESS = VLESS,${host_ip},${listen_port},\"${uuid}\",transport=tcp,flow=xtls-rprx-vision,public-key=\"${public_key}\",short-id=${short_id},udp=true,block-quic=false,over-tls=true,sni=${sni}${RESET}"

        echo -e "\n${CYAN}=============== Clash Meta / Mihomo ===============${RESET}"
        cat << EOF
  - name: ${ip_country}-VLESS-Reality
    type: vless
    server: ${host_ip}
    port: ${listen_port}
    uuid: ${uuid}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${sni}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${public_key}
      short-id: ${short_id}
EOF

        echo -e "\n${CYAN}=============== Sing-box Outbound ===============${RESET}"
        cat << EOF
{
  "type": "vless",
  "tag": "${ip_country}-VLESS-Reality",
  "server": "${host_ip}",
  "server_port": ${listen_port},
  "uuid": "${uuid}",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "${sni}",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    },
    "reality": {
      "enabled": true,
      "public_key": "${public_key}",
      "short_id": "${short_id}"
    }
  }
}
EOF
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
    short_id=$(tr -dc 'a-f0-9' </dev/urandom | head -c 16)

    # 生成密钥对并提取公私钥
    keys=$(sing-box generate reality-keypair)
    private_key=$(echo "$keys" | grep "PrivateKey" | awk '{print $2}')
    public_key=$(echo "$keys" | grep "PublicKey" | awk '{print $2}')

    set_current_host_info

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
        "server": "${shadowtls_sni}",
        "server_port": 443
      },
      "strict_mode": true
    }
EOF
}

write_shadowtls_client() {
    local encoded_ss_password
    local encoded_plugin
    local uri_host

    encoded_ss_password=$(url_encode "${ss_password}")
    encoded_plugin=$(url_encode "shadow-tls;host=${shadowtls_sni};passwd=${password};v3")
    uri_host=$(format_host_for_uri "${host_ip}")

    {
        echo -e "${PURPLE}=============== 明文参数 ===============${RESET}"
        echo "节点类型        : ShadowTLS + Shadowsocks"
        echo "服务器IP        : ${host_ip}"
        echo "ShadowTLS 端口  : ${sport}"
        echo "Shadowsocks 端口: ${ssport}"
        echo "加密方法        : 2022-blake3-aes-128-gcm"
        echo "Shadowsocks 密码: ${ss_password}"
        echo "ShadowTLS 密码  : ${password}"
        echo "伪装域名        : ${shadowtls_sni}"
        echo "ShadowTLS 版本  : 3"
        echo "指纹(fp)        : chrome"

        echo -e "\n${CYAN}=============== 通用分享链接 ===============${RESET}"
        echo -e "${YELLOW}ss://2022-blake3-aes-128-gcm:${encoded_ss_password}@${uri_host}:${sport}/?plugin=${encoded_plugin}#${ip_country}-ShadowTLS${RESET}"

        echo -e "\n${GREEN}=============== Sub-Store ===============${RESET}"
        echo -e "${YELLOW}${ip_country}-ShadowTLS = Shadowsocks,${host_ip},${sport},2022-blake3-aes-128-gcm,\"${ss_password}\",shadow-tls-password=${password},shadow-tls-sni=${shadowtls_sni},shadow-tls-version=3,udp-port=${ssport},fast-open=false,udp=true${RESET}"

        echo -e "\n${CYAN}=============== Clash Meta / Mihomo ===============${RESET}"
        cat << EOF
  - name: ${ip_country}-ShadowTLS
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
      host: ${shadowtls_sni}
      password: ${password}
      version: 3
    smux:
      enabled: true
EOF

        echo -e "\n${CYAN}=============== Sing-box Outbound ===============${RESET}"
        cat << EOF
[
  {
    "type": "shadowsocks",
    "tag": "${ip_country}-ShadowTLS-SS",
    "server": "${host_ip}",
    "server_port": ${ssport},
    "method": "2022-blake3-aes-128-gcm",
    "password": "${ss_password}",
    "detour": "${ip_country}-ShadowTLS"
  },
  {
    "type": "shadowtls",
    "tag": "${ip_country}-ShadowTLS",
    "server": "${host_ip}",
    "server_port": ${sport},
    "version": 3,
    "password": "${password}",
    "tls": {
      "enabled": true,
      "server_name": "${shadowtls_sni}",
      "utls": {
        "enabled": true,
        "fingerprint": "chrome"
      }
    }
  }
]
EOF
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

    read -p "请输入 ShadowTLS 伪装域名 SNI (默认: www.bing.com): " shadowtls_sni
    shadowtls_sni=${shadowtls_sni:-www.bing.com}

    # 生成密码
    ss_password=$(sing-box generate rand 16 --base64)
    password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)

    set_current_host_info

    write_shadowtls_fragment
    write_shadowtls_client
    PROTOCOL_CHANGED=1
}

write_hy2_fragment() {
    cat > "${HY2_FRAGMENT_FILE}" << EOF
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${hy2_port},
      "up_mbps": ${hy2_up_mbps},
      "down_mbps": ${hy2_down_mbps},
      "obfs": {
        "type": "salamander",
        "password": "${hy2_obfs_password}"
      },
      "users": [
        {
          "name": "hy2",
          "password": "${hy2_password}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${hy2_sni}",
        "certificate_path": "${HY2_CERT_FILE}",
        "key_path": "${HY2_KEY_FILE}"
      }
    }
EOF
}

write_hy2_client() {
    local uri_host hy2_uri_port hy2_uri encoded_password encoded_obfs hop_range_dash hop_interval_seconds

    uri_host=$(format_host_for_uri "${host_ip}")
    encoded_password=$(url_encode "${hy2_password}")
    encoded_obfs=$(url_encode "${hy2_obfs_password}")
    hop_range_dash=$(range_colon_to_dash "${hy2_hop_range}")
    hop_interval_seconds=$(interval_to_seconds "${hy2_hop_interval}")

    if [ "${hy2_hop_enabled}" = "true" ]; then
        hy2_uri_port="${hop_range_dash}"
    else
        hy2_uri_port="${hy2_port}"
    fi

    hy2_uri="hysteria2://${encoded_password}@${uri_host}:${hy2_uri_port}/?insecure=1&obfs=salamander&obfs-password=${encoded_obfs}&sni=${hy2_sni}#${ip_country}-HY2"

    {
        echo -e "${PURPLE}=============== 明文参数 ===============${RESET}"
        echo "节点类型      : Hysteria2"
        echo "服务器IP      : ${host_ip}"
        echo "监听端口      : ${hy2_port}"
        echo "认证密码      : ${hy2_password}"
        echo "混淆类型      : salamander"
        echo "混淆密码      : ${hy2_obfs_password}"
        echo "SNI           : ${hy2_sni}"
        echo "TLS           : 自签证书，客户端需允许 insecure/跳过证书验证"
        echo "上行/下行     : ${hy2_up_mbps} Mbps / ${hy2_down_mbps} Mbps"
        if [ "${hy2_hop_enabled}" = "true" ]; then
            echo "端口跳跃      : 启用 (${hop_range_dash}, 间隔 ${hy2_hop_interval})"
        else
            echo "端口跳跃      : 未启用"
        fi

        echo -e "\n${CYAN}=============== 通用分享链接 ===============${RESET}"
        echo -e "${YELLOW}${hy2_uri}${RESET}"

        echo -e "\n${GREEN}=============== Sub-Store ===============${RESET}"
        echo -e "${YELLOW}${ip_country}-HY2=Hysteria2,${host_ip},${hy2_port},\"${hy2_password}\",tls-name=${hy2_sni},skip-cert-verify=true,salamander-password=${hy2_obfs_password},fast-open=false${RESET}"

        echo -e "\n${CYAN}=============== Clash Meta / Mihomo ===============${RESET}"
        cat << EOF
  - name: ${ip_country}-HY2
    type: hysteria2
    server: ${host_ip}
    port: ${hy2_port}
EOF
        if [ "${hy2_hop_enabled}" = "true" ]; then
            cat << EOF
    ports: ${hop_range_dash}
    hop-interval: ${hop_interval_seconds}
EOF
        fi
        cat << EOF
    password: ${hy2_password}
    up: "${hy2_up_mbps} Mbps"
    down: "${hy2_down_mbps} Mbps"
    obfs: salamander
    obfs-password: ${hy2_obfs_password}
    sni: ${hy2_sni}
    skip-cert-verify: true
    alpn:
      - h3
EOF

        echo -e "\n${CYAN}=============== Sing-box Outbound ===============${RESET}"
        cat << EOF
{
  "type": "hysteria2",
  "tag": "${ip_country}-HY2",
  "server": "${host_ip}",
EOF
        if [ "${hy2_hop_enabled}" = "true" ]; then
            cat << EOF
  "server_ports": [
    "${hy2_hop_range}"
  ],
  "hop_interval": "${hy2_hop_interval}",
EOF
        else
            cat << EOF
  "server_port": ${hy2_port},
EOF
        fi
        cat << EOF
  "up_mbps": ${hy2_up_mbps},
  "down_mbps": ${hy2_down_mbps},
  "obfs": {
    "type": "salamander",
    "password": "${hy2_obfs_password}"
  },
  "password": "${hy2_password}",
  "tls": {
    "enabled": true,
    "server_name": "${hy2_sni}",
    "insecure": true
  }
}
EOF
        echo -e "${GREEN}================================================================${RESET}"
    } > "${HY2_CLIENT_FILE}"
}

install_hy2_protocol() {
    local enable_hop

    if [ -f "${HY2_FRAGMENT_FILE}" ]; then
        echo -e "${YELLOW}Hysteria2 已存在，跳过安装${RESET}"
        return
    fi

    hy2_port=$(get_valid_port "请输入 Hysteria2 UDP 监听端口 (默认随机，回车确认): ")
    hy2_up_mbps=$(get_valid_mbps "请输入 HY2 上行带宽 Mbps (默认 100): " 100)
    hy2_down_mbps=$(get_valid_mbps "请输入 HY2 下行带宽 Mbps (默认 100): " 100)

    read -p "请输入 HY2 TLS SNI (默认: www.bing.com): " hy2_sni
    hy2_sni=${hy2_sni:-www.bing.com}

    read -p "是否启用 HY2 端口跳跃? (y/N): " enable_hop
    case "${enable_hop}" in
        y|Y)
            hy2_hop_enabled=true
            hy2_hop_range=$(get_valid_port_range "请输入端口跳跃范围 (默认 20000:50000): " "20000:50000")
            hy2_hop_interval=$(get_valid_interval "请输入端口跳跃间隔 (默认 30s，最小 5s): " "30s")
            ;;
        *)
            hy2_hop_enabled=false
            hy2_hop_range=""
            hy2_hop_interval="30s"
            ;;
    esac

    echo -e "${CYAN}正在生成 Hysteria2 密码...${RESET}"
    hy2_password=$(sing-box generate rand 16 --base64)
    hy2_obfs_password=$(sing-box generate rand 16 --base64)

    set_current_host_info
    generate_hy2_certificate
    write_hy2_state
    write_hy2_fragment
    write_hy2_client

    if [ "${hy2_hop_enabled}" = "true" ]; then
        echo -e "${YELLOW}已保存 HY2 端口跳跃配置，但未修改防火墙规则。需要时请在主菜单执行防火墙检测/自动放行。${RESET}"
    fi

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
            hy2)
                install_hy2_protocol
                ;;
        esac
    done

    if [ "${PROTOCOL_CHANGED}" -eq 1 ]; then
        render_config
        render_client_config
        reload_sing_box_service
        echo -e "${GREEN}sing-box 协议配置更新成功！${RESET}"
        echo ""
        show_client_summary
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
            restore_managed_firewall_rules

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
    [ -f "${REALITY_FRAGMENT_FILE}" ] || [ -f "${HY2_FRAGMENT_FILE}" ] || [ -f "${SHADOWTLS_FRAGMENT_FILE}" ]
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
            hy2)
                if [ -f "${HY2_FRAGMENT_FILE}" ]; then
                    disable_hy2_port_hopping_runtime
                    rm -f "${HY2_FRAGMENT_FILE}" "${HY2_CLIENT_FILE}" "${HY2_STATE_FILE}" "${HY2_CERT_FILE}" "${HY2_KEY_FILE}"
                    removed=1
                    echo -e "${GREEN}已删除 Hysteria2 协议配置${RESET}"
                else
                    echo -e "${YELLOW}Hysteria2 未安装，跳过删除${RESET}"
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
        show_client_summary
    else
        read -p "$(echo -e "${YELLOW}已没有剩余协议，是否同时卸载 sing-box 服务与配置? (Y/n) ${RESET}")" cleanup_choice
        cleanup_choice=${cleanup_choice:-Y}
        case "${cleanup_choice}" in
            y|Y)
                choice=Y
                echo -e "${CYAN}正在卸载 sing-box${RESET}"
                restore_managed_firewall_rules
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
strip_ansi() {
    sed "s/$(printf '\033')\\[[0-9;]*[A-Za-z]//g"
}

client_uri() {
    local file=$1
    local prefix=$2

    [ -f "${file}" ] || return
    strip_ansi < "${file}" | awk -v prefix="${prefix}" 'index($0, prefix) == 1 { print; exit }'
}

client_section_line() {
    local file=$1
    local section=$2

    [ -f "${file}" ] || return
    strip_ansi < "${file}" | awk -v section="${section}" '
        index($0, section) > 0 {
            in_section = 1
            next
        }
        in_section {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            if (line != "") {
                print line
                exit
            }
        }
    '
}

show_protocol_client_summary() {
    local name=$1
    local file=$2
    local uri_prefix=$3
    local uri sub_store

    [ -f "${file}" ] || return

    echo -e "${GREEN}${name}${RESET}"
    uri=$(client_uri "${file}" "${uri_prefix}")
    sub_store=$(client_section_line "${file}" "Sub-Store")

    if [ -n "${uri}" ]; then
        echo -e "  ${CYAN}分享链接${RESET}"
        echo "  ${uri}"
    fi
    if [ -n "${sub_store}" ]; then
        echo -e "  ${CYAN}Sub-Store${RESET}"
        echo "  ${sub_store}"
    fi
    echo ""
}

show_client_summary() {
    import_existing_protocols
    render_client_config

    if [ -f "${CLIENT_CONFIG_FILE}" ]; then
        clear
        echo -e "${CYAN}节点配置摘要${RESET}"
        echo -e "${GRAY}仅展示通用分享链接与 Sub-Store。完整 Clash / Sing-box 配置可在上一层选择“完整查看”。${RESET}"
        echo ""
        show_protocol_client_summary "VLESS Reality" "${REALITY_CLIENT_FILE}" "vless://"
        show_protocol_client_summary "Hysteria2" "${HY2_CLIENT_FILE}" "hysteria2://"
        show_protocol_client_summary "ShadowTLS + Shadowsocks" "${SHADOWTLS_CLIENT_FILE}" "ss://"
    else
        echo -e "${YELLOW}配置文件不存在: ${CLIENT_CONFIG_FILE}${RESET}"
    fi
}

show_full_client_config() {
    if [ -f "${CLIENT_CONFIG_FILE}" ]; then
        clear
        cat "${CLIENT_CONFIG_FILE}"
    else
        echo -e "${YELLOW}配置文件不存在: ${CLIENT_CONFIG_FILE}${RESET}"
    fi
}

client_config_menu() {
    import_existing_protocols
    render_client_config

    if [ ! -f "${CLIENT_CONFIG_FILE}" ]; then
        echo -e "${YELLOW}配置文件不存在: ${CLIENT_CONFIG_FILE}${RESET}"
        return
    fi

    menu_reset
    menu_add "1" "简洁查看" "按协议只展示通用分享链接和 Sub-Store，默认推荐。"
    menu_add "2" "完整查看" "显示原始完整配置，包含 Clash Meta、Sub-Store、Sing-box outbound 等全部片段。"
    menu_add "0" "返回主菜单" "不查看配置，回到主菜单。"
    interactive_select "请选择节点配置查看方式:"

    case "${MENU_CHOICE}" in
        1) show_client_summary ;;
        2) show_full_client_config ;;
        0)
            SKIP_PAUSE=1
            return
            ;;
    esac
}

# 更改 VLESS Reality 监听端口与伪装域名
change_reality_port() {
    local port_choice current_sni new_port new_sni tmp_file tmp_client_file

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

    current_sni=$(awk -F\" '/"server_name"[[:space:]]*:/ { print $4; exit }' "${REALITY_FRAGMENT_FILE}")
    current_sni=${current_sni:-www.yahoo.com}

    menu_reset
    menu_add "1" "更改 Reality 监听端口" "当前 Reality 端口: ${current_port}。只修改入站监听端口。"
    menu_add "2" "更改 Reality 伪装域名" "当前伪装域名: ${current_sni}。同步更新 Reality 握手域名和客户端配置。"
    menu_add "3" "同时更改端口和伪装域名" "同时修改 Reality 监听端口与伪装域名。"
    menu_add "0" "返回上级菜单" "不修改 Reality 配置。"
    interactive_select "请选择 Reality 修改方式:"
    port_choice="${MENU_CHOICE}"

    new_port=${current_port}
    new_sni=${current_sni}

    case "${port_choice}" in
        1)
            new_port=$(get_valid_port "请输入新的 VLESS 监听端口 (默认随机，回车确认): ")
            ;;
        2)
            read -p "请输入新的 Reality 伪装域名 SNI (默认: ${current_sni}): " new_sni
            new_sni=${new_sni:-${current_sni}}
            ;;
        3)
            new_port=$(get_valid_port "请输入新的 VLESS 监听端口 (默认随机，回车确认): ")
            read -p "请输入新的 Reality 伪装域名 SNI (默认: ${current_sni}): " new_sni
            new_sni=${new_sni:-${current_sni}}
            ;;
        0)
            SKIP_PAUSE=1
            return
            ;;
        *)
            echo -e "${RED}无效的选项，已取消修改${RESET}"
            return
            ;;
    esac

    if [ "${new_port}" = "${current_port}" ] && [ "${new_sni}" = "${current_sni}" ]; then
        echo -e "${YELLOW}配置未变化，已取消修改${RESET}"
        return
    fi

    tmp_file="${REALITY_FRAGMENT_FILE}.tmp"
    if ! awk -v new_port="${new_port}" -v new_sni="${new_sni}" '
        /"listen_port"/ && changed == 0 {
            sub(/"listen_port"[[:space:]]*:[[:space:]]*[0-9]+/, "\"listen_port\": " new_port)
            changed = 1
        }
        /"server_name"[[:space:]]*:/ && server_name_changed == 0 {
            sub(/"server_name"[[:space:]]*:[[:space:]]*"[^"]+"/, "\"server_name\": \"" new_sni "\"")
            server_name_changed = 1
        }
        /"server"[[:space:]]*:/ && handshake_changed == 0 {
            sub(/"server"[[:space:]]*:[[:space:]]*"[^"]+"/, "\"server\": \"" new_sni "\"")
            handshake_changed = 1
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
        if ! awk \
            -v old_port="${current_port}" \
            -v new_port="${new_port}" \
            -v old_sni="${current_sni}" \
            -v new_sni="${new_sni}" '
            {
                sub("监听端口[[:space:]]*:[[:space:]]*" old_port, "监听端口  : " new_port)
                sub("伪装域名[[:space:]]*:[[:space:]]*" old_sni, "伪装域名  : " new_sni)
                gsub(":" old_port, ":" new_port)
                gsub("," old_port ",", "," new_port ",")
                gsub("sni=" old_sni, "sni=" new_sni)
                gsub("servername: " old_sni, "servername: " new_sni)
                gsub("\"server_name\": \"" old_sni "\"", "\"server_name\": \"" new_sni "\"")
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
        echo -e "${GREEN}Reality 伪装域名已从 ${current_sni} 修改为 ${new_sni}${RESET}"
        show_client_summary
    else
        echo -e "${RED}端口已写入配置，但 ${SERVICE_NAME} 服务未成功运行，请查看状态或日志${RESET}"
    fi
}

# 更改 ShadowTLS / Shadowsocks 监听端口与伪装域名
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
    current_sni=$(awk -F\" '/"server"[[:space:]]*:/ { print $4; exit }' "${SHADOWTLS_FRAGMENT_FILE}")
    current_sni=${current_sni:-www.bing.com}

    if [ -z "${current_ssport}" ] || [ -z "${current_sport}" ]; then
        echo -e "${RED}无法从配置文件中读取当前监听端口${RESET}"
        return
    fi

    menu_reset
    menu_add "1" "更改 ShadowTLS 端口" "当前 ShadowTLS 端口: ${current_sport}。只修改外层 ShadowTLS 入口。"
    menu_add "2" "更改 Shadowsocks 端口" "当前 Shadowsocks 端口: ${current_ssport}。只修改内层 Shadowsocks 入口。"
    menu_add "3" "同时更改两个端口" "当前 ShadowTLS: ${current_sport}，Shadowsocks: ${current_ssport}。"
    menu_add "4" "更改 ShadowTLS 伪装域名" "当前伪装域名: ${current_sni}。同步更新服务端握手和客户端配置。"
    menu_add "5" "同时更改端口和伪装域名" "同时修改 ShadowTLS / Shadowsocks 端口与伪装域名。"
    menu_add "0" "返回上级菜单" "不修改 ShadowTLS / Shadowsocks 配置。"
    interactive_select "请选择 ShadowTLS 端口修改方式:"
    port_choice="${MENU_CHOICE}"

    new_sport=${current_sport}
    new_ssport=${current_ssport}
    new_sni=${current_sni}

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
        4)
            read -p "请输入新的 ShadowTLS 伪装域名 SNI (默认: ${current_sni}): " new_sni
            new_sni=${new_sni:-${current_sni}}
            ;;
        5)
            new_sport=$(get_valid_port "请输入新的 ShadowTLS 监听端口 (默认随机，回车确认): ")
            new_ssport=$(get_valid_port "请输入新的 Shadowsocks 监听端口 (默认随机，回车确认): ")
            read -p "请输入新的 ShadowTLS 伪装域名 SNI (默认: ${current_sni}): " new_sni
            new_sni=${new_sni:-${current_sni}}
            ;;
        0)
            SKIP_PAUSE=1
            return
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

    if [ "${new_sport}" = "${current_sport}" ] && [ "${new_ssport}" = "${current_ssport}" ] && [ "${new_sni}" = "${current_sni}" ]; then
        echo -e "${YELLOW}配置未变化，已取消修改${RESET}"
        return
    fi

    tmp_file="${SHADOWTLS_FRAGMENT_FILE}.tmp"
    if ! awk -v new_ssport="${new_ssport}" -v new_sport="${new_sport}" -v new_sni="${new_sni}" '
        /"listen_port"/ {
            count++
            if (count == 1) {
                sub(/"listen_port"[[:space:]]*:[[:space:]]*[0-9]+/, "\"listen_port\": " new_ssport)
            } else if (count == 2) {
                sub(/"listen_port"[[:space:]]*:[[:space:]]*[0-9]+/, "\"listen_port\": " new_sport)
            }
        }
        /"server"[[:space:]]*:/ && sni_changed == 0 {
            sub(/"server"[[:space:]]*:[[:space:]]*"[^"]+"/, "\"server\": \"" new_sni "\"")
            sni_changed = 1
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
            -v new_ssport="${new_ssport}" \
            -v old_sni="${current_sni}" \
            -v new_sni="${new_sni}" '
            {
                sub("ShadowTLS 端口[[:space:]]*:[[:space:]]*" old_sport, "ShadowTLS 端口  : " new_sport)
                sub("Shadowsocks 端口:[[:space:]]*" old_ssport, "Shadowsocks 端口: " new_ssport)
                sub("伪装域名[[:space:]]*:[[:space:]]*" old_sni, "伪装域名        : " new_sni)
                sub("port: " old_sport "$", "port: " new_sport)
                sub("server_port: " old_sport, "server_port: " new_sport)
                gsub(":" old_sport "/[?]plugin=", ":" new_sport "/?plugin=")
                gsub(":" old_ssport "#", ":" new_ssport "#")
                gsub("," old_sport ",2022-blake3-aes-128-gcm", "," new_sport ",2022-blake3-aes-128-gcm")
                gsub("udp-port=" old_ssport, "udp-port=" new_ssport)
                gsub("host=" old_sni, "host=" new_sni)
                gsub("shadow-tls-sni=" old_sni, "shadow-tls-sni=" new_sni)
                gsub("host: " old_sni, "host: " new_sni)
                gsub("\"server_name\": \"" old_sni "\"", "\"server_name\": \"" new_sni "\"")
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
        echo -e "${GREEN}ShadowTLS 伪装域名已从 ${current_sni} 修改为 ${new_sni}${RESET}"
        show_client_summary
    else
        echo -e "${RED}端口已写入配置，但 ${SERVICE_NAME} 服务未成功运行，请查看状态或日志${RESET}"
    fi
}

# 更改 Hysteria2 监听端口、TLS SNI 与端口跳跃
change_hy2_port() {
    local port_choice enable_hop old_port old_sni old_hop_enabled old_hop_range old_hop_interval regen_hy2_cert

    import_existing_protocols

    if [ ! -f "${HY2_FRAGMENT_FILE}" ]; then
        echo -e "${RED}Hysteria2 尚未安装${RESET}"
        return
    fi

    load_hy2_state || return
    check_ss_command

    old_port=${hy2_port}
    old_sni=${hy2_sni:-www.bing.com}
    hy2_sni=${old_sni}
    old_hop_enabled=${hy2_hop_enabled}
    old_hop_range=${hy2_hop_range}
    old_hop_interval=${hy2_hop_interval}

    menu_reset
    if [ "${hy2_hop_enabled}" = "true" ]; then
        menu_add "1" "更改 HY2 监听端口" "当前监听端口: ${hy2_port}；端口跳跃已启用，范围 $(range_colon_to_dash "${hy2_hop_range}")，间隔 ${hy2_hop_interval}。"
        menu_add "2" "更改 HY2 TLS SNI" "当前 SNI: ${hy2_sni}。同步更新证书、服务端和客户端配置。"
        menu_add "3" "配置 HY2 端口跳跃" "当前端口跳跃: 启用，范围 $(range_colon_to_dash "${hy2_hop_range}")，间隔 ${hy2_hop_interval}。"
        menu_add "4" "同时更改端口、SNI 与端口跳跃" "先修改监听端口和 SNI，再重新配置端口跳跃。"
    else
        menu_add "1" "更改 HY2 监听端口" "当前监听端口: ${hy2_port}；端口跳跃未启用。"
        menu_add "2" "更改 HY2 TLS SNI" "当前 SNI: ${hy2_sni}。同步更新证书、服务端和客户端配置。"
        menu_add "3" "配置 HY2 端口跳跃" "当前端口跳跃: 未启用。可开启并设置跳跃范围与间隔。"
        menu_add "4" "同时更改端口、SNI 与端口跳跃" "先修改监听端口和 SNI，再设置是否启用端口跳跃。"
    fi
    menu_add "0" "返回上级菜单" "不修改 HY2 配置。"
    interactive_select "请选择 HY2 修改方式:"
    port_choice="${MENU_CHOICE}"

    case "${port_choice}" in
        1)
            hy2_port=$(get_valid_port "请输入新的 HY2 UDP 监听端口 (默认随机，回车确认): ")
            ;;
        2)
            read -p "请输入新的 HY2 TLS SNI (默认: ${hy2_sni}): " hy2_sni
            hy2_sni=${hy2_sni:-${old_sni}}
            ;;
        3)
            ;;
        4)
            hy2_port=$(get_valid_port "请输入新的 HY2 UDP 监听端口 (默认随机，回车确认): ")
            read -p "请输入新的 HY2 TLS SNI (默认: ${hy2_sni}): " hy2_sni
            hy2_sni=${hy2_sni:-${old_sni}}
            ;;
        0)
            SKIP_PAUSE=1
            return
            ;;
        *)
            echo -e "${RED}无效的选项，已取消修改${RESET}"
            return
            ;;
    esac

    if [ "${port_choice}" = "3" ] || [ "${port_choice}" = "4" ]; then
        menu_reset
        menu_add "1" "启用 / 更新端口跳跃" "只保存 UDP 端口范围与跳跃间隔，不自动修改防火墙规则。"
        menu_add "2" "关闭端口跳跃" "只更新 HY2 配置状态，不自动修改防火墙规则。"
        menu_add "0" "取消修改" "不改变当前端口跳跃配置。"
        interactive_select "请选择 HY2 端口跳跃状态:"
        enable_hop="${MENU_CHOICE}"
        case "${enable_hop}" in
            1)
                hy2_hop_enabled=true
                hy2_hop_range=$(get_valid_port_range "请输入端口跳跃范围 (默认 20000:50000): " "${hy2_hop_range:-20000:50000}")
                hy2_hop_interval=$(get_valid_interval "请输入端口跳跃间隔 (默认 30s，最小 5s): " "${hy2_hop_interval:-30s}")
                ;;
            2)
                hy2_hop_enabled=false
                hy2_hop_range=""
                hy2_hop_interval="30s"
                ;;
            0)
                hy2_port=${old_port}
                hy2_sni=${old_sni}
                hy2_hop_enabled=${old_hop_enabled}
                hy2_hop_range=${old_hop_range}
                hy2_hop_interval=${old_hop_interval}
                SKIP_PAUSE=1
                return
                ;;
        esac
    fi

    if [ "${hy2_port}" = "${old_port}" ] &&
        [ "${hy2_sni}" = "${old_sni}" ] &&
        [ "${hy2_hop_enabled}" = "${old_hop_enabled}" ] &&
        [ "${hy2_hop_range}" = "${old_hop_range}" ] &&
        [ "${hy2_hop_interval}" = "${old_hop_interval}" ]; then
        echo -e "${YELLOW}配置未变化，已取消修改${RESET}"
        return
    fi

    set_current_host_info
    regen_hy2_cert=0
    if [ "${hy2_sni}" != "${old_sni}" ]; then
        regen_hy2_cert=1
        rm -f "${HY2_CERT_FILE}" "${HY2_KEY_FILE}"
    fi
    generate_hy2_certificate
    write_hy2_state
    write_hy2_fragment
    write_hy2_client

    echo -e "${YELLOW}HY2 配置已更新，但未修改防火墙规则。需要时请在主菜单执行防火墙检测/自动放行。${RESET}"

    render_config
    render_client_config
    restart_sing_box
    if is_sing_box_running; then
        echo -e "${GREEN}Hysteria2 配置已更新${RESET}"
        if [ "${regen_hy2_cert}" -eq 1 ]; then
            echo -e "${GREEN}HY2 TLS SNI 已从 ${old_sni} 修改为 ${hy2_sni}，证书已重新生成${RESET}"
        fi
        show_client_summary
    else
        echo -e "${RED}配置已写入，但 ${SERVICE_NAME} 服务未成功运行，请查看状态或日志${RESET}"
    fi
}

protocol_status_text() {
    if "$1"; then
        echo -e "${GREEN}已配置${RESET}"
    else
        echo -e "${RED}未配置${RESET}"
    fi
}

build_state_panel_cache() {
    local os_text core_text service_text protocol_text firewall_text

    if [ "$IS_ALPINE" -eq 1 ]; then
        os_text="${YELLOW}Alpine Linux / OpenRC${RESET}"
    else
        os_text="${YELLOW}Standard Linux / systemd${RESET}"
    fi

    if [ ${sing_box_installed} -eq 0 ]; then
        core_text="${GREEN}已安装${RESET}"
    else
        core_text="${RED}未安装${RESET}"
    fi

    if [ ${sing_box_running} -eq 0 ]; then
        service_text="${GREEN}运行中${RESET}"
    else
        service_text="${YELLOW}未运行${RESET}"
    fi

    protocol_text="Reality $(protocol_status_text has_reality_protocol) | HY2 $(protocol_status_text has_hy2_protocol) | ShadowTLS $(protocol_status_text has_shadowtls_protocol)"
    firewall_text="$(firewall_backend_label)"

    STATE_PANEL_TEXT=$(cat << EOF
系统: ${os_text}
核心: ${core_text}  服务: ${service_text}
协议: ${protocol_text}
防火墙: ${firewall_text}

$(show_startup_ip_info)
EOF
)
}

show_state_panel() {
    if [ -n "${STATE_PANEL_TEXT:-}" ]; then
        echo -e "${STATE_PANEL_TEXT}"
        return
    fi

    build_state_panel_cache
    echo -e "${STATE_PANEL_TEXT}"
}

draw_menu_header() {
    show_state_panel
    echo ""
}

menu_reset() {
    MENU_NUMBERS=()
    MENU_ACTIONS=()
    MENU_LABELS=()
    MENU_DESCS=()
    MENU_COUNT=0
}

menu_add() {
    MENU_NUMBERS+=("$1")
    MENU_LABELS+=("$2")
    MENU_DESCS+=("$3")
    MENU_ACTIONS+=("${4:-$1}")
    MENU_COUNT=$((MENU_COUNT + 1))
}

menu_add_auto() {
    menu_add "${MENU_NEXT_NUMBER}" "$1" "$2" "$3"
    MENU_NEXT_NUMBER=$((MENU_NEXT_NUMBER + 1))
}

menu_index_by_number() {
    local number=$1
    local i

    for ((i = 0; i < MENU_COUNT; i++)); do
        if [ "${MENU_NUMBERS[$i]}" = "${number}" ]; then
            echo "${i}"
            return 0
        fi
    done

    return 1
}

render_menu_screen() {
    local title=$1
    local selected=$2
    local i prefix label_color

    if [ "${MENU_SCREEN_READY:-0}" -eq 1 ]; then
        printf '\033[H'
    else
        clear
        MENU_SCREEN_READY=1
    fi

    draw_menu_header
    echo -e "${YELLOW}${title}${RESET}"
    echo ""

    for ((i = 0; i < MENU_COUNT; i++)); do
        prefix=" "
        label_color="${RESET}"
        if [ "${i}" -eq "${selected}" ]; then
            prefix="${YELLOW}>${RESET}"
            label_color="${GREEN}"
        fi

        printf "%b %2s. %b%s%b\n" "${prefix}" "${MENU_NUMBERS[$i]}" "${label_color}" "${MENU_LABELS[$i]}" "${RESET}"
    done

    echo ""
    echo -e "${YELLOW}当前选项说明${RESET}"
    echo -e "${GRAY}-----------------------------------------------------${RESET}"
    echo -e " ${MENU_DESCS[$selected]}"
    echo -e "${GRAY}-----------------------------------------------------${RESET}"
    echo -e "${GRAY}↑/↓/j/k 移动   Enter/Space 确认   数字 快速选择   Esc/q 返回/退出${RESET}"
    printf '\033[J'
}

interactive_select() {
    local title=$1
    local selected=0
    local key rest next digits idx

    MENU_SCREEN_READY=0
    printf '\033[?25l'
    while true; do
        render_menu_screen "${title}" "${selected}"
        IFS= read -rsn1 key

        if [ -z "${key}" ] || [ "${key}" = " " ]; then
            MENU_CHOICE="${MENU_ACTIONS[$selected]}"
            printf '\033[?25h'
            return
        fi

        case "${key}" in
            $'\x1b')
                rest=""
                IFS= read -rsn2 -t 0.1 rest || true
                case "${rest}" in
                    "[A")
                        selected=$((selected - 1))
                        [ "${selected}" -lt 0 ] && selected=$((MENU_COUNT - 1))
                        ;;
                    "[B")
                        selected=$((selected + 1))
                        [ "${selected}" -ge "${MENU_COUNT}" ] && selected=0
                        ;;
                    *)
                        MENU_CHOICE="0"
                        printf '\033[?25h'
                        return
                        ;;
                esac
                ;;
            j|J)
                selected=$((selected + 1))
                [ "${selected}" -ge "${MENU_COUNT}" ] && selected=0
                ;;
            k|K)
                selected=$((selected - 1))
                [ "${selected}" -lt 0 ] && selected=$((MENU_COUNT - 1))
                ;;
            q|Q)
                MENU_CHOICE="0"
                printf '\033[?25h'
                return
                ;;
            [0-9])
                digits="${key}"
                if IFS= read -rsn1 -t 0.35 next && [[ "${next}" =~ ^[0-9]$ ]]; then
                    digits="${digits}${next}"
                fi

                idx=$(menu_index_by_number "${digits}" || true)
                if [ -n "${idx}" ]; then
                    MENU_CHOICE="${MENU_ACTIONS[$idx]}"
                    printf '\033[?25h'
                    return
                fi
                ;;
        esac
    done
}

# 显示菜单
show_menu() {
    load_startup_ip_info
    import_existing_protocols
    is_sing_box_installed
    sing_box_installed=$?
    is_sing_box_running
    sing_box_running=$?
    build_state_panel_cache

    menu_reset
    MENU_NEXT_NUMBER=1
    if [ ${sing_box_installed} -ne 0 ]; then
        menu_add_auto "一键安装 Reality + HY2 + ShadowTLS" "推荐首次部署。自动安装 sing-box，依次配置三个协议，并在完成后输出全部节点。" "install_all"
        menu_add_auto "仅安装 VLESS Reality" "只部署 Reality，适合需要稳定 TCP + Reality 伪装的场景。" "install_reality"
        menu_add_auto "仅安装 Hysteria2" "只部署 HY2，可在安装流程中选择是否启用 UDP 端口跳跃。" "install_hy2"
        menu_add_auto "仅安装 ShadowTLS" "只部署 ShadowTLS + Shadowsocks，兼容已有 ShadowTLS 客户端配置。" "install_shadowtls"
        menu_add "0" "退出程序" "不执行任何操作，直接退出。" "exit"
        interactive_select "请选择安装方案:"
    else
        if ! has_all_protocols; then
            menu_add_auto "一键补齐缺失协议" "只安装当前缺失的协议；已存在的协议会自动跳过，不重复覆盖。" "install_all"
            if ! has_reality_protocol; then
                menu_add_auto "安装 VLESS Reality" "新增 Reality 协议，适合稳定 TCP + Reality 伪装场景。" "install_reality"
            fi
            if ! has_hy2_protocol; then
                menu_add_auto "安装 Hysteria2" "新增 HY2 协议，并可选择配置 UDP 端口跳跃。" "install_hy2"
            fi
            if ! has_shadowtls_protocol; then
                menu_add_auto "安装 ShadowTLS" "新增 ShadowTLS + Shadowsocks 协议。" "install_shadowtls"
            fi
        fi

        menu_add_auto "查看节点链接配置" "默认进入简洁摘要；完整 Clash / Sing-box / Sub-Store 配置可在二级菜单打开。" "view_config"
        if [ ${sing_box_running} -eq 0 ]; then
            menu_add_auto "停止 sing-box 服务" "停止正在运行的 sing-box 服务。" "toggle_service"
        else
            menu_add_auto "启动 sing-box 服务" "启动已安装的 sing-box 服务。" "toggle_service"
        fi
        menu_add_auto "重启 sing-box 服务" "重新加载服务，适合手动调整配置后使用。" "restart"
        menu_add_auto "查看 sing-box 状态" "调用系统服务管理器查看 sing-box 当前运行状态。" "status"
        menu_add_auto "查看 sing-box 日志" "实时跟踪 sing-box 日志，按 Ctrl+C 退出日志查看。" "logs"
        menu_add_auto "修改端口 / HY2 端口跳跃" "修改 Reality、HY2、ShadowTLS 端口，或重新配置 HY2 端口跳跃。" "change_ports"
        menu_add_auto "防火墙检测 / 自动放行" "检测防火墙后端，或手动放行当前协议端口；安装和改端口不会自动修改防火墙。" "firewall"
        menu_add_auto "删除指定协议" "选择并删除某个协议；如果没有剩余协议，会询问是否同时卸载。" "remove_protocol"
        menu_add_auto "完全卸载 sing-box" "停止服务并删除 sing-box、配置目录、日志和 HY2 端口跳跃规则。" "uninstall"
        menu_add "0" "退出程序" "不执行任何操作，直接退出。" "exit"
        interactive_select "请选择操作:"
    fi

    choice="${MENU_CHOICE}"
    echo ""
}

change_ports_menu() {
    menu_reset
    menu_add "1" "VLESS Reality 端口 / 伪装域名" "修改 Reality 入站监听端口或伪装域名，并同步更新客户端分享信息。"
    menu_add "2" "Hysteria2 端口 / SNI / 端口跳跃" "修改 HY2 UDP 监听端口、TLS SNI，或开启、关闭、调整端口跳跃范围。"
    menu_add "3" "ShadowTLS 端口 / 伪装域名" "修改 ShadowTLS 外层端口、Shadowsocks 内层端口或 ShadowTLS 伪装域名。"
    menu_add "0" "返回主菜单" "不修改端口，回到主菜单。"
    interactive_select "请选择要修改的协议:"
    change_choice="${MENU_CHOICE}"
    echo ""

    case "${change_choice}" in
        1) change_reality_port ;;
        2) change_hy2_port ;;
        3) change_shadowtls_port ;;
        0)
            SKIP_PAUSE=1
            return
            ;;
        *) echo -e "${RED}无效的选项，已返回主菜单${RESET}" ;;
    esac
}

remove_protocols_menu() {
    menu_reset
    menu_add "1" "删除 VLESS Reality" "删除 Reality 服务端片段和对应客户端信息。"
    menu_add "2" "删除 Hysteria2" "删除 HY2 配置、证书、客户端信息，并清理端口跳跃规则。"
    menu_add "3" "删除 ShadowTLS" "删除 ShadowTLS + Shadowsocks 入站片段和客户端信息。"
    menu_add "4" "删除全部协议" "删除 Reality、HY2、ShadowTLS；若无剩余协议，会继续询问是否卸载核心。"
    menu_add "0" "返回主菜单" "不删除任何协议，回到主菜单。"
    interactive_select "请选择要删除的协议:"
    remove_choice="${MENU_CHOICE}"
    echo ""

    case "${remove_choice}" in
        1) remove_protocols reality ;;
        2) remove_protocols hy2 ;;
        3) remove_protocols shadowtls ;;
        4) remove_protocols reality hy2 shadowtls ;;
        0)
            SKIP_PAUSE=1
            return
            ;;
        *) echo -e "${RED}无效的选项，已返回主菜单${RESET}" ;;
    esac
}

firewall_menu() {
    while true; do
        menu_reset
        menu_add "1" "检测当前防火墙状态" "读取当前防火墙后端、脚本管理记录，并逐项检查已配置协议端口是否放行。"
        menu_add "2" "自动放行当前协议端口" "按当前 Reality / HY2 / ShadowTLS 配置放行端口；若 HY2 启用端口跳跃，也会应用跳跃重定向规则。"
        menu_add "3" "复原脚本管理的防火墙规则" "删除本脚本自动放行的端口规则，并移除 HY2 端口跳跃重定向服务。"
        menu_add "0" "返回主菜单" "不修改防火墙，回到主菜单。"
        interactive_select "请选择防火墙操作:"

        case "${MENU_CHOICE}" in
            1)
                show_firewall_status
                read -p "按 Enter 键返回防火墙菜单..."
                ;;
            2)
                apply_current_firewall_rules
                read -p "按 Enter 键返回防火墙菜单..."
                ;;
            3)
                restore_managed_firewall_rules
                echo -e "${GREEN}已复原脚本管理的防火墙规则${RESET}"
                read -p "按 Enter 键返回防火墙菜单..."
                ;;
            0)
                SKIP_PAUSE=1
                return
                ;;
        esac
    done
}

# 捕获 Ctrl+C 信号
trap 'printf "\033[?25h"; echo -e "\n${RED}已取消操作${RESET}"; exit' INT

# 主循环
check_root

while true; do
    SKIP_PAUSE=0
    show_menu
    case "${choice}" in
        install_all)
            install_protocols reality hy2 shadowtls
            ;;
        install_reality)
            install_protocols reality
            ;;
        install_hy2)
            install_protocols hy2
            ;;
        install_shadowtls)
            install_protocols shadowtls
            ;;
        view_config)
            if [ ${sing_box_installed} -eq 0 ]; then
                client_config_menu
            else
                echo -e "${YELLOW}当前未安装 sing-box，请先选择 1-4 完成安装。${RESET}"
            fi
            ;;
        toggle_service)
            if [ ${sing_box_installed} -eq 0 ]; then
                if [ ${sing_box_running} -eq 0 ]; then
                    stop_sing_box
                else
                    start_sing_box
                fi
            else
                echo -e "${YELLOW}当前未安装 sing-box，请先选择 1-4 完成安装。${RESET}"
            fi
            ;;
        restart)
            if [ ${sing_box_installed} -eq 0 ]; then
                restart_sing_box
            else
                echo -e "${YELLOW}当前未安装 sing-box，请先选择 1-4 完成安装。${RESET}"
            fi
            ;;
        status)
            if [ ${sing_box_installed} -eq 0 ]; then
                status_sing_box
            else
                echo -e "${YELLOW}当前未安装 sing-box，请先选择 1-4 完成安装。${RESET}"
            fi
            ;;
        logs)
            if [ ${sing_box_installed} -eq 0 ]; then
                log_sing_box
            else
                echo -e "${YELLOW}当前未安装 sing-box，请先选择 1-4 完成安装。${RESET}"
            fi
            ;;
        change_ports)
            if [ ${sing_box_installed} -eq 0 ]; then
                change_ports_menu
            else
                echo -e "${YELLOW}当前未安装 sing-box，请先选择 1-4 完成安装。${RESET}"
            fi
            ;;
        firewall)
            if [ ${sing_box_installed} -eq 0 ]; then
                firewall_menu
            else
                echo -e "${YELLOW}当前未安装 sing-box，请先选择 1-4 完成安装。${RESET}"
            fi
            ;;
        remove_protocol)
            if [ ${sing_box_installed} -eq 0 ]; then
                remove_protocols_menu
            else
                echo -e "${YELLOW}当前未安装 sing-box，请先选择 1-4 完成安装。${RESET}"
            fi
            ;;
        uninstall)
            if [ ${sing_box_installed} -eq 0 ]; then
                uninstall_sing_box
            else
                echo -e "${YELLOW}当前未安装 sing-box，请先选择 1-4 完成安装。${RESET}"
            fi
            ;;
        0|exit)
            echo -e "${GREEN}已退出 sing-box 管理工具${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选项，请重新选择${RESET}"
            ;;
    esac
    if [ "${SKIP_PAUSE:-0}" -eq 0 ]; then
        read -p "按 Enter 键继续..."
    fi
done
