using System.Text;
using System.Text.Json;
using ShareMouse.Core;

namespace ShareMouse.Network;

// Calls into a platform adapter are serialized on the application's input context.
public sealed class InputService : IDisposable
{
    public bool ScreenCrossingEnabled { get; set; } = true;
    public Func<string, double>? PointerSensitivity
    {
        get; set;
    }
    public Func<string, (bool Horizontal, bool Vertical)>? ScrollInversion
    {
        get; set;
    }
    public Func<string, double>? HorizontalScrollAngle
    {
        get; set;
    }
    private bool fnEnabled = true, functionKeysEnabled = true;
    private readonly Dictionary<string, (bool Fn, bool Functions)> sourceOptions = new();
    private readonly Dictionary<string, string> physicalFunctionSlots = new();
    private readonly Dictionary<string, Dictionary<string, string>> remoteFunctionSlots = new();
    public string ResolveSourceFunction(string key, string? slot) => KeyboardMapping.Map(key, platform,
        Active is { } screen && screen.PeerID != id ? platforms.GetValueOrDefault(screen.PeerID, "unknown") : platform, Config,
        functionKey: KeyboardMapping.MacFunction, fnEnabled: fnEnabled, functionKeysEnabled: functionKeysEnabled, functionSlot: slot);
    public bool SharingRemoteFunctions => Enabled && Active is { } screen && screen.PeerID != id && functionPeers.Contains(screen.PeerID);
    public void ConfigureKeyboard(bool fn, bool functions)
    {
        if (fnEnabled == fn && functionKeysEnabled == functions)
            return;
        fnEnabled = fn;
        functionKeysEnabled = functions;
        heldSnapshots.Clear();
        SendHeld();
    }
    private double Gain(string peer)
    {
        var gain = peer == id ? 1 : PointerSensitivity?.Invoke(peer) ?? 1;
        return double.IsFinite(gain) ? Math.Clamp(gain, 0.1, 4) : 1;
    }
    private readonly string id, platform;
    private readonly SessionManager manager;
    private readonly SynchronizationContext context;
    private readonly Action<CapturedInput, ScreenGeometry?, double, double> inject;
    private readonly Action<bool, bool> restrict;
    private readonly Action<string> status;
    private readonly Action<string> log;
    private readonly System.Threading.Timer timer;
    private SharedGroup? group;
    private HashSet<string> online = new();
    private HashSet<string> inputPeers = new();
    public Func<bool>? RelativePointerCaptured
    {
        get; set;
    }
    public Func<string, string?>? FunctionKey
    {
        get; set;
    }
    private HashSet<string> relativePeers = [];
    private HashSet<string> functionPeers = [];
    private string? relativePeer, relativeReported;
    private ulong relativeEpoch;
    private double relativeX, relativeY;
    private bool localRelative;
    private long relativeReportAt;
    private readonly Dictionary<string, (ulong Epoch, double X, double Y)> relativeReceived = new();
    private static bool MotionType(string type) => type is "move" or "relative-move";
    private void ReportRelativeMode()
    {
        if (!Enabled || Active is not { } screen || pointer is not { } point || screen.PeerID != id || point.OwnerPeerID == id || !relativePeers.Contains(point.OwnerPeerID))
        {
            if (localRelative)
                try
                {
                    inject(new("relativeEnd"), Active, 0, 0);
                }
                catch { }
            localRelative = false;
            relativeReported = null;
            return;
        }
        var captured = RelativePointerCaptured?.Invoke() == true;
        var key = $"{point.OwnerPeerID}|{point.Epoch}|{screen.Id}|{captured}";
        var now = Environment.TickCount64;
        if (key == relativeReported && now - relativeReportAt < 2000)
            return;
        relativeReported = key;
        relativeReportAt = now;
        if (localRelative != captured)
            try
            {
                inject(new(captured ? "relativeBegin" : "relativeEnd"), screen, 0, 0);
            }
            catch { Pause(); return; }
        localRelative = captured;
        if (captured)
            renderTarget = null;
        var value = Packet("mouse-mode", point.OwnerPeerID);
        value.Command = captured ? "relative-on" : "relative-off";
        Queue(point.OwnerPeerID, value);
    }
    private void ReceiveMouseMode(string peer, InputPacket value)
    {
        if (!Enabled || !relativePeers.Contains(peer) || Active is not { } screen || screen.PeerID != peer || pointer?.OwnerPeerID != id || value.TargetPeerID != id || value.TargetScreenID != screen.Id || value.Pointer?.Epoch != pointer?.Epoch || value.Command is not ("relative-on" or "relative-off"))
            return;
        if (value.Command == "relative-off")
        {
            if (relativePeer is not null)
                log("InputRelativeModeEnded");
            relativePeer = null;
            return;
        }
        if (relativePeer == peer && relativeEpoch == pointer!.Epoch)
            return;
        relativePeer = peer;
        relativeEpoch = pointer!.Epoch;
        relativeX = relativeY = 0;
        motion.Remove(peer);
        pending.RemoveAll(p => p.Peer == peer && MotionType(p.Packet.Type));
        var start = Packet("relative-start", peer);
        start.DeltaX = start.DeltaY = 0;
        Queue(peer, start);
        log("InputRelativeModeStarted targetPeerId=" + peer);
    }
    private void ApplyRelative(string peer, InputPacket value, ScreenGeometry screen)
    {
        if (!relativePeers.Contains(peer) || screen.PeerID != id || value.Pointer is not { } point || !double.IsFinite(value.DeltaX) || !double.IsFinite(value.DeltaY) || Math.Abs(value.DeltaX) > 1e9 || Math.Abs(value.DeltaY) > 1e9)
            return;
        if (value.Type == "relative-start")
        {
            relativeReceived[peer] = (point.Epoch, value.DeltaX, value.DeltaY);
            renderTarget = null;
            try
            {
                inject(new("relativeReset"), screen, 0, 0);
            }
            catch { Pause(); }
            return;
        }
        if (!localRelative || !relativeReceived.TryGetValue(peer, out var old) || old.Epoch != point.Epoch)
            return;
        relativeReceived[peer] = (point.Epoch, value.DeltaX, value.DeltaY);
        var dx = value.DeltaX - old.X;
        var dy = value.DeltaY - old.Y;
        if (Math.Abs(dx) > 10000 || Math.Abs(dy) > 10000)
            return;
        try
        {
            inject(new("relativeMove", DeltaX: dx, DeltaY: dy), screen, 0, 0);
        }
        catch { Pause(); }
    }
    private HashSet<string> compactPeers = new(), scrollPeers = new(), contextPeers = new(), scrollFlowPeers = new();
    private readonly Dictionary<string, InputPacket> scroll = new();
    private CancellationTokenSource? scrollDelay;
    public Action? ResumeRequested
    {
        get; set;
    }
    private HashSet<string> blePeers = new(), bleCompactPeers = new();
    private readonly Dictionary<string, Dictionary<ulong, long>> bleSentAt = new();
    private readonly Dictionary<string, BleMotionWindow> bleWindows = new();
    private readonly List<double> bleAckMilliseconds = [];
    private long bleReportAt;
    private readonly Dictionary<string, HashSet<ulong>> outstanding = new();
    private readonly Dictionary<string, long> motionProgress = new();
    private readonly Dictionary<string, long> slowDeliveryReported = new();
    private readonly Dictionary<string, (ulong Sequence, ISessionTransport Transport)> acknowledgements = new();
    private readonly Dictionary<string, (PointerState Pointer, ulong Sequence)> receivedContexts = new();
    private int deliveryGeneration;
    private PointerState? renderFrom, rendered, renderTarget;
    private long renderAt;
    private long lastRemoteMotion;
    private System.Threading.Timer? highRateTimer;
    private long lastAckAt;
    private long receiveDelayReported, recoveryReported;
    private long dispatcherStallReported;
    public int CaptureRate
    {
        get; private set;
    }
    public int SendRate
    {
        get; private set;
    }
    private int capturedMoves, sentMoves;
    private readonly Dictionary<string, string> sessionIds = new();
    private readonly List<string> arrivals = new();
    private string[] priority = [];
    private HashSet<string> priorityRecipients = [];
    private PointerState? pointer;
    private readonly HashSet<string> physicalKeys = new();
    private readonly HashSet<int> physicalButtons = new();
    private readonly Dictionary<string, (string Screen, ulong Epoch, HashSet<string> Keys, HashSet<int> Buttons)> heldSnapshots = new();
    private readonly Dictionary<string, HashSet<string>> keys = new();
    private readonly Dictionary<string, Dictionary<string, string>> originalKeys = new();
    private readonly HashSet<string> commandKeys = new();
    private Dictionary<string, string> platforms = new();
    public Func<string, string, string?, Task<bool>>? CommandHandler
    {
        get; set;
    }
    public Func<CapturedInput, bool>? TargetKeyHandler
    {
        get; set;
    }
    public Func<string?>? ClipboardEntryID
    {
        get; set;
    }
    public Action? LocalClipboardCommand
    {
        get; set;
    }
    private KeyboardConfig? Config => group?.Configs.FirstOrDefault(c => c.Id == group.CurrentConfigID);
    private readonly Dictionary<string, HashSet<int>> buttons = new();
    private readonly Dictionary<string, ulong> received = new();
    private readonly Dictionary<string, long> heard = new();
    private readonly List<(string Peer, InputPacket Packet, long At)> pending = new();
    private ulong sequence;
    private long lastSnapshot, lastRate, stateReportAt, rejectionReportAt;
    private double noiseX, noiseY;
    private long noiseAt;
    private readonly Dictionary<string, InputPacket> motion = new();
    private CancellationTokenSource? motionDelay;
    private bool sending, disposed;
    private int generation;
    private Task capabilityUpdate = Task.CompletedTask;
    public bool Enabled
    {
        get; private set;
    }
    public PointerState? Pointer => pointer;
    private static readonly JsonSerializerOptions json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };
    public InputService(string id, string platform, SessionManager manager, SynchronizationContext context,
        Action<CapturedInput, ScreenGeometry?, double, double> inject, Action<bool, bool> restrict, Action<string> status, Action<string>? log = null)
    {
        this.id = id;
        this.platform = platform;
        this.manager = manager;
        this.context = context;
        this.inject = inject;
        this.restrict = restrict;
        this.status = status;
        this.log = log ?? (_ => { });
        manager.ReceiveWithTransport("input", (peer, bytes, transport) =>
        {
            var queued = System.Diagnostics.Stopwatch.GetTimestamp();
            context.Post(_ =>
            {
                var delay = System.Diagnostics.Stopwatch.GetElapsedTime(queued).TotalMilliseconds;
                if (delay > 50)
                {
                    manager.YieldBulkForInput(peer);
                    if (Environment.TickCount64 - receiveDelayReported > 2000)
                    {
                        receiveDelayReported = Environment.TickCount64;
                        this.log($"InputReceiveQueued transport={transport.Kind} delayMs={delay:F0}");
                    }
                }
                Receive(peer, bytes, transport);
            }, null);
            return Task.CompletedTask;
        });
        var watchdogPosted = 0;
        timer = new(_ =>
        {
            // A blocked native call must not leave a backlog of watchdog ticks behind it.
            if (Interlocked.Exchange(ref watchdogPosted, 1) != 0)
                return;
            context.Post(_ => { try { Tick(); } finally { Interlocked.Exchange(ref watchdogPosted, 0); } }, null);
        }, null, 100, 100);
    }
    public void Update(SharedGroup? value, string[] peers, SessionInfo[] sessions)
    {
        var oldBLE = blePeers;
        var oldInput = inputPeers;
        var old = online;
        online = peers.ToHashSet();
        platforms = sessions.ToDictionary(s => s.PeerID, s => s.RemotePlatform);
        blePeers = sessions.Where(s => s.Capabilities.Contains("ble") && (manager.BluetoothInputOnly || !s.Capabilities.Contains("tcp") && !s.Capabilities.Contains("quic"))).Select(s => s.PeerID).ToHashSet();
        bleCompactPeers = sessions.Where(s => s.Capabilities.Contains("ble-input-v2") && blePeers.Contains(s.PeerID)).Select(s => s.PeerID).ToHashSet();
        relativePeers = sessions.Where(s => s.Capabilities.Contains("relative-pointer-v1")).Select(s => s.PeerID).ToHashSet();
        functionPeers = sessions.Where(s => s.Capabilities.Contains("input-function-keys-v1")).Select(s => s.PeerID).ToHashSet();
        compactPeers = sessions.Where(s => s.Capabilities.Contains("compact-input")).Select(s => s.PeerID).ToHashSet();
        contextPeers = sessions.Where(s => s.Capabilities.Contains("compact-input-v3")).Select(s => s.PeerID).ToHashSet();
        scrollFlowPeers = sessions.Where(s => s.Capabilities.Contains("scroll-flow-v1")).Select(s => s.PeerID).ToHashSet();
        scrollPeers = sessions.Where(s => s.Capabilities.Contains("compact-scroll-v1")).Select(s => s.PeerID).ToHashSet();
        inputPeers = sessions.Where(s => s.Capabilities.Contains("input")).Select(s => s.PeerID).ToHashSet();
        foreach (var session in sessions)
        {
            var inputSession = session.SessionID + "|" + (session.RemoteInstanceID ?? "legacy");
            if (sessionIds.TryGetValue(session.PeerID, out var previous) && previous != inputSession)
            {
                bleSentAt.Remove(session.PeerID);
                ReleasePeer(session.PeerID);
                outstanding.Remove(session.PeerID);
                motionProgress.Remove(session.PeerID);
                slowDeliveryReported.Remove(session.PeerID);
                received.Remove(session.PeerID);
                receivedContexts.Remove(session.PeerID);
                heard.Remove(session.PeerID);
                if (Enabled && (pointer?.OwnerPeerID == session.PeerID || Active?.PeerID == session.PeerID))
                    Recover("对端已重新连接，输入状态已恢复");
                log("InputPeerRestarted peerId=" + session.PeerID);
            }
            sessionIds[session.PeerID] = inputSession;
        }
        foreach (var peer in old.Except(online))
        {
            bleSentAt.Remove(peer);
            ReleasePeer(peer);
            outstanding.Remove(peer);
            motionProgress.Remove(peer);
            slowDeliveryReported.Remove(peer);
            received.Remove(peer);
            receivedContexts.Remove(peer);
            heard.Remove(peer);
            arrivals.Remove(peer);
        }
        foreach (var session in sessions)
            if (!arrivals.Contains(session.PeerID))
                arrivals.Add(session.PeerID);
        if (!arrivals.Contains(id))
            arrivals.Insert(0, id);
        var oldConfig = Config;
        var previousGroup = group;
        var changed = group?.Id != value?.Id;
        group = value;
        if (!changed && pointer is { } current && previousGroup?.Layout.FirstOrDefault(s => s.Id == current.ScreenID) is { } before && group?.Layout.FirstOrDefault(s => s.Id == current.ScreenID) is { } after
            && (before.X != after.X || before.Y != after.Y || before.Scale != after.Scale || before.ScaleX != after.ScaleX || before.ScaleY != after.ScaleY || before.Rotation != after.Rotation || before.PixelWidth != after.PixelWidth || before.PixelHeight != after.PixelHeight))
        {
            if (before.PixelWidth != after.PixelWidth || before.PixelHeight != after.PixelHeight)
            {
                ReleaseAll();
                physicalKeys.Clear();
                physicalFunctionSlots.Clear();
                physicalButtons.Clear();
            }
            pointer = current with
            {
                X = after.X + (current.X - before.X) / before.Width * after.Width,
                Y = after.Y + (current.Y - before.Y) / before.Height * after.Height
            };
            if (Enabled && pointer.OwnerPeerID == id)
                Broadcast("control");
            MoveLocal();
        }
        if (!KeyboardMapping.Same(oldConfig, Config))
        {
            ReleaseAll();
            SendHeld();
        }
        if (changed)
        {
            Pause();
            pointer = null;
            received.Clear();
            receivedContexts.Clear();
        }
        if (group is null || online.Count < 2)
        {
            Pause();
            return;
        }
        if (group.LeaderID == id)
        {
            var next = priority.Where(online.Contains).Concat(arrivals.Where(online.Contains)).Distinct().ToArray();
            if (changed || !priority.SequenceEqual(next) || !priorityRecipients.SetEquals(inputPeers))
            {
                priority = next;
                priorityRecipients = inputPeers.ToHashSet();
                Broadcast("priority");
            }
        }
        if (Enabled && pointer is not null && !UsableScreens().Any(s => s.Id == pointer.ScreenID))
        {
            ReleaseAll();
            physicalKeys.Clear();
            physicalFunctionSlots.Clear();
            physicalButtons.Clear();
            var safe = UsableScreens().FirstOrDefault(s => s.PeerID == id && s.Primary) ?? UsableScreens().FirstOrDefault(s => s.Primary) ?? UsableScreens().FirstOrDefault();
            if (safe is null)
            {
                Pause();
                return;
            }
            pointer = PointerRouter.Center(safe, id, pointer.Epoch + 1);
            Broadcast("control");
            MoveLocal();
        }
        foreach (var peer in oldInput.Except(inputPeers).Where(_ => manager.BluetoothInputOnly))
        {
            ReleasePeer(peer);
            outstanding.Remove(peer);
            bleSentAt.Remove(peer);
            if (pointer?.OwnerPeerID == peer)
                Recover("蓝牙输入链路已断开，已释放本机控制", false);
        }
        if (Enabled && pointer?.OwnerPeerID == id && inputPeers.Except(oldInput).Any())
            Broadcast("control");
        if (!oldBLE.SetEquals(blePeers))
            RefreshInputRoute();
        if (Enabled)
            status(inputPeers.Count == 0 ? "等待对端输入就绪 · 本机输入可用" : "键鼠共享已启用 · 当前输入：" + (Active?.PeerID is { } target && target != id ? (blePeers.Contains(target) ? "蓝牙" : "Wi-Fi／网络") : "本机"));
        RestrictCursor();
    }
    private void DiscardContinuousDelivery()
    {
        deliveryGeneration++;
        motion.Clear();
        scroll.Clear();
        motionDelay?.Cancel();
        motionDelay = null;
        scrollDelay?.Cancel();
        scrollDelay = null;
        pending.RemoveAll(p => p.Packet.Type is "move" or "relative-move" or "scroll");
        outstanding.Clear();
        bleSentAt.Clear();
        bleWindows.Clear();
        motionProgress.Clear();
        slowDeliveryReported.Clear();
    }
    public void RefreshInputRoute()
    {
        DiscardContinuousDelivery();
        heldSnapshots.Clear();
        if (Enabled && pointer?.OwnerPeerID == id)
        {
            Broadcast("control");
            SendHeld();
        }
    }
    private ScreenGeometry[] UsableScreens() => group?.Layout.Where(s => online.Contains(s.PeerID) && (s.PeerID == id || inputPeers.Contains(s.PeerID))).ToArray() ?? [];
    private ScreenGeometry? Active => group?.Layout.FirstOrDefault(s => s.Id == pointer?.ScreenID);
    public async Task Enable(bool claimControl = true)
    {
        var round = ++generation;
        if (group is null || online.Count < 2)
            throw new IOException("Connect an online group first.");
        var screen = UsableScreens().FirstOrDefault(s => s.PeerID == id && s.Primary) ?? throw new IOException("No local screen.");
        // A paused interval must not count against the next input session's watchdog.
        heard.Clear();
        StartHighRateTimer();
        Enabled = true;
        pointer = PointerRouter.Center(screen, id, (pointer?.Epoch ?? 0) + (claimControl ? 1UL : 0UL));
        noiseX = noiseY = 0;
        if (claimControl) MoveLocal();
        RestrictCursor();
        if (!Enabled)
            return;
        await ChangeCapability(true);
        if (round != generation)
            return;
        if (claimControl && pointer?.OwnerPeerID == id)
            Broadcast("control");
        log($"InputMode bluetoothOnly={manager.BluetoothInputOnly} bleWindow=adaptive-max16 maxPendingAgeMs=80 coalesceMs=2 render=immediate");
        log($"InputEnabled targetPeerId={Active?.PeerID ?? "none"} epoch={pointer?.Epoch ?? 0}");
        status(manager.BluetoothInputOnly && inputPeers.Count == 0 ? "等待蓝牙输入链路 · 本机输入可用" : "键鼠共享已启用 · Ctrl+Alt+Shift+Esc 暂停／恢复");
    }
    private Task ChangeCapability(bool enabled)
    {
        var previous = capabilityUpdate;
        async Task UpdateCapability()
        {
            await previous;
            await manager.SetCapabilitiesAsync(new Dictionary<string, bool>
            {
                ["input-function-slots-v1"] = true,
                ["input-function-keys-v1"] = true,
                ["ble-input-v2"] = true,
                ["compact-input"] = true,
                ["compact-scroll-v1"] = true,
                ["compact-input-v3"] = true,
                ["scroll-flow-v1"] = true,
                ["relative-pointer-v1"] = true,
                ["input-resume"] = true,
                ["input"] = enabled,
                ["command-clipboard"] = enabled,
                ["scroll-2d"] = enabled,
                ["input-committed-text"] = enabled,
                ["command-undo-redo"] = enabled
            });
        }
        return capabilityUpdate = UpdateCapability();
    }
    public void Pause()
    {
        if (localRelative)
            try
            {
                inject(new("relativeEnd"), Active, 0, 0);
            }
            catch { }
        relativePeer = null;
        relativeReported = null;
        localRelative = false;
        relativeReceived.Clear();
        generation++;
        bleWindows.Clear();
        bleSentAt.Clear();
        outstanding.Clear();
        motionProgress.Clear();
        slowDeliveryReported.Clear();
        acknowledgements.Clear();
        renderTarget = rendered = null;
        highRateTimer?.Dispose();
        highRateTimer = null;
        motionDelay?.Cancel();
        motionDelay = null;
        motion.Clear();
        scroll.Clear();
        scrollDelay?.Cancel();
        scrollDelay = null;
        pending.Clear();
        if (Enabled)
            Broadcast("release");
        _ = ChangeCapability(false);
        Enabled = false;
        commandKeys.Clear();
        physicalKeys.Clear();
        physicalFunctionSlots.Clear();
        physicalButtons.Clear();
        ReleaseAll();
        restrict(false, false);
    }
    private void Claim(CapturedInput e)
    {
        if (pointer is null && UsableScreens().FirstOrDefault(s => s.Id == e.ScreenID) is { } screen)
        {
            var position = screen.Logical(e.X, e.Y);
            pointer = new(screen.Id, screen.X + position.X * screen.Width, screen.Y + position.Y * screen.Height, id, 0);
        }
        if (pointer is null)
            return;
        DiscardContinuousDelivery();
        pointer = pointer with
        {
            OwnerPeerID = id,
            Epoch = pointer.Epoch + 1
        };
        noiseX = noiseY = 0;
        Broadcast("control");
    }
    public string? RemoteScreenID => Enabled && Active?.PeerID != id ? Active?.Id : null;
    public bool SourceCommand(string key, IEnumerable<string> held)
    {
        if (!Enabled || Active is not { } screen || screen.PeerID == id || KeyboardMapping.Command(key, held, platform, platforms.GetValueOrDefault(screen.PeerID, "unknown"), Config, fnEnabled, functionKeysEnabled) is not { } command)
            return false;
        Perform(command, screen.PeerID);
        return true;
    }
    public bool BeginSourceIME()
    {
        if (RemoteScreenID is null)
            return false;
        physicalKeys.Clear();
        physicalFunctionSlots.Clear();
        commandKeys.Clear();
        SendHeld();
        return true;
    }
    public bool CommitText(string text, string screenID)
    {
        if (!Enabled || Active is not { } screen || screen.Id != screenID || screen.PeerID == id)
            return false;
        var part = new System.Text.StringBuilder();
        var length = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            if (length + rune.Utf8SequenceLength > 4096)
            {
                var packet = Packet("text", screen.PeerID);
                packet.Text = part.ToString();
                Queue(screen.PeerID, packet);
                part.Clear();
                length = 0;
            }
            ;
            part.Append(rune.ToString());
            length += rune.Utf8SequenceLength;
        }
        if (part.Length > 0)
        {
            var packet = Packet("text", screen.PeerID);
            packet.Text = part.ToString();
            Queue(screen.PeerID, packet);
        }
        ;
        return true;
    }
    public bool Capture(CapturedInput e)
    {
        if (e.Type == "move" && localRelative && pointer?.OwnerPeerID != id && e.HardwareMotion == false)
            return false;
        if (!Enabled || group is null || pointer is null || Active is not { } active)
            return false;
        if (e.Key is { } function && active.PeerID != id && !functionPeers.Contains(active.PeerID) && (KeyboardMapping.FunctionKeys.Contains(function) || function.StartsWith("F", StringComparison.Ordinal) && int.TryParse(function.AsSpan(1), out var number) && number > 12))
            return false;
        if (e.Type is "keyDown" or "keyUp" && e.Key is { } key)
        {
            if (e.Type == "keyDown")
            {
                physicalKeys.Add(key);
                if (e.FunctionSlot is { } slot && KeyboardMapping.WindowsFunctions.ContainsKey(slot))
                    physicalFunctionSlots[key] = slot;
            }
            else
            {
                physicalKeys.Remove(key);
                physicalFunctionSlots.Remove(key);
                if (Active?.PeerID == id && keys.GetValueOrDefault(id)?.Contains(key) == true)
                    try
                    {
                        Key(id, key, false);
                    }
                    catch { Pause(); }
            }
            if (e.Type == "keyDown" && key == "Escape" && Has("Control") && Has("Alt") && Has("Shift"))
            {
                Pause();
                status("已紧急恢复本机输入");
                return true;
            }
        }
        if (e.Key is { } released && e.Type == "keyUp" && commandKeys.Remove(released))
            return true;
        if (e.Key is { } pressed && e.Type == "keyDown" && !commandKeys.Contains(pressed)
            && KeyboardMapping.Command(pressed, physicalKeys, platform, active.PeerID == id ? platform : platforms.GetValueOrDefault(active.PeerID, "unknown"), Config, active.PeerID == id || fnEnabled, functionKeysEnabled) is { } command)
        {
            if (active.PeerID == id && (command is "copy" or "cut" or "paste" or "undo" or "redo"))
            {
                if (command is "copy" or "cut")
                    LocalClipboardCommand?.Invoke();
                return false;
            }
            commandKeys.Add(pressed);
            Perform(command, active.PeerID);
            return true;
        }
        if (e.Key is { } repeat && commandKeys.Contains(repeat))
            return true;
        if (e.Type == "command" && e.Command is { } semantic)
        {
            Perform(semantic, active.PeerID);
            return true;
        }
        if (e.Type == "move" && relativePeer == active.PeerID && pointer.OwnerPeerID == id && active.PeerID != id)
        {
            capturedMoves++;
            lastRemoteMotion = Environment.TickCount64;
            relativeX += e.DeltaX * Gain(active.PeerID);
            relativeY += e.DeltaY * Gain(active.PeerID);
            var value = Packet("relative-move", active.PeerID);
            value.DeltaX = relativeX;
            value.DeltaY = relativeY;
            Queue(active.PeerID, value);
            RestrictCursor();
            return true;
        }
        if (e.Type == "move")
        {
            capturedMoves++;
            if (pointer.OwnerPeerID != id)
            {
                var now = Environment.TickCount64;
                if (now - noiseAt > 200)
                    noiseX = noiseY = 0;
                noiseAt = now;
                noiseX += e.DeltaX;
                noiseY += e.DeltaY;
                if (Math.Sqrt(noiseX * noiseX + noiseY * noiseY) < 6)
                    return true;
                Claim(e);
            }
            var before = pointer.ScreenID;
            var local = active.PeerID == id && e.ScreenID == active.Id;
            if (local)
            {
                var position = active.Logical(Math.Clamp(e.X, 0, 1), Math.Clamp(e.Y, 0, 1));
                pointer = pointer with
                {
                    X = active.X + position.X * active.Width,
                    Y = active.Y + position.Y * active.Height
                };
            }
            var edgeX = e.X <= 0 && e.DeltaX < 0 || e.X >= 1 - 1.0 / active.PixelWidth && e.DeltaX > 0;
            var edgeY = e.Y <= 0 && e.DeltaY < 0 || e.Y >= 1 - 1.0 / active.PixelHeight && e.DeltaY > 0;
            var delta = local ? active.Delta(edgeX ? e.DeltaX : 0, edgeY ? e.DeltaY : 0) : (e.DeltaX * (active.ScaleX ?? active.Scale), e.DeltaY * (active.ScaleY ?? active.Scale));
            pointer = PointerRouter.Move(pointer, ScreenCrossingEnabled ? UsableScreens() : UsableScreens().Where(s => s.PeerID == active.PeerID).ToArray(), delta.Item1 * Gain(active.PeerID), delta.Item2 * Gain(active.PeerID));
            active = Active!;
            if (before != pointer.ScreenID)
            {
                if (local)
                {
                    foreach (var button in physicalButtons)
                        try
                        {
                            inject(new("buttonUp", Button: button), null, 0, 0);
                        }
                        catch { }
                    foreach (var heldKey in physicalKeys)
                        try
                        {
                            inject(new("keyUp", heldKey), null, 0, 0);
                        }
                        catch { }
                }
                physicalButtons.Clear();
                ReleaseAll();
                Broadcast("control");
                MoveLocal();
                SendHeld();
                if (active.PeerID == id)
                    foreach (var heldKey in physicalKeys.Except(commandKeys).ToArray())
                        try
                        {
                            Key(id, heldKey, true);
                        }
                        catch { }
            }
            else if (active.PeerID != id)
            {
                lastRemoteMotion = Environment.TickCount64;
                Emit("move", active.PeerID);
            }
            RestrictCursor();
            return !local || before != pointer.ScreenID;
        }
        if (e.Type is "buttonDown" or "scroll" && pointer.OwnerPeerID != id)
            Claim(e);
        if (e.Type == "buttonDown")
            physicalButtons.Add(e.Button);
        if (e.Type == "buttonUp")
            physicalButtons.Remove(e.Button);
        if (active.PeerID == id)
            return false;
        var packet = Packet(e.Type, active.PeerID);
        packet.Key = e.Key;
        packet.FunctionSlot = e.FunctionSlot;
        packet.Button = e.Button; // Apply only to outgoing remote scroll; retain phases and existing flow control.
        var inversion = e.Type == "scroll" ? ScrollInversion?.Invoke(active.PeerID) ?? default : default;
        var dx = e.Type == "scroll" ? HorizontalScrollFilter.Apply(e.DeltaX, e.DeltaY, HorizontalScrollAngle?.Invoke(active.PeerID) ?? 30) : e.DeltaX;
        packet.DeltaX = inversion.Horizontal ? -dx : dx;
        packet.DeltaY = inversion.Vertical ? -e.DeltaY : e.DeltaY;
        packet.ScrollPhase = e.ScrollPhase;
        packet.MomentumPhase = e.MomentumPhase;
        packet.PreciseScroll = e.PreciseScroll;
        if (e.Type == "scroll")
            lastRemoteMotion = Environment.TickCount64;
        Queue(active.PeerID, packet);
        return true;
    }
    private bool Has(string prefix) => physicalKeys.Any(k => k.StartsWith(prefix, StringComparison.Ordinal));
    private InputPacket Packet(string type, string target) => new()
    {
        Type = type,
        GroupID = group!.Id,
        SourcePeerID = id,
        TargetPeerID = target,
        TargetScreenID = pointer?.ScreenID,
        Pointer = pointer,
        SourcePlatform = platform,
        Sequence = ++sequence,
        FnEnabled = type is "keyDown" or "keyUp" or "held" ? fnEnabled : null,
        FunctionKeysEnabled = type is "keyDown" or "keyUp" or "held" ? functionKeysEnabled : null
    };
    private void Emit(string type, string peer) => Queue(peer, Packet(type, peer));
    private void Broadcast(string type)
    {
        if (group is null)
            return;
        foreach (var peer in online.Where(p => p != id && (type is not ("pointer" or "priority") || inputPeers.Contains(p))))
        {
            var packet = Packet(type, Active?.PeerID ?? id);
            packet.Priority = priority;
            Queue(peer, packet);
        }
    }
    public void RequestPeerResume()
    {
        if (!Enabled || group is null)
            return;
        foreach (var peer in online.Where(p => p != id))
            Queue(peer, Packet("resume", peer));
    }
    private static bool MergeableScroll(InputPacket a, InputPacket b) => a.Type == "scroll" && b.Type == "scroll" && a.TargetScreenID == b.TargetScreenID && a.Pointer?.Epoch == b.Pointer?.Epoch
        && (a.ScrollPhase ?? 0) == (b.ScrollPhase ?? 0) && (b.ScrollPhase ?? 0) is 0 or 2 && (a.MomentumPhase ?? 0) == (b.MomentumPhase ?? 0) && (b.MomentumPhase ?? 0) is 0 or 2
        && (a.PreciseScroll ?? false) == (b.PreciseScroll ?? false);
    private static InputPacket MergedScroll(InputPacket a, InputPacket b)
    {
        b.DeltaX = Math.Clamp(a.DeltaX + b.DeltaX, -10000, 10000);
        b.DeltaY = Math.Clamp(a.DeltaY + b.DeltaY, -10000, 10000);
        return b;
    }
    private async Task FlushScrollAfterDelay(CancellationTokenSource delay)
    {
        try
        {
            await Task.Delay(8, delay.Token);
            if (!disposed && ReferenceEquals(scrollDelay, delay))
            {
                scrollDelay = null;
                FlushMotion();
            }
        }
        catch (OperationCanceledException) { }
        finally { delay.Dispose(); }
    }
    private void Queue(string peer, InputPacket packet)
    {
        if (disposed)
            return;
        if (packet.Type == "scroll")
        {
            if (!double.IsFinite(packet.DeltaX) || !double.IsFinite(packet.DeltaY))
                return;
            packet.DeltaX = Math.Clamp(packet.DeltaX, -10000, 10000);
            packet.DeltaY = Math.Clamp(packet.DeltaY, -10000, 10000);
            if (scroll.TryGetValue(peer, out var previous))
            {
                if (MergeableScroll(previous, packet))
                    packet = MergedScroll(previous, packet);
                else
                    FlushMotion();
            }
            scroll[peer] = packet;
            if ((packet.ScrollPhase ?? 0) is not (0 or 2) || (packet.MomentumPhase ?? 0) is not (0 or 2))
            {
                FlushMotion();
                return;
            }
            if (scrollDelay is null)
            {
                scrollDelay = new();
                _ = FlushScrollAfterDelay(scrollDelay);
            }
            return;
        }
        if (MotionType(packet.Type))
        {
            motion[peer] = packet;
            if (motionDelay is null)
            {
                motionDelay = new();
                _ = FlushMotionAfterDelay(motionDelay, 2);
            }
            return;
        }
        if (packet.Type is "control" or "release")
        {
            scroll.Remove(peer);
            motion.Remove(peer);
            pending.RemoveAll(p => p.Peer == peer && (MotionType(p.Packet.Type) || p.Packet.Type == "scroll" && (p.Packet.ScrollPhase ?? 0) is 0 or 2 && (p.Packet.MomentumPhase ?? 0) is 0 or 2));
        }
        FlushMotion();
        Enqueue(peer, packet);
    }
    private async Task FlushMotionAfterDelay(CancellationTokenSource delay, int milliseconds)
    {
        try
        {
            await Task.Delay(milliseconds, delay.Token);
            if (!disposed)
            {
                motionDelay = null;
                FlushMotion();
            }
        }
        catch (OperationCanceledException) { }
        finally { delay.Dispose(); }
    }
    private void FlushMotion()
    {
        var latest = motion.Concat(scroll).OrderBy(pair => pair.Value.Sequence).ToArray();
        motion.Clear();
        scroll.Clear();
        scrollDelay?.Cancel();
        scrollDelay = null;
        foreach (var pair in latest)
            Enqueue(pair.Key, pair.Value);
    }
    private static bool ContinuousInput(InputPacket packet) => MotionType(packet.Type) || packet.Type == "scroll" && (packet.ScrollPhase ?? 0) is 0 or 2 && (packet.MomentumPhase ?? 0) is 0 or 2;
    private void Enqueue(string peer, InputPacket packet)
    {
        var now = Environment.TickCount64;
        var next = packet;
        if (ContinuousInput(packet))
        {
            for (var index = pending.Count - 1; index >= 0; index--)
            {
                var old = pending[index];
                if (old.Peer != peer || !ContinuousInput(old.Packet))
                    break;
                if (MergeableScroll(old.Packet, packet))
                {
                    next = MergedScroll(old.Packet, packet);
                    pending.RemoveAt(index);
                    break;
                }
                if (MotionType(packet.Type) && old.Packet.Type == packet.Type && old.Packet.TargetScreenID == packet.TargetScreenID && old.Packet.Pointer?.Epoch == packet.Pointer?.Epoch)
                {
                    pending.RemoveAt(index);
                    break;
                }
            }
        }
        if (pending.Count >= 256)
        {
            log($"InputQueueCongested targetPeerId={peer}");
            pending.Clear();
            Recover("输入队列拥塞，已恢复本机控制并保持共享");
            return;
        }
        pending.Add((peer, next, now));
        if (!sending)
            _ = Drain();
    }
    private bool MotionWindowFull(string peer)
    {
        var count = outstanding.GetValueOrDefault(peer)?.Count ?? 0;
        if (!blePeers.Contains(peer))
            return count >= 8;
        if (!bleWindows.TryGetValue(peer, out var window))
            bleWindows[peer] = window = new();
        var oldest = bleSentAt.TryGetValue(peer, out var times) && times.Count > 0 ? System.Diagnostics.Stopwatch.GetElapsedTime(times.Values.Min()).TotalSeconds : 0;
        return !window.Allows(count, platforms.GetValueOrDefault(peer) == "windows" ? 240 : 60, oldest);
    }
    private async Task Drain()
    {
        sending = true;
        try
        {
            while (pending.Count > 0 && !disposed)
            {
                var item = pending[0];
                if ((MotionType(item.Packet.Type) || item.Packet.Type == "scroll" && scrollFlowPeers.Contains(item.Peer)) && compactPeers.Contains(item.Peer) && MotionWindowFull(item.Peer))
                {
                    if (ContinuousInput(item.Packet) && !pending.Skip(1).Any(p => !ContinuousInput(p.Packet)))
                        return;
                    if (item.Packet.Type != "scroll")
                        item.Packet.Type = "pointer";
                }
                pending.RemoveAt(0);
                var round = (generation, deliveryGeneration);
                try
                {
                    var compact = compactPeers.Contains(item.Peer) ? MotionCodec.Encode(item.Packet, group?.Layout ?? [], extended: bleCompactPeers.Contains(item.Peer), compactScroll: scrollPeers.Contains(item.Peer), contextPeers.Contains(item.Peer)) : null;
                    if (MotionType(item.Packet.Type))
                        sentMoves++;
                    if (MotionType(item.Packet.Type) || item.Packet.Type == "scroll" && scrollFlowPeers.Contains(item.Peer))
                    {
                        if (compact is not null)
                        {
                            if (!outstanding.TryGetValue(item.Peer, out var values))
                                outstanding[item.Peer] = values = [];
                            if (values.Count == 0)
                                motionProgress[item.Peer] = Environment.TickCount64;
                            values.Add(item.Packet.Sequence);
                        }
                    }
                    if ((MotionType(item.Packet.Type) || item.Packet.Type == "scroll" && scrollFlowPeers.Contains(item.Peer)) && compact is not null && blePeers.Contains(item.Peer))
                    {
                        if (!bleSentAt.TryGetValue(item.Peer, out var times))
                            bleSentAt[item.Peer] = times = new();
                        times[item.Packet.Sequence] = System.Diagnostics.Stopwatch.GetTimestamp();
                    }
                    var tracked = compact is not null && (MotionType(item.Packet.Type) || item.Packet.Type == "scroll" && scrollFlowPeers.Contains(item.Peer));
                    await manager.SendInputAsync(item.Peer, compact ?? JsonSerializer.SerializeToUtf8Bytes(item.Packet, json), tracked ? item.Packet.Sequence : null);
                }
                catch { if (round == (generation, deliveryGeneration)) { outstanding.Remove(item.Peer); ReleasePeer(item.Peer); if (Active?.PeerID == item.Peer) Recover("输入目标暂不可达，已恢复本机控制并保持共享"); } }
            }
        }
        finally { sending = false; }
    }
    private void Receive(string peer, byte[] bytes, ISessionTransport transport)
    {
        if (disposed || group is null || !online.Contains(peer))
            return;
        InputPacket? packet;
        try
        {
            packet = MotionCodec.Decode(bytes, group, peer, id, receivedContexts.TryGetValue(peer, out var wire) ? wire.Pointer : null) ?? JsonSerializer.Deserialize<InputPacket>(bytes, json);
        }
        catch { return; }
        if (packet is null || packet.SourcePeerID != peer || packet.GroupID != group.Id || packet.Keys?.Length > 128 || packet.Buttons?.Length > 8)
            return;
        heard[peer] = Environment.TickCount64;
        if (packet.Type == "resume" && packet.TargetPeerID == id && packet.Sequence > received.GetValueOrDefault(peer))
        {
            received[peer] = packet.Sequence;
            ResumeRequested?.Invoke();
            log("InputResumeRequested peerId=" + peer);
            return;
        }
        if (packet.Type == "motionAck" && packet.AcknowledgedSequence is { } ack)
        {
            manager.InputAcknowledged(peer, ack, transport);
            var tail = 0.0;
            if (bleSentAt.TryGetValue(peer, out var times))
                foreach (var item in times.Where(p => p.Key <= ack).ToArray())
                {
                    if (transport.Kind == "ble")
                    {
                        if (!bleWindows.TryGetValue(peer, out var window))
                            bleWindows[peer] = window = new();
                        var elapsed = System.Diagnostics.Stopwatch.GetElapsedTime(item.Value).TotalSeconds;
                        window.Acknowledged(elapsed);
                        tail = Math.Max(tail, elapsed);
                        if (bleAckMilliseconds.Count < 2048)
                            bleAckMilliseconds.Add(elapsed * 1000);
                    }
                    times.Remove(item.Key);
                }
            if (tail > .06)
                manager.YieldBulkForInput(peer);
            if (outstanding.TryGetValue(peer, out var values) && values.RemoveWhere(s => s <= ack) > 0)
            {
                motionProgress[peer] = Environment.TickCount64;
                if (slowDeliveryReported.Remove(peer))
                {
                    log("InputDeliveryResumed peerId=" + peer);
                    status("对端输入已恢复，键鼠共享继续运行");
                }
            }
            if (!sending && pending.Count > 0)
                _ = Drain();
            return;
        }
        if ((MotionType(packet.Type) || packet.Type == "scroll" && scrollFlowPeers.Contains(peer)) && compactPeers.Contains(peer) && packet.Sequence >= acknowledgements.GetValueOrDefault(peer).Sequence)
            acknowledgements[peer] = (packet.Sequence, transport);
        if (packet.Type == "release")
        {
            received[peer] = Math.Max(received.GetValueOrDefault(peer), packet.Sequence);
            ReleasePeer(peer);
            if (pointer?.OwnerPeerID == peer || Active?.PeerID == peer)
            {
                Recover("对端已停止输入共享，本机已恢复", false, Active?.PeerID != id);
            }
            return;
        }
        if (packet.Type == "priority" && peer == group.LeaderID && packet.Priority is { } list && list.Length <= group.Members.Length
            && list.Distinct().Count() == list.Length && list.All(online.Contains))
        {
            priority = list;
            return;
        }
        if (packet.Type == "mouse-mode")
        {
            ReceiveMouseMode(peer, packet);
            return;
        }
        if (packet.Type is "control" or "pointer" or "move" or "relative-start" or "relative-move")
        {
            if (packet.Pointer is not { } next || next.OwnerPeerID != peer || !double.IsFinite(next.X) || !double.IsFinite(next.Y)
                || group.Layout.FirstOrDefault(s => s.Id == next.ScreenID) is not { } screen || !online.Contains(screen.PeerID)
                || next.X < screen.X || next.X > screen.X + screen.Width || next.Y < screen.Y || next.Y > screen.Y + screen.Height)
                return;
            if (!receivedContexts.TryGetValue(peer, out var oldWire) || packet.Sequence >= oldWire.Sequence && next.Epoch >= oldWire.Pointer.Epoch)
                receivedContexts[peer] = (next, packet.Sequence);
            if (pointer is { } current && (next.Epoch < current.Epoch || next.Epoch == current.Epoch && next.OwnerPeerID != current.OwnerPeerID
                && Rank(next.OwnerPeerID) >= Rank(current.OwnerPeerID)))
            {
                var now = Environment.TickCount64;
                if (Environment.GetCommandLineArgs().Contains("--input-state-check") && now - rejectionReportAt >= 5000)
                {
                    rejectionReportAt = now;
                    log($"InputControlRejected type={packet.Type} incomingOwner={next.OwnerPeerID} incomingEpoch={next.Epoch} localOwner={current.OwnerPeerID} localEpoch={current.Epoch}");
                }
                return;
            }
            if (packet.Sequence <= received.GetValueOrDefault(peer))
                return;
            received[peer] = packet.Sequence;
            var changedScreen = pointer?.ScreenID != next.ScreenID;
            var changedOwner = pointer?.Epoch != next.Epoch || pointer?.OwnerPeerID != next.OwnerPeerID;
            if (changedOwner && pointer?.OwnerPeerID == id)
                DiscardContinuousDelivery();
            pointer = next;
            noiseX = noiseY = 0;
            ReportRelativeMode();
            if (packet.Type == "control")
                log($"InputControlApplied sourcePeerId={peer} targetPeerId={screen.PeerID} epoch={next.Epoch} enabled={Enabled}");
            if (packet.Type is "relative-start" or "relative-move")
            {
                ApplyRelative(peer, packet, screen);
                RestrictCursor();
                return;
            }
            if (localRelative && !changedScreen && !changedOwner && packet.Type != "control")
                return;
            if (changedScreen || changedOwner || packet.Type == "control")
            {
                if (changedScreen)
                    ReleaseAll();
                MoveLocal();
                if (changedScreen)
                    SendHeld();
            }
            else
                ScheduleRender(next);
            RestrictCursor();
            return;
        }
        if (!Enabled)
            return;
        if (packet.TargetPeerID != id || packet.TargetScreenID != pointer?.ScreenID || Active?.PeerID != id)
            return;
        if (packet.Type == "scroll" && (packet.Pointer?.OwnerPeerID != peer || pointer?.OwnerPeerID != peer || packet.Pointer?.Epoch != pointer?.Epoch))
            return;
        if (packet.Sequence <= received.GetValueOrDefault(peer))
            return;
        received[peer] = packet.Sequence;
        if (packet.Type is "keyDown" or "keyUp" or "held")
        {
            var next = (Fn: packet.FnEnabled ?? true, Functions: packet.FunctionKeysEnabled ?? true);
            if (sourceOptions.GetValueOrDefault(peer, (Fn: true, Functions: true)) != next)
            {
                var from = packet.SourcePlatform ?? platforms.GetValueOrDefault(peer, "unknown");
                var originals = originalKeys.GetValueOrDefault(peer)?.ToArray() ?? [];
                var fnDown = originals.Any(p => KeyboardMapping.Map(p.Key, from, platform, Config, fnEnabled: next.Fn, functionKeysEnabled: next.Functions) == "Fn");
                foreach (var item in originals)
                {
                    var updated = KeyboardMapping.Map(item.Key, from, platform, Config, fnDown, FunctionKey, next.Fn, next.Functions, remoteFunctionSlots.GetValueOrDefault(peer)?.GetValueOrDefault(item.Key));
                    if (updated != item.Value)
                        try
                        {
                            MappedKey(peer, item.Key, false, from);
                        }
                        catch { }
                }
            }
            sourceOptions[peer] = next;
        }
        // Unchanged held-state repair must not interrupt an in-flight movement interpolation.
        if (packet.Type == "scroll" && packet.Pointer is { } nextPoint && pointer is { } oldPoint && nextPoint.OwnerPeerID == peer && nextPoint.Epoch == oldPoint.Epoch && nextPoint.ScreenID == oldPoint.ScreenID && Active is { } screenPoint && double.IsFinite(nextPoint.X) && double.IsFinite(nextPoint.Y) && nextPoint.X >= screenPoint.X && nextPoint.X <= screenPoint.X + screenPoint.Width && nextPoint.Y >= screenPoint.Y && nextPoint.Y <= screenPoint.Y + screenPoint.Height)
        {
            pointer = nextPoint;
            if (nextPoint != oldPoint)
                MoveLocal();
        }
        if (packet.Type != "scroll" && (packet.Type != "held" || !new HashSet<string>(packet.Keys ?? []).SetEquals(originalKeys.GetValueOrDefault(peer)?.Keys ?? Enumerable.Empty<string>()) || !new HashSet<int>(packet.Buttons ?? []).SetEquals(buttons.GetValueOrDefault(peer) ?? [])))
            MoveLocal();
        try
        {
            if (packet.Type == "held")
                SyncHeld(peer, packet.Keys ?? [], packet.Buttons ?? [], packet.SourcePlatform ?? platforms.GetValueOrDefault(peer, "unknown"), packet.FunctionSlots);
            else if (packet.Type is "keyDown" or "keyUp" && packet.Key is { Length: > 0 and <= 32 } key && TargetKeyHandler?.Invoke(new(packet.Type, key)) != true)
                MappedKey(peer, key, packet.Type == "keyDown", packet.SourcePlatform ?? platforms.GetValueOrDefault(peer, "unknown"), packet.FunctionSlot);
            else if (packet.Type == "text" && packet.Text is { Length: > 0 } text && System.Text.Encoding.UTF8.GetByteCount(text) <= 4096)
                inject(new("text", Text: text), Active, 0, 0);
            else if (packet.Type == "command" && packet.Command is { } command)
                _ = Execute(command, peer, packet.ClipboardEntryID);
            else if (packet.Type is "buttonDown" or "buttonUp" && packet.Button is >= 0 and <= 2)
                Button(peer, packet.Button, packet.Type == "buttonDown");
            else if (packet.Type == "scroll" && double.IsFinite(packet.DeltaX) && double.IsFinite(packet.DeltaY))
                inject(new("scroll", DeltaX: Math.Clamp(packet.DeltaX, -10000, 10000), DeltaY: Math.Clamp(packet.DeltaY, -10000, 10000), ScrollPhase: packet.ScrollPhase, MomentumPhase: packet.MomentumPhase, PreciseScroll: packet.PreciseScroll), Active, 0, 0);
        }
        catch { Pause(); status("系统拒绝输入注入，已恢复本机控制"); }
    }
    private void Perform(string command, string target)
    {
        log($"InputCommandSent command={command} targetPeerId={target}");
        var entryID = command == "paste" ? ClipboardEntryID?.Invoke() : null;
        if (target == id)
            _ = Execute(command, id, entryID);
        else
        {
            var packet = Packet("command", target);
            packet.Command = command;
            packet.ClipboardEntryID = entryID;
            Queue(target, packet);
        }
    }
    private async Task Execute(string command, string source, string? entryID)
    {
        if (command is not ("copy" or "cut" or "paste" or "history" or "undo" or "redo" or "desktopPrevious" or "desktopNext" or "overview"))
            return;
        log($"InputCommandExecute command={command} sourcePeerId={source}");
        try
        {
            if (CommandHandler is not null && await CommandHandler(command, source, entryID))
                return;
            inject(new("command", Command: command), Active, 0, 0);
        }
        catch { Pause(); status("命令未完成：目标系统权限或能力不可用，已恢复本机控制"); }
    }
    private void MappedKey(string peer, string key, bool down, string from, string? functionSlot = null)
    {
        if (!originalKeys.TryGetValue(peer, out var originals))
            originalKeys[peer] = originals = new();
        if (down)
        {
            if (originals.TryGetValue(key, out var old))
            {
                if (old != KeyboardMapping.NoAction)
                    Key(peer, old, true);
                return;
            }
            if (!remoteFunctionSlots.TryGetValue(peer, out var slots))
                remoteFunctionSlots[peer] = slots = new();
            if (functionSlot is not null && KeyboardMapping.WindowsFunctions.ContainsKey(functionSlot))
                slots[key] = functionSlot;
            else
                slots.Remove(key);
            var fnDown = originals.Values.Contains("Fn");
            var mapped = KeyboardMapping.Map(key, from, platform, Config, fnDown, FunctionKey, sourceOptions.GetValueOrDefault(peer, (Fn: true, Functions: true)).Fn, sourceOptions.GetValueOrDefault(peer, (Fn: true, Functions: true)).Functions, slots.GetValueOrDefault(key));
            var duplicate = originals.Values.Contains(mapped);
            var functionModifier = from == "macos" && key.StartsWith("F", StringComparison.Ordinal) && int.TryParse(key.AsSpan(1), out var f) && f is >= 1 and <= 12 && originals.TryGetValue("Fn", out var modifier) && KeyboardMapping.Modifiers.Contains(modifier) ? modifier : null;
            originals[key] = mapped;
            if (!duplicate && mapped != KeyboardMapping.NoAction)
                Key(peer, mapped, true, functionModifier);
            if (from == "macos" && KeyboardMapping.MacFunctionSlots.TryGetValue(key, out var slot) && mapped == KeyboardMapping.NoAction && Config?.MacToWindows.ContainsKey(key) != true && Config?.MacToWindows.ContainsKey(slot) != true)
                status("该 Windows 功能需要目标电脑的厂商接口，目前不能执行");
        }
        else
        {
            remoteFunctionSlots.GetValueOrDefault(peer)?.Remove(key);
            if (originals.Remove(key, out var mapped) && !originals.Values.Contains(mapped) && mapped != KeyboardMapping.NoAction)
                Key(peer, mapped, false);
        }
    }
    private int Rank(string peer) => Array.IndexOf(priority, peer) is var rank && rank >= 0 ? rank : int.MaxValue;
    private void MoveLocal()
    {
        if (localRelative && pointer?.OwnerPeerID != id)
            return;
        renderTarget = null;
        rendered = pointer;
        if (!Enabled || pointer is null || Active is not { PeerID: var peer } screen || peer != id)
            return;
        try
        {
            var native = screen.Native((pointer.X - screen.X) / screen.Width, (pointer.Y - screen.Y) / screen.Height);
            inject(new("move"), screen, native.X, native.Y);
        }
        catch { Pause(); status("系统拒绝移动 Pointer"); }
    }
    private void RestrictCursor() => restrict(Enabled && Active?.PeerID != id, Enabled && (Active?.PeerID != id || pointer?.OwnerPeerID != id));
    private void Key(string peer, string key, bool down, string? functionModifier = null)
    {
        if (!keys.TryGetValue(peer, out var held))
            keys[peer] = held = new();
        if (down)
        {
            var other = keys.Any(p => p.Key != peer && p.Value.Contains(key));
            var fresh = held.Add(key);
            if (!other || !fresh)
                inject(new("keyDown", key, FunctionModifier: functionModifier), Active, 0, 0);
        }
        else if (held.Remove(key) && !keys.Values.Any(s => s.Contains(key)))
            inject(new("keyUp", key), Active, 0, 0);
    }
    private void Button(string peer, int button, bool down)
    {
        if (!buttons.TryGetValue(peer, out var held))
            buttons[peer] = held = new();
        if (down)
        {
            var other = buttons.Any(p => p.Key != peer && p.Value.Contains(button));
            if (held.Add(button) && !other)
                inject(new("buttonDown", Button: button), Active, 0, 0);
        }
        else if (held.Remove(button) && !buttons.Values.Any(s => s.Contains(button)))
            inject(new("buttonUp", Button: button), Active, 0, 0);
    }
    private void SyncHeld(string peer, string[] desiredKeys, int[] desiredButtons, string from, Dictionary<string, string>? slots = null)
    {
        if (slots is not null && (slots.Count > desiredKeys.Length || slots.Any(p => !desiredKeys.Contains(p.Key) || !KeyboardMapping.WindowsFunctions.ContainsKey(p.Value))))
            return;
        if (desiredKeys.Any(k => k.Length > 32) || desiredButtons.Any(b => b is < 0 or > 2))
            return;
        desiredKeys = desiredKeys.Where(key => TargetKeyHandler?.Invoke(new("keyDown", key)) != true).ToArray();
        foreach (var key in originalKeys.GetValueOrDefault(peer)?.Keys.Except(desiredKeys).ToArray() ?? [])
            MappedKey(peer, key, false, from);
        foreach (var key in desiredKeys.Except(originalKeys.GetValueOrDefault(peer)?.Keys.ToArray() ?? []).OrderByDescending(k => from == "macos" && k == "Fn" || KeyboardMapping.Map(k, from, platform, Config) == "Fn").ThenBy(k => k, StringComparer.Ordinal))
            MappedKey(peer, key, true, from, slots?.GetValueOrDefault(key));
        foreach (var button in buttons.GetValueOrDefault(peer)?.Except(desiredButtons).ToArray() ?? [])
            Button(peer, button, false);
        foreach (var button in desiredButtons.Except(buttons.GetValueOrDefault(peer) ?? []))
            Button(peer, button, true);
    }
    private void ReleasePeer(string peer)
    {
        foreach (var key in keys.GetValueOrDefault(peer)?.ToArray() ?? [])
            try
            {
                Key(peer, key, false);
            }
            catch { }
        foreach (var button in buttons.GetValueOrDefault(peer)?.ToArray() ?? [])
            try
            {
                Button(peer, button, false);
            }
            catch { }
        remoteFunctionSlots.Remove(peer);
        originalKeys.Remove(peer);
        keys.Remove(peer);
        buttons.Remove(peer);
    }
    private void ReleaseAll()
    {
        foreach (var peer in keys.Keys.Union(buttons.Keys).ToArray())
            ReleasePeer(peer);
    }
    private void SendHeld()
    {
        if (!Enabled || Active is not { } active)
            return;
        if (active.PeerID == id)
            return;
        var desiredKeys = physicalKeys.Except(commandKeys).ToHashSet();
        var epoch = pointer?.Epoch ?? 0;
        if (desiredKeys.Count == 0 && physicalButtons.Count == 0 && heldSnapshots.TryGetValue(active.PeerID, out var last)
            && last.Screen == active.Id && last.Epoch == epoch && last.Keys.Count == 0 && last.Buttons.Count == 0)
            return;
        heldSnapshots[active.PeerID] = (active.Id, epoch, desiredKeys, physicalButtons.ToHashSet());
        var packet = Packet("held", active.PeerID);
        packet.Keys = desiredKeys.ToArray();
        packet.FunctionSlots = physicalFunctionSlots.Where(p => desiredKeys.Contains(p.Key)).ToDictionary(p => p.Key, p => p.Value);
        packet.Buttons = physicalButtons.ToArray();
        Queue(active.PeerID, packet);
    }
    private void Tick()
    {
        if (disposed)
            return;
        var now = Environment.TickCount64;
        if (Environment.GetCommandLineArgs().Contains("--input-state-check") && now - stateReportAt >= 5000)
        {
            stateReportAt = now;
            log($"InputState enabled={Enabled} online={string.Join(',', online.Order())} inputPeers={string.Join(',', inputPeers.Order())} blePeers={string.Join(',', blePeers.Order())} owner={pointer?.OwnerPeerID ?? "none"} target={Active?.PeerID ?? "none"} epoch={pointer?.Epoch ?? 0} captureRate={CaptureRate} sendRate={SendRate}");
        }
        if (!Enabled)
            return;
        ReportRelativeMode();
        if (now - bleReportAt >= 5000 && bleAckMilliseconds.Count > 0)
        {
            bleReportAt = now;
            var samples = bleAckMilliseconds.Order().ToArray();
            bleAckMilliseconds.Clear();
            log($"BLEInputDelivery samples={samples.Length} ackP50Ms={samples[samples.Length / 2]:F0} ackP95Ms={samples[Math.Min(samples.Length - 1, samples.Length * 95 / 100)]:F0} ackMaxMs={samples[^1]:F0}");
        }
        if (outstanding.FirstOrDefault(p => p.Value.Count > 0 && now - motionProgress.GetValueOrDefault(p.Key, now) > 1000).Key is { } stalled)
        {
            if (manager.InputSessionAlive(stalled))
            {
                // Keep delivery credit bounded. A responsive transport is not proof of native injection.
                var waiting = slowDeliveryReported.TryGetValue(stalled, out var previous);
                if (!waiting || now - previous >= 5000)
                {
                    slowDeliveryReported[stalled] = now;
                    log("InputDeliveryWaiting peerId=" + stalled + " sessionAlive=true");
                    if (!waiting)
                        status("对端输入处理较慢，共享保持连接；可用紧急快捷键恢复本机");
                }
            }
            else
            {
                log("InputMotionAckStalled peerId=" + stalled);
                Recover("输入连接已不可用，已恢复本机控制");
                return;
            }
        }
        foreach (var peer in heard.Where(p => now - p.Value > 3000).Select(p => p.Key).ToArray())
        {
            if (manager.InputSessionAlive(peer))
                continue;
            ReleasePeer(peer);
            heard.Remove(peer);
            if (pointer?.OwnerPeerID == peer)
                Recover("输入连接已不可用，已恢复本机控制");
        }
        if (now - lastRate >= 1000)
        {
            lastRate = now;
            CaptureRate = capturedMoves;
            SendRate = sentMoves;
            capturedMoves = sentMoves = 0;
        }
        if (now - lastSnapshot >= 500)
        {
            lastSnapshot = now;
            // Move frames already carry position and liveness. Keep bulky repair off the moving path.
            var movingRemote = pointer?.OwnerPeerID == id && Active?.PeerID != id && now - lastRemoteMotion < 250;
            if (!movingRemote)
            {
                if (pointer?.OwnerPeerID == id)
                    Broadcast("pointer");
                SendHeld();
            }
        }
    }
    private void Recover(string reason, bool announce = true, bool reposition = true)
    {
        if (Environment.TickCount64 - recoveryReported > 1000)
        {
            recoveryReported = Environment.TickCount64;
            log($"InputRecovery reason={reason} pending={pending.Count} outstanding={outstanding.Values.Sum(s => s.Count)}");
        }
        DiscardContinuousDelivery();
        pending.Clear();
        acknowledgements.Clear();
        heard.Clear();
        physicalKeys.Clear();
        physicalFunctionSlots.Clear();
        physicalButtons.Clear();
        commandKeys.Clear();
        ReleaseAll();
        renderTarget = null;
        if (UsableScreens().FirstOrDefault(s => s.PeerID == id && s.Primary) is { } screen)
        {
            pointer = PointerRouter.Center(screen, id, (pointer?.Epoch ?? 0) + 1);
            restrict(false, false);
            if (reposition) MoveLocal();
            if (announce)
                Broadcast("control");
        }
        else
            restrict(false, false);
        log($"InputRecovered enabled={Enabled}");
        status(reason);
    }
    private void ScheduleRender(PointerState target)
    {
        if (!Enabled || Active?.PeerID != id)
            return;
        if (blePeers.Contains(target.OwnerPeerID))
        {
            MoveLocal();
            return;
        }
        if (renderTarget == target)
            return;
        if (rendered == target)
        {
            renderTarget = null;
            return;
        }
        renderFrom = rendered ?? target;
        renderTarget = target;
        renderAt = System.Diagnostics.Stopwatch.GetTimestamp();
    }
    private void StartHighRateTimer()
    {
        highRateTimer?.Dispose();
        var round = generation;
        var posted = 0;
        lastAckAt = System.Diagnostics.Stopwatch.GetTimestamp();
        highRateTimer = new(_ =>
        {
            if (Interlocked.Exchange(ref posted, 1) != 0)
                return;
            var queuedAt = System.Diagnostics.Stopwatch.GetTimestamp();
            context.Post(_ =>
            {
                Interlocked.Exchange(ref posted, 0);
                if (round != generation || !Enabled || disposed)
                    return;
                var delay = System.Diagnostics.Stopwatch.GetElapsedTime(queuedAt).TotalMilliseconds;
                if (delay > 100 && Environment.TickCount64 - dispatcherStallReported > 1000)
                {
                    dispatcherStallReported = Environment.TickCount64;
                    log($"InputDispatcherStalled delayMs={delay:F0}");
                }
                RenderStep();
                // Timer callbacks may be coalesced: four callbacks need not be 8ms.
                if (System.Diagnostics.Stopwatch.GetElapsedTime(lastAckAt).TotalMilliseconds >= 8)
                {
                    lastAckAt = System.Diagnostics.Stopwatch.GetTimestamp();
                    SendAcknowledgements();
                }
            }, null);
        }, null, 2, 2);
    }
    private void RenderStep()
    {
        if (!Enabled || renderTarget is not { } target || renderFrom is not { } from || Active is not { } screen || screen.PeerID != id)
            return;
        var fraction = Math.Min(1, System.Diagnostics.Stopwatch.GetElapsedTime(renderAt).TotalSeconds / .004);
        var point = target with
        {
            X = from.X + (target.X - from.X) * fraction,
            Y = from.Y + (target.Y - from.Y) * fraction
        };
        try
        {
            var native = screen.Native((point.X - screen.X) / screen.Width, (point.Y - screen.Y) / screen.Height);
            inject(new("move"), screen, native.X, native.Y);
            rendered = point;
            if (fraction == 1)
                renderTarget = null;
        }
        catch { Pause(); status("系统拒绝移动 Pointer"); }
    }
    private void SendAcknowledgements()
    {
        if (group is null)
            return;
        var values = acknowledgements.ToArray();
        acknowledgements.Clear();
        foreach (var (peer, value) in values)
        {
            var ack = new InputPacket { Type = "motionAck", GroupID = group.Id, SourcePeerID = id, TargetPeerID = peer, AcknowledgedSequence = value.Sequence };
            if (MotionCodec.Encode(ack, group.Layout, compactContext: contextPeers.Contains(peer)) is { } bytes)
                _ = SendAck(peer, bytes, value.Transport);
        }
    }
    private async Task SendAck(string peer, byte[] bytes, ISessionTransport transport)
    {
        try
        {
            manager.InputReceived(peer, transport);
            await manager.SendOnTransportAsync(peer, "input", bytes, transport);
        }
        catch { }
    }
    public void Dispose()
    {
        if (disposed)
            return;
        Pause();
        disposed = true;
        timer.Dispose();
        pending.Clear();
    }
}
