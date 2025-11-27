#!/bin/bash

# ==============================================================================
# Cloudflared 隧道管理脚本 (V4.8 - 终极全能稳定版)
# 功能：自动架构检测、配置管理、安全备份、UI美化、资源监控、备份管理
# V4.8变更：由于远程仓库源文件损坏，已暂时禁用自动更新功能以避免报错
# ==============================================================================

# --- 全局变量与配置 ---
CONFIG_DIR="/etc/cloudflared"
CONFIG_FILE="$CONFIG_DIR/config.yml"
CRED_DIR="/root/.cloudflared"
GH_PROXY="https://ghfast.top/" # GitHub 加速代理

# [重要] 远程更新源目前存在语法错误，已留空以禁用更新功能
SCRIPT_URL="" 
# 原地址备份 (等对方修复后再填回): https://raw.githubusercontent.com/ioiy/hinas-cf/main/cf.sh

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# --- 基础工具函数 ---

# 提取脚本版本号
get_script_version() {
    grep -o "V[0-9.]\+" "$1" | head -n 1
}

print_logo() {
    clear
    local current_ver=$(get_script_version "$0")
    echo -e "${BLUE}=============================================================${PLAIN}"
    echo -e "${CYAN}    Cloudflared Tunnel Manager ${YELLOW}($current_ver Stable)${PLAIN}"
    echo -e "${BLUE}=============================================================${PLAIN}"
    
    # --- 资源监控 (全局常驻) ---
    if pgrep cloudflared > /dev/null; then
        local pid=$(pgrep cloudflared | head -n 1)
        # 尝试获取资源信息
        local stats=""
        # 检查 ps 命令是否支持标准输出格式
        if ps -p "$pid" -o %cpu,%mem,etime >/dev/null 2>&1; then
            stats=$(ps -p "$pid" -o %cpu,%mem,etime --no-headers 2>/dev/null)
        fi
        
        if [ -n "$stats" ]; then
             local cpu=$(echo "$stats" | awk '{print $1}')
             local mem=$(echo "$stats" | awk '{print $2}')
             local time=$(echo "$stats" | awk '{print $3}')
             echo -e "  状态: ${GREEN}● 运行中${PLAIN} | CPU: ${YELLOW}${cpu}%${PLAIN} | 内存: ${YELLOW}${mem}%${PLAIN} | 时长: ${CYAN}${time}${PLAIN}"
        else
             # 降级显示 (当 ps 命令不支持参数时)
             echo -e "  状态: ${GREEN}● 运行中${PLAIN} (PID: $pid)"
        fi
    else
        echo -e "  状态: ${RED}● 未运行${PLAIN}"
    fi
    # -------------------------

    echo -e "  架构: ${YELLOW}$(uname -m)${PLAIN} | 配置: ${YELLOW}$CONFIG_FILE${PLAIN}"
    echo -e "${BLUE}-------------------------------------------------------------${PLAIN}"
}

msg_info() { echo -e "${BLUE}[INFO]${PLAIN} $1"; }
msg_success() { echo -e "${GREEN}[SUCCESS]${PLAIN} $1"; }
msg_warn() { echo -e "${YELLOW}[WARN]${PLAIN} $1"; }
msg_error() { echo -e "${RED}[ERROR]${PLAIN} $1"; }

pause() {
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

# --- 检查环境 ---

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}[错误] 此脚本必须以 root 权限运行。${PLAIN}"
        echo -e "请使用: ${YELLOW}sudo $0${PLAIN}"
        exit 1
    fi
}

check_dependencies() {
    local deps=("wget" "curl" "grep" "sed" "awk" "systemctl" "tar" "crontab")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            # crontab 特殊处理，有些系统叫 cronie
            if [[ "$dep" == "crontab" ]]; then continue; fi 
            msg_error "缺少必要命令: $dep"
            echo "请先安装它 (例如: apt install $dep 或 yum install $dep)"
            exit 1
        fi
    done
}

# --- 核心功能函数 ---

