# ShareMouse v0.1.0-alpha.2

本发行版为 alpha.2，内部构建号 26；Mac 数字版本 0.1.0，Windows 文件版本 0.1.0.26，MCP／协议版本保持 1.3.1。仍处于人工体验验收阶段。

## 产物与系统

输出目录：`artifacts/releases/v0.1.0-alpha.2/`。

- `ShareMouse-v0.1.0-alpha.2-macos-universal.dmg`：macOS 14+，arm64／x86_64 通用。
- `ShareMouse-v0.1.0-alpha.2-windows-x64-setup.exe`：Windows 11 x64，包含 .NET 运行时，保留管理员启动要求。
- `sign-install-macos.zsh` 与 `ShareMouse-macOS-signing-guide.md`：供使用者在自己的 Mac 本机签名。

公开 DMG 无 Apple 公证；没有 Developer ID 时使用 ad-hoc 签名，不将开发者个人 Apple Development 身份当作公开发行身份。Windows 安装包无 Authenticode 签名。使用者本机签名的步骤及限制见 [签名说明](macOS本机签名安装.md)。

## 重建

```sh
zsh scripts/release-macos.zsh v0.1.0-alpha.2 26
```

可显式设置 `SHAREMOUSE_SIGNING_IDENTITY`；未设置时仅自动选择 Developer ID Application，否则 ad-hoc。采用 Release、-O、universal 架构，不含 debug dylib。

```powershell
powershell -NoProfile -File scripts/release-windows.ps1 -ReleaseVersion v0.1.0-alpha.2 -BuildNumber 26 -ISCC '<Inno Setup 7 x64 的 ISCC.exe 路径>'
```

Windows 使用 self-contained win-x64，不裁剪、不做单文件抽取。安装器沿用现有 AppId 和上次安装目录，桌面入口使用系统的实际用户桌面路径；卸载不删除个人身份、设置、历史。只管理本程序 TCP 49160、UDP 49164／49161／5353 规则，不开放本机 MCP 49170。

Windows 11 下限来自系统 TLS 1.3／QUIC 依赖：[Microsoft TLS 支持表](https://learn.microsoft.com/en-us/windows/win32/secauthn/protocols-in-tls-ssl--schannel-ssp-)，[.NET QUIC 依赖](https://learn.microsoft.com/en-us/dotnet/fundamentals/networking/quic/quic-overview)。签名不代替权限授权；安装完成不表示实体键盘功能、Intel 实机或全部体验均已验收。
