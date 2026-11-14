#!/bin/bash

# ==============================================================================
# Cloudflared 隧道管理脚本 (V6.1 - 终极全能完整版)
# 功能：自动架构检测、配置管理、安全备份、UI美化、资源监控、备份管理
#       多隧道管理、Docker模式、配置导入导出、流量统计、systemd看门狗
#       一键诊断、服务模板库、隧道迁移、日志轮转、IPv6适配、配置diff预览
# V6.1变更：修复6个bug + 新增6个功能模块 (诊断/模板/迁移/轮转/IPv6/diff)
# V6.0变更：修复全部已知bug + 新增8个功能模块
# V5.2变更：添加针对老旧设备(armv7l等)的 2026.5.0 兼容版本一键降级选项
# V5.0变更：新增手动指定版本号功能，支持降级或安装特定历史版本
# ==============================================================================

# --- 全局变量与配置 ---
CONFIG_DIR="/etc/cloudflared"
CONFIG_FILE="$CONFIG_DIR/config.yml"
CRED_DIR="/root/.cloudflared"
CF_BIN="/usr/bin/cloudflared"
CF_CMD="cf"
SERVICE_NAME="cloudflared"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SERVICE_FILE_LIB="/usr/lib/systemd/system/${SERVICE_NAME}.service"
GH_PROXY="https://ghfast.top/" # GitHub 加速代理
DOCKER_IMAGE="cloudflare/cloudflared:latest"
DOCKER_CONTAINER="cloudflared"

# [恢复更新源] 配合下方的语法检查机制 (bash -n)，即使源文件损坏也能安全拦截
SCRIPT_URL="https://raw.githubusercontent.com/ioiy/hinas-cf/main/cf.sh"

# --- 颜色定义 (检测终端，非终端时禁用颜色) ---
if [ -t 1 ]; then
 RED='\033[0;31m'
 GREEN='\033[0;32m'
 YELLOW='\033[1;33m'
 BLUE='\033[0;34m'
 CYAN='\033[0;36m'
 PLAIN='\033[0m'
else
 RED=GREEN=YELLOW=BLUE=CYAN=PLAIN=''
fi

# --- 临时文件清理 (trap) ---
TEMP_FILES=()
cleanup() {
 for f in "${TEMP_FILES[@]}"; do
 rm -f "$f" 2>/dev/null
 done
}
trap cleanup EXIT INT TERM

register_temp() {
 TEMP_FILES+=("$1")
}

# --- 基础工具函数 ---

# 提取脚本版本号
get_script_version() {
 grep -o "V[0-9.]\+" "$1" | head -n 1
}

print_logo() {
 clear
 local current_ver=$(get_script_version "$0")
 echo -e "${BLUE}=============================================================${PLAIN}"
 echo -e "${CYAN} Cloudflared Tunnel Manager ${YELLOW}($current_ver Ultimate)${PLAIN}"
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
 echo -e " 状态: ${GREEN}● 运行中${PLAIN} | CPU: ${YELLOW}${cpu}%${PLAIN} | 内存: ${YELLOW}${mem}%${PLAIN} | 时长: ${CYAN}${time}${PLAIN}"
 else
 # 降级显示 (当 ps 命令不支持参数时)
 echo -e " 状态: ${GREEN}● 运行中${PLAIN} (PID: $pid)"
 fi
 else
 echo -e " 状态: ${RED}● 未运行${PLAIN}"
 fi
 # -------------------------

 echo -e " 架构: ${YELLOW}$(uname -m)${PLAIN} | 配置: ${YELLOW}$CONFIG_FILE${PLAIN}"
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

# --- 提取的公共辅助函数 ---

# 从配置文件提取 Tunnel UUID
get_tunnel_uuid() {
 local cfg="${1:-$CONFIG_FILE}"
 if [ -f "$cfg" ]; then
 grep "^tunnel:" "$cfg" | awk '{print $2}'
 fi
}

# 显示隧道连接信息 (提取的公共函数，消除重复代码)
show_tunnel_info() {
 local cfg="${1:-$CONFIG_FILE}"
 local uuid=$(get_tunnel_uuid "$cfg")
 if [ -n "$uuid" ]; then
 echo -e "${BLUE}--- 隧道连接信息 ---${PLAIN}"
 cloudflared tunnel info "$uuid" 2>/dev/null || msg_warn "无法获取隧道信息"
 echo ""
 fi
}

# 检查 systemd 是否可用
has_systemd() {
 command -v systemctl &> /dev/null && [ -d /run/systemd/system ]
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
 local deps=("wget" "curl" "grep" "sed" "awk" "tar")
 for dep in "${deps[@]}"; do
 if ! command -v "$dep" &> /dev/null; then
 msg_error "缺少必要命令: $dep"
 echo "请先安装它 (例如: apt install $dep 或 yum install $dep)"
 exit 1
 fi
 done
 # systemctl 软依赖: 没有则警告但继续
 if ! has_systemd; then
 msg_warn "未检测到 systemd，服务管理功能将受限 (启停/自启不可用)。"
 msg_warn "可直接使用 cloudflared 命令或 Docker 模式运行。"
 echo ""
 fi
}

# --- 核心功能函数 ---

# 验证 config.yml 语法，失败则回滚备份
validate_config() {
 local cfg="${1:-$CONFIG_FILE}"
 if [ ! -f "$cfg" ]; then
 msg_error "配置文件不存在: $cfg"
 return 1
 fi
 if cloudflared tunnel ingress validate --config "$cfg" 2>/dev/null; then
 return 0
 else
 msg_error "配置验证失败！正在回滚备份..."
 if [ -f "${cfg}.bak" ]; then
 mv "${cfg}.bak" "$cfg"
 msg_info "已恢复到修改前的配置。"
 else
 msg_warn "未找到备份文件，请手动检查 $cfg"
 fi
 return 1
 fi
}

# 检查 cloudflared 是否已安装
check_cf() {
 if ! command -v cloudflared &> /dev/null; then
 msg_error "cloudflared 尚未安装！请先执行菜单 1 安装。"
 pause
 return 1
 fi
 return 0
}

# 重启并验证
restart_cf() {
 if ! has_systemd; then
 msg_warn "无 systemd，尝试直接重启进程..."
 pkill cloudflared 2>/dev/null
 sleep 1
 if [ -f "$CONFIG_FILE" ]; then
 nohup cloudflared tunnel --config "$CONFIG_FILE" run &>/dev/null &
 else
 nohup cloudflared tunnel run &>/dev/null &
 fi
 sleep 2
 if pgrep cloudflared >/dev/null; then
 msg_success "进程已重启。"
 else
 msg_error "进程重启失败！"
 fi
 return
 fi
 systemctl restart "$SERVICE_NAME"
 sleep 2
 if systemctl is-active --quiet "$SERVICE_NAME"; then
 msg_success "服务已重启并运行正常。"
 else
 msg_error "服务重启后未正常运行！请检查日志 (菜单 8 → 1)。"
 systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null | head -10
 show_tunnel_info
 fi
}

install_cloudflared() {
 print_logo
 echo -e "${CYAN}=== Cloudflared 更新/安装/降级 ===${PLAIN}"
 echo -e "正在检测系统架构..."
 
 local ARCH=$(uname -m)
 local DOWNLOAD_ARCH=""
 
 case $ARCH in
 x86_64|amd64) DOWNLOAD_ARCH="amd64" ;;
 aarch64|arm64) DOWNLOAD_ARCH="arm64" ;;
 armv7l|armhf) DOWNLOAD_ARCH="arm" ;;
 i386|i686) DOWNLOAD_ARCH="386" ;;
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
 echo -e "当前已装版本: ${YELLOW}$LOCAL_VER${PLAIN}"
 echo -e "官方最新版本: ${GREEN}$REMOTE_VER${PLAIN}"
 echo -e "----------------------------------------"
 echo ""

 echo -e "1. 安装/更新到 ${GREEN}最新版本${PLAIN} ($REMOTE_VER)"
 echo -e "2. 安装/降级到 ${YELLOW}兼容稳定版 2026.5.0${PLAIN} ${RED}[推荐老旧ARM设备/内核报错 panic 者使用]${PLAIN}"
 echo -e "3. ${CYAN}手动指定任意版本号${PLAIN} (高级)"
 echo -e "0. 返回上一级"
 echo ""
 
 read -p "请选择 [1/2/3/0]: " choice

 local BASE_URL=""
 local TARGET_VER=""

 case $choice in
 1)
 TARGET_VER="最新版"
 BASE_URL="${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${DOWNLOAD_ARCH}"
 ;;
 2)
 TARGET_VER="2026.5.0"
 BASE_URL="${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/download/${TARGET_VER}/cloudflared-linux-${DOWNLOAD_ARCH}"
 ;;
 3)
 echo ""
 read -p "请输入要安装的完整版本号 (例如 2024.4.1): " TARGET_VER
 if [[ -z "$TARGET_VER" ]]; then
 msg_error "版本号不能为空。"
 pause
 return
 fi
 BASE_URL="${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/download/${TARGET_VER}/cloudflared-linux-${DOWNLOAD_ARCH}"
 ;;
 0)
 return
 ;;
 *)
 msg_error "操作已取消。"
 pause
 return
 ;;
 esac

 echo ""
 msg_info "准备下载版本: ${YELLOW}${TARGET_VER}${PLAIN}"
 
 # 下载前先停止服务，避免文件占用被拒绝覆盖
 if has_systemd && systemctl is-active --quiet "$SERVICE_NAME"; then
 msg_info "正在暂时停止 cloudflared 服务以进行替换..."
 systemctl stop "$SERVICE_NAME"
 fi

 # 下载: 先试代理, 失败试直连
 local TMP_BIN="/tmp/cloudflared_new"
 register_temp "$TMP_BIN"
 msg_info "正在下载 (代理加速)..."
 wget -q -O "$TMP_BIN" "$BASE_URL" 2>/dev/null
 if [ $? -ne 0 ] || [ ! -s "$TMP_BIN" ]; then
 msg_warn "代理下载失败, 尝试直连..."
 local DIRECT_URL=$(echo "$BASE_URL" | sed "s|${GH_PROXY}||")
 wget -q -O "$TMP_BIN" "$DIRECT_URL" 2>/dev/null
 fi

 if [ $? -ne 0 ] || [ ! -s "$TMP_BIN" ]; then
 msg_error "下载失败！请检查您输入的版本号是否正确，或检查网络连接。"
 rm -f "$TMP_BIN"
 has_systemd && systemctl start "$SERVICE_NAME" 2>/dev/null
 pause
 return
 fi

 # 验证下载的文件是否为有效二进制
 local FILE_TYPE=$(file "$TMP_BIN" 2>/dev/null)
 if ! echo "$FILE_TYPE" | grep -qiE "ELF|executable"; then
 msg_error "下载的文件不是有效的可执行文件！可能下载了 HTML 错误页。"
 echo -e "${YELLOW}文件类型: ${PLAIN}$FILE_TYPE"
 rm -f "$TMP_BIN"
 has_systemd && systemctl start "$SERVICE_NAME" 2>/dev/null
 pause; return
 fi

 # 基本大小检查 (有效二进制应 > 1MB)
 local FILE_SIZE=$(stat -c%s "$TMP_BIN" 2>/dev/null || stat -f%z "$TMP_BIN" 2>/dev/null)
 if [ -n "$FILE_SIZE" ] && [ "$FILE_SIZE" -lt 1048576 ]; then
 msg_warn "下载文件较小 (${FILE_SIZE} 字节)，可能不完整，但继续安装..."
 fi
 
 # 替换文件
 mv "$TMP_BIN" "$CF_BIN"
 chmod 0755 "$CF_BIN"
 mkdir -p "$CONFIG_DIR"
 
 # 验证安装后的二进制可执行
 if ! "$CF_BIN" --version >/dev/null 2>&1; then
 msg_error "安装后验证失败：cloudflared 无法执行！可能架构不匹配。"
 echo -e "${YELLOW}请确认您的架构 ($DOWNLOAD_ARCH) 是否正确。${PLAIN}"
 rm -f "$CF_BIN"
 has_systemd && systemctl start "$SERVICE_NAME" 2>/dev/null
 pause; return
 fi
 
 msg_success "安装/替换完成！"
 # 创建快捷命令
 ln -sf "$0" "/usr/bin/${CF_CMD}" 2>/dev/null
 msg_info "快捷命令: 任意目录输入 ${GREEN}${CF_CMD}${PLAIN} 即可打开本脚本"
 "$CF_BIN" --version
 # 尝试重启服务
 if has_systemd && systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
 msg_info "正在重新启动系统服务..."
 systemctl start "$SERVICE_NAME"
 fi
 
 pause
}

