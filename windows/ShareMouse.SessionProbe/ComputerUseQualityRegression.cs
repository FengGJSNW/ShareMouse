using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json.Nodes;
using ShareMouse.Core;
using ShareMouse.Network;

static class ComputerUseQualityRegression
{
    public static async Task Run()
    {
        ComputerUseService.ValidateObservationOptions(new JsonObject());
        foreach (var cap in new[] { 0, 1, 1600, 3840, 16384 })
            ComputerUseService.ValidateObservationOptions(ComputerUseService.Obj(("max_dimension", cap)));
        foreach (var cap in new[] { -1.0, 16385.0, 1.5 })
            await Reject("invalid_max_dimension", () => { ComputerUseService.ValidateObservationOptions(ComputerUseService.Obj(("max_dimension", cap))); return Task.FromResult<JsonNode>(new JsonObject()); });
        var id = Guid.NewGuid().ToString("D");
        var directory = Path.Combine(Path.GetTempPath(), "ShareMouse-Quality-" + id);
        Directory.CreateDirectory(directory);
        try
        {
            using var identity = new IdentityStore(id);
            await using var manager = new SessionManager(id, "Quality", identity, new PeerRegistry(directory), "123456", "", _ => true, _ => true, _ => { });
            var context = new SynchronizationContext();
            using var clipboard = new ClipboardService(id, manager, context, _ => { });
            var screen = new ScreenGeometry(id + ":test", id, "Fixture", 1, 2560, 1600, true, 99, 77);
            var window = "A";
            var events = new List<CapturedInput>();
            var captures = 0;
            var previews = new List<string>();
            var previewMilliseconds = 0;
            var failButtonUp = false;
            var time = DateTime.UtcNow;
            var available = true;
            var permissions = new JsonObject();
            JsonObject State() => ComputerUseService.Obj(("foreground_window", ComputerUseService.Obj(("window_id", window))), ("cursor_position", ComputerUseService.Obj(("x", -1280), ("y", 920))), ("input_injection_blocked", false));
            using var service = new ComputerUseService(id, "Quality", manager, null, clipboard, context, () => [screen], () => ComputerUseService.Obj(("permissions", permissions)), _ => Task.FromResult(ComputerUseService.Obj(("width", 1000), ("height", 720))), (value, _, _, _) => { if (value.Type == "buttonUp" && failButtonUp) throw new IOException("fixture_native_failure"); events.Add(value); }, () => true, _ => { }, () => available, utcNow: () => time, inputState: State, captureWithOptions: (_, options, active) => { Require(active(), "Capture continued after exit"); captures++; var width = options["thumbnail_max_dimension"]?.GetValue<int>() ?? 1000; return Task.FromResult(ComputerUseService.Obj(("width", width), ("height", width == 320 ? 200 : 720), ("captured_at", "fixture"), ("desktop_bounds", ComputerUseService.Obj(("x", -2560), ("y", 120), ("width", 2560), ("height", 1600))), ("desktop_coordinate_space", "desktop_pixels"), ("input_state", State()))); }, pointerPreview: (_, _, _, kind) => { previews.Add(kind); return previewMilliseconds; }, focusApplication: name => { window = name; return Task.CompletedTask; });
            service.AllowComputer = true;
            using var wireServer = new MCPServer(service, directory);
            var wire = await wireServer.Process(ComputerUseService.Obj(("jsonrpc", "2.0"), ("id", "list-array"), ("method", "tools/call"), ("params", ComputerUseService.Obj(("name", "list_computers"), ("arguments", new JsonObject())))));
            Require(wire?["result"]?["isError"]?.GetValue<bool>() == false && wire["result"]!["structuredContent"]!["result"] is JsonArray, "MCP wire failed to return a computer list array");
            JsonObject args = new();
            async Task<JsonNode> Open()
            {
                var opened = await service.Tool("open_computer", ComputerUseService.Obj(("peer_id", "local")));
                args = ComputerUseService.Obj(("peer_id", "local"), ("control_session_id", opened["control_session_id"]), ("observation_id", opened["observation_id"]));
                return opened;
            }
            async Task<JsonNode> RunActions(JsonObject request)
            {
                var result = await service.Tool("computer_action", request);
                if (result["observation"]?["observation_id"] is { } observation)
                    args["observation_id"] = observation.DeepClone();
                return result;
            }
            var opened = await Open();
            Require(opened["input_state"]!["cursor_position_screenshot"]!["x"]!.GetValue<double>() == 500, "Wrong cursor transform");
            Require(opened["coordinate_transform"]!["desktop_bounds"]!["x"]!.GetValue<int>() == -2560, "Used logical layout as desktop coordinates");
            var status = await service.Tool("get_control_status", args);
            Require(status["latest_observation_id"]!.GetValue<string>() == opened["observation_id"]!.GetValue<string>() && captures == 1, "Status changed observation");
            time = time.AddSeconds(5);
            var computerInfo = await service.Tool("get_computer_info", ComputerUseService.Obj(("peer_id", "local")));
            Require(computerInfo["control_state"]!["open_blocker"]!.GetValue<string>() == "computer_control_in_use" && computerInfo["control_state"]!["lease_remaining_ms"]!.GetValue<double>() == 595000, "Occupancy query changed lease or omitted blocker");
            Require(computerInfo["control_state"]!["control_session_id"] is null && captures == 1, "Occupancy leaked token or captured screen");
            try
            {
                await service.Tool("open_computer", ComputerUseService.Obj(("peer_id", "local")));
                throw new Exception("Existing control replaced");
            }
            catch (ComputerToolException e) { Require(e.Message == "computer_control_in_use" && e.Details?["input_outcome"]?.GetValue<string>() == "not_attempted", "Ambiguous control rejection"); }
            status = await service.Tool("get_control_status", args);
            Require(status["latest_observation_id"]!.GetValue<string>() == opened["observation_id"]!.GetValue<string>() && status["lease_remaining_ms"]!.GetValue<double>() == 595000, "Open rejection changed existing control");
            time = time.AddSeconds(596);
            var fresh = await Open();
            Require(fresh["control_session_id"]!.GetValue<string>() != opened["control_session_id"]!.GetValue<string>() && captures == 2, "Expired control not cleared before open");
            service.EndControl();
            available = false;
            permissions = ComputerUseService.Obj(("desktop_available", false));
            await Reject("desktop_locked_or_unavailable", () => service.Tool("open_computer", ComputerUseService.Obj(("peer_id", "local"))));
            permissions = ComputerUseService.Obj(("desktop_available", true), ("input_injection", false));
            await Reject("input_permission_missing", () => service.Tool("open_computer", ComputerUseService.Obj(("peer_id", "local"))));
            Require(!service.Controlling && captures == 2 && events.Count == 0, "Permission rejection acquired control or injected");
            available = true;
            permissions = ComputerUseService.Obj(("screen_capture", false));
            await Reject("screen_capture_permission_missing", () => service.Tool("open_computer", ComputerUseService.Obj(("peer_id", "local"))));
            Require(captures == 2 && !service.Controlling, "Missing capture permission acquired control");
            permissions = new();
            await Open();
            var move = ComputerUseService.Obj(("type", "move"), ("x", 10), ("y", 10));
            var bad = (JsonObject)args.DeepClone();
            bad["observation_id"] = "wrong";
            bad["actions"] = new JsonArray(move.DeepClone());
            try
            {
                await service.Tool("computer_action", bad);
                throw new Exception("Wrong observation accepted");
            }
            catch (ComputerToolException e) { Require(e.Details?["code"]?.GetValue<string>() == "observation_id_mismatch" && events.Count == 0, "Wrong stale rejection"); }
            bad = (JsonObject)args.DeepClone();
            bad["actions"] = new JsonArray(move.DeepClone());
            bad["ocr_region"] = ComputerUseService.Obj(("x", 900), ("y", 0), ("width", 200), ("height", 10));
            await Reject("analysis_region_outside_observation", () => service.Tool("computer_action", bad));
            Require(events.Count == 0, "Invalid ROI injected input");
            window = "B";
            var request = (JsonObject)args.DeepClone();
            request["actions"] = new JsonArray(move.DeepClone());
            request["require_same_window"] = true;
            var rejected = await RunActions(request);
            Require(rejected["error"]?.GetValue<string>() == "target_window_changed" && events.Count == 0 && service.Controlling, "Window switch ended control or injected");
            request = (JsonObject)args.DeepClone();
            request["actions"] = new JsonArray(move.DeepClone(), ComputerUseService.Obj(("type", "click"), ("x", 20), ("y", 20)));
            request["checkpoint_after"] = 1;
            request["step_images"] = true;
            request["settle_ms"] = 0;
            request["request_id"] = Guid.NewGuid().ToString("D");
            var checkpoint = await RunActions(request);
            Require(checkpoint["execution_status"]!.GetValue<string>() == "checkpoint" && events.Count == 1, "Checkpoint executed later actions");
            var before = captures;
            await service.Tool("computer_action", request);
            Require(captures == before && events.Count == 1, "Replay reinjected checkpoint");
            request = (JsonObject)args.DeepClone();
            request["actions"] = new JsonArray(ComputerUseService.Obj(("type", "move_relative"), ("dx", 250), ("dy", -50), ("steps", 30)));
            await RunActions(request);
            Require(events.Where(e => e.Type == "relativeMove").Sum(e => e.DeltaX) == 250, "Relative movement rounding lost counts");
            request = (JsonObject)args.DeepClone();
            request["actions"] = new JsonArray(ComputerUseService.Obj(("type", "key_hold"), ("keys", new JsonArray("W")), ("duration_ms", 800)));
            _ = Task.Run(async () => { await Task.Delay(70); service.EndControl("user_exit"); });
            var held = await service.Tool("computer_action", request);
            Require(held["error"]?.GetValue<string>() == "control_session_unavailable:user_exit" && events.Any(e => e.Type == "keyUp" && e.Key == "KeyW"), "Held key not released on user exit");
            await Open();
            failButtonUp = true;
            request = (JsonObject)args.DeepClone();
            request["actions"] = new JsonArray(ComputerUseService.Obj(("type", "click"), ("x", 10), ("y", 10)));
            var partial = await RunActions(request);
            Require(partial["executed_actions"]!.GetValue<int>() == 0 && partial["error_details"]!["input_outcome"]!.GetValue<string>() == "partial_or_unknown", "Partial native input reported as none");
            failButtonUp = false;
            service.EndControl();
            await Open();
            events.Clear();
            previewMilliseconds = 100;
            previews.Clear();
            request = (JsonObject)args.DeepClone();
            request["actions"] = new JsonArray(ComputerUseService.Obj(("type", "click"), ("x", 10), ("y", 20)), ComputerUseService.Obj(("type", "double_click"), ("x", 30), ("y", 40)), ComputerUseService.Obj(("type", "drag"), ("path", new JsonArray(ComputerUseService.Obj(("x", 20), ("y", 20)), ComputerUseService.Obj(("x", 30), ("y", 30))))), ComputerUseService.Obj(("type", "move_relative"), ("dx", 5), ("dy", 0), ("steps", 1)));
            await RunActions(request);
            Require(previews.SequenceEqual(new[] { "click", "double_click" }) && events.Count(e => e.Type == "move") == 4 && events.Count(e => e.Type == "buttonDown") == 4, "Preview changed input path or click count");
            events.Clear();
            previewMilliseconds = 200;
            request = (JsonObject)args.DeepClone();
            request["actions"] = new JsonArray(move.DeepClone());
            _ = Task.Run(async () => { await Task.Delay(40); service.EndControl("user_exit"); });
            var stopped = await service.Tool("computer_action", request);
            Require(stopped["error_details"]!["input_outcome"]!.GetValue<string>() == "not_attempted" && events.Count == 0, "Preview injected after explicit exit");
            await Open();
            request = (JsonObject)args.DeepClone();
            request["actions"] = new JsonArray(move.DeepClone());
            request["require_same_window"] = true;
            _ = Task.Run(async () => { await Task.Delay(40); window = "changed"; });
            var switched = await service.Tool("computer_action", request);
            Require(switched["error"]!.GetValue<string>() == "target_window_changed" && events.Count == 0 && service.Controlling, "Preview bypassed window guard");
            service.EndControl();
            available = true;
            permissions = new();
            previewMilliseconds = 0;
            events.Clear();
            var managed = await service.Tool("open_computer", ComputerUseService.Obj(("peer_id", "local"), ("control_session_idle_timeout_ms", 45000), ("client_id", Guid.NewGuid().ToString("D")), ("client_name", "QA client")));
            Require(managed["control_session_idle_timeout_ms"]!.GetValue<double>() == 45000, "Managed lease timeout missing");
            var ownerInfo = await service.Tool("get_computer_info", ComputerUseService.Obj(("peer_id", "local")));
            Require(ownerInfo["control_state"]!["owner_client_name"]!.GetValue<string>() == "QA client", "Owner label missing");
            var focus = ComputerUseService.Obj(("peer_id", "local"), ("control_session_id", managed["control_session_id"]), ("observation_id", managed["observation_id"]), ("actions", new JsonArray(ComputerUseService.Obj(("type", "focus_application"), ("application", "QA app"), ("allow_window_change", true)))));
            var focused = await service.Tool("computer_action", focus);
            Require(focused["observation"]!["input_state"]!["foreground_window"]!["window_id"]!.GetValue<string>() == "QA app" && events.Count == 0, "Focus changed input or failed to select app");
            time = time.AddSeconds(46);
            await Reject("control_session_unavailable:lease_expired", () => service.Tool("get_control_status", focus));
            Console.WriteLine("ComputerUse quality passed: occupancy without tokens, expired-open recovery, precise permission errors, native coordinate transform, precise rejection, window guard, checkpoint/replay, exact relative motion, held-key exit, partial input reporting.");
        }
        finally { using (var store = new X509Store(StoreName.My, StoreLocation.CurrentUser)) { store.Open(OpenFlags.ReadWrite); foreach (var certificate in store.Certificates.Where(c => c.Subject == "CN=ShareMouse-" + id)) store.Remove(certificate); } if (CngKey.Exists("ShareMouse-" + id)) { using var key = CngKey.Open("ShareMouse-" + id); key.Delete(); } Directory.Delete(directory, true); }
    }
    static void Require(bool value, string message)
    {
        if (!value)
            throw new Exception(message);
    }
    static async Task Reject(string message, Func<Task<JsonNode>> action)
    {
        try
        {
            await action();
        }
        catch (IOException e) when (e.Message == message) { return; }
        throw new Exception("Expected: " + message);
    }
}
