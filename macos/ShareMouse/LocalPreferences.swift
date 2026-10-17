import AppKit
import ServiceManagement
import SwiftUI

@MainActor final class LocalPreferences: ObservableObject {
    private struct Saved: Codable {
        var renderer: String;
        var corner: String;
        var logLevel: String;
        var onboardingComplete: Bool;
        var networkAvailable: Bool?;
        var bluetoothAvailable: Bool?;
        var mcpEnabled: Bool?;
        var allowComputerUse: Bool?;
        var allowMcpFiles: Bool?;
        var computerCursorHints: Bool?;
        var bluetoothInputOnly: Bool?;
        var gameMouseMode: String?;
        var computerControlMode: String?;
        var logEnabled: Bool?;
        var pointerSensitivity: [String: Double]?;
        var reverseScrollHorizontal: [String: Bool]?;
        var reverseScrollVertical: [String: Bool]?;
        var horizontalScrollAngle: [String: Double]?;
        var fnEnabled: Bool?;
        var functionKeysEnabled: Bool?;
        var screenCrossingEnabled: Bool?
    }
    private let file: URL
    @Published var renderer = "custom"
    @Published var corner = "bottomRight"
    @Published var logLevel = "INFO"
    @Published var logEnabled = true
    @Published var startup = false
    @Published var status = ""
    @Published var mcpEnabled = false
    @Published var allowComputerUse = false
    @Published var allowMcpFiles = false
    @Published var computerCursorHints = true
    @Published var computerControlMode = "user_mouse"
    var pointerSensitivity: [String: Double] = [:]
    var reverseScrollHorizontal: [String: Bool] = [:]
    var reverseScrollVertical: [String: Bool] = [:]
    var horizontalScrollAngle: [String: Double] = [:]
    var fnEnabled = true
    var functionKeysEnabled = true
    var screenCrossingEnabled = true
    var bluetoothInputOnly = false
    @Published var gameMouseMode = "auto"
    var networkAvailable = true
    var bluetoothAvailable = true
    var onboardingComplete = false
    init(directory: URL) {
        file = directory.appendingPathComponent("local-settings.json")
        if let bytes = try? Data(contentsOf: file) {
            do {
                let saved = try JSONDecoder().decode(Saved.self, from: bytes);
                pointerSensitivity = (saved.pointerSensitivity ?? [:]).filter {
                    $0.value.isFinite && (0.1...4).contains($0.value)
                };
                reverseScrollHorizontal = saved.reverseScrollHorizontal ?? [:];
                reverseScrollVertical = saved.reverseScrollVertical ?? [:];
                horizontalScrollAngle = (saved.horizontalScrollAngle ?? [:]).filter {
                    $0.value.isFinite && (0...90).contains($0.value)
                };
                fnEnabled = saved.fnEnabled ?? true;
                functionKeysEnabled = saved.functionKeysEnabled ?? true;
                screenCrossingEnabled = saved.screenCrossingEnabled ?? true;
                renderer = saved.renderer;
                corner = saved.corner;
                logLevel = saved.logLevel;
                logEnabled = saved.logEnabled ?? true;
                onboardingComplete = saved.onboardingComplete;
                networkAvailable = saved.networkAvailable ?? true;
                bluetoothAvailable = saved.bluetoothAvailable ?? true;
                mcpEnabled = saved.mcpEnabled ?? false;
                allowComputerUse = saved.allowComputerUse ?? false;
                allowMcpFiles = saved.allowMcpFiles ?? false;
                computerCursorHints = saved.computerCursorHints ?? true;
                computerControlMode = saved.computerControlMode == "independent" ? "independent" : "user_mouse";
                bluetoothInputOnly = saved.bluetoothInputOnly ?? false;
                gameMouseMode =
                    ["auto", "on", "off"].contains(saved.gameMouseMode ?? "") ? saved.gameMouseMode! : "auto"
            } catch { status = "设置无法读取，原文件已保留" }
        }
        // Preserve the selected input transport across ordinary and login launches.
        if ProcessInfo.processInfo.arguments.contains("--bluetooth-input") {
            bluetoothInputOnly = true;
            if status.isEmpty { save() }
        }
        startup = SMAppService.mainApp.status == .enabled
    }
    func save() {
        do {
            try JSONEncoder().encode(
                Saved(
                    renderer: renderer, corner: corner, logLevel: logLevel, onboardingComplete: onboardingComplete,
                    networkAvailable: networkAvailable, bluetoothAvailable: bluetoothAvailable, mcpEnabled: mcpEnabled,
                    allowComputerUse: allowComputerUse, allowMcpFiles: allowMcpFiles,
                    computerCursorHints: computerCursorHints, bluetoothInputOnly: bluetoothInputOnly,
                    gameMouseMode: gameMouseMode, computerControlMode: computerControlMode, logEnabled: logEnabled,
                    pointerSensitivity: pointerSensitivity, reverseScrollHorizontal: reverseScrollHorizontal,
                    reverseScrollVertical: reverseScrollVertical, horizontalScrollAngle: horizontalScrollAngle,
                    fnEnabled: fnEnabled, functionKeysEnabled: functionKeysEnabled,
                    screenCrossingEnabled: screenCrossingEnabled)
            ).write(to: file, options: .atomic)
        } catch { status = "无法保存本机设置" }
    }
    func setStartup(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() };
            startup = SMAppService.mainApp.status == .enabled;
            status = startup == enabled ? "登录启动设置已更新" : "请在系统设置的登录项中确认"
        } catch { status = "登录启动未完成；请先将应用放到稳定安装目录，再在系统设置中确认" }
    }
    func accepts(_ level: LogLevel) -> Bool {
        guard logEnabled else { return false };
        let order = ["TRACE", "DEBUG", "INFO", "WARN", "ERROR"];
        return (order.firstIndex(of: level.rawValue) ?? 2) >= (order.firstIndex(of: logLevel) ?? 2)
    }
}
