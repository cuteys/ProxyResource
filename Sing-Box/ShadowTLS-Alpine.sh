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
LOG_FILE="/var/log/singbox.log"
SERVICE_NAME="sing-box"
CLIENT_CONFIG_FILE="${CONFIG_DIR}/client.txt"

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
    rc-service "${SERVICE_NAME}" status &> /dev/null
    return $?
}

# 检查 ss 命令是否可用
check_ss_command() {
    if ! command -v ss &> /dev/null; then
        echo -e "${YELLOW}ss 命令未找到，正在尝试自动安装 iproute2 ${RESET}"
        apk update && apk add iproute2
        if command -v ss &> /dev/null; then
            echo -e "${GREEN}iproute2 安装成功，ss 命令已可用${RESET}"
        else
            echo -e "${RED}自动安装失败，请手动安装 iproute2 包${RESET}"
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
        return 0  # 端口被占用
    else
        return 1  # 端口未占用
    fi
}

# 获取有效端口号
get_valid_port() {
    local port
    while true; do
        read -p "$1" port
        port=${port:-$(generate_unused_port)}

        if [ -z "$port" ]; then
            port=$((RANDOM % 65535 + 1)) 
        fi

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

# 安装 sing-box
install_sing_box() {
    echo -e "${CYAN}正在安装 sing-box${RESET}"

    # 检查 ss 命令是否可用
    check_ss_command

    # 启用 edge 和 testing 存储库
    echo "启用 edge/community 和 edge/testing 仓库..."
    for repo in community testing; do
        if ! grep -q "edge/$repo" /etc/apk/repositories; then
            echo "https://dl-cdn.alpinelinux.org/alpine/edge/$repo" >> /etc/apk/repositories
        fi
    done

    # 更新 apk 索引
    apk update

    # 安装 sing-box
    apk add sing-box

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}sing-box 安装成功${RESET}"
    else
        echo -e "${RED}sing-box 安装失败，请检查错误信息${RESET}"
    fi

    # 获取端口参数，确保端口在有效范围内
    ssport=$(get_valid_port "请输入 Shadowsocks 端口（ssport，1-65535）：")
    sport=$(get_valid_port "请输入 ShadowTLS 端口（sport，1-65535）：")

    # 生成密码
    ss_password=$(sing-box generate rand 16 --base64)
    password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)

    # 获取本机 IP 地址和所在国家
    host_ip=$(curl -s http://checkip.amazonaws.com)
    ip_country=$(curl -s http://ipinfo.io/${host_ip}/country)

    # 生成配置文件
    cat > "${CONFIG_FILE}" << EOF
{
  "log": {
    "level": "info",
    "timestamp": true,
    "output": "${LOG_FILE}"
  },
  "dns": {
    "servers": [
      {
        "address": "https://1.1.1.1/dns-query",
        "strategy": "prefer_ipv4"
      },
      {
        "address": "https://8.8.8.8/dns-query",
        "strategy": "prefer_ipv4"
      }
    ]
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
        "server": "www.bing.com",
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

    # 启用并启动 sing-box 服务
    rc-update add "${SERVICE_NAME}" default || {
        echo -e "${RED}无法启用 ${SERVICE_NAME} 服务！${RESET}"
        exit 1
    }

    rc-service "${SERVICE_NAME}" start || {
        echo -e "${RED}无法启动 ${SERVICE_NAME} 服务！${RESET}"
        exit 1
    }

    # 检查服务状态
    if ! is_sing_box_running; then
        echo -e "${RED}${SERVICE_NAME} 服务未成功启动！${RESET}"
        rc-service "${SERVICE_NAME}" status
        exit 1
    fi

    # 输出客户端配置到文件
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
      host: www.bing.com
      password: ${password}
      version: 3
    smux:
      enabled: true
EOF

        echo
        echo "ss://2022-blake3-aes-128-gcm:${ss_password}==@${host_ip}:${ssport}#${ip_country}"
        echo
        echo "${ip_country} = Shadowsocks,${host_ip},${sport},2022-blake3-aes-128-gcm,\"${ss_password}\",shadow-tls-password=${password},shadow-tls-sni=www.bing.com,shadow-tls-version=3,udp-port=${ssport},fast-open=false,udp=true"
    } > "${CLIENT_CONFIG_FILE}"

    echo -e "${GREEN}sing-box 安装成功${RESET}"
    cat "${CLIENT_CONFIG_FILE}"
}

uninstall_sing_box() {
    read -p "$(echo -e "${RED}确定要卸载 sing-box 吗? (Y/n) ${RESET}")" choice
    choice=${choice:-Y}  # 默认设置为 Y
    case "${choice}" in
        y|Y)
            echo -e "${CYAN}正在卸载 sing-box${RESET}"

            # 停止服务
            rc-service "${SERVICE_NAME}" stop || {
                echo -e "${RED}停止 sing-box 服务失败。${RESET}"
            }
            
            # 禁用服务
            rc-update del "${SERVICE_NAME}" default || {
                echo -e "${RED}禁用 sing-box 服务失败。${RESET}"
            }

            # 卸载 sing-box（假设通过 apk 安装）
            apk del sing-box || {
                echo -e "${YELLOW}无法通过 apk 卸载 sing-box，可能未通过 apk 安装。${RESET}"
            }

            # 删除配置文件和日志
            rm -rf "${CONFIG_DIR}" || {
                echo -e "${YELLOW}无法删除 ${CONFIG_DIR}。${RESET}"
            }

            rm -f "${LOG_FILE}" || {
                echo -e "${YELLOW}无法删除 ${LOG_FILE}。${RESET}"
            }

            # 删除 sing-box 可执行文件（如存在）
            if [ -f "/usr/local/bin/sing-box" ]; then
                rm /usr/local/bin/sing-box || {
                    echo -e "${YELLOW}无法删除 /usr/local/bin/sing-box。${RESET}"
                }
            fi

            echo -e "${GREEN}sing-box 卸载成功${RESET}"
            ;;
        *)
            echo -e "${YELLOW}已取消卸载操作${RESET}"
            ;;
    esac
}

