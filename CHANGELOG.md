Changelog

All notable changes to this project will be documented in this file.

[V5.0] - 2024-05-20

Fixed

修复备份管理器无法识别 /root 目录下 .tar.gz 压缩包的问题。

优化文件路径检测逻辑。

[V4.9] - 2024-05-18

Changed

恢复自动更新源 SCRIPT_URL。

引入语法安全检查盾 (Syntax Safety Shield)，防止远程损坏代码覆盖本地文件。

[V4.8] - 2024-05-15

Security

紧急禁用自动更新功能，以应对上游仓库代码损坏的安全风险。

[V4.7] - 2024-05-12

Added

新增交互式备份文件管理器。

支持按序号删除指定备份。

支持保留最新 5 份备份的自动清理策略。

[V4.6] - 2024-05-10

Added

新增 Crontab 定时任务管理（自动重启/保活）。

新增网络延迟检测功能 (Ping 测试)。

[V4.5] - 2024-05-08

Changed

将资源监控面板移至主菜单顶部常驻显示。

优化对 Busybox 等精简系统的 ps 命令兼容性。

[V4.4] - 2024-05-05

Added

新增 Token 模式安装支持 (适配 Cloudflare Zero Trust Dashboard)。

新增配置文件一键备份与清理功能。

[V4.0] - 2024-05-01

Initial Release

首次发布，包含基本的安装、配置、域名管理功能。

支持自动架构检测 (AMD64/ARM64/ARMv7)。
