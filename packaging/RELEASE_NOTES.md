# ShareMouse v0.1.0

内部构建 44，MCP 1.5.4。

## 更新

- MCP 支持枚举并绑定指定窗口，通过原生无障碍控件操作；Windows 独立模式提供控件树。
- 新增可选 Edge 扩展与 Native Messaging 宿主，支持在指定标签页读取和操作网页控件。需按 MCP 文档单独配置 Python、宿主和扩展。
- 改进页面加载、冻结标签、控件引用、超时与会话恢复的处理。网页事件为合成事件，跨源框架、浏览器界面及画布不支持。

## 使用与验证边界

- macOS 14+ universal DMG 为 ad-hoc 签名，未公证；Windows 11 x64 安装器无 Authenticode 签名。请核对 SHA256，权限需自行授权。
- MCP 自动化测试及两端真实浏览器控件操作曾通过；自动化不能代替实体键鼠、所有网页及长期使用验收。
- Windows 的 TrustedInstaller 重启是可选功能，需要 PowerShell 7 和自行配置的 TrustInstaller-Start。普通启动仍为管理员用户。
- 升级前退出旧实例；安装保留本机身份和设置。