login_cloudflare() {
 print_logo
 check_cf || return
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
 check_cf || return
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

 TUNNEL_UUID=$(echo "$CREATE_OUTPUT" | grep -oE '[a-f0-9-]{36}' | head -1)
 
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
 # 清理 crontab 定时任务
 if crontab -l 2>/dev/null | grep -q "cloudflared"; then
 crontab -l 2>/dev/null | grep -v "cloudflared" | crontab -
 msg_info "已清理 crontab 中的 cloudflared 定时任务"
 fi
 
 # 删除快捷命令
 rm -f "/usr/bin/${CF_CMD}"
 systemctl daemon-reload
 systemctl enable "$SERVICE_NAME"
 systemctl restart "$SERVICE_NAME"

 if systemctl is-active --quiet "$SERVICE_NAME"; then
 msg_success "服务启动成功！"
 echo -e "访问地址: ${GREEN}https://$HOSTNAME${PLAIN}"
 else
 msg_error "服务启动失败，请检查日志。"
 systemctl status "$SERVICE_NAME" --no-pager
 show_tunnel_info
 fi
 pause
}

# --- 配置文件解析与操作 ---

manage_domains() {
 while true; do
 print_logo
 check_cf || return
 echo -e "${CYAN}=== 域名与路由管理 ===${PLAIN}"
 list_local_domains
 echo ""
 echo "1. 添加新域名"
 echo "2. 批量添加域名"
 echo "3. 删除域名"
 echo "0. 返回主菜单"
 echo ""
 read -p "请选择: " dom_choice

 case $dom_choice in
 1) add_domain_logic ;;
 2) add_domain_batch ;;
 3) delete_domain_logic ;;
 0) return ;;
 *) msg_error "无效输入"; sleep 1 ;;
 esac
 done
}

list_local_domains() {
 local cfg="${1:-$CONFIG_FILE}"
 echo -e "${CYAN}--- 当前配置的域名列表 ($cfg) ---${PLAIN}"
 printf "%-35s | %-30s\n" "域名 (Hostname)" "指向本地服务 (Service)"
 echo "-------------------------------------------------------------------"
 
 if [ ! -f "$cfg" ]; then
 echo " (配置文件不存在)"
 echo "-------------------------------------------------------------------"
 return
 fi
 
 # 纯 awk 解析 YAML ingress 段 — 健壮版
 awk '
 BEGIN { in_ingress=0; host=""; svc="" }
 /^ingress:/ { in_ingress=1; next }
 in_ingress && /^[[:space:]]*-/ {
  # 新条目开始，先输出上一个
  if (host != "" && svc != "" && svc !~ /http_status:404/) {
   printf "%s|%s\n", host, svc
  }
  host=""; svc=""
 }
 in_ingress && /hostname:/ {
  val=$0; sub(/.*hostname:[[:space:]]*/, "", val); gsub(/\r/, "", val); gsub(/["'"'"']/, "", val)
  host=val
 }
 in_ingress && /service:/ {
  val=$0; sub(/.*service:[[:space:]]*/, "", val); gsub(/\r/, "", val)
  svc=val
 }
 END {
  if (host != "" && svc != "" && svc !~ /http_status:404/) {
   printf "%s|%s\n", host, svc
  }
 }
 ' "$cfg" | while IFS="|" read -r h s; do
 if [ -n "$h" ] && [ -n "$s" ]; then
 printf "${GREEN}%-35s${PLAIN} | ${YELLOW}%-30s${PLAIN}\n" "$h" "$s"
 fi
 done
 
 echo "-------------------------------------------------------------------"
}

add_domain_logic() {
 if [ ! -f "$CONFIG_FILE" ]; then
 msg_error "找不到配置文件，请先创建隧道。"
 pause; return
 fi

 local TUNNEL_UUID=$(get_tunnel_uuid)
 if [ -z "$TUNNEL_UUID" ]; then
 msg_error "配置文件中无法读取 Tunnel UUID。"
 pause; return
 fi

 echo ""
 read -p "请输入新域名 (例如: plex.example.com): " NEW_HOST
 if grep -q "hostname: $NEW_HOST" "$CONFIG_FILE"; then
 msg_error "域名 $NEW_HOST 已存在，请勿重复添加。"
 pause; return
 fi
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

 local INSERT_STR=" - hostname: $NEW_HOST\n service: $NEW_SVC"
 
 if grep -q "http_status:404" "$CONFIG_FILE"; then
 sed -i "/- service: http_status:404/i $INSERT_STR" "$CONFIG_FILE"
 else
 echo -e "$INSERT_STR" >> "$CONFIG_FILE"
 echo " - service: http_status:404" >> "$CONFIG_FILE"
 fi

 if [ $? -eq 0 ]; then
 msg_success "配置已更新。"
 msg_info "正在验证配置语法..."
 if validate_config; then
 msg_info "正在添加 Cloudflare DNS 记录..."
 cloudflared tunnel route dns "$TUNNEL_UUID" "$NEW_HOST"
 msg_info "重启服务以应用更改..."
 restart_cf
 fi
 else
 msg_error "修改配置文件失败，已恢复备份。"
 mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
 fi
 sleep 2
}

add_domain_batch() {
 if [ ! -f "$CONFIG_FILE" ]; then
 msg_error "找不到配置文件，请先创建隧道。"
 pause; return
 fi

 local TUNNEL_UUID=$(get_tunnel_uuid)
 if [ -z "$TUNNEL_UUID" ]; then
 msg_error "配置文件中无法读取 Tunnel UUID。"
 pause; return
 fi

 echo ""
 echo -e "${CYAN}批量添加域名${PLAIN}"
 echo "每行一个，格式: 域名 端口或地址"
 echo "例如:"
 echo "  plex.example.com 32400"
 echo "  nas.example.com 5000"
 echo "  git.example.com http://192.168.1.5:3000"
 echo "输入空行结束:"
 echo ""

 local lines=()
 while IFS= read -r line; do
 [ -z "$line" ] && break
 lines+=("$line")
 done

 if [ ${#lines[@]} -eq 0 ]; then
 msg_info "未输入任何域名。"
 pause; return
 fi

 cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
 local success=0 fail=0

 for line in "${lines[@]}"; do
 local host=$(echo "$line" | awk '{print $1}')
 local svc_in=$(echo "$line" | awk '{print $2}')

 if [ -z "$host" ] || [ -z "$svc_in" ]; then
 msg_error "跳过无效行: $line"
 fail=$((fail+1))
 continue
 fi

 if grep -q "hostname: $host" "$CONFIG_FILE"; then
 msg_error "跳过已存在: $host"
 fail=$((fail+1))
 continue
 fi

 local new_svc="$svc_in"
 if [[ "$svc_in" =~ ^[0-9]+$ ]]; then
 new_svc="http://127.0.0.1:$svc_in"
 fi

 cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
 local insert_str=" - hostname: $host\n service: $new_svc"
 if grep -q "http_status:404" "$CONFIG_FILE"; then
 sed -i "/- service: http_status:404/i $insert_str" "$CONFIG_FILE"
 else
 echo -e "$insert_str" >> "$CONFIG_FILE"
 echo " - service: http_status:404" >> "$CONFIG_FILE"
 fi

 cloudflared tunnel route dns "$TUNNEL_UUID" "$host" 2>/dev/null
 msg_success "已添加: $host -> $new_svc"
 success=$((success+1))
 done

 echo ""
 echo -e "成功: ${GREEN}$success${PLAIN}  失败: ${RED}$fail${PLAIN}"

 msg_info "正在验证配置语法..."
 if validate_config; then
 msg_info "重启服务..."
 restart_cf
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
 
 # 加固版: 用 grep -n 定位 hostname 行号，删除该行和下一行 (service 行)
 local HOST_LINE=$(grep -n "hostname: $DEL_HOST" "$CONFIG_FILE" | head -1 | cut -d: -f1)
 if [ -n "$HOST_LINE" ]; then
 sed -i "${HOST_LINE},$((HOST_LINE+1))d" "$CONFIG_FILE"
 # 如果上面只删了一行 (service 行可能不在紧接的下一行)，再检查
 if grep -q "hostname: $DEL_HOST" "$CONFIG_FILE"; then
 # fallback: 用 awk 删除
 awk -v host="$DEL_HOST" '
 $0 ~ "hostname: " host { skip=1; next }
 skip && /^[[:space:]]*service:/ { skip=0; next }
 skip { next }
 { print }
 ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
 fi
 fi

 # 显示配置变更 diff
 show_config_diff "${CONFIG_FILE}.bak" "$CONFIG_FILE" || return
 msg_success "已从本地配置移除。"
 msg_info "正在验证配置语法..."
 if validate_config; then
 msg_warn "注意：DNS 记录并未删除 (通常无需删除，它只会变无效)。"
 msg_info "重启服务..."
 restart_cf
 fi
 sleep 2
}

service_status() {
 print_logo
 check_cf || return
 echo -e "${CYAN}=== 系统服务状态 ===${PLAIN}"
 # 资源监控已在 Logo 下方显示
 
 if has_systemd; then
 systemctl status "$SERVICE_NAME" --no-pager
 else
 if pgrep cloudflared >/dev/null; then
 echo -e "${GREEN}● cloudflared 进程运行中${PLAIN} (PID: $(pgrep cloudflared | head -1))"
 else
 echo -e "${RED}● cloudflared 未运行${PLAIN}"
 fi
 fi
 
 show_tunnel_info
 echo ""
 echo -e "${BLUE}操作选项:${PLAIN}"
 echo "1. 启动服务"
 echo "2. 停止服务"
 echo "3. 重启服务"
 echo "4. 设置开机自启"
 echo "0. 返回主菜单"
 
 read -p "请选择: " svc_opt
 case $svc_opt in
 1)
 if has_systemd; then
 systemctl start "$SERVICE_NAME" && msg_success "已启动"
 else
 nohup cloudflared tunnel --config "$CONFIG_FILE" run &>/dev/null &
 msg_success "已启动进程"
 fi
 ;;
 2)
 if has_systemd; then
 systemctl stop "$SERVICE_NAME" && msg_warn "已停止"
 else
 pkill cloudflared && msg_warn "已停止进程"
 fi
 ;;
 3) restart_cf ;;
 4)
 if has_systemd; then
 systemctl enable "$SERVICE_NAME" && msg_success "已设置开机自启"
 else
 msg_warn "无 systemd，无法设置开机自启"
 fi
 ;;
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
 echo "3. 从备份恢复配置 (Restore Config)"
 echo "4. 切换传输协议 (QUIC/HTTP2)"
 echo "5. 管理备份文件 (删除/清理)"
 echo "6. 网络延迟检测 (Ping/Traceroute)"
 echo "7. 直接编辑配置文件"
 echo "8. 配置导入/导出"
 echo "9. 隧道流量统计"
 echo "10. 设置 systemd 自动重启 (看门狗)"
 echo "11. 常用服务模板库"
 echo "12. 隧道迁移助手"
 echo "13. 日志轮转配置"
 echo "14. IPv6 环境检测与适配"
 echo "0. 返回主菜单"
 echo ""
 read -p "请选择 [1-14, 0]: " t_choice
 
 case $t_choice in
 1) view_logs ;;
 2) backup_config ;;
 3) restore_config ;;
 4) switch_protocol ;;
 5) manage_backups ;;
 6) network_test ;;
 7) edit_config ;;
 8) config_import_export ;;
 9) tunnel_stats ;;
 10) systemd_watchdog ;;
 11) service_template_menu ;;
 12) tunnel_migrate ;;
 13) setup_logrotate ;;
 14) ipv6_check ;;
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
 if has_systemd; then
 journalctl -u "$SERVICE_NAME" -f
 else
 echo "无 systemd，尝试查看进程日志..."
 # 尝试找日志文件
 local LOG_FILE="/var/log/cloudflared.log"
 if [ -f "$LOG_FILE" ]; then
 tail -f "$LOG_FILE"
 else
 msg_warn "未找到日志文件。可通过 cloudflared tunnel --config $CONFIG_FILE run 2>&1 | tee $LOG_FILE 启动并记录日志。"
 fi
 fi
}

