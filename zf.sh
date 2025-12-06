#!/bin/bash

# =================配置区域=================
CONF_FILE="/etc/socat-v2raya.conf"
SERVICE_FILE="/etc/systemd/system/socat-v2raya.service"
TEST_URL="https://www.google.com"
# =========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 检查 Root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：请使用 sudo 运行此脚本！${NC}"
  exit 1
fi

# 0. 环境自检
check_dependencies() {
    local deps=("socat" "curl" "netstat")
    local install_needed=false

    for tool in "${deps[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            echo -e "${YELLOW}未检测到 $tool，准备安装...${NC}"
            install_needed=true
        fi
    done

    if [ "$install_needed" = true ]; then
        apt-get update -y > /dev/null 2>&1
        apt-get install -y socat curl net-tools > /dev/null 2>&1
        echo -e "${GREEN}依赖工具安装完成。${NC}"
    fi
    
    # 初始化配置
    if [ ! -f "$CONF_FILE" ]; then
        echo "30000 127.0.0.1 20172 TCP" > "$CONF_FILE"
        echo "30001 127.0.0.1 20171 TCP" >> "$CONF_FILE"
    fi
}

# 重建服务 (核心逻辑)
rebuild_service() {
    echo -e "${BLUE}正在重构系统服务...${NC}"
    
    CMD_STR="/bin/bash -c \""
    
    while read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        # 读取配置：本地端口 目标IP 目标端口 协议(默认TCP)
        read -r lp tip tp proto <<< "$line"
        proto=${proto:-TCP} # 默认 TCP
        
        if [[ "${proto^^}" == "UDP" ]]; then
            # UDP 转发命令
            CMD_STR+="/usr/bin/socat UDP4-LISTEN:${lp},fork UDP4:${tip}:${tp} & "
        else
            # TCP 转发命令
            CMD_STR+="/usr/bin/socat TCP4-LISTEN:${lp},fork TCP4:${tip}:${tp} & "
        fi
    done < "$CONF_FILE"
    
    CMD_STR+="wait -n\""

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Socat Port Forward Manager (v2raya)
After=network.target docker.service

[Service]
ExecStart=$CMD_STR
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable socat-v2raya.service > /dev/null 2>&1
    systemctl restart socat-v2raya.service
    
    if systemctl is-active --quiet socat-v2raya.service; then
        echo -e "${GREEN}服务已重启并正在运行！${NC}"
    else
        echo -e "${RED}服务启动失败！请使用选项 6 查看日志。${NC}"
    fi
}

