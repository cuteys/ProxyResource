#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
RESET='\033[0m'

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
SNELL_FRAGMENT_FILE="${PROTOCOL_DIR}/snell.json"
SNELL_STATE_FILE="${PROTOCOL_DIR}/snell.env"
UPSTREAM_OUTBOUND_FILE="${CONFIG_DIR}/upstream-outbound.env"
UPSTREAM_OUTBOUND_TAG="upstream-out"
LOG_STATE_FILE="${CONFIG_DIR}/log.env"
REALITY_CLIENT_FILE="${CLIENT_DIR}/reality.txt"
SHADOWTLS_CLIENT_FILE="${CLIENT_DIR}/shadowtls.txt"
HY2_CLIENT_FILE="${CLIENT_DIR}/hy2.txt"
SNELL_CLIENT_FILE="${CLIENT_DIR}/snell.txt"
VLESSWS_FRAGMENT_FILE="${PROTOCOL_DIR}/vlessws.json"
VLESSWS_STATE_FILE="${PROTOCOL_DIR}/vlessws.env"
VLESSWS_CLIENT_FILE="${CLIENT_DIR}/vlessws.txt"
VLESSWS_CERT_RESCUE_DIR="/var/lib/sing-box-certs-rescue"
VLESSWS_CERT_RESCUE_LIST="${VLESSWS_CERT_RESCUE_DIR}/protected-paths.list"
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

IS_ALPINE=0
if [ -f /etc/alpine-release ]; then
    IS_ALPINE=1
fi

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请使用 root 权限执行此脚本！${RESET}" >&2
        exit 1
    fi
}

is_sing_box_installed() {
    command -v sing-box >/dev/null 2>&1
}

is_sing_box_running() {
    if [ "${IS_ALPINE}" -eq 1 ]; then
        rc-service "${SERVICE_NAME}" status >/dev/null 2>&1
    else
        systemctl is-active --quiet "${SERVICE_NAME}"
    fi
}

check_time_sync() {
    local sync_answer

    if [ "${IS_ALPINE}" -eq 1 ]; then
        if ! command -v chronyd >/dev/null 2>&1 && ! command -v ntpd >/dev/null 2>&1; then
            echo -e "${YELLOW}提示：未检测到时间同步服务，Reality 对时间要求严格，建议安装 chrony 并保持运行${RESET}" >&2
        fi
        return
    fi
    if ! command -v timedatectl >/dev/null 2>&1; then
        echo -e "${YELLOW}提示：未找到 timedatectl，请自行确认系统时间同步已开启${RESET}" >&2
        return
    fi
    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]; then
        echo -e "${YELLOW}警告：系统时间未与网络同步，Reality 握手与防探测都依赖准确时间${RESET}" >&2
        read -r -p "是否立即开启自动校时? (y/N): " sync_answer
        case "${sync_answer}" in
            [yY]|[yY][eE][sS])
                if timedatectl set-ntp true; then
                    echo -e "${GREEN}自动校时已开启${RESET}"
                else
                    echo -e "${RED}开启失败，请手动执行: timedatectl set-ntp true${RESET}" >&2
                fi
                ;;
            *)
                echo -e "${YELLOW}已跳过，可稍后手动执行: timedatectl set-ntp true${RESET}"
                ;;
        esac
    fi
}

# 统一各发行版包管理安装流程并在特权环境下省略提权前缀
install_system_package() {
    local debian_pkg=$1
    local rhel_pkg=${2:-$1}
    local alpine_update=${3:-0}
    local manual_hint=${4:-$1}

    if [ "${IS_ALPINE}" -eq 1 ]; then
        if [ "${alpine_update}" -eq 1 ]; then
            apk update && apk add "${debian_pkg}"
        else
            apk add "${debian_pkg}"
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y "${debian_pkg}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${rhel_pkg}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${rhel_pkg}"
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm "${debian_pkg}"
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y "${debian_pkg}"
    else
        echo -e "${RED}无法检测到支持的包管理器，请手动安装 ${manual_hint}${RESET}" >&2
        exit 1
    fi
}

check_ss_command() {
    if ! command -v ss >/dev/null 2>&1; then
        echo -e "${YELLOW}ss 命令未找到，正在尝试自动安装 iproute2 ${RESET}"
        install_system_package "iproute2" "iproute" 1 "iproute2 包"

        if command -v ss >/dev/null 2>&1; then
            echo -e "${GREEN}iproute2 安装成功，ss 命令已可用${RESET}"
        else
            echo -e "${RED}自动安装失败，请手动安装 iproute2 / iproute 包${RESET}" >&2
            exit 1
        fi
    else
        echo -e "${GREEN}ss 命令可用${RESET}"
    fi
}

is_port_in_use() {
    local port=$1
    ss -tuln | grep -q ":${port} "
}

is_valid_port() {
    local port=$1
    [[ "${port}" =~ ^[0-9]+$ ]] && [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ]
}

get_valid_port() {
    local port
    while true; do
        read -r -p "$1" port
        port=${port:-$((RANDOM % 50000 + 10000))}

        if is_valid_port "${port}"; then
            if is_port_in_use "${port}"; then
                echo -e "${RED}端口 ${port} 已被占用，请选择其他端口。${RESET}" >&2
            else
                echo "${port}"
                return
            fi
        else
            echo -e "${RED}请输入一个有效的端口号（1-65535）${RESET}" >&2
        fi
    done
}

get_valid_target_port() {
    local prompt=$1
    local port

    while true; do
        read -r -p "${prompt}" port

        if is_valid_port "${port}"; then
            echo "${port}"
            return
        fi

        echo -e "${RED}请输入有效端口号（1-65535）${RESET}" >&2
    done
}

# 用 printf -v 生成确认提示以避免子壳层开销
confirm_yes_default() {
    local color=$1
    local message=$2
    local prompt confirm

    printf -v prompt '%b' "${color}${message} (Y/n) ${RESET}"
    read -r -p "${prompt}" confirm
    confirm=${confirm:-Y}
    case "${confirm}" in
        y|Y) return 0 ;;
        *) return 1 ;;
    esac
}

get_required_value() {
    local prompt=$1
    local value

    while true; do
        read -r -p "${prompt}" value
        if [ -n "${value}" ]; then
            echo "${value}"
            return
        fi

        echo -e "${RED}此项不能为空，请重新输入${RESET}" >&2
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

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

shell_single_quote_escape() {
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

json_string_value() {
    local json=$1
    local key=$2
    echo "${json}" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

# 统一提取 GeoIP 嵌套对象中的字符串与整数值
json_nested_value() {
    local json=$1
    local section=$2
    local key=$3
    local value_type=${4:-string}
    local value_pattern='"\([^"]*\)"'

    if [ "${value_type}" = "number" ]; then
        value_pattern='\([0-9][0-9]*\)'
    fi

    echo "${json}" | sed -n "s/.*\"${section}\"[[:space:]]*:[[:space:]]*{[^}]*\"${key}\"[[:space:]]*:[[:space:]]*${value_pattern}.*/\1/p"
}

geoip_is_success() {
    echo "$1" | grep -q '"code"[[:space:]]*:[[:space:]]*0'
}

fetch_geoip_json() {
    local family=$1

    if ! command -v curl >/dev/null 2>&1; then
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
    country_name=$(json_nested_value "${json}" "country" "name")
    country_code=$(json_nested_value "${json}" "country" "code")
    as_number=$(json_nested_value "${json}" "as" "number" "number")
    as_name=$(json_nested_value "${json}" "as" "name")

    echo -e "${label}: ${GREEN}${ip}${RESET}  ${country_name}(${country_code})  AS${as_number} ${as_name}"
    [ -n "${addr}" ] && echo -e "      网段: ${addr}"
}

show_startup_ip_info() {
    echo -e "${CYAN}公网出口信息${RESET}"
    print_geoip_summary "IPv4" "${IPV4_GEOIP_JSON}"
    print_geoip_summary "IPv6" "${IPV6_GEOIP_JSON}"
}

# 跨函数共享的公网地址与国家代码采用大写全局命名
set_current_host_info() {
    local json

    load_startup_ip_info
    json="${IPV4_GEOIP_JSON}"
    if [ -z "$(json_string_value "${json}" "ip")" ]; then
        json="${IPV6_GEOIP_JSON}"
    fi

    HOST_IP=$(json_string_value "${json}" "ip")
    IP_COUNTRY=$(json_nested_value "${json}" "country" "code")

    if [ -z "${HOST_IP}" ]; then
        HOST_IP=$(curl -4 -s --max-time 5 http://checkip.amazonaws.com 2>/dev/null | tr -d '\r\n')
    fi

    HOST_IP=${HOST_IP:-YOUR_SERVER_IP}
    IP_COUNTRY=${IP_COUNTRY:-NODE}
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

is_valid_upstream_type() {
    case "$1" in
        socks|http) return 0 ;;
        *) return 1 ;;
    esac
}

upstream_type_label() {
    case "$1" in
        socks) echo "SOCKS5" ;;
        http) echo "HTTP" ;;
        *) echo "未设置" ;;
    esac
}

# 保留状态文件键名小写以兼容已有环境持久化配置
load_upstream_outbound() {
    [ -f "${UPSTREAM_OUTBOUND_FILE}" ] || return 1

    upstream_type=""
    upstream_server=""
    upstream_port=""
    upstream_username=""
    upstream_password=""
    . "${UPSTREAM_OUTBOUND_FILE}"

    is_valid_upstream_type "${upstream_type}" || return 1
    [ -n "${upstream_server}" ] || return 1
    is_valid_port "${upstream_port}" || return 1
}

has_upstream_outbound() {
    load_upstream_outbound
}

write_upstream_outbound_state() {
    ensure_state_dirs

    cat > "${UPSTREAM_OUTBOUND_FILE}" << EOF
upstream_type='$(shell_single_quote_escape "${upstream_type}")'
upstream_server='$(shell_single_quote_escape "${upstream_server}")'
upstream_port='$(shell_single_quote_escape "${upstream_port}")'
upstream_username='$(shell_single_quote_escape "${upstream_username}")'
upstream_password='$(shell_single_quote_escape "${upstream_password}")'
EOF
}

upstream_outbound_status_text() {
    local auth_text upstream_type upstream_server upstream_port upstream_username upstream_password

    if [ -f "${UPSTREAM_OUTBOUND_FILE}" ]; then
        if load_upstream_outbound; then
            if [ -n "${upstream_username}" ]; then
                auth_text="，认证: 已启用"
            else
                auth_text="，认证: 无"
            fi
            echo -e "${GREEN}$(upstream_type_label "${upstream_type}") -> ${upstream_server}:${upstream_port}${RESET}${GRAY}${auth_text}${RESET}"
        else
            echo -e "${RED}配置无效，当前渲染时会回退 direct${RESET}" >&2
        fi
    else
        echo -e "${YELLOW}未设置，默认直连 direct${RESET}"
    fi
}

render_upstream_outbound_json() {
    local escaped_server escaped_username escaped_password

    load_upstream_outbound || return 1

    escaped_server=$(json_escape "${upstream_server}")
    escaped_username=$(json_escape "${upstream_username}")
    escaped_password=$(json_escape "${upstream_password}")

    echo "    {"
    echo "      \"type\": \"${upstream_type}\","
    echo "      \"tag\": \"${UPSTREAM_OUTBOUND_TAG}\","
    echo "      \"server\": \"${escaped_server}\","
    if [ "${upstream_type}" = "socks" ] || [ -n "${upstream_username}" ]; then
        echo "      \"server_port\": ${upstream_port},"
    else
        echo "      \"server_port\": ${upstream_port}"
    fi
    if [ "${upstream_type}" = "socks" ]; then
        if [ -n "${upstream_username}" ]; then
            echo "      \"version\": \"5\","
        else
            echo "      \"version\": \"5\""
        fi
    fi
    if [ -n "${upstream_username}" ]; then
        echo "      \"username\": \"${escaped_username}\","
        echo "      \"password\": \"${escaped_password}\""
    fi
    echo "    }"
}

load_log_state() {
    [ -f "${LOG_STATE_FILE}" ] || return 1

    log_enabled=""
    . "${LOG_STATE_FILE}"

    case "${log_enabled}" in
        true|false) return 0 ;;
        *) return 1 ;;
    esac
}

is_log_enabled() {
    local log_enabled

    if load_log_state; then
        [ "${log_enabled}" = "true" ]
        return
    fi

    return 0
}

write_log_state() {
    ensure_state_dirs

    cat > "${LOG_STATE_FILE}" << EOF
log_enabled='${log_enabled}'
EOF
}

log_status_text() {
    if is_log_enabled; then
        echo -e "${GREEN}已开启${RESET}${GRAY}，可能记录连接源 IP${RESET}"
    else
        echo -e "${YELLOW}已关闭${RESET}${GRAY}，sing-box 不输出运行日志${RESET}"
    fi
}

cleanup_sing_box_logs() {
    local journal_mode=${1:-ask}
    local journal_choice

    rm -f /var/log/sing-box.log*
    rm -f /etc/logrotate.d/sing-box

    if [ "${IS_ALPINE}" -ne 1 ] && command -v journalctl >/dev/null 2>&1; then
        case "${journal_mode}" in
            force)
                journal_choice="y"
                ;;
            skip)
                journal_choice="n"
                ;;
            *)
                echo -e "${YELLOW}systemd journal 不支持只删除 sing-box 单个服务的历史日志。${RESET}" >&2
                read -r -p "是否清理已归档的 systemd journal? 这可能影响其它服务的历史日志 (y/N): " journal_choice
                ;;
        esac

        case "${journal_choice}" in
            y|Y)
                journalctl --rotate >/dev/null 2>&1 || true
                journalctl --vacuum-time=1s >/dev/null 2>&1 || true
                echo -e "${GREEN}已清理已归档的 systemd journal${RESET}"
                ;;
            *)
                echo -e "${YELLOW}已跳过 systemd journal 清理；如需彻底清除，请手动处理 journal 历史。${RESET}" >&2
                ;;
        esac
    fi

    echo -e "${GREEN}已删除 sing-box 文件日志与 logrotate 配置${RESET}"
}

prompt_log_preference_if_unset() {
    local choice log_enabled

    if [ -f "${LOG_STATE_FILE}" ]; then
        return
    fi

    echo -e "${CYAN}日志设置${RESET}"
    echo -e "${YELLOW}日志可能记录代理连接者 IP。为了隐私，默认关闭日志。${RESET}"
    read -r -p "是否开启 sing-box 日志? (y/N): " choice

    case "${choice}" in
        y|Y)
            log_enabled="true"
            write_log_state
            echo -e "${GREEN}已选择开启 sing-box 日志${RESET}"
            ;;
        *)
            log_enabled="false"
            write_log_state
            cleanup_sing_box_logs ask
            echo -e "${GREEN}已选择关闭 sing-box 日志${RESET}"
            ;;
    esac
}