backup_config() {
 print_logo
 local BACKUP_FILE="/root/cloudflared_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
 msg_info "正在打包配置文件..."
 
 if [ ! -d "$CONFIG_DIR" ] && [ ! -d "$CRED_DIR" ]; then
 msg_error "未找到配置目录，无法备份。"
 pause; return
 fi
 
 # 使用相对路径打包，方便恢复到不同位置
 tar -czf "$BACKUP_FILE" -C / etc/cloudflared root/.cloudflared 2>/dev/null
 
 if [ -f "$BACKUP_FILE" ]; then
 msg_success "备份成功！"
 echo -e "备份文件路径: ${GREEN}$BACKUP_FILE${PLAIN}"
 echo -e "备份内容: ${YELLOW}etc/cloudflared/ + root/.cloudflared/ (相对路径)${PLAIN}"
 else
 msg_error "备份失败。"
 fi
 
 # 自动清理: 超过 10 份删最旧的
 local BK_COUNT=$(ls -1 /root/cloudflared_backup_*.tar.gz 2>/dev/null | wc -l)
 if [ "$BK_COUNT" -gt 10 ]; then
 ls -rt /root/cloudflared_backup_*.tar.gz | head -n -$((10)) | xargs rm -f
 msg_info "已自动清理 $((BK_COUNT - 10)) 个旧备份 (保留最近 10 份)"
 fi
 pause
}

# [新功能] 从备份恢复配置
restore_config() {
 print_logo
 echo -e "${CYAN}=== 从备份恢复配置 ===${PLAIN}"
 
 local backups=($(ls /root/cloudflared_backup_*.tar.gz 2>/dev/null | sort))
 
 if [ ${#backups[@]} -eq 0 ]; then
 echo ""
 msg_error "没有找到备份文件 (cloudflared_backup_*.tar.gz)。"
 pause; return
 fi

 echo -e "当前共有 ${#backups[@]} 个备份文件："
 echo "----------------------------------------"
 local i=1
 for bk in "${backups[@]}"; do
 local bk_size=$(du -h "$bk" | awk '{print $1}')
 local bk_date=$(basename "$bk" | grep -oE '[0-9]{8}_[0-9]{6}' | sed 's/_/ /')
 echo -e " $i. $(basename "$bk")  ${YELLOW}(${bk_size})${PLAIN}"
 let i++
 done
 echo "----------------------------------------"
 echo -e "输入 ${GREEN}数字序号${PLAIN} 恢复指定备份"
 echo -e "输入 ${BLUE}0${PLAIN} 返回上一级"
 echo ""
 
 read -p "请选择: " op
 
 case $op in
 0) return ;;
 *)
 if [[ "$op" =~ ^[0-9]+$ ]] && [ "$op" -ge 1 ] && [ "$op" -le ${#backups[@]} ]; then
 local file_idx=$((op-1))
 local file_path="${backups[$file_idx]}"
 
 echo ""
 msg_warn "恢复将覆盖当前配置和凭证文件！"
 read -p "确认恢复? (y/N): " confirm
 if [[ ! "$confirm" =~ ^[yY]$ ]]; then
 msg_info "操作已取消。"
 pause; return
 fi
 
 # 先备份当前配置
 if [ -d "$CONFIG_DIR" ] || [ -d "$CRED_DIR" ]; then
 local SAFETY_BACKUP="/root/cloudflared_pre_restore_$(date +%Y%m%d_%H%M%S).tar.gz"
 tar -czf "$SAFETY_BACKUP" -C / etc/cloudflared root/.cloudflared 2>/dev/null
 msg_info "当前配置已安全备份到: $SAFETY_BACKUP"
 fi
 
 # 停止服务
 if has_systemd; then
 systemctl stop "$SERVICE_NAME" 2>/dev/null
 fi
 
 # 解压恢复 (相对路径，解压到 /)
 msg_info "正在解压恢复..."
 tar -xzf "$file_path" -C /
 
 if [ -f "$CONFIG_FILE" ]; then
 msg_success "恢复完成！"
 msg_info "正在验证配置..."
 if validate_config; then
 msg_info "正在重启服务..."
 if has_systemd; then
 systemctl start "$SERVICE_NAME"
 else
 nohup cloudflared tunnel --config "$CONFIG_FILE" run &>/dev/null &
 fi
 sleep 2
 msg_success "服务已恢复运行。"
 fi
 else
 msg_error "恢复后未找到配置文件，请检查备份完整性。"
 fi
 else
 msg_error "无效选项"
 fi
 ;;
 esac
 pause
}

manage_backups() {
 while true; do
 print_logo
 echo -e "${CYAN}=== 备份文件管理 ===${PLAIN}"
 echo -e "${YELLOW}说明：管理位于 /root/ 下的 .tar.gz 压缩备份包${PLAIN}"
 
 local backups=($(ls /root/cloudflared_backup_*.tar.gz 2>/dev/null | sort))
 
 if [ ${#backups[@]} -eq 0 ]; then
 echo ""
 echo "没有找到备份文件 (cloudflared_backup_*.tar.gz)。"
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
 ls -rt /root/cloudflared_backup_*.tar.gz | head -n -5 | xargs rm -f
 msg_success "已清理旧备份，仅保留最新 5 份。"
 fi
 sleep 2
 ;;
 a)
 read -p "确认删除所有备份? (y/N): " confirm
 if [[ "$confirm" =~ ^[yY]$ ]]; then
 rm -f /root/cloudflared_backup_*.tar.gz
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
 check_cf || return
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
 sed -i "/^credentials-file:/a protocol: http2" "$CONFIG_FILE"
 msg_success "已设置为 http2。"
 restart_cf
 fi
 ;;
 2)
 if grep -q "protocol: http2" "$CONFIG_FILE"; then
 sed -i "/protocol: http2/d" "$CONFIG_FILE"
 msg_success "已恢复为 QUIC。"
 restart_cf
 else
 msg_info "已经是 QUIC 协议了。"
 fi
 ;;
 0) return ;;
 esac
 pause
}

# [增强] 网络延迟检测 — 增加 traceroute/mtr + 丢包率
network_test() {
 print_logo
 echo -e "${CYAN}=== 网络延迟检测 ===${PLAIN}"
 
 # Ping Cloudflare
 echo "正在 Ping Cloudflare 边缘节点 (1.1.1.1)..."
 echo ""
 local ping_result=$(ping -c 4 1.1.1.1 2>&1)
 echo "$ping_result"
 
 # 提取丢包率
 local loss=$(echo "$ping_result" | grep -oE '[0-9.]+% packet loss' | head -1)
 if [ -n "$loss" ]; then
 local loss_num=$(echo "$loss" | grep -oE '[0-9.]+')
	if [ -n "$loss_num" ] && awk -v n="$loss_num" 'BEGIN{exit !(n>0)}'; then
 echo -e "${YELLOW}⚠ 检测到丢包: $loss${PLAIN}"
 fi
 fi
 
 echo ""
 
 # Traceroute / mtr
 echo -e "${CYAN}--- 路由追踪到 Cloudflare ---${PLAIN}"
 if command -v mtr &> /dev/null; then
 msg_info "使用 mtr 进行路由追踪 (10 跳)..."
 mtr -n -c 3 -r 1.1.1.1 2>/dev/null || msg_warn "mtr 执行失败"
 elif command -v traceroute &> /dev/null; then
 msg_info "使用 traceroute 进行路由追踪..."
 traceroute -n -m 15 1.1.1.1 2>/dev/null || msg_warn "traceroute 执行失败"
 elif command -v tracepath &> /dev/null; then
 msg_info "使用 tracepath 进行路由追踪..."
 tracepath -n 1.1.1.1 2>/dev/null || msg_warn "tracepath 执行失败"
 else
 msg_warn "未找到 traceroute/mtr/tracepath，跳过路由追踪。"
 fi
 
 # 隧道端到端测试
 if [ -f "$CONFIG_FILE" ]; then
 echo ""
 echo -e "${CYAN}--- 隧道端到端测试 ---${PLAIN}"
 local first_host=$(awk '/hostname:/ {print $NF; exit}' "$CONFIG_FILE")
 if [ -n "$first_host" ]; then
 echo "正在测试隧道域名: https://$first_host"
	local result=$(curl -L -o /dev/null -s -w "%{http_code} %{time_total}" --connect-timeout 10 --max-time 15 "https://$first_host" 2>/dev/null)
	local http_code=$(echo "$result" | awk '{print $1}')
	local time_total=$(echo "$result" | awk '{print $2}')
 if [ -n "$http_code" ] && [ "$http_code" != "000" ]; then
 echo -e "结果: ${GREEN}HTTP $http_code — 隧道连通${PLAIN} | 耗时: ${YELLOW}${time_total}s${PLAIN}"
 else
 echo -e "结果: ${RED}不可达 — 隧道可能未连接${PLAIN}"
 fi
 else
 echo -e "${YELLOW}配置文件中未找到域名${PLAIN}"
 fi
 fi
 pause
}

# [新功能] 直接编辑配置文件
edit_config() {
 print_logo
 check_cf || return
 echo -e "${CYAN}=== 直接编辑配置文件 ===${PLAIN}"
 
 if [ ! -f "$CONFIG_FILE" ]; then
 msg_error "配置文件不存在: $CONFIG_FILE"
 pause; return
 fi
 
 # 查找可用的编辑器
 local editor=""
 for candidate in "${EDITOR:-}" vim nano vi emacs micro; do
 if command -v "$candidate" &> /dev/null; then
 editor="$candidate"
 break
 fi
 done
 
 if [ -z "$editor" ]; then
 msg_error "未找到可用的文本编辑器 (vim/nano/vi)。"
 pause; return
 fi
 
 echo -e "将使用 ${GREEN}$editor${PLAIN} 编辑配置文件。"
 echo -e "${YELLOW}提示：保存退出后将自动验证配置语法并重启服务。${PLAIN}"
 echo ""
 
 # 备份
 cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
 
 # 调用编辑器
 "$editor" "$CONFIG_FILE"
 
 # 检查是否有变化
 if cmp -s "$CONFIG_FILE" "${CONFIG_FILE}.bak"; then
 msg_info "配置文件未修改。"
 rm -f "${CONFIG_FILE}.bak"
 else
 msg_info "检测到配置已修改，正在验证语法..."
 if validate_config; then
 msg_success "配置验证通过！正在重启服务..."
 restart_cf
 else
 msg_error "配置验证失败，已自动回滚。"
 fi
 fi
 pause
}

# [新功能] 配置导入/导出
config_import_export() {
 while true; do
 print_logo
 echo -e "${CYAN}=== 配置导入/导出 ===${PLAIN}"
 echo "1. 导出当前配置 (含凭证路径)"
 echo "2. 导出配置模板 (不含敏感信息，可分享)"
 echo "3. 从本地文件导入配置"
 echo "4. 从 URL 下载导入配置"
 echo "0. 返回上一级"
 echo ""
 read -p "请选择: " ie_choice
 
 case $ie_choice in
 1) config_export_full ;;
 2) config_export_template ;;
 3) config_import_file ;;
 4) config_import_url ;;
 0) return ;;
 *) msg_error "无效选项"; sleep 1 ;;
 esac
 done
}

