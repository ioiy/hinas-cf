Cloudflared Tunnel Manager (CN) ☁️

这是一个专为 Linux 系统设计的高级 Bash 脚本，旨在简化 Cloudflare Tunnel (原 Argo Tunnel) 的部署、管理和维护工作。

它专注于本机服务的管理，通过交互式的菜单界面，让您无需手动编辑复杂的 YAML 配置文件，即可轻松实现内网穿透。

项目地址：https://github.com/ioiy/hinas-cf

✨ 核心特性

🛡️ 安全优先：

在修改关键配置前自动创建带时间戳的备份。

严格的 Root 权限检查，防止权限错误。

移除了危险的云端隧道删除功能，仅管理本地路由。

🚀 智能安装：

自动检测系统架构（AMD64, ARM64, ARMv7 等）。

自动从 GitHub 获取最新版本的 cloudflared 二进制文件。

内置 GitHub 加速代理支持（可配置）。

🎨 交互式体验：

全中文界面，彩色状态输出。

智能补全：输入 8080 自动识别为 http://127.0.0.1:8080。

一键管理 Systemd 服务（启动、停止、自启）。

⚡ 便捷管理：

热添加域名：无需手动改文件，脚本自动插入配置并注册 DNS。

热删除域名：自动清理配置文件中的过时路由。

🛠️ 安装与使用

1. 下载脚本

您可以在服务器上直接创建文件，或者使用 wget / curl 直接下载。

# 下载脚本
wget -O cf.sh [https://raw.githubusercontent.com/ioiy/hinas-cf/main/cf.sh](https://raw.githubusercontent.com/ioiy/hinas-cf/main/cf.sh)

# 或者如果无法连接 raw.githubusercontent.com，可以使用加速镜像
# wget -O cf.sh [https://ghproxy.com/https://raw.githubusercontent.com/ioiy/hinas-cf/main/cf.sh](https://ghproxy.com/https://raw.githubusercontent.com/ioiy/hinas-cf/main/cf.sh)


2. 赋予执行权限

chmod +x cf.sh


3. 运行脚本

脚本需要 Root 权限才能管理 /etc/cloudflared 目录和系统服务。

sudo ./cf.sh


📖 功能详解

1. 安装 / 更新 Cloudflared

脚本会自动判断您的 CPU 架构。

从 Cloudflare 官方 GitHub 仓库下载最新的二进制文件到 /usr/bin/cloudflared。

如果已安装，此选项可用于强制更新到最新版。

2. 登录 Cloudflare 账户

用于首次配置。脚本会提供一个 URL。

复制 URL 到浏览器登录并授权域名。

授权后，证书文件 cert.pem 会自动下载到本地。

3. 创建新隧道 (向导)

适用场景：在一台新机器上首次部署。

流程：

输入隧道名称（如 nas）。

输入第一个要穿透的域名（如 nas.example.com）。

输入本地端口（如 8080）。

脚本自动生成 UUID、创建配置文件、注册 DNS 并启动服务。

4. 管理域名 (核心功能)

这是日常使用最频繁的功能。

查看列表：显示当前 config.yml 中配置的所有域名和对应的本地服务。

添加新域名：

输入新子域名（如 plex.example.com）。

输入本地端口（如 32400）。

脚本会自动修改 config.yml，保留原有的 404 兜底规则，并通知 Cloudflare 添加 CNAME 记录。

删除域名：

输入要删除的域名。

脚本从配置文件中移除对应规则并重启服务。

5. 服务管理

查看 systemd 运行状态。

一键启动、停止、重启隧道服务。

设置开机自启。

📂 文件结构说明

配置文件：/etc/cloudflared/config.yml

隧道的路由规则都在这里。脚本操作的就是这个文件。

凭证目录：/root/.cloudflared/

存放登录证书 (cert.pem) 和隧道凭证 JSON 文件。

程序路径：/usr/bin/cloudflared

⚠️ 常见问题 (FAQ)

Q: 运行脚本报错 Permission denied？
A: 请使用 sudo ./cf.sh 或以 root 用户登录运行。

Q: 添加域名后无法访问？
A:

检查本地服务端口是否开启。

检查脚本是否提示 "DNS记录添加成功"。

尝试在菜单中选择 "5. 服务管理" -> "3. 重启服务"。

Q: 脚本修改配置文件会搞乱我的注释吗？
A: 脚本使用 sed 进行精准插入和删除。虽然尽量保持格式，但大量的手动注释可能会在自动化操作中移位。每次修改前，脚本都会在同目录下生成 .bak 备份文件，如果出问题可以随时还原。

Q: 如何手动查看详细日志？
A: 使用命令 journalctl -u cloudflared -f。

📝 依赖检查

脚本依赖以下标准 Linux 工具，大多数发行版已预装：

wget / curl (用于下载)

grep, sed, awk (用于文本处理)

systemctl (用于服务管理)

python3 (可选，用于更精准的配置文件显示，无 Python 也能运行)

根据大佬的教程 https://bbs.histb.com/d/240-cloudflared-https 结合ai写出的