install_cloudflared() {
    print_logo
    echo -e "${CYAN}=== Cloudflared 更新/安装 ===${PLAIN}"
    echo -e "正在检测系统架构..."
    
    local ARCH=$(uname -m)
    local DOWNLOAD_ARCH=""
    
    case $ARCH in
        x86_64|amd64)  DOWNLOAD_ARCH="amd64" ;;
        aarch64|arm64) DOWNLOAD_ARCH="arm64" ;;
        armv7l|armhf)  DOWNLOAD_ARCH="arm" ;;
        i386|i686)     DOWNLOAD_ARCH="386" ;;
        *)
            msg_error "不支持的架构: $ARCH"
            return
            ;;
    esac
    msg_info "检测到架构: ${GREEN}$DOWNLOAD_ARCH${PLAIN}"

    # 1. 获取当前版本
    local LOCAL_VER="未安装"
    if command -v cloudflared &> /dev/null; then
        LOCAL_VER=$(cloudflared --version 2>/dev/null | awk '{print $3}' | sed 's/,//')
    fi

    # 2. 获取最新版本 (尝试从 GitHub 获取)
    msg_info "正在联网检查最新版本信息..."
    local LATEST_URL=$(curl -Ls -o /dev/null -w %{url_effective} --max-time 10 https://github.com/cloudflare/cloudflared/releases/latest)
    local REMOTE_VER=$(echo "$LATEST_URL" | awk -F'/' '{print $NF}')
    
    if [[ -z "$REMOTE_VER" || "$REMOTE_VER" == "latest" ]]; then
        REMOTE_VER="检测失败(网络问题)"
    fi

    echo ""
    echo -e "----------------------------------------"
    echo -e "当前版本: ${YELLOW}$LOCAL_VER${PLAIN}"
    echo -e "最新版本: ${GREEN}$REMOTE_VER${PLAIN}"
    echo -e "----------------------------------------"
    echo ""

    if [[ "$LOCAL_VER" == "$REMOTE_VER" && "$LOCAL_VER" != "未安装" ]]; then
        echo -e "${GREEN}当前已是最新版本。${PLAIN}"
        echo -e "1. 强制重新安装"
    else
        echo -e "1. 立即更新/安装"
    fi
    echo -e "0. 返回上一级"
    echo ""
    
    read -p "请选择 [1/0]: " choice

    if [[ "$choice" != "1" ]]; then
        msg_info "操作已取消。"
        pause
        return
    fi

    local BASE_URL="${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${DOWNLOAD_ARCH}"
    
    msg_info "开始下载: cloudflared-linux-${DOWNLOAD_ARCH}"
    wget --no-check-certificate -O /usr/bin/cloudflared "$BASE_URL"

    if [ $? -ne 0 ]; then
        msg_error "下载失败，请检查网络或更换代理设置。"
        rm -f /usr/bin/cloudflared
        pause
        return
    fi

    chmod 0755 /usr/bin/cloudflared
    mkdir -p $CONFIG_DIR
    
    msg_success "安装/更新完成！"
    cloudflared --version
    pause
}

login_cloudflare() {
    print_logo
    msg_info "即将开始登录流程..."
    echo -e "${YELLOW}提示：${PLAIN} 您将看到一个 URL，请在浏览器中打开它并授权域名。"
    echo -e "${YELLOW}提示：${PLAIN} 授权完成后，证书将自动下载。"
    echo ""
    
    cloudflared login
    
    if [ -f "$CRED_DIR/cert.pem" ]; then
        msg_success "登录成功！证书已保存。"
    else
        msg_warn "未检测到证书文件，请确认是否登录成功。"
    fi
    pause
}

