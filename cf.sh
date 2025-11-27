#!/bin/bash

# ==============================================================================
# Cloudflared 隧道管理脚本 (V4.2 - 终极美化增强版)
# 功能：自动架构检测、配置管理、安全备份、UI美化、自动更新、版本对比
# ==============================================================================

# --- 全局变量与配置 ---
CONFIG_DIR="/etc/cloudflared"
CONFIG_FILE="$CONFIG_DIR/config.yml"
CRED_DIR="/root/.cloudflared"
GH_PROXY="https://ghfast.top/" # GitHub 加速代理，如果是国外机器可留空 ""
SCRIPT_URL="https://raw.githubusercontent.com/ioiy/hinas-cf/main/cf.sh" # 脚本更新地址

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
    echo -e "${CYAN}    Cloudflared Tunnel Manager ${YELLOW}($current_ver Enhanced)${PLAIN}"
    echo -e "${BLUE}=============================================================${PLAIN}"
    echo -e "  ${PLAIN}专注于管理本机隧道配置、域名路由与服务状态"
    echo -e "  ${PLAIN}当前架构: ${YELLOW}$(uname -m)${PLAIN} | 配置文件: ${YELLOW}$CONFIG_FILE${PLAIN}"
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
    local deps=("wget" "curl" "grep" "sed" "awk" "systemctl")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
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
    # 使用 curl 获取跳转后的 URL 来确定版本号，超时设置 5 秒
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
        read -p "是否强制重新安装? (y/N): " choice
    else
        read -p "是否开始安装/更新? (y/N): " choice
    fi

    if [[ ! "$choice" =~ ^[yY]$ ]]; then
        msg_info "操作已取消。"
        pause
        return
    fi

    # 开始下载
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
        # 备份旧配置
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

    # 提取 UUID
    TUNNEL_UUID=$(echo "$CREATE_OUTPUT" | grep -oP 'created tunnel \K[a-f0-9-]{36}')
    
    if [ -z "$TUNNEL_UUID" ]; then
        msg_warn "自动提取 UUID 失败。"
        echo "$CREATE_OUTPUT"
        read -p "请手动输入上方显示的 UUID: " TUNNEL_UUID
    fi

    local CRED_FILE="$CRED_DIR/${TUNNEL_UUID}.json"
    msg_success "隧道创建成功！UUID: ${CYAN}$TUNNEL_UUID${PLAIN}"

    # 初始域名设置
    echo ""
    echo -e "${YELLOW}--- 配置第一个服务 ---${PLAIN}"
    read -p "请输入访问域名 (例如: nas.example.com): " HOSTNAME
    read -p "请输入本地服务 (直接输入端口如 8080 或完整地址 http://...): " SERVICE_INPUT

    # 智能补全本地地址
    local SERVICE_URL="$SERVICE_INPUT"
    if [[ "$SERVICE_INPUT" =~ ^[0-9]+$ ]]; then
        SERVICE_URL="http://127.0.0.1:$SERVICE_INPUT"
        msg_info "已自动补全本地地址为: $SERVICE_URL"
    fi

    # 写入配置文件
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

# 辅助：获取 Python 解析脚本 (用于读取 YAML)
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
        # 简单状态机
        if line.strip() == 'ingress:':
            in_ingress = True
            continue
        if not in_ingress: continue
        
        # 匹配 hostname
        m_host = re.match(r'^\s*-\s*hostname:\s*(.+)$', line)
        if m_host:
            current_host = m_host.group(1).strip()
            # 预读取下一行找 service (假设格式规范)
            continue
            
        # 匹配 service
        m_svc = re.match(r'^\s*service:\s*(.+)$', line)
        if m_svc:
            svc = m_svc.group(1).strip()
            if 'http_status:404' in svc: break
            # 如果之前读到了 hostname，这里尝试匹配
            # 这是一个简化的解析，假设 hostname 和 service 是成对出现的
            pass 
            
    # 由于 bash/python 交互复杂，这里使用更简单的纯正则提取用于显示
    content = "".join(lines)
    # 查找所有 hostname 和 service 对
    # 这是一个非贪婪匹配
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
        # Python 方式 (更准)
        python3 -c "$(get_python_parser)" "$CONFIG_FILE" | while IFS='|' read -r host svc; do
             printf "${GREEN}%-30s${PLAIN} | ${YELLOW}%-30s${PLAIN}\n" "$host" "$svc"
        done
    else
        # Bash 兜底方式
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
        echo "3. 返回主菜单"
        echo ""
        read -p "请选择: " dom_choice

        case $dom_choice in
            1)
                add_domain_logic
                ;;
            2)
                delete_domain_logic
                ;;
            3)
                return
                ;;
            *)
                msg_error "无效输入"
                sleep 1
                ;;
        esac
    done
}