config_export_full() {
 if [ ! -f "$CONFIG_FILE" ]; then
 msg_error "配置文件不存在。"
 pause; return
 fi
 local export_path="/root/cloudflared_config_export_$(date +%Y%m%d_%H%M%S).yml"
 cp "$CONFIG_FILE" "$export_path"
 msg_success "已导出到: $export_path"
 echo -e "${YELLOW}注意：此文件包含凭证路径信息，请勿公开分享。${PLAIN}"
 pause
}

config_export_template() {
 if [ ! -f "$CONFIG_FILE" ]; then
 msg_error "配置文件不存在。"
 pause; return
 fi
 local export_path="/root/cloudflared_config_template_$(date +%Y%m%d_%H%M%S).yml"
 # 移除 credentials-file 行，替换 tunnel UUID 为占位符
 sed -e '/^credentials-file:/d' \
     -e 's/^tunnel: .*/tunnel: <YOUR_TUNNEL_UUID>/' \
     "$CONFIG_FILE" > "$export_path"
 msg_success "已导出模板到: $export_path"
 echo -e "${GREEN}此模板可安全分享，不含敏感信息。${PLAIN}"
 echo ""
 echo -e "${CYAN}--- 模板内容预览 ---${PLAIN}"
 cat "$export_path"
 echo "------------------------"
 pause
}

config_import_file() {
 echo ""
 read -p "请输入配置文件路径: " import_path
 if [ ! -f "$import_path" ]; then
 msg_error "文件不存在: $import_path"
 pause; return
 fi
 _do_import "$import_path"
}

config_import_url() {
 echo ""
 read -p "请输入配置文件 URL: " import_url
 if [ -z "$import_url" ]; then
 msg_error "URL 不能为空。"
 pause; return
 fi
 local tmp_import="/tmp/cf_import_$$"
 register_temp "$tmp_import"
 msg_info "正在下载配置文件..."
 wget -q -O "$tmp_import" "$import_url" 2>/dev/null
 if [ $? -ne 0 ] || [ ! -s "$tmp_import" ]; then
 msg_error "下载失败，请检查 URL。"
 pause; return
 fi
 _do_import "$tmp_import"
}

_do_import() {
 local import_path="$1"
 
 if [ -f "$CONFIG_FILE" ]; then
 cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
 msg_info "当前配置已备份。"
 fi
 
 msg_warn "导入将覆盖当前配置文件！"
 read -p "确认导入? (y/N): " confirm
 if [[ ! "$confirm" =~ ^[yY]$ ]]; then
 msg_info "操作已取消。"
 return
 fi
 
 cp "$import_path" "$CONFIG_FILE"
 msg_info "正在验证配置语法..."
 if validate_config; then
 msg_success "导入成功！正在重启服务..."
 restart_cf
 else
 msg_error "导入的配置验证失败，已回滚。"
 fi
 pause
}

# [新功能] 隧道流量统计
tunnel_stats() {
 print_logo
 check_cf || return
 echo -e "${CYAN}=== 隧道流量统计 ===${PLAIN}"
 echo ""
 
 local TUNNEL_UUID=$(get_tunnel_uuid)
 if [ -z "$TUNNEL_UUID" ]; then
 msg_error "无法读取 Tunnel UUID。"
 pause; return
 fi
 
 msg_info "正在获取隧道信息..."
 echo ""
 
 # 隧道基本信息
 echo -e "${CYAN}--- 隧道基本信息 ---${PLAIN}"
 cloudflared tunnel info "$TUNNEL_UUID" 2>/dev/null || msg_error "无法获取隧道信息"
 echo ""
 
 # 列出所有隧道及其状态
 echo -e "${CYAN}--- 所有隧道列表 ---${PLAIN}"
 cloudflared tunnel list 2>/dev/null || msg_error "无法列出隧道"
 echo ""
 
 # 进程资源占用
 if pgrep cloudflared >/dev/null; then
 echo -e "${CYAN}--- 进程资源占用 ---${PLAIN}"
 local pid=$(pgrep cloudflared | head -1)
 ps -p "$pid" -o pid,%cpu,%mem,vsz,rss,etime,cmd --no-headers 2>/dev/null
 echo ""
 
 # 网络连接数
 if command -v ss &> /dev/null; then
 local conn_count=$(ss -tnp 2>/dev/null | grep "cloudflared" | wc -l)
 echo -e "TCP 连接数: ${GREEN}$conn_count${PLAIN}"
 fi
 if command -v ss &> /dev/null; then
 local udp_count=$(ss -unp 2>/dev/null | grep "cloudflared" | wc -l)
 echo -e "UDP 连接数: ${GREEN}$udp_count${PLAIN}"
 fi
 else
 msg_warn "cloudflared 进程未运行。"
 fi
 echo ""
 
 # 配置的域名数
 if [ -f "$CONFIG_FILE" ]; then
 local domain_count=$(grep -c "hostname:" "$CONFIG_FILE" 2>/dev/null || echo 0)
 echo -e "已配置域名数: ${GREEN}$domain_count${PLAIN}"
 fi
 
 pause
}

# [新功能] systemd 原生看门狗 (Restart=always)
systemd_watchdog() {
 print_logo
 echo -e "${CYAN}=== systemd 自动重启 (看门狗) ===${PLAIN}"
 
 if ! has_systemd; then
 msg_error "当前系统无 systemd，无法使用此功能。"
 msg_info "请使用菜单 11 的 crontab 看门狗替代。"
 pause; return
 fi
 
 local OVERRIDE_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
 local OVERRIDE_FILE="$OVERRIDE_DIR/restart.conf"
 
 echo -e "通过 systemd override 设置 Restart=always，服务挂掉后 10 秒自动拉起。"
 echo -e "${YELLOW}比 crontab 的 5 分钟检测更及时、更可靠。${PLAIN}"
 echo ""
 
 # 检查当前状态
 local current_status="未开启"
 if [ -f "$OVERRIDE_FILE" ] && grep -q "Restart=always" "$OVERRIDE_FILE"; then
 current_status="已开启"
 fi
 echo -e "当前状态: ${YELLOW}$current_status${PLAIN}"
 echo ""
 echo "1. 开启 systemd 自动重启"
 echo "2. 关闭 systemd 自动重启"
 echo "3. 查看当前 service 配置"
 echo "0. 返回上一级"
 
 read -p "请选择: " wd_choice
 
 case $wd_choice in
 1)
 mkdir -p "$OVERRIDE_DIR"
 cat > "$OVERRIDE_FILE" << 'EOF'
[Service]
Restart=always
RestartSec=10
StartLimitIntervalSec=0
EOF
 systemctl daemon-reload
 systemctl restart "$SERVICE_NAME" 2>/dev/null
 msg_success "已开启 systemd 自动重启！"
 echo -e "服务异常退出后将在 ${GREEN}10 秒${PLAIN}内自动重新拉起。"
 ;;
 2)
 if [ -f "$OVERRIDE_FILE" ]; then
 rm -f "$OVERRIDE_FILE"
 systemctl daemon-reload
 msg_success "已关闭 systemd 自动重启。"
 else
 msg_info "本未开启，无需关闭。"
 fi
 ;;
 3)
 echo ""
 echo -e "${CYAN}--- service 主配置 ---${PLAIN}"
 if [ -f "$SERVICE_FILE" ]; then
 cat "$SERVICE_FILE"
 elif [ -f "$SERVICE_FILE_LIB" ]; then
 cat "$SERVICE_FILE_LIB"
 else
 msg_warn "未找到 service 文件。"
 fi
 if [ -f "$OVERRIDE_FILE" ]; then
 echo ""
 echo -e "${CYAN}--- override 配置 ---${PLAIN}"
 cat "$OVERRIDE_FILE"
 fi
 ;;
 0) return ;;
 esac
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
 has_systemd && systemctl stop "$SERVICE_NAME" 2>/dev/null
 
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
 while true; do
 print_logo
 echo -e "${CYAN}=== 定时任务管理 (Crontab) ===${PLAIN}"
 
 if ! command -v crontab &> /dev/null; then
 msg_error "系统中未找到 crontab 命令，无法管理定时任务。"
 pause; return
 fi
 
 local CRON_CMD="systemctl restart cloudflared"
 local WATCH_CMD="systemctl is-active --quiet cloudflared || systemctl start cloudflared"
 local EXISTS=$(crontab -l 2>/dev/null | grep "$CRON_CMD")
 local WATCH_EXISTS=$(crontab -l 2>/dev/null | grep -F "is-active --quiet cloudflared")
 local CRON_HOUR="4"
 if [ -n "$EXISTS" ]; then
 CRON_HOUR=$(echo "$EXISTS" | awk '{print $2}')
 fi
 
 # 定时重启状态
 if [ -n "$EXISTS" ]; then
 echo -e "定时重启: ${GREEN}● 已开启${PLAIN} (每天 ${CRON_HOUR}:00)"
 else
 echo -e "定时重启: ${YELLOW}○ 未开启${PLAIN}"
 fi
 
 # 自动恢复状态
 if [ -n "$WATCH_EXISTS" ]; then
 echo -e "故障恢复: ${GREEN}● 已开启${PLAIN} (每 5 分钟检测)"
 else
 echo -e "故障恢复: ${YELLOW}○ 未开启${PLAIN}"
 fi
 
 echo ""
 echo -e "${GREEN}1.${PLAIN} 定时重启 (开启/关闭/改时间)"
 echo -e "${GREEN}2.${PLAIN} 自动故障恢复 (挂了自动拉起)"
 echo -e "${YELLOW}3.${PLAIN} 使用 systemd 原生看门狗 (推荐，更可靠)"
 echo "0. 返回主菜单"
 echo ""
 read -p "请选择: " c_choice
 
 case $c_choice in
 1) manage_cron_restart "$CRON_CMD" "$EXISTS" "$CRON_HOUR" ;;
 2) manage_cron_watchdog "$WATCH_CMD" "$WATCH_EXISTS" ;;
 3) systemd_watchdog ;;
 0) return ;;
 *) msg_error "无效选项"; sleep 1 ;;
 esac
 done
}

