Cloudflared Tunnel Manager (V4.6) ☁️

这是一个专为 Linux 设计的 Cloudflare Tunnel 一站式管理脚本。无论是传统的本地配置文件模式，还是网页端的 Token 模式，都能轻松驾驭。

特点：全中文界面、自动架构检测、安全备份、资源监控。

🚀 快速开始

# 下载脚本
wget -O cf.sh [https://raw.githubusercontent.com/ioiy/hinas-cf/main/cf.sh](https://raw.githubusercontent.com/ioiy/hinas-cf/main/cf.sh)

# 赋予权限并运行 (需要 Root)
chmod +x cf.sh
sudo ./cf.sh


✨ 核心功能

自动安装/更新：智能识别 CPU 架构 (AMD64/ARM64/ARMv7)，自动下载最新版 Cloudflared。

双模式支持：

本地配置模式：自动生成 config.yml，通过菜单一键添加/删除域名路由，自动注册 DNS。

Token 模式：支持输入 Cloudflare 网页端生成的 Token 进行快速部署。

运维工具箱：

实时日志：查看隧道运行日志。

资源监控：顶部常驻显示 CPU、内存占用及运行时间。

协议切换：一键切换 QUIC/HTTP2 协议，解决网络阻断问题。

配置备份：自动备份配置文件，支持一键清理冗余备份。

网络检测：一键测试到 Cloudflare 节点的延迟。

自动保活：支持设置 Crontab 定时任务，每天凌晨自动重启服务，保持连接稳定。

安全可靠：修改配置前自动备份，添加域名时自动检测本地端口连通性。更新脚本时增加语法自检，防止下载损坏文件。

📋 菜单概览

选项

功能描述

1

安装 / 更新 (含版本检测与对比)

2

登录账户 (获取证书)

3

创建新隧道 (本机向导，生成 UUID)

4

管理域名 (最常用：添加/删除本地服务的公网映射)

5

服务管理 (启动/停止/重启/自启 + 资源监控)

6

列出云端隧道

7

更新脚本 (自我更新，含语法校验盾)

8

高级工具箱 (日志/备份/协议切换/清理备份/网络测试)

9

彻底卸载 (清理所有残留)

10

Token 模式安装 (使用网页端 Token 部署)

11

定时任务 (设置自动重启策略)

⚠️ 注意事项

必须以 root 用户或使用 sudo 运行。

Token 模式与本地配置模式互斥，安装 Token 模式会覆盖原有的本地服务。



根据大佬的教程 https://bbs.histb.com/d/240-cloudflared-https 结合ai写出的
