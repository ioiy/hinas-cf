#!/bin/bash

# Cloudflared 隧道管理脚本 (V3 - 本机安全版)
# 专注于管理本机的 config.yml 和域名，移除了危险的隧道删除功能。
# 基于教程: https://bbs.histb.com/d/240-cloudflared-https

# 确保以root权限运行
if [ "$(id -u)" -ne 0 ]; then
  echo "此脚本需要root权限运行。请使用 'sudo ./cf.sh' 运行。"
  exit 1
fi

CONFIG_DIR="/etc/cloudflared"
CONFIG_FILE="$CONFIG_DIR/config.yml"
CRED_DIR="/root/.cloudflared" # 教程中默认的凭证目录

# 检查 cloudflared 是否已安装
check_cloudflared() {
    if ! command -v cloudflared &> /dev/null; then
        echo "cloudflared 命令未找到。正在尝试下载 (ARM 32-bit)..."
        echo "如果您的架构不同，请从 https://github.com/cloudflare/cloudflared/releases 手动下载。"
        # 注意：教程中的版本较旧，您可以替换为更新的下载链接
        wget https://ghproxy.futils.com/https://github.com/cloudflare/cloudflared/releases/download/2022.5.1/cloudflared-linux-arm -O /usr/bin/cloudflared
        if [ $? -ne 0 ]; then
            echo "下载失败。请手动安装 cloudflared。"
            exit 1
        fi
        chmod 0777 /usr/bin/cloudflared
    fi
    # 确保配置目录存在
    mkdir -p $CONFIG_DIR
}

# 1. 登录 (如果需要)
login() {
    echo "----------------------------------------"
    echo "1. 登录 Cloudflare"
    echo "----------------------------------------"
    echo "您将被重定向到一个浏览器窗口进行登录。"
    echo "请登录并授权您的域名。"
    
    cloudflared login
    
    echo "登录完成。凭证证书已保存。"
    read -p "按回车键返回菜单..."
}

# 2. 安装/配置新隧道 (本机的初始设置)
create_tunnel() {
    echo "----------------------------------------"
    echo "2. 安装/配置新隧道 (本机的初始设置)"
    echo "----------------------------------------"
    
    if [ -f "$CONFIG_FILE" ]; then
        echo "警告： $CONFIG_FILE 已经存在。"
        read -p "继续操作将覆盖现有配置。确定吗? (y/N): " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[yY]$ ]]; then
            echo "操作已取消。"
            read -p "按回车键返回菜单..."
            return
        fi
    fi
    
    read -p "请输入【新】隧道的名称 (例如: nas): " TUNNEL_NAME
    if [ -z "$TUNNEL_NAME" ]; then
        echo "隧道名称不能为空。"
        return
    fi

    echo "正在创建隧道 '$TUNNEL_NAME'..."
    
    CREATE_OUTPUT=$(cloudflared tunnel create $TUNNEL_NAME 2>&1)
    
    if [ $? -ne 0 ]; then
        echo "创建隧道失败:"
        echo "$CREATE_OUTPUT"
        read -p "按回车键返回菜单..."
        return
    fi
    
    echo "$CREATE_OUTPUT"
    
    TUNNEL_UUID=$(echo "$CREATE_OUTPUT" | grep -oP 'created tunnel \K[a-f0-9-]{36}')
    
    if [ -z "$TUNNEL_UUID" ]; then
        echo "无法从输出中自动提取 Tunnel UUID。请检查上面的输出。"
        read -p "请手动输入 Tunnel UUID: " TUNNEL_UUID
    fi
    
    CRED_FILE="$CRED_DIR/${TUNNEL_UUID}.json"
    if [ ! -f "$CRED_FILE" ]; then
        echo "警告：在 $CRED_DIR 中未找到凭证文件 ${TUNNEL_UUID}.json。"
    fi

    echo "隧道 UUID: $TUNNEL_UUID"
    echo "凭证文件: $CRED_FILE"
    
    read -p "请输入您要绑定的【第一个】主机名 (例如: nas.yourdomain.com): " HOSTNAME
    read -p "请输入您要穿透的本地服务地址 (例如: http://127.0.0.1:8080): " SERVICE_URL
    
    echo "正在创建配置文件: $CONFIG_FILE"
    
    cat > $CONFIG_FILE << EOL