# 按协议名集中维护片段路径与标签以避免四份重复分支
protocol_fragment_file() {
    case "$1" in
        reality) echo "${REALITY_FRAGMENT_FILE}" ;;
        shadowtls) echo "${SHADOWTLS_FRAGMENT_FILE}" ;;
        hy2) echo "${HY2_FRAGMENT_FILE}" ;;
        snell) echo "${SNELL_FRAGMENT_FILE}" ;;
        vlessws) echo "${VLESSWS_FRAGMENT_FILE}" ;;
        *) return 1 ;;
    esac
}

protocol_label() {
    case "$1" in
        reality) echo "VLESS Reality" ;;
        shadowtls) echo "ShadowTLS" ;;
        hy2) echo "Hysteria2" ;;
        snell) echo "Snell" ;;
        vlessws) echo "VLESS WS TLS" ;;
        *) echo "$1" ;;
    esac
}

config_has_protocol() {
    local pattern

    [ -f "${CONFIG_FILE}" ] || return 1
    case "$1" in
        reality) pattern='"tag"[[:space:]]*:[[:space:]]*"vless-reality"' ;;
        shadowtls) pattern='"type"[[:space:]]*:[[:space:]]*"shadowtls"' ;;
        hy2) pattern='"tag"[[:space:]]*:[[:space:]]*"hy2-in"' ;;
        snell) pattern='"tag"[[:space:]]*:[[:space:]]*"snell-in"' ;;
        vlessws) pattern='"tag"[[:space:]]*:[[:space:]]*"vlessws-in"' ;;
        *) return 1 ;;
    esac

    grep -q "${pattern}" "${CONFIG_FILE}"
}

has_protocol() {
    local fragment_file

    fragment_file=$(protocol_fragment_file "$1") || return 1
    [ -f "${fragment_file}" ] || config_has_protocol "$1"
}

# 一键补齐口径只看四个基础协议避免 VLESS WS TLS 缺失导致补齐项空转
has_all_protocols() {
    has_protocol reality && has_protocol hy2 && has_protocol shadowtls && has_protocol snell
}

extract_fragment_listen_port() {
    awk -F: '/"listen_port"/ { gsub(/[^0-9]/, "", $2); print $2; exit }' "$1"
}

extract_shadowtls_ports() {
    awk -F: '/"listen_port"/ { gsub(/[^0-9]/, "", $2); ports[++i]=$2 } END { if (i >= 2) print ports[1], ports[2] }' "${SHADOWTLS_FRAGMENT_FILE}"
}

extract_json_string_field() {
    local field=$1
    local file=$2
    awk -F\" -v field="\"${field}\"[[:space:]]*:" '$0 ~ field { print $4; exit }' "${file}"
}