create_tunnel_wizard() {
    print_logo
    echo -e "${CYAN}=== 创建新隧道向导 ===${PLAIN}"
    
    if [ -f "$CONFIG_FILE" ]; then
        msg_warn "检测到已存在配置文件：$CONFIG_FILE"
        read -p "是否覆盖并创建全新隧道？这会删除旧配置 (y/N): " choice
        if [[ ! "$choice" =~ ^[yY]$ ]]; then
            msg_info "操作已取消。"
            pause
            return
        fi
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        msg_info "旧配置已备份。"
    fi

    read -p "请输入隧道名称 (例如: my-nas): " TUNNEL_NAME
    [[ -z "$TUNNEL_NAME" ]] && { msg_error "名称不能为空"; pause; return; }

    msg_info "正在向 Cloudflare 请求创建隧道..."
    CREATE_OUTPUT=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1)
    
    if echo "$CREATE_OUTPUT" | grep -q "Error"; then
        msg_error "创建失败: $CREATE_OUTPUT"
        pause
        return
    fi

    TUNNEL_UUID=$(echo "$CREATE_OUTPUT" | grep -oP 'created tunnel \K[a-f0-9-]{36}')
    
    if [ -z "$TUNNEL_UUID" ]; then
        msg_warn "自动提取 UUID 失败。"
        echo "$CREATE_OUTPUT"
        read -p "请手动输入上方显示的 UUID: " TUNNEL_UUID
    fi

    local CRED_FILE="$CRED_DIR/${TUNNEL_UUID}.json"
    msg_success "隧道创建成功！UUID: ${CYAN}$TUNNEL_UUID${PLAIN}"

    echo ""
    echo -e "${YELLOW}--- 配置第一个服务 ---${PLAIN}"
    read -p "请输入访问域名 (例如: nas.example.com): " HOSTNAME
    read -p "请输入本地服务 (直接输入端口如 8080 或完整地址 http://...): " SERVICE_INPUT

    local SERVICE_URL="$SERVICE_INPUT"
    if [[ "$SERVICE_INPUT" =~ ^[0-9]+$ ]]; then
        SERVICE_URL="http://127.0.0.1:$SERVICE_INPUT"
        msg_info "已自动补全本地地址为: $SERVICE_URL"
    fi

    cat > "$CONFIG_FILE" << EOL
tunnel: $TUNNEL_UUID
credentials-file: $CRED_FILE
ingress:
  - hostname: $HOSTNAME
    service: $SERVICE_URL
  # 404 兜底规则 (切勿删除)
  - service: http_status:404
EOL

    msg_success "配置文件已生成。"
    msg_info "正在注册 DNS 记录..."
    cloudflared tunnel route dns "$TUNNEL_NAME" "$HOSTNAME"
    msg_info "正在安装并启动系统服务..."
    cloudflared service install 2>/dev/null
    systemctl daemon-reload
    systemctl enable cloudflared
    systemctl restart cloudflared

    if systemctl is-active --quiet cloudflared; then
        msg_success "服务启动成功！"
        echo -e "访问地址: ${GREEN}https://$HOSTNAME${PLAIN}"
    else
        msg_error "服务启动失败，请检查日志。"
        systemctl status cloudflared --no-pager
    fi
    pause
}

# --- 配置文件解析与操作 ---

get_python_parser() {
    cat << 'PYEOF'
import sys, re
try:
    with open(sys.argv[1], 'r') as f:
        lines = f.readlines()
    
    in_ingress = False
    results = []
    
    for line in lines:
        line = line.rstrip('\n')
        if line.strip() == 'ingress:':
            in_ingress = True
            continue
        if not in_ingress: continue
        
        m_host = re.match(r'^\s*-\s*hostname:\s*(.+)$', line)
        if m_host:
            current_host = m_host.group(1).strip()
            continue
            
        m_svc = re.match(r'^\s*service:\s*(.+)$', line)
        if m_svc:
            svc = m_svc.group(1).strip()
            if 'http_status:404' in svc: break
            pass 
            
    content = "".join(lines)
    matches = re.findall(r'-\s+hostname:\s+(.*?)\s+service:\s+(.*?)\n', content, re.DOTALL)
    for h, s in matches:
        s = s.strip()
        if 'http_status:404' not in s:
            print(f"{h.strip()}|{s}")

except Exception as e:
    pass
PYEOF
}

