import SwiftUI

struct SettingsPanel: View {
    @ObservedObject var model: PairingViewModel
    @ObservedObject var preferences: LocalPreferences
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("外观") {
                HStack {
                    Label("界面主题", systemImage: "circle.lefthalf.filled");
                    Spacer();
                    SMThemePicker().frame(width: 180)
                }.padding(10)
            }
            GroupBox("权限向导") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ShareMouse 会逐项向系统申请权限，由你确认是否允许。未授权的功能保持关闭，其它模块继续运行。").font(.callout)
                    Text(model.permissionStatus).font(.callout)
                    HStack {
                        Button("1 · 申请辅助功能") { model.requestAccessibility() };
                        Text("向目标应用发送键鼠输入").font(.caption)
                    }
                    HStack {
                        Button("2 · 申请输入监控") { model.requestInputMonitoring() };
                        Text("捕获本机键鼠并路由到当前屏幕").font(.caption)
                    }
                    HStack {
                        Button("3 · 申请蓝牙并开始发现") { model.startBluetooth() };
                        Text("发现附近设备及蓝牙传输，可选").font(.caption)
                    }
                    Button("停止蓝牙发现和连接") { model.stopBluetooth() }
                    HStack {
                        Button("4 · 申请 Finder 自动化") { model.requestFinderPermission() };
                        Text("读取所选文件和粘贴目录，可选 · " + model.finderPermissionStatus).font(.caption)
                    }
                    Text("本地网络在首次发现设备时由系统询问，用于局域网加密连接；系统原生通知在选择该通知方式时申请。上述用途已写入应用声明。").font(.caption).foregroundStyle(
                        .secondary)
                    HStack {
                        Button("刷新状态") { model.refreshPermissions() };
                        Button("完成权限设置") { model.finishPermissionSetup() }
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("MCP / 远程 Computer Use") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("启用本机 MCP 接口", isOn: $preferences.mcpEnabled).onChange(of: preferences.mcpEnabled) { _, _ in
                        model.configureMCP()
                    }
                    Toggle("允许 AI / 已配对设备截图并操控本机", isOn: $preferences.allowComputerUse).onChange(
                        of: preferences.allowComputerUse
                    ) { _, _ in model.configureMCP() }
                    Toggle("允许 MCP 复制文件与管理传输任务", isOn: $preferences.allowMcpFiles).onChange(
                        of: preferences.allowMcpFiles
                    ) { _, _ in model.configureMCP() }
                    Picker("AI 鼠标控制方式", selection: $preferences.computerControlMode) {
                        Text("创建独立鼠标").tag("independent");
                        Text("使用用户鼠标").tag("user_mouse")
                    }.onChange(of: preferences.computerControlMode) { _, _ in model.configureMCP() }
                    Text("独立鼠标绑定应用窗口，后台输入不支持时会明确报错；agent 可为每次接管选择方式。接管期间仅暂停本机键鼠共享，文件和剪贴板保持连接。").font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("显示鼠标移动与点击反馈", isOn: $preferences.computerCursorHints).onChange(
                        of: preferences.computerCursorHints
                    ) { _, _ in model.configureMCP() }
                    Text("两种模式均显示平滑移动与点击反馈。点击之间使用柔和曲线；连续移动与拖拽保持指定路径。").font(.caption).foregroundStyle(.secondary)
                    Text("截图会返回给接入的 AI 客户端。操作当前桌面；误动键鼠不会结束接管，点击“退出接管”恢复本机控制。文件发送更新共享文件剪贴板，源文件保留。").font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("申请屏幕录制权限") { model.requestScreenCapture() };
                        Button("复制 MCP 接入配置") { model.copyMCPConfiguration() }
                    }
                    HStack {
                        Text(model.mcpControlling ? "MCP 正在接管本机" : "MCP 未接管本机").font(.caption);
                        Button("退出接管") { model.exitMCPControl() }.disabled(!model.mcpControlling)
                    }
                    Text(model.mcpStatus).font(.caption)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("本机设置") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("通知", selection: $preferences.renderer) {
                        Text("自定义圆角提示").tag("custom");
                        Text("系统原生通知").tag("native")
                    }.onChange(of: preferences.renderer) { _, _ in model.configureNotifications() }
                    Picker("自定义提示位置", selection: $preferences.corner) {
                        Text("右下角").tag("bottomRight");
                        Text("左下角").tag("bottomLeft");
                        Text("右上角").tag("topRight");
                        Text("左上角").tag("topLeft")
                    }.onChange(of: preferences.corner) { _, _ in model.configureNotifications() }
                    Toggle("日志", isOn: $preferences.logEnabled).onChange(of: preferences.logEnabled) { _, _ in
                        preferences.save()
                    }
                    Text("关闭后停止记录日志，已有日志保留。").font(.caption).foregroundStyle(.secondary)
                    Picker("日志等级", selection: $preferences.logLevel) {
                        ForEach(["INFO", "WARN", "ERROR", "DEBUG", "TRACE"], id: \.self) { Text($0).tag($0) }
                    }.disabled(!preferences.logEnabled).onChange(of: preferences.logLevel) { _, _ in preferences.save()
                    }
                    Toggle(
                        "登录后启动 ShareMouse",
                        isOn: Binding(get: { preferences.startup }, set: { preferences.setStartup($0) }))
                    Button("历史容量与快捷键…") { model.manageHistory() }
                    Button("测试通知") { model.testNotification() }
                    Text(preferences.status).font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("关闭主窗口后，菜单栏服务继续运行。退出 ShareMouse 才停止共享并释放按键。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
