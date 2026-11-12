import Foundation

/// A bounded rendezvous with the browser's native-messaging host. This never executes scripts.
@MainActor public final class BrowserBroker {
    private struct Pending {
        let id: String, host: String, command: JSONValue, deadline: Date
        let active: @MainActor () -> Bool
        let continuation: CheckedContinuation<JSONValue, Error>
        var delivered = false
    }
    private let now: () -> Date
    private let timeout: TimeInterval
    private let startupURL: URL?
    private var hosts: [String: Date] = [:]
    private var pending: Pending?
    private var watchdog: Task<Void, Never>?

    public init(now: @escaping () -> Date = { Date() }, timeout: TimeInterval = 15, startupURL: URL? = nil) {
        self.now = now
        self.timeout = timeout
        self.startupURL = startupURL
    }

    public func execute(_ command: JSONValue, active: @escaping @MainActor () -> Bool) async throws -> JSONValue {
        try Self.validate(command)
        sweep()
        guard active() else { throw ComputerUseError.message("browser_control_ended") }
        guard hosts.count == 1, let host = hosts.keys.first else {
            let code = hosts.isEmpty ? "browser_extension_unavailable" : "browser_profile_ambiguous"
            if hosts.isEmpty, let startup = startupHint() {
                var details = ComputerUseService.errorDetails(ComputerUseError.message(code))
                details["startup"] = startup
                throw ComputerUseError.detailed(code, details)
            }
            throw ComputerUseError.message(code)
        }
        guard pending == nil else { throw ComputerUseError.message("computer_busy") }
        return try await withCheckedThrowingContinuation { continuation in
            pending = Pending(id: UUID().uuidString.lowercased(), host: host, command: command,
                deadline: now().addingTimeInterval(timeout), active: active, continuation: continuation)
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, self.pending != nil else { return }
                    self.sweep()
                }
            }
        }
    }

    public func exchange(_ value: JSONValue) throws -> JSONValue {
        guard case .object(let args) = value, Set(args.keys).isSubset(of: ["instance_id", "response"]),
            let host = value["instance_id"].string, UUID(uuidString: host) != nil else { throw ComputerUseError.message("invalid_browser_exchange") }
        guard try value.data().count <= 245760 else { throw ComputerUseError.message("browser_response_too_large") }
        let response = value["response"]
        if response != .null {
            guard case .object(let fields) = response, Set(fields.keys).isSubset(of: ["id", "result", "error"]),
                let responseID = response["id"].string, UUID(uuidString: responseID) != nil,
                fields.keys.contains("result") != fields.keys.contains("error") else {
                throw ComputerUseError.message("invalid_browser_response")
            }
        }
        hosts[host] = now()
        sweep()
        if let request = pending, request.host == host, request.delivered, response["id"].string == request.id {
            if response.object.keys.contains("error") {
                let error = response["error"]
                let message = String((error.string ?? error["message"].string ?? "browser_command_failed").prefix(512))
                finish(.failure(Self.failure(message, command: request.command, delivered: true)))
            } else {
                finish(.success(response["result"]))
            }
        }
        guard var request = pending, request.host == host, !request.delivered else {
            return .object(["command": .null])
        }
        // Recheck at delivery: user exit, expiry and a second profile all invalidate queued work.
        sweep()
        guard pending?.id == request.id else { return .object(["command": .null]) }
        request.delivered = true
        pending = request
        return .object(["command": .object([
            "id": .string(request.id), "deadline_ms": .number(request.deadline.timeIntervalSince1970 * 1000),
            "command": request.command
        ])])
    }

    public func stop() {
        hosts = [:]
        fail("browser_server_stopped")
    }

    private func startupHint() -> JSONValue? {
        guard let startupURL else { return nil }
        do {
            guard try startupURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            let file = try FileHandle(forReadingFrom: startupURL)
            defer { try? file.close() }
            let data = try file.read(upToCount: 4097) ?? Data()
            guard data.count <= 4096,
                let raw = try JSONDecoder().decode(JSONValue.self, from: data)["preferred_shortcut_name"].string,
                raw.unicodeScalars.count <= 256,
                !raw.unicodeScalars.contains(where: {
                    switch $0.properties.generalCategory {
                    case .control, .format, .lineSeparator, .paragraphSeparator: return true
                    default: return false
                    }
                }) else { return nil }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return .object(["preferred_shortcut_name": .string(name)])
        } catch { return nil }
    }

    private func sweep() {
        hosts = hosts.filter { now().timeIntervalSince($0.value) < 5 }
        guard let request = pending else { return }
        if !request.active() { fail("browser_control_ended") }
        else if request.deadline <= now() { fail("browser_timeout_execution_unknown") }
        else if hosts.count > 1 { fail("browser_profile_ambiguous") }
        else if hosts[request.host] == nil { fail("browser_host_disconnected") }
    }

    private func fail(_ code: String) {
        guard let request = pending else { return }
        finish(.failure(Self.failure(code, command: request.command, delivered: request.delivered)))
    }

    static func isReadOnly(_ command: JSONValue) -> Bool {
        ["tabs", "observe"].contains(command["action"].string ?? "")
    }

    static func isTimeout(_ message: String) -> Bool {
        ["browser_read_timeout", "browser_timeout_execution_unknown", "remote_timeout_execution_unknown",
            "browser_command_expired", "deadline_exceeded"].contains(message.components(separatedBy: ":")[0].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func failure(_ message: String, command: JSONValue, delivered: Bool) -> ComputerUseError {
        let readOnly = isReadOnly(command)
        let code = readOnly && isTimeout(message) ? "browser_read_timeout"
            : message.components(separatedBy: ":")[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let domCommand = ["observe", "click", "fill", "select", "check", "press"].contains(command["action"].string ?? "")
        // These exact DOM errors precede all setters, focus changes and event dispatches.
        let elementRejected = domCommand && [
            "stale_element", "one_exact_locator_required", "ambiguous_element", "locator_scan_truncated", "element_not_found",
            "disabled_element", "hidden_element", "explicit_tab_id_required", "wrong_tab", "max_nodes_must_be_1_to_500",
            "unsupported_action", "readonly_element", "element_not_fillable", "invalid_text", "single_select_required",
            "value_required", "option_scan_truncated", "ambiguous_option", "option_not_found", "disabled_option",
            "native_checkable_required", "radio_cannot_be_unchecked", "element_not_clickable", "unsupported_key", "element_not_focusable"
        ].contains(code)
        // Navigation may already have been sent; only DOM commands have these preflight guarantees.
        let pageLoading = domCommand && code == "browser_page_loading"
        let pageError = domCommand && code == "browser_page_error"
        let retryable = readOnly && (["browser_read_timeout", "browser_host_disconnected"].contains(code) || pageLoading)
        let unavailableTab = ["browser_tab_frozen", "browser_tab_discarded"].contains(code)
        return .detailed(code, .object([
            "code": .string(code), "message": .string(message), "read_only": .bool(readOnly),
            "input_outcome": .string(readOnly || !delivered || unavailableTab || elementRejected || pageLoading || pageError ? "not_attempted" : "unknown"),
            "retryable": .bool(retryable), "max_retries": .number(retryable ? 1 : 0),
            "next_step": .string(elementRejected ? "observe_and_choose_fresh_element"
                : pageLoading ? "observe_loading_page_with_bounded_retry" : pageError ? "report_browser_page_unavailable"
                : unavailableTab ? "inspect_tab_state_before_new_request"
                : retryable ? "retry_read_once_then_report_unavailable"
                : readOnly ? "report_browser_unavailable_without_retry" : "observe_before_new_request")
        ]))
    }

    private func finish(_ result: Result<JSONValue, Error>) {
        let request = pending
        pending = nil
        watchdog?.cancel()
        watchdog = nil
        request?.continuation.resume(with: result)
    }

    public static func validate(_ command: JSONValue) throws {
        guard case .object(let fields) = command, try command.data().count <= 65536,
            let action = command["action"].string,
            ["tabs", "navigate", "observe", "click", "fill", "select", "check", "press"].contains(action) else {
            throw ComputerUseError.message("invalid_browser_command")
        }
        let allowed: Set<String> = ["action", "tab_id", "url", "element_id", "text", "value", "checked", "key", "max_nodes", "role", "name"]
        guard Set(fields.keys).isSubset(of: allowed) else { throw ComputerUseError.message("invalid_browser_command_field") }
        if action != "tabs" || fields["tab_id"] != nil {
            _ = try ComputerUseService.integer(command, "tab_id", default: -1, range: 1...Int(Int32.max))
        }
        for (key, limit) in [("url", 8192), ("element_id", 512), ("text", 32768), ("value", 8192), ("key", 40), ("role", 80), ("name", 1024)] {
            if let value = fields[key] {
                guard let text = value.string, text.utf8.count <= limit else { throw ComputerUseError.message("invalid_browser_" + key) }
            }
        }
        if action == "navigate" {
            let url = try command.required("url")
            guard url == "about:blank" || URL(string: url).map({ ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil }) == true else {
                throw ComputerUseError.message("invalid_browser_url")
            }
        }
        if ["click", "fill", "select", "check", "press"].contains(action), command["element_id"].string?.isEmpty != false {
            _ = try command.required("role")
            _ = try command.required("name")
        }
        if action == "fill", command["text"].string == nil { throw ComputerUseError.message("missing_text") }
        if action == "select", command["value"].string == nil { throw ComputerUseError.message("missing_value") }
        if action == "press" { _ = try command.required("key") }
        if fields["checked"] != nil || action == "check" {
            guard command["checked"] == .bool(true) || command["checked"] == .bool(false) else { throw ComputerUseError.message("invalid_browser_checked") }
        }
        if fields["max_nodes"] != nil { _ = try ComputerUseService.integer(command, "max_nodes", default: 200, range: 1...500) }
    }
}