list_local_domains() {
    echo -e "${CYAN}--- 当前配置的域名列表 ($CONFIG_FILE) ---${PLAIN}"
    printf "%-30s | %-30s\n" "域名 (Hostname)" "指向本地服务 (Service)"
    echo "----------------------------------------------------------------"
    
    if command -v python3 &> /dev/null; then
        python3 -c "$(get_python_parser)" "$CONFIG_FILE" | while IFS='|' read -r host svc; do
             printf "${GREEN}%-30s${PLAIN} | ${YELLOW}%-30s${PLAIN}\n" "$host" "$svc"
        done
    else
        grep -B1 "service:" "$CONFIG_FILE" | grep "hostname:" -A1 | while read -r line; do
            if [[ "$line" =~ hostname: ]]; then
                host=$(echo "$line" | cut -d: -f2- | tr -d ' ')
                read -r next_line
                svc=$(echo "$next_line" | cut -d: -f2- | tr -d ' ')
                if [[ "$svc" != *"http_status:404"* ]]; then
                    printf "${GREEN}%-30s${PLAIN} | ${YELLOW}%-30s${PLAIN}\n" "$host" "$svc"
                fi
            fi
        done
    fi
    echo "----------------------------------------------------------------"
}

manage_domains() {
    while true; do
        print_logo
        echo -e "${CYAN}=== 域名与路由管理 ===${PLAIN}"
        list_local_domains
        echo ""
        echo "1. 添加新域名"
        echo "2. 删除域名"
        echo "0. 返回主菜单"
        echo ""
        read -p "请选择: " dom_choice

        case $dom_choice in
            1) add_domain_logic ;;
            2) delete_domain_logic ;;
            0) return ;;
            *) msg_error "无效输入"; sleep 1 ;;
        esac
    done
}

add_domain_logic() {
    if [ ! -f "$CONFIG_FILE" ]; then
        msg_error "找不到配置文件，请先创建隧道。"
        pause; return
    fi

    local TUNNEL_UUID=$(grep "^tunnel:" "$CONFIG_FILE" | awk '{print $2}')
    if [ -z "$TUNNEL_UUID" ]; then
        msg_error "配置文件中无法读取 Tunnel UUID。"
        pause; return
    fi

    echo ""
    read -p "请输入新域名 (例如: plex.example.com): " NEW_HOST
    read -p "请输入本地端口或地址 (例如 32400 或 http://192.168.1.5:80): " SVC_IN

    local NEW_SVC="$SVC_IN"
    if [[ "$SVC_IN" =~ ^[0-9]+$ ]]; then
        NEW_SVC="http://127.0.0.1:$SVC_IN"
    fi

    # --- 健康检查 ---
    msg_info "正在检测本地服务连通性..."
    if ! curl -s --connect-timeout 2 -I "$NEW_SVC" >/dev/null; then
         msg_warn "警告：无法连接到本地服务 $NEW_SVC"
         echo "这可能是因为：服务未启动、防火墙阻止或端口错误。"
         read -p "是否仍然要添加此路由? (y/N): " FORCE
         if [[ ! "$FORCE" =~ ^[yY]$ ]]; then
             msg_info "操作已取消。"
             return
         fi
    else
         msg_success "本地服务检测通畅。"
    fi
    # ----------------

    msg_info "将添加映射: $NEW_HOST -> $NEW_SVC"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

    local INSERT_STR="  - hostname: $NEW_HOST\n    service: $NEW_SVC"
    
    if grep -q "http_status:404" "$CONFIG_FILE"; then
        sed -i "/- service: http_status:404/i $INSERT_STR" "$CONFIG_FILE"
    else
        echo -e "$INSERT_STR" >> "$CONFIG_FILE"
        echo "  - service: http_status:404" >> "$CONFIG_FILE"
    fi

    if [ $? -eq 0 ]; then
        msg_success "配置已更新。"
        msg_info "正在添加 Cloudflare DNS 记录..."
        cloudflared tunnel route dns "$TUNNEL_UUID" "$NEW_HOST"
        msg_info "重启服务以应用更改..."
        systemctl restart cloudflared
        msg_success "完成！"
    else
        msg_error "修改配置文件失败，已恢复备份。"
        mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
    fi
    sleep 2
}

delete_domain_logic() {
    echo ""
    read -p "请输入要删除的完整域名 (例如: nas.example.com): " DEL_HOST
    
    if ! grep -q "$DEL_HOST" "$CONFIG_FILE"; then
        msg_error "配置文件中找不到域名: $DEL_HOST"
        sleep 2
        return
    fi

    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    msg_info "正在删除配置..."
    sed -i "/hostname: $DEL_HOST/,+1d" "$CONFIG_FILE"

    msg_success "已从本地配置移除。"
    msg_warn "注意：DNS 记录并未删除 (通常无需删除，它只会变无效)。"
    msg_info "重启服务..."
    systemctl restart cloudflared
    msg_success "完成！"
    sleep 2
}

