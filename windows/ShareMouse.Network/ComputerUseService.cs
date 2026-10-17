using System.Text.Json;
using System.Text.Json.Nodes;
using ShareMouse.Core;

namespace ShareMouse.Network;

public sealed class ComputerUseService : IDisposable
{
    public const string Capability = "remote-computer-v1";
    public const int IdleTimeoutSeconds = 600;
    public bool AllowComputer
    {
        get; set;
    }
    public bool AllowFiles
    {
        get; set;
    }
    public bool Controlling => control is not null;
    public JsonNode? ControlContext => control?.ControlContext;
    private readonly string id, name;
    private readonly SessionManager manager;
    private readonly FileTransferService? files;
    private readonly ClipboardService clipboard;
    private readonly SynchronizationContext context;
    private readonly Func<ScreenGeometry[]> screens;
    private readonly Func<JsonObject> info;
    private readonly Func<ScreenGeometry, Task<JsonObject>> screenshot;
    private readonly Action<CapturedInput, ScreenGeometry?, double, double> inject;
    private readonly Func<bool> suspend, canControl;
    private readonly Action<bool> restore;
    private readonly Action<ScreenGeometry, double, double, string> marker;
    private readonly Func<ScreenGeometry, double, double, string, int> pointerPreview;
    private readonly Func<string, Task> focusApplication;
    private readonly Timer watcher;
    private readonly Func<DateTime> utcNow;
    private readonly Action<string> diagnostic;
    private readonly Action<bool, string> controlChanged;
    private readonly Action activity;
    private readonly Func<JsonObject>? inputState;
    private readonly Func<ScreenGeometry, JsonNode, Func<bool>, Task<JsonObject>>? captureWithOptions;
    private bool stopped;
    private sealed class Control(string token, string owner, string? ownerSession, ScreenGeometry screen, bool restoreSharing, DateTime started)
    {
        public readonly string Token = token, Owner = owner; public readonly string? OwnerSession = ownerSession;
        public readonly ScreenGeometry Screen = screen; public readonly bool RestoreSharing = restoreSharing;
        public double IdleSeconds = IdleTimeoutSeconds; public string? ClientID, ClientName; public readonly DateTime Started = started; public DateTime Expires = started.AddSeconds(IdleTimeoutSeconds); public string Observation = ""; public int Width, Height; public bool Busy; public JsonNode ControlContext = Obj(("mode", "user_mouse")); public JsonNode Region = Obj(("x", 0), ("y", 0), ("width", 1), ("height", 1)); public JsonNode? LastResult, LastCapturedAt; public string? LastWindowID; public string? OpenRequest;
        public readonly Dictionary<string, (string signature, JsonObject result)> Completed = new();
    }
    private Control? control;
    private (string token, string owner, string reason)? lastEnded;
    private readonly HashSet<string> heldKeys = new(); private readonly HashSet<int> heldButtons = new();
    private sealed record Packet(string Type, string RequestID, int Offset, int Total, byte[] Data);
    private sealed class Assembly(int total)
    {
        public readonly MemoryStream Data = new(); public readonly int Total = total; public readonly DateTime Created = DateTime.UtcNow;
    }
    private sealed record Pending(string Peer, string Session, string Operation, TaskCompletionSource<JsonNode> Result);
    private readonly Dictionary<string, Assembly> incoming = new(); private readonly HashSet<string> working = new();
    private readonly Dictionary<string, Pending> pending = new();
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true };
    public static JsonObject Obj(params (string key, object? value)[] values)
    {
        var result = new JsonObject();
        foreach (var (key, value) in values)
            result[key] = value is JsonNode node ? node.DeepClone() : JsonSerializer.SerializeToNode(value, Json);
        return result;
    }
    private static string S(JsonNode? a, string key) => a?[key]?.GetValue<string>() is { Length: > 0 } value ? value : throw new IOException("missing_" + key);
    private static double N(JsonNode? a, string key, double fallback = 0)
    {
        if (a?[key] is null)
            return fallback;
        if (a[key] is JsonValue value)
        {
            if (value.TryGetValue<double>(out var d))
                return d;
            if (value.TryGetValue<int>(out var i))
                return i;
            if (value.TryGetValue<long>(out var l))
                return l;
            if (value.TryGetValue<float>(out var f))
                return f;
            if (value.TryGetValue<decimal>(out var m))
                return (double)m;
        }
        throw new IOException("invalid_" + key);
    }
    public ComputerUseService(string id, string name, SessionManager manager, FileTransferService? files, ClipboardService clipboard, SynchronizationContext context,
        Func<ScreenGeometry[]> screens, Func<JsonObject> info, Func<ScreenGeometry, Task<JsonObject>> screenshot,
        Action<CapturedInput, ScreenGeometry?, double, double> inject, Func<bool> suspend, Action<bool> restore, Func<bool> canControl, Action<ScreenGeometry, double, double, string>? marker = null, Func<DateTime>? utcNow = null, Action<string>? diagnostic = null, Action<bool, string>? controlChanged = null, Action? activity = null, Func<JsonObject>? inputState = null, Func<ScreenGeometry, JsonNode, Func<bool>, Task<JsonObject>>? captureWithOptions = null, Func<ScreenGeometry, double, double, string, int>? pointerPreview = null, Func<string, Task>? focusApplication = null)
    {
        this.id = id;
        this.name = name;
        this.manager = manager;
        this.files = files;
        this.clipboard = clipboard;
        this.context = context;
        this.screens = screens;
        this.info = info;
        this.screenshot = screenshot;
        this.inject = inject;
        this.suspend = suspend;
        this.restore = restore;
        this.canControl = canControl;
        this.marker = marker ?? ((_, _, _, _) => { });
        this.utcNow = utcNow ?? (() => DateTime.UtcNow);
        this.diagnostic = diagnostic ?? (_ => { });
        this.controlChanged = controlChanged ?? ((_, _) => { });
        this.activity = activity ?? (() => { });
        this.inputState = inputState;
        this.captureWithOptions = captureWithOptions;
        this.pointerPreview = pointerPreview ?? ((_, _, _, _) => 0);
        this.focusApplication = focusApplication ?? (_ => throw new IOException("application_focus_unavailable"));
        watcher = new Timer(_ => context.Post(_ => Tick(), null), null, Timeout.Infinite, Timeout.Infinite);
    }
    private Task<T> OnUI<T>(Func<Task<T>> work)
    {
        var result = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        context.Post(async _ => { try { result.TrySetResult(await work()); } catch (Exception e) { result.TrySetException(e); } }, null);
        return result.Task;
    }
    public async Task Start()
    {
        manager.Receive("computer", (peer, bytes) => OnUI(async () => { await Receive(peer, bytes); return true; }));
        await UpdateCapabilities();
        watcher.Change(1000, 1000);
    }
    public Task UpdateCapabilities() => manager.SetCapabilitiesAsync(new Dictionary<string, bool> { { Capability, true }, { "computer-open-ack-v1", true } });
    private void Tick()
    {
        if (stopped)
            return;
        var online = manager.CurrentSessions();
        if (control is { } c)
        {
            if (Unavailable(c) is { } reason)
                EndControl(reason);
            else if (c.Owner != id && !online.Any(s => s.PeerID == c.Owner && s.SessionID == c.OwnerSession))
                EndControl("peer_disconnected");
        }
        foreach (var pair in pending.Where(p => !online.Any(s => s.PeerID == p.Value.Peer && s.SessionID == p.Value.Session)).ToArray())
        {
            pending.Remove(pair.Key);
            pair.Value.Result.TrySetException(new IOException("peer_disconnected"));
        }
        foreach (var key in incoming.Where(p => (DateTime.UtcNow - p.Value.Created).TotalSeconds > 60).Select(p => p.Key).ToArray())
        {
            incoming[key].Data.Dispose();
            incoming.Remove(key);
        }
    }
    // Bypass sharing handlers while MCP controls this desktop, but pass real input to the OS.
    // Accidental movement or typing does not end the session; the user exits explicitly.
    public bool PhysicalInput(CapturedInput e) => Controlling;
    private void ReleaseHeld()
    {
        foreach (var b in heldButtons)
            try
            {
                inject(new("buttonUp", Button: b), null, 0, 0);
            }
            catch { }
        foreach (var k in heldKeys)
            try
            {
                inject(new("keyUp", k), null, 0, 0);
            }
            catch { }
        heldButtons.Clear();
        heldKeys.Clear();
    }
    public void EndControl(string reason = "closed")
    {
        var old = control;
        control = null;
        ReleaseHeld();
        if (old is not null)
        {
            lastEnded = (old.Token, old.Owner, reason);
            diagnostic($"ComputerUseEnded reason={reason} ageMs={(int)(utcNow() - old.Started).TotalMilliseconds}");
            controlChanged(false, reason);
            restore(old.RestoreSharing);
        }
    }
    public void Dispose()
    {
        stopped = true;
        watcher.Dispose();
        EndControl("server_stopped");
        foreach (var p in pending.Values)
            p.Result.TrySetException(new IOException("server_stopped"));
        pending.Clear();
        foreach (var a in incoming.Values)
            a.Data.Dispose();
        incoming.Clear();
    }
    private async Task Receive(string peer, byte[] bytes)
    {
        Packet? packet;
        try
        {
            packet = JsonSerializer.Deserialize<Packet>(bytes, Json);
        }
        catch { return; }
        if (stopped || packet is null || !Guid.TryParse(packet.RequestID, out _))
            return;
        if (packet.Type is "open_ack" or "open_cancel")
        {
            if (packet.Total != 0 || packet.Offset != 0 || packet.Data.Length != 0 || control?.Owner != peer || control?.OpenRequest != packet.RequestID)
                return;
            if (packet.Type == "open_ack")
            {
                control.OpenRequest = null;
                diagnostic("ComputerOpenConfirmed");
            }
            else
                EndControl("open_request_cancelled");
            return;
        }
        if (packet.Type is not ("request" or "response") || packet.Total <= 0 || packet.Total > (packet.Type == "request" ? 262144 : 16 * 1024 * 1024) || packet.Data.Length > 20000)
            return;
        if (packet.Type == "response" && (!pending.TryGetValue(packet.RequestID, out var expected) || expected.Peer != peer))
            return;
        var key = peer + ":" + packet.Type + ":" + packet.RequestID;
        if (working.Contains(key))
            return;
        if (!incoming.TryGetValue(key, out var state))
        {
            if (packet.Offset != 0 || incoming.Count >= 12)
                return;
            incoming[key] = state = new(packet.Total);
        }
        if (state.Total != packet.Total || state.Data.Length != packet.Offset || packet.Offset + packet.Data.Length > packet.Total)
        {
            state.Data.Dispose();
            incoming.Remove(key);
            return;
        }
        state.Data.Write(packet.Data);
        if (state.Data.Length != state.Total)
            return;
        incoming.Remove(key);
        JsonNode? value;
        try
        {
            value = JsonNode.Parse(state.Data.ToArray());
        }
        catch { state.Data.Dispose(); return; }
        state.Data.Dispose();
        if (value is null)
            return;
        if (packet.Type == "response")
        {
            if (pending.Remove(packet.RequestID, out var p))
            {
                if (value["ok"]?.GetValue<bool>() == true)
                {
                    if (p.Operation == "open")
                        try
                        {
                            await SendOpenSignal(peer, "open_ack", packet.RequestID);
                        }
                        catch { }
                    p.Result.TrySetResult(value["value"]!);
                }
                else
                    p.Result.TrySetException(new ComputerToolException(value["error"]?.GetValue<string>() ?? "remote_failure", value["error_details"] as JsonObject));
            }
        }
        else
        {
            if (control is { } occupied && occupied.Owner == peer && value["operation"]?.GetValue<string>() != "open" && value["arguments"]?["control_session_id"]?.GetValue<string>() == occupied.Token)
                occupied.OpenRequest = null;
            working.Add(key);
            _ = Respond();
            async Task Respond()
            {
                try
                {
                    JsonObject result;
                    try
                    {
                        result = Obj(("ok", true), ("value", await Execute(S(value, "operation"), value["arguments"] ?? new JsonObject(), peer, packet.RequestID)));
                    }
                    catch (Exception e) { result = Obj(("ok", false), ("error", e.Message), ("error_details", ErrorDetails(e))); }
                    await Transmit(peer, "response", packet.RequestID, result);
                }
                catch { }
                finally { working.Remove(key); }
            }
        }
        await Task.CompletedTask;
    }
    private Task SendOpenSignal(string peer, string type, string request) => manager.SendAsync(peer, "computer", JsonSerializer.SerializeToUtf8Bytes(new Packet(type, request, 0, 0, []), Json));
    private async Task Transmit(string peer, string type, string request, JsonNode value)
    {
        var data = JsonSerializer.SerializeToUtf8Bytes(value, Json);
        if (data.Length > 16 * 1024 * 1024)
            throw new IOException("payload_too_large");
        for (var offset = 0; offset < data.Length; offset += 20000)
            await manager.SendAsync(peer, "computer", JsonSerializer.SerializeToUtf8Bytes(new Packet(type, request, offset, data.Length, data.AsSpan(offset, Math.Min(20000, data.Length - offset)).ToArray()), Json));
    }
    private async Task<JsonNode> Call(string peer, string operation, JsonNode a)
    {
        if (stopped)
            throw new IOException("server_stopped");
        if (peer == id || peer == "local")
            return await Execute(operation, a, id);
        var session = manager.CurrentSessions().FirstOrDefault(s => s.PeerID == peer && s.Capabilities.Contains(Capability));
        if (session is null || pending.Count >= 8)
            throw new IOException("peer_offline_or_capability_unavailable");
        var request = Guid.NewGuid().ToString("D");
        var result = new TaskCompletionSource<JsonNode>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending[request] = new(peer, session.SessionID, operation, result);
        _ = Send();
        async Task Send()
        {
            try
            {
                await Transmit(peer, "request", request, Obj(("operation", operation), ("arguments", a)));
            }
            catch (Exception e) { if (pending.Remove(request, out var p)) p.Result.TrySetException(e); }
        }
        _ = TimeoutRequest();
        async Task TimeoutRequest()
        {
            await Task.Delay(60000);
            if (pending.Remove(request, out var p))
            {
                if (p.Operation == "open")
                    _ = CancelOpen();
                async Task CancelOpen()
                {
                    try
                    {
                        await SendOpenSignal(peer, "open_cancel", request);
                    }
                    catch { }
                }
                p.Result.TrySetException(new ComputerToolException("remote_timeout_execution_unknown", Obj(("code", "remote_timeout_execution_unknown"), ("request_id", request), ("input_outcome", operation == "open" ? "not_attempted" : "unknown"), ("next_step", "query_control_status_before_retry"), ("cleanup_requested", operation == "open"))));
            }
        }
        return await result.Task;
    }
    private string? Unavailable(Control c)
    {
        if (c.OpenRequest is not null && (utcNow() - c.Started).TotalSeconds > 45)
            return "open_response_unconfirmed";
        if (c.Expires <= utcNow())
            return "lease_expired";
        if (!AllowComputer)
            return "computer_access_disabled";
        if (!canControl())
            return "input_permission_or_desktop_unavailable";
        if (!screens().Contains(c.Screen))
            return "screen_changed";
        return null;
    }
    private void PruneUnavailableControl()
    {
        if (control is { } c)
        {
            var reason = Unavailable(c);
            if (reason is null && c.Owner != id && !manager.CurrentSessions().Any(s => s.PeerID == c.Owner && s.SessionID == c.OwnerSession))
                reason = "peer_disconnected";
            if (reason is not null)
                EndControl(reason);
        }
    }
    private string? OpenBlocker(JsonObject? snapshot = null)
    {
        if (!AllowComputer)
            return "computer_access_disabled";
        var permissions = (snapshot ?? info())["permissions"];
        if (permissions?["desktop_available"]?.GetValue<bool>() == false)
            return "desktop_locked_or_unavailable";
        if (permissions?["input_injection"]?.GetValue<bool>() == false)
            return "input_permission_missing";
        if (permissions?["screen_capture"]?.GetValue<bool>() == false)
            return "screen_capture_permission_missing";
        if (!canControl())
            return "input_permission_or_desktop_unavailable";
        if (screens().Length == 0)
            return "screen_unavailable";
        return null;
    }
    // This summary deliberately omits the control token; a peer may host multiple MCP clients.
    private JsonObject ControlState(string owner, JsonObject? snapshot = null)
    {
        var c = control;
        var unavailable = c is null ? null : Unavailable(c);
        var blocker = OpenBlocker(snapshot);
        var occupied = c is not null && unavailable is null;
        return Obj(("session_present", c is not null), ("active", occupied), ("busy", c?.Busy ?? false), ("can_open", !occupied && blocker is null),
            ("open_blocker", blocker ?? (occupied ? "computer_control_in_use" : null)), ("unavailable_reason", unavailable),
            ("owner_peer_id", c?.Owner), ("owner_client_id", c?.ClientID), ("owner_client_name", c?.ClientName), ("owner_is_local", c is null ? null : (object)(c.Owner == id)), ("owner_matches_requesting_peer", c is null ? null : (object)(c.Owner == owner)),
            ("control_mode", c?.ControlContext["mode"]), ("input_sharing_isolated", occupied), ("screen_id", c?.Screen.Id), ("started_at", c?.Started.ToString("O")), ("lease_remaining_ms", c is null ? null : (object)Math.Max(0, (c.Expires - utcNow()).TotalMilliseconds)),
            ("control_session_expires_at", c?.Expires.ToString("O")), ("renews_lease", false));
    }
    private void EnsureCanOpen(string owner)
    {
        var blocker = OpenBlocker() ?? (control is not null ? "computer_control_in_use" : null);
        if (blocker is null)
            return;
        var details = ErrorDetails(new IOException(blocker));
        details["input_outcome"] = "not_attempted";
        details["control_state"] = ControlState(owner);
        diagnostic($"ComputerUseOpenRejected reason={blocker} ownerPeer={control?.Owner ?? "none"}");
        throw new ComputerToolException(blocker, details);
    }
    private Control Checked(JsonNode a, string owner)
    {
        var token = S(a, "control_session_id");
        if (control is { } c && c.Token == token && c.Owner == owner)
        {
            if (Unavailable(c) is { } reason)
                EndControl(reason);
            else
                return c;
        }
        var ended = lastEnded;
        throw new IOException("control_session_unavailable:" + (ended is { } old && old.token == token && old.owner == owner ? old.reason : "session_mismatch_or_replaced"));
    }
    private Task<JsonObject> Capture(Control c, JsonNode options)
    {
        var adjusted = (JsonObject)options.DeepClone();
        var peer = manager.CurrentSessions().FirstOrDefault(s => s.PeerID == c.Owner);
        if (peer is not null && peer.Capabilities.Contains("ble") && !peer.Capabilities.Contains("tcp") && !peer.Capabilities.Contains("quic"))
            adjusted["_transport_jpeg"] = true;
        return captureWithOptions is null ? screenshot(c.Screen) : captureWithOptions(c.Screen, adjusted, () => control?.Token == c.Token && Unavailable(c) is null);
    }
    private async Task<JsonObject> Observe(JsonNode a, string owner)
    {
        ValidateObservationOptions(a);
        var c = Checked(a, owner);
        var started = System.Diagnostics.Stopwatch.StartNew();
        var image = await Capture(c, a);
        c = Checked(a, owner);
        c.Observation = Guid.NewGuid().ToString("D");
        c.Width = image["width"]!.GetValue<int>();
        c.Height = image["height"]!.GetValue<int>();
        c.Region = image["normalized_capture_region"]?.DeepClone() ?? Obj(("x", 0), ("y", 0), ("width", 1), ("height", 1));
        c.Expires = utcNow().AddSeconds(c.IdleSeconds);
        c.LastCapturedAt = image["captured_at"]?.DeepClone();
        var state = image["input_state"]?.DeepClone() as JsonObject ?? inputState?.Invoke();
        if (state is not null)
        {
            state["cursor_position_screenshot"] = MapCursor(state["cursor_position"], image);
            c.LastWindowID = state["foreground_window"]?["window_id"]?.GetValue<string>();
        }
        return Obj(("peer_id", id), ("control_session_id", c.Token), ("screen_id", c.Screen.Id), ("observation_id", c.Observation), ("screenshot", image), ("control_mode", "user_mouse"), ("input_sharing_isolated", true), ("coordinate_space", "screenshot_pixels"), ("coordinate_transform", Coordinates(image)), ("input_state", state), ("analysis", image["analysis"]), ("observation_duration_ms", started.Elapsed.TotalMilliseconds), ("control_session_idle_timeout_ms", c.IdleSeconds * 1000), ("control_session_expires_at", c.Expires.ToString("O")));
    }
    private async Task<JsonNode> Execute(string operation, JsonNode a, string owner, string? requestID = null)
    {
        activity();
        if (operation == "info")
        {
            if (!AllowComputer && !AllowFiles)
                throw new IOException("access_disabled");
            var result = info();
            result["peer_id"] = id;
            result["name"] = name;
            result["screens"] = JsonSerializer.SerializeToNode(screens(), Json);
            result["allow_computer"] = AllowComputer;
            result["allow_files"] = AllowFiles;
            result["control_state"] = ControlState(owner, result);
            if (Flag(a, "read_screen"))
            {
                if (!AllowComputer)
                    throw new IOException("computer_access_disabled");
                ValidateObservationOptions(a);
                var screen = screens().FirstOrDefault(s => a["screen_id"] is null || s.Id == S(a, "screen_id")) ?? throw new IOException("screen_unavailable");
                var image = captureWithOptions is null ? await screenshot(screen) : await captureWithOptions(screen, a, () => !stopped && AllowComputer);
                result["observation"] = Obj(("screenshot", image), ("analysis", image["analysis"]), ("input_state", image["input_state"]), ("coordinate_transform", Coordinates(image)), ("read_only", true));
            }
            return result;
        }
        if (operation is "prepare_files" or "paste_files" or "transfers" or "transfer_action")
        {
            if (!AllowFiles || files is null)
                throw new IOException("file_access_disabled");
            switch (operation)
            {
                case "prepare_files":
                    var paths = (a["paths"] as JsonArray)?.Select(v => v!.GetValue<string>()).ToArray() ?? [];
                    if (paths.Length is < 1 or > 100 || paths.Any(p => !Path.IsPathFullyQualified(p)))
                        throw new IOException("absolute_source_paths_required");
                    await files.Copy(paths, false);
                    return Obj(("entry_id", clipboard.Current?.Id), ("source_peer_id", id));
                case "paste_files":
                    var source = S(a, "source_peer_id");
                    var entry = S(a, "entry_id");
                    var destination = S(a, "destination");
                    if (!Path.IsPathFullyQualified(destination) || !Directory.Exists(destination))
                        throw new IOException("existing_absolute_destination_directory_required");
                    if (source != id)
                        await clipboard.WaitForEntry(entry, source);
                    if (clipboard.Current?.Id != entry || clipboard.Current?.SourcePeerID != source)
                        throw new IOException("clipboard_changed");
                    return Obj(("peer_id", id), ("task_id", files.BeginPaste(destination)));
                case "transfers":
                    if (a["task_id"] is { } taskNode)
                    {
                        var task = files.Tasks.FirstOrDefault(t => t.Id == taskNode.GetValue<string>()) ?? throw new IOException("task_not_found");
                        return JsonSerializer.SerializeToNode(task, Json)!;
                    }
                    return JsonSerializer.SerializeToNode(files.Tasks, Json)!;
                default:
                    var key = S(a, "task_id");
                    if (!files.Tasks.Any(t => t.Id == key))
                        throw new IOException("task_not_found");
                    switch (S(a, "action"))
                    {
                        case "pause":
                            files.Pause(key);
                            break;
                        case "cancel":
                            files.Cancel(key);
                            break;
                        case "resume":
                        case "retry":
                            _ = files.Resume(key);
                            break;
                        default:
                            throw new IOException("invalid_transfer_action");
                    }
                    return Obj(("task_id", key), ("accepted", true));
            }
        }
        if (!AllowComputer)
            throw new IOException("computer_access_disabled");
        switch (operation)
        {
            case "status":
                var status = Checked(a, owner);
                return Obj(("active", true), ("busy", status.Busy), ("latest_observation_id", status.Observation.Length == 0 ? null : status.Observation), ("last_captured_at", status.LastCapturedAt), ("last_action", status.LastResult), ("input_state", inputState?.Invoke()), ("lease_remaining_ms", Math.Max(0, (status.Expires - utcNow()).TotalMilliseconds)), ("control_session_expires_at", status.Expires.ToString("O")), ("renews_lease", false));
            case "open":
                ValidateObservationOptions(a);
                var idleMilliseconds = Integer(a, "control_session_idle_timeout_ms", IdleTimeoutSeconds * 1000, 15000, 600000);
                PruneUnavailableControl();
                EnsureCanOpen(owner);
                if (a["control_mode"] is not null && S(a, "control_mode") != "user_mouse")
                    throw new IOException("control_mode_unsupported");
                var selected = a["screen_id"] is { } requested ? screens().FirstOrDefault(s => s.Id == requested.GetValue<string>()) : screens().FirstOrDefault(s => s.Primary) ?? screens().FirstOrDefault();
                if (selected is null)
                    throw new IOException("screen_unavailable");
                control = new(Guid.NewGuid().ToString("D"), owner, manager.CurrentSessions().FirstOrDefault(s => s.PeerID == owner)?.SessionID, selected, suspend(), utcNow());
                if (requestID is not null && manager.CurrentSessions().FirstOrDefault(s => s.PeerID == owner)?.Capabilities.Contains("computer-open-ack-v1") == true)
                    control.OpenRequest = requestID;
                if (a["control_session_idle_timeout_ms"] is not null)
                {
                    control.IdleSeconds = idleMilliseconds / 1000.0;
                    control.Expires = utcNow().AddSeconds(control.IdleSeconds);
                }
                if (a["client_id"]?.GetValue<string>() is { } client && Guid.TryParse(client, out _))
                {
                    control.ClientID = client;
                    control.ClientName = (a["client_name"]?.GetValue<string>() ?? "MCP client")[..Math.Min(80, (a["client_name"]?.GetValue<string>() ?? "MCP client").Length)];
                }
                diagnostic($"ComputerUseStarted idleSeconds={control.IdleSeconds}");
                try
                {
                    controlChanged(true, "opened");
                    return await Observe(OpenArguments(a, control.Token), owner);
                }
                catch { EndControl("capture_failed"); throw; }
            case "observe":
                if (control?.Busy == true)
                    throw new IOException("computer_busy");
                return await Observe(a, owner);
            case "close":
                Checked(a, owner);
                EndControl();
                return Obj(("closed", true));
            case "actions":
                return await Actions(a, owner);
            default:
                throw new IOException("unknown_operation");
        }
    }
    private static JsonObject OpenArguments(JsonNode a, string token)
    {
        var result = (JsonObject)a.DeepClone();
        result["control_session_id"] = token;
        return result;
    }
    private async Task<JsonObject> Actions(JsonNode a, string owner)
    {
        var c = Checked(a, owner);
        var request = a["request_id"]?.GetValue<string>() ?? Guid.NewGuid().ToString("D");
        if (!Guid.TryParse(request, out _))
            throw new IOException("request_id_must_be_uuid");
        var body = (JsonObject)a.DeepClone();
        foreach (var key in new[] { "peer_id", "control_session_id", "observation_id", "request_id" })
            body.Remove(key);
        var signature = body.ToJsonString();
        if (c.Completed.TryGetValue(request, out var previous))
        {
            if (previous.signature != signature)
                throw new IOException("request_id_reused_with_different_actions");
            return (JsonObject)previous.result.DeepClone();
        }
        if (c.Busy)
            throw new ComputerToolException("computer_busy", Obj(("code", "computer_busy"), ("retryable", true), ("next_step", "wait_then_observe"), ("input_outcome", "not_attempted")));
        if (c.Observation != S(a, "observation_id"))
            throw new ComputerToolException("observation_id_mismatch", Obj(("code", "observation_id_mismatch"), ("retryable", true), ("next_step", "observe_then_issue_new_request"), ("expected_observation_id", c.Observation), ("input_outcome", "not_attempted")));
        if (a["actions"] is not JsonArray actions || actions.Count is < 1 or > 20)
            throw new IOException("invalid_action_batch_1_to_20_required");
        ValidateObservationOptions(a);
        ValidateObservationBounds(a, c.Width, c.Height);
        var settle = Integer(a, "settle_ms", 100, 0, 5000);
        var checkpoint = Integer(a, "checkpoint_after", actions.Count, 1, 20);
        if (a["expected_window_id"] is not null && (a["expected_window_id"] is not JsonValue ew || !ew.TryGetValue<string>(out var window) || window.Length == 0))
            throw new IOException("expected_window_id_must_be_nonempty_string");
        ValidateBoolean(a, "require_same_window");
        foreach (var action in actions)
            Validate(action!, c);
        if (actions.Sum(action => N(action, action?["type"]?.GetValue<string>() == "wait" ? "milliseconds" : "duration_ms")) + (a["settle_ms"] is null ? 0 : settle) > 30000)
            throw new IOException("batch_wait_exceeds_30000_ms");
        var expected = a["expected_window_id"]?.GetValue<string>() ?? (Flag(a, "require_same_window") ? c.LastWindowID : null);
        if (Flag(a, "require_same_window") && expected is null)
            throw new IOException("foreground_window_identity_unavailable");
        c.Busy = true;
        c.Observation = "";
        c.Expires = utcNow().AddSeconds(Math.Max(c.IdleSeconds, 60));
        var started = System.Diagnostics.Stopwatch.StartNew();
        var count = 0;
        Exception? failure = null;
        var steps = new JsonArray();
        foreach (var action in actions.Take(checkpoint))
        {
            var stepStart = System.Diagnostics.Stopwatch.StartNew();
            injectionAttempted = false;
            successfulInjectionCalls = 0;
            activeExpectedWindow = Flag(action!, "allow_window_change") ? null : expected;
            var index = count;
            try
            {
                Checked(a, owner);
                CheckWindow(expected, Flag(action!, "allow_window_change"));
                await Apply(action!, c, Flag(action!, "allow_window_change") ? null : expected);
                count++;
                var step = Obj(("index", index), ("type", action!["type"]), ("status", "completed"), ("duration_ms", stepStart.Elapsed.TotalMilliseconds), ("injection_started", injectionAttempted), ("successful_injection_calls", successfulInjectionCalls));
                if (Flag(a, "step_images") && index < 3)
                    step["screenshot"] = await Capture(Checked(a, owner), Obj(("thumbnail_max_dimension", 320), ("include_ocr", false), ("include_controls", false)));
                steps.Add(step);
            }
            catch (Exception e) { marker(c.Screen, 0, 0, "cancel"); failure = e; var details = ErrorDetails(e); details["input_outcome"] = injectionAttempted ? "partial_or_unknown" : "not_attempted"; steps.Add(Obj(("index", index), ("type", action?["type"]), ("status", "interrupted"), ("duration_ms", stepStart.Elapsed.TotalMilliseconds), ("injection_started", injectionAttempted), ("successful_injection_calls", successfulInjectionCalls), ("error_details", details))); break; }
        }
        if (control is null || control.Token == c.Token)
            ReleaseHeld();
        var result = Obj(("request_id", request), ("executed_actions", count), ("remaining_actions", actions.Count - count), ("execution_status", failure is not null ? "interrupted" : count < actions.Count ? "checkpoint" : "injected"), ("step_results", steps));
        if (failure is not null)
        {
            result["error"] = failure.Message;
            result["error_details"] = steps.Last()!["error_details"]!.DeepClone();
        }
        try
        {
            await CheckedDelay(settle, c);
            result["observation"] = await Observe(a, owner);
        }
        catch (Exception e) { result["observation_error"] = e.Message; result["observation_error_details"] = ErrorDetails(e); }
        result["action_to_observation_ms"] = started.Elapsed.TotalMilliseconds;
        if (control?.Token == c.Token)
        {
            c.Busy = false;
            c.LastResult = Obj(("request_id", request), ("execution_status", result["execution_status"]), ("executed_actions", count), ("error", result["error"]), ("action_to_observation_ms", result["action_to_observation_ms"]));
            if (c.Completed.Count >= 4)
                c.Completed.Clear();
            c.Completed[request] = (signature, (JsonObject)result.DeepClone());
        }
        return result;
    }
    private bool injectionAttempted; private int successfulInjectionCalls; private string? activeExpectedWindow;
    private void SendInput(CapturedInput value, ScreenGeometry? screen, double x, double y)
    {
        CheckWindow(activeExpectedWindow);
        if (inputState?.Invoke()["input_injection_blocked"]?.GetValue<bool>() == true)
            throw new IOException("input_blocked_by_integrity_level:restart_ShareMouse_as_administrator");
        injectionAttempted = true;
        inject(value, screen, x, y);
        successfulInjectionCalls++;
    }
    private void CheckWindow(string? expected, bool allow = false)
    {
        if (expected is not null && !allow && inputState?.Invoke()["foreground_window"]?["window_id"]?.GetValue<string>() != expected)
            throw new IOException("target_window_changed");
    }
    private async Task CheckedDelay(int milliseconds, Control c, string? expected = null)
    {
        for (var remaining = milliseconds; ;)
        {
            Checked(Obj(("control_session_id", c.Token)), c.Owner);
            CheckWindow(expected);
            if (remaining <= 0)
                return;
            var step = Math.Min(50, remaining);
            await Task.Delay(step);
            remaining -= step;
        }
    }
    private static (double x, double y) Point(JsonNode a, Control c)
    {
        if (a["x"] is null || a["y"] is null)
            throw new IOException("coordinates_required");
        var x = N(a, "x");
        var y = N(a, "y");
        if (!double.IsFinite(x) || !double.IsFinite(y) || x < 0 || y < 0 || x >= c.Width || y >= c.Height)
            throw new IOException("coordinate_outside_observation");
        return (N(c.Region, "x") + x / c.Width * N(c.Region, "width", 1), N(c.Region, "y") + y / c.Height * N(c.Region, "height", 1));
    }
    private static readonly Dictionary<string, string> Aliases = new() { ["CTRL"] = "ControlLeft", ["CONTROL"] = "ControlLeft", ["ALT"] = "AltLeft", ["OPTION"] = "AltLeft", ["SHIFT"] = "ShiftLeft", ["CMD"] = "MetaLeft", ["COMMAND"] = "MetaLeft", ["WIN"] = "MetaLeft", ["META"] = "MetaLeft", ["ESC"] = "Escape", ["RETURN"] = "Enter", ["ENTER"] = "Enter", ["SPACE"] = "Space" };
    private static string Key(string s) => Aliases.TryGetValue(s.ToUpperInvariant(), out var alias) ? alias : s.Length == 1 && char.IsAscii(s[0]) ? char.IsDigit(s[0]) ? "Digit" + s : "Key" + s.ToUpperInvariant() : Keys.FirstOrDefault(k => k.Equals(s, StringComparison.OrdinalIgnoreCase)) ?? s;
    private static readonly HashSet<string> Keys = new(Enumerable.Range(65, 26).Select(i => "Key" + (char)i).Concat(Enumerable.Range(0, 10).Select(i => "Digit" + i)).Concat(Enumerable.Range(1, 12).Select(i => "F" + i)).Concat(new[] { "Enter", "Tab", "Space", "Backspace", "Escape", "Delete", "Home", "End", "PageUp", "PageDown", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "ControlLeft", "ControlRight", "AltLeft", "AltRight", "ShiftLeft", "ShiftRight", "MetaLeft", "MetaRight", "Minus", "Equal", "BracketLeft", "BracketRight", "Backslash", "Semicolon", "Quote", "Comma", "Period", "Slash", "Backquote" }));
    private static void Validate(JsonNode a, Control c)
    {
        switch (S(a, "type"))
        {
            case "click":
            case "double_click":
            case "move":
            case "scroll":
                Point(a, c);
                if (S(a, "type") == "scroll" && (a["delta_y"] is null || !double.IsFinite(N(a, "delta_y")) || Math.Abs(N(a, "delta_y")) > 10000 || Math.Abs(N(a, "delta_x")) > 10000))
                    throw new IOException("invalid_scroll");
                break;
            case "drag":
                if (a["path"] is not JsonArray path || path.Count is < 2 or > 100)
                    throw new IOException("invalid_drag_path");
                foreach (var p in path)
                    Point(p!, c);
                break;
            case "focus_application":
                if (S(a, "application").Length > 256)
                    throw new IOException("application_name_required");
                break;
            case "keypress":
            case "key_hold":
                if (a["keys"] is not JsonArray keys || keys.Count is < 1 or > 8 || keys.Any(k => k is null || !Keys.Contains(Key(k.GetValue<string>()))))
                    throw new IOException("unsupported_key");
                break;
            case "move_relative":
                if (a["dx"] is null || a["dy"] is null || !double.IsFinite(N(a, "dx")) || !double.IsFinite(N(a, "dy")) || Math.Abs(N(a, "dx")) > 10000 || Math.Abs(N(a, "dy")) > 10000)
                    throw new IOException("invalid_relative_movement");
                Integer(a, "duration_ms", 0, 0, 5000);
                Integer(a, "steps", 1, 1, 100);
                break;
            case "type":
                if (System.Text.Encoding.UTF8.GetByteCount(S(a, "text")) > 131072)
                    throw new IOException("invalid_text");
                break;
            case "wait":
                var ms = N(a, "milliseconds", double.NaN);
                if (!double.IsFinite(ms) || Math.Truncate(ms) != ms || ms < 0 || ms > 30000)
                    throw new IOException("wait_must_be_integer_0_to_30000_ms");
                break;
            default:
                throw new IOException("unsupported_action");
        }
        if (S(a, "type") == "key_hold")
            Integer(a, "duration_ms", 0, 1, 5000);
        ValidateBoolean(a, "allow_window_change");
        if (a["button"] is { } button && button.GetValue<string>() is not ("left" or "right" or "middle"))
            throw new IOException("unsupported_button");
    }
    // Preview never injects intermediate positions or changes an input path.
    private async Task Preview(JsonNode a, Control c, string? expected)
    {
        var (x, y) = Point(a, c);
        var milliseconds = Math.Clamp(pointerPreview(c.Screen, x, y, S(a, "type")), 0, 360);
        if (milliseconds > 0)
            await CheckedDelay(milliseconds, c, expected);
    }
    private void Move(JsonNode a, Control c, string kind)
    {
        var (x, y) = Point(a, c);
        SendInput(new("move"), c.Screen, x, y);
        marker(c.Screen, x, y, kind);
    }
    private async Task Apply(JsonNode a, Control c, string? expected)
    {
        var button = a["button"]?.GetValue<string>() switch
        {
            "right" => 1,
            "middle" => 2,
            _ => 0
        };
        switch (S(a, "type"))
        {
            case "move":
                await Preview(a, c, expected);
                Move(a, c, "move");
                break;
            case "click":
            case "double_click":
                await Preview(a, c, expected);
                Move(a, c, "position");
                for (var i = 0; i < (S(a, "type") == "double_click" ? 2 : 1); i++)
                {
                    if (control?.Token != c.Token)
                        throw new IOException("control_interrupted");
                    heldButtons.Add(button);
                    SendInput(new("buttonDown", Button: button), null, 0, 0);
                    SendInput(new("buttonUp", Button: button), null, 0, 0);
                    heldButtons.Remove(button);
                    var point = Point(a, c);
                    marker(c.Screen, point.x, point.y, "click");
                    await Task.Delay(40);
                }
                break;
            case "drag":
                var path = (JsonArray)a["path"]!;
                Move(path[0]!, c, "drag");
                heldButtons.Add(button);
                SendInput(new("buttonDown", Button: button), null, 0, 0);
                foreach (var p in path.Skip(1))
                {
                    if (control?.Token != c.Token)
                        throw new IOException("control_interrupted");
                    CheckWindow(expected);
                    Move(p!, c, "drag");
                    await Task.Delay(16);
                }
                SendInput(new("buttonUp", Button: button), null, 0, 0);
                heldButtons.Remove(button);
                break;
            case "scroll":
                await Preview(a, c, expected);
                Move(a, c, "scroll");
                SendInput(new("scroll", DeltaX: N(a, "delta_x"), DeltaY: N(a, "delta_y")), null, 0, 0);
                break;
            case "move_relative":
                marker(c.Screen, 0, 0, "relative");
                var duration = Integer(a, "duration_ms", 0, 0, 5000);
                var stepCount = Integer(a, "steps", Math.Max(1, Math.Min(100, duration / 16)), 1, 100);
                for (var index = 0; index < stepCount; index++)
                {
                    Checked(Obj(("control_session_id", c.Token)), c.Owner);
                    CheckWindow(expected);
                    SendInput(new("relativeMove", DeltaX: Math.Round(N(a, "dx") * (index + 1) / stepCount) - Math.Round(N(a, "dx") * index / stepCount), DeltaY: Math.Round(N(a, "dy") * (index + 1) / stepCount) - Math.Round(N(a, "dy") * index / stepCount)), c.Screen, 0, 0);
                    if (duration > 0)
                        await CheckedDelay(duration / stepCount + (index < duration % stepCount ? 1 : 0), c, expected);
                }
                break;
            case "focus_application":
                await focusApplication(S(a, "application"));
                Checked(Obj(("control_session_id", c.Token)), c.Owner);
                break;
            case "keypress":
            case "key_hold":
                var keys = ((JsonArray)a["keys"]!).Select(k => Key(k!.GetValue<string>())).ToArray();
                foreach (var k in keys)
                {
                    heldKeys.Add(k);
                    SendInput(new("keyDown", k), null, 0, 0);
                }
                if (S(a, "type") == "key_hold")
                    await CheckedDelay(Integer(a, "duration_ms", 0, 1, 5000), c, expected);
                foreach (var k in keys.Reverse())
                {
                    SendInput(new("keyUp", k), null, 0, 0);
                    heldKeys.Remove(k);
                }
                break;
            case "type":
                var part = new System.Text.StringBuilder();
                var length = 0;
                foreach (var rune in S(a, "text").EnumerateRunes())
                {
                    if (length + rune.Utf8SequenceLength > 4096)
                    {
                        SendInput(new("text", Text: part.ToString()), null, 0, 0);
                        part.Clear();
                        length = 0;
                    }
                    part.Append(rune);
                    length += rune.Utf8SequenceLength;
                }
                if (part.Length > 0)
                    SendInput(new("text", Text: part.ToString()), null, 0, 0);
                break;
            case "wait":
                await CheckedDelay((int)N(a, "milliseconds"), c, expected);
                break;
        }
    }
    public Task<JsonNode> Tool(string name, JsonNode a) => OnUI(() => ToolCore(name, a));
    private async Task<JsonNode> ToolCore(string tool, JsonNode a)
    {
        activity();
        if (tool == "list_computers")
        {
            var peers = new JsonArray(Obj(("peer_id", id), ("name", name), ("platform", info()["platform"]), ("local", true)));
            foreach (var s in manager.CurrentSessions())
                peers.Add(Obj(("peer_id", s.PeerID), ("name", s.Name), ("platform", s.RemotePlatform), ("capabilities", s.Capabilities), ("local", false)));
            return peers;
        }
        if (tool == "send_files")
        {
            var prepared = await Call(S(a, "source_peer_id"), "prepare_files", a);
            var receive = (JsonObject)a.DeepClone();
            receive["entry_id"] = prepared["entry_id"]!.DeepClone();
            receive["source_peer_id"] = prepared["source_peer_id"]!.DeepClone();
            return await Call(S(a, "target_peer_id"), "paste_files", receive);
        }
        var operation = tool switch
        {
            "get_computer_info" => "info",
            "get_control_status" => "status",
            "open_computer" => "open",
            "observe_computer" => "observe",
            "computer_action" => "actions",
            "release_input" or "close_computer" => "close",
            "list_transfers" or "get_transfer" => "transfers",
            "control_transfer" => "transfer_action",
            _ => throw new IOException("unknown_tool")
        };
        return await Call(S(a, "peer_id"), operation, a);
    }
    public static bool Flag(JsonNode a, string key) => a[key] is JsonValue value && value.TryGetValue<bool>(out var flag) && flag;
    public static void ValidateBoolean(JsonNode a, string key)
    {
        if (a[key] is not null && (a[key] is not JsonValue value || !value.TryGetValue<bool>(out _)))
            throw new IOException("invalid_" + key);
    }
    public static int Integer(JsonNode a, string key, int fallback, int minimum, int maximum)
    {
        if (a[key] is null)
        {
            if (fallback < minimum || fallback > maximum)
                throw new IOException("missing_" + key);
            return fallback;
        }
        var value = N(a, key, double.NaN);
        if (!double.IsFinite(value) || value != Math.Truncate(value) || value < minimum || value > maximum)
            throw new IOException("invalid_" + key);
        return (int)value;
    }
    public static void ValidateObservationOptions(JsonNode a)
    {
        foreach (var key in new[] { "include_ocr", "include_controls", "wait_for_stable", "mark_cursor", "step_images", "text_only", "read_screen" })
            ValidateBoolean(a, key);
        Integer(a, "stability_timeout_ms", 2000, 200, 5000);
        Integer(a, "stability_interval_ms", 200, 100, 1000);
        Integer(a, "stability_samples", 3, 2, 5);
        Integer(a, "max_dimension", 0, 0, 16384);
        Integer(a, "jpeg_quality", 80, 1, 100);
        if (a["image_format"] is not null && S(a, "image_format") is not ("png" or "jpeg"))
            throw new IOException("invalid_image_format");
        if (Flag(a, "text_only") && (Flag(a, "wait_for_stable") || Flag(a, "mark_cursor") || a["preview_point"] is not null))
            throw new IOException("text_only_incompatible_with_image_analysis");
        if (a["capture_region"] is { } r)
        {
            foreach (var field in new[] { "x", "y", "width", "height" })
            {
                var n = N(r, field, double.NaN);
                if (!double.IsFinite(n) || n < 0 || n > 1)
                    throw new IOException("invalid_capture_region");
            }
            if (N(r, "width") <= 0 || N(r, "height") <= 0 || N(r, "x") + N(r, "width") > 1.0000001 || N(r, "y") + N(r, "height") > 1.0000001)
                throw new IOException("invalid_capture_region");
        }
        Integer(a, "max_controls", 50, 1, 100);
        Integer(a, "max_ocr_results", 100, 1, 200);
        if (a["stability_threshold"] is not null)
        {
            var n = N(a, "stability_threshold", double.NaN);
            if (!double.IsFinite(n) || n < 0 || n > 25)
                throw new IOException("invalid_stability_threshold");
        }
        foreach (var key in new[] { "ocr_region", "stability_region" })
            if (a[key] is not null)
                foreach (var field in new[] { "x", "y", "width", "height" })
                {
                    var n = N(a[key], field, double.NaN);
                    if (!double.IsFinite(n) || n < (field is "x" or "y" ? 0 : 1) || n > 10000)
                        throw new IOException("invalid_" + key);
                }
        foreach (var key in new[] { "preview_point", "control_point" })
            if (a[key] is not null)
                foreach (var field in new[] { "x", "y" })
                {
                    var n = N(a[key], field, double.NaN);
                    if (!double.IsFinite(n) || n < 0 || n > 10000)
                        throw new IOException("invalid_" + key);
                }
        if (a["ocr_language"] is not null && (a["ocr_language"] is not JsonValue v || !v.TryGetValue<string>(out var language) || language.Length == 0 || System.Text.Encoding.UTF8.GetByteCount(language) > 64))
            throw new IOException("invalid_ocr_language");
    }
    public static void ValidateObservationBounds(JsonNode a, int width, int height)
    {
        foreach (var key in new[] { "ocr_region", "stability_region" })
            if (a[key] is { } r && (N(r, "x") + N(r, "width") > width || N(r, "y") + N(r, "height") > height))
                throw new IOException("analysis_region_outside_observation");
        foreach (var key in new[] { "preview_point", "control_point" })
            if (a[key] is { } point && (N(point, "x") >= width || N(point, "y") >= height))
                throw new IOException(key + "_outside_observation");
    }
    public static JsonObject Coordinates(JsonNode image)
    {
        var rect = image["desktop_bounds"];
        if (rect is null)
            return Obj(("status", "unavailable"), ("screenshot_size", Obj(("width", image["width"]), ("height", image["height"]))));
        double dw = N(rect, "width"), dh = N(rect, "height"), sw = N(image, "width"), sh = N(image, "height");
        if (dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0)
            return Obj(("status", "unavailable"));
        return Obj(("status", "available"), ("screenshot_size", Obj(("width", image["width"]), ("height", image["height"]))), ("desktop_bounds", rect), ("desktop_coordinate_space", image["desktop_coordinate_space"]), ("display_pixel_size", image["display_pixel_size"]), ("normalized_capture_region", image["normalized_capture_region"]), ("desktop_origin", Obj(("x", rect["x"]), ("y", rect["y"]))), ("screenshot_pixels_per_desktop_unit", Obj(("x", sw / dw), ("y", sh / dh))), ("desktop_units_per_screenshot_pixel", Obj(("x", dw / sw), ("y", dh / sh))));
    }
    public static JsonObject? MapCursor(JsonNode? cursor, JsonNode image)
    {
        var rect = image["desktop_bounds"];
        if (cursor?["x"] is null || cursor["y"] is null || rect is null)
            return null;
        double x = N(cursor, "x"), y = N(cursor, "y"), left = N(rect, "x"), top = N(rect, "y"), width = N(rect, "width"), height = N(rect, "height");
        if (width <= 0 || height <= 0)
            return null;
        var inside = x >= left && y >= top && x < left + width && y < top + height;
        return Obj(("coordinate_space", "screenshot_pixels"), ("inside_screen", inside), ("x", inside ? (x - left) / width * N(image, "width") : (double?)null), ("y", inside ? (y - top) / height * N(image, "height") : (double?)null));
    }
    public static JsonObject ErrorDetails(Exception error)
    {
        if (error is ComputerToolException { Details: { } details })
            return (JsonObject)details.DeepClone();
        var code = error.Message.Split(':')[0];
        if (code == "control_session_unavailable")
            code = error.Message.Split(':').Skip(1).FirstOrDefault() ?? code;
        var retryable = code is "computer_busy" or "observation_id_mismatch" or "target_window_changed" or "lease_expired" or "computer_control_in_use" or "desktop_locked_or_unavailable";
        var next = code switch
        {
            "user_exit" => "wait_for_user_authorization",
            "computer_busy" => "wait_then_observe",
            "computer_control_in_use" => "use_existing_session_or_wait_for_release",
            "desktop_locked_or_unavailable" => "wait_for_user_to_unlock_desktop",
            "input_permission_missing" => "ask_user_to_grant_input_permission",
            "screen_capture_permission_missing" => "ask_user_to_grant_screen_capture_permission",
            "lease_expired" => "open_new_session",
            "input_blocked_by_integrity_level" => "ask_user_to_restart_as_administrator",
            _ => retryable ? "observe_then_issue_new_request" : "inspect_error_before_retry"
        };
        return Obj(("code", code), ("message", error.Message), ("retryable", retryable), ("next_step", next));
    }

}

public sealed class ComputerToolException(string message, JsonObject? details) : IOException(message)
{
    public JsonObject? Details { get; } = details;
}