manage_cron_restart() {
 local CRON_CMD="$1" EXISTS="$2" CRON_HOUR="$3"
 
 if [ -n "$EXISTS" ]; then
 echo ""
 echo -e "当前: ${GREEN}已开启${PLAIN} (每天凌晨 ${CRON_HOUR}:00 重启)"
 echo "1. 关闭定时重启"
 echo "2. 修改重启时间"
 echo "0. 返回"
 read -p "请选择: " sub
 case $sub in
 1)
 crontab -l 2>/dev/null | grep -v "$CRON_CMD" | crontab -
 msg_success "已关闭定时重启。"
 ;;
 2)
 read -p "请输入新的重启时间 (小时 0-23): " input_hour
 if ! [[ "$input_hour" =~ ^[0-9]+$ ]] || [ "$input_hour" -lt 0 ] || [ "$input_hour" -gt 23 ]; then
 msg_error "无效时间"
 else
 crontab -l 2>/dev/null | grep -v "$CRON_CMD" | crontab -
 (crontab -l 2>/dev/null; echo "0 $input_hour * * * $CRON_CMD") | crontab -
 msg_success "已修改为每天凌晨 ${input_hour}:00 重启"
 fi
 ;;
 esac
 else
 read -p "请输入重启时间 (小时 0-23, 默认4): " input_hour
 CRON_HOUR="${input_hour:-4}"
 if ! [[ "$CRON_HOUR" =~ ^[0-9]+$ ]] || [ "$CRON_HOUR" -lt 0 ] || [ "$CRON_HOUR" -gt 23 ]; then
 msg_error "无效时间，使用默认 4 点"
 CRON_HOUR="4"
 fi
 (crontab -l 2>/dev/null; echo "0 $CRON_HOUR * * * $CRON_CMD") | crontab -
 msg_success "已开启定时重启 (每天凌晨 ${CRON_HOUR}:00)"
 fi
 sleep 2
}

manage_cron_watchdog() {
 local WATCH_CMD="$1" WATCH_EXISTS="$2"
 
 if [ -n "$WATCH_EXISTS" ]; then
 echo ""
 echo -e "当前: ${GREEN}已开启${PLAIN} (每 5 分钟检测，挂了自动拉起)"
 read -p "是否关闭自动故障恢复? (y/N): " confirm
 if [[ "$confirm" =~ ^[yY]$ ]]; then
 crontab -l 2>/dev/null | grep -v -F "is-active --quiet cloudflared" | crontab -
 msg_success "已关闭自动故障恢复。"
 fi
 else
 echo ""
 echo "开启后，每 5 分钟检测 cloudflared 服务状态，如果挂了自动拉起。"
 echo -e "${YELLOW}提示：更推荐使用 systemd 原生看门狗 (菜单 11 → 3)，响应更快。${PLAIN}"
 read -p "是否开启? (y/N): " confirm
 if [[ "$confirm" =~ ^[yY]$ ]]; then
 (crontab -l 2>/dev/null; echo "*/5 * * * * $WATCH_CMD") | crontab -
 msg_success "已开启自动故障恢复。"
 fi
 fi
 sleep 2
}

# [新功能] 多隧道管理
multi_tunnel_menu() {
 while true; do
 print_logo
 check_cf || return
 echo -e "${CYAN}=== 多隧道管理 ===${PLAIN}"
 echo ""
 
 # 列出本地所有隧道配置
 echo -e "${CYAN}--- 本地隧道配置 ---${PLAIN}"
 local idx=1
 local tunnel_configs=()
 
 # 主配置
 if [ -f "$CONFIG_FILE" ]; then
 local uuid=$(get_tunnel_uuid "$CONFIG_FILE")
 local active=""
 if has_systemd && systemctl is-active --quiet "$SERVICE_NAME"; then
 active="${GREEN}●运行中${PLAIN}"
 else
 active="${RED}○已停止${PLAIN}"
 fi
 echo -e " ${idx}. ${YELLOW}[主隧道]${PLAIN} UUID: ${CYAN}${uuid:-未知}${PLAIN} 状态: $active"
 tunnel_configs+=("$CONFIG_FILE|main")
 let idx++
 fi
 
 # 额外隧道配置
	shopt -s nullglob
 for extra_cfg in "$CONFIG_DIR"/tunnel-*.yml; do
 if [ -f "$extra_cfg" ]; then
 local tname=$(basename "$extra_cfg" | sed 's/tunnel-//;s/.yml//')
 local uuid=$(get_tunnel_uuid "$extra_cfg")
 local svc="${SERVICE_NAME}-${tname}"
 local active=""
 if has_systemd && systemctl is-active --quiet "$svc" 2>/dev/null; then
 active="${GREEN}●运行中${PLAIN}"
 else
 active="${RED}○已停止${PLAIN}"
 fi
 echo -e " ${idx}. ${YELLOW}[${tname}]${PLAIN} UUID: ${CYAN}${uuid:-未知}${PLAIN} 状态: $active"
 tunnel_configs+=("$extra_cfg|$tname")
 let idx++
 fi
 done
 
 if [ ${#tunnel_configs[@]} -eq 0 ]; then
 echo " (暂无隧道配置)"
 fi
 
 echo ""
 echo "1. 创建额外隧道"
 echo "2. 启动/停止指定隧道"
 echo "3. 删除额外隧道"
 echo "4. 查看云端所有隧道"
 echo "0. 返回主菜单"
 echo ""
 read -p "请选择: " mt_choice
 
 case $mt_choice in
 1) multi_tunnel_create ;;
 2) multi_tunnel_toggle "${tunnel_configs[@]}" ;;
 3) multi_tunnel_delete "${tunnel_configs[@]}" ;;
 4)
 print_logo
 cloudflared tunnel list
 pause
 ;;
 0) return ;;
 *) msg_error "无效选项"; sleep 1 ;;
 esac
 done
	shopt -u nullglob
}

multi_tunnel_create() {
 echo ""
 read -p "请输入新隧道名称 (英文，如 nas2): " t_name
 if [[ -z "$t_name" ]]; then
 msg_error "名称不能为空。"; return
 fi
 if ! [[ "$t_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
 msg_error "名称只能包含字母、数字、下划线和连字符。"; return
 fi
 
 local extra_cfg="$CONFIG_DIR/tunnel-${t_name}.yml"
 if [ -f "$extra_cfg" ]; then
 msg_error "隧道 ${t_name} 的配置已存在。"
 return
 fi
 
 msg_info "正在向 Cloudflare 请求创建隧道..."
 local create_out=$(cloudflared tunnel create "$t_name" 2>&1)
 if echo "$create_out" | grep -q "Error"; then
 msg_error "创建失败: $create_out"
 return
 fi
 
 local t_uuid=$(echo "$create_out" | grep -oE '[a-f0-9-]{36}' | head -1)
 if [ -z "$t_uuid" ]; then
 msg_warn "自动提取 UUID 失败，请手动输入。"
 echo "$create_out"
 read -p "UUID: " t_uuid
 fi
 
 local cred_file="$CRED_DIR/${t_uuid}.json"
 msg_success "隧道创建成功！UUID: $t_uuid"
 
 echo ""
 read -p "请输入访问域名 (如 ${t_name}.example.com): " hostname
 read -p "请输入本地服务 (端口或地址): " svc_input
 local svc_url="$svc_input"
 if [[ "$svc_input" =~ ^[0-9]+$ ]]; then
 svc_url="http://127.0.0.1:$svc_input"
 fi
 
 cat > "$extra_cfg" << EOL
tunnel: $t_uuid
credentials-file: $cred_file
ingress:
 - hostname: $hostname
 service: $svc_url
 - service: http_status:404
EOL
 
 msg_success "配置文件已生成: $extra_cfg"
 msg_info "正在注册 DNS..."
 cloudflared tunnel route dns "$t_name" "$hostname" 2>/dev/null
 
 # 创建独立的 systemd service
 if has_systemd; then
 local svc_name="${SERVICE_NAME}-${t_name}"
 local svc_file="/etc/systemd/system/${svc_name}.service"
 cat > "$svc_file" << EOL
[Unit]
Description=Cloudflared Tunnel - ${t_name}
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${CF_BIN} tunnel --config ${extra_cfg} run
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL
 systemctl daemon-reload
 systemctl enable "$svc_name"
 systemctl start "$svc_name"
 
 if systemctl is-active --quiet "$svc_name"; then
 msg_success "隧道 ${t_name} 已启动！"
 echo -e "访问地址: ${GREEN}https://$hostname${PLAIN}"
 else
 msg_error "隧道启动失败，请检查日志: journalctl -u $svc_name"
 fi
 else
 msg_info "无 systemd，请手动运行: cloudflared tunnel --config $extra_cfg run"
 fi
 pause
}

multi_tunnel_toggle() {
 shift # 去掉第一个参数 (choice)
 local configs=("$@")
 if [ ${#configs[@]} -eq 0 ]; then
 msg_error "没有可操作的隧道。"; return
 fi
 
 echo ""
 echo "请选择要启动/停止的隧道:"
 local i=1
 for cfg_entry in "${configs[@]}"; do
 local cfg_file=$(echo "$cfg_entry" | cut -d'|' -f1)
 local t_name=$(echo "$cfg_entry" | cut -d'|' -f2)
 echo " $i. $t_name ($cfg_file)"
 let i++
 done
 echo " 0. 返回"
 read -p "请选择: " sel
 
 if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#configs[@]} ]; then
 local idx=$((sel-1))
 local cfg_entry="${configs[$idx]}"
 local cfg_file=$(echo "$cfg_entry" | cut -d'|' -f1)
 local t_name=$(echo "$cfg_entry" | cut -d'|' -f2)
 
 if [ "$t_name" == "main" ]; then
 local svc="$SERVICE_NAME"
 else
 local svc="${SERVICE_NAME}-${t_name}"
 fi
 
 if has_systemd && systemctl is-active --quiet "$svc" 2>/dev/null; then
 systemctl stop "$svc"
 msg_success "已停止: $t_name"
 else
 if has_systemd; then
 systemctl start "$svc"
 msg_success "已启动: $t_name"
 else
 nohup cloudflared tunnel --config "$cfg_file" run &>/dev/null &
 msg_success "已启动进程: $t_name"
 fi
 fi
 fi
 sleep 2
}

multi_tunnel_delete() {
 shift
 local configs=("$@")
 # 只允许删除额外隧道 (非 main)
 local extra_configs=()
 local i=1
 for cfg_entry in "${configs[@]}"; do
 local t_name=$(echo "$cfg_entry" | cut -d'|' -f2)
 if [ "$t_name" != "main" ]; then
 local cfg_file=$(echo "$cfg_entry" | cut -d'|' -f1)
 echo " $i. $t_name ($cfg_file)"
 extra_configs+=("$cfg_entry")
 let i++
 fi
 done
 
 if [ ${#extra_configs[@]} -eq 0 ]; then
 msg_error "没有可删除的额外隧道。"
 return
 fi
 
 echo " 0. 返回"
 read -p "请选择要删除的隧道: " sel
 
 if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#extra_configs[@]} ]; then
 local idx=$((sel-1))
 local cfg_entry="${extra_configs[$idx]}"
 local cfg_file=$(echo "$cfg_entry" | cut -d'|' -f1)
 local t_name=$(echo "$cfg_entry" | cut -d'|' -f2)
 local svc="${SERVICE_NAME}-${t_name}"
 
 read -p "确认删除隧道 $t_name? 此操作不可恢复 (yes/N): " confirm
 if [[ "$confirm" == "yes" ]]; then
 has_systemd && systemctl stop "$svc" 2>/dev/null
 has_systemd && systemctl disable "$svc" 2>/dev/null
 rm -f "/etc/systemd/system/${svc}.service"
 has_systemd && systemctl daemon-reload
 rm -f "$cfg_file"
 
 # 尝试删除云端隧道
 local t_uuid=$(get_tunnel_uuid "$cfg_file")
 if [ -n "$t_uuid" ]; then
 cloudflared tunnel delete "$t_uuid" 2>/dev/null
 fi
 
 msg_success "隧道 $t_name 已删除。"
 else
 msg_info "操作已取消。"
 fi
 fi
 sleep 2
}

# [新功能] Docker 模式运行
docker_menu() {
 while true; do
 print_logo
 echo -e "${CYAN}=== Docker 模式运行 ===${PLAIN}"
 
 if ! command -v docker &> /dev/null; then
 msg_error "未检测到 Docker，请先安装 Docker。"
 echo -e "安装命令: ${YELLOW}curl -fsSL https://get.docker.com | sh${PLAIN}"
 pause; return
 fi
 
 # 检查容器状态
 local container_status="未创建"
 if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${DOCKER_CONTAINER}$"; then
 if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${DOCKER_CONTAINER}$"; then
 container_status="${GREEN}● 运行中${PLAIN}"
 else
 container_status="${YELLOW}○ 已停止${PLAIN}"
 fi
 fi
 
 echo -e "容器名: ${YELLOW}$DOCKER_CONTAINER${PLAIN} | 状态: $container_status"
 echo ""
 echo "1. 创建并启动 Docker 容器 (使用本地 config.yml)"
 echo "2. 使用 Token 模式启动 Docker 容器"
 echo "3. 启动容器"
 echo "4. 停止容器"
 echo "5. 重启容器"
 echo "6. 查看容器日志"
 echo "7. 查看容器状态"
 echo "8. 删除容器"
 echo "0. 返回主菜单"
 echo ""
 read -p "请选择: " d_choice
 
 case $d_choice in
 1) docker_create_config ;;
 2) docker_create_token ;;
 3) docker start "$DOCKER_CONTAINER" && msg_success "容器已启动" ;;
 4) docker stop "$DOCKER_CONTAINER" && msg_warn "容器已停止" ;;
 5) docker restart "$DOCKER_CONTAINER" && msg_success "容器已重启" ;;
 6) docker logs -f --tail 50 "$DOCKER_CONTAINER" 2>/dev/null || msg_error "容器不存在" ;;
 7) docker ps -a --filter "name=$DOCKER_CONTAINER" || msg_error "容器不存在" ;;
 8) docker_delete ;;
 0) return ;;
 *) msg_error "无效选项"; sleep 1 ;;
 esac
 [ "$d_choice" != "6" ] && [ "$d_choice" != "0" ] && pause
 done
}

