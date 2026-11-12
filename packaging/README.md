# ShareMouse v0.1.0

内部构建 44，MCP 1.5.4。支持 macOS 14+ universal 和 Windows 11 x64。实际硬件与长期使用仍需验证。

- `ShareMouse-v0.1.0-macos-universal.dmg`：ad-hoc 签名，未公证。
- `ShareMouse-v0.1.0-windows-x64-setup.exe`：自包含 .NET 运行时，无 Authenticode 签名。
- MCP Edge 扩展及宿主参见源码 `mcp/` 及其 README；须单独配置。
- 本机签名脚本与说明供 macOS 用户使用自己的开发证书；签名不代替系统权限授权。

重建：`zsh scripts/release-macos.zsh v0.1.0 44`；Windows 使用 `powershell -NoProfile -File scripts/release-windows.ps1 -ReleaseVersion v0.1.0 -BuildNumber 44 -ISCC <ISCC.exe路径>`。Windows 使用 self-contained win-x64。升级前退出旧实例；安装保留用户身份和设置。