service_status() {
    print_logo
    echo -e "${CYAN}=== 系统服务状态 ===${PLAIN}"
    # 资源监控已在 Logo 下方显示
    
    systemctl status cloudflared --no-pager
    echo ""
    echo -e "${BLUE}操作选项:${PLAIN}"
    echo "1. 启动服务"
    echo "2. 停止服务"
    echo "3. 重启服务"
    echo "4. 设置开机自启"
    echo "0. 返回主菜单"
    
    read -p "请选择: " svc_opt
    case $svc_opt in
        1) systemctl start cloudflared && msg_success "已启动";;
        2) systemctl stop cloudflared && msg_warn "已停止";;
        3) systemctl restart cloudflared && msg_success "已重启";;
        4) systemctl enable cloudflared && msg_success "已设置开机自启";;
        0) return ;;
        *) return ;;
    esac
    pause
}

# --- 高级工具箱功能 ---

toolbox_menu() {
    while true; do
        print_logo
        echo -e "${CYAN}=== 高级工具箱 ===${PLAIN}"
        echo "1. 查看实时日志 (Live Logs)"
        echo "2. 备份配置文件 (Backup Config)"
        echo "3. 切换传输协议 (QUIC/HTTP2)"
        echo "4. 管理备份文件 (删除/清理)"
        echo "5. 网络延迟检测 (Ping Cloudflare)"
        echo "0. 返回主菜单"
        echo ""
        read -p "请选择 [1-5, 0]: " t_choice
        
        case $t_choice in
            1) view_logs ;;
            2) backup_config ;;
            3) switch_protocol ;;
            4) manage_backups ;;
            5) network_test ;;
            0) return ;;
            *) msg_error "无效选项"; sleep 1 ;;
        esac
    done
}

view_logs() {
    print_logo
    echo -e "${CYAN}=== 实时日志监控 ===${PLAIN}"
    echo -e "${YELLOW}提示：日志将实时滚动显示。按 Ctrl + C 退出查看。${PLAIN}"
    echo ""
    sleep 2
    journalctl -u cloudflared -f
}

backup_config() {
    print_logo
    local BACKUP_FILE="/root/cloudflared_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    msg_info "正在打包配置文件..."
    
    if [ ! -d "$CONFIG_DIR" ] && [ ! -d "$CRED_DIR" ]; then
        msg_error "未找到配置目录，无法备份。"
        pause; return
    fi
    
    tar -czf "$BACKUP_FILE" "$CONFIG_DIR" "$CRED_DIR" 2>/dev/null
    
    if [ -f "$BACKUP_FILE" ]; then
        msg_success "备份成功！"
        echo -e "备份文件路径: ${GREEN}$BACKUP_FILE${PLAIN}"
    else
        msg_error "备份失败。"
    fi
    pause
}

