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
        if [ "$IS_ALPINE" -eq 1 ]; then
            apk update && apk add iproute2
        elif command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y iproute2 iptables
        elif command -v yum &> /dev/null; then
            yum install -y iproute iptables
        elif command -v dnf &> /dev/null; then
            dnf install -y iproute iptables
        elif command -v pacman &> /dev/null; then
            pacman -Sy --noconfirm iproute2 iptables
        elif command -v zypper &> /dev/null; then
            zypper install -y iproute2 iptables
        else
            echo -e "${RED}无法检测到支持的包管理器，请手动安装 iproute2 包${RESET}"
            exit 1
        fi
        
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
        port=${port:-$((RANDOM % 60000 + 1024))}

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

# 防火墙配置：拦截 SS 端口的外网 TCP 访问，仅放行 UDP
config_firewall() {
    local ssport=$1
    echo -e "${CYAN}正在配置防火墙以拦截外部对 SS 端口 (${ssport}) 的 TCP 访问...${RESET}"
    
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        ufw deny proto tcp from any to any port "$ssport"
        ufw allow proto udp from any to any port "$ssport"
        echo -e "${GREEN}已添加 UFW 规则 (阻断 TCP, 放行 UDP)${RESET}"
    elif command -v iptables &> /dev/null; then
        if ! iptables -C INPUT -p tcp --dport "$ssport" -j DROP &> /dev/null 2>&1; then
            iptables -I INPUT -p tcp --dport "$ssport" -j DROP
            echo -e "${GREEN}已添加 iptables 规则 (阻断外部 TCP)${RESET}"
            
            # 尝试保存规则以防重启失效
            if command -v netfilter-persistent &> /dev/null; then
                netfilter-persistent save &> /dev/null
            elif command -v iptables-save &> /dev/null; then
                [ -d /etc/iptables ] && iptables-save > /etc/iptables/rules.v4
            fi
        else
            echo -e "${YELLOW}iptables 规则已存在，跳过添加${RESET}"
        fi
    else
        echo -e "${YELLOW}未检测到活跃的防火墙 (UFW/iptables)，建议手动配置防火墙拦截端口 $ssport 的 TCP 访问。${RESET}"
    fi
}

# 移除防火墙规则（卸载时调用）
remove_firewall_rule() {
    local ssport=$1
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        ufw delete deny proto tcp from any to any port "$ssport" &> /dev/null
        ufw delete allow proto udp from any to any port "$ssport" &> /dev/null
    elif command -v iptables &> /dev/null; then
        iptables -D INPUT -p tcp --dport "$ssport" -j DROP &> /dev/null
        if command -v netfilter-persistent &> /dev/null; then
            netfilter-persistent save &> /dev/null
        fi
    fi
}

