# 开发与代码规范

macOS 界面使用 SwiftUI／AppKit，Windows 使用 WPF；共享模型、协议和平台注入分别放在 Core、Network 与平台适配层。键鼠捕获回调不得执行磁盘、剪贴板或窗口枚举等阻塞操作；协议变更须协商能力并保留旧端兼容。不要改变原生输入 FIFO、滚动信用或已验证的后台光标策略。

## 格式化

仓库使用 `.editorconfig` 与 `.swift-format`，UTF-8、LF、四空格缩进。使用 Xcode 附带的 swift-format 及 .NET SDK 自带格式化器，无须加入应用运行依赖。

```sh
xcrun swift-format format --in-place --recursive --configuration .swift-format macos/ShareMouse macos/Sources macos/Tests
xcrun swift-format lint --strict --recursive --configuration .swift-format macos/ShareMouse macos/Sources macos/Tests
```

```powershell
dotnet format whitespace windows/ShareMouse.slnx --no-restore
dotnet format whitespace windows/ShareMouse.slnx --no-restore --verify-no-changes
```

格式改动与功能改动应分开检查。保留用户配置、稳定设备身份及已有人工验收记录。大型旧模块按具体职责逐步拆分，不在发布整理中批量改写输入或网络状态机。

## 验证与发布

```sh
swift test --package-path macos --jobs 2
python3 -m unittest discover -s mcp -p 'test_*.py'
```

```powershell
dotnet build windows/ShareMouse.slnx -c Release --disable-build-servers -m:1
dotnet run --project windows/ShareMouse.Checks -c Release --no-build -- --function-slots
dotnet run --project windows/ShareMouse.SessionProbe -c Release --no-build -- --function-row-regression
```

功能行专项使用采集报告和注入收集器；不会向桌面发送真实按键。构建、注入调用成功和实际硬件功能生效应分别记录。厂商 Fn 报告只对经过确认的硬件描述符启用，不伪造通用 Fn 虚拟键。

安装包由 `scripts/release-macos.zsh` 与 `scripts/release-windows.ps1` 构建，参数与签名限制见 `packaging/README.md`。不要提交运行时身份、密钥、个人设置、日志、构建目录或安装包。

## alpha.2 的已知验证缺口

修正映射测试对输入能力就绪的前提后，排除两项既有网络 fixture，其余 90 项 Swift 回归通过；Windows 功能槽／HID 专项及 Python 客户端 14 项通过。以下两项在本次改动前的 Git 基线上也超时，仍待处理，没有在源码中跳过或标记为通过：

- `SharingTests.testCompactInputBackpressureDragReleaseAndTemporaryRecovery`
- `SharingTests.testNetworkRecoveryWithoutBonjourKeepsBLEAndPinnedIdentity`

实体键盘、固件 FnLock、特定系统功能及实际网络环境仍需人工验收。

Alpha.3 release check (2026-10-26): 96 Swift tests passed and one environment-dependent test skipped; the two baseline network fixtures listed above were excluded. Windows solution, function-slot, availability, file-transfer and blocked TCP-write checks passed; physical acceptance remains separate.