add_domain_logic() {
    if [ ! -f "$CONFIG_FILE" ]; then
        msg_error "找不到配置文件，请先创建隧道。"
        pause; return
    fi

    # 获取隧道名称 (用于 DNS)
    local TUNNEL_UUID=$(grep "^tunnel:" "$CONFIG_FILE" | awk '{print $2}')
    if [ -z "$TUNNEL_UUID" ]; then
        msg_error "配置文件中无法读取 Tunnel UUID。"
        pause; return
    fi

    echo ""
    read -p "请输入新域名 (例如: plex.example.com): " NEW_HOST
    read -p "请输入本地端口或地址 (例如 32400 或 http://192.168.1.5:80): " SVC_IN

    # 智能补全
    local NEW_SVC="$SVC_IN"
    if [[ "$SVC_IN" =~ ^[0-9]+$ ]]; then
        NEW_SVC="http://127.0.0.1:$SVC_IN"
    fi

    msg_info "将添加映射: $NEW_HOST -> $NEW_SVC"
    
    # 备份
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

    # 使用 sed 在 http_status:404 之前插入两行
    # 注意：这里假设 yaml 缩进是 2 个空格，这是 cloudflared 默认格式
    # 插入逻辑：找到 '- service: http_status:404'，在它前面插入 hostname 和 service
    
    local INSERT_STR="  - hostname: $NEW_HOST\n    service: $NEW_SVC"
    
    if grep -q "http_status:404" "$CONFIG_FILE"; then
        sed -i "/- service: http_status:404/i $INSERT_STR" "$CONFIG_FILE"
    else
        # 如果没有 404 规则，直接追加
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

    # 备份
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    msg_info "正在删除配置..."
    
    # 删除 hostname 行以及它后面的一行 (service 行)
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
    echo ""
    systemctl status cloudflared --no-pager
    echo ""
    echo -e "${BLUE}操作选项:${PLAIN}"
    echo "1. 启动服务"
    echo "2. 停止服务"
    echo "3. 重启服务"
    echo "4. 设置开机自启"
    echo "5. 返回"
    
    read -p "请选择: " svc_opt
    case $svc_opt in
        1) systemctl start cloudflared && msg_success "已启动";;
        2) systemctl stop cloudflared && msg_warn "已停止";;
        3) systemctl restart cloudflared && msg_success "已重启";;
        4) systemctl enable cloudflared && msg_success "已设置开机自启";;
        *) return ;;
    esac
    pause
}

update_script() {
    print_logo
    echo -e "${CYAN}=== 脚本自我更新 ===${PLAIN}"
    msg_info "正在检查脚本更新..."
    
    local TEMP_FILE="/tmp/cf_manager_new.sh"
    local DOWNLOAD_URL="${SCRIPT_URL}"
    
    # 如果配置了 GH_PROXY 且 SCRIPT_URL 是 github 链接
    if [[ -n "$GH_PROXY" && "$SCRIPT_URL" == *"github"* ]]; then
        DOWNLOAD_URL="${GH_PROXY}${SCRIPT_URL}"
    fi
    
    # 1. 下载新版本到临时文件
    msg_info "正在获取最新脚本版本..."
    wget --no-check-certificate -q -O "$TEMP_FILE" "$DOWNLOAD_URL"
    
    if [ $? -ne 0 ]; then
        msg_error "下载失败，请检查网络。"
        rm -f "$TEMP_FILE"
        pause
        return
    fi
    
    # 2. 完整性检查
    if ! grep -q "Cloudflared Tunnel Manager" "$TEMP_FILE"; then
        msg_error "文件校验失败 (无效的文件内容)。"
        rm -f "$TEMP_FILE"
        pause
        return
    fi

    # 3. 版本对比
    local CURRENT_SCRIPT_VER=$(get_script_version "$0")
    local REMOTE_SCRIPT_VER=$(get_script_version "$TEMP_FILE")

    echo ""
    echo -e "----------------------------------------"
    echo -e "当前脚本版本: ${YELLOW}$CURRENT_SCRIPT_VER${PLAIN}"
    echo -e "最新脚本版本: ${GREEN}$REMOTE_SCRIPT_VER${PLAIN}"
    echo -e "----------------------------------------"
    echo ""

    if [[ "$CURRENT_SCRIPT_VER" == "$REMOTE_SCRIPT_VER" ]]; then
        read -p "版本已是最新，是否强制覆盖? (y/N): " choice
    else
        read -p "发现新版本，是否更新? (y/N): " choice
    fi

    if [[ ! "$choice" =~ ^[yY]$ ]]; then
        msg_info "更新已取消。"
        rm -f "$TEMP_FILE"
        pause
        return
    fi

    # 4. 执行更新
    # 备份当前脚本
    cp "$0" "${0}.bak"
    msg_info "已备份当前脚本到 ${0}.bak"
    
    # 替换
    mv "$TEMP_FILE" "$0"
    chmod +x "$0"
    
    msg_success "脚本已更新！即将重新加载..."
    sleep 2
    # 重新执行
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
    echo -e "0. 退出"
    echo ""
    read -p "请输入选项 [0-7]: " choice

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
        0) exit 0 ;;
        *) msg_error "无效选项"; sleep 1 ;;
    esac
done
