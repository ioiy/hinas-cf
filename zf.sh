#!/bin/bash

# =================配置区域=================
CONF_FILE="/etc/socat-v2raya.conf"
SERVICE_FILE="/etc/systemd/system/socat-v2raya.service"
START_SCRIPT="/etc/socat-v2raya-start.sh"
BACKUP_DIR="/etc/socat-v2raya.backups"
AUDIT_LOG="/var/log/socat-v2raya-audit.log"
INSTALLED_FLAG="/etc/socat-v2raya.installed"
MAX_BACKUPS=10
VERSION="4.2"
SCRIPT_URL="https://raw.githubusercontent.com/ioiy/hinas-cf/main/zf.sh"
# =========================================

# 颜色定义 (仅在终端输出时启用，避免管道/重定向乱码)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
fi

# 检查 Root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请使用 sudo 运行此脚本！${NC}"
    exit 1
fi

# 信号处理: 释放锁并提示
cleanup_on_exit() {
    flock -u 200 2>/dev/null
}
trap 'echo -e "\n${YELLOW}操作已中断${NC}"; exit 130' INT TERM
trap cleanup_on_exit EXIT

# 配置文件并发锁 (防止多实例同时修改)
exec 200>"${CONF_FILE}.lock" 2>/dev/null
flock -x 200 2>/dev/null

# ==================== 工具函数 ====================

# 端口校验 (1-65535)
validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    return 0
}