tunnel: $TUNNEL_UUID
credentials-file: $CRED_FILE
ingress:
  - hostname: $HOSTNAME
    service: $SERVICE_URL
  # 默认规则：所有其他流量返回 404
  - service: http_status:404
EOL

    echo "配置文件创建成功。"
    
    echo "正在为 '$HOSTNAME' 创建 DNS 记录..."
    cloudflared tunnel route dns $TUNNEL_NAME $HOSTNAME
    
    echo "DNS 记录创建成功。"
    
    echo "正在安装并启动 systemd 服务..."
    cloudflared service install
    systemctl start cloudflared
    
    echo "隧道 '$TUNNEL_NAME' 已创建并启动！"
    echo "您现在应该可以通过 https://$HOSTNAME 访问。"
    systemctl status cloudflared --no-pager
    
    read -p "按回车键返回菜单..."
}

# 3. 列出您 Cloudflare 账户上的【所有】隧道
list_all_tunnels() {
    echo "----------------------------------------"
    echo "3. 列出您 Cloudflare 账户上的【所有】隧道"
    echo "----------------------------------------"
    echo "(这显示的是您云端账户中的所有隧道，包括其他机器上的)"
    cloudflared tunnel list
    read -p "按回车键返回菜单..."
}

# 4. 管理本机服务 (systemd)
manage_service() {
    echo "----------------------------------------"
    echo "4. 管理本机服务 (systemd)"
    echo "----------------------------------------"
    PS3="请选择操作: "
    options=("查看状态" "启动服务" "停止服务" "重启服务" "返回主菜单")
    select opt in "${options[@]}"
    do
        case $opt in
            "查看状态")
                systemctl status cloudflared --no-pager
                ;;
            "启动服务")
                systemctl start cloudflared
                systemctl status cloudflared --no-pager
                ;;
            "停止服务")
                systemctl stop cloudflared
                systemctl status cloudflared --no-pager
                ;;
            "重启服务")
                systemctl restart cloudflared
                systemctl status cloudflared --no-pager
                ;;
            "返回主菜单")
                break
                ;;
            *) echo "无效选项 $REPLY";;
        esac
    done
}