docker_create_config() {
 if [ ! -f "$CONFIG_FILE" ]; then
 msg_error "配置文件不存在，请先创建隧道 (菜单 3)。"
 return
 fi
 
 # 先删除已有容器
 docker rm -f "$DOCKER_CONTAINER" 2>/dev/null
 
 msg_info "正在拉取镜像..."
 docker pull "$DOCKER_IMAGE" 2>/dev/null
 
 msg_info "正在创建并启动容器..."
 docker run -d \
 --name "$DOCKER_CONTAINER" \
 --restart unless-stopped \
 -v "$CONFIG_DIR:$CONFIG_DIR:ro" \
 -v "$CRED_DIR:$CRED_DIR:ro" \
 "$DOCKER_IMAGE" tunnel --config "$CONFIG_FILE" run
 
 if [ $? -eq 0 ]; then
 msg_success "Docker 容器已启动！"
 docker ps --filter "name=$DOCKER_CONTAINER"
 else
 msg_error "容器启动失败。"
 fi
}

docker_create_token() {
 read -p "请输入 Cloudflare Token: " token
 if [ -z "$token" ]; then
 msg_error "Token 不能为空。"
 return
 fi
 
 docker rm -f "$DOCKER_CONTAINER" 2>/dev/null
 
 msg_info "正在拉取镜像..."
 docker pull "$DOCKER_IMAGE" 2>/dev/null
 
 msg_info "正在创建并启动容器..."
 docker run -d \
 --name "$DOCKER_CONTAINER" \
 --restart unless-stopped \
 "$DOCKER_IMAGE" tunnel --token "$token" run
 
 if [ $? -eq 0 ]; then
 msg_success "Docker 容器已启动 (Token 模式)！"
 docker ps --filter "name=$DOCKER_CONTAINER"
 else
 msg_error "容器启动失败。"
 fi
}

docker_delete() {
 read -p "确认删除 Docker 容器? (y/N): " confirm
 if [[ "$confirm" =~ ^[yY]$ ]]; then
 docker rm -f "$DOCKER_CONTAINER" 2>/dev/null
 msg_success "容器已删除。"
 fi
}


# [新功能] 一键诊断报告
diagnose_all() {
 print_logo
 echo -e "${CYAN}=== 一键诊断报告 ===${PLAIN}"
 echo ""
 local pass=0 fail=0 warn=0
 local results=""
 check_item() {
  local name="$1" status="$2" detail="${3:-}"
  case "$status" in
  pass) results+="✅ ${GREEN}$name${PLAIN}: 通过"; [ -n "$detail" ] && results+=" ($detail)"; results+="\n"; pass=$((pass+1)) ;;
  fail) results+="❌ ${RED}$name${PLAIN}: 失败"; [ -n "$detail" ] && results+=" — $detail"; results+="\n"; fail=$((fail+1)) ;;
  warn) results+="⚠️  ${YELLOW}$name${PLAIN}: 警告"; [ -n "$detail" ] && results+=" — $detail"; results+="\n"; warn=$((warn+1)) ;;
  esac
 }
 echo -e "${BLUE}正在逐项检查...${PLAIN}"
 echo ""
 # 1. 二进制
 if command -v cloudflared &>/dev/null; then
  local ver=$(cloudflared --version 2>/dev/null | awk '{print $3}' | sed 's/,//')
  check_item "cloudflared 二进制" pass "v$ver"
 else
  check_item "cloudflared 二进制" fail "未安装"
 fi
 # 2. 配置文件
 if [ -f "$CONFIG_FILE" ]; then
  check_item "配置文件存在" pass "$CONFIG_FILE"
  if command -v cloudflared &>/dev/null; then
   if cloudflared tunnel ingress validate --config "$CONFIG_FILE" 2>/dev/null; then
    check_item "配置语法验证" pass
   else
    check_item "配置语法验证" fail "ingress 规则有误"
   fi
  fi
  local uuid=$(get_tunnel_uuid)
  if [ -n "$uuid" ]; then
   check_item "Tunnel UUID" pass "$uuid"
   local cred="$CRED_DIR/${uuid}.json"
   if [ -f "$cred" ]; then
    check_item "凭证文件" pass
   else
    check_item "凭证文件" fail "$cred 不存在"
   fi
  else
   check_item "Tunnel UUID" fail "配置中未找到"
  fi
 else
  check_item "配置文件" fail "不存在"
 fi
 # 3. 服务状态
 if has_systemd; then
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
   check_item "systemd 服务" pass "运行中"
  else
   check_item "systemd 服务" fail "未运行"
  fi
  if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
   check_item "开机自启" pass
  else
   check_item "开机自启" warn "未设置"
  fi
 else
  if pgrep cloudflared >/dev/null; then
   check_item "cloudflared 进程" pass "PID: $(pgrep cloudflared | head -1)"
  else
   check_item "cloudflared 进程" fail "未运行"
  fi
 fi
 # 4. DNS + 隧道连通性
 if [ -f "$CONFIG_FILE" ]; then
  local first_host=$(awk '/hostname:/ {print $NF; exit}' "$CONFIG_FILE")
  if [ -n "$first_host" ]; then
   if nslookup "$first_host" >/dev/null 2>&1 || host "$first_host" >/dev/null 2>&1; then
    check_item "DNS 解析 ($first_host)" pass
   else
    check_item "DNS 解析 ($first_host)" warn "解析失败"
   fi
   local http_code=$(curl -L -o /dev/null -s -w "%{http_code}" --connect-timeout 8 --max-time 12 "https://$first_host" 2>/dev/null)
   if [ -n "$http_code" ] && [ "$http_code" != "000" ]; then
    check_item "隧道连通性" pass "HTTP $http_code"
   else
    check_item "隧道连通性" fail "不可达"
   fi
  fi
 fi
 # 5. 本地端口检查
 if [ -f "$CONFIG_FILE" ]; then
  local svc_lines=$(awk '/service:.*127\.0\.0\.1/ {print $NF}' "$CONFIG_FILE")
  for svc_url in $svc_lines; do
   local port=$(echo "$svc_url" | grep -oE '[0-9]+$')
   if [ -n "$port" ]; then
    if curl -s --connect-timeout 2 -I "$svc_url" >/dev/null 2>&1; then
     check_item "本地端口 $port" pass
    else
     check_item "本地端口 $port" warn "无响应"
    fi
   fi
  done
 fi
 # 6. Cloudflare 连通性 + IPv6
 if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
  check_item "Cloudflare 连通性" pass
 else
  check_item "Cloudflare 连通性" fail "无法 ping 通 1.1.1.1"
 fi
 if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
  check_item "IPv6 地址" pass "已配置"
 else
  check_item "IPv6 地址" warn "未配置"
 fi
 # 输出
 echo -e "${BLUE}========================================${PLAIN}"
 echo -e "${CYAN}诊断报告${PLAIN}"
 echo -e "${BLUE}========================================${PLAIN}"
 echo -e "$results"
 echo -e "${BLUE}----------------------------------------${PLAIN}"
 echo -e "总计: ${GREEN}$pass 通过${PLAIN} | ${RED}$fail 失败${PLAIN} | ${YELLOW}$warn 警告${PLAIN}"
 echo -e "${BLUE}----------------------------------------${PLAIN}"
 if [ "$fail" -gt 0 ]; then
  echo -e "${RED}存在失败项，建议逐一排查。${PLAIN}"
 elif [ "$warn" -gt 0 ]; then
  echo -e "${YELLOW}存在警告项，建议关注。${PLAIN}"
 else
  echo -e "${GREEN}全部检查通过！隧道运行正常。${PLAIN}"
 fi
 pause
}