manage_backups() {
    while true; do
        print_logo
        echo -e "${CYAN}=== 备份文件管理 ===${PLAIN}"
        
        # 获取所有备份文件并按名称排序
        local backups=($(ls $CONFIG_FILE.bak.* 2>/dev/null | sort))
        
        if [ ${#backups[@]} -eq 0 ]; then
            echo "没有找到备份文件。"
            echo ""
            read -n 1 -s -r -p "按任意键返回..."
            return
        fi

        echo -e "当前共有 ${#backups[@]} 个备份文件："
        echo "----------------------------------------"
        local i=1
        for bk in "${backups[@]}"; do
            echo -e " $i. $(basename "$bk")"
            let i++
        done
        echo "----------------------------------------"
        echo -e "输入 ${GREEN}数字序号${PLAIN} 删除指定文件"
        echo -e "输入 ${YELLOW}k${PLAIN} 保留最近5份并删除其他"
        echo -e "输入 ${RED}a${PLAIN} 删除所有备份"
        echo -e "输入 ${BLUE}0${PLAIN} 返回上一级"
        echo ""
        
        read -p "请输入操作: " op
        
        case $op in
            0) return ;;
            k) 
               if [ ${#backups[@]} -le 5 ]; then
                   msg_warn "备份数量未超过 5 个，无需清理。"
               else
                   ls -rt $CONFIG_FILE.bak.* | head -n -5 | xargs rm -f
                   msg_success "已清理旧备份，仅保留最新 5 份。"
               fi
               sleep 2
               ;;
            a)
               read -p "确认删除所有备份? (y/N): " confirm
               if [[ "$confirm" =~ ^[yY]$ ]]; then
                   rm -f $CONFIG_FILE.bak.*
                   msg_success "已清空所有备份。"
                   sleep 2
                   return
               fi
               ;;
            *)
               if [[ "$op" =~ ^[0-9]+$ ]] && [ "$op" -ge 1 ] && [ "$op" -le ${#backups[@]} ]; then
                   local file_idx=$((op-1))
                   local file_path="${backups[$file_idx]}"
                   rm -f "$file_path"
                   msg_success "已删除: $(basename "$file_path")"
                   sleep 1
               else
                   msg_error "无效选项"
                   sleep 1
               fi
               ;;
        esac
    done
}

switch_protocol() {
    print_logo
    echo -e "${CYAN}=== 切换传输协议 ===${PLAIN}"
    echo -e "默认协议为 QUIC (基于 UDP)。部分网络环境下可能会被阻断。"
    echo -e "切换到 http2 (基于 TCP) 可能提高连接稳定性。"
    echo ""
    
    local CURRENT_PROTO="QUIC (默认)"
    if grep -q "protocol: http2" "$CONFIG_FILE"; then
        CURRENT_PROTO="http2"
    fi
    
    echo -e "当前协议: ${YELLOW}$CURRENT_PROTO${PLAIN}"
    echo ""
    echo "1. 切换为 http2 (推荐网络不佳时使用)"
    echo "2. 恢复为 QUIC (默认)"
    echo "0. 返回上一级"
    
    read -p "请选择: " p_choice
    
    case $p_choice in
        1)
            if grep -q "protocol: http2" "$CONFIG_FILE"; then
                msg_info "已经是 http2 协议了。"
            else
                sed -i '1i protocol: http2' "$CONFIG_FILE"
                msg_success "已设置为 http2。"
                systemctl restart cloudflared
                msg_info "服务已重启。"
            fi
            ;;
        2)
            if grep -q "protocol: http2" "$CONFIG_FILE"; then
                sed -i '/protocol: http2/d' "$CONFIG_FILE"
                msg_success "已恢复为 QUIC。"
                systemctl restart cloudflared
                msg_info "服务已重启。"
            else
                msg_info "已经是 QUIC 协议了。"
            fi
            ;;
        0) return ;;
    esac
    pause
}

network_test() {
    print_logo
    echo -e "${CYAN}=== 网络延迟检测 ===${PLAIN}"
    echo "正在 Ping Cloudflare 边缘节点 (1.1.1.1)..."
    echo ""
    ping -c 4 1.1.1.1
    echo ""
    echo "正在 Ping Google (8.8.8.8)..."
    echo ""
    ping -c 4 8.8.8.8
    pause
}

install_token_mode() {
    print_logo
    echo -e "${CYAN}=== Token 模式安装 (Web Dashboard) ===${PLAIN}"
    echo -e "${YELLOW}注意：${PLAIN}此模式下，隧道路由完全由 Cloudflare 网页后台管理。"
    echo -e "本地的 config.yml 将失效，脚本的[管理域名]功能也将无法使用。"
    echo ""
    read -p "请输入 Cloudflare 提供的 Token (以 eyJh 开头的长串): " TOKEN
    
    if [ -z "$TOKEN" ]; then
        msg_error "Token 不能为空。"
        pause; return
    fi
    
    echo ""
    msg_info "正在停止当前服务..."
    systemctl stop cloudflared
    
    if [ -f "$CONFIG_FILE" ]; then
        msg_info "备份旧配置文件..."
        mv "$CONFIG_FILE" "${CONFIG_FILE}.bak.token_install"
    fi
    
    msg_info "正在安装 Token 服务..."
    cloudflared service install "$TOKEN"
    
    if [ $? -ne 0 ]; then
        msg_error "安装失败，请检查 Token 是否正确。"
        pause; return
    fi
    
    msg_success "Token 服务安装成功！"
    echo -e "请前往 Cloudflare Zero Trust Dashboard 查看连接状态。"
    pause
}