# --- 域名管理帮助函数 ---
list_domains_from_config() {
    echo "--- 当前 $CONFIG_FILE 中的域名配置 ---"
    
    # V6.0 - 使用Python脚本(如果可用),否则使用简化的bash
    
    # 检查是否有Python
    if command -v python3 &> /dev/null; then
        # 使用Python内联脚本
        python3 - "$CONFIG_FILE" << 'PYEOF'
import sys, re
try:
    with open(sys.argv[1], 'r') as f:
        lines = f.readlines()
    in_ingress, hostname = False, None
    for line in lines:
        line = line.rstrip('\n')
        if line.strip() == 'ingress:':
            in_ingress = True
            continue
        if not in_ingress:
            continue
        m = re.match(r'^\s*-\s*hostname:\s*(.+)$', line)
        if m:
            hostname = m.group(1).strip()
            continue
        m = re.match(r'^\s*service:\s*(.+)$', line)
        if m and hostname:
            service = m.group(1).strip()
            if service == 'http_status:404':
                break
            pm = re.search(r':(\d+)$', service)
            if pm:
                print(f" -> {hostname}:{pm.group(1)}")
            else:
                print(f" -> {hostname}:80/443")
            hostname = None
except Exception as e:
    print(f"错误: {e}")
PYEOF
    else
        # 备用方案:使用最简单的grep+cut方法
        grep -B1 "service:" "$CONFIG_FILE" | grep -v "^--$" | while IFS= read -r line; do
            if echo "$line" | grep -q "hostname:"; then
                h=$(echo "$line" | cut -d: -f2- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
                read -r svc
                if echo "$svc" | grep -q "http_status:404"; then
                    break
                fi
                # 检查端口
                if echo "$svc" | grep -qE ':[0-9]+$'; then
                    p=$(echo "$svc" | rev | cut -d: -f1 | rev)
                    echo " -> $h:$p"
                else
                    echo " -> $h:80/443"
                fi
            fi
        done
    fi
    
    echo "----------------------------------------"
}

add_domain() {
    echo "--- 添加新域名到 $CONFIG_FILE ---"
    
    # 从本机config.yml中读取隧道UUID
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "错误: 配置文件 $CONFIG_FILE 不存在"
        read -p "按回车键返回..."
        return
    fi
    
    TUNNEL_UUID=$(grep "^tunnel:" "$CONFIG_FILE" | cut -d: -f2- | tr -d ' ')
    
    if [ -z "$TUNNEL_UUID" ]; then
        echo "错误: 无法从 $CONFIG_FILE 中读取隧道UUID"
        read -p "按回车键返回..."
        return
    fi
    
    # 尝试获取隧道名称(静默失败)
    TUNNEL_NAME=$(cloudflared tunnel info $TUNNEL_UUID 2>/dev/null | grep "^Name:" | cut -d: -f2- | tr -d ' ')
    
    # 如果获取失败,直接使用UUID(UUID也可以用于DNS路由)
    if [ -z "$TUNNEL_NAME" ]; then
        TUNNEL_NAME=$TUNNEL_UUID
    fi
    
    echo "本机隧道: $TUNNEL_NAME"
    echo "----------------------------------------"

    read -p "请输入【新】域名 (例如: jellyfin.yourdomain.com): " NEW_HOST
    read -p "请输入该域名对应的【本地服务地址】 (例如: http://127.0.0.1:8096): " NEW_SERVICE
    
    if [ -z "$NEW_HOST" ] || [ -z "$NEW_SERVICE" ]; then
        echo "域名和服务地址都不能为空。"
        return
    fi
    
    # 验证服务地址格式
    if ! echo "$NEW_SERVICE" | grep -qE '^https?://'; then
        echo "警告: 服务地址格式不正确。"
        echo "服务地址必须以 http:// 或 https:// 开头"
        echo "例如: http://127.0.0.1:8096"
        echo ""
        read -p "是否自动添加 http:// 前缀? (Y/n): " AUTO_FIX
        if [[ ! "$AUTO_FIX" =~ ^[nN]$ ]]; then
            # 如果只输入了端口号
            if echo "$NEW_SERVICE" | grep -qE '^[0-9]+$'; then
                NEW_SERVICE="http://127.0.0.1:$NEW_SERVICE"
                echo "已修正为: $NEW_SERVICE"
            else
                NEW_SERVICE="http://$NEW_SERVICE"
                echo "已修正为: $NEW_SERVICE"
            fi
        else
            echo "操作已取消。"
            return
        fi
    fi
    
    # 检查是否已有 404 规则
    if ! grep -q "http_status:404" "$CONFIG_FILE"; then
        echo "警告: 您的 $CONFIG_FILE 中没有 'service: http_status:404' 规则。"
        echo "将把新规则追加到文件末尾..."
        echo "  - hostname: $NEW_HOST" >> $CONFIG_FILE
        echo "    service: $NEW_SERVICE" >> $CONFIG_FILE
    else
        echo "正在将新域名规则插入到 404 规则之前..."
        # 使用 sed 在 404 规则前插入
        sed -i "/^[[:space:]]*- service: http_status:404/i \ \ - hostname: $NEW_HOST\n    service: $NEW_SERVICE" $CONFIG_FILE
    fi

    if [ $? -ne 0 ]; then
        echo "错误：修改 $CONFIG_FILE 失败。"
        return
    fi
    
    echo "配置文件已更新。"
    echo "正在为 $NEW_HOST 创建 DNS 路由..."
    cloudflared tunnel route dns $TUNNEL_NAME $NEW_HOST
    
    echo "正在重启 cloudflared 服务以应用更改..."
    systemctl restart cloudflared
    
    echo "完成！新域名 $NEW_HOST 已添加并指向 $NEW_SERVICE。"
    systemctl status cloudflared --no-pager
}

delete_domain() {
    echo "--- 从 $CONFIG_FILE 删除域名 ---"
    list_domains_from_config
    
    read -p "请输入您要删除的【完整主机名】 (例如: bt.yourdomain.com): " HOST_TO_DELETE
    if [ -z "$HOST_TO_DELETE" ]; then
        echo "主机名不能为空。"
        return
    fi
    
    # 检查域名是否存在于文件中
    if ! grep -q "hostname: $HOST_TO_DELETE" "$CONFIG_FILE"; then
        echo "错误：在 $CONFIG_FILE 中未找到主机名 '$HOST_TO_DELETE'。"
        return
    fi
    
    echo "正在从 $CONFIG_FILE 中删除 '$HOST_TO_DELETE' 及其服务..."
    
    # 使用 sed 查找匹配 'hostname: ...' 的行，并删除它及它的下一行 (+1)
    sed -i -e "/^[[:space:]]*- hostname: $HOST_TO_DELETE$/,+1 d" $CONFIG_FILE

    if [ $? -ne 0 ]; then
        echo "错误：修改 $CONFIG_FILE 失败。"
        return
    fi
    
    echo "配置文件已更新。"
    echo "注意：DNS CNAME 记录 ($HOST_TO_DELETE) 仍然存在于 Cloudflare。"
    echo "它现在将返回 404，因为它已从隧道配置中移除。"
    
    echo "正在重启 cloudflared 服务以应用更改..."
    systemctl restart cloudflared
    
    echo "完成！已删除域名 $HOST_TO_DELETE 的本地路由。"
    systemctl status cloudflared --no-pager
}
# --- 结束帮助函数 ---


# 5. 【重点】管理本机的域名 (config.yml)
manage_local_domains() {
    echo "----------------------------------------"
    echo "5. 管理本机的域名 (config.yml)"
    echo "----------------------------------------"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "错误: 配置文件 $CONFIG_FILE 未找到。"
        echo "请先使用 '安装/配置新隧道' (选项2) 创建一个配置。"
        read -p "按回车键返回菜单..."
        return
    fi

    while true; do
        echo "--- 域名管理子菜单 ---"
        echo "1. 查看当前配置的域名"
        echo "2. 添加一个新的域名"
        echo "3. 删除一个已配置的域名"
        echo "4. 返回主菜单"
        echo "----------------------"
        read -p "请选择操作 [1-4]: " domain_choice
        
        case $domain_choice in
            1)
                list_domains_from_config
                read -p "按回车键返回..."
                ;;
            2)
                add_domain
                read -p "按回车键返回..."
                break
                ;;
            3)
                delete_domain
                read -p "按回车键返回..."
                break
                ;;
            4)
                break
                ;;
            *) echo "无效选项 $REPLY";;
        esac
    done
}