# 1. 连通性测试 (Option 1)
check_connectivity() {
    echo -e "\n${BLUE}=== 代理连通性深度检测 (目标: $TEST_URL) ===${NC}"
    printf "%-10s %-15s %-8s %-20s\n" "本地端口" "目标端口" "协议" "测试结果"
    echo "---------------------------------------------------------------"
    
    while read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        read -r lp tip tp proto <<< "$line"
        proto=${proto:-TCP}

        if [[ "${proto^^}" == "UDP" ]]; then
            printf "${CYAN}%-10s${NC} %-15s %-8s ${YELLOW}跳过 (UDP不支持CURL检测)${NC}\n" "$lp" "$tp" "UDP"
            continue
        fi
        
        # HTTP 测试
        http_code=$(curl -x http://127.0.0.1:$lp -I -s -o /dev/null -w "%{http_code}" --connect-timeout 3 $TEST_URL)
        if [[ "$http_code" =~ ^[23] ]]; then
            printf "${GREEN}%-10s${NC} %-15s %-8s ${GREEN}通 (HTTP模式)${NC}\n" "$lp" "$tp" "TCP"
            continue
        fi

        # SOCKS5 测试
        socks_res=$(curl -x socks5h://127.0.0.1:$lp -I -s -o /dev/null --connect-timeout 3 $TEST_URL; echo $?)
        if [ "$socks_res" -eq 0 ]; then
             printf "${GREEN}%-10s${NC} %-15s %-8s ${GREEN}通 (SOCKS5模式)${NC}\n" "$lp" "$tp" "TCP"
        else
             printf "${RED}%-10s${NC} %-15s %-8s ${RED}连接超时 / 失败${NC}\n" "$lp" "$tp" "TCP"
        fi
        
    done < "$CONF_FILE"
    echo ""
    read -n 1 -s -r -p "按任意键返回菜单..."
}

# 2. 查看状态
show_status() {
    echo -e "\n${BLUE}=== 当前配置规则 ===${NC}"
    printf "%-4s %-12s %-15s %-10s %-5s\n" "序号" "本地端口" "目标IP" "目标端口" "协议"
    echo "---------------------------------------------------------"
    i=1
    while read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        read -r lp tip tp proto <<< "$line"
        proto=${proto:-TCP}
        printf "${YELLOW}%-4s${NC} %-12s -> %-15s : %-10s [%s]\n" "$i" "$lp" "$tip" "$tp" "$proto"
        ((i++))
    done < "$CONF_FILE"

    echo -e "\n${BLUE}=== 服务运行状态 ===${NC}"
    if systemctl is-active --quiet socat-v2raya.service; then
        echo -e "Systemd: ${GREEN}Active (Running)${NC}"
    else
        echo -e "Systemd: ${RED}Failed / Stopped${NC}"
    fi
    
    echo -e "\n${BLUE}=== 端口监听 (Netstat) ===${NC}"
    ports=$(awk '{print $1}' $CONF_FILE | tr '\n' '|')
    ports=${ports%|}
    if [ -n "$ports" ]; then
        netstat -antp | grep -E "($ports)" | grep LISTEN
        netstat -anup | grep -E "($ports)" # 增加UDP显示
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回..."
}

# 3. 添加端口 (支持 UDP)
add_port() {
    echo -e "\n${GREEN}=== 添加转发规则 ===${NC}"
    read -p "本地监听端口 (如 30002): " l_port
    if ! [[ "$l_port" =~ ^[0-9]+$ ]]; then echo -e "${RED}无效端口${NC}"; return; fi

    if grep -q "^$l_port " "$CONF_FILE"; then
        echo -e "${RED}端口已存在！${NC}"; return
    fi

    read -p "目标 IP (回车默认 127.0.0.1): " t_ip
    t_ip=${t_ip:-127.0.0.1}

    read -p "目标端口 (如 20171): " t_port
    
    read -p "协议 (1.TCP / 2.UDP) [默认1]: " proto_choice
    if [[ "$proto_choice" == "2" ]]; then proto="UDP"; else proto="TCP"; fi
    
    echo "$l_port $t_ip $t_port $proto" >> "$CONF_FILE"
    echo -e "${GREEN}已添加: $l_port -> $t_ip:$t_port [$proto]${NC}"
    
    # 自动处理防火墙
    if [[ "$proto" == "TCP" ]]; then
        iptables -I INPUT 1 -p tcp --dport "$l_port" -j ACCEPT >/dev/null 2>&1
    else
        iptables -I INPUT 1 -p udp --dport "$l_port" -j ACCEPT >/dev/null 2>&1
    fi
    
    rebuild_service
}

# 4. 删除端口
del_port() {
    echo -e "\n${YELLOW}=== 删除规则 ===${NC}"
    rules=()
    i=1
    while read -r line; do
        rules+=("$line")
        echo "$i. $line"
        ((i++))
    done < "$CONF_FILE"
    
    read -p "输入序号删除 (c 取消): " num
    [[ "$num" == "c" ]] && return
    
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#rules[@]} ]; then
        echo -e "${RED}无效序号${NC}"; return
    fi
    
    sed -i "${num}d" "$CONF_FILE"
    echo -e "${GREEN}已删除。${NC}"
    rebuild_service
}

# 5. 修改端口
modify_port() {
    echo -e "\n${BLUE}=== 修改规则 ===${NC}"
    rules=()
    i=1
    while read -r line; do
        rules+=("$line")
        echo "$i. $line"
        ((i++))
    done < "$CONF_FILE"

    read -p "输入序号修改 (c 取消): " num
    [[ "$num" == "c" ]] && return

    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#rules[@]} ]; then
        echo -e "${RED}无效序号${NC}"; return
    fi

    read -r o_lp o_ip o_tp o_proto <<< "${rules[$((num-1))]}"
    o_proto=${o_proto:-TCP}

    echo "修改规则 (直接回车保持原值):"
    read -p "本地端口 [$o_lp]: " n_lp; n_lp=${n_lp:-$o_lp}
    read -p "目标 IP [$o_ip]: " n_ip; n_ip=${n_ip:-$o_ip}
    read -p "目标端口 [$o_tp]: " n_tp; n_tp=${n_tp:-$o_tp}
    read -p "协议 [$o_proto]: " n_proto; n_proto=${n_proto:-$o_proto}

    sed -i "${num}c ${n_lp} ${n_ip} ${n_tp} ${n_proto}" "$CONF_FILE"
    echo -e "${GREEN}规则已更新。${NC}"
    rebuild_service
}

# 7. 实时日志 (增强版)
view_logs() {
    echo -e "\n${BLUE}=== 日志查看模式 ===${NC}"
    echo "1. 查看最近 50 行 (静态)"
    echo "2. 实时监控日志 (动态 - 按 Ctrl+C 退出)"
    read -p "请选择: " log_choice
    
    if [[ "$log_choice" == "2" ]]; then
        echo -e "${GREEN}正在进入实时监控模式...${NC}"
        journalctl -u socat-v2raya.service -f
    else
        journalctl -u socat-v2raya.service -n 50 --no-pager
        read -n 1 -s -r -p "按任意键返回..."
    fi
}

# 主循环
check_dependencies
while true; do
    clear
    echo -e "${BLUE}======================================${NC}"
    echo -e "   端口转发与代理管理 (v3.0 Ultimate)"
    echo -e "${BLUE}======================================${NC}"
    echo -e "${GREEN}1. 连通性测试 (检测 Google 连通性)${NC}"
    echo -e "2. 查看系统状态 (Status & Netstat)"
    echo -e "--------------------------------------"
    echo -e "3. 添加转发规则 (支持 TCP/UDP)"
    echo -e "4. 删除转发规则"
    echo -e "5. 修改转发规则"
    echo -e "--------------------------------------"
    echo -e "6. 快速重启服务"
    echo -e "7. 查看运行日志 (支持实时监控)"
    echo -e "8. 重建配置文件"
    echo -e "0. 退出脚本"
    echo -e "${BLUE}======================================${NC}"
    read -p "请输入选项: " choice

    case $choice in
        1) check_connectivity ;;
        2) show_status ;;
        3) add_port ;;
        4) del_port ;;
        5) modify_port ;;
        6) systemctl restart socat-v2raya.service; echo "已发送重启指令"; sleep 1; show_status ;;
        7) view_logs ;;
        8) rebuild_service ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
done