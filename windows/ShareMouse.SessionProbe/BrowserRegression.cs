using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json.Nodes;
using ShareMouse.Core;
using ShareMouse.Network;

static class BrowserRegression
{
    public static async Task Run()
    {
        var id = Guid.NewGuid().ToString("D");
        var directory = Path.Combine(Path.GetTempPath(), "ShareMouse-Browser-" + id);
        Directory.CreateDirectory(directory);
        try
        {
            using var identity = new IdentityStore(id);
            await using var manager = new SessionManager(id, "Browser", identity, new PeerRegistry(directory), "123456", "", _ => true, _ => true, _ => { });
            using var context = new FixtureInputContext();
            using var clipboard = new ClipboardService(id, manager, context, _ => { });
            var screen = new ScreenGeometry(id + ":test", id, "Fixture", 1, 100, 100, true, 0, 0);
            using var service = new ComputerUseService(id, "Browser", manager, null, clipboard, context,
                () => [screen], () => new JsonObject(), _ => Task.FromResult(ComputerUseService.Obj(("width", 100), ("height", 100))),
                (_, _, _, _) => throw new Exception("Browser operation injected OS input"), () => true, _ => { }, () => true);
            service.AllowComputer = true;
            await Reject("missing_control_session_id", () => service.Tool("browser_command", ComputerUseService.Obj(
                ("peer_id", "local"), ("request_id", Guid.NewGuid().ToString("D")), ("command", ComputerUseService.Obj(("action", "tabs"))))));
            using var server = new MCPServer(service, directory);
            var opened = await service.Tool("open_computer", ComputerUseService.Obj(("peer_id", "local")));
            var startupDirectory = Path.Combine(directory, "browser");
            Directory.CreateDirectory(startupDirectory);
            var startupPath = Path.Combine(startupDirectory, "startup.json");
            var validStartup = System.Text.Encoding.UTF8.GetBytes("{\"preferred_shortcut_name\":\"Edge Custom Profile\"}");
            var startupCases = new List<(byte[] data, bool accepted)> { (validStartup, true),
                (validStartup.Concat(Enumerable.Repeat((byte)32, 4096 - validStartup.Length)).ToArray(), true),
                (validStartup.Concat(Enumerable.Repeat((byte)32, 4097 - validStartup.Length)).ToArray(), false),
                (System.Text.Encoding.UTF8.GetBytes("[]"), false) };
            foreach (var invalid in new[] { "", " \t ", new string('x', 257), "Edge\nother", "Edge\u202Ehidden" })
                startupCases.Add((System.Text.Encoding.UTF8.GetBytes(ComputerUseService.Obj(("preferred_shortcut_name", invalid)).ToJsonString()), false));
            foreach (var (data, accepted) in startupCases)
            {
                File.WriteAllBytes(startupPath, data);
                var missing = await service.Tool("browser_command", Request());
                Require(missing["error_details"]?["code"]?.GetValue<string>() == "browser_extension_unavailable", "Wrong missing host error");
                Require(accepted ? missing["error_details"]?["startup"]?["preferred_shortcut_name"]?.GetValue<string>() == "Edge Custom Profile"
                    : missing["error_details"]?["startup"] is null, "Invalid local startup name handling");
            }
            var host = Guid.NewGuid().ToString("D");
            Task<JsonObject?> Exchange(JsonNode? response = null) => server.Process(ComputerUseService.Obj(("jsonrpc", "2.0"), ("id", 1),
                ("method", "browser/exchange"), ("params", ComputerUseService.Obj(("instance_id", host), ("response", response)))));
            var exchanged = await Exchange();
            Require(exchanged?["result"] is JsonObject result && result.ContainsKey("command") && result["command"] is null,
                "Native browser exchange unavailable");
            JsonObject Request(JsonNode? command = null) => ComputerUseService.Obj(("peer_id", "local"),
                ("control_session_id", opened["control_session_id"]), ("request_id", Guid.NewGuid().ToString("D")),
                ("command", command ?? ComputerUseService.Obj(("action", "tabs"))));
            async Task<JsonNode> Delivery()
            {
                for (var attempt = 0; attempt < 100; attempt++)
                {
                    var response = await Exchange();
                    if (response?["result"]?["command"] is { } command) return command;
                    await Task.Delay(10);
                }
                throw new Exception("Browser command was not delivered");
            }
            var request = Request();
            var executing = service.Tool("browser_command", request);
            var delivered = await Delivery();
            Require(delivered["command"]?["action"]?.GetValue<string>() == "tabs" && delivered["deadline_ms"]!.GetValue<long>() > DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), "Invalid native command envelope");
            await Reject("computer_busy", () => service.Tool("browser_command", request));
            await Exchange(ComputerUseService.Obj(("id", delivered["id"]), ("result", ComputerUseService.Obj(("tabs", new JsonArray())))));
            var first = await executing;
            Require(first["browser"]?["tabs"] is JsonArray && first["control_session_expires_at"] is not null, "Native browser result missing");
            var replay = await service.Tool("browser_command", request);
            Require(JsonNode.DeepEquals(first, replay) && (await Exchange())?["result"]?["command"] is null, "Browser replay redelivered");
            var changed = (JsonObject)request.DeepClone();
            changed["command"] = ComputerUseService.Obj(("action", "observe"), ("tab_id", 1));
            await Reject("request_id_reused_with_different_actions", () => service.Tool("browser_command", changed));
            await Reject("request_id_reused_with_different_actions", () => service.Tool("computer_action", request));
            var rejectedRequest = Request(ComputerUseService.Obj(("action", "click"), ("tab_id", 1), ("role", "link"), ("name", "npm")));
            executing = service.Tool("browser_command", rejectedRequest);
            delivered = await Delivery();
            await Exchange(ComputerUseService.Obj(("id", delivered["id"]), ("error", "ambiguous_element: two npm links")));
            var rejected = await executing;
            Require(rejected["error_details"]?["input_outcome"]?.GetValue<string>() == "not_attempted"
                && rejected["error_details"]?["next_step"]?.GetValue<string>() == "observe_and_choose_fresh_element",
                "Service lost preflight failure classification");
            Require(JsonNode.DeepEquals(rejected, await service.Tool("browser_command", rejectedRequest))
                && (await Exchange())?["result"]?["command"] is null, "Rejected browser request was redelivered");
            var unknownRequest = Request(ComputerUseService.Obj(("action", "click"), ("tab_id", 1), ("element_id", "button")));
            executing = service.Tool("browser_command", unknownRequest);
            delivered = await Delivery();
            await Exchange(ComputerUseService.Obj(("id", delivered["id"]), ("error", "browser_page_changed")));
            var unknown = await executing;
            Require(unknown["error_details"]?["input_outcome"]?.GetValue<string>() == "unknown", "Lost unknown outcome");
            for (var index = 0; index < 5; index++)
            {
                var status = await service.Tool("get_control_status", request);
                var desktop = ComputerUseService.Obj(("peer_id", "local"), ("control_session_id", opened["control_session_id"]),
                    ("observation_id", status["latest_observation_id"]), ("request_id", Guid.NewGuid().ToString("D")),
                    ("settle_ms", 0), ("actions", new JsonArray(ComputerUseService.Obj(("type", "wait"), ("milliseconds", 0)))));
                Require((await service.Tool("computer_action", desktop))["error"] is null, "Desktop wait regression failed");
            }
            Require(JsonNode.DeepEquals(unknown, await service.Tool("browser_command", unknownRequest)), "Failed result replay was not cached");
            const string originalMessage = "deadline_exceeded: operation timed out";
            context.Invoke(() => service.BrowserHandler = (_, _) => throw new ComputerToolException("browser_read_timeout",
                ComputerUseService.Obj(("code", "browser_read_timeout"), ("message", originalMessage))));
            var readRequest = Request(ComputerUseService.Obj(("action", "observe"), ("tab_id", 1)));
            var readFailure = await service.Tool("browser_command", readRequest);
            Require(readFailure["error"]?.GetValue<string>() == "browser_read_timeout"
                && readFailure["error_details"]?["read_only"]?.GetValue<bool>() == true
                && readFailure["error_details"]?["input_outcome"]?.GetValue<string>() == "not_attempted"
                && readFailure["error_details"]?["max_retries"]?.GetValue<int>() == 1
                && readFailure["error_details"]?["message"]?.GetValue<string>() == originalMessage, "Service lost read-only failure classification or full message");
            Require(JsonNode.DeepEquals(readFailure, await service.Tool("browser_command", readRequest)), "Read failure was not cached");
            var count = 0;
            context.Invoke(() => service.BrowserHandler = (_, active) =>
            {
                Require(active(), "Inactive browser callback");
                count++;
                return Task.FromResult<JsonNode>(ComputerUseService.Obj(("ok", true)));
            });
            var orderedRequest = Request(ComputerUseService.Obj(("action", "observe"), ("tab_id", 1)));
            var orderedResult = await service.Tool("browser_command", orderedRequest);
            orderedRequest["command"] = ComputerUseService.Obj(("tab_id", 1), ("action", "observe"));
            Require(JsonNode.DeepEquals(orderedResult, await service.Tool("browser_command", orderedRequest)) && count == 1,
                "Object field order changed browser request identity");
            var evictionRequests = new List<JsonObject> { request, orderedRequest };
            for (var index = 0; index < 65; index++)
            {
                var candidate = Request();
                evictionRequests.Add(candidate);
                await service.Tool("browser_command", candidate);
            }
            var evicted = 0;
            foreach (var candidate in evictionRequests)
            {
                try { await service.Tool("browser_command", candidate); }
                catch (IOException error) when (error.Message == "browser_request_result_expired") { evicted++; }
            }
            Require(evicted > 0, "Browser result cache did not evict any request");
            Require(count == 66, "Evicted browser result was executed again");
            context.Invoke(() => { service.BrowserHandler = async (_, active) =>
            {
                while (active()) await Task.Delay(10);
                throw new ComputerToolException("browser_control_ended", ComputerUseService.Obj(("input_outcome", "unknown")));
            }; return true; });
            executing = service.Tool("browser_command", Request(ComputerUseService.Obj(("action", "click"), ("tab_id", 1), ("element_id", "button"))));
            await Task.Delay(25);
            context.Invoke(() => { service.EndControl("user_exit"); return true; });
            var ended = await executing.WaitAsync(TimeSpan.FromSeconds(2));
            Require(ended["error_details"]?["code"]?.GetValue<string>() == "user_exit", "Browser command lost explicit exit reason");
            Require(ended["error_details"]?["input_outcome"]?.GetValue<string>() == "unknown", "User exit hid an already-dispatched browser outcome");
            await Reject("control_session_unavailable:user_exit", () => service.Tool("browser_command", Request()));
            opened = await service.Tool("open_computer", ComputerUseService.Obj(("peer_id", "local")));
            context.Invoke(() => service.BrowserHandler = (_, _) =>
            {
                service.EndControl("user_exit");
                throw new ComputerToolException("browser_timeout_execution_unknown", ComputerUseService.Obj(
                    ("input_outcome", "unknown"), ("retryable", true), ("max_retries", 1)));
            });
            var exitedRead = await service.Tool("browser_command", Request(ComputerUseService.Obj(("action", "observe"), ("tab_id", 1))));
            Require(exitedRead["error_details"]?["code"]?.GetValue<string>() == "user_exit"
                && exitedRead["error_details"]?["read_only"]?.GetValue<bool>() == true
                && exitedRead["error_details"]?["input_outcome"]?.GetValue<string>() == "not_attempted"
                && exitedRead["error_details"]?["retryable"]?.GetValue<bool>() == false
                && exitedRead["error_details"]?["max_retries"] is null
                && exitedRead["error_details"]?["next_step"]?.GetValue<string>() == "wait_for_user_authorization", "Read recovery bypassed explicit exit");
            await BrokerBoundaries(context);
            await ReadOnlyFailures(context);
            await PreflightFailures(context);
            await PagePreflightFailures(context);
            Console.WriteLine("Browser regression passed: lease, native exchange, result/replay, unknown-result cache, cross-action ID, eviction, user exit, validation, profile ambiguity and deadline.");
        }
        finally
        {
            using (var store = new X509Store(StoreName.My, StoreLocation.CurrentUser))
            {
                store.Open(OpenFlags.ReadWrite);
                foreach (var certificate in store.Certificates.Where(c => c.Subject == "CN=ShareMouse-" + id)) store.Remove(certificate);
            }
            if (CngKey.Exists("ShareMouse-" + id)) { using var key = CngKey.Open("ShareMouse-" + id); key.Delete(); }
            Directory.Delete(directory, true);
        }
    }
    static async Task BrokerBoundaries(FixtureInputContext context)
    {
        using (var unicodeBroker = new BrowserBroker(context))
        {
            var unicodeHost = Guid.NewGuid().ToString("D");
            var heartbeat = ComputerUseService.Obj(("instance_id", unicodeHost));
            await unicodeBroker.Exchange(heartbeat);
            var executing = unicodeBroker.Execute(ComputerUseService.Obj(("action", "tabs")), () => true);
            var unicodeDelivery = await unicodeBroker.Exchange(heartbeat);
            var text = new string('中', 60000); // 180 KiB UTF-8, below the browser and broker reply limits.
            await unicodeBroker.Exchange(ComputerUseService.Obj(("instance_id", unicodeHost), ("response",
                ComputerUseService.Obj(("id", unicodeDelivery["command"]!["id"]), ("result", ComputerUseService.Obj(("text", text)))))));
            Require((await executing)["text"]?.GetValue<string>() == text, "Valid Unicode browser result was rejected");
            BrowserBroker.Validate(ComputerUseService.Obj(("action", "fill"), ("tab_id", 1),
                ("element_id", "field"), ("text", new string('中', 10922))));
        }
        foreach (var (command, expected) in new[]
        {
            (ComputerUseService.Obj(("action", "evaluate"), ("code", "1+1")), "invalid_browser_command"),
            (ComputerUseService.Obj(("action", "tabs"), ("script", "1+1")), "invalid_browser_command_field"),
            (ComputerUseService.Obj(("action", "observe"), ("tab_id", 0)), "invalid_tab_id"),
            (ComputerUseService.Obj(("action", "observe"), ("tab_id", 1), ("max_nodes", 501)), "invalid_max_nodes"),
            (ComputerUseService.Obj(("action", "navigate"), ("tab_id", 1), ("url", "javascript:alert(1)")), "invalid_browser_url")
        }) await Reject(expected, () => { BrowserBroker.Validate(command); return Task.FromResult<JsonNode>(new JsonObject()); });
        var time = DateTime.UtcNow;
        using var broker = new BrowserBroker(context, () => time);
        var firstHost = Guid.NewGuid().ToString("D");
        JsonObject Heartbeat(string instance) => ComputerUseService.Obj(("instance_id", instance));
        await broker.Exchange(Heartbeat(firstHost));
        var queued = broker.Execute(ComputerUseService.Obj(("action", "tabs")), () => true);
        var confused = await broker.Exchange(Heartbeat(Guid.NewGuid().ToString("D")));
        Require(confused["command"] is null, "Ambiguous profile received pending command");
        await Reject("browser_profile_ambiguous", () => queued);
        context.Invoke(() => { time = time.AddSeconds(6); return true; });
        await broker.Exchange(Heartbeat(firstHost));
        var active = true;
        queued = broker.Execute(ComputerUseService.Obj(("action", "tabs")), () => active);
        context.Invoke(() => { active = false; return true; });
        Require((await broker.Exchange(Heartbeat(firstHost)))["command"] is null, "Browser delivered after user exit");
        await Reject("browser_control_ended", () => queued);
        queued = broker.Execute(ComputerUseService.Obj(("action", "click"), ("tab_id", 1), ("element_id", "button")), () => true);
        var delivery = await broker.Exchange(Heartbeat(firstHost));
        Require(delivery["command"] is not null, "Deadline test did not deliver");
        context.Invoke(() => { time = time.AddSeconds(16); return true; });
        await broker.Exchange(Heartbeat(firstHost));
        try { await queued; throw new Exception("Browser timeout accepted"); }
        catch (ComputerToolException error) { Require(error.Message == "browser_timeout_execution_unknown" && error.Details?["input_outcome"]?.GetValue<string>() == "unknown", "Wrong delivered timeout outcome"); }
    }
    static async Task ReadOnlyFailures(FixtureInputContext context)
    {
        var time = DateTime.UtcNow;
        using var broker = new BrowserBroker(context, () => time, TimeSpan.FromSeconds(1));
        var host = Guid.NewGuid().ToString("D");
        var poll = ComputerUseService.Obj(("instance_id", host));
        foreach (var action in new[] { "tabs", "observe" })
        {
            var command = action == "tabs" ? ComputerUseService.Obj(("action", action)) : ComputerUseService.Obj(("action", action), ("tab_id", 1));
            foreach (var source in new[] { "broker", "browser_timeout_execution_unknown", "deadline_exceeded: operation timed out" })
            {
                await broker.Exchange(poll);
                var task = broker.Execute(command, () => true);
                var delivery = await broker.Exchange(poll);
                if (source == "broker")
                {
                    context.Invoke(() => { time = time.AddSeconds(2); return true; });
                    await broker.Exchange(poll);
                }
                else await broker.Exchange(ComputerUseService.Obj(("instance_id", host), ("response",
                    ComputerUseService.Obj(("id", delivery["command"]!["id"]), ("error", source)))));
                try { await task; throw new Exception("Timed-out read succeeded"); }
                catch (ComputerToolException error)
                {
                    var details = error.Details;
                    Require(error.Message == "browser_read_timeout" && details?["read_only"]?.GetValue<bool>() == true
                        && details?["input_outcome"]?.GetValue<string>() == "not_attempted"
                        && details?["retryable"]?.GetValue<bool>() == true && details?["max_retries"]?.GetValue<int>() == 1
                        && details?["next_step"]?.GetValue<string>() == "retry_read_once_then_report_unavailable",
                        "Read-only timeout was reported as unknown input or without bounded recovery: " + error.Message);
                }
            }
        }
        foreach (var code in new[] { "browser_tab_frozen", "browser_tab_discarded" })
        {
            foreach (var action in new[] { "click", "observe" })
            {
                var message = code + ": tab 1449689917 is suspended; DOM execution unavailable";
                await broker.Exchange(poll);
                var task = broker.Execute(ComputerUseService.Obj(("action", action), ("tab_id", 1), ("element_id", "button")), () => true);
                var delivery = await broker.Exchange(poll);
                await broker.Exchange(ComputerUseService.Obj(("instance_id", host), ("response",
                    ComputerUseService.Obj(("id", delivery["command"]!["id"]), ("error", message)))));
                try { await task; throw new Exception("Frozen tab accepted input"); }
                catch (ComputerToolException error)
                {
                    Require(error.Message == code && error.Details?["code"]?.GetValue<string>() == code
                        && error.Details?["message"]?.GetValue<string>() == message
                        && error.Details?["read_only"]?.GetValue<bool>() == (action == "observe")
                        && error.Details?["input_outcome"]?.GetValue<string>() == "not_attempted"
                        && error.Details?["retryable"]?.GetValue<bool>() == false
                        && error.Details?["next_step"]?.GetValue<string>() == "inspect_tab_state_before_new_request",
                        "Preflight frozen/discarded rejection lost its stable code or guidance");
                }
            }
        }
    }
    static async Task PreflightFailures(FixtureInputContext context)
    {
        using var broker = new BrowserBroker(context);
        var host = Guid.NewGuid().ToString("D");
        var poll = ComputerUseService.Obj(("instance_id", host));
        var preflight = new[]
        {
            ("click", "ambiguous_element"), ("click", "stale_element"), ("click", "element_not_found"),
            ("click", "locator_scan_truncated"), ("click", "disabled_element"), ("click", "hidden_element"),
            ("click", "element_not_clickable"), ("click", "one_exact_locator_required"), ("click", "wrong_tab"),
            ("click", "explicit_tab_id_required"), ("click", "max_nodes_must_be_1_to_500"), ("click", "unsupported_action"),
            ("fill", "readonly_element"), ("fill", "element_not_fillable"), ("fill", "invalid_text"),
            ("select", "single_select_required"), ("select", "value_required"), ("select", "option_scan_truncated"),
            ("select", "ambiguous_option"), ("select", "option_not_found"), ("select", "disabled_option"),
            ("check", "native_checkable_required"), ("check", "radio_cannot_be_unchecked"),
            ("press", "unsupported_key"), ("press", "element_not_focusable")
        };
        var afterDispatch = new[]
        {
            ("fill", "fill_not_applied"), ("select", "select_not_applied"), ("check", "check_not_applied"),
            ("press", "focus_not_applied"), ("press", "focus_scan_truncated"), ("press", "focus_boundary"),
            ("click", "deadline_exceeded"), ("click", "document_unavailable"), ("click", "ambiguous_element_other")
        };
        foreach (var (item, index) in preflight.Concat(afterDispatch).Select((item, index) => (item, index)))
        {
            var (action, code) = item;
            var message = code + ": DOM rejected the command";
            var command = ComputerUseService.Obj(("action", action), ("tab_id", 1), ("element_id", "element"),
                ("text", "value"), ("value", "option"), ("checked", true), ("key", "Enter"));
            await broker.Exchange(poll);
            var task = broker.Execute(command, () => true);
            var delivery = await broker.Exchange(poll);
            await broker.Exchange(ComputerUseService.Obj(("instance_id", host), ("response",
                ComputerUseService.Obj(("id", delivery["command"]!["id"]), ("error", message)))));
            try { await task; throw new Exception("Rejected input succeeded"); }
            catch (ComputerToolException error)
            {
                var details = error.Details;
                var rejectedBeforeInput = index < preflight.Length;
                Require(details?["code"]?.GetValue<string>() == code && details?["message"]?.GetValue<string>() == message
                    && details?["input_outcome"]?.GetValue<string>() == (rejectedBeforeInput ? "not_attempted" : "unknown")
                    && details?["retryable"]?.GetValue<bool>() == false && details?["max_retries"]?.GetValue<int>() == 0
                    && details?["next_step"]?.GetValue<string>() == (rejectedBeforeInput ? "observe_and_choose_fresh_element" : "observe_before_new_request"),
                    "Wrong browser preflight/dispatch classification: " + code);
            }
        }
    }
    static async Task PagePreflightFailures(FixtureInputContext context)
    {
        using var broker = new BrowserBroker(context);
        var host = Guid.NewGuid().ToString("D");
        var poll = ComputerUseService.Obj(("instance_id", host));
        foreach (var code in new[] { "browser_page_loading", "browser_page_error" })
        {
            foreach (var action in new[] { "observe", "click", "navigate" })
            {
                await broker.Exchange(poll);
                var task = broker.Execute(ComputerUseService.Obj(("action", action), ("tab_id", 1),
                    ("element_id", "element"), ("url", "https://example.com/")), () => true);
                var delivery = await broker.Exchange(poll);
                await broker.Exchange(ComputerUseService.Obj(("instance_id", host), ("response",
                    ComputerUseService.Obj(("id", delivery["command"]!["id"]), ("error", code + ": page cannot run DOM commands")))));
                try { await task; throw new Exception("Unavailable page accepted input"); }
                catch (ComputerToolException error)
                {
                    var details = error.Details;
                    var retryable = action == "observe" && code == "browser_page_loading";
                    Require(details?["input_outcome"]?.GetValue<string>() == (action == "navigate" ? "unknown" : "not_attempted")
                        && details?["retryable"]?.GetValue<bool>() == retryable && details?["max_retries"]?.GetValue<int>() == (retryable ? 1 : 0)
                        && details?["next_step"]?.GetValue<string>() == (action == "navigate" ? "observe_before_new_request"
                            : code == "browser_page_loading" ? "observe_loading_page_with_bounded_retry" : "report_browser_page_unavailable"),
                        "Wrong page-state preflight classification for " + action + ": " + code);
                }
            }
        }
    }
    static void Require(bool passed, string message)
    {
        if (!passed) throw new Exception(message);
    }
    static async Task Reject(string expected, Func<Task<JsonNode>> operation)
    {
        try { await operation(); }
        catch (IOException e) when (e.Message == expected) { return; }
        throw new Exception("Expected " + expected);
    }
}
