# macOS 本机签名安装

此流程供使用者在自己的 Mac 上给已下载的 ShareMouse DMG 重新签名并安装，适用于本机测试和本机 TCC 权限身份固定。脚本不收集 Apple Account 密码，也不会自动授予辅助功能、输入监控或绕过 Gatekeeper。

## 准备签名身份

1. 安装 Xcode，并在 Xcode 的 **Settings > Accounts** 中登录 Apple Account。
2. 选择自己的 Team，打开 **Manage Certificates**，创建 **Apple Development** 证书。Apple Account 登录与双重认证由 Xcode 自己处理；不要把 Apple Account 密码交给脚本。
3. 确认证书及其私钥已在本机钥匙串中。`codesign` 可能会弹出钥匙串访问确认；这是本机私钥授权，与 Apple Account 密码不是一回事。

Apple Development 身份用于开发测试。直接向其他用户分发 macOS 应用，应使用 Developer ID Application 证书并进行 Apple 公证；Apple Development 签名不能替代这套正式分发流程。

## 运行脚本

从 GitHub 仓库下载 `packaging/sign-install-macos.zsh`，然后在终端运行：

```sh
zsh ./sign-install-macos.zsh "$HOME/Downloads/ShareMouse-macos-universal.dmg"
```

如果脚本与 `ShareMouse.app` 一起放在已挂载的 DMG 根目录中，也可以直接运行脚本，不传 DMG 路径。

脚本会检查 `com.sharemouse.desktop` Bundle ID，使用钥匙串中的 Apple Development 私钥签名，验证签名后安装到 `~/Applications/ShareMouse.app`。若该用户目录原来已有 ShareMouse，脚本会先把旧副本移到 `~/Library/Application Support/ShareMouse/backups/`。不需要 `sudo`，也不会覆盖 `/Applications/ShareMouse.app`。

第一次运行时，macOS 可能仍显示 Gatekeeper 警告，因为 Apple Development 签名不是 Developer ID 公证签名。脚本不会移除 `com.apple.quarantine`；请只在确认 DMG 来源可信时，通过系统提供的 **Privacy & Security** 流程审阅并决定是否打开。

## 首次授权与后续更新

签名改变了应用代码身份，因此请在 **System Settings > Privacy & Security** 中检查这个安装副本的 **Accessibility** 和 **Input Monitoring** 授权。辅助功能允许应用控制 Mac；输入监控允许应用读取键盘、鼠标或触控板活动。用户需自行确认并开启。

后续版本要继续匹配本机授权，应使用同一个 Apple Development Team/证书并保持 Bundle ID 不变。每位使用者用自己的证书签名后，得到的是各自的代码身份；权限也必须在各自的 Mac 上授权。

Apple 文档：

- [Apple Development 与其他证书类型](https://developer.apple.com/help/account/create-certificates/certificates-overview)
- [Developer ID 证书](https://developer.apple.com/help/glossary/developer-id-certificate/)
- [macOS 软件公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