# 安装 sing-box
install_sing_box() {
    echo -e "${CYAN}正在安装 sing-box${RESET}"
    check_ss_command

    if [ "$IS_ALPINE" -eq 1 ]; then
        echo -e "${YELLOW}检测到 Alpine Linux，使用 apk 安装...${RESET}"
        for repo in community testing; do
            if ! grep -q "edge/$repo" /etc/apk/repositories; then
                echo "https://dl-cdn.alpinelinux.org/alpine/edge/$repo" >> /etc/apk/repositories
            fi
        done
        apk update && apk add sing-box
        if [ $? -ne 0 ]; then
            echo -e "${RED}sing-box 安装失败，请检查错误信息${RESET}"
            exit 1
        fi
    else
        bash <(curl -fsSL https://sing-box.app/deb-install.sh) || {
            echo -e "${RED}sing-box 安装失败！请检查网络连接或安装脚本来源。${RESET}"
            exit 1
        }
    fi

    # 获取端口、SNI 及密码配置
    sport=$(get_valid_port "请输入 ShadowTLS 外网端口（sport，1-65535）[回车随机]: ")
    ssport=$(get_valid_port "请输入 Shadowsocks 内网端口（ssport，1-65535）[回车随机]: ")
    
    read -p "请输入 ShadowTLS 伪装域名 (SNI) [默认: gateway.icloud.com]: " sni_domain
    sni_domain=${sni_domain:-gateway.icloud.com}

    ss_password=$(sing-box generate rand 16 --base64)
    password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)

    host_ip=$(curl -s http://checkip.amazonaws.com)
    ip_country=$(curl -s http://ipinfo.io/${host_ip}/country)

    # 生成配置文件
    mkdir -p "${CONFIG_DIR}"
    cat > "${CONFIG_FILE}" << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
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
        "server": "${sni_domain}",
        "server_port": 443
      },
      "strict_mode": true
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

    # 配置防火墙拦截 SS 的外网 TCP
    config_firewall "${ssport}"
    # 记录 ssport 以便卸载时清理规则
    echo "${ssport}" > "${CONFIG_DIR}/.ssport"

    # 启用并启动服务
    if [ "$IS_ALPINE" -eq 1 ]; then
        rc-update add "${SERVICE_NAME}" default
        rc-service "${SERVICE_NAME}" start
    else
        systemctl enable "${SERVICE_NAME}"
        systemctl restart "${SERVICE_NAME}"
    fi

    if ! is_sing_box_running; then
        echo -e "${RED}${SERVICE_NAME} 服务未成功启动！${RESET}"
        exit 1
    fi

    # 输出客户端配置
    {
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
      host: ${sni_domain}
      password: ${password}
      version: 3
    smux:
      enabled: true
EOF
        echo
        echo "ss://2022-blake3-aes-128-gcm:${ss_password}==@${host_ip}:${ssport}#${ip_country}"
        echo
        echo "${ip_country} = Shadowsocks,${host_ip},${sport},2022-blake3-aes-128-gcm,\"${ss_password}\",shadow-tls-password=${password},shadow-tls-sni=${sni_domain},shadow-tls-version=3,udp-port=${ssport},fast-open=false,udp=true"
    } > "${CLIENT_CONFIG_FILE}"

    echo -e "${GREEN}sing-box 安装与防火墙配置成功！${RESET}"
    cat "${CLIENT_CONFIG_FILE}"
}

uninstall_sing_box() {
    read -p "$(echo -e "${RED}确定要卸载 sing-box 吗? (Y/n) ${RESET}")" choice
    choice=${choice:-Y}
    case "${choice}" in
        y|Y)
            echo -e "${CYAN}正在卸载 sing-box${RESET}"
            
            # 移除防火墙规则
            if [ -f "${CONFIG_DIR}/.ssport" ]; then
                local old_ssport=$(cat "${CONFIG_DIR}/.ssport")
                remove_firewall_rule "$old_ssport"
                echo -e "${GREEN}已清理相关防火墙规则${RESET}"
            fi

            if [ "$IS_ALPINE" -eq 1 ]; then
                rc-service "${SERVICE_NAME}" stop
                rc-update del "${SERVICE_NAME}" default
                apk del sing-box
            else
                systemctl stop "${SERVICE_NAME}"
                systemctl disable "${SERVICE_NAME}"
                dpkg --purge sing-box || yum remove -y sing-box &> /dev/null
                systemctl daemon-reload
            fi

            rm -rf "${CONFIG_DIR}"
            [ -f "/usr/local/bin/sing-box" ] && rm /usr/local/bin/sing-box

            echo -e "${GREEN}sing-box 卸载成功${RESET}"
            ;;
        *)
            echo -e "${YELLOW}已取消卸载操作${RESET}"
            ;;
    esac
}

start_sing_box() {
    if [ "$IS_ALPINE" -eq 1 ]; then rc-service "${SERVICE_NAME}" start; else systemctl start "${SERVICE_NAME}"; fi
    [ $? -eq 0 ] && echo -e "${GREEN}${SERVICE_NAME} 服务成功启动${RESET}" || echo -e "${RED}${SERVICE_NAME} 服务启动失败${RESET}"
}