# --- 定时任务管理 ---

manage_cron() {
    print_logo
    echo -e "${CYAN}=== 定时重启任务 (Crontab) ===${PLAIN}"
    
    if ! command -v crontab &> /dev/null; then
        msg_error "系统中未找到 crontab 命令，无法管理定时任务。"
        pause; return
    fi
    
    local CRON_CMD="systemctl restart cloudflared"
    # 检查是否存在
    local EXISTS=$(crontab -l 2>/dev/null | grep "$CRON_CMD")
    
    if [ -n "$EXISTS" ]; then
        echo -e "当前状态: ${GREEN}已开启${PLAIN} (每天凌晨 4:00 重启)"
        echo ""
        echo "1. 关闭定时重启"
    else
        echo -e "当前状态: ${YELLOW}未开启${PLAIN}"
        echo ""
        echo "1. 开启定时重启 (每天凌晨 4:00)"
    fi
    echo "0. 返回主菜单"
    
    read -p "请选择: " c_choice
    
    if [[ "$c_choice" == "1" ]]; then
        if [ -n "$EXISTS" ]; then
            # 删除任务
            crontab -l 2>/dev/null | grep -v "$CRON_CMD" | crontab -
            msg_success "已关闭定时重启。"
        else
            # 添加任务 (0 4 * * *)
            (crontab -l 2>/dev/null; echo "0 4 * * * $CRON_CMD") | crontab -
            msg_success "已开启定时重启。"
        fi
    fi
    pause
}

uninstall_cloudflared() {
    print_logo
    echo -e "${RED}========================================${PLAIN}"
    echo -e "${RED}      危险操作：彻底卸载 Cloudflared      ${PLAIN}"
    echo -e "${RED}========================================${PLAIN}"
    echo -e "此操作将执行以下动作："
    echo -e "1. 停止并禁用 cloudflared 服务"
    echo -e "2. 删除 /usr/bin/cloudflared 执行文件"
    echo -e "3. 删除 /etc/cloudflared 配置目录"
    echo -e "4. 删除 /root/.cloudflared 凭证目录"
    echo -e "5. 删除 systemd 服务文件"
    echo ""
    echo -e "${YELLOW}请务必确认您已备份重要数据！${PLAIN}"
    echo ""
    read -p "请输入 'yes' 以确认执行卸载 (不含引号): " CONFIRM
    
    if [[ "$CONFIRM" != "yes" ]]; then
        msg_info "输入不匹配，操作已取消。"
        pause
        return
    fi
    
    msg_info "正在停止服务..."
    systemctl stop cloudflared
    systemctl disable cloudflared 2>/dev/null
    
    msg_info "正在清理文件..."
    rm -f /usr/bin/cloudflared
    rm -rf /etc/cloudflared
    rm -rf /root/.cloudflared
    rm -f /etc/systemd/system/cloudflared.service
    rm -f /usr/lib/systemd/system/cloudflared.service
    
    systemctl daemon-reload
    
    msg_success "Cloudflared 已从系统中彻底移除。"
    echo "脚本自身未被删除，您可以使用 'rm $0' 删除本脚本。"
    exit 0
}