extract_inbounds_to_fragment() {
    local protocol=$1
    local output_file=$2
    local tmp_file="${output_file}.tmp"

    # 导入 vlessws 片段前校验核心版本旧核心无法解析新式证书写法时跳过导入
    if [ "${protocol}" = "vlessws" ] && is_sing_box_installed; then
        if [ -z "$(get_sing_box_version)" ] || ! is_version_at_least "$(get_sing_box_version)" "1.14.0"; then
            echo -e "${YELLOW}当前 sing-box 核心低于 1.14.0，跳过导入 VLESS WS TLS 片段以避免写入不兼容配置${RESET}" >&2
            return 1
        fi
    fi

    if ! awk -v protocol="${protocol}" '
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
            if (protocol == "snell") {
                return block ~ /"tag"[[:space:]]*:[[:space:]]*"snell-in"/
            }
            if (protocol == "vlessws") {
                return block ~ /"tag"[[:space:]]*:[[:space:]]*"vlessws-in"/
            }
            return block ~ /"tag"[[:space:]]*:[[:space:]]*"shadowsocks-in"/ || block ~ /"type"[[:space:]]*:[[:space:]]*"shadowtls"/
        }
        # 复用入站块收尾输出逻辑以避免开始行与结束行分支漂移
        function flush_block() {
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
        /"inbounds"[[:space:]]*:/ {
            in_inbounds = 1
            next
        }
        in_inbounds {
            if (capturing) {
                block = block "\n" $0
                depth += count_char($0, "{") - count_char($0, "}")
                if (depth == 0) {
                    flush_block()
                }
                next
            }

            if ($0 ~ /^[[:space:]]*{/) {
                capturing = 1
                block = $0
                depth = count_char($0, "{") - count_char($0, "}")
                if (depth == 0) {
                    flush_block()
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
    ' "${CONFIG_FILE}" > "${tmp_file}" || [ ! -s "${tmp_file}" ]; then
        rm -f "${tmp_file}"
        echo -e "${RED}无法从现有配置导入 ${protocol} 入站配置，已停止以避免覆盖原配置。${RESET}" >&2
        exit 1
    fi

    mv "${tmp_file}" "${output_file}"

    # 导入的 vlessws 片段缺 server_name 或为空串时拒绝导入避免还原出无域名的坏配置
    if [ "${protocol}" = "vlessws" ] && ! grep -Eq '"server_name"[[:space:]]*:[[:space:]]*"[^"]' "${output_file}"; then
        rm -f "${output_file}"
        echo -e "${RED}导入的 VLESS WS TLS 片段缺少或含空 server_name，已拒绝导入${RESET}" >&2
        return 1
    fi

    # 导入规范化幂等按模式收敛自备证书片段原样保留仅 acme 片段缺引用时补齐
    if [ "${protocol}" = "vlessws" ] && ! grep -q '"certificate_path"' "${output_file}" && ! grep -q '"certificate_provider"' "${output_file}"; then
        awk '
            {
                if (!in_tls) {
                    print
                    if ($0 ~ /"tls"/) {
                        in_tls = 1
                        tls_indent = $0
                        sub(/[^[:space:]].*/, "", tls_indent)
                    }
                    next
                }
                if ($0 ~ ("^" tls_indent "}[[:space:]]*$")) {
                    if (prev != "" && prev !~ /,[[:space:]]*$/) {
                        sub(/[[:space:]]*$/, ",", prev)
                    }
                    if (prev != "") {
                        print prev
                    }
                    print tls_indent "    \"certificate_provider\": \"vlessws-cert\""
                    print $0
                    in_tls = 0
                    prev = ""
                    next
                }
                if (prev != "") {
                    print prev
                }
                prev = $0
            }
            END {
                if (prev != "") {
                    print prev
                }
            }
        ' "${output_file}" > "${tmp_file}" && mv "${tmp_file}" "${output_file}"
    fi
}

import_marked_client_section() {
    local section_title=$1
    local output_file=$2
    local start_marker="===== BEGIN ${section_title} ====="
    local end_marker="===== END ${section_title} ====="

    if awk -v start_marker="${start_marker}" -v end_marker="${end_marker}" '
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
    ' "${CLIENT_CONFIG_FILE}" > "${output_file}.tmp" && [ -s "${output_file}.tmp" ]; then
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
        [ -f "${REALITY_CLIENT_FILE}" ] || import_marked_client_section "VLESS Reality" "${REALITY_CLIENT_FILE}"
        [ -f "${HY2_CLIENT_FILE}" ] || import_marked_client_section "Hysteria2" "${HY2_CLIENT_FILE}"
        [ -f "${SHADOWTLS_CLIENT_FILE}" ] || import_marked_client_section "ShadowTLS + Shadowsocks" "${SHADOWTLS_CLIENT_FILE}"
        [ -f "${SNELL_CLIENT_FILE}" ] || import_marked_client_section "Snell" "${SNELL_CLIENT_FILE}"
        [ -f "${VLESSWS_CLIENT_FILE}" ] || import_marked_client_section "VLESS WS TLS" "${VLESSWS_CLIENT_FILE}"
        return
    fi

    if config_has_protocol reality && ! config_has_protocol hy2 && ! config_has_protocol shadowtls && [ ! -f "${REALITY_CLIENT_FILE}" ]; then
        cp "${CLIENT_CONFIG_FILE}" "${REALITY_CLIENT_FILE}"
    elif config_has_protocol hy2 && ! config_has_protocol reality && ! config_has_protocol shadowtls && [ ! -f "${HY2_CLIENT_FILE}" ]; then
        cp "${CLIENT_CONFIG_FILE}" "${HY2_CLIENT_FILE}"
    elif config_has_protocol shadowtls && ! config_has_protocol reality && ! config_has_protocol hy2 && [ ! -f "${SHADOWTLS_CLIENT_FILE}" ]; then
        cp "${CLIENT_CONFIG_FILE}" "${SHADOWTLS_CLIENT_FILE}"
    fi
}

import_existing_protocols() {
    local protocol fragment_file

    ensure_state_dirs

    if [ ! -f "${CONFIG_FILE}" ]; then
        return
    fi

    for protocol in reality shadowtls hy2 snell vlessws; do
        fragment_file=$(protocol_fragment_file "${protocol}")
        if config_has_protocol "${protocol}" && [ ! -f "${fragment_file}" ]; then
            echo -e "${CYAN}检测到现有 $(protocol_label "${protocol}") 配置，正在导入以便合并管理...${RESET}"
            if ! extract_inbounds_to_fragment "${protocol}" "${fragment_file}"; then
                echo -e "${YELLOW}已跳过导入 $(protocol_label "${protocol}") 配置${RESET}" >&2
            fi
        fi
    done

    import_existing_clients
}

# 统一判定 vlessws 证书模式优先状态文件次之嗅探片段内容
vlessws_effective_cert_mode() {
    local mode=""

    if load_vlessws_state >/dev/null 2>&1; then
        mode=${vlessws_cert_mode:-acme}
    elif [ -f "${VLESSWS_FRAGMENT_FILE}" ] && grep -q '"certificate_path"' "${VLESSWS_FRAGMENT_FILE}"; then
        mode="custom"
    fi

    [ -n "${mode}" ] || mode="acme"
    echo "${mode}"
}

# 证书签发数据固定落在状态目录 acme 子目录以支持续期持久化
render_certificate_providers() {
    local domain mode
    local vlessws_cert_mode vlessws_cert_path vlessws_key_path

    vlessws_cert_mode="" vlessws_cert_path="" vlessws_key_path=""
    domain=""
    if load_vlessws_state >/dev/null 2>&1; then
        domain="${vlessws_domain}"
    fi
    if [ -z "${domain}" ] && [ -f "${VLESSWS_FRAGMENT_FILE}" ]; then
        domain=$(extract_json_string_field "server_name" "${VLESSWS_FRAGMENT_FILE}")
    fi

    [ -n "${domain}" ] || return 0

    # 自备证书模式顶层不渲染 certificate_providers 以保持配置纯净
    if [ "$(vlessws_effective_cert_mode)" = "custom" ]; then
        return 0
    fi

    cat << EOF
  "certificate_providers": [
    {
      "type": "acme",
      "tag": "vlessws-cert",
      "domain": ["$(json_escape "${domain}")"],
      "data_directory": "${CONFIG_DIR}/acme"
    }
  ],
EOF
}

render_config() {
    local first=1
    local upstream_enabled=0
    local log_config fragment_file
    local upstream_type="" upstream_server="" upstream_port="" upstream_username="" upstream_password=""
    ensure_state_dirs

    if has_upstream_outbound; then
        upstream_enabled=1
    fi

    if ! is_log_enabled; then
        log_config='  "log": {
    "disabled": true
  },'
    elif [ "${IS_ALPINE}" -eq 1 ]; then
        log_config='  "log": {
    "level": "info",
    "timestamp": true,
    "output": "/var/log/sing-box.log"
  },'
    else
        log_config='  "log": {
    "level": "info",
    "timestamp": true
  },'
    fi

    {
        cat << EOF
{
${log_config}
  "dns": {
    "servers": [
      {
        "tag": "local-dns",
        "type": "local"
      },
      {
        "tag": "remote-dns",
        "type": "udp",
        "server": "8.8.8.8"
      }
    ],
    "strategy": "prefer_ipv4"
  },
EOF

        if [ "${upstream_enabled}" -eq 1 ]; then
            cat << EOF
  "route": {
    "default_domain_resolver": "local-dns",
    "final": "${UPSTREAM_OUTBOUND_TAG}"
  },
EOF
        else
            cat << EOF
  "route": {
    "default_domain_resolver": "local-dns"
  },
EOF
        fi

        render_certificate_providers

        cat << EOF
  "inbounds": [
EOF

        for fragment_file in "${REALITY_FRAGMENT_FILE}" "${HY2_FRAGMENT_FILE}" "${SHADOWTLS_FRAGMENT_FILE}" "${SNELL_FRAGMENT_FILE}" "${VLESSWS_FRAGMENT_FILE}"; do
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
EOF

        if [ "${upstream_enabled}" -eq 1 ]; then
            echo ","
            render_upstream_outbound_json
        fi

        cat << EOF
  ]
}
EOF
    } > "${CONFIG_FILE}"
}

append_client_section() {
    local section_title=$1
    local client_file=$2
    local trailing_blank=${3:-1}

    [ -f "${client_file}" ] || return 0
    echo "===== BEGIN ${section_title} ====="
    cat "${client_file}"
    echo "===== END ${section_title} ====="
    if [ "${trailing_blank}" -eq 1 ]; then
        echo ""
    fi
}

render_client_config() {
    ensure_state_dirs

    {
        append_client_section "VLESS Reality" "${REALITY_CLIENT_FILE}"
        append_client_section "Hysteria2" "${HY2_CLIENT_FILE}"
        append_client_section "ShadowTLS + Shadowsocks" "${SHADOWTLS_CLIENT_FILE}"
        append_client_section "Snell" "${SNELL_CLIENT_FILE}" 1
        append_client_section "VLESS WS TLS" "${VLESSWS_CLIENT_FILE}" 0
    } > "${CLIENT_CONFIG_FILE}"
}

setup_logrotate_for_alpine() {
    if [ "${IS_ALPINE}" -eq 1 ]; then
        if ! is_log_enabled; then
            rm -f /etc/logrotate.d/sing-box
            return
        fi

        echo -e "${CYAN}检测到 Alpine 环境，正在配置 logrotate 自动清理日志...${RESET}"
        apk add logrotate >/dev/null 2>&1
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

install_sing_box_deb() {
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
}

install_sing_box_binary() {
    local repo

    check_ss_command

    if is_sing_box_installed; then
        echo -e "${GREEN}sing-box 已安装，跳过核心安装${RESET}"
        return
    fi

    echo -e "${CYAN}正在安装 sing-box${RESET}"

    if [ "${IS_ALPINE}" -eq 1 ]; then
        echo -e "${YELLOW}检测到 Alpine Linux，使用 apk 安装...${RESET}"
        for repo in community testing; do
            if ! grep -q "edge/${repo}" /etc/apk/repositories; then
                echo "https://dl-cdn.alpinelinux.org/alpine/edge/${repo}" >> /etc/apk/repositories
            fi
        done
        apk update
        if ! apk add sing-box; then
            echo -e "${RED}sing-box 安装失败，请检查错误信息${RESET}" >&2
            exit 1
        fi
    else
        install_sing_box_deb || {
            echo -e "${RED}sing-box 安装失败！请检查网络连接或安装脚本来源。${RESET}" >&2
            exit 1
        }
    fi
}

enable_sing_box_service() {
    if [ "${IS_ALPINE}" -eq 1 ]; then
        rc-update add "${SERVICE_NAME}" default || {
            echo -e "${RED}无法启用 ${SERVICE_NAME} 服务！${RESET}" >&2
            exit 1
        }
    else
        systemctl enable "${SERVICE_NAME}" || {
            echo -e "${RED}无法启用 ${SERVICE_NAME} 服务！${RESET}" >&2
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

    if ! is_sing_box_running; then
        echo -e "${RED}${SERVICE_NAME} 服务未成功启动！${RESET}" >&2
        if [ "${IS_ALPINE}" -eq 1 ]; then rc-service "${SERVICE_NAME}" status; else systemctl status "${SERVICE_NAME}"; fi
        exit 1
    fi
}

install_package_if_missing() {
    local command_name=$1
    local package_name=$2

    if command -v "${command_name}" >/dev/null 2>&1; then
        return
    fi

    echo -e "${YELLOW}${command_name} 未安装，正在尝试安装 ${package_name}...${RESET}"
    install_system_package "${package_name}" "${package_name}" 0 "${package_name}"

    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo -e "${RED}${command_name} 安装失败，请手动安装 ${package_name}${RESET}" >&2
        exit 1
    fi
}

get_valid_mbps() {
    local prompt=$1
    local default_value=$2
    local value

    while true; do
        read -r -p "${prompt}" value
        value=${value:-${default_value}}

        if [[ "${value}" =~ ^[0-9]+$ ]] && [ "${value}" -gt 0 ]; then
            echo "${value}"
            return
        fi

        echo -e "${RED}请输入大于 0 的整数 Mbps 数值${RESET}" >&2
    done
}

get_valid_interval() {
    local prompt=$1
    local default_value=$2
    local value number

    while true; do
        read -r -p "${prompt}" value
        value=${value:-${default_value}}
        number=${value%s}

        if [[ "${number}" =~ ^[0-9]+$ ]] && [ "${number}" -ge 5 ]; then
            echo "${number}s"
            return
        fi

        echo -e "${RED}请输入不小于 5 秒的间隔，例如 30s${RESET}" >&2
    done
}

get_valid_port_range() {
    local prompt=$1
    local default_value=$2
    local range start end

    while true; do
        read -r -p "${prompt}" range
        range=${range:-${default_value}}
        range=$(echo "${range}" | tr -d ' ' | tr '-' ':')

        if [[ "${range}" =~ ^([0-9]+):([0-9]+)$ ]]; then
            start=${BASH_REMATCH[1]}
            end=${BASH_REMATCH[2]}

            if is_valid_port "${start}" && is_valid_port "${end}" && [ "${start}" -lt "${end}" ]; then
                echo "${start}:${end}"
                return
            fi
        fi

        echo -e "${RED}请输入有效端口范围，例如 20000:50000${RESET}" >&2
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
        echo -e "${RED}缺少 HY2 状态文件，无法安全修改。建议删除后重新安装 HY2。${RESET}" >&2
        return 1
    fi

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
                echo -e "${RED}Hysteria2 证书生成失败${RESET}" >&2
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
    if [ "${IS_ALPINE}" -eq 1 ]; then
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

    if [ "${IS_ALPINE}" -eq 1 ]; then
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
    local marker family table chain handle

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
            # 用 read 解析空格字段以避免覆盖调用方位置参数
            IFS=' ' read -r nft_family nft_table nft_chain <<< "$(nft_input_chain)" || true
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
        echo -e "${YELLOW}放行失败或不支持: ${label} ${port}/${proto}${RESET}" >&2
    fi
}

apply_current_firewall_rules() {
    local backend reality_port shadow_ports shadow_ssport shadow_sport snell_port vlessws_port
    local hy2_port hy2_password hy2_obfs_password hy2_sni hy2_up_mbps hy2_down_mbps hy2_hop_enabled hy2_hop_range hy2_hop_interval

    ensure_state_dirs
    backend=$(detect_firewall_backend)

    if [ "${backend}" = "none" ]; then
        echo -e "${YELLOW}未检测到 ufw / firewalld / iptables，未修改防火墙。${RESET}" >&2
        return
    fi

    restore_managed_firewall_rules
    : > "${FIREWALL_STATE_FILE}"

    echo -e "${CYAN}使用 ${backend} 自动放行当前协议端口...${RESET}"

    if [ -f "${REALITY_FRAGMENT_FILE}" ]; then
        reality_port=$(extract_fragment_listen_port "${REALITY_FRAGMENT_FILE}")
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
        shadow_ports=$(extract_shadowtls_ports)
        IFS=' ' read -r shadow_ssport shadow_sport <<< "${shadow_ports}" || true
        [ -n "${shadow_sport}" ] && add_firewall_rule_once "${backend}" "tcp" "${shadow_sport}" "ShadowTLS"
        if [ -n "${shadow_ssport}" ]; then
            add_firewall_rule_once "${backend}" "udp" "${shadow_ssport}" "Shadowsocks"
        fi
    fi

    if [ -f "${SNELL_FRAGMENT_FILE}" ]; then
        snell_port=$(extract_fragment_listen_port "${SNELL_FRAGMENT_FILE}")
        [ -n "${snell_port}" ] && add_firewall_rule_once "${backend}" "tcp" "${snell_port}" "Snell"
    fi

    if [ -f "${VLESSWS_FRAGMENT_FILE}" ]; then
        vlessws_port=$(extract_fragment_listen_port "${VLESSWS_FRAGMENT_FILE}")
        [ -n "${vlessws_port}" ] && add_firewall_rule_once "${backend}" "tcp" "${vlessws_port}" "VLESS WS TLS"
        # ACME HTTP-01 校验依赖 80 端口自备证书模式不放行
        if [ "$(vlessws_effective_cert_mode)" = "acme" ]; then
            add_firewall_rule_once "${backend}" "tcp" "80" "VLESS WS TLS ACME"
        fi
    fi

    if [ ! -s "${FIREWALL_STATE_FILE}" ]; then
        rm -f "${FIREWALL_STATE_FILE}"
    fi
}

show_firewall_status() {
    local backend reality_port shadow_ports shadow_ssport shadow_sport snell_port vlessws_port printed_ports
    local hy2_port hy2_password hy2_obfs_password hy2_sni hy2_up_mbps hy2_down_mbps hy2_hop_enabled hy2_hop_range hy2_hop_interval

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
        reality_port=$(extract_fragment_listen_port "${REALITY_FRAGMENT_FILE}")
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
        shadow_ports=$(extract_shadowtls_ports)
        IFS=' ' read -r shadow_ssport shadow_sport <<< "${shadow_ports}" || true
        print_firewall_port_status "${backend}" "ShadowTLS" "tcp" "${shadow_sport}"
        print_firewall_port_status "${backend}" "Shadowsocks" "udp" "${shadow_ssport}"
        printed_ports=1
    fi

    if [ -f "${SNELL_FRAGMENT_FILE}" ]; then
        snell_port=$(extract_fragment_listen_port "${SNELL_FRAGMENT_FILE}")
        print_firewall_port_status "${backend}" "Snell" "tcp" "${snell_port}"
        printed_ports=1
    fi

    if [ -f "${VLESSWS_FRAGMENT_FILE}" ]; then
        vlessws_port=$(extract_fragment_listen_port "${VLESSWS_FRAGMENT_FILE}")
        print_firewall_port_status "${backend}" "VLESS WS TLS" "tcp" "${vlessws_port}"
        # ACME 模式额外展示 80 端口放行状态与放行口径一致
        if [ "$(vlessws_effective_cert_mode)" = "acme" ]; then
            print_firewall_port_status "${backend}" "VLESS WS TLS ACME" "tcp" "80"
        fi
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
    uri_host=$(format_host_for_uri "${HOST_IP}")

    {
        echo -e "${PURPLE}=============== 明文参数 ===============${RESET}"
        echo "节点类型  : VLESS"
        echo "服务器IP  : ${HOST_IP}"
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
        echo -e "${YELLOW}vless://${uuid}@${uri_host}:${listen_port}?security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&flow=xtls-rprx-vision#${IP_COUNTRY}-VLESS-Reality${RESET}"

        echo -e "\n${GREEN}=============== Sub-Store ===============${RESET}"
        echo -e "${YELLOW}${IP_COUNTRY}-VLESS = VLESS,${HOST_IP},${listen_port},\"${uuid}\",transport=tcp,flow=xtls-rprx-vision,public-key=\"${public_key}\",short-id=${short_id},udp=true,block-quic=false,over-tls=true,sni=${sni}${RESET}"

        echo -e "\n${CYAN}=============== Clash Meta / Mihomo ===============${RESET}"
        cat << EOF
  - name: ${IP_COUNTRY}-VLESS-Reality
    type: vless
    server: ${HOST_IP}
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
  "tag": "${IP_COUNTRY}-VLESS-Reality",
  "server": "${HOST_IP}",
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

# 在安装入口内用局部变量隔离各协议临时生成参数
install_reality_protocol() {
    local listen_port sni uuid short_id keys private_key public_key

    if [ -f "${REALITY_FRAGMENT_FILE}" ]; then
        echo -e "${YELLOW}VLESS Reality 已存在，跳过安装${RESET}"
        return
    fi

    listen_port=$(get_valid_port "请输入 VLESS 监听端口 (默认随机，回车确认): ")

    read -r -p "请输入伪装域名 SNI (默认: www.postgresql.org): " sni
    sni=${sni:-www.postgresql.org}

    echo -e "${CYAN}正在生成 UUID...${RESET}"
    uuid=$(sing-box generate uuid)
    short_id=$(tr -dc 'a-f0-9' </dev/urandom | head -c 16)

    keys=$(sing-box generate reality-keypair)
    private_key=$(echo "${keys}" | grep "PrivateKey" | awk '{print $2}')
    public_key=$(echo "${keys}" | grep "PublicKey" | awk '{print $2}')

    set_current_host_info

    write_reality_fragment
    write_reality_client
    protocol_changed=1
}

write_shadowtls_fragment() {
    cat > "${SHADOWTLS_FRAGMENT_FILE}" << EOF
    {
      "type": "shadowsocks",
      "tag": "shadowsocks-in",
      "listen": "::",
      "listen_port": ${ss_port},
      "method": "2022-blake3-aes-128-gcm",
      "password": "${ss_password}",
      "multiplex": {
        "enabled": true
      }
    },
    {
      "type": "shadowtls",
      "listen": "::",
      "listen_port": ${shadowtls_port},
      "detour": "shadowsocks-in",
      "version": 3,
      "users": [
        {
          "password": "${shadowtls_password}"
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
    encoded_plugin=$(url_encode "shadow-tls;host=${shadowtls_sni};passwd=${shadowtls_password};v3")
    uri_host=$(format_host_for_uri "${HOST_IP}")

    {
        echo -e "${PURPLE}=============== 明文参数 ===============${RESET}"
        echo "节点类型        : ShadowTLS + Shadowsocks"
        echo "服务器IP        : ${HOST_IP}"
        echo "ShadowTLS 端口  : ${shadowtls_port}"
        echo "Shadowsocks 端口: ${ss_port}"
        echo "加密方法        : 2022-blake3-aes-128-gcm"
        echo "Shadowsocks 密码: ${ss_password}"
        echo "ShadowTLS 密码  : ${shadowtls_password}"
        echo "伪装域名        : ${shadowtls_sni}"
        echo "ShadowTLS 版本  : 3"
        echo "指纹(fp)        : chrome"

        echo -e "\n${CYAN}=============== 通用分享链接 ===============${RESET}"
        echo -e "${YELLOW}ss://2022-blake3-aes-128-gcm:${encoded_ss_password}@${uri_host}:${shadowtls_port}/?plugin=${encoded_plugin}#${IP_COUNTRY}-ShadowTLS${RESET}"

        echo -e "\n${GREEN}=============== Sub-Store ===============${RESET}"
        echo -e "${YELLOW}${IP_COUNTRY}-ShadowTLS = Shadowsocks,${HOST_IP},${shadowtls_port},2022-blake3-aes-128-gcm,\"${ss_password}\",shadow-tls-password=${shadowtls_password},shadow-tls-sni=${shadowtls_sni},shadow-tls-version=3,udp-port=${ss_port},fast-open=false,udp=true${RESET}"

        echo -e "\n${CYAN}=============== Clash Meta / Mihomo ===============${RESET}"
        cat << EOF
  - name: ${IP_COUNTRY}-ShadowTLS
    type: ss
    server: ${HOST_IP}
    port: ${shadowtls_port}
    cipher: 2022-blake3-aes-128-gcm
    password: ${ss_password}
    udp: true
    plugin: shadow-tls
    client-fingerprint: chrome
    plugin-opts:
      mode: tls
      host: ${shadowtls_sni}
      password: ${shadowtls_password}
      version: 3
    smux:
      enabled: true
EOF

        echo -e "\n${CYAN}=============== Sing-box Outbound ===============${RESET}"
        cat << EOF
[
  {
    "type": "shadowsocks",
    "tag": "${IP_COUNTRY}-ShadowTLS-SS",
    "server": "${HOST_IP}",
    "server_port": ${ss_port},
    "method": "2022-blake3-aes-128-gcm",
    "password": "${ss_password}",
    "detour": "${IP_COUNTRY}-ShadowTLS"
  },
  {
    "type": "shadowtls",
    "tag": "${IP_COUNTRY}-ShadowTLS",
    "server": "${HOST_IP}",
    "server_port": ${shadowtls_port},
    "version": 3,
    "password": "${shadowtls_password}",
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
    local shadowtls_port ss_port shadowtls_sni ss_password shadowtls_password

    if [ -f "${SHADOWTLS_FRAGMENT_FILE}" ]; then
        echo -e "${YELLOW}ShadowTLS 已存在，跳过安装${RESET}"
        return
    fi

    shadowtls_port=$(get_valid_port "请输入 ShadowTLS 监听端口 (默认随机，回车确认): ")
    ss_port=$(get_valid_port "请输入 Shadowsocks 监听端口 (默认随机，回车确认): ")

    read -r -p "请输入 ShadowTLS 伪装域名 SNI (默认: www.postgresql.org): " shadowtls_sni
    shadowtls_sni=${shadowtls_sni:-www.postgresql.org}

    ss_password=$(sing-box generate rand 16 --base64)
    shadowtls_password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)

    set_current_host_info

    write_shadowtls_fragment
    write_shadowtls_client
    protocol_changed=1
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

    uri_host=$(format_host_for_uri "${HOST_IP}")
    encoded_password=$(url_encode "${hy2_password}")
    encoded_obfs=$(url_encode "${hy2_obfs_password}")
    hop_range_dash=$(range_colon_to_dash "${hy2_hop_range}")
    hop_interval_seconds=$(interval_to_seconds "${hy2_hop_interval}")

    if [ "${hy2_hop_enabled}" = "true" ]; then
        hy2_uri_port="${hop_range_dash}"
    else
        hy2_uri_port="${hy2_port}"
    fi

    hy2_uri="hysteria2://${encoded_password}@${uri_host}:${hy2_uri_port}/?insecure=1&obfs=salamander&obfs-password=${encoded_obfs}&sni=${hy2_sni}#${IP_COUNTRY}-HY2"

    {
        echo -e "${PURPLE}=============== 明文参数 ===============${RESET}"
        echo "节点类型      : Hysteria2"
        echo "服务器IP      : ${HOST_IP}"
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
        echo -e "${YELLOW}${IP_COUNTRY}-HY2 = Hysteria2,${HOST_IP},${hy2_port},\"${hy2_password}\",tls-name=${hy2_sni},skip-cert-verify=true,salamander-password=${hy2_obfs_password},fast-open=false${RESET}"

        echo -e "\n${CYAN}=============== Clash Meta / Mihomo ===============${RESET}"
        cat << EOF
  - name: ${IP_COUNTRY}-HY2
    type: hysteria2
    server: ${HOST_IP}
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
  "tag": "${IP_COUNTRY}-HY2",
  "server": "${HOST_IP}",
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

install_snell_core_from_github() {
    local arch version url tmp_dir

    case "$(uname -m)" in
        x86_64)
            arch="amd64"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        *)
            echo -e "${RED}不支持的架构: $(uname -m)${RESET}" >&2
            return 1
            ;;
    esac

    version=$(curl -fsSL --max-time 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -oE '"tag_name": *"v[0-9.]+' | cut -d'"' -f4 | sed 's/^v//')

    if [ -z "${version}" ]; then
        echo -e "${RED}无法获取 sing-box 最新版本号${RESET}" >&2
        return 1
    fi

    echo -e "${CYAN}Alpine 仓库无 1.14 以上版本，改用 GitHub 官方 sing-box ${version}...${RESET}"
    url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}.tar.gz"
    tmp_dir=$(mktemp -d)

    if ! curl -fsSL --max-time 180 "${url}" -o "${tmp_dir}/sing-box.tar.gz" || ! tar -xzf "${tmp_dir}/sing-box.tar.gz" -C "${tmp_dir}"; then
        echo -e "${RED}下载 sing-box ${version} 失败${RESET}" >&2
        rm -rf "${tmp_dir}"
        return 1
    fi

    if command -v apk >/dev/null 2>&1; then
        echo -e "${CYAN}官方二进制为 glibc 动态链接，安装 gcompat 兼容层...${RESET}"
        apk add --no-cache gcompat || {
            echo -e "${RED}安装 gcompat 兼容层失败${RESET}" >&2
            rm -rf "${tmp_dir}"
            return 1
        }
    fi

    install -m755 "${tmp_dir}/sing-box-${version}-linux-${arch}/sing-box" "/usr/bin/sing-box" || {
        echo -e "${RED}安装 sing-box 二进制失败${RESET}" >&2
        rm -rf "${tmp_dir}"
        return 1
    }

    if ! sing-box version >/dev/null 2>&1; then
        if [ "${arch}" = "amd64" ] && [ ! -e /lib64/ld-linux-x86-64.so.2 ]; then
            echo -e "${CYAN}创建 /lib64 动态链接器兼容链接...${RESET}"
            mkdir -p /lib64
            ln -sf /lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
        fi

        if ! sing-box version >/dev/null 2>&1; then
            echo -e "${RED}sing-box 二进制仍无法执行，请检查架构与依赖${RESET}" >&2
            rm -rf "${tmp_dir}"
            return 1
        fi
    fi

    rm -rf "${tmp_dir}"

    echo -e "${GREEN}已安装 GitHub 官方 sing-box ${version}${RESET}"
}

get_sing_box_version() {
    sing-box version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

is_version_at_least() {
    local current_version=$1
    local required_version=$2
    local oldest

    oldest=$(printf '%s\n%s\n' "${required_version}" "${current_version}" | sort -V | head -n1)
    [ "${oldest}" = "${required_version}" ]
}

ensure_snell_capable_core() {
    local current_version

    if ! command -v sing-box >/dev/null 2>&1; then
        return 0
    fi

    current_version=$(get_sing_box_version)

    if [ -z "${current_version}" ]; then
        echo -e "${YELLOW}sing-box 存在但无法执行，疑似官方二进制缺少 glibc 兼容层${RESET}" >&2
        if confirm_yes_default "${YELLOW}" "是否现在重装官方 sing-box 二进制修复?"; then
            install_snell_core_from_github || {
                echo -e "${RED}sing-box 修复失败，已中止 Snell 安装${RESET}" >&2
                return 1
            }
        else
            echo -e "${YELLOW}已取消修复，中止 Snell 安装${RESET}"
            return 1
        fi

        current_version=$(get_sing_box_version)

        if [ -n "${current_version}" ]; then
            return 0
        fi

        echo -e "${RED}sing-box 修复后仍无法执行，已中止 Snell 安装${RESET}" >&2
        return 1
    fi

    if is_version_at_least "${current_version}" "1.14.0"; then
        return 0
    fi

    echo -e "${YELLOW}当前 sing-box ${current_version} 不支持 Snell v6，需要升级到 1.14.0 以上${RESET}" >&2
    if confirm_yes_default "${YELLOW}" "是否现在升级 sing-box 核心?"; then
        if [ "${IS_ALPINE}" -eq 1 ]; then
            install_snell_core_from_github || {
                echo -e "${RED}sing-box 升级失败，已中止 Snell 安装${RESET}" >&2
                return 1
            }
        else
            install_sing_box_deb || {
                echo -e "${RED}sing-box 升级失败，已中止 Snell 安装${RESET}" >&2
                return 1
            }
        fi
    else
        echo -e "${YELLOW}已取消升级，中止 Snell 安装${RESET}"
        return 1
    fi

    current_version=$(get_sing_box_version)

    if ! is_version_at_least "${current_version}" "1.14.0"; then
        echo -e "${RED}升级后 sing-box version 实际输出:${RESET}" >&2
        sing-box version 2>&1 | head -n3 >&2
        echo -e "${RED}升级后版本 ${current_version} 仍低于 1.14.0，已中止 Snell 安装${RESET}" >&2
        return 1
    fi

    echo -e "${GREEN}sing-box 已升级到 ${current_version}${RESET}"
}

write_snell_state() {
    cat > "${SNELL_STATE_FILE}" << EOF
snell_port='${snell_port}'
snell_psk='${snell_psk}'
snell_mode='${snell_mode}'
EOF
}

write_snell_fragment() {
    cat > "${SNELL_FRAGMENT_FILE}" << EOF
    {
      "type": "snell",
      "tag": "snell-in",
      "listen": "::",
      "listen_port": ${snell_port},
      "version": 6,
      "psk": "${snell_psk}",
      "mode": "${snell_mode}"
    }
EOF
}

write_snell_client() {
    {
        echo -e "${PURPLE}=============== 明文参数 ===============${RESET}"
        echo "节点类型      : Snell v6"
        echo "服务器IP      : ${HOST_IP}"
        echo "监听端口      : ${snell_port} (TCP)"
        echo "PSK           : ${snell_psk}"
        echo "流量整形模式  : ${snell_mode}"
        echo "UDP           : 走 UDP-over-TCP，无需单独放行 UDP 端口"

        echo -e "\n${GREEN}=============== Sub-Store ===============${RESET}"
        echo -e "${YELLOW}${IP_COUNTRY}-Snell = snell,${HOST_IP},${snell_port},\"${snell_psk}\",version=6,udp=true,block-quic=true${RESET}"

        echo -e "\n${CYAN}=============== Clash Meta / Mihomo ===============${RESET}"
        cat << EOF
  - name: ${IP_COUNTRY}-Snell
    type: snell
    server: ${HOST_IP}
    port: ${snell_port}
    psk: ${snell_psk}
    version: "6"
EOF
        echo "备注: Snell v6 需要 mihomo 内核 1.19.34 以上或 sing-box 1.14 以上"

        echo -e "\n${CYAN}=============== Sing-box Outbound ===============${RESET}"
        cat << EOF
{
  "type": "snell",
  "tag": "${IP_COUNTRY}-Snell",
  "server": "${HOST_IP}",
  "server_port": ${snell_port},
  "version": 6,
  "psk": "${snell_psk}"
}
EOF
    } > "${SNELL_CLIENT_FILE}"
}

install_snell_protocol() {
    local snell_port snell_mode snell_psk

    if [ -f "${SNELL_FRAGMENT_FILE}" ]; then
        echo -e "${YELLOW}Snell 已存在，跳过安装${RESET}"
        return
    fi

    ensure_snell_capable_core || return 1

    snell_port=$(get_valid_port "请输入 Snell TCP 监听端口 (默认随机，回车确认): ")

    read -r -p "请输入 Snell v6 流量整形模式 default/unshaped/unsafe-raw (默认: default): " snell_mode
    snell_mode=${snell_mode:-default}

    case "${snell_mode}" in
        default|unshaped|unsafe-raw)
            ;;
        *)
            echo -e "${YELLOW}无效的模式，已改用 default${RESET}" >&2
            snell_mode="default"
            ;;
    esac

    echo -e "${CYAN}正在生成 Snell PSK...${RESET}"
    snell_psk=$(head -c 16 /dev/urandom | base64 | tr -d '\n')

    set_current_host_info
    write_snell_state
    write_snell_fragment
    write_snell_client

    protocol_changed=1
}

install_hy2_protocol() {
    local enable_hop hy2_port hy2_up_mbps hy2_down_mbps hy2_sni hy2_hop_enabled hy2_hop_range hy2_hop_interval hy2_password hy2_obfs_password

    if [ -f "${HY2_FRAGMENT_FILE}" ]; then
        echo -e "${YELLOW}Hysteria2 已存在，跳过安装${RESET}"
        return
    fi

    hy2_port=$(get_valid_port "请输入 Hysteria2 UDP 监听端口 (默认随机，回车确认): ")
    hy2_up_mbps=$(get_valid_mbps "请输入 HY2 上行带宽 Mbps (默认 1000): " 1000)
    hy2_down_mbps=$(get_valid_mbps "请输入 HY2 下行带宽 Mbps (默认 1000): " 1000)

    read -r -p "请输入 HY2 TLS SNI (默认: www.postgresql.org): " hy2_sni
    hy2_sni=${hy2_sni:-www.postgresql.org}

    read -r -p "是否启用 HY2 端口跳跃? (y/N): " enable_hop
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

    protocol_changed=1
}

# 逐个比对已有协议入站端口以避免新入站与现有协议互踩
find_vlessws_port_conflict() {
    local port=$1
    local check_port shadow_ports shadow_ssport shadow_sport
    local hy2_port hy2_password hy2_obfs_password hy2_sni hy2_up_mbps hy2_down_mbps hy2_hop_enabled hy2_hop_range hy2_hop_interval

    if [ -f "${REALITY_FRAGMENT_FILE}" ]; then
        check_port=$(extract_fragment_listen_port "${REALITY_FRAGMENT_FILE}")
        if [ "${check_port}" = "${port}" ]; then
            echo "VLESS Reality"
            return 0
        fi
    fi

    if [ -f "${HY2_FRAGMENT_FILE}" ] && load_hy2_state >/dev/null 2>&1; then
        if [ "${hy2_port}" = "${port}" ]; then
            echo "Hysteria2"
            return 0
        fi
    fi

    if [ -f "${SHADOWTLS_FRAGMENT_FILE}" ]; then
        shadow_ports=$(extract_shadowtls_ports)
        IFS=' ' read -r shadow_ssport shadow_sport <<< "${shadow_ports}" || true
        if [ "${shadow_ssport}" = "${port}" ] || [ "${shadow_sport}" = "${port}" ]; then
            echo "ShadowTLS"
            return 0
        fi
    fi

    if [ -f "${SNELL_FRAGMENT_FILE}" ]; then
        check_port=$(extract_fragment_listen_port "${SNELL_FRAGMENT_FILE}")
        if [ "${check_port}" = "${port}" ]; then
            echo "Snell"
            return 0
        fi
    fi

    return 1
}

# 回车即随机选端口并对齐四协议占用与冲突校验口径
get_vlessws_listen_port() {
    local prompt=$1
    local port conflict

    while true; do
        read -r -p "${prompt}" port
        port=${port:-$((RANDOM % 50000 + 10000))}

        if ! is_valid_port "${port}"; then
            echo -e "${RED}请输入一个有效的端口号（1-65535）${RESET}" >&2
            continue
        fi

        if is_port_in_use "${port}"; then
            echo -e "${RED}端口 ${port} 已被占用，请选择其他端口。${RESET}" >&2
            continue
        fi

        conflict=$(find_vlessws_port_conflict "${port}")
        if [ -n "${conflict}" ]; then
            echo -e "${RED}端口 ${port} 与 ${conflict} 入站端口冲突，请更换端口。${RESET}" >&2
            continue
        fi

        if ! vlessws_warn_cdn_port "${port}"; then
            continue
        fi

        echo "${port}"
        return
    done
}

# 端口不在 Cloudflare HTTPS 代理白名单时提醒按 CDN 语境确认后继续
vlessws_warn_cdn_port() {
    local port=$1

    case "${port}" in
        443|8443|2053|2083|2087|2096)
            return 0
            ;;
    esac

    echo -e "${YELLOW}警告：端口 ${port} 不在 Cloudflare HTTPS 代理白名单（443、8443、2053、2083、2087、2096）内，CF 不会代理该端口${RESET}" >&2
    echo -e "${YELLOW}可在 Cloudflare 用 Origin Rules 做端口改写，或改用白名单端口${RESET}" >&2
    confirm_yes_default "${YELLOW}" "是否确认继续?"
}

# 低于 1.14.0 的核心无法解析新式 certificate_providers 写法时直接拒装
ensure_vlessws_capable_core() {
    local current_version

    if ! is_sing_box_installed; then
        return 0
    fi

    current_version=$(get_sing_box_version)

    if [ -n "${current_version}" ] && is_version_at_least "${current_version}" "1.14.0"; then
        return 0
    fi

    echo -e "${RED}当前 sing-box ${current_version:-版本未知} 低于 1.14.0，不支持 VLESS WS TLS 所需的 certificate_providers 写法，请先升级核心再安装${RESET}" >&2
    return 1
}

# 域名解析与出口 IP 仅作提醒不阻断，实际签发以可达性为准
prompt_vlessws_domain() {
    local domain resolved_ip

    set_current_host_info
    while true; do
        domain=$(get_required_value "请输入 VLESS WS TLS 绑定域名: ")
        # 域名进入 JSON 与分享链接仅限合法字符防止畸形输入破坏配置
        if [[ "${domain}" =~ ^[A-Za-z0-9.-]+$ ]]; then
            break
        fi
        echo -e "${RED}域名仅限字母数字点与横线，请重新输入${RESET}" >&2
    done
    resolved_ip=$(getent hosts "${domain}" 2>/dev/null | awk '{print $1; exit}')

    if [ -z "${resolved_ip}" ]; then
        echo -e "${YELLOW}警告：域名 ${domain} 当前未解析出 IP，可继续，但 ACME 签发可能失败${RESET}" >&2
    elif [ "${HOST_IP}" != "YOUR_SERVER_IP" ] && [ "${resolved_ip}" != "${HOST_IP}" ]; then
        echo -e "${YELLOW}警告：域名 ${domain} 解析到 ${resolved_ip}，与本机出口 IP ${HOST_IP} 不一致，可能解析尚未生效或已套 CDN${RESET}" >&2
        echo -e "${YELLOW}若已套 CDN 请按 CDN 语境处理：确认端口在代理白名单内，并按证书类型核对 CF SSL 模式${RESET}" >&2
    fi

    echo "${domain}"
}

# 提取证书公钥哈希用于与私钥比对
vlessws_cert_pubkey_hash() {
    local pem

    pem=$(openssl x509 -noout -pubkey -in "$1" 2>/dev/null)
    if [ -z "${pem}" ]; then
        return 1
    fi
    printf '%s\n' "${pem}" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
}

# 提取私钥公钥哈希用于与证书比对
vlessws_key_pubkey_hash() {
    local pem

    # passin 传空口令遇加密私钥立即失败避免交互挂起
    pem=$(openssl pkey -in "$1" -pubout -passin pass: 2>/dev/null)
    if [ -z "${pem}" ]; then
        return 1
    fi
    printf '%s\n' "${pem}" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
}

# 判断 SAN 列表是否覆盖绑定域名支持通配符匹配
vlessws_san_covers_domain() {
    local san_text=$1
    local domain=$2
    local entry domain_lc entry_lc

    domain_lc=${domain,,}

    while IFS= read -r entry; do
        [ -n "${entry}" ] || continue
        entry_lc=${entry,,}
        if [ "${entry_lc}" = "${domain_lc}" ]; then
            return 0
        fi
        case "${entry_lc}" in
            \*.*)
                case "${domain_lc}" in
                    *.${entry_lc#\*.}) return 0 ;;
                esac
                ;;
        esac
    done << EOF
$(printf '%s\n' "${san_text}" | grep -o 'DNS:[^,]*' | sed 's/^DNS://')
EOF

    return 1
}

# 每次安装都询问证书来源并按自备流程完成存在可读与匹配校验
prompt_vlessws_cert_source() {
    local choice cert_file key_file cert_hash key_hash

    echo -e "${CYAN}请选择 VLESS WS TLS 证书来源${RESET}"
    echo -e "${GRAY}1. ACME 自动签发${RESET}"
    echo -e "${GRAY}2. 自备证书文件${RESET}"
    read -r -p "请选择 (默认 1，回车即可): " choice

    if [ "${choice}" != "2" ]; then
        vlessws_cert_mode="acme"
        vlessws_cert_path=""
        vlessws_key_path=""
        return 0
    fi

    vlessws_cert_mode="custom"

    while true; do
        cert_file=$(get_required_value "请输入证书文件路径: ")
        if [[ "${cert_file}" = /* ]] && [ -f "${cert_file}" ] && [ -r "${cert_file}" ]; then
            break
        fi
        echo -e "${RED}证书文件不存在不可读或不是绝对路径，请输入绝对路径后重试${RESET}" >&2
    done

    while true; do
        key_file=$(get_required_value "请输入私钥文件路径: ")
        if [[ "${key_file}" = /* ]] && [ -f "${key_file}" ] && [ -r "${key_file}" ]; then
            break
        fi
        echo -e "${RED}私钥文件不存在不可读或不是绝对路径，请输入绝对路径后重试${RESET}" >&2
    done

    # 状态文件只登记规范化后的绝对路径防止相对路径与符号链接绕过迁出保护
    cert_file=$(readlink -f "${cert_file}" 2>/dev/null)
    key_file=$(readlink -f "${key_file}" 2>/dev/null)
    if [ -z "${cert_file}" ] || [ -z "${key_file}" ]; then
        echo -e "${RED}无法规范化证书或私钥路径，已放弃安装${RESET}" >&2
        return 1
    fi

    install_package_if_missing openssl openssl

    cert_hash=$(vlessws_cert_pubkey_hash "${cert_file}")
    key_hash=$(vlessws_key_pubkey_hash "${key_file}")
    if [ -z "${cert_hash}" ] || [ -z "${key_hash}" ]; then
        echo -e "${RED}无法读取证书或私钥的公钥信息，请确认文件为 PEM 格式后重试${RESET}" >&2
        return 1
    fi
    if [ "${cert_hash}" != "${key_hash}" ]; then
        echo -e "${RED}证书与私钥公钥不匹配，已拒绝安装${RESET}" >&2
        return 1
    fi

    # SAN 与绑定域名不一致仅软警告不阻断安装
    if ! vlessws_san_covers_domain "$(openssl x509 -noout -ext subjectAltName -in "${cert_file}" 2>/dev/null)" "${vlessws_domain}"; then
        echo -e "${YELLOW}警告：证书 SAN 未覆盖域名 ${vlessws_domain}，客户端可能出现证书域名校验告警，可继续安装${RESET}" >&2
    fi

    vlessws_cert_path="${cert_file}"
    vlessws_key_path="${key_file}"
}

# 优先用核心生成随机 WS 路径核心命令失败时用 urandom 兜底
generate_vlessws_ws_path() {
    local rand_part

    rand_part=""
    if is_sing_box_installed; then
        rand_part=$(sing-box generate rand 16 --hex 2>/dev/null)
    fi
    if ! [[ "${rand_part}" =~ ^[A-Za-z0-9]{16,64}$ ]]; then
        rand_part=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
    fi

    echo "/${rand_part}"
}

write_vlessws_state() {
    cat > "${VLESSWS_STATE_FILE}" << EOF
vlessws_port='${vlessws_port}'
vlessws_uuid='${vlessws_uuid}'
vlessws_domain='$(shell_single_quote_escape "${vlessws_domain}")'
vlessws_path='$(shell_single_quote_escape "${vlessws_path}")'
vlessws_cert_mode='${vlessws_cert_mode:-acme}'
vlessws_cert_path='$(shell_single_quote_escape "${vlessws_cert_path:-}")'
vlessws_key_path='$(shell_single_quote_escape "${vlessws_key_path:-}")'
EOF
}

load_vlessws_state() {
    if [ ! -f "${VLESSWS_STATE_FILE}" ]; then
        echo -e "${RED}缺少 VLESS WS TLS 状态文件，无法安全修改。建议删除后重新安装 VLESS WS TLS。${RESET}" >&2
        return 1
    fi

    # shellcheck disable=SC1090
    . "${VLESSWS_STATE_FILE}"

    # 旧状态文件缺新键时兜底为 ACME 模式避免渲染与防火墙误判
    vlessws_cert_mode=${vlessws_cert_mode:-acme}
    vlessws_cert_path=${vlessws_cert_path:-}
    vlessws_key_path=${vlessws_key_path:-}
}

# 自定义证书位于配置目录内时登记迁出保护清单登记前规范化路径防止绕过前缀匹配
vlessws_record_cert_rescue() {
    local rescue_kind=$1 rescue_path=$2 rescue_real=""

    [ "${vlessws_cert_mode:-acme}" = "custom" ] || return 0
    [ -n "${rescue_path}" ] || return 0
    # 相对路径先按配置目录补全为绝对路径避免前缀匹配扑空
    if [[ "${rescue_path}" != /* ]] && [ -f "${CONFIG_DIR}/${rescue_path}" ]; then
        rescue_path="${CONFIG_DIR}/${rescue_path}"
    fi
    [ -f "${rescue_path}" ] || return 0
    # 登记前用 readlink -f 规范化路径挡住 .. 与符号链接绕过保护前缀匹配
    rescue_real=$(readlink -f "${rescue_path}" 2>/dev/null) || rescue_real=""
    if [ -z "${rescue_real}" ] || [[ "${rescue_real}" != /* ]]; then
        echo -e "${RED}自备证书路径 ${rescue_path} 无法规范化为绝对路径，已拒绝登记${RESET}" >&2
        return 1
    fi
    [[ "${rescue_real}" == "${CONFIG_DIR}"/* ]] || return 0
    mkdir -p "${VLESSWS_CERT_RESCUE_DIR}" || return 1
    if [ -f "${VLESSWS_CERT_RESCUE_LIST}" ] && grep -Fxq "${rescue_kind}|${rescue_real}" "${VLESSWS_CERT_RESCUE_LIST}"; then
        return 0
    fi
    echo "${rescue_kind}|${rescue_real}" >> "${VLESSWS_CERT_RESCUE_LIST}"
}

write_vlessws_fragment() {
    local tls_cert_fields

    if [ "${vlessws_cert_mode:-acme}" = "custom" ]; then
        tls_cert_fields="        \"certificate_path\": \"$(json_escape "${vlessws_cert_path}")\",
        \"key_path\": \"$(json_escape "${vlessws_key_path}")\""
    else
        tls_cert_fields='        "certificate_provider": "vlessws-cert"'
    fi

    cat > "${VLESSWS_FRAGMENT_FILE}" << EOF
    {
      "type": "vless",
      "tag": "vlessws-in",
      "listen": "::",
      "listen_port": ${vlessws_port},
      "users": [
        {
          "uuid": "$(json_escape "${vlessws_uuid}")"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$(json_escape "${vlessws_path}")",
        "headers": {
          "host": "$(json_escape "${vlessws_domain}")"
        },
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      },
      "tls": {
        "enabled": true,
        "server_name": "$(json_escape "${vlessws_domain}")",
${tls_cert_fields}
      }
    }
EOF
}

write_vlessws_client() {
    {
        echo -e "${PURPLE}=============== 明文参数 ===============${RESET}"
        echo "节点类型      : VLESS WS TLS"
        echo "连接域名      : ${vlessws_domain}"
        echo "监听端口      : ${vlessws_port} (TCP)"
        echo "UUID          : ${vlessws_uuid}"
        echo "WS 路径       : ${vlessws_path}"
        echo "加密方式      : none"
        if [ "${vlessws_cert_mode:-acme}" = "custom" ]; then
            echo "TLS           : 自备证书 (${vlessws_cert_path})"
            echo "CF SSL 模式   : 公网 CA 证书配 Full strict，自签或 Origin CA 证书配 Full"
        else
            echo "TLS           : ACME 自动签发证书"
            echo "CF SSL 模式   : Let's Encrypt 证书兼容 Full 与 Full strict"
        fi
        echo "0-RTT         : 已启用 (max_early_data 2048)"

        echo -e "\n${CYAN}=============== 通用分享链接 ===============${RESET}"
        echo -e "${YELLOW}vless://${vlessws_uuid}@${vlessws_domain}:${vlessws_port}?encryption=none&security=tls&sni=${vlessws_domain}&type=ws&host=${vlessws_domain}&path=${vlessws_path}#VLESSWS-${vlessws_domain}${RESET}"

        echo -e "\n${GREEN}=============== Sub-Store ===============${RESET}"
        echo -e "${YELLOW}${IP_COUNTRY}-VLESSWS = VLESS,${vlessws_domain},${vlessws_port},\"${vlessws_uuid}\",transport=ws,path=${vlessws_path},host=${vlessws_domain},over-tls=true,sni=${vlessws_domain},udp=true${RESET}"

        echo -e "\n${CYAN}=============== Clash Meta / Mihomo ===============${RESET}"
        cat << EOF
  - name: ${IP_COUNTRY}-VLESSWS
    type: vless
    server: ${vlessws_domain}
    port: ${vlessws_port}
    uuid: ${vlessws_uuid}
    network: ws
    tls: true
    udp: true
    servername: ${vlessws_domain}
    ws-opts:
      path: ${vlessws_path}
      headers:
        Host: ${vlessws_domain}
EOF

        echo -e "\n${CYAN}=============== Sing-box Outbound ===============${RESET}"
        cat << EOF
{
  "type": "vless",
  "tag": "${IP_COUNTRY}-VLESSWS",
  "server": "${vlessws_domain}",
  "server_port": ${vlessws_port},
  "uuid": "${vlessws_uuid}",
  "tls": {
    "enabled": true,
    "server_name": "${vlessws_domain}"
  },
  "transport": {
    "type": "ws",
    "path": "${vlessws_path}",
    "headers": {
      "Host": "${vlessws_domain}"
    },
    "max_early_data": 2048,
    "early_data_header_name": "Sec-WebSocket-Protocol"
  }
}
EOF
        echo -e "${GREEN}================================================================${RESET}"
    } > "${VLESSWS_CLIENT_FILE}"
}

install_vlessws_protocol() {
    local vlessws_port vlessws_uuid vlessws_domain vlessws_path
    local vlessws_cert_mode vlessws_cert_path vlessws_key_path

    if [ -f "${VLESSWS_FRAGMENT_FILE}" ]; then
        echo -e "${YELLOW}VLESS WS TLS 已存在，跳过安装${RESET}"
        return
    fi

    ensure_vlessws_capable_core || return 1

    set_current_host_info

    vlessws_domain=$(prompt_vlessws_domain)
    vlessws_port=$(get_vlessws_listen_port "请输入 VLESS WS TLS 监听端口 (默认随机，回车即可): ")

    prompt_vlessws_cert_source || {
        echo -e "${YELLOW}已取消 VLESS WS TLS 安装${RESET}"
        return 1
    }

    # 仅 ACME 模式依赖 80 端口完成 HTTP-01 校验自备证书无需占用
    if [ "${vlessws_cert_mode}" = "acme" ] && is_port_in_use 80; then
        echo -e "${YELLOW}警告：端口 80 已被占用，ACME HTTP-01 校验无法完成，证书签发会失败${RESET}" >&2
        if ! confirm_yes_default "${YELLOW}" "是否继续安装? 如需自动签发证书请先腾出 80 端口"; then
            echo -e "${YELLOW}已取消 VLESS WS TLS 安装${RESET}"
            return 1
        fi
    fi

    echo -e "${CYAN}正在生成 UUID...${RESET}"
    vlessws_uuid=$(sing-box generate uuid)

    read -r -p "请输入自定义 WS 路径 (默认随机，回车即可): " vlessws_path
    vlessws_path=${vlessws_path:-$(generate_vlessws_ws_path)}
    if [ "${vlessws_path#/}" = "${vlessws_path}" ]; then
        vlessws_path="/${vlessws_path}"
    fi
    # path 进入分享链接 query 与状态文件，限定安全字符避免拼装错位
    if ! [[ "${vlessws_path}" =~ ^/[A-Za-z0-9_./-]*$ ]]; then
        echo -e "${RED}WS 路径仅限字母数字与 _ . / - 字符，已放弃安装${RESET}" >&2
        return 1
    fi

    write_vlessws_state
    write_vlessws_fragment
    write_vlessws_client

    protocol_changed=1
}

change_vlessws_port() {
    local current_port new_port tmp_file vlessws_port vlessws_uuid vlessws_domain vlessws_path
    local vlessws_cert_mode vlessws_cert_path vlessws_key_path

    import_existing_protocols

    if [ ! -f "${VLESSWS_FRAGMENT_FILE}" ]; then
        echo -e "${RED}VLESS WS TLS 尚未安装${RESET}" >&2
        return
    fi

    check_ss_command

    current_port=$(extract_fragment_listen_port "${VLESSWS_FRAGMENT_FILE}")
    if [ -z "${current_port}" ]; then
        echo -e "${RED}无法从配置文件中读取当前监听端口${RESET}" >&2
        return
    fi

    load_vlessws_state || return

    new_port=$(get_vlessws_listen_port "请输入新的 VLESS WS TLS 监听端口 (当前 ${current_port}，默认随机，回车即可): ")

    if [ "${new_port}" = "${current_port}" ]; then
        echo -e "${YELLOW}配置未变化，已取消修改${RESET}"
        return
    fi

    tmp_file="${VLESSWS_FRAGMENT_FILE}.tmp"
    if ! awk -v new_port="${new_port}" '
        /"listen_port"/ && changed == 0 {
            sub(/"listen_port"[[:space:]]*:[[:space:]]*[0-9]+/, "\"listen_port\": " new_port)
            changed = 1
        }
        { print }
    ' "${VLESSWS_FRAGMENT_FILE}" > "${tmp_file}"; then
        echo -e "${RED}更新服务端配置失败${RESET}" >&2
        rm -f "${tmp_file}"
        return
    fi
    mv "${tmp_file}" "${VLESSWS_FRAGMENT_FILE}"

    vlessws_port=${new_port}
    write_vlessws_state
    set_current_host_info
    write_vlessws_client

    if apply_config_and_restart "端口已写入配置，但 ${SERVICE_NAME} 服务未成功运行，请查看状态或日志"; then
        echo -e "${GREEN}VLESS WS TLS 监听端口已从 ${current_port} 修改为 ${new_port}${RESET}"
        echo -e "${YELLOW}域名与 WS 路径如需变更请删除本协议后重新安装${RESET}"
        echo -e "${YELLOW}端口变更不会自动修改防火墙，请到防火墙菜单执行自动放行${RESET}"
        show_client_summary
    fi
}

install_protocols() {
    local protocol_changed=0
    local protocol

    install_sing_box_binary
    prompt_log_preference_if_unset
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
            snell)
                install_snell_protocol
                ;;
            vlessws)
                install_vlessws_protocol
                ;;
        esac
    done

    if [ "${protocol_changed}" -eq 1 ]; then
        render_config
        render_client_config
        reload_sing_box_service
        echo -e "${GREEN}sing-box 协议配置更新成功！${RESET}"
        echo -e "${YELLOW}安全提醒：请勿将节点配置发到聊天群，勿用在线检测网站测试节点${RESET}"
        echo ""
        show_client_summary
    else
        echo -e "${YELLOW}没有新增协议配置${RESET}"
    fi
}

perform_uninstall_sing_box() {
    local vlessws_cert_mode vlessws_cert_path vlessws_key_path
    local preserve_cert=0 preserve_key=0 preserve_dir=""
    local rescue_entry rescue_kind rescue_path restore_failed=0

    echo -e "${CYAN}正在卸载 sing-box${RESET}"
    restore_managed_firewall_rules

    if [ "${IS_ALPINE}" -eq 1 ]; then
        rc-service "${SERVICE_NAME}" stop || echo -e "${RED}停止 sing-box 服务失败。${RESET}" >&2
        rc-update del "${SERVICE_NAME}" default || echo -e "${RED}禁用 sing-box 服务失败。${RESET}" >&2
        apk del sing-box || echo -e "${YELLOW}无法通过 apk 卸载 sing-box。${RESET}" >&2
    else
        systemctl stop "${SERVICE_NAME}" || echo -e "${RED}停止 sing-box 服务失败。${RESET}" >&2
        systemctl disable "${SERVICE_NAME}" || echo -e "${RED}禁用 sing-box 服务失败。${RESET}" >&2
        dpkg --purge sing-box || echo -e "${YELLOW}可能未通过 apt 安装，跳过 dpkg 卸载。${RESET}" >&2
        systemctl daemon-reload
    fi

    # 自备证书文件绝不删除先登记迁出保护清单备份成功才允许删除配置目录
    if load_vlessws_state >/dev/null 2>&1 && [ "${vlessws_cert_mode:-acme}" = "custom" ]; then
        if ! vlessws_record_cert_rescue cert "${vlessws_cert_path}" || ! vlessws_record_cert_rescue key "${vlessws_key_path}"; then
            echo -e "${RED}自备证书迁出保护清单登记失败，已中止卸载且未删除任何文件${RESET}" >&2
            return 1
        fi
    elif [ ! -f "${VLESSWS_STATE_FILE}" ] && [ -f "${VLESSWS_FRAGMENT_FILE}" ] && grep -q '"certificate_path"' "${VLESSWS_FRAGMENT_FILE}"; then
        # 无状态文件时嗅探自备证书片段登记路径避免导入态直卸误删
        vlessws_cert_mode="custom"
        vlessws_cert_path=$(extract_json_string_field "certificate_path" "${VLESSWS_FRAGMENT_FILE}")
        vlessws_key_path=$(extract_json_string_field "key_path" "${VLESSWS_FRAGMENT_FILE}")
        if ! vlessws_record_cert_rescue cert "${vlessws_cert_path}" || ! vlessws_record_cert_rescue key "${vlessws_key_path}"; then
            echo -e "${RED}自备证书迁出保护清单登记失败，已中止卸载且未删除任何文件${RESET}" >&2
            return 1
        fi
    fi

    if [ -f "${VLESSWS_CERT_RESCUE_LIST}" ]; then
        while IFS= read -r rescue_entry || [ -n "${rescue_entry}" ]; do
            rescue_kind=${rescue_entry%%|*}
            rescue_path=${rescue_entry#*|}
            if [ -n "${rescue_path}" ] && [ -f "${rescue_path}" ] && [[ "${rescue_path}" == "${CONFIG_DIR}"/* ]]; then
                case "${rescue_kind}" in
                    cert)
                        preserve_cert=1
                        vlessws_cert_path=${rescue_path}
                        ;;
                    key)
                        preserve_key=1
                        vlessws_key_path=${rescue_path}
                        ;;
                esac
            fi
        done < "${VLESSWS_CERT_RESCUE_LIST}"
    fi

    if [ "${preserve_cert}" -eq 0 ] && [ "${preserve_key}" -eq 0 ] && [ -f "${VLESSWS_CERT_RESCUE_LIST}" ]; then
        rm -rf "${VLESSWS_CERT_RESCUE_DIR}"
    fi

    if [ "${preserve_cert}" -eq 1 ] || [ "${preserve_key}" -eq 1 ]; then
        preserve_dir=${VLESSWS_CERT_RESCUE_DIR}
        if [ "${preserve_cert}" -eq 1 ]; then
            cp -p "${vlessws_cert_path}" "${preserve_dir}/cert" || {
                echo -e "${RED}自备证书迁出备份失败，已中止卸载且未删除任何文件${RESET}" >&2
                return 1
            }
        fi
        if [ "${preserve_key}" -eq 1 ]; then
            cp -p "${vlessws_key_path}" "${preserve_dir}/key" || {
                echo -e "${RED}自备证书私钥迁出备份失败，已中止卸载且未删除任何文件${RESET}" >&2
                return 1
            }
        fi
    fi

    rm -rf "${CONFIG_DIR}"
    rm -f /var/log/sing-box.log*
    rm -f /etc/logrotate.d/sing-box

    if [ "${preserve_cert}" -eq 1 ]; then
        mkdir -p "$(dirname "${vlessws_cert_path}")"
        if ! cp -p "${preserve_dir}/cert" "${vlessws_cert_path}"; then
            echo -e "${RED}自备证书原位恢复失败，迁出副本保留在 ${preserve_dir}${RESET}" >&2
            restore_failed=1
        fi
    fi
    if [ "${preserve_key}" -eq 1 ]; then
        mkdir -p "$(dirname "${vlessws_key_path}")"
        if ! cp -p "${preserve_dir}/key" "${vlessws_key_path}"; then
            echo -e "${RED}自备证书私钥原位恢复失败，迁出副本保留在 ${preserve_dir}${RESET}" >&2
            restore_failed=1
        fi
    fi
    if [ -n "${preserve_dir}" ] && [ "${restore_failed}" -eq 0 ]; then
        rm -rf "${VLESSWS_CERT_RESCUE_DIR}"
        echo -e "${GREEN}已保留自备证书文件未删除${RESET}"
    elif [ -n "${preserve_dir}" ]; then
        echo -e "${YELLOW}自备证书迁出副本保留在 ${preserve_dir}${RESET}"
    fi

    if [ -f "/usr/local/bin/sing-box" ]; then
        rm /usr/local/bin/sing-box
    fi

    echo -e "${GREEN}sing-box 卸载成功${RESET}"
}

uninstall_sing_box() {
    if confirm_yes_default "${RED}" "确定要卸载 sing-box 并删除全部协议配置吗?"; then
        perform_uninstall_sing_box
    else
        echo -e "${YELLOW}已取消卸载操作${RESET}"
    fi
}

has_any_protocol_fragment() {
    [ -f "${REALITY_FRAGMENT_FILE}" ] || [ -f "${HY2_FRAGMENT_FILE}" ] || [ -f "${SHADOWTLS_FRAGMENT_FILE}" ] || [ -f "${SNELL_FRAGMENT_FILE}" ] || [ -f "${VLESSWS_FRAGMENT_FILE}" ]
}

remove_single_protocol() {
    local protocol=$1
    local fragment_file label

    fragment_file=$(protocol_fragment_file "${protocol}") || return 1
    label=$(protocol_label "${protocol}")

    if [ ! -f "${fragment_file}" ]; then
        echo -e "${YELLOW}${label} 未安装，跳过删除${RESET}"
        return 1
    fi

    case "${protocol}" in
        reality)
            rm -f "${REALITY_FRAGMENT_FILE}" "${REALITY_CLIENT_FILE}"
            ;;
        shadowtls)
            rm -f "${SHADOWTLS_FRAGMENT_FILE}" "${SHADOWTLS_CLIENT_FILE}"
            ;;
        hy2)
            disable_hy2_port_hopping_runtime
            rm -f "${HY2_FRAGMENT_FILE}" "${HY2_CLIENT_FILE}" "${HY2_STATE_FILE}" "${HY2_CERT_FILE}" "${HY2_KEY_FILE}"
            ;;
        snell)
            rm -f "${SNELL_FRAGMENT_FILE}" "${SNELL_CLIENT_FILE}" "${SNELL_STATE_FILE}"
            ;;
        vlessws)
            vlessws_cert_mode="" vlessws_cert_path="" vlessws_key_path=""
            if load_vlessws_state >/dev/null 2>&1; then
                :
            elif [ -f "${VLESSWS_FRAGMENT_FILE}" ] && grep -q '"certificate_path"' "${VLESSWS_FRAGMENT_FILE}"; then
                vlessws_cert_mode="custom"
                vlessws_cert_path=$(extract_json_string_field "certificate_path" "${VLESSWS_FRAGMENT_FILE}")
                vlessws_key_path=$(extract_json_string_field "key_path" "${VLESSWS_FRAGMENT_FILE}")
            fi
            rescue_record_failed=0
            if [ "${vlessws_cert_mode:-acme}" = "custom" ]; then
                vlessws_record_cert_rescue cert "${vlessws_cert_path}" || rescue_record_failed=1
                vlessws_record_cert_rescue key "${vlessws_key_path}" || rescue_record_failed=1
                if [ "${rescue_record_failed}" -eq 1 ]; then
                    echo -e "${RED}登记自备证书迁出保护清单失败，已中止删除且未删除任何文件${RESET}" >&2
                    return 1
                fi
            fi
            if [ "$(vlessws_effective_cert_mode)" = "custom" ]; then
                echo -e "${YELLOW}自备证书文件不受影响，仅清理脚本生成物${RESET}"
            fi
            rm -f "${VLESSWS_FRAGMENT_FILE}" "${VLESSWS_CLIENT_FILE}" "${VLESSWS_STATE_FILE}"
            ;;
    esac

    echo -e "${GREEN}已删除 ${label} 协议配置${RESET}"
}

remove_protocols() {
    local removed=0
    local protocol

    import_existing_protocols

    for protocol in "$@"; do
        if remove_single_protocol "${protocol}"; then
            removed=1
        fi
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
        if confirm_yes_default "${YELLOW}" "已没有剩余协议，是否同时卸载 sing-box 服务与配置?"; then
            perform_uninstall_sing_box
        else
            render_config
            render_client_config
            stop_sing_box
            echo -e "${YELLOW}已保留 sing-box，当前没有启用任何协议${RESET}"
        fi
    fi
}

run_sing_box_service_action() {
    local action=$1
    local action_label=$2
    local service_rc=0

    if [ "${IS_ALPINE}" -eq 1 ]; then
        rc-service "${SERVICE_NAME}" "${action}" || service_rc=1
    else
        systemctl "${action}" "${SERVICE_NAME}" || service_rc=1
    fi

    if [ "${service_rc}" -eq 0 ]; then
        echo -e "${GREEN}${SERVICE_NAME} 服务成功${action_label}${RESET}"
    else
        echo -e "${RED}${SERVICE_NAME} 服务${action_label}失败${RESET}" >&2
    fi
}

start_sing_box() {
    run_sing_box_service_action "start" "启动"
}

stop_sing_box() {
    run_sing_box_service_action "stop" "停止"
}

restart_sing_box() {
    run_sing_box_service_action "restart" "重启"
}

status_sing_box() {
    if [ "${IS_ALPINE}" -eq 1 ]; then
        rc-service "${SERVICE_NAME}" status
    else
        systemctl status "${SERVICE_NAME}"
    fi
}

log_sing_box() {
    if ! is_log_enabled; then
        echo -e "${YELLOW}当前已关闭 sing-box 日志，无日志可查看${RESET}"
        return
    fi

    echo -e "${CYAN}正在实时监控 sing-box 日志，按 Ctrl+C 退出${RESET}"
    if [ "${IS_ALPINE}" -eq 1 ]; then
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
        show_protocol_client_summary "Snell v6" "${SNELL_CLIENT_FILE}" "snell://"
        show_protocol_client_summary "VLESS WS TLS" "${VLESSWS_CLIENT_FILE}" "vless://"
    else
        echo -e "${YELLOW}配置文件不存在: ${CLIENT_CONFIG_FILE}${RESET}" >&2
    fi
}

show_full_client_config() {
    if [ -f "${CLIENT_CONFIG_FILE}" ]; then
        clear
        cat "${CLIENT_CONFIG_FILE}"
    else
        echo -e "${YELLOW}配置文件不存在: ${CLIENT_CONFIG_FILE}${RESET}" >&2
    fi
}

client_config_menu() {
    import_existing_protocols
    render_client_config

    if [ ! -f "${CLIENT_CONFIG_FILE}" ]; then
        echo -e "${YELLOW}配置文件不存在: ${CLIENT_CONFIG_FILE}${RESET}" >&2
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

configure_upstream_outbound() {
    local selected_type=$1
    local current_type="" current_server="" current_port="" current_username="" current_password=""
    local upstream_type="" upstream_server="" upstream_port="" upstream_username="" upstream_password=""
    local label input_username input_password

    if load_upstream_outbound; then
        current_type="${upstream_type}"
        current_server="${upstream_server}"
        current_port="${upstream_port}"
        current_username="${upstream_username}"
        current_password="${upstream_password}"
    fi

    label=$(upstream_type_label "${selected_type}")
    if [ "${current_type}" != "${selected_type}" ]; then
        current_username=""
        current_password=""
    fi

    echo -e "${CYAN}配置 ${label} 上游出站${RESET}"
    echo -e "${GRAY}启用后，脚本生成的 route.final 会指向 ${UPSTREAM_OUTBOUND_TAG}，未匹配其它规则的 sing-box 入站流量都会走这里。${RESET}"
    if [ "${current_type}" = "${selected_type}" ]; then
        echo -e "${GRAY}当前 ${label} 上游: ${current_server}:${current_port}${RESET}"
    fi
    upstream_server=$(get_required_value "请输入 ${label} 上游地址: ")
    upstream_port=$(get_valid_target_port "请输入 ${label} 上游端口: ")

    if [ -n "${current_username}" ]; then
        read -r -p "请输入认证用户名 (当前: ${current_username}；回车保留，输入 - 清空认证): " input_username
        case "${input_username}" in
            "")
                upstream_username="${current_username}"
                upstream_password="${current_password}"
                ;;
            -)
                upstream_username=""
                upstream_password=""
                ;;
            *)
                upstream_username="${input_username}"
                ;;
        esac
    else
        read -r -p "请输入认证用户名 (无认证直接回车): " upstream_username
        upstream_password=""
    fi

    if [ -n "${upstream_username}" ]; then
        if [ "${upstream_username}" = "${current_username}" ] && [ -n "${current_password}" ]; then
            read -r -s -p "请输入认证密码 (回车保留当前密码): " input_password
            echo ""
            upstream_password=${input_password:-${current_password}}
        else
            read -r -s -p "请输入认证密码: " upstream_password
            echo ""
        fi
    fi

    upstream_type="${selected_type}"
    write_upstream_outbound_state
    render_config
    restart_sing_box

    if is_sing_box_running; then
        echo -e "${GREEN}上游出站已启用: $(upstream_type_label "${upstream_type}") -> ${upstream_server}:${upstream_port}${RESET}"
    else
        echo -e "${RED}配置已写入，但 ${SERVICE_NAME} 服务未成功运行，请查看状态或日志${RESET}" >&2
    fi
}

disable_upstream_outbound() {
    if [ ! -f "${UPSTREAM_OUTBOUND_FILE}" ]; then
        echo -e "${YELLOW}当前未设置上游出站，无需关闭${RESET}"
        return
    fi

    rm -f "${UPSTREAM_OUTBOUND_FILE}"
    render_config
    restart_sing_box

    if is_sing_box_running; then
        echo -e "${GREEN}已关闭上游出站，默认出站恢复为 direct${RESET}"
    else
        echo -e "${YELLOW}已关闭上游出站并写入配置；服务当前未运行，请按需启动${RESET}"
    fi
}

upstream_outbound_menu() {
    menu_reset
    menu_add "1" "设置 / 更新 SOCKS5 上游" "适合本机或内网 Socks5 代理；地址和端口均需手动填写。"
    menu_add "2" "设置 / 更新 HTTP 上游" "适合本机或内网 HTTP CONNECT 代理；地址和端口均需手动填写。"
    if [ -f "${UPSTREAM_OUTBOUND_FILE}" ]; then
        menu_add "3" "关闭上游出站" "删除上游出站设置，恢复 sing-box 默认 direct。"
    fi
    menu_add "0" "返回主菜单" "不修改出站设置。"
    interactive_select "请选择上游出站操作:"

    case "${MENU_CHOICE}" in
        1) configure_upstream_outbound "socks" ;;
        2) configure_upstream_outbound "http" ;;
        3) disable_upstream_outbound ;;
        0)
            SKIP_PAUSE=1
            return
            ;;
        *) echo -e "${RED}无效的选项，已返回主菜单${RESET}" >&2 ;;
    esac
}

apply_log_setting() {
    local enabled=$1
    local log_enabled

    log_enabled="${enabled}"
    write_log_state
    setup_logrotate_for_alpine
    render_config

    if is_sing_box_running; then
        restart_sing_box
    else
        echo -e "${YELLOW}${SERVICE_NAME} 服务当前未运行，已仅写入配置${RESET}"
    fi

    if [ "${enabled}" = "false" ]; then
        cleanup_sing_box_logs ask
        echo -e "${GREEN}sing-box 日志已关闭${RESET}"
    else
        echo -e "${GREEN}sing-box 日志已开启${RESET}"
    fi
}

logging_menu() {
    menu_reset
    if is_log_enabled; then
        menu_add "1" "关闭日志并删除历史日志" "写入 log.disabled=true，并清理 sing-box 历史日志。"
    else
        menu_add "1" "开启日志" "恢复 sing-box info 日志；可能记录代理连接者 IP。"
    fi
    menu_add "2" "清理历史日志" "删除 sing-box 文件日志；systemd journal 会另行询问。"
    menu_add "0" "返回主菜单" "不修改日志设置。"
    interactive_select "请选择日志操作:"

    case "${MENU_CHOICE}" in
        1)
            if is_log_enabled; then
                if confirm_yes_default "${YELLOW}" "确认关闭日志并删除历史日志吗?"; then
                    apply_log_setting "false"
                else
                    echo -e "${YELLOW}已取消关闭日志${RESET}"
                fi
            else
                apply_log_setting "true"
            fi
            ;;
        2)
            cleanup_sing_box_logs ask
            ;;
        0)
            SKIP_PAUSE=1
            return
            ;;
        *) echo -e "${RED}无效的选项，已返回主菜单${RESET}" >&2 ;;
    esac
}

# 统一修改菜单中重复的 SNI 输入提示与空值回退
prompt_new_sni() {
    local label=$1
    local default=$2
    local input

    read -r -p "请输入新的 ${label} (默认: ${default}): " input
    printf '%s' "${input:-${default}}"
}

apply_config_and_restart() {
    local failure_message=$1

    render_config
    render_client_config
    restart_sing_box
    if ! is_sing_box_running; then
        echo -e "${RED}${failure_message}${RESET}" >&2
        return 1
    fi
}

change_reality_port() {
    local port_choice current_port current_sni new_port new_sni tmp_file tmp_client_file

    import_existing_protocols

    if [ ! -f "${REALITY_FRAGMENT_FILE}" ]; then
        echo -e "${RED}VLESS Reality 尚未安装${RESET}" >&2
        return
    fi

    check_ss_command

    current_port=$(extract_fragment_listen_port "${REALITY_FRAGMENT_FILE}")
    if [ -z "${current_port}" ]; then
        echo -e "${RED}无法从配置文件中读取当前监听端口${RESET}" >&2
        return
    fi

    current_sni=$(extract_json_string_field "server_name" "${REALITY_FRAGMENT_FILE}")
    current_sni=${current_sni:-www.postgresql.org}

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
            new_sni=$(prompt_new_sni "Reality 伪装域名 SNI" "${current_sni}")
            ;;
        3)
            new_port=$(get_valid_port "请输入新的 VLESS 监听端口 (默认随机，回车确认): ")
            new_sni=$(prompt_new_sni "Reality 伪装域名 SNI" "${current_sni}")
            ;;
        0)
            SKIP_PAUSE=1
            return
            ;;
        *)
            echo -e "${RED}无效的选项，已取消修改${RESET}" >&2
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
        echo -e "${RED}更新服务端配置失败${RESET}" >&2
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
            echo -e "${RED}更新客户端配置失败${RESET}" >&2
            rm -f "${tmp_client_file}"
            return
        fi
        mv "${tmp_client_file}" "${REALITY_CLIENT_FILE}"
    else
        echo -e "${YELLOW}客户端配置文件不存在，已仅更新服务端配置${RESET}" >&2
    fi

    if apply_config_and_restart "端口已写入配置，但 ${SERVICE_NAME} 服务未成功运行，请查看状态或日志"; then
        echo -e "${GREEN}VLESS 监听端口已从 ${current_port} 修改为 ${new_port}${RESET}"
        echo -e "${GREEN}Reality 伪装域名已从 ${current_sni} 修改为 ${new_sni}${RESET}"
        show_client_summary
    fi
}

change_snell_port() {
    local current_port new_port tmp_file snell_port snell_psk snell_mode

    import_existing_protocols

    if [ ! -f "${SNELL_FRAGMENT_FILE}" ]; then
        echo -e "${RED}Snell 尚未安装${RESET}" >&2
        return
    fi

    check_ss_command

    current_port=$(extract_fragment_listen_port "${SNELL_FRAGMENT_FILE}")
    if [ -z "${current_port}" ]; then
        echo -e "${RED}无法从配置文件中读取当前监听端口${RESET}" >&2
        return
    fi

    new_port=$(get_valid_port "请输入新的 Snell 监听端口 (当前 ${current_port}，默认随机，回车确认): ")

    if [ "${new_port}" = "${current_port}" ]; then
        echo -e "${YELLOW}配置未变化，已取消修改${RESET}"
        return
    fi

    tmp_file="${SNELL_FRAGMENT_FILE}.tmp"
    if ! awk -v new_port="${new_port}" '
        /"listen_port"/ && changed == 0 {
            sub(/"listen_port"[[:space:]]*:[[:space:]]*[0-9]+/, "\"listen_port\": " new_port)
            changed = 1
        }
        { print }
    ' "${SNELL_FRAGMENT_FILE}" > "${tmp_file}"; then
        echo -e "${RED}更新服务端配置失败${RESET}" >&2
        rm -f "${tmp_file}"
        return
    fi
    mv "${tmp_file}" "${SNELL_FRAGMENT_FILE}"

    snell_port=${new_port}
    snell_psk=$(extract_json_string_field "psk" "${SNELL_FRAGMENT_FILE}")
    snell_mode=$(extract_json_string_field "mode" "${SNELL_FRAGMENT_FILE}")
    write_snell_state
    set_current_host_info
    write_snell_client

    if apply_config_and_restart "端口已写入配置，但 ${SERVICE_NAME} 服务未成功运行，请查看状态或日志"; then
        echo -e "${GREEN}Snell 监听端口已从 ${current_port} 修改为 ${new_port}${RESET}"
        echo -e "${YELLOW}端口变更不会自动修改防火墙，请到防火墙菜单执行自动放行${RESET}"
        show_client_summary
    fi
}

change_shadowtls_port() {
    local current_ports current_ssport current_sport current_sni port_choice new_sport new_ssport new_sni tmp_file tmp_client_file

    import_existing_protocols

    if [ ! -f "${SHADOWTLS_FRAGMENT_FILE}" ]; then
        echo -e "${RED}ShadowTLS 尚未安装${RESET}" >&2
        return
    fi

    check_ss_command

    current_ports=$(extract_shadowtls_ports)
    IFS=' ' read -r current_ssport current_sport <<< "${current_ports}" || true
    current_sni=$(extract_json_string_field "server" "${SHADOWTLS_FRAGMENT_FILE}")
    current_sni=${current_sni:-www.postgresql.org}

    if [ -z "${current_ssport}" ] || [ -z "${current_sport}" ]; then
        echo -e "${RED}无法从配置文件中读取当前监听端口${RESET}" >&2
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
            new_sni=$(prompt_new_sni "ShadowTLS 伪装域名 SNI" "${current_sni}")
            ;;
        5)
            new_sport=$(get_valid_port "请输入新的 ShadowTLS 监听端口 (默认随机，回车确认): ")
            new_ssport=$(get_valid_port "请输入新的 Shadowsocks 监听端口 (默认随机，回车确认): ")
            new_sni=$(prompt_new_sni "ShadowTLS 伪装域名 SNI" "${current_sni}")
            ;;
        0)
            SKIP_PAUSE=1
            return
            ;;
        *)
            echo -e "${RED}无效的选项，已取消修改${RESET}" >&2
            return
            ;;
    esac

    if [ "${new_sport}" = "${new_ssport}" ]; then
        echo -e "${RED}ShadowTLS 和 Shadowsocks 端口不能相同，已取消修改${RESET}" >&2
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
        echo -e "${RED}更新服务端配置失败${RESET}" >&2
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
            echo -e "${RED}更新客户端配置失败${RESET}" >&2
            rm -f "${tmp_client_file}"
            return
        fi
        mv "${tmp_client_file}" "${SHADOWTLS_CLIENT_FILE}"
    else
        echo -e "${YELLOW}客户端配置文件不存在，已仅更新服务端配置${RESET}" >&2
    fi

    if apply_config_and_restart "端口已写入配置，但 ${SERVICE_NAME} 服务未成功运行，请查看状态或日志"; then
        echo -e "${GREEN}ShadowTLS 端口已从 ${current_sport} 修改为 ${new_sport}${RESET}"
        echo -e "${GREEN}Shadowsocks 端口已从 ${current_ssport} 修改为 ${new_ssport}${RESET}"
        echo -e "${GREEN}ShadowTLS 伪装域名已从 ${current_sni} 修改为 ${new_sni}${RESET}"
        show_client_summary
    fi
}

change_hy2_port() {
    local port_choice enable_hop old_port old_sni old_hop_enabled old_hop_range old_hop_interval regen_hy2_cert
    local hy2_port hy2_password hy2_obfs_password hy2_sni hy2_up_mbps hy2_down_mbps hy2_hop_enabled hy2_hop_range hy2_hop_interval

    import_existing_protocols

    if [ ! -f "${HY2_FRAGMENT_FILE}" ]; then
        echo -e "${RED}Hysteria2 尚未安装${RESET}" >&2
        return
    fi

    load_hy2_state || return
    check_ss_command

    old_port=${hy2_port}
    old_sni=${hy2_sni:-www.postgresql.org}
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
            hy2_sni=$(prompt_new_sni "HY2 TLS SNI" "${old_sni}")
            ;;
        3)
            ;;
        4)
            hy2_port=$(get_valid_port "请输入新的 HY2 UDP 监听端口 (默认随机，回车确认): ")
            hy2_sni=$(prompt_new_sni "HY2 TLS SNI" "${old_sni}")
            ;;
        0)
            SKIP_PAUSE=1
            return
            ;;
        *)
            echo -e "${RED}无效的选项，已取消修改${RESET}" >&2
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

    if apply_config_and_restart "配置已写入，但 ${SERVICE_NAME} 服务未成功运行，请查看状态或日志"; then
        echo -e "${GREEN}Hysteria2 配置已更新${RESET}"
        if [ "${regen_hy2_cert}" -eq 1 ]; then
            echo -e "${GREEN}HY2 TLS SNI 已从 ${old_sni} 修改为 ${hy2_sni}，证书已重新生成${RESET}"
        fi
        show_client_summary
    fi
}

protocol_status_text() {
    if has_protocol "$1"; then
        echo -e "${GREEN}已配置${RESET}"
    else
        echo -e "${RED}未配置${RESET}"
    fi
}

build_state_panel_cache() {
    local os_text core_text service_text protocol_text upstream_text log_text firewall_text

    if [ "${IS_ALPINE}" -eq 1 ]; then
        os_text="${YELLOW}Alpine Linux / OpenRC${RESET}"
    else
        os_text="${YELLOW}Standard Linux / systemd${RESET}"
    fi

    if [ "${SING_BOX_INSTALLED}" -eq 0 ]; then
        core_text="${GREEN}已安装${RESET}"
    else
        core_text="${RED}未安装${RESET}"
    fi

    if [ "${SING_BOX_RUNNING}" -eq 0 ]; then
        service_text="${GREEN}运行中${RESET}"
    else
        service_text="${YELLOW}未运行${RESET}"
    fi

    protocol_text="Reality $(protocol_status_text reality) | HY2 $(protocol_status_text hy2) | ShadowTLS $(protocol_status_text shadowtls) | Snell $(protocol_status_text snell) | VLESSWS $(protocol_status_text vlessws)"
    upstream_text="$(upstream_outbound_status_text)"
    log_text="$(log_status_text)"
    firewall_text="$(firewall_backend_label)"

    STATE_PANEL_TEXT=$(cat << EOF
系统: ${os_text}
核心: ${core_text}  服务: ${service_text}
协议: ${protocol_text}
出站: ${upstream_text}
日志: ${log_text}
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
    printf "%b\033[K\n" "${YELLOW}${title}${RESET}"
    printf '\033[K\n'

    for ((i = 0; i < MENU_COUNT; i++)); do
        prefix=" "
        label_color="${RESET}"
        if [ "${i}" -eq "${selected}" ]; then
            prefix="${YELLOW}>${RESET}"
            label_color="${GREEN}"
        fi

        printf "%b %2s. %b%s%b\033[K\n" "${prefix}" "${MENU_NUMBERS[$i]}" "${label_color}" "${MENU_LABELS[$i]}" "${RESET}"
    done

    printf '\033[K\n'
    printf "%b\033[K\n" "${YELLOW}当前选项说明${RESET}"
    printf "%b\033[K\n" "${GRAY}-----------------------------------------------------${RESET}"
    printf " %b\033[K\n" "${MENU_DESCS[$selected]}"
    printf "%b\033[K\n" "${GRAY}-----------------------------------------------------${RESET}"
    printf "%b\033[K\n" "${GRAY}↑/↓/j/k 移动   Enter/Space 确认   数字 快速选择   Esc/q 返回/退出${RESET}"
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

show_menu() {
    load_startup_ip_info
    import_existing_protocols
    if is_sing_box_installed; then
        SING_BOX_INSTALLED=0
    else
        SING_BOX_INSTALLED=1
    fi
    if is_sing_box_running; then
        SING_BOX_RUNNING=0
    else
        SING_BOX_RUNNING=1
    fi
    build_state_panel_cache

    menu_reset
    MENU_NEXT_NUMBER=1
    if [ "${SING_BOX_INSTALLED}" -ne 0 ]; then
        menu_add_auto "一键安装 Reality + HY2 + ShadowTLS + Snell" "推荐首次部署。自动安装 sing-box，依次配置四个协议，并在完成后输出全部节点。" "install_all"
        menu_add_auto "仅安装 VLESS Reality" "只部署 Reality，适合需要稳定 TCP + Reality 伪装的场景。" "install_reality"
        menu_add_auto "仅安装 Hysteria2" "只部署 HY2，可在安装流程中选择是否启用 UDP 端口跳跃。" "install_hy2"
        menu_add_auto "仅安装 ShadowTLS" "只部署 ShadowTLS + Shadowsocks，兼容已有 ShadowTLS 客户端配置。" "install_shadowtls"
        menu_add_auto "仅安装 Snell v6" "只部署 Snell v6，轻量加密 + 流量整形，需要 sing-box 1.14+ 与支持 v6 的客户端。" "install_snell"
        menu_add_auto "仅安装 VLESS WS TLS" "只部署 VLESS + WS + TLS，需要自有域名，可选 ACME 自动签发或自备证书文件，要求核心 1.14+。" "install_vlessws"
        menu_add "0" "退出程序" "不执行任何操作，直接退出。" "exit"
        interactive_select "请选择安装方案:"
    else
        if ! has_all_protocols; then
            menu_add_auto "一键补齐缺失协议" "只安装当前缺失的协议；已存在的协议会自动跳过，不重复覆盖。" "install_all"
        fi
        if ! has_protocol reality; then
            menu_add_auto "安装 VLESS Reality" "新增 Reality 协议，适合稳定 TCP + Reality 伪装场景。" "install_reality"
        fi
        if ! has_protocol hy2; then
            menu_add_auto "安装 Hysteria2" "新增 HY2 协议，并可选择配置 UDP 端口跳跃。" "install_hy2"
        fi
        if ! has_protocol shadowtls; then
            menu_add_auto "安装 ShadowTLS" "新增 ShadowTLS + Shadowsocks 协议。" "install_shadowtls"
        fi
        if ! has_protocol snell; then
            menu_add_auto "安装 Snell v6" "新增 Snell v6 协议；核心低于 1.14 时会先升级 sing-box。" "install_snell"
        fi
        if ! has_protocol vlessws; then
            menu_add_auto "安装 VLESS WS TLS" "新增 VLESS + WS + TLS 协议；需要自有域名，可选 ACME 自动签发或自备证书文件。" "install_vlessws"
        fi

        menu_add_auto "查看节点链接配置" "默认进入简洁摘要；完整 Clash / Sing-box / Sub-Store 配置可在二级菜单打开。" "view_config"
        menu_add_auto "配置上游出站" "可选设置 SOCKS5 / HTTP 上游；未设置时保持 direct，设置后作为 sing-box 默认出站。" "upstream_outbound"
        if [ "${SING_BOX_RUNNING}" -eq 0 ]; then
            menu_add_auto "停止 sing-box 服务" "停止正在运行的 sing-box 服务。" "toggle_service"
        else
            menu_add_auto "启动 sing-box 服务" "启动已安装的 sing-box 服务。" "toggle_service"
        fi
        menu_add_auto "重启 sing-box 服务" "重新加载服务，适合手动调整配置后使用。" "restart"
        menu_add_auto "查看 sing-box 状态" "调用系统服务管理器查看 sing-box 当前运行状态。" "status"
        menu_add_auto "查看 sing-box 日志" "实时跟踪 sing-box 日志，按 Ctrl+C 退出日志查看。" "logs"
        menu_add_auto "日志开关 / 清理" "开启或关闭 sing-box 日志；关闭时会清理历史日志，降低连接者 IP 暴露风险。" "logging"
        menu_add_auto "修改端口 / HY2 端口跳跃" "修改 Reality、HY2、ShadowTLS、Snell、VLESS WS TLS 端口，或重新配置 HY2 端口跳跃。" "change_ports"
        menu_add_auto "防火墙检测 / 自动放行" "检测防火墙后端，或手动放行当前协议端口；安装和改端口不会自动修改防火墙。" "firewall"
        menu_add_auto "删除指定协议" "选择并删除某个协议；如果没有剩余协议，会询问是否同时卸载。" "remove_protocol"
        menu_add_auto "完全卸载 sing-box" "停止服务并删除 sing-box、配置目录、日志和 HY2 端口跳跃规则。" "uninstall"
        menu_add "0" "退出程序" "不执行任何操作，直接退出。" "exit"
        interactive_select "请选择操作:"
    fi

    MAIN_CHOICE="${MENU_CHOICE}"
    echo ""
}

change_ports_menu() {
    local change_choice

    menu_reset
    menu_add "1" "VLESS Reality 端口 / 伪装域名" "修改 Reality 入站监听端口或伪装域名，并同步更新客户端分享信息。"
    menu_add "2" "Hysteria2 端口 / SNI / 端口跳跃" "修改 HY2 UDP 监听端口、TLS SNI，或开启、关闭、调整端口跳跃范围。"
    menu_add "3" "ShadowTLS 端口 / 伪装域名" "修改 ShadowTLS 外层端口、Shadowsocks 内层端口或 ShadowTLS 伪装域名。"
    menu_add "4" "Snell 端口" "修改 Snell 入站监听端口，并同步更新客户端信息。"
    menu_add "5" "VLESS WS TLS 端口" "修改 VLESS WS TLS 入站监听端口；域名与 WS 路径如需变更请删除后重装。"
    menu_add "0" "返回主菜单" "不修改端口，回到主菜单。"
    interactive_select "请选择要修改的协议:"
    change_choice="${MENU_CHOICE}"
    echo ""

    case "${change_choice}" in
        1) change_reality_port ;;
        2) change_hy2_port ;;
        3) change_shadowtls_port ;;
        4) change_snell_port ;;
        5) change_vlessws_port ;;
        0)
            SKIP_PAUSE=1
            return
            ;;
        *) echo -e "${RED}无效的选项，已返回主菜单${RESET}" >&2 ;;
    esac
}

remove_protocols_menu() {
    local remove_choice

    menu_reset
    menu_add "1" "删除 VLESS Reality" "删除 Reality 服务端片段和对应客户端信息。"
    menu_add "2" "删除 Hysteria2" "删除 HY2 配置、证书、客户端信息，并清理端口跳跃规则。"
    menu_add "3" "删除 ShadowTLS" "删除 ShadowTLS + Shadowsocks 入站片段和客户端信息。"
    menu_add "4" "删除 Snell" "删除 Snell 入站片段和客户端信息。"
    menu_add "5" "删除 VLESS WS TLS" "删除 VLESS WS TLS 入站片段、客户端信息和状态文件。"
    menu_add "6" "删除全部协议" "删除 Reality、HY2、ShadowTLS、Snell、VLESS WS TLS；若无剩余协议，会继续询问是否卸载核心。"
    menu_add "0" "返回主菜单" "不删除任何协议，回到主菜单。"
    interactive_select "请选择要删除的协议:"
    remove_choice="${MENU_CHOICE}"
    echo ""

    case "${remove_choice}" in
        1) remove_protocols reality ;;
        2) remove_protocols hy2 ;;
        3) remove_protocols shadowtls ;;
        4) remove_protocols snell ;;
        5) remove_protocols vlessws ;;
        6) remove_protocols reality hy2 shadowtls snell vlessws ;;
        0)
            SKIP_PAUSE=1
            return
            ;;
        *) echo -e "${RED}无效的选项，已返回主菜单${RESET}" >&2 ;;
    esac
}

firewall_menu() {
    while true; do
        menu_reset
        menu_add "1" "检测当前防火墙状态" "读取当前防火墙后端、脚本管理记录，并逐项检查已配置协议端口是否放行。"
        menu_add "2" "自动放行当前协议端口" "按当前 Reality / HY2 / ShadowTLS / Snell / VLESS WS TLS 配置放行端口；若 HY2 启用端口跳跃，也会应用跳跃重定向规则。"
        menu_add "3" "复原脚本管理的防火墙规则" "删除本脚本自动放行的端口规则，并移除 HY2 端口跳跃重定向服务。"
        menu_add "0" "返回主菜单" "不修改防火墙，回到主菜单。"
        interactive_select "请选择防火墙操作:"

        case "${MENU_CHOICE}" in
            1)
                show_firewall_status
                read -r -p "按 Enter 键返回防火墙菜单..."
                ;;
            2)
                apply_current_firewall_rules
                read -r -p "按 Enter 键返回防火墙菜单..."
                ;;
            3)
                restore_managed_firewall_rules
                echo -e "${GREEN}已复原脚本管理的防火墙规则${RESET}"
                read -r -p "按 Enter 键返回防火墙菜单..."
                ;;
            0)
                SKIP_PAUSE=1
                return
                ;;
        esac
    done
}

# 通过统一前置守卫收敛主循环中重复的安装态校验
run_if_installed() {
    if [ "${SING_BOX_INSTALLED}" -eq 0 ]; then
        "$@"
    else
        echo -e "${YELLOW}当前未安装 sing-box，请先选择 1-6 完成安装。${RESET}" >&2
    fi
}

toggle_sing_box_service() {
    if [ "${SING_BOX_RUNNING}" -eq 0 ]; then
        stop_sing_box
    else
        start_sing_box
    fi
}

trap 'printf "\033[?25h"; echo -e "\n${RED}已取消操作${RESET}"; exit' INT

check_root
check_time_sync

while true; do
    SKIP_PAUSE=0
    show_menu
    case "${MAIN_CHOICE}" in
        install_all)
            install_protocols reality hy2 shadowtls snell
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
        install_snell)
            install_protocols snell
            ;;
        install_vlessws)
            install_protocols vlessws
            ;;
        view_config)
            run_if_installed client_config_menu
            ;;
        upstream_outbound)
            run_if_installed upstream_outbound_menu
            ;;
        toggle_service)
            run_if_installed toggle_sing_box_service
            ;;
        restart)
            run_if_installed restart_sing_box
            ;;
        status)
            run_if_installed status_sing_box
            ;;
        logs)
            run_if_installed log_sing_box
            ;;
        logging)
            run_if_installed logging_menu
            ;;
        change_ports)
            run_if_installed change_ports_menu
            ;;
        firewall)
            run_if_installed firewall_menu
            ;;
        remove_protocol)
            run_if_installed remove_protocols_menu
            ;;
        uninstall)
            run_if_installed uninstall_sing_box
            ;;
        0|exit)
            echo -e "${GREEN}已退出 sing-box 管理工具${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选项，请重新选择${RESET}" >&2
            ;;
    esac
    if [ "${SKIP_PAUSE:-0}" -eq 0 ]; then
        read -r -p "按 Enter 键继续..."
    fi
done