# [新功能] 常用服务配置模板库
service_template_menu() {
 print_logo
 check_cf || return
 if [ ! -f "$CONFIG_FILE" ]; then
  msg_error "配置文件不存在，请先创建隧道。"
  pause; return
 fi
 echo -e "${CYAN}=== 常用服务模板库 ===${PLAIN}"
 echo "选择常用服务模板，自动填充端口，只需输入域名前缀。"
 echo ""
 local templates=(
  "NAS Web|5000"
  "Plex|32400"
  "Jellyfin|8096"
  "Emby|8096"
  "Home Assistant|8123"
  "qBittorrent|8080"
  "Transmission|9091"
  "Alist|5244"
  "Gitea|3000"
  "Nextcloud|80"
  "Portainer|9000"
  "AdGuard Home|3000"
  "Vaultwarden|80"
  "Nginx|80"
 )
 local i=1
 for tpl in "${templates[@]}"; do
  local name=$(echo "$tpl" | cut -d'|' -f1)
  local port=$(echo "$tpl" | cut -d'|' -f2)
  printf " %2d. %-20s 端口: %s\n" "$i" "$name" "$port"
  let i++
 done
 echo "  0. 返回上一级"
 echo ""
 read -p "请选择服务模板: " tpl_choice
 if [[ "$tpl_choice" == "0" ]]; then return; fi
 if ! [[ "$tpl_choice" =~ ^[0-9]+$ ]] || [ "$tpl_choice" -lt 1 ] || [ "$tpl_choice" -gt ${#templates[@]} ]; then
  msg_error "无效选择"; return
 fi
 local idx=$((tpl_choice-1))
 local selected="${templates[$idx]}"
 local svc_name=$(echo "$selected" | cut -d'|' -f1)
 local svc_port=$(echo "$selected" | cut -d'|' -f2)
 local svc_url="http://127.0.0.1:$svc_port"
 echo ""
 echo -e "已选择: ${GREEN}$svc_name${PLAIN} (端口 $svc_port)"
 read -p "请输入域名前缀 (如 mynas): " prefix
 if [[ -z "$prefix" ]]; then
  msg_error "前缀不能为空"; return
 fi
 # 从现有配置提取域名后缀
 local existing_host=$(awk '/hostname:/ {print $NF; exit}' "$CONFIG_FILE" 2>/dev/null)
 local domain_suffix=""
 if [ -n "$existing_host" ]; then
  domain_suffix=$(echo "$existing_host" | sed 's/^[^.]*\.//')
 fi
 local full_host=""
 if [ -n "$domain_suffix" ]; then
  full_host="${prefix}.${domain_suffix}"
  read -p "完整域名 (回车使用 $full_host): " input_host
  [ -n "$input_host" ] && full_host="$input_host"
 else
  read -p "请输入完整域名 (如 ${prefix}.example.com): " full_host
 fi
 if [[ -z "$full_host" ]]; then
  msg_error "域名不能为空"; return
 fi
 if grep -q "hostname: $full_host" "$CONFIG_FILE" 2>/dev/null; then
  msg_error "域名 $full_host 已存在。"; return
 fi
 echo ""
 msg_info "将添加: $full_host -> $svc_url"
 # 健康检查
 if ! curl -s --connect-timeout 2 -I "$svc_url" >/dev/null 2>&1; then
  msg_warn "本地端口 $svc_port 无响应，服务可能未启动。"
  read -p "仍然添加? (y/N): " force
  [[ ! "$force" =~ ^[yY]$ ]] && return
 else
  msg_success "本地服务检测通畅。"
 fi
 local TUNNEL_UUID=$(get_tunnel_uuid)
 if [ -z "$TUNNEL_UUID" ]; then
  msg_error "无法读取 Tunnel UUID。"; return
 fi
 cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
 local INSERT_STR=" - hostname: $full_host\n service: $svc_url"
 if grep -q "http_status:404" "$CONFIG_FILE"; then
  sed -i "/- service: http_status:404/i $INSERT_STR" "$CONFIG_FILE"
 else
  echo -e "$INSERT_STR" >> "$CONFIG_FILE"
  echo " - service: http_status:404" >> "$CONFIG_FILE"
 fi
 # 显示 diff 预览
 show_config_diff "${CONFIG_FILE}.bak" "$CONFIG_FILE" || return
 msg_info "正在验证配置语法..."
 if validate_config; then
  msg_info "正在添加 DNS 记录..."
  cloudflared tunnel route dns "$TUNNEL_UUID" "$full_host" 2>/dev/null
  msg_info "重启服务..."
  restart_cf
  msg_success "已添加: $full_host -> $svc_url"
 else
  msg_error "配置验证失败，已回滚。"
 fi
 sleep 2
}

# [新功能] 配置变更 diff 预览
show_config_diff() {
 local old_file="$1" new_file="$2"
 if [ ! -f "$old_file" ] || [ ! -f "$new_file" ]; then
  return 0
 fi
 # 只有有差异才显示
 if cmp -s "$old_file" "$new_file"; then
  return 0
 fi
 echo ""
 echo -e "${CYAN}--- 配置变更预览 (diff) ---${PLAIN}"
 diff "$old_file" "$new_file" 2>/dev/null
 echo -e "${CYAN}------------------------${PLAIN}"
 read -p "确认应用此变更? (y/N): " confirm
 if [[ ! "$confirm" =~ ^[yY]$ ]]; then
  msg_info "已取消，正在回滚..."
  cp "$old_file" "$new_file"
  return 1
 fi
 return 0
}

# [新功能] 隧道迁移助手
tunnel_migrate() {
 while true; do
  print_logo
  check_cf || return
  echo -e "${CYAN}=== 隧道迁移助手 ===${PLAIN}"
  echo "导出当前隧道的完整配置和凭证，在新机器上导入即可接管同一隧道。"
  echo ""
  echo "1. 导出迁移包 (配置 + 凭证)"
  echo "2. 导入迁移包"
  echo "0. 返回上一级"
  echo ""
  read -p "请选择: " mig_choice
  case $mig_choice in
  1) tunnel_migrate_export ;;
  2) tunnel_migrate_import ;;
  0) return ;;
  *) msg_error "无效选项"; sleep 1 ;;
  esac
 done
}

tunnel_migrate_export() {
 if [ ! -f "$CONFIG_FILE" ]; then
  msg_error "配置文件不存在。"; return
 fi
 local uuid=$(get_tunnel_uuid)
 if [ -z "$uuid" ]; then
  msg_error "无法读取 Tunnel UUID。"; return
 fi
 local cred_file="$CRED_DIR/${uuid}.json"
 if [ ! -f "$cred_file" ]; then
  msg_error "凭证文件不存在: $cred_file"; return
 fi
 local export_file="/root/cloudflared_migration_$(date +%Y%m%d_%H%M%S).tar.gz"
 msg_info "正在打包迁移文件..."
 tar -czf "$export_file" -C / etc/cloudflared/config.yml "root/.cloudflared/${uuid}.json" 2>/dev/null
 if [ -f "$export_file" ]; then
  msg_success "迁移包已生成: $export_file"
  echo ""
  echo -e "${YELLOW}迁移步骤：${PLAIN}"
  echo "1. 将 $export_file 传到新机器 (scp 或 U盘)"
  echo "2. 在新机器安装 cloudflared (菜单 1)"
  echo "3. 在新机器运行本脚本 → 工具箱 → 隧道迁移 → 导入迁移包"
  echo "4. 确认新机器隧道正常后，停止旧机器的服务"
  echo ""
  echo -e "${RED}注意：同一隧道不能在两台机器同时运行！${PLAIN}"
  echo -e "迁移包含凭证文件，请妥善保管，勿公开分享。"
 else
  msg_error "打包失败。"
 fi
 pause
}

tunnel_migrate_import() {
 echo ""
 read -p "请输入迁移包路径: " import_path
 if [ ! -f "$import_path" ]; then
  msg_error "文件不存在: $import_path"; return
 fi
 msg_warn "导入将覆盖当前配置和凭证！"
 read -p "确认导入? (y/N): " confirm
 if [[ ! "$confirm" =~ ^[yY]$ ]]; then return; fi
 # 安全备份
 if [ -d "$CONFIG_DIR" ] || [ -d "$CRED_DIR" ]; then
  local safety="/root/cloudflared_pre_migrate_$(date +%Y%m%d_%H%M%S).tar.gz"
  tar -czf "$safety" -C / etc/cloudflared root/.cloudflared 2>/dev/null
  msg_info "当前配置已备份到: $safety"
 fi
 has_systemd && systemctl stop "$SERVICE_NAME" 2>/dev/null
 mkdir -p "$CONFIG_DIR" "$CRED_DIR"
 tar -xzf "$import_path" -C /
 if [ -f "$CONFIG_FILE" ]; then
  msg_success "迁移包已解压。"
  msg_info "正在验证配置..."
  if validate_config; then
   msg_info "正在重启服务..."
   if has_systemd; then
    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME"
   else
    nohup cloudflared tunnel --config "$CONFIG_FILE" run &>/dev/null &
   fi
   sleep 3
   if has_systemd && systemctl is-active --quiet "$SERVICE_NAME"; then
    msg_success "迁移成功！隧道已在新机器上运行。"
    show_tunnel_info
   elif pgrep cloudflared >/dev/null; then
    msg_success "迁移成功！进程已启动。"
   else
    msg_error "服务启动失败，请检查日志。"
   fi
  fi
 else
  msg_error "解压后未找到配置文件。"
 fi
 pause
}

# [新功能] 日志轮转配置
setup_logrotate() {
 print_logo
 echo -e "${CYAN}=== 日志轮转配置 ===${PLAIN}"
 local LOG_FILE="/var/log/cloudflared.log"
 local ROTATE_CONF="/etc/logrotate.d/cloudflared"
 echo "为非 systemd 环境的日志文件设置自动轮转，避免日志占满磁盘。"
 echo ""
 if ! command -v logrotate &>/dev/null; then
  msg_error "未安装 logrotate。请先安装: apt install logrotate 或 yum install logrotate"
  pause; return
 fi
 # 检查当前状态
 if [ -f "$ROTATE_CONF" ]; then
  echo -e "当前状态: ${GREEN}已配置${PLAIN}"
  echo ""
  echo "1. 查看当前轮转配置"
  echo "2. 重新配置"
  echo "3. 删除轮转配置"
  echo "0. 返回"
  read -p "请选择: " lr_choice
  case "$lr_choice" in
  1) cat "$ROTATE_CONF"; pause; return ;;
  3) rm -f "$ROTATE_CONF"; msg_success "已删除轮转配置。"; pause; return ;;
  2) ;; # 继续到下面的配置
  0) return ;;
  *) return ;;
  esac
 else
  echo -e "当前状态: ${YELLOW}未配置${PLAIN}"
 fi
 echo ""
 read -p "日志文件路径 (回车使用默认 /var/log/cloudflared.log): " input_log
 [ -n "$input_log" ] && LOG_FILE="$input_log"
 # 确保日志文件存在
 touch "$LOG_FILE" 2>/dev/null
 cat > "$ROTATE_CONF" << EOF