update_script() {
    print_logo
    echo -e "${CYAN}=== 脚本自我更新 ===${PLAIN}"
    
    if [[ -z "$SCRIPT_URL" ]]; then
        msg_warn "未配置更新源 (SCRIPT_URL)。"
        echo -e "${YELLOW}原因：上游远程仓库代码存在损坏，为安全起见，自动更新已暂时禁用。${PLAIN}"
        pause; return
    fi
    
    msg_info "正在检查脚本更新..."
    local TEMP_FILE="/tmp/cf_manager_new.sh"
    local DOWNLOAD_URL="${SCRIPT_URL}"
    
    if [[ -n "$GH_PROXY" && "$SCRIPT_URL" == *"github"* ]]; then
        DOWNLOAD_URL="${GH_PROXY}${SCRIPT_URL}"
    fi
    
    msg_info "正在获取最新脚本版本..."
    wget --no-check-certificate -q -O "$TEMP_FILE" "$DOWNLOAD_URL"
    
    if [ $? -ne 0 ]; then
        msg_error "下载失败，请检查网络。"
        rm -f "$TEMP_FILE"
        pause
        return
    fi
    
    if ! grep -q "Cloudflared Tunnel Manager" "$TEMP_FILE"; then
        msg_error "文件校验失败 (无效的文件内容)。"
        rm -f "$TEMP_FILE"
        pause
        return
    fi
    
    # --- 关键修改：语法安全检查 ---
    # 这将拦截所有语法错误（如 'case $choice 在'），防止覆盖本地脚本
    if ! bash -n "$TEMP_FILE"; then
        echo ""
        msg_error "严重安全警告：下载的远程脚本包含语法错误！"
        echo -e "${RED}更新已被强制拦截。您本地的脚本未受影响。${PLAIN}"
        echo -e "错误原因可能是上游仓库代码损坏。"
        rm -f "$TEMP_FILE"
        pause
        return
    fi
    # ---------------------------

    local CURRENT_SCRIPT_VER=$(get_script_version "$0")
    local REMOTE_SCRIPT_VER=$(get_script_version "$TEMP_FILE")

    echo ""
    echo -e "----------------------------------------"
    echo -e "当前脚本版本: ${YELLOW}$CURRENT_SCRIPT_VER${PLAIN}"
    echo -e "最新脚本版本: ${GREEN}$REMOTE_SCRIPT_VER${PLAIN}"
    echo -e "----------------------------------------"
    echo ""

    if [[ "$CURRENT_SCRIPT_VER" == "$REMOTE_SCRIPT_VER" ]]; then
        echo -e "${GREEN}当前已是最新版本。${PLAIN}"
        echo -e "1. 强制覆盖更新"
    else
        echo -e "1. 立即更新"
    fi
    echo -e "0. 返回上一级"
    echo ""
    
    read -p "请选择 [1/0]: " choice

    if [[ "$choice" != "1" ]]; then
        msg_info "更新已取消。"
        rm -f "$TEMP_FILE"
        pause
        return
    fi

    cp "$0" "${0}.bak"
    msg_info "已备份当前脚本到 ${0}.bak"
    mv "$TEMP_FILE" "$0"
    chmod +x "$0"
    
    msg_success "脚本已更新！即将重新加载..."
    sleep 2
    exec "$0"
}

# --- 主逻辑 ---

check_root
check_dependencies

while true; do
    print_logo
    echo -e "1. ${GREEN}安装 / 更新 Cloudflared${PLAIN} ${YELLOW}(含版本检测)${PLAIN}"
    echo -e "2. ${GREEN}登录 Cloudflare 账户${PLAIN}"
    echo -e "3. ${GREEN}创建新隧道 (本机向导)${PLAIN}"
    echo -e "4. ${CYAN}管理域名 (添加/删除 本地路由)${PLAIN} ${RED}[常用]${PLAIN}"
    echo -e "5. ${CYAN}服务管理 (启动/停止/日志)${PLAIN}"
    echo -e "6. 列出云端所有隧道"
    echo -e "7. ${YELLOW}更新此脚本${PLAIN}"
    echo -e "8. ${BLUE}高级工具箱 (日志/备份/协议)${PLAIN}"
    echo -e "9. ${RED}彻底卸载 Cloudflared${PLAIN}"
    echo -e "10. ${CYAN}Token 模式安装 (网页端管理)${PLAIN}"
    echo -e "11. ${BLUE}定时重启任务 (Crontab)${PLAIN}"
    echo -e "0. 退出"
    echo ""
    read -p "请输入选项 [0-11]: " choice

    case $choice in
        1) install_cloudflared ;;
        2) login_cloudflare ;;
        3) create_tunnel_wizard ;;
        4) manage_domains ;;
        5) service_status ;;
        6) 
           print_logo
           cloudflared tunnel list
           pause
           ;;
        7) update_script ;;
        8) toolbox_menu ;;
        9) uninstall_cloudflared ;;
        10) install_token_mode ;;
        11) manage_cron ;;
        0) exit 0 ;;
        *) msg_error "无效选项"; sleep 1 ;;
    esac
done