# 启动 sing-box
start_sing_box() {
    rc-service "${SERVICE_NAME}" start
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${SERVICE_NAME} 服务成功启动${RESET}"
    else
        echo -e "${RED}${SERVICE_NAME} 服务启动失败${RESET}"
    fi
}

# 停止 sing-box
stop_sing_box() {
    rc-service "${SERVICE_NAME}" stop
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${SERVICE_NAME} 服务成功停止${RESET}"
    else
        echo -e "${RED}${SERVICE_NAME} 服务停止失败${RESET}"
    fi
}

# 重启 sing-box
restart_sing_box() {
    rc-service "${SERVICE_NAME}" restart
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${SERVICE_NAME} 服务成功重启${RESET}"
    else
        echo -e "${RED}${SERVICE_NAME} 服务重启失败${RESET}"
    fi
}

# 查看 sing-box 状态
status_sing_box() {
    rc-service "${SERVICE_NAME}" status
}

# 查看 sing-box 日志
log_sing_box() {
    cat "${LOG_FILE}"
}


# 查看 sing-box 配置
check_sing_box() {
    if [ -f "${CLIENT_CONFIG_FILE}" ]; then
        cat "${CLIENT_CONFIG_FILE}"
    else
        echo -e "${YELLOW}配置文件不存在: ${CLIENT_CONFIG_FILE}${RESET}"
    fi
}

# 显示菜单
show_menu() {
    clear
    is_sing_box_installed
    sing_box_installed=$?
    is_sing_box_running
    sing_box_running=$?

    echo -e "${GREEN}=== sing-box 管理工具 ===${RESET}"
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
    echo -e "${GREEN}=========================${RESET}"
    read -p "请输入选项编号 (0-7): " choice
    echo ""
}

# 捕获 Ctrl+C 信号
trap 'echo -e "${RED}已取消操作${RESET}"; exit' INT

# 主循环
check_root

while true; do
    show_menu
    case "${choice}" in
        1)
            if [ ${sing_box_installed} -eq 0 ]; then
                echo -e "${YELLOW}sing-box 已经安装！${RESET}"
            else
                install_sing_box
            fi
            ;;
        2)
            if [ ${sing_box_installed} -eq 0 ]; then
                uninstall_sing_box
            else
                echo -e "${YELLOW}sing-box 尚未安装！${RESET}"
            fi
            ;;
        3)
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
        4)
            if [ ${sing_box_installed} -eq 0 ]; then
                restart_sing_box
            else
                echo -e "${RED}sing-box 尚未安装！${RESET}"
            fi
            ;;
        5)
            if [ ${sing_box_installed} -eq 0 ]; then
                status_sing_box
            else
                echo -e "${RED}sing-box 尚未安装！${RESET}"
            fi
            ;;
        6)
            if [ ${sing_box_installed} -eq 0 ]; then
                log_sing_box
            else
                echo -e "${RED}sing-box 尚未安装！${RESET}"
            fi
            ;;
        7)
            if [ ${sing_box_installed} -eq 0 ]; then
                check_sing_box
            else
                echo -e "${RED}sing-box 尚未安装！${RESET}"
            fi
            ;;
        0)
            echo -e "${GREEN}已退出 sing-box 管理工具${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选项，请输入有效的编号 (0-7)${RESET}"
            ;;
    esac
    read -p "按 Enter 键继续..."
done