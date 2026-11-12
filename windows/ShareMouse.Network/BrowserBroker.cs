using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Globalization;

namespace ShareMouse.Network;

/// <summary>A bounded rendezvous with the browser native-messaging host; never executes scripts.</summary>
public sealed class BrowserBroker : IDisposable
{
    // These are UTF-8 IPC budgets, not HTML-escaped JSON character budgets.
    private static readonly JsonSerializerOptions WireJson = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    private sealed class Pending(string id, string host, JsonNode command, DateTime deadline, Func<bool> active)
    {
        public readonly string ID = id, Host = host;
        public readonly JsonNode Command = command;
        public readonly DateTime Deadline = deadline;
        public readonly Func<bool> Active = active;
        public readonly TaskCompletionSource<JsonNode> Result = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool Delivered;
    }
    private readonly SynchronizationContext context;
    private readonly Func<DateTime> now;
    private readonly TimeSpan timeout;
    private readonly string? startupPath;
    private readonly Dictionary<string, DateTime> hosts = new();
    private readonly Timer watchdog;
    private Pending? pending;
    private bool stopped;

    public BrowserBroker(SynchronizationContext context, Func<DateTime>? now = null, TimeSpan? timeout = null, string? startupPath = null)
    {
        this.context = context;
        this.now = now ?? (() => DateTime.UtcNow);
        this.timeout = timeout ?? TimeSpan.FromSeconds(15);
        this.startupPath = startupPath;
        watchdog = new Timer(_ => context.Post(_ => Sweep(), null), null, Timeout.Infinite, Timeout.Infinite);
    }
    private Task<JsonNode> OnContext(Func<Task<JsonNode>> work)
    {
        var result = new TaskCompletionSource<JsonNode>(TaskCreationOptions.RunContinuationsAsynchronously);
        context.Post(async _ => { try { result.TrySetResult(await work()); } catch (Exception e) { result.TrySetException(e); } }, null);
        return result.Task;
    }
    public Task<JsonNode> Execute(JsonNode command, Func<bool> active) => OnContext(() =>
    {
        Validate(command);
        Sweep();
        if (stopped) throw new IOException("browser_server_stopped");
        if (!active()) throw new IOException("browser_control_ended");
        if (hosts.Count != 1)
        {
            var code = hosts.Count == 0 ? "browser_extension_unavailable" : "browser_profile_ambiguous";
            if (hosts.Count == 0 && StartupHint() is { } startup)
            {
                var details = ComputerUseService.ErrorDetails(new IOException(code));
                details["startup"] = startup;
                throw new ComputerToolException(code, details);
            }
            throw new IOException(code);
        }
        if (pending is not null) throw new IOException("computer_busy");
        pending = new(Guid.NewGuid().ToString("D"), hosts.Keys.First(), command.DeepClone(), now().Add(timeout), active);
        watchdog.Change(100, 100);
        return pending.Result.Task;
    });
    public Task<JsonNode> Exchange(JsonNode value) => OnContext(() => Task.FromResult(ExchangeCore(value)));
    private JsonNode ExchangeCore(JsonNode value)
    {
        if (stopped) throw new IOException("browser_server_stopped");
        if (value is not JsonObject fields || fields.Any(pair => pair.Key is not ("instance_id" or "response"))
            || Text(value["instance_id"]) is not { } host || !Guid.TryParse(host, out _)) throw new IOException("invalid_browser_exchange");
        if (Encoding.UTF8.GetByteCount(value.ToJsonString(WireJson)) > 245760) throw new IOException("browser_response_too_large");
        var response = value["response"];
        if (response is not null && (response is not JsonObject responseFields
            || responseFields.Any(pair => pair.Key is not ("id" or "result" or "error"))
            || !Guid.TryParse(Text(response["id"]), out _)
            || responseFields.ContainsKey("result") == responseFields.ContainsKey("error"))) throw new IOException("invalid_browser_response");
        hosts[host] = now();
        Sweep();
        if (pending is { Delivered: true } request && request.Host == host && Text(response?["id"]) == request.ID)
        {
            if (((JsonObject)response!).ContainsKey("error"))
            {
                var error = response["error"];
                var message = Text(error) ?? (error is JsonObject ? Text(error["message"]) : null) ?? "browser_command_failed";
                if (message.Length > 512) message = message[..512];
                Finish(null, Failure(message, request.Command, true));
            }
            else Finish(response!["result"]?.DeepClone(), null);
        }
        Sweep();
        if (pending is not { Delivered: false } next || next.Host != host) return ComputerUseService.Obj(("command", null));
        next.Delivered = true;
        return ComputerUseService.Obj(("command", ComputerUseService.Obj(("id", next.ID),
            ("deadline_ms", new DateTimeOffset(next.Deadline).ToUnixTimeMilliseconds()), ("command", next.Command))));
    }
    private void Sweep()
    {
        foreach (var host in hosts.Where(pair => (now() - pair.Value).TotalSeconds >= 5).Select(pair => pair.Key).ToArray()) hosts.Remove(host);
        if (pending is not { } request) return;
        if (!request.Active()) Fail("browser_control_ended");
        else if (request.Deadline <= now()) Fail("browser_timeout_execution_unknown");
        else if (hosts.Count > 1) Fail("browser_profile_ambiguous");
        else if (!hosts.ContainsKey(request.Host)) Fail("browser_host_disconnected");
    }
    private void Fail(string code)
    {
        if (pending is not { } request) return;
        Finish(null, Failure(code, request.Command, request.Delivered));
    }
    internal static bool IsReadOnly(JsonNode command) => command is JsonObject && Text(command["action"]) is "tabs" or "observe";
    internal static bool IsTimeout(string message) => message.Split(':', 2)[0].Trim() is "browser_read_timeout" or "browser_timeout_execution_unknown"
        or "remote_timeout_execution_unknown" or "browser_command_expired" or "deadline_exceeded";
    internal static ComputerToolException Failure(string message, JsonNode command, bool delivered)
    {
        var readOnly = IsReadOnly(command);
        var code = readOnly && IsTimeout(message) ? "browser_read_timeout" : message.Split(':', 2)[0].Trim();
        var domCommand = Text(command["action"]) is "observe" or "click" or "fill" or "select" or "check" or "press";
        // These exact DOM errors precede all setters, focus changes and event dispatches.
        var elementRejected = domCommand && code is "stale_element" or "one_exact_locator_required" or "ambiguous_element"
            or "locator_scan_truncated" or "element_not_found" or "disabled_element" or "hidden_element" or "explicit_tab_id_required"
            or "wrong_tab" or "max_nodes_must_be_1_to_500" or "unsupported_action" or "readonly_element" or "element_not_fillable"
            or "invalid_text" or "single_select_required" or "value_required" or "option_scan_truncated" or "ambiguous_option"
            or "option_not_found" or "disabled_option" or "native_checkable_required" or "radio_cannot_be_unchecked"
            or "element_not_clickable" or "unsupported_key" or "element_not_focusable";
        // Navigation may already have been sent; only DOM commands have these preflight guarantees.
        var pageLoading = domCommand && code == "browser_page_loading";
        var pageError = domCommand && code == "browser_page_error";
        var retryable = readOnly && (code is "browser_read_timeout" or "browser_host_disconnected" || pageLoading);
        var unavailableTab = code is "browser_tab_frozen" or "browser_tab_discarded";
        return new ComputerToolException(code, ComputerUseService.Obj(("code", code), ("message", message), ("read_only", readOnly),
            ("input_outcome", readOnly || !delivered || unavailableTab || elementRejected || pageLoading || pageError ? "not_attempted" : "unknown"),
            ("retryable", retryable), ("max_retries", retryable ? 1 : 0),
            ("next_step", elementRejected ? "observe_and_choose_fresh_element"
                : pageLoading ? "observe_loading_page_with_bounded_retry" : pageError ? "report_browser_page_unavailable"
                : unavailableTab ? "inspect_tab_state_before_new_request" : retryable ? "retry_read_once_then_report_unavailable"
                : readOnly ? "report_browser_unavailable_without_retry" : "observe_before_new_request")));
    }
    private void Finish(JsonNode? value, Exception? error)
    {
        var request = pending;
        pending = null;
        watchdog.Change(Timeout.Infinite, Timeout.Infinite);
        if (error is not null) request?.Result.TrySetException(error);
        else request?.Result.TrySetResult(value!);
    }
    public void Dispose() => context.Post(_ =>
    {
        if (stopped) return;
        stopped = true;
        hosts.Clear();
        Fail("browser_server_stopped");
        watchdog.Dispose();
    }, null);