# 6. 更新 cloudflared
update_cloudflared() {
    echo "----------------------------------------"
    echo "6. 更新 cloudflared"
    echo "----------------------------------------"
    
    # 检测系统架构
    ARCH=$(uname -m)
    echo "检测到系统架构: $ARCH"
    
    # 获取当前版本
    CURRENT_VERSION=$(cloudflared version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "未知")
    echo "当前版本: $CURRENT_VERSION"
    
    # 获取最新版本信息
    echo "正在检查最新版本..."
    LATEST_RELEASE=$(curl -s https://api.github.com/repos/cloudflare/cloudflared/releases/latest)
    
    if [ -z "$LATEST_RELEASE" ]; then
        echo "错误: 无法获取最新版本信息。请检查网络连接。"
        read -p "按回车键返回菜单..."
        return
    fi
    
    LATEST_VERSION=$(echo "$LATEST_RELEASE" | grep -oP '"tag_name":\s*"\K[^"]+' || echo "")
    echo "最新版本: $LATEST_VERSION"
    
    # 检查架构支持
    case "$ARCH" in
        armv7l|armv7*)
            ASSET_NAME="cloudflared-linux-arm"
            echo "将下载 ARM 32-bit 版本"
            ;;
        aarch64|arm64)
            ASSET_NAME="cloudflared-linux-arm64"
            echo "将下载 ARM 64-bit 版本"
            ;;
        x86_64|amd64)
            ASSET_NAME="cloudflared-linux-amd64"
            echo "将下载 x86_64 版本"
            ;;
        i386|i686)
            ASSET_NAME="cloudflared-linux-386"
            echo "将下载 x86 32-bit 版本"
            ;;
        *)
            echo "错误: 不支持的架构 '$ARCH'"
            echo "请访问 https://github.com/cloudflare/cloudflared/releases 手动下载"
            read -p "按回车键返回菜单..."
            return
            ;;
    esac
    
    # 检查该版本是否有对应架构的包
    ASSET_URL=$(echo "$LATEST_RELEASE" | grep -oP "\"browser_download_url\":\s*\"[^\"]*${ASSET_NAME}\"" | grep -oP 'https://[^"]+' || echo "")
    
    if [ -z "$ASSET_URL" ]; then
        echo "警告: 最新版本 $LATEST_VERSION 没有 $ASSET_NAME 的发布包"
        echo "您的架构可能不再被支持,或者发布包命名已更改"
        read -p "是否查看所有可用的发布包? (y/N): " VIEW_ASSETS
        if [[ "$VIEW_ASSETS" =~ ^[yY]$ ]]; then
            echo "可用的包:"
            echo "$LATEST_RELEASE" | grep -oP '"name":\s*"cloudflared-[^"]+"' | sed 's/"name": "/  - /'
        fi
        read -p "按回车键返回菜单..."
        return
    fi
    
    echo "下载地址: $ASSET_URL"
    
    # 确认更新
    if [ "$CURRENT_VERSION" != "未知" ] && [ "$CURRENT_VERSION" = "${LATEST_VERSION#v}" ]; then
        echo "您已经是最新版本了!"
        read -p "按回车键返回菜单..."
        return
    fi
    
    read -p "是否继续更新? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[yY]$ ]]; then
        echo "更新已取消"
        read -p "按回车键返回菜单..."
        return
    fi
    
    # 停止服务
    echo "正在停止 cloudflared 服务..."
    systemctl stop cloudflared 2>/dev/null
    
    # 备份当前版本
    if [ -f "/usr/bin/cloudflared" ]; then
        echo "备份当前版本到 /usr/bin/cloudflared.backup"
        cp /usr/bin/cloudflared /usr/bin/cloudflared.backup
    fi
    
    # 下载新版本
    echo "正在下载 $LATEST_VERSION ..."
    wget -O /tmp/cloudflared.new "$ASSET_URL"
    
    if [ $? -ne 0 ]; then
        echo "错误: 下载失败"
        echo "正在恢复服务..."
        systemctl start cloudflared 2>/dev/null
        read -p "按回车键返回菜单..."
        return
    fi
    
    # 安装新版本
    echo "正在安装新版本..."
    chmod +x /tmp/cloudflared.new
    mv /tmp/cloudflared.new /usr/bin/cloudflared
    
    # 验证安装
    NEW_VERSION=$(/usr/bin/cloudflared version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "未知")
    echo "安装后的版本: $NEW_VERSION"
    
    # 重启服务
    echo "正在重启 cloudflared 服务..."
    systemctl start cloudflared
    
    echo "更新完成!"
    systemctl status cloudflared --no-pager
    
    read -p "按回车键返回菜单..."
}

