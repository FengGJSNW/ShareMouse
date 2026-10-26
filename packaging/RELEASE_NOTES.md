# ShareMouse v0.1.0-alpha.3

内部构建 37；MCP／协议版本仍为 1.3.1。

## 更新

- 修复 Mac 紧急释放快捷键被转发到 Windows 的问题，兼容 Fn／Command 系统交换。
- 文本 Command+X 恢复应用原生行为；Finder 文件 Cut 与文本输入分流，避免误拦截剪切和粘贴。
- 双端新增“合盖释放键鼠”“锁屏释放键鼠”开关；解除条件后被动恢复，保留手动暂停，不抢当前光标。
- 更新 Mac 应用／菜单栏和 Windows EXE／托盘／安装器图标。
- TCP 文件进度改用轻量检查点，背景写入增加超时，保留断点恢复、文件校验及 Cut 删除保护。
- Windows 显示当前权限，补充可选的本次 TrustedInstaller 重启和原用户身份保持；修复此模式的鼠标主题问题。

## 验证范围

- Mac arm64＋x86_64 通用 DMG，Windows x64 自包含安装器构建通过。
- Swift 本轮执行97项：96通过、1项条件跳过；另2项已知网络基线 fixture 未纳入本轮。
- Windows 全解决方案构建无警告／错误；功能行、键鼠释放恢复、文件断点／完整性及10秒阻塞写入专项通过。MCP Python 14项通过。
- 构建与自动化回归不代替实体输入、合盖硬件、校园网吞吐及长期流畅度验收。

## 安装说明

- macOS 14+：下载 universal DMG；公开包为 ad-hoc 签名，未公证。可下载随附签名脚本和说明，以自己的开发证书进行本机签名；权限需用户自行授权。
- Windows 11 x64：下载 setup.exe，包含 .NET 运行时，启动仍申请管理员授权；安装器未做 Authenticode 签名。
- TrustedInstaller 是可选功能，依赖 PowerShell 7 及自行配置的 TrustInstaller-Start 命令；普通共享不依赖该命令，默认不以 TrustedInstaller 启动。
- 升级前退出旧实例；安装器保留原用户身份和设置。文件校验值见 SHA256SUMS.txt。