    private JsonObject? StartupHint()
    {
        if (startupPath is null) return null;
        try
        {
            using var file = new FileStream(startupPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            if (file.Length > 4096) return null;
            var bytes = new byte[4097];
            var length = 0;
            while (length < bytes.Length)
            {
                var read = file.Read(bytes, length, bytes.Length - length);
                if (read == 0) break;
                length += read;
            }
            if (length > 4096 || JsonNode.Parse(bytes.AsSpan(0, length)) is not JsonObject config
                || Text(config["preferred_shortcut_name"]) is not { } raw) return null;
            var count = 0;
            foreach (var rune in raw.EnumerateRunes())
                if (++count > 256 || Rune.GetUnicodeCategory(rune) is UnicodeCategory.Control or UnicodeCategory.Format
                    or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator) return null;
            var name = raw.Trim();
            return name.Length == 0 ? null : ComputerUseService.Obj(("preferred_shortcut_name", name));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }

    private static string? Text(JsonNode? value) => value is JsonValue text && text.TryGetValue<string>(out var result) ? result : null;
    private static string Required(JsonNode value, string key) => Text(value[key]) is { Length: > 0 } text ? text : throw new IOException("missing_" + key);
    public static void Validate(JsonNode command)
    {
        if (command is not JsonObject fields || Encoding.UTF8.GetByteCount(command.ToJsonString(WireJson)) > 65536
            || Text(command["action"]) is not ("tabs" or "navigate" or "observe" or "click" or "fill" or "select" or "check" or "press")) throw new IOException("invalid_browser_command");
        if (fields.Any(pair => pair.Key is not ("action" or "tab_id" or "url" or "element_id" or "text" or "value" or "checked" or "key" or "max_nodes" or "role" or "name"))) throw new IOException("invalid_browser_command_field");
        var action = Required(command, "action");
        if (action != "tabs" || fields.ContainsKey("tab_id")) _ = ComputerUseService.Integer(command, "tab_id", -1, 1, int.MaxValue);
        foreach (var (key, limit) in new[] { ("url", 8192), ("element_id", 512), ("text", 32768), ("value", 8192), ("key", 40), ("role", 80), ("name", 1024) })
            if (fields.ContainsKey(key) && (Text(command[key]) is not { } text || Encoding.UTF8.GetByteCount(text) > limit)) throw new IOException("invalid_browser_" + key);
        if (action == "navigate")
        {
            var url = Required(command, "url");
            if (url != "about:blank" && (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https") || uri.Host.Length == 0)) throw new IOException("invalid_browser_url");
        }
        if (action is "click" or "fill" or "select" or "check" or "press" && Text(command["element_id"]) is not { Length: > 0 })
        {
            _ = Required(command, "role");
            _ = Required(command, "name");
        }
        if (action == "fill" && Text(command["text"]) is null) throw new IOException("missing_text");
        if (action == "select" && Text(command["value"]) is null) throw new IOException("missing_value");
        if (action == "press") _ = Required(command, "key");
        if ((fields.ContainsKey("checked") || action == "check") && (command["checked"] is not JsonValue checkedValue || !checkedValue.TryGetValue<bool>(out _))) throw new IOException("invalid_browser_checked");
        if (fields.ContainsKey("max_nodes")) _ = ComputerUseService.Integer(command, "max_nodes", 200, 1, 500);
    }
}
