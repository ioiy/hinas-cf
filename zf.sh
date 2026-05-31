#!/bin/bash

# =================配置区域=================
CONF_FILE="/etc/socat-v2raya.conf"
SERVICE_FILE="/etc/systemd/system/socat-v2raya.service"
VERSION="3.6"
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
    local deps=("socat" "curl" "ss" "awk")
    local install_needed=false

    for tool in "${deps[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            echo -e "${YELLOW}未检测到 $tool，准备安装相关依赖...${NC}"
            install_needed=true
        fi
    done

    if [ "$install_needed" = true ]; then
        if command -v apt-get &> /dev/null; then
            apt-get update -y > /dev/null 2>&1
            apt-get install -y socat curl iproute2 awk > /dev/null 2>&1
        elif command -v yum &> /dev/null; then
            yum install -y socat curl iproute awk > /dev/null 2>&1
        fi
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
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable socat-v2raya.service > /dev/null 2>&1
    systemctl restart socat-v2raya.service
    
    if systemctl is-active --quiet socat-v2raya.service; then
        echo -e "${GREEN}服务已重启并正在运行！${NC}"
    else
        echo -e "${RED}服务启动失败！请使用选项 7 查看日志。${NC}"
    fi
}

# 1. 连通性测试 (Option 1)
check_connectivity() {
    echo -e "\n${BLUE}=== 请选择测试的目标链接 ===${NC}"
    echo "1. Google (测试代理翻墙连通性 - 默认)"
    echo "2. Cloudflare (测试 Anycast 节点延迟)"
    echo "3. GitHub (测试开发者服务连接)"
    echo "4. 百度 (测试国内直连延迟)"
    read -p "请输入序号 [1-4, 默认1]: " target_choice
    
    local test_url="https://www.google.com"
    local target_name="Google"
    
    case $target_choice in
        2) test_url="https://1.1.1.1"; target_name="Cloudflare" ;;
        3) test_url="https://github.com"; target_name="GitHub" ;;
        4) test_url="https://www.baidu.com"; target_name="Baidu" ;;
        *) test_url="https://www.google.com"; target_name="Google" ;;
    esac

    echo -e "\n${BLUE}=== 代理连通性深度检测 (目标: $target_name) ===${NC}"
    printf "%-10s %-15s %-8s %-20s %-10s\n" "本地端口" "目标端口" "协议" "测试结果" "连接延迟"
    echo "----------------------------------------------------------------------"
    
    while read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        read -r lp tip tp proto <<< "$line"
        proto=${proto:-TCP}

        if [[ "${proto^^}" == "UDP" ]]; then
            printf "${CYAN}%-10s${NC} %-15s %-8s ${YELLOW}%-20s${NC} %-10s\n" "$lp" "$tp" "UDP" "跳过 (UDP不支持CURL)" "N/A"
            continue
        fi
        
        # HTTP 测试并测算延迟
        local curl_cmd="curl -s -o /dev/null -m 3"
        
        # 1. 尝试 HTTP 代理模式测试
        local res_http=$( $curl_cmd -x http://127.0.0.1:$lp -w "%{http_code} %{time_total}" "$test_url" 2>/dev/null )
        read -r http_code time_total <<< "$res_http"
        
        if [[ "$http_code" =~ ^[23] ]]; then
            local ms=$(awk "BEGIN {print int($time_total * 1000)}")
            printf "${GREEN}%-10s${NC} %-15s %-8s ${GREEN}%-20s${NC} ${GREEN}%-10s${NC}\n" "$lp" "$tp" "TCP" "通 (HTTP代理)" "${ms} ms"
            continue
        fi

        # 2. 尝试 SOCKS5 代理模式测试
        local res_socks=$( $curl_cmd -x socks5h://127.0.0.1:$lp -w "%{http_code} %{time_total}" "$test_url" 2>/dev/null )
        read -r socks_code socks_total <<< "$res_socks"
        
        if [[ "$socks_code" =~ ^[23] || "$socks_code" == "000" && $(awk "BEGIN {print ($socks_total > 0)?1:0}") -eq 1 ]]; then
            local ms=$(awk "BEGIN {print int($socks_total * 1000)}")
            printf "${GREEN}%-10s${NC} %-15s %-8s ${GREEN}%-20s${NC} ${GREEN}%-10s${NC}\n" "$lp" "$tp" "TCP" "通 (SOCKS5代理)" "${ms} ms"
        else
            printf "${RED}%-10s${NC} %-15s %-8s ${RED}%-20s${NC} ${RED}%-10s${NC}\n" "$lp" "$tp" "TCP" "连接超时 / 失败" "Timeout"
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
    local i=1
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
    
    echo -e "\n${BLUE}=== 端口监听状态 (ss -tlnp) ===${NC}"
    local ports=$(awk '{print $1}' "$CONF_FILE" 2>/dev/null | tr '\n' '|')
    ports=${ports%|}
    if [ -n "$ports" ] && command -v ss &>/dev/null; then
        ss -tulnp | grep -E "($ports)"
    else
        echo "暂未监听到指定端口，或配置为空"
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回..."
}

# 3. 添加端口 (支持 UDP)
add_port() {
    echo -e "\n${GREEN}=== 添加转发规则 ===${NC}"
    read -p "本地监听端口 (如 30002): " l_port
    if ! [[ "$l_port" =~ ^[0-9]+$ ]]; then echo -e "${RED}错误：无效端口！${NC}"; return; fi

    if grep -q "^$l_port " "$CONF_FILE"; then
        echo -e "${RED}错误：该端口在配置文件中已存在！${NC}"; return
    fi

    # 智能检查系统级端口冲突
    if command -v ss &>/dev/null; then
        if ss -tulnp | grep -q ":$l_port "; then
            echo -e "${YELLOW}警告：系统端口 $l_port 已被非当前脚本关联的进程占用！${NC}"
            read -p "强行绑定可能会导致 socat 启动失败，是否继续？(y/n) [默认n]: " force_add
            if [[ "$force_add" != "y" ]]; then
                echo -e "${RED}操作已取消${NC}"
                return
            fi
        fi
    fi

    read -p "目标 IP (回车默认 127.0.0.1): " t_ip
    t_ip=${t_ip:-127.0.0.1}

    read -p "目标端口 (如 20171): " t_port
    if ! [[ "$t_port" =~ ^[0-9]+$ ]]; then echo -e "${RED}错误：无效目标端口！${NC}"; return; fi
    
    read -p "协议 (1.TCP / 2.UDP) [默认1]: " proto_choice
    if [[ "$proto_choice" == "2" ]]; then proto="UDP"; else proto="TCP"; fi
    
    # 写入配置
    echo "$l_port $t_ip $t_port $proto" >> "$CONF_FILE"
    echo -e "${GREEN}已成功添加: $l_port -> $t_ip:$t_port [$proto]${NC}"
    
    # 自动放行防火墙 (兼容 iptables)
    if command -v iptables &>/dev/null; then
        if [[ "$proto" == "TCP" ]]; then
            iptables -I INPUT 1 -p tcp --dport "$l_port" -j ACCEPT >/dev/null 2>&1
        else
            iptables -I INPUT 1 -p udp --dport "$l_port" -j ACCEPT >/dev/null 2>&1
        fi
    fi
    
    rebuild_service
}

# 4. 删除端口
del_port() {
    echo -e "\n${YELLOW}=== 删除规则 ===${NC}"
    local rules=()
    local i=1
    while read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        rules+=("$line")
        echo "$i. $line"
        ((i++))
    done < "$CONF_FILE"
    
    if [ ${#rules[@]} -eq 0 ]; then
        echo -e "${RED}当前无可用规则${NC}"
        read -n 1 -s -r -p "按任意键返回..."
        return
    fi

    read -p "输入序号删除 (c 取消): " num
    [[ "$num" == "c" ]] && return
    
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#rules[@]} ]; then
        echo -e "${RED}无效序号${NC}"; return
    fi
    
    # 基于内容精确定位删除
    local line_to_del="${rules[$((num-1))]}"
    sed -i "\|$line_to_del|d" "$CONF_FILE"
    echo -e "${GREEN}已成功删除规则。${NC}"
    rebuild_service
}

# 5. 修改端口
modify_port() {
    echo -e "\n${BLUE}=== 修改规则 ===${NC}"
    local rules=()
    local i=1
    while read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        rules+=("$line")
        echo "$i. $line"
        ((i++))
    done < "$CONF_FILE"

    if [ ${#rules[@]} -eq 0 ]; then
        echo -e "${RED}当前无可用规则${NC}"
        read -n 1 -s -r -p "按任意键返回..."
        return
    fi

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
    read -p "协议 (TCP/UDP) [$o_proto]: " n_proto; n_proto=${n_proto:-$o_proto}

    local old_rule="${rules[$((num-1))]}"
    local new_rule="${n_lp} ${n_ip} ${n_tp} ${n_proto^^}"
    
    # 替换对应行
    sed -i "s|$old_rule|$new_rule|g" "$CONF_FILE"
    echo -e "${GREEN}规则已成功更新。${NC}"
    rebuild_service
}

# 7. 实时日志
view_logs() {
    echo -e "\n${BLUE}=== 日志查看模式 ===${NC}"
    echo "1. 查看最近 50 行 (静态)"
    echo "2. 实时监控日志 (动态 - 按 Ctrl+C 退出)"
    read -p "请选择 [1-2]: " log_choice
    
    if [[ "$log_choice" == "2" ]]; then
        echo -e "${GREEN}正在进入实时监控模式...${NC}"
        journalctl -u socat-v2raya.service -f
    else
        journalctl -u socat-v2raya.service -n 50 --no-pager
        read -n 1 -s -r -p "按任意键返回..."
    fi
}

# 8. 备份与恢复配置
backup_restore_config() {
    local backup_dir="/etc/socat-v2raya.backups"
    mkdir -p "$backup_dir"

    echo -e "\n${BLUE}=== 配置备份与恢复 ===${NC}"
    echo "1. 备份当前配置"
    echo "2. 恢复历史备份"
    echo "3. 返回主菜单"
    read -p "请选择 [1-3]: " br_choice
    
    case $br_choice in
        1)
            local backup_file="${backup_dir}/socat-v2raya_$(date +%Y%m%d_%H%M%S).conf"
            cp "$CONF_FILE" "$backup_file"
            echo -e "${GREEN}备份成功！配置文件已保存至: $backup_file${NC}"
            ;;
        2)
            local backups=($(ls -t "$backup_dir"/*.conf 2>/dev/null))
            if [ ${#backups[@]} -eq 0 ]; then
                echo -e "${RED}没有找到历史备份文件！${NC}"
            else
                echo -e "${YELLOW}可用的备份文件列表（按时间倒序）：${NC}"
                for idx in "${!backups[@]}"; do
                    echo "$((idx+1)). $(basename "${backups[$idx]}")"
                done
                read -p "请选择要恢复的备份序号 (c 取消): " r_idx
                [[ "$r_idx" == "c" ]] && return
                if [[ "$r_idx" =~ ^[0-9]+$ ]] && [ "$r_idx" -ge 1 ] && [ "$r_idx" -le ${#backups[@]} ]; then
                    cp "${backups[$((r_idx-1))]}" "$CONF_FILE"
                    echo -e "${GREEN}配置已恢复，正在重构并启动服务...${NC}"
                    rebuild_service
                else
                    echo -e "${RED}无效输入！${NC}"
                fi
            fi
            ;;
        *)
            return
            ;;
    esac
    read -n 1 -s -r -p "按任意键返回..."
}

# 9. 在线更新脚本 (一键同步 GitHub 最新版)
update_script() {
    echo -e "\n${BLUE}=== 在线更新脚本 ===${NC}"
    echo -e "当前本地脚本版本: ${GREEN}${VERSION}${NC}"
    echo -e "正在连接 GitHub 获取最新版本信息..."
    
    local raw_url="https://raw.githubusercontent.com/ioiy/hinas-cf/main/zf.sh"
    local temp_file="/tmp/zf_update.sh"
    
    # 下载远程脚本临时文件用于提取版本号
    if ! curl -s -L -m 10 "$raw_url" -o "$temp_file"; then
        echo -e "${RED}错误：无法连接到 GitHub，请检查您的网络连接或代理！${NC}"
        rm -f "$temp_file"
        read -n 1 -s -r -p "按任意键返回..."
        return
    fi
    
    # 提取远程脚本里的 VERSION 变量定义
    local remote_version=$(grep -E "^VERSION=" "$temp_file" | head -n 1 | cut -d'"' -f2)
    
    if [ -z "$remote_version" ]; then
        echo -e "${YELLOW}警告：远程文件解析版本号失败，远程文件可能非本管理脚本。${NC}"
        remote_version="未知"
    fi
    
    echo -e "--------------------------------------"
    echo -e "本地当前版本: ${YELLOW}${VERSION}${NC}"
    echo -e "远程最新版本: ${CYAN}${remote_version}${NC}"
    echo -e "--------------------------------------"
    
    if [[ "$VERSION" == "$remote_version" ]]; then
        echo -e "${GREEN}您当前已经是最新版本，无需更新！${NC}"
    else
        echo -e "${YELLOW}检测到新版本可用！${NC}"
    fi
    
    # 第一次确认
    read -p "是否确认下载并更新脚本？(y/n) [默认n]: " confirm
    if [[ "$confirm" != "y" ]]; then
        echo -e "${YELLOW}已取消更新。${NC}"
        rm -f "$temp_file"
        read -n 1 -s -r -p "按任意键返回..."
        return
    fi
    
    # 第二次确认（输入完整 yes）
    read -p "警告：更新会覆盖当前运行脚本！请输入 [yes] 确认覆盖: " double_confirm
    if [[ "$double_confirm" != "yes" ]]; then
        echo -e "${YELLOW}二次确认未通过，已安全取消。${NC}"
        rm -f "$temp_file"
        read -n 1 -s -r -p "按任意键返回..."
        return
    fi
    
    # 再次检查临时文件的合法性
    if grep -q "rebuild_service" "$temp_file" && grep -q "#!/bin/bash" "$temp_file"; then
        mv "$temp_file" "$0"
        chmod +x "$0"
        echo -e "${GREEN}脚本在线更新成功！正在重新载入并运行新版本...${NC}"
        sleep 1.5
        exec "$0"
    else
        echo -e "${RED}错误：下载的脚本文件内容不完整，校验失败，已放弃更新！${NC}"
        rm -f "$temp_file"
    fi
    read -n 1 -s -r -p "按任意键返回..."
}

# 主循环
check_dependencies
while true; do
    clear
    echo -e "${BLUE}======================================${NC}"
    echo -e "    端口转发与代理管理 (v${VERSION} Ultimate)"
    echo -e "${BLUE}======================================${NC}"
    echo -e "${GREEN}1. 连通性测试 (支持多目标与延迟测速)${NC}"
    echo -e "2. 查看系统状态 (Status & ss 监听)"
    echo -e "--------------------------------------"
    echo -e "3. 添加转发规则 (带端口冲突智能检测)"
    echo -e "4. 删除转发规则"
    echo -e "5. 修改转发规则"
    echo -e "--------------------------------------"
    echo -e "6. 快速重启服务"
    echo -e "7. 查看运行日志 (支持实时监控)"
    echo -e "8. 配置备份与恢复"
    echo -e "9. ${CYAN}一键在线更新脚本 (GitHub)${NC}"
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
        8) backup_restore_config ;;
        9) update_script ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
done