# --- 主程序 ---

# 启动时检查
check_cloudflared

# 主菜单
show_menu() {
    clear
    echo "========================================"
    echo "    Cloudflared 隧道管理脚本 (V4)"
    echo "    (安全版 - 仅管理本机)"
    echo "========================================"
    echo "1. 登录 Cloudflare (首次使用或更换账户时)"
    echo "2. 安装/配置【新】隧道 (本机初始设置)"
    echo "3. 列出您 Cloudflare 账户上的【所有】隧道"
    echo "4. 管理本机服务 (启动/停止/状态)"
    echo "5. 管理本机的【域名】(添加/删除/查看)"
    echo "6. 更新 cloudflared"
    echo "7. 退出"
    echo "----------------------------------------"
}

# 主循环
while true; do
    show_menu
    read -p "请输入您的选择 [1-7]: " choice
    
    case $choice in
        1)
            login
            ;;
        2)
            create_tunnel
            ;;
        3)
            list_all_tunnels
            ;;
        4)
            manage_service
            ;;
        5)
            manage_local_domains # 核心功能
            ;;
        6)
            update_cloudflared # 更新功能
            ;;
        7)
            echo "退出脚本。"
            exit 0
            ;;
        *)
            echo "无效输入，请输入 1 到 7 之间的数字。"
            read -p "按回车键继续..."
            ;;
    esac
done