$LOG_FILE {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
 msg_success "日志轮转已配置！"
 echo -e "日志文件: ${GREEN}$LOG_FILE${PLAIN}"
 echo -e "轮转策略: 每天轮转，保留 7 天，自动压缩"
 pause
}

# [新功能] IPv6 环境适配
ipv6_check() {
 print_logo
 check_cf || return
 echo -e "${CYAN}=== IPv6 环境检测与适配 ===${PLAIN}"
 echo ""
 # 检测 IPv6 地址
 local has_ipv6=false
 if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
  has_ipv6=true
  echo -e "IPv6 全局地址: ${GREEN}已配置${PLAIN}"
  ip -6 addr show scope global 2>/dev/null | grep inet6 | awk '{print "  " $2}'
 else
  echo -e "IPv6 全局地址: ${YELLOW}未配置${PLAIN}"
 fi
 echo ""
 # 检测 IPv4
 local has_ipv4=false
 if ip -4 addr show scope global 2>/dev/null | grep -q inet; then
  has_ipv4=true
  echo -e "IPv4 全局地址: ${GREEN}已配置${PLAIN}"
 else
  echo -e "IPv4 全局地址: ${YELLOW}未配置${PLAIN}"
 fi
 echo ""
 # 判断环境类型
 if [ "$has_ipv6" = true ] && [ "$has_ipv4" = false ]; then
  echo -e "${RED}检测到 IPv6-only 环境！${PLAIN}"
  echo "cloudflared 默认使用 IPv4 连接 Cloudflare 边缘，在 IPv6-only 环境会连接失败。"
  echo "需要在配置中添加 edge-ip-version: 6 参数。"
  echo ""
  if [ -f "$CONFIG_FILE" ]; then
   if grep -q "edge-ip-version" "$CONFIG_FILE"; then
    echo -e "当前配置已包含 edge-ip-version 参数。"
    grep "edge-ip-version" "$CONFIG_FILE"
   else
    read -p "是否自动添加 edge-ip-version: 6 到配置? (y/N): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
     cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
     sed -i "/^credentials-file:/a edge-ip-version: 6" "$CONFIG_FILE"
     msg_success "已添加 edge-ip-version: 6"
     msg_info "正在验证并重启..."
     validate_config && restart_cf
    fi
   fi
  fi
 elif [ "$has_ipv6" = true ] && [ "$has_ipv4" = true ]; then
  echo -e "${GREEN}双栈环境 (IPv4 + IPv6)${PLAIN}"
  echo "cloudflared 默认使用 IPv4，无需特殊处理。"
  echo ""
  if [ -f "$CONFIG_FILE" ]; then
   if grep -q "edge-ip-version" "$CONFIG_FILE"; then
    echo -e "当前配置包含 edge-ip-version 参数:"
    grep "edge-ip-version" "$CONFIG_FILE"
    echo ""
    read -p "是否移除 edge-ip-version 参数恢复默认? (y/N): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
     cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
     sed -i "/edge-ip-version/d" "$CONFIG_FILE"
     msg_success "已移除 edge-ip-version"
     validate_config && restart_cf
    fi
   else
    echo "配置中未设置 edge-ip-version，使用默认 (IPv4)。"
   fi
  fi
 else
  echo -e "${RED}未检测到任何全局 IP 地址！${PLAIN}"
  echo "请检查网络配置。"
 fi
 echo ""
 # 测试 Cloudflare IPv6 连通性
 echo -e "${CYAN}--- Cloudflare IPv6 连通性测试 ---${PLAIN}"
 if ping -6 -c 2 -W 3 2606:4700:4700::1111 >/dev/null 2>&1; then
  echo -e "Cloudflare IPv6 (2606:4700:4700::1111): ${GREEN}可达${PLAIN}"
 else
  echo -e "Cloudflare IPv6 (2606:4700:4700::1111): ${YELLOW}不可达${PLAIN}"
 fi
 if ping -4 -c 2 -W 3 1.1.1.1 >/dev/null 2>&1; then
  echo -e "Cloudflare IPv4 (1.1.1.1): ${GREEN}可达${PLAIN}"
 else
  echo -e "Cloudflare IPv4 (1.1.1.1): ${YELLOW}不可达${PLAIN}"
 fi
 pause
}
uninstall_cloudflared() {
 print_logo
 echo -e "${RED}========================================${PLAIN}"
 echo -e "此操作将执行以下动作："
 echo -e "1. 停止并禁用 cloudflared 服务"
 echo -e "2. 删除 ${CF_BIN} 执行文件"
 echo -e "3. 删除 ${CONFIG_DIR} 配置目录"
 echo -e "4. 删除 ${CRED_DIR} 凭证目录"
 echo -e "5. 删除 systemd 服务文件"
 echo -e "6. 清理定时任务 (crontab)"
 echo -e "7. 删除快捷命令 ${CF_CMD}"
 echo -e "8. 删除 Docker 容器 (如存在)"
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
 has_systemd && systemctl stop "$SERVICE_NAME" 2>/dev/null
 has_systemd && systemctl disable "$SERVICE_NAME" 2>/dev/null
 
 # 停止并删除额外隧道服务
 for svc_file in /etc/systemd/system/${SERVICE_NAME}-*.service; do
 if [ -f "$svc_file" ]; then
 local svc_name=$(basename "$svc_file" .service)
 systemctl stop "$svc_name" 2>/dev/null
 systemctl disable "$svc_name" 2>/dev/null
 rm -f "$svc_file"
 fi
 done
 
 msg_info "正在清理文件..."
 rm -f "$CF_BIN"
 rm -rf "$CONFIG_DIR"
 rm -rf "$CRED_DIR"
 rm -f "$SERVICE_FILE"
 rm -f "$SERVICE_FILE_LIB"
 
 # 清理 systemd override
 rm -rf "/etc/systemd/system/${SERVICE_NAME}.service.d"
 
 # 清理 crontab 定时任务
 if crontab -l 2>/dev/null | grep -q "cloudflared"; then
 crontab -l 2>/dev/null | grep -v "cloudflared" | crontab -
 msg_info "已清理 crontab 中的 cloudflared 定时任务"
 fi
 
 # 删除快捷命令
 rm -f "/usr/bin/${CF_CMD}"
 has_systemd && systemctl daemon-reload
 
 # 删除 Docker 容器
 if command -v docker &> /dev/null; then
 docker rm -f "$DOCKER_CONTAINER" 2>/dev/null && msg_info "已删除 Docker 容器"
 fi
 
 msg_success "Cloudflared 已从系统中彻底移除。"
 echo "脚本自身未被删除，您可以使用 'rm $0' 删除本脚本。"
 exit 0
}

update_script() {
 print_logo
 echo -e "${CYAN}=== 脚本自我更新 ===${PLAIN}"
 
 if [[ -z "$SCRIPT_URL" ]]; then
 msg_warn "未配置更新源 (SCRIPT_URL)。"
 pause; return
 fi
 
 msg_info "正在检查脚本更新..."
 local TEMP_FILE="/tmp/cf_manager_new.sh"
 register_temp "$TEMP_FILE"
 local DOWNLOAD_URL="${SCRIPT_URL}"
 
 if [[ -n "$GH_PROXY" && "$SCRIPT_URL" == *"github"* ]]; then
 DOWNLOAD_URL="${GH_PROXY}${SCRIPT_URL}"
 fi
 
 msg_info "正在获取最新脚本版本..."
 wget -q -O "$TEMP_FILE" "$DOWNLOAD_URL" 2>/dev/null
 if [ $? -ne 0 ] || [ ! -s "$TEMP_FILE" ]; then
 msg_warn "代理下载失败, 尝试直连..."
 wget -q -O "$TEMP_FILE" "$SCRIPT_URL" 2>/dev/null
 fi
 
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

# --- 分组子菜单 ---

install_menu() {
 while true; do
  print_logo
  echo -e "${CYAN}=== 安装与部署 ===${PLAIN}"
  echo -e "1. 安装 / 更新 / 降级 Cloudflared (含版本检测)"
  echo -e "2. Token 模式安装 (网页端管理)"
  echo -e "3. 登录 Cloudflare 账户"
  echo -e "4. Docker 模式运行"
  echo -e "0. 返回主菜单"
  echo ""
  read -p "请选择 [0-4]: " sub_choice
  case $sub_choice in
  1) install_cloudflared ;;
  2) install_token_mode ;;
  3) login_cloudflare ;;
  4) docker_menu ;;
  0) return ;;
  *) msg_error "无效选项"; sleep 1 ;;
  esac
 done
}

tunnel_menu() {
 while true; do
  print_logo
  echo -e "${CYAN}=== 隧道与域名管理 ===${PLAIN}"
  echo -e "1. 创建新隧道 (本机向导)"
  echo -e "2. ${GREEN}管理域名 (添加/删除 本地路由) [常用]${PLAIN}"
  echo -e "3. 列出云端所有隧道"
  echo -e "4. 多隧道管理"
  echo -e "0. 返回主菜单"
  echo ""
  read -p "请选择 [0-4]: " sub_choice
  case $sub_choice in
  1) create_tunnel_wizard ;;
  2) manage_domains ;;
  3)
   print_logo
   cloudflared tunnel list
   pause
   ;;
  4) multi_tunnel_menu ;;
  0) return ;;
  *) msg_error "无效选项"; sleep 1 ;;
  esac
 done
}

ops_menu() {
 while true; do
  print_logo
  echo -e "${CYAN}=== 服务运维 ===${PLAIN}"
  echo -e "1. 服务管理 (启动/停止/日志)"
  echo -e "2. ${GREEN}一键诊断报告${PLAIN}"
  echo -e "3. 定时任务与自动保活 (Crontab/Systemd)"
  echo -e "0. 返回主菜单"
  echo ""
  read -p "请选择 [0-3]: " sub_choice
  case $sub_choice in
  1) service_status ;;
  2) diagnose_all ;;
  3) manage_cron ;;
  0) return ;;
  *) msg_error "无效选项"; sleep 1 ;;
  esac
 done
}

# --- 主菜单 ---

while true; do
 print_logo
 echo -e "${CYAN}========== Cloudflared 隧道管理 ==========${PLAIN}"
 echo ""
 echo -e "1. ${BLUE}安装与部署${PLAIN}  (安装/Token/登录/Docker)"
 echo -e "2. ${GREEN}隧道与域名${PLAIN}  (创建/域名管理/列表/多隧道)"
 echo -e "3. ${BLUE}服务运维${PLAIN}    (启停/诊断/定时保活)"
 echo -e "4. ${BLUE}高级工具箱${PLAIN}  (日志/备份/模板/迁移/IPv6...)"
 echo -e "5. 更新此脚本"
 echo -e "6. ${RED}彻底卸载 Cloudflared${PLAIN}"
 echo -e "0. 退出"
 echo ""
 read -p "请输入选项 [0-6]: " choice

 case $choice in
 1) install_menu ;;
 2) tunnel_menu ;;
 3) ops_menu ;;
 4) toolbox_menu ;;
 5) update_script ;;
 6) uninstall_cloudflared ;;
 0) echo "退出。"; exit 0 ;;
 *) msg_error "无效选项"; sleep 1 ;;
 esac
done