stop_sing_box() {
    if [ "$IS_ALPINE" -eq 1 ]; then rc-service "${SERVICE_NAME}" stop; else systemctl stop "${SERVICE_NAME}"; fi
    [ $? -eq 0 ] && echo -e "${GREEN}${SERVICE_NAME} 服务成功停止${RESET}" || echo -e "${RED}${SERVICE_NAME} 服务停止失败${RESET}"
}

restart_sing_box() {
    if [ "$IS_ALPINE" -eq 1 ]; then rc-service "${SERVICE_NAME}" restart; else systemctl restart "${SERVICE_NAME}"; fi
    [ $? -eq 0 ] && echo -e "${GREEN}${SERVICE_NAME} 服务成功重启${RESET}" || echo -e "${RED}${SERVICE_NAME} 服务重启失败${RESET}"
}

status_sing_box() {
    if [ "$IS_ALPINE" -eq 1 ]; then rc-service "${SERVICE_NAME}" status; else systemctl status "${SERVICE_NAME}"; fi
}

log_sing_box() {
    echo -e "${CYAN}正在实时监控 sing-box 日志，按 Ctrl+C 退出${RESET}"
    journalctl -u sing-box -n 100 -f
}

check_sing_box() {
    [ -f "${CLIENT_CONFIG_FILE}" ] && cat "${CLIENT_CONFIG_FILE}" || echo -e "${YELLOW}配置文件不存在: ${CLIENT_CONFIG_FILE}${RESET}"
}

show_menu() {
    clear
    is_sing_box_installed
    sing_box_installed=$?
    is_sing_box_running
    sing_box_running=$?

    echo -e "${GREEN}=== sing-box 管理工具 (增强优化版) ===${RESET}"
    echo -e "安装状态: $(if [ ${sing_box_installed} -eq 0 ]; then echo -e "${GREEN}已安装${RESET}"; else echo -e "${RED}未安装${RESET}"; fi)"
    echo -e "运行状态: $(if [ ${sing_box_running} -eq 0 ]; then echo -e "${GREEN}已运行${RESET}"; else echo -e "${RED}未运行${RESET}"; fi)"
    echo ""
    echo "1. 安装 sing-box 服务"
    echo "2. 卸载 sing-box 服务"
    if [ ${sing_box_installed} -eq 0 ]; then
        if [ ${sing_box_running} -eq 0 ]; then
            echo "3. 停止 sing-box 服务"
        else
            echo "3. 启动 sing-box 服务"
        fi
        echo "4. 重启 sing-box 服务"
        echo "5. 查看 sing-box 状态"
        echo "6. 查看 sing-box 日志"
        echo "7. 查看 sing-box 配置"
    fi
    echo "0. 退出"
    echo -e "${GREEN}==========================================${RESET}"
    read -p "请输入选项编号: " choice
    echo ""
}

trap 'echo -e "\n${RED}已取消操作${RESET}"; exit' INT

check_root

while true; do
    show_menu
    case "${choice}" in
        1) [ ${sing_box_installed} -eq 0 ] && echo -e "${YELLOW}sing-box 已经安装！${RESET}" || install_sing_box ;;
        2) [ ${sing_box_installed} -eq 0 ] && uninstall_sing_box || echo -e "${YELLOW}sing-box 尚未安装！${RESET}" ;;
        3) if [ ${sing_box_installed} -eq 0 ]; then [ ${sing_box_running} -eq 0 ] && stop_sing_box || start_sing_box; else echo -e "${RED}未安装！${RESET}"; fi ;;
        4) [ ${sing_box_installed} -eq 0 ] && restart_sing_box || echo -e "${RED}未安装！${RESET}" ;;
        5) [ ${sing_box_installed} -eq 0 ] && status_sing_box || echo -e "${RED}未安装！${RESET}" ;;
        6) [ ${sing_box_installed} -eq 0 ] && log_sing_box || echo -e "${RED}未安装！${RESET}" ;;
        7) [ ${sing_box_installed} -eq 0 ] && check_sing_box || echo -e "${RED}未安装！${RESET}" ;;
        0) echo -e "${GREEN}已退出${RESET}"; exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
    read -p "按 Enter 键继续..."
done