# IP 地址校验 (IPv4 / IPv6 / 主机名)
validate_ip() {
    local ip=$1
    # IPv4
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            [ "$octet" -gt 255 ] && return 1
        done
        return 0
    fi
    # IPv6 (简单格式)
    [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && return 0
    # 主机名: 必须以字母数字开头和结尾，中间可含 . 和 -
    [[ "$ip" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] && return 0
    return 1
}

# 协议校验
validate_proto() {
    local proto=$1
    [[ "${proto^^}" == "TCP" || "${proto^^}" == "UDP" ]] && return 0
    return 1
}

# 解析配置行，输出: "disabled|lp|ip|tp|proto"，注释/空行返回空
parse_rule() {
    local line="$1"
    [[ -z "$line" ]] && return 1
    local re_dis='^#DISABLED '
    if [[ "$line" =~ ^# ]]; then
        if [[ ! "$line" =~ $re_dis ]]; then
            return 1
        fi
    fi
    local disabled="false"
    local lp ip tp proto

    if [[ "$line" =~ $re_dis ]]; then
        disabled="true"
        read -r _ lp ip tp proto <<< "$line"
    else
        read -r lp ip tp proto <<< "$line"
    fi

    proto=${proto:-TCP}
    echo "${disabled}|${lp}|${ip}|${tp}|${proto}"
    return 0
}

# 格式化字节数为人类可读 (纯 bash 算术，不 spawn 外部进程)
format_bytes() {
    local bytes=${1:-0}
    if (( bytes >= 1073741824 )); then
        local whole=$((bytes / 1073741824))
        local frac=$(( (bytes % 1073741824) * 100 / 1073741824 ))
        printf "%d.%02d GB" "$whole" "$frac"
    elif (( bytes >= 1048576 )); then
        local whole=$((bytes / 1048576))
        local frac=$(( (bytes % 1048576) * 100 / 1048576 ))
        printf "%d.%02d MB" "$whole" "$frac"
    elif (( bytes >= 1024 )); then
        local whole=$((bytes / 1024))
        local frac=$(( (bytes % 1024) * 100 / 1024 ))
        printf "%d.%02d KB" "$whole" "$frac"
    else
        printf "%d B" "$bytes"
    fi
}

# 添加 iptables 放行规则
add_iptables_rule() {
    local port=$1 proto=$2
    local proto_lower
    proto_lower=$(echo "$proto" | tr 'A-Z' 'a-z')
    if command -v iptables &>/dev/null; then
        iptables -C INPUT -p "$proto_lower" --dport "$port" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT 1 -p "$proto_lower" --dport "$port" -j ACCEPT 2>/dev/null
    fi
}

# 删除 iptables 放行规则 (循环删除所有匹配项)
remove_iptables_rule() {
    local port=$1 proto=$2
    local proto_lower
    proto_lower=$(echo "$proto" | tr 'A-Z' 'a-z')
    if command -v iptables &>/dev/null; then
        while iptables -D INPUT -p "$proto_lower" --dport "$port" -j ACCEPT 2>/dev/null; do
            :
        done
    fi
}

# 按行号精确替换 (用 awk，避免 sed 对特殊字符的解释问题)
replace_line() {
    local line_num=$1 new_text=$2 file=$3
    awk -v ln="$line_num" -v txt="$new_text" 'NR==ln{print txt; next} {print}' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# 操作审计日志
log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$AUDIT_LOG" 2>/dev/null
}

# 公共规则选择函数 (del/modify/toggle 复用)
# 设置全局: SELECTED_IDX, SELECTED_LINE_NUM, SELECTED_RAW, SELECTED_PARSED
# $1 = 提示文字
select_rule() {
    local prompt="$1"
    local rules=()
    local line_nums=()
    local raw_lines=()
    local i=1
    local line_num=0

    while IFS= read -r line; do
        ((line_num++))
        local parsed
        parsed=$(parse_rule "$line")
        [[ -z "$parsed" ]] && continue

        rules+=("$parsed")
        line_nums+=("$line_num")
        raw_lines+=("$line")
        IFS='|' read -r disabled lp ip tp proto <<< "$parsed"
        local status="启用"
        [[ "$disabled" == "true" ]] && status="禁用"
        echo "$i. [$status] $lp -> $ip:$tp [$proto]"
        ((i++))
    done < "$CONF_FILE"

    if [ ${#rules[@]} -eq 0 ]; then
        echo -e "${RED}当前无可用规则${NC}"
        read -n 1 -s -r -p "按任意键返回..."
        return 1
    fi

    read -p "$prompt (c 取消): " num
    [[ "$num" == "c" ]] && return 1

    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#rules[@]} ]; then
        echo -e "${RED}无效序号${NC}"
        return 1
    fi

    SELECTED_IDX=$((num-1))
    SELECTED_LINE_NUM="${line_nums[$SELECTED_IDX]}"
    SELECTED_RAW="${raw_lines[$SELECTED_IDX]}"
    SELECTED_PARSED="${rules[$SELECTED_IDX]}"
    return 0
}

# ==================== 核心功能 ====================

# 0. 环境自检
check_dependencies() {
    # 已安装标记存在且关键工具可用时跳过安装流程
    if [ -f "$INSTALLED_FLAG" ] && command -v socat &>/dev/null && command -v curl &>/dev/null; then
        # 仍需初始化配置
        if [ ! -f "$CONF_FILE" ]; then
            echo "30000 127.0.0.1 20172 TCP" > "$CONF_FILE"
            echo "30001 127.0.0.1 20171 TCP" >> "$CONF_FILE"
        fi
        return
    fi

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
            apt-get install -y socat curl iproute2 gawk > /dev/null 2>&1
        elif command -v dnf &> /dev/null; then
            dnf install -y socat curl iproute gawk > /dev/null 2>&1
        elif command -v yum &> /dev/null; then
            yum install -y socat curl iproute gawk > /dev/null 2>&1
        fi

        # 验证安装结果
        local install_ok=true
        for tool in socat curl; do
            if ! command -v "$tool" &> /dev/null; then
                install_ok=false
                echo -e "${RED}错误：$tool 安装失败！${NC}"
            fi
        done
        if [ "$install_ok" = true ]; then
            echo -e "${GREEN}依赖工具安装完成。${NC}"
            touch "$INSTALLED_FLAG"
        else
            echo -e "${RED}依赖安装不完整，部分功能可能不可用。${NC}"
        fi
    else
        touch "$INSTALLED_FLAG"
    fi

    # 初始化配置
    if [ ! -f "$CONF_FILE" ]; then
        echo "30000 127.0.0.1 20172 TCP" > "$CONF_FILE"
        echo "30001 127.0.0.1 20171 TCP" >> "$CONF_FILE"
    fi
}

# 重建服务 (核心逻辑) — 生成独立启动脚本，避免 ExecStart 过长和转义问题
rebuild_service() {
    echo -e "${BLUE}正在重构系统服务...${NC}"

    local has_active=false

    # 生成启动脚本
    cat > "$START_SCRIPT" << 'HEADER'
#!/bin/bash
HEADER

    while IFS= read -r line; do
        local parsed
        parsed=$(parse_rule "$line")
        [[ -z "$parsed" ]] && continue

        IFS='|' read -r disabled lp tip tp proto <<< "$parsed"
        [[ "$disabled" == "true" ]] && continue

        has_active=true
        if [[ "${proto^^}" == "UDP" ]]; then
            echo "/usr/bin/socat UDP4-LISTEN:${lp},fork UDP4:${tip}:${tp} &" >> "$START_SCRIPT"
        else
            echo "/usr/bin/socat TCP4-LISTEN:${lp},fork,reuseaddr TCP4:${tip}:${tp} &" >> "$START_SCRIPT"
        fi
        # 同步 iptables 规则 (确保已启用规则都有防火墙放行)
        add_iptables_rule "$lp" "$proto"
    done < "$CONF_FILE"
    if [ "$has_active" = false ]; then
        echo -e "${YELLOW}警告：没有启用的转发规则，服务将以空状态运行。${NC}"
        echo "sleep infinity" >> "$START_SCRIPT"
    else
        echo "wait" >> "$START_SCRIPT"
    fi

    chmod +x "$START_SCRIPT"

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Socat Port Forward Manager (v2raya)
After=network.target docker.service

[Service]
ExecStart=$START_SCRIPT
Type=simple
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
        echo -e "${RED}服务启动失败！请使用选项 9 查看日志。${NC}"
    fi
}

# 1. 连通性测试 (并行测试所有规则)
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

    # 并行测试: 每条规则一个后台任务，结果写入临时文件
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local seq=0
    local job_pids=()

    while IFS= read -r line; do
        local parsed
        parsed=$(parse_rule "$line")
        [[ -z "$parsed" ]] && continue

        IFS='|' read -r disabled lp tip tp proto <<< "$parsed"
        ((seq++))

        # 禁用或 UDP: 直接写结果，不启动后台任务
        if [[ "$disabled" == "true" ]]; then
            echo "${seq}|${YELLOW}%-10s${NC} %-15s %-8s ${YELLOW}%-20s${NC} %-10s|${lp}|${tp}|${proto}|跳过 (已禁用)|N/A" > "$tmp_dir/r_${seq}"
            continue
        fi
        if [[ "${proto^^}" == "UDP" ]]; then
            echo "${seq}|${CYAN}%-10s${NC} %-15s %-8s ${YELLOW}%-20s${NC} %-10s|${lp}|${tp}|UDP|跳过 (UDP不支持CURL)|N/A" > "$tmp_dir/r_${seq}"
            continue
        fi

        # 后台并行测试
        (
            local res_http http_code time_total
            res_http=$(curl -s -o /dev/null -m 3 -x http://127.0.0.1:${lp} -w "%{http_code} %{time_total}" "$test_url" 2>/dev/null)
            read -r http_code time_total <<< "$res_http"

            if [[ "$http_code" =~ ^[23] ]]; then
                local ms
                ms=$(awk "BEGIN {print int($time_total * 1000)}")
                echo "${seq}|${GREEN}%-10s${NC} %-15s %-8s ${GREEN}%-20s${NC} ${GREEN}%-10s${NC}|${lp}|${tp}|TCP|通 (HTTP代理)|${ms} ms" > "$tmp_dir/r_${seq}"
                exit 0
            fi

            local res_socks socks_code socks_total
            res_socks=$(curl -s -o /dev/null -m 3 -x socks5h://127.0.0.1:${lp} -w "%{http_code} %{time_total}" "$test_url" 2>/dev/null)
            read -r socks_code socks_total <<< "$res_socks"

            if [[ "$socks_code" =~ ^[23] ]]; then
                local ms
                ms=$(awk "BEGIN {print int($socks_total * 1000)}")
                echo "${seq}|${GREEN}%-10s${NC} %-15s %-8s ${GREEN}%-20s${NC} ${GREEN}%-10s${NC}|${lp}|${tp}|TCP|通 (SOCKS5代理)|${ms} ms" > "$tmp_dir/r_${seq}"
            else
                echo "${seq}|${RED}%-10s${NC} %-15s %-8s ${RED}%-20s${NC} ${RED}%-10s${NC}|${lp}|${tp}|TCP|连接超时 / 失败|Timeout" > "$tmp_dir/r_${seq}"
            fi
        ) &
        job_pids+=($!)
    done < "$CONF_FILE"

    # 等待所有后台任务完成
    for pid in "${job_pids[@]}"; do
        wait "$pid" 2>/dev/null
    done

    # 按序号顺序输出结果
    for s in $(seq 1 "$seq"); do
        if [ -f "$tmp_dir/r_${s}" ]; then
            local data
            data=$(cat "$tmp_dir/r_${s}")
            local r_seq r_fmt r_lp r_tp r_proto r_result r_latency
            IFS='|' read -r r_seq r_fmt r_lp r_tp r_proto r_result r_latency <<< "$data"
            printf "$r_fmt\n" "$r_lp" "$r_tp" "$r_proto" "$r_result" "$r_latency"
        fi
    done

    rm -rf "$tmp_dir"
    echo ""
    read -n 1 -s -r -p "按任意键返回菜单..."
}

# 2. 查看状态
show_status() {
    echo -e "\n${BLUE}=== 当前配置规则 ===${NC}"
    printf "%-4s %-8s %-12s %-15s %-10s %-5s\n" "序号" "状态" "本地端口" "目标IP" "目标端口" "协议"
    echo "------------------------------------------------------------------"
    local i=1
    while IFS= read -r line; do
        local parsed
        parsed=$(parse_rule "$line")
        [[ -z "$parsed" ]] && continue

        IFS='|' read -r disabled lp tip tp proto <<< "$parsed"
        if [[ "$disabled" == "true" ]]; then
            printf "${YELLOW}%-4s${NC} ${RED}%-8s${NC} %-12s -> %-15s : %-10s [%s]\n" "$i" "禁用" "$lp" "$tip" "$tp" "$proto"
        else
            printf "${YELLOW}%-4s${NC} ${GREEN}%-8s${NC} %-12s -> %-15s : %-10s [%s]\n" "$i" "启用" "$lp" "$tip" "$tp" "$proto"
        fi
        ((i++))
    done < "$CONF_FILE"

    echo -e "\n${BLUE}=== 服务运行状态 ===${NC}"
    if systemctl is-active --quiet socat-v2raya.service; then
        echo -e "Systemd: ${GREEN}Active (Running)${NC}"
    else
        echo -e "Systemd: ${RED}Failed / Stopped${NC}"
    fi

    echo -e "\n${BLUE}=== 端口监听状态 ===${NC}"
    # 精确提取启用端口，用 :(端口) 格式 grep 避免子串误匹配
    local ports=""
    while IFS= read -r line; do
        local parsed
        parsed=$(parse_rule "$line")
        [[ -z "$parsed" ]] && continue
        IFS='|' read -r disabled lp tip tp proto <<< "$parsed"
        [[ "$disabled" == "true" ]] && continue
        ports="${ports}${lp}|"
    done < "$CONF_FILE"
    ports=${ports%|}

    if [ -n "$ports" ] && command -v ss &>/dev/null; then
        ss -tulnp | grep -E ":(${ports}) " || echo "暂未监听到指定端口"
    else
        echo "暂无启用的规则，或 ss 命令不可用"
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回..."
}

# 3. 流量统计
show_traffic() {
    echo -e "\n${BLUE}=== 流量统计 (iptables 计数) ===${NC}"

    if ! command -v iptables &>/dev/null; then
        echo -e "${RED}错误：iptables 未安装，无法统计流量${NC}"
        read -n 1 -s -r -p "按任意键返回..."
        return
    fi

    printf "%-10s %-8s %-15s %-15s %-20s\n" "本地端口" "协议" "数据包" "流量" "目标"
    echo "------------------------------------------------------------------------"

    local has_rule=false
    while IFS= read -r line; do
        local parsed
        parsed=$(parse_rule "$line")
        [[ -z "$parsed" ]] && continue

        IFS='|' read -r disabled lp ip tp proto <<< "$parsed"
        [[ "$disabled" == "true" ]] && continue
        has_rule=true

        local proto_lower
        proto_lower=$(echo "$proto" | tr 'A-Z' 'a-z')

        # 从 iptables INPUT 链获取该端口的统计
        local stats
        stats=$(iptables -L INPUT -v -n 2>/dev/null | grep -E "dpt:${lp}([^0-9]|$)")

        if [[ -n "$stats" ]]; then
            local pkts bytes formatted
            pkts=$(echo "$stats" | head -1 | awk '{print $1}')
            bytes=$(echo "$stats" | head -1 | awk '{print $2}')
            formatted=$(format_bytes "$bytes")
            printf "${GREEN}%-10s${NC} %-8s %-15s %-15s %-20s\n" "$lp" "$proto" "$pkts" "$formatted" "${ip}:${tp}"
        else
            printf "${YELLOW}%-10s${NC} %-8s %-15s %-15s %-20s\n" "$lp" "$proto" "N/A" "N/A" "${ip}:${tp}"
        fi
    done < "$CONF_FILE"

    if [ "$has_rule" = false ]; then
        echo -e "${YELLOW}当前没有启用的转发规则${NC}"
    fi

    echo ""
    read -n 1 -s -r -p "按任意键返回..."
}

# 4. 添加端口
add_port() {
    echo -e "\n${GREEN}=== 添加转发规则 ===${NC}"
    read -p "本地监听端口 (如 30002): " l_port
    if ! validate_port "$l_port"; then
        echo -e "${RED}错误：无效端口 (1-65535)！${NC}"; return
    fi

    if grep -qE "(^|#DISABLED )$l_port " "$CONF_FILE"; then
        echo -e "${RED}错误：该端口在配置文件中已存在！${NC}"; return
    fi

    # 智能检查系统级端口冲突
    if command -v ss &>/dev/null; then
        if ss -tulnp | grep -q ":$l_port "; then
            echo -e "${YELLOW}警告：系统端口 $l_port 已被其他进程占用！${NC}"
            read -p "强行绑定可能会导致 socat 启动失败，是否继续？(y/n) [默认n]: " force_add
            if [[ "$force_add" != "y" ]]; then
                echo -e "${RED}操作已取消${NC}"
                return
            fi
        fi
    fi

    read -p "目标 IP (回车默认 127.0.0.1): " t_ip
    t_ip=${t_ip:-127.0.0.1}
    if ! validate_ip "$t_ip"; then
        echo -e "${RED}错误：无效目标 IP！${NC}"; return
    fi

    read -p "目标端口 (如 20171): " t_port
    if ! validate_port "$t_port"; then
        echo -e "${RED}错误：无效目标端口 (1-65535)！${NC}"; return
    fi

    read -p "协议 (1.TCP / 2.UDP) [默认1]: " proto_choice
    if [[ "$proto_choice" == "2" ]]; then proto="UDP"; else proto="TCP"; fi

    # 写入配置
    echo "$l_port $t_ip $t_port $proto" >> "$CONF_FILE"
    echo -e "${GREEN}已成功添加: $l_port -> $t_ip:$t_port [$proto]${NC}"
    log_action "添加规则: $l_port -> $t_ip:$t_port [$proto]"

    # 自动放行防火墙
    add_iptables_rule "$l_port" "$proto"

    rebuild_service
}

# 5. 删除端口 (按行号精确删除)
del_port() {
    echo -e "\n${YELLOW}=== 删除规则 ===${NC}"
    select_rule "输入序号删除" || return

    IFS='|' read -r disabled lp ip tp proto <<< "$SELECTED_PARSED"

    # 按行号精确删除
    sed -i "${SELECTED_LINE_NUM}d" "$CONF_FILE"
    echo -e "${GREEN}已成功删除规则: $lp -> $ip:$tp [$proto]${NC}"
    log_action "删除规则: $lp -> $ip:$tp [$proto]"

    # 清理对应的 iptables 规则
    remove_iptables_rule "$lp" "$proto"
    echo -e "${GREEN}已清理对应防火墙规则${NC}"

    rebuild_service
}

# 6. 修改端口 (按行号精确替换，带输入校验)
modify_port() {
    echo -e "\n${BLUE}=== 修改规则 ===${NC}"
    select_rule "输入序号修改" || return

    IFS='|' read -r o_disabled o_lp o_ip o_tp o_proto <<< "$SELECTED_PARSED"
    o_proto=${o_proto:-TCP}

    echo "修改规则 (直接回车保持原值):"
    read -p "本地端口 [$o_lp]: " n_lp; n_lp=${n_lp:-$o_lp}
    if ! validate_port "$n_lp"; then
        echo -e "${RED}错误：无效端口 (1-65535)！${NC}"; return
    fi

    read -p "目标 IP [$o_ip]: " n_ip; n_ip=${n_ip:-$o_ip}
    if ! validate_ip "$n_ip"; then
        echo -e "${RED}错误：无效目标 IP！${NC}"; return
    fi

    read -p "目标端口 [$o_tp]: " n_tp; n_tp=${n_tp:-$o_tp}
    if ! validate_port "$n_tp"; then
        echo -e "${RED}错误：无效目标端口 (1-65535)！${NC}"; return
    fi

    read -p "协议 (TCP/UDP) [$o_proto]: " n_proto; n_proto=${n_proto:-$o_proto}
    if ! validate_proto "$n_proto"; then
        echo -e "${RED}错误：协议仅支持 TCP 或 UDP！${NC}"; return
    fi

    # 构建新行 (保留禁用状态)
    local new_rule="${n_lp} ${n_ip} ${n_tp} ${n_proto^^}"
    if [[ "$o_disabled" == "true" ]]; then
        new_rule="#DISABLED ${new_rule}"
    fi

    # 按行号精确替换 (用 awk 避免 sed 特殊字符问题)
    replace_line "$SELECTED_LINE_NUM" "$new_rule" "$CONF_FILE"
    echo -e "${GREEN}规则已成功更新。${NC}"
    log_action "修改规则: $o_lp->$o_ip:$o_tp [$o_proto] => $n_lp->$n_ip:$n_tp [${n_proto^^}]"

    # 如果端口或协议变了，更新 iptables 规则
    if [[ "$n_lp" != "$o_lp" || "${n_proto^^}" != "${o_proto^^}" ]]; then
        remove_iptables_rule "$o_lp" "$o_proto"
        if [[ "$o_disabled" != "true" ]]; then
            add_iptables_rule "$n_lp" "${n_proto^^}"
        fi
    fi

    rebuild_service
}

# 7. 启用/禁用规则
toggle_rule() {
    echo -e "\n${BLUE}=== 启用/禁用规则 ===${NC}"
    select_rule "输入序号切换启用/禁用" || return

    IFS='|' read -r disabled lp ip tp proto <<< "$SELECTED_PARSED"

    local new_line
    if [[ "$disabled" == "true" ]]; then
        # 当前禁用 → 启用 (去掉 #DISABLED 前缀)
        new_line="${SELECTED_RAW/#\#DISABLED /}"
        replace_line "$SELECTED_LINE_NUM" "$new_line" "$CONF_FILE"
        echo -e "${GREEN}已启用: $lp -> $ip:$tp [$proto]${NC}"
        log_action "启用规则: $lp -> $ip:$tp [$proto]"
        add_iptables_rule "$lp" "$proto"
    else
        # 当前启用 → 禁用 (加 #DISABLED 前缀)
        new_line="#DISABLED ${SELECTED_RAW}"
        replace_line "$SELECTED_LINE_NUM" "$new_line" "$CONF_FILE"
        echo -e "${YELLOW}已禁用: $lp -> $ip:$tp [$proto]${NC}"
        log_action "禁用规则: $lp -> $ip:$tp [$proto]"
        remove_iptables_rule "$lp" "$proto"
    fi

    rebuild_service
}

# 8. 实时日志
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

# 9. 备份与恢复配置
backup_restore_config() {
    mkdir -p "$BACKUP_DIR"

    echo -e "\n${BLUE}=== 配置备份与恢复 ===${NC}"
    echo "1. 备份当前配置"
    echo "2. 恢复历史备份"
    echo "3. 返回主菜单"
    read -p "请选择 [1-3]: " br_choice

    case $br_choice in
        1)
            local backup_file="${BACKUP_DIR}/socat-v2raya_$(date +%Y%m%d_%H%M%S).conf"
            cp "$CONF_FILE" "$backup_file"
            echo -e "${GREEN}备份成功！配置文件已保存至: $backup_file${NC}"
            log_action "备份配置到: $backup_file"

            # 自动清理旧备份，仅保留最近 MAX_BACKUPS 份
            local backup_count
            backup_count=$(ls -1 "$BACKUP_DIR"/*.conf 2>/dev/null | wc -l)
            if [ "$backup_count" -gt "$MAX_BACKUPS" ]; then
                local to_delete=$((backup_count - MAX_BACKUPS))
                ls -t "$BACKUP_DIR"/*.conf | tail -n "$to_delete" | xargs rm -f
                echo -e "${YELLOW}已自动清理 ${to_delete} 个旧备份 (保留最近 ${MAX_BACKUPS} 份)${NC}"
            fi
            ;;
        2)
            local backups=()
            while IFS= read -r f; do
                backups+=("$f")
            done < <(ls -t "$BACKUP_DIR"/*.conf 2>/dev/null)

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
                    log_action "从备份恢复: $(basename "${backups[$((r_idx-1))]}")"
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

# 10. 在线更新脚本
update_script() {
    echo -e "\n${BLUE}=== 在线更新脚本 ===${NC}"
    echo -e "当前本地脚本版本: ${GREEN}${VERSION}${NC}"
    echo -e "正在连接 GitHub 获取最新版本信息..."

    local temp_file="/tmp/zf_update.sh"

    if ! curl -s -L -m 10 "$SCRIPT_URL" -o "$temp_file"; then
        echo -e "${RED}错误：无法连接到 GitHub，请检查网络连接！${NC}"
        rm -f "$temp_file"
        read -n 1 -s -r -p "按任意键返回..."
        return
    fi

    local remote_version
    remote_version=$(grep -E "^VERSION=" "$temp_file" | head -n 1 | cut -d'"' -f2)

    if [ -z "$remote_version" ]; then
        echo -e "${YELLOW}警告：远程文件解析版本号失败。${NC}"
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

    read -p "是否确认下载并更新脚本？(y/n) [默认n]: " confirm
    if [[ "$confirm" != "y" ]]; then
        echo -e "${YELLOW}已取消更新。${NC}"
        rm -f "$temp_file"
        read -n 1 -s -r -p "按任意键返回..."
        return
    fi

    read -p "警告：更新会覆盖当前运行脚本！请输入 [yes] 确认覆盖: " double_confirm
    if [[ "$double_confirm" != "yes" ]]; then
        echo -e "${YELLOW}二次确认未通过，已安全取消。${NC}"
        rm -f "$temp_file"
        read -n 1 -s -r -p "按任意键返回..."
        return
    fi

    # 校验下载文件合法性
    if grep -q "rebuild_service" "$temp_file" && grep -q "#!/bin/bash" "$temp_file"; then
        cp "$temp_file" "$0"
        chmod +x "$0"
        rm -f "$temp_file"
        log_action "脚本更新: $VERSION -> $remote_version"
        echo -e "${GREEN}脚本在线更新成功！正在重新载入新版本...${NC}"
        sleep 1.5
        exec "$0"
    else
        echo -e "${RED}错误：下载的脚本文件校验失败，已放弃更新！${NC}"
        rm -f "$temp_file"
    fi
    read -n 1 -s -r -p "按任意键返回..."
}

# 11. 卸载 (停止服务并清理)
uninstall() {
    echo -e "\n${RED}=== 卸载端口转发管理 ===${NC}"
    echo -e "${YELLOW}此操作将执行以下清理：${NC}"
    echo "  1. 停止并禁用 socat-v2raya 服务"
    echo "  2. 删除 systemd 服务文件和启动脚本"
    echo "  3. 清理所有相关 iptables 规则"
    echo "  4. (可选) 删除配置文件和备份"
    echo ""
    echo -e "${RED}警告：此操作不可逆！${NC}"
    read -p "确认卸载？请输入 [yes] 确认: " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${YELLOW}已取消卸载。${NC}"
        read -n 1 -s -r -p "按任意键返回..."
        return
    fi

    # 1. 停止并禁用服务
    echo -e "${BLUE}正在停止服务...${NC}"
    systemctl stop socat-v2raya.service 2>/dev/null
    systemctl disable socat-v2raya.service 2>/dev/null
    echo -e "${GREEN}服务已停止并禁用${NC}"

    # 2. 删除服务文件和启动脚本
    if [ -f "$SERVICE_FILE" ]; then
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        echo -e "${GREEN}已删除服务文件: $SERVICE_FILE${NC}"
    fi
    rm -f "$START_SCRIPT" 2>/dev/null && echo -e "${GREEN}已删除启动脚本: $START_SCRIPT${NC}"

    # 3. 清理 iptables 规则
    echo -e "${BLUE}正在清理 iptables 规则...${NC}"
    local iptables_cleaned=0
    if command -v iptables &>/dev/null && [ -f "$CONF_FILE" ]; then
        while IFS= read -r line; do
            local parsed
            parsed=$(parse_rule "$line")
            [[ -z "$parsed" ]] && continue
            IFS='|' read -r disabled lp ip tp proto <<< "$parsed"
            remove_iptables_rule "$lp" "$proto"
            ((iptables_cleaned++))
        done < "$CONF_FILE"
    fi
    echo -e "${GREEN}已清理 ${iptables_cleaned} 条 iptables 规则${NC}"

    # 4. 可选删除配置和备份
    read -p "是否同时删除配置文件和备份？(y/n) [默认n]: " del_config
    if [[ "$del_config" == "y" ]]; then
        rm -f "$CONF_FILE"
        rm -rf "$BACKUP_DIR"
        rm -f "$INSTALLED_FLAG"
        echo -e "${GREEN}已删除配置文件、备份目录和安装标记${NC}"
    else
        echo -e "${YELLOW}已保留配置文件: $CONF_FILE${NC}"
    fi

    log_action "卸载完成 (iptables清理: ${iptables_cleaned})"
    echo -e "\n${GREEN}=== 卸载完成 ===${NC}"
    echo -e "${YELLOW}如需重新使用，请重新运行本脚本即可自动初始化。${NC}"
    read -n 1 -s -r -p "按任意键退出..."
    exit 0
}

# ==================== 主菜单 ====================
check_dependencies

while true; do
    clear
    echo -e "${BLUE}======================================${NC}"
    echo -e " 端口转发与代理管理 (v${VERSION})"
    echo -e "${BLUE}======================================${NC}"
    echo -e "${GREEN}1.${NC} 连通性测试 (多目标延迟测速)"
    echo -e "${GREEN}2.${NC} 查看系统状态 (规则 & 监听)"
    echo -e "${GREEN}3.${NC} 流量统计 (iptables 计数)"
    echo -e "--------------------------------------"
    echo -e "${GREEN}4.${NC} 添加转发规则"
    echo -e "${GREEN}5.${NC} 删除转发规则"
    echo -e "${GREEN}6.${NC} 修改转发规则"
    echo -e "${GREEN}7.${NC} 启用/禁用规则"
    echo -e "--------------------------------------"
    echo -e "${GREEN}8.${NC} 快速重启服务"
    echo -e "${GREEN}9.${NC} 查看运行日志"
    echo -e "${GREEN}10.${NC} 配置备份与恢复"
    echo -e "${GREEN}11.${NC} ${CYAN}一键在线更新 (GitHub)${NC}"
    echo -e "${GREEN}12.${NC} ${RED}卸载 (停止服务并清理)${NC}"
    echo -e "${GREEN}0.${NC} 退出脚本"
    echo -e "${BLUE}======================================${NC}"
    read -p "请输入选项: " choice

    case $choice in
        1) check_connectivity ;;
        2) show_status ;;
        3) show_traffic ;;
        4) add_port ;;
        5) del_port ;;
        6) modify_port ;;
        7) toggle_rule ;;
        8) systemctl restart socat-v2raya.service; echo "已发送重启指令"; sleep 1; show_status ;;
        9) view_logs ;;
        10) backup_restore_config ;;
        11) update_script ;;
        12) uninstall ;;
        0) exit 0 ;;
        *) echo "无效选项"; sleep 1 ;;
    esac
done
