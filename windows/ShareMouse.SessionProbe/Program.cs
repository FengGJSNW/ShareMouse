using System.Text.Json;
using System.Text;
using ShareMouse.Core;
using ShareMouse.Network;

if (args.Length >= 1 && args[0] == ShareMouse.WindowsClipboardReader.HelperArgument)
{
    var blocked = args.Contains("--blocked-fixture");
    Environment.Exit(ShareMouse.WindowsClipboardReader.RunHelper(() =>
    {
        if (blocked)
            Thread.Sleep(10000);
        return new ShareMouse.ClipboardReadSnapshot(42, ClipboardContent.Text("clipboard-qa🙂"), null, false);
    }));
    return;
}
if (args.Contains("--function-row-regression")) { FunctionRowRegression.Run(); return; }
if (args.Contains("--ble-context-regression")) { await SharingRegression.CheckBleTransportContext(); return; }
if (args.Contains("--input-ack-route-regression")) { await SharingRegression.CheckInputAckRoute(); return; }
if (args.Contains("--input-stall-regression")) { await SharingRegression.CheckInputStall(); return; }
if (args.Contains("--file-window-regression")) { await SharingRegression.CheckFileWindow(); return; }
if (args.Contains("--link-speed-regression")) { await SharingRegression.CheckLinkSpeed(); return; }
if (args.Contains("--new-acceptance-regression")) { await SharingRegression.CheckNewAcceptance(); return; }
if (args.Contains("--clipboard-reader-regression")) { await ClipboardReaderRegression.Run(); return; }
if (args.Contains("--native-scroll-hook-regression")) { NativeScrollHookRegression.Run(args.Contains("--legacy-native-send")); return; }
if (args.Contains("--native-click-regression")) { NativeClickRegression.Run(args.Contains("--legacy-input-context")); return; }

if (args.Contains("--compact-ownership-regression")) { await SharingRegression.CheckCompactOwnership(); return; }
if (args.Contains("--ble-scroll-pressure-regression")) { await SharingRegression.CheckBLEScrollPressure(); return; }
if (args.Contains("--relative-motion-regression")) { await SharingRegression.CheckRelativeMotion(); return; }
if (args.Contains("--network-recovery-regression")) { await SharingRegression.CheckNetworkRecovery(); return; }

if (args.Contains("--windows-input-status-check"))
{
    var state = ShareMouse.WindowsInputStatus.Capture();
    var blocked = state["input_injection_blocked"]!.GetValue<bool>();
    var rejected = false;
    try
    {
        ShareMouse.WindowsInputStatus.EnsureCanInject();
    }
    catch (IOException e) when (e.Message.StartsWith("input_blocked_by_integrity_level", StringComparison.Ordinal)) { rejected = true; }
    if (blocked != rejected)
        throw new Exception("Input privilege guard disagrees with foreground state");
    Console.WriteLine(state.ToJsonString());
    Console.WriteLine("Input privilege guard matched: " + (blocked ? "blocked" : "allowed"));
    return;
}
if (args.Contains("--computer-use-quality-regression")) { await ComputerUseQualityRegression.Run(); return; }
if (args.Contains("--computer-use-regression")) { await ComputerUseRegression.Run(); return; }
if (args.Contains("--repeated-approval-regression")) { await SharingRegression.CheckRepeatedApproval(); return; }
if (args.Contains("--bulk-route-regression")) { await SharingRegression.CheckBulkRoute(); return; }
if (args.Contains("--dual-link-regression")) { await SharingRegression.CheckDualLinkReconnect(); return; }
if (args.Contains("--input-transport-regression")) { await SharingRegression.CheckInputTransport(); return; }
if (args.Contains("--sharing-regression")) { await SharingRegression.Run(); return; }
if (args.Contains("--feedback-regression")) { await SharingRegression.CheckAcceptanceFeedback(); return; }
if (args.Contains("--layout-regression")) { await SharingRegression.CheckLayoutConsistency(); return; }
if (args.Contains("--file-transfer-regression")) { await SharingRegression.CheckFileTransfers(); return; }
if (args.Contains("--history-regression")) { await SharingRegression.CheckHistoryRealtime(); return; }
if (args.Contains("--bluetooth-pairing-regression")) { await SharingRegression.CheckBluetoothPairing(); return; }

if (args.Length != 1) throw new ArgumentException("Expected a local probe configuration path.");
var json = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
var config = JsonSerializer.Deserialize<ProbeConfig>(File.ReadAllText(args[0]), json)!;
if (config.Mode == "ble")
{
    using var ble = new BleDiscovery();
    ble.Status += Console.WriteLine;
    ble.Found += (candidateId, _) => Console.WriteLine("BLECandidate id=" + candidateId);
    await ble.StartAsync();
    await Task.Delay(TimeSpan.FromSeconds(config.Seconds));
    return;
}
var id = new PeerIdentityStore(config.Directory).LoadOrCreate().Value.ToString("D");
using var identity = new IdentityStore(id);
if (config.Mode == "identity")
{
    Console.WriteLine(JsonSerializer.Serialize(new
    {
        peerID = id,
        publicKey = identity.Identity.PublicKey,
        certificate = Convert.ToBase64String(identity.Certificate.RawData)
    }, json));
    return;
}
var registry = new PeerRegistry(config.Directory);
foreach (var peer in config.TrustedPeers ?? [])
{
    registry.Remember(new(peer, config.ExpectedPeers![peer]), "Explicitly trusted integration peer");
    registry.SetPreferences(peer, true, false);
}
if (config.Trusted && config.ExpectedPeerID is not null && config.ExpectedPublicKey is not null)
{
    registry.Remember(new(config.ExpectedPeerID, config.ExpectedPublicKey), "Integration peer");
    registry.SetPreferences(config.ExpectedPeerID, true, true);
}
await using var manager = new SessionManager(id, "Windows integration peer", identity, registry, config.PairCode, config.Password,
    peer => config.ExpectedPeers?.GetValueOrDefault(peer.PeerID) == peer.PublicKey
        || peer.PeerID == config.ExpectedPeerID && peer.PublicKey == config.ExpectedPublicKey,
    _ => true, Console.WriteLine);
GroupManager? group = null;
if (config.GroupMode is not null)
{
    group = new GroupManager(id, "Windows group fixture", identity.Identity.PublicKey,
        [new ScreenGeometry(id + ":fixture", id, "Protocol fixture", 1, 1920, 1080, true, 0, 0)], config.Directory,
        manager, registry, member => Task.FromResult(config.ExpectedPeers?.GetValueOrDefault(member.PeerID) == member.PublicKey), Console.WriteLine);
    group.Start();
    manager.Changed += values => { _ = group.ConnectionsChanged(values); };
}
var connected = 0;
manager.Changed += sessions =>
{
    if (sessions.Any(s => s.PeerID == config.ExpectedPeerID))
        Interlocked.Exchange(ref connected, 1);
    Console.WriteLine("SessionCount=" + sessions.Length);
};
var echoCount = 0;
long echoBytes = 0;
var echoInvalid = false;
manager.Receive("probe", async (peerId, payload) =>
{
    if (config.Mode == "listen")
        await manager.SendAsync(peerId, "probe", payload);
    else
    {
        if (!payload.AsSpan().SequenceEqual(Block(echoCount, config.Workload ?? "strings")))
            echoInvalid = true;
        Interlocked.Add(ref echoBytes, payload.Length);
        Interlocked.Increment(ref echoCount);
    }
});
manager.Start(config.ListenPort ?? config.Port);
if ((config.Transport == "quic" || config.SecondaryTransport == "quic") && !await manager.StartQuicListener(config.ListenPort ?? config.Port))
    throw new PlatformNotSupportedException("QUIC unavailable.");
using var discovery = new LanDiscovery(config.Port);
discovery.Changed += candidates =>
{
    foreach (var candidate in candidates)
        Console.WriteLine("LANCandidate endpoint=" + candidate.Host + ":" + candidate.Port);
};
if (config.GroupMode == "create") await group!.Create("Integration group");
TaskCompletionSource<string>? groupReply = null;
manager.Receive("group-check", async (peerId, payload) =>
{
    var text = Encoding.UTF8.GetString(payload);
    if (config.GroupTest == "observer" && group is not null)
    {
        if (text == "try-locked")
        {
            bool denied = false;
            try
            {
                var lease = await group.BeginEdit("layout");
                await group.Release(lease);
            }
            catch { denied = true; }
            await manager.SendAsync(peerId, "group-check", Encoding.UTF8.GetBytes(denied ? "lock-denied" : "lock-incorrectly-granted"));
        }
        else if (text == "verify-config")
        {
            await WaitUntil(() => group.Active?.Configs.FirstOrDefault(c => c.Id == group.Active.CurrentConfigID)?.WindowsToMac.GetValueOrDefault("ControlLeft") == "AltLeft", 10);
            await manager.SendAsync(peerId, "group-check", Encoding.UTF8.GetBytes("config-ok"));
        }
        else if (text == "verify-layout")
        {
            await WaitUntil(() => group.Active?.Layout.Last().Scale == 2, 10);
            await manager.SendAsync(peerId, "group-check", Encoding.UTF8.GetBytes("layout-ok"));
        }
    }
    else
        groupReply?.TrySetResult(text);
});
if (config.Mode == "connect")
{
    await manager.ConnectAsync(config.Host!, config.Port, config.PairCode, config.Password, config.Trusted, config.Transport ?? "tcp");
    if (config.SecondaryTransport is { } secondary)
    {
        var before = manager.CurrentSessions().Single().SessionID;
        await manager.ConnectAsync(config.Host!, config.Port, null, null, kind: secondary);
        var combined = manager.CurrentSessions().Single();
        if (combined.SessionID != before || !combined.Capabilities.Contains("tcp") || !combined.Capabilities.Contains(secondary))
            throw new InvalidDataException("Additional transport did not attach to the existing Session.");
        Console.WriteLine("PASS: multiple transports share one Session");
        if (config.DisconnectPrimary)
        {
            manager.DisconnectTransport(config.ExpectedPeerID!, "tcp");
            var deadline = DateTime.UtcNow.AddSeconds(5);
            while (manager.CurrentSessions().Any(s => s.Capabilities.Contains("tcp")) && DateTime.UtcNow < deadline)
                await Task.Delay(50);
            if (manager.CurrentSessions().Single().SessionID != before)
                throw new InvalidDataException("Session lost after TCP disconnect.");
            Console.WriteLine("PASS: Session retained after TCP disconnect");
        }
    }
}
if (config.GroupMode is not null && group is not null)
{
    if (config.GroupMode == "join")
        await group.Join(config.ExpectedPeerID!);
    if (config.GroupRecommendPeer is { } recommended)
    {
        await WaitUntil(() => group.Active?.Members.Length == 2 && manager.CurrentSessions().Any(s => s.PeerID == recommended), 40);
        await group.Recommend(recommended);
    }
    await WaitUntil(() => group.Active?.Members.Length == (config.Workload is "input" or "clipboard" or "files" or "history" or "rich" ? 2 : 3) && group.Online.Length == (config.Workload is "input" or "clipboard" or "files" or "history" or "rich" ? 2 : 3), 50);
    if (config.Workload == "history")
    {
        using var context = new FixtureInputContext();
        var history = context.Invoke(() => new HistoryService(id, config.Directory, manager, context));
        var longText = new string('中', 25000) + " history ✓";
        Action<SharedGroup?, GroupEditLock[], string[], SharedGroup[]> update = (state, locks, online, saved) => context.Post(_ => history.Update(state, online), null);
        group.Changed += update;
        context.Invoke(() => { history.Update(group.Active, group.Online); history.Configure(3, "KeyH", ["Meta", "Shift"]); return true; });
        await context.Invoke(() => history.Start());
        var ready = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var shared = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        manager.Receive("history-check", async (peer, data) =>
        {
            var command = Encoding.UTF8.GetString(data);
            if (config.Mode == "listen" && command == "ready")
            {
                context.Invoke(() => { history.Remember("favorite", timestamp: 100, favorite: true); history.Remember("evicted", timestamp: 1); history.Remember("normal", timestamp: 200); history.Remember(longText, timestamp: 300); history.Remember(longText, timestamp: 301); if (history.Entries.Length != 3 || history.Entries.Count(e => e.Text == longText) != 1 || history.Entries.Any(e => e.Text == "evicted")) throw new Exception("History dedupe/capacity failed."); return true; });
                await manager.SendAsync(peer, "history-check", Encoding.UTF8.GetBytes("ready-ok"));
            }
            if (config.Mode == "listen" && command == "share")
            {
                context.Invoke(() => { history.Remember("shared favorite", favorite: true); return true; });
                await context.Invoke(() => history.ShareFavorites());
                await manager.SendAsync(peer, "history-check", Encoding.UTF8.GetBytes("share-ok"));
            }
            if (command == "ready-ok")
                ready.TrySetResult(true);
            if (command == "share-ok")
                shared.TrySetResult(true);
            return;
        });
        if (config.Mode == "listen")
        {
            await WaitUntil(() => group.Online.Length == 1, 60);
            Console.WriteLine("PASS: encrypted realtime history and manual sync/share fallback");
        }
        else
        {
            await Task.Delay(300);
            await manager.SendAsync(config.ExpectedPeerID!, "history-check", Encoding.UTF8.GetBytes("ready"));
            await ready.Task.WaitAsync(TimeSpan.FromSeconds(15));
            await WaitUntil(() => context.Invoke(() => history.Entries.Any(e => e.Text == longText)), 15);
            context.Invoke(() => { history.Remember("local"); return true; });
            await context.Invoke(() => history.Sync());
            if (!context.Invoke(() => history.Entries.Any(e => e.Text == longText) && history.Entries.Any(e => e.Text == "favorite" && e.Favorite) && history.Entries.Length == 3))
                throw new Exception("History sync failed.");
            await manager.SendAsync(config.ExpectedPeerID!, "history-check", Encoding.UTF8.GetBytes("share"));
            await shared.Task.WaitAsync(TimeSpan.FromSeconds(15));
            await WaitUntil(() => context.Invoke(() => history.Entries.Any(e => e.Text == "shared favorite" && e.Favorite)), 10);
            context.Invoke(() => { history.Configure(1, "KeyH", ["Meta", "Shift"]); history.Remember("latest ordinary retained"); history.Dispose(); history = new HistoryService(id, config.Directory, manager, context); if (history.Capacity != 1 || !history.Entries.Any(e => e.Text == "latest ordinary retained") || history.ShortcutKey != "KeyH" || history.Entries.Count(e => e.Favorite) != 2 || history.Entries.Length != 3) throw new Exception("History restart lost entries, favorites, or settings."); return true; });
            Console.WriteLine("PASS: encrypted long-text history sync, dedupe, capacity, persistent favorites and custom hotkey");
            manager.Disconnect(config.ExpectedPeerID!);
        }
        group.Changed -= update;
        context.Invoke(() => { history.Dispose(); return true; });
        return;
    }
    if (config.Workload == "files")
    {
        using var context = new FixtureInputContext();
        using var clipboard = context.Invoke(() => new ClipboardService(id, manager, context, Console.WriteLine, config.Directory));
        var source = Path.Combine(config.Directory, "selected-folder");
        var second = Path.Combine(config.Directory, "pending-cut");
        var destination = Path.Combine(config.Directory, "destination");
        Directory.CreateDirectory(destination);
        var sourceChangePrompts = 0;
        var allowChanged = false;
        var selfDanger = false;
        var dangerRequested = 0;
        string[]? dangerRoots = null;
        var reconnectDone = false;
        var pausedOnce = false;
        var pauseAtChunk = false;
        FileTransferService CreateFiles() => new(id, config.Directory, manager, clipboard, context, Console.WriteLine,
            _ => { sourceChangePrompts++; return Task.FromResult(allowChanged); }, (_, _, _) => Task.FromResult(selfDanger ? "overwrite" : "keepBoth"), _ => Task.FromResult(selfDanger ? "deleteAll" : "abort"), paths => { dangerRequested++; if (dangerRoots is not null && !paths.ToHashSet(StringComparer.OrdinalIgnoreCase).SetEquals(dangerRoots)) throw new Exception("Delete All changed from original selection to local replicas."); return Task.FromResult(false); });
        var files = context.Invoke(CreateFiles);
        Action<SharedGroup?, GroupEditLock[], string[], SharedGroup[]> update = (state, locks, online, saved) => context.Post(_ => { clipboard.Update(state, online); files.Update(state, online, manager.CurrentSessions()); }, null);
        group.Changed += update;
        context.Invoke(() => { clipboard.Update(group.Active, group.Online); files.Update(group.Active, group.Online, manager.CurrentSessions()); return true; });
        await context.Invoke(() => clipboard.Start());
        await context.Invoke(() => files.Start());
        var replies = new System.Collections.Concurrent.ConcurrentDictionary<string, TaskCompletionSource<bool>>();
        async Task Ask(string command)
        {
            var reply = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            replies[command] = reply;
            await manager.SendAsync(config.ExpectedPeerID!, "file-check", Encoding.UTF8.GetBytes(command));
            await reply.Task.WaitAsync(TimeSpan.FromSeconds(30));
        }
        manager.Receive("file-check", async (peer, payload) =>
        {
            var command = Encoding.UTF8.GetString(payload);
            if (command.StartsWith("ok:"))
            {
                if (replies.TryGetValue(command[3..], out var answer))
                    answer.TrySetResult(true);
                return;
            }
            if (config.Mode != "listen")
                return;
            if (command == "ready")
            {
                Directory.CreateDirectory(Path.Combine(source, "empty"));
                Directory.CreateDirectory(Path.Combine(source, "nested"));
                File.WriteAllBytes(Path.Combine(source, "nested", "binary.dat"), Enumerable.Range(0, 3 * 1024 * 1024).Select(n => (byte)(n % 251)).ToArray());
                File.WriteAllText(Path.Combine(source, "中文.txt"), "directory cut ✓");
                await context.Invoke(() => files.Copy([source], true));
            }
            else if (command == "paused")
            {
                await WaitUntil(() => context.Invoke(() => files.Tasks.Any(t => t.Direction == "send" && t.State == "paused")), 10);
                if (!Directory.Exists(source) || !File.Exists(Path.Combine(source, "nested", "binary.dat")))
                    throw new Exception("Paused Cut deleted source.");
            }
            else if (command == "deleted")
            {
                await WaitUntil(() => !Directory.Exists(source), 10);
            }
            else if (command == "new-cut")
            {
                Directory.CreateDirectory(second);
                File.WriteAllBytes(Path.Combine(second, "pending.dat"), new byte[1024 * 1024]);
                await context.Invoke(() => files.Copy([second], true));
            }
            else if (command == "replace")
                await context.Invoke(() => clipboard.PublishText("new copy cancels old cut"));
            else if (command == "kept")
            {
                if (!File.Exists(Path.Combine(second, "pending.dat")))
                    throw new Exception("New Copy did not cancel old Cut.");
            }
            else if (command == "changed-cut")
            {
                await context.Invoke(() => files.Copy([second], true));
                File.AppendAllText(Path.Combine(second, "pending.dat"), "changed");
            }
            else if (command == "declined")
            {
                if (sourceChangePrompts < 1 || !Directory.Exists(second))
                    throw new Exception("Source change was not confirmed or source disappeared.");
            }
            else if (command == "allow")
                context.Invoke(() => { allowChanged = true; return true; });
            else if (command == "reconnect-metadata")
            {
                await context.Invoke(() => clipboard.PublishFiles(0, 0, false));
                _ = Task.Run(async () => { try { await WaitUntil(() => group.Online.Length == 1, 10); await context.Invoke(() => clipboard.FileVersion(7, 1024)); } catch (Exception error) { Console.Error.WriteLine(error); } });
            }
            else if (command == "reconnect-done")
                reconnectDone = true;
            else if (command == "done")
            {
                var selfSource = Path.Combine(config.Directory, "self-cut-original");
                var selfTarget = Path.Combine(config.Directory, "self-cut-target");
                Directory.CreateDirectory(selfSource);
                Directory.CreateDirectory(selfTarget);
                var one = Path.Combine(selfSource, "one.txt");
                var two = Path.Combine(selfSource, "two.txt");
                File.WriteAllText(one, "one source");
                File.WriteAllText(two, "two source");
                dangerRoots = [one, two];
                var blocked = Path.Combine(selfTarget, "two.txt");
                File.WriteAllText(blocked, "protected destination");
                File.SetAttributes(blocked, FileAttributes.ReadOnly);
                context.Invoke(() => { selfDanger = true; return true; });
                await context.Invoke(() => files.Copy([one, two], true));
                var localID = await context.Invoke(() => files.Paste(selfTarget));
                if (dangerRequested != 1 || !File.Exists(two) || !File.Exists(Path.Combine(selfTarget, "one.txt")))
                    throw new Exception("Declined Delete All lost source or local replica.");
                File.SetAttributes(blocked, FileAttributes.Normal);
                File.Delete(blocked);
                await context.Invoke(() => files.Resume(localID));
                if (context.Invoke(() => files.Tasks.Single(t => t.Id == localID).State) != "completed" || File.Exists(one) || File.Exists(two) || !File.Exists(Path.Combine(selfTarget, "one.txt")) || !File.Exists(blocked))
                    throw new Exception("Self Cut retry did not keep replicas and delete only verified originals.");
                context.Invoke(() => { selfDanger = false; return true; });
                var repeated = await context.Invoke(() => files.Paste(selfTarget));
                if (context.Invoke(() => files.Tasks.Single(t => t.Id == repeated).State) != "completed")
                    throw new Exception("Self Cut replica could not provide repeated Paste.");
                Console.WriteLine("PASS: original Cut selection stays separate from self-pasted replicas, declined Delete All and partial retry");
                Console.WriteLine("PASS: encrypted directory Cut source guarded by verified receipt, replacement and change confirmation");
            }
            await manager.SendAsync(peer, "file-check", Encoding.UTF8.GetBytes("ok:" + command));
        });
        if (config.Mode == "listen")
        {
            await WaitUntil(() => reconnectDone && group.Online.Length == 1, 100);
        }
        else
        {
            await Task.Delay(300);
            await Ask("ready");
            await WaitUntil(() => context.Invoke(() => clipboard.Current?.Kind == "files"), 10);
            context.Invoke(() => { pauseAtChunk = true; files.Changed += tasks => { var task = tasks.FirstOrDefault(t => t.State == "running" && t.Received > 100000); if (pauseAtChunk && !pausedOnce && task is not null) { pausedOnce = true; files.Pause(task.Id); } }; return true; });
            var pausedID = await context.Invoke(() => files.Paste(destination));
            if (context.Invoke(() => files.Tasks.Single(t => t.Id == pausedID).State) != "paused")
                throw new Exception("File task was not paused.");
            await Ask("paused");
            if (config.SecondaryTransport == "quic")
            {
                var sessionID = manager.CurrentSessions().Single().SessionID;
                manager.DisconnectTransport(config.ExpectedPeerID!, "tcp");
                await WaitUntil(() => !manager.CurrentSessions().Single().Capabilities.Contains("tcp"), 10);
                if (manager.CurrentSessions().Single().SessionID != sessionID)
                    throw new Exception("File transport switch lost Session.");
                Console.WriteLine("PASS: encrypted file Resume retains Session after TCP to QUIC switch");
            }
            context.Invoke(() => { files.Dispose(); files = CreateFiles(); files.Update(group.Active, group.Online, manager.CurrentSessions()); return true; });
            await context.Invoke(() => files.Start());
            await context.Invoke(() => files.Resume(pausedID));
            var completed = context.Invoke(() => files.Tasks.Single(t => t.Id == pausedID));
            if (completed.State != "completed")
                throw new Exception("Resume failed: " + completed.Error + " " + string.Join(";", completed.Files.Select(f => f.Error)));
            var binary = Path.Combine(destination, "selected-folder", "nested", "binary.dat");
            if (new FileInfo(binary).Length != 3 * 1024 * 1024 || File.ReadAllBytes(binary).Where((b, n) => b != (byte)(n % 251)).Any())
                throw new Exception("Final file content differs.");
            await Ask("deleted");
            var repeatID = await context.Invoke(() => files.Paste(destination));
            if (context.Invoke(() => files.Tasks.Single(t => t.Id == repeatID).State) != "completed")
                throw new Exception("New provider repeated Paste failed.");
            await Ask("new-cut");
            await WaitUntil(() => context.Invoke(() => clipboard.Current?.FileCount == 2 && clipboard.Current.Cut == true), 10);
            context.Invoke(() => { pausedOnce = false; files.Changed += tasks => { var task = tasks.FirstOrDefault(t => t.State == "running" && t.Received > 100000); if (!pausedOnce && task is not null) { pausedOnce = true; files.Pause(task.Id); } }; return true; });
            var oldID = await context.Invoke(() => files.Paste(destination));
            await Ask("replace");
            await WaitUntil(() => context.Invoke(() => clipboard.Current?.Kind == "text"), 10);
            await context.Invoke(() => files.Resume(oldID));
            await Ask("kept");
            await Ask("changed-cut");
            await WaitUntil(() => context.Invoke(() => clipboard.Current?.Kind == "files"), 10);
            var declined = await context.Invoke(() => files.Paste(destination));
            if (context.Invoke(() => files.Tasks.Single(t => t.Id == declined).State) == "completed")
                throw new Exception("Changed source copied without permission.");
            await Ask("declined");
            await Ask("allow");
            await context.Invoke(() => files.Resume(declined));
            if (context.Invoke(() => files.Tasks.Single(t => t.Id == declined).State) != "completed")
                throw new Exception("Current version retry failed.");
            await Ask("done");
            await Ask("reconnect-metadata");
            await WaitUntil(() => context.Invoke(() => clipboard.Current?.Kind == "files" && clipboard.Current.FileCount == 0), 10);
            var preparingID = context.Invoke(() => clipboard.Current!.Id);
            manager.Disconnect(config.ExpectedPeerID!);
            await WaitUntil(() => group.Online.Length == 1, 10);
            await Task.Delay(300);
            await manager.ConnectAsync(config.Host!, config.Port, config.PairCode, config.Password);
            await WaitUntil(() => context.Invoke(() => clipboard.Current?.Id == preparingID && clipboard.Current.FileCount == 7 && clipboard.Current.FileRevision == 2), 15);
            await Ask("reconnect-done");
            Console.WriteLine("PASS: encrypted reconnect recovers newer file revision from preparing metadata");
            Console.WriteLine("PASS: encrypted chunks, final content, restart Resume, Cut replacement, changed source, and repeated Paste provider");
            manager.Disconnect(config.ExpectedPeerID!);
        }
        group.Changed -= update;
        context.Invoke(() => { files.Dispose(); return true; });
        return;
    }
    if (config.Workload == "rich")
    {
        using var context = new FixtureInputContext();
        var requests = 0;
        var published = -1;
        var clipboard = context.Invoke(() => new ClipboardService(id, manager, context, metadata => { if (metadata == "ClipboardTextRequested") requests++; Console.WriteLine(metadata); }, config.Directory));
        Action<SharedGroup?, GroupEditLock[], string[], SharedGroup[]> changed = (state, _, online, __) => context.Post(_ => clipboard.Update(state, online), null);
        group.Changed += changed;
        context.Invoke(() => { clipboard.Update(group.Active, group.Online); return true; });
        await context.Invoke(() => clipboard.Start());
        var rich = new[] {
            new ClipboardContent("png",Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jfoQAAAAASUVORK5CYII=")),
            new ClipboardContent("url",Encoding.UTF8.GetBytes("https://example.org/路径?q=😀"),"https://example.org/路径?q=😀"),
            new ClipboardContent("html",Encoding.UTF8.GetBytes("<p>"+string.Concat(Enumerable.Repeat("中文😀 <b>formatted</b>",6000))+"</p>"),"formatted text"),
            new ClipboardContent("rtf",Encoding.ASCII.GetBytes(@"{\rtf1\ansi Unicode \u20013?\u25991? \b formatted\b0}"),"中文 formatted")
        };
        var response = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        manager.Receive("rich-check", (peer, data) =>
        {
            var command = Encoding.UTF8.GetString(data);
            if (config.Mode == "listen")
                context.Post(async _ =>
                {
                    try
                    {
                        if (command.StartsWith("publish:", StringComparison.Ordinal) && int.TryParse(command[8..], out var index) && index >= 0 && index < rich.Length)
                        {
                            if (published != index)
                            {
                                if (requests != index)
                                    throw new Exception("Advanced body was not lazy.");
                                await clipboard.PublishContent(rich[index]);
                                published = index;
                                if (index == rich.Length - 1)
                                {
                                    clipboard.Dispose();
                                    clipboard = new ClipboardService(id, manager, context, metadata => { if (metadata == "ClipboardTextRequested") requests++; }, config.Directory);
                                    clipboard.Update(group.Active, group.Online);
                                    await clipboard.Start();
                                }
                                ;
                            }
                            ;
                            await manager.SendAsync(peer, "rich-check", Encoding.UTF8.GetBytes("ready:" + index));
                        }
                        if (command == "invalid")
                        {
                            try
                            {
                                await clipboard.PublishContent(new("png", new byte[24]));
                            }
                            catch (InvalidDataException) { }
                            ;
                            if (clipboard.Current?.Kind != "unsupported")
                                throw new Exception("Unsupported copy retained stale clipboard.");
                            await manager.SendAsync(peer, "rich-check", Encoding.UTF8.GetBytes("unsupported"));
                        }
                        if (command == "done")
                        {
                            if (requests != rich.Length)
                                throw new Exception("Rich body request count mismatch.");
                            Console.WriteLine("PASS: encrypted rich clipboard stays lazy and rejects invalid replacement");
                            await manager.SendAsync(peer, "rich-check", Encoding.UTF8.GetBytes("done"));
                        }
                    }
                    catch (Exception error) { Console.Error.WriteLine(error); }
                }, null);
            else
                response.TrySetResult(command);
            return Task.CompletedTask;
        });
        if (config.Mode == "listen")
            await WaitUntil(() => context.Invoke(() => requests) == rich.Length, 35);
        else
        {
            async Task<string> Ask(string message)
            {
                response = new(TaskCreationOptions.RunContinuationsAsynchronously);
                for (var retry = 0; retry < 30 && !response.Task.IsCompleted; retry++)
                {
                    await manager.SendAsync(config.ExpectedPeerID!, "rich-check", Encoding.UTF8.GetBytes(message));
                    await Task.WhenAny(response.Task, Task.Delay(100));
                }
                ;
                return await response.Task.WaitAsync(TimeSpan.FromSeconds(10));
            }
            for (var index = 0; index < rich.Length; index++)
            {
                if (await Ask("publish:" + index) != "ready:" + index)
                    throw new Exception("Rich metadata failed.");
                await WaitUntil(() => context.Invoke(() => clipboard.Current?.Kind == rich[index].Kind), 10);
                var actual = await context.Invoke(() => clipboard.Content());
                if (actual.Kind != rich[index].Kind || !actual.Data.SequenceEqual(rich[index].Data) || actual.PlainText != rich[index].PlainText)
                    throw new Exception("Rich format changed during segmented transfer.");
            }
            if (await Ask("invalid") != "unsupported")
                throw new Exception("Invalid replacement failed.");
            await WaitUntil(() => context.Invoke(() => clipboard.Current?.Kind == "unsupported"), 10);
            var rejected = false;
            try
            {
                await context.Invoke(() => clipboard.Content());
            }
            catch (IOException) { rejected = true; }
            ;
            if (!rejected)
                throw new Exception("Old rich body pasted after unsupported Copy.");
            await Ask("done");
            Console.WriteLine("PASS: encrypted PNG, URL, Unicode HTML, RTF and Last Copy Wins invalid replacement");
        }
        await Task.Delay(3000);
        group.Changed -= changed;
        context.Invoke(() => { clipboard.Dispose(); return true; });
        return;
    }
    if (config.Workload == "clipboard")
    {
        using var context = new FixtureInputContext();
        var requests = 0;
        using var clipboard = context.Invoke(() => new ClipboardService(id, manager, context, metadata => { if (metadata == "ClipboardTextRequested") requests++; Console.WriteLine(metadata); }));
        Action<SharedGroup?, GroupEditLock[], string[], SharedGroup[]> changed = (state, locks, online, saved) => context.Post(_ => clipboard.Update(state, online), null);
        group.Changed += changed;
        context.Invoke(() => { clipboard.Update(group.Active, group.Online); return true; });
        await context.Invoke(() => clipboard.Start());
        var ready = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var lazy = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var replacement = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var longText = new string('中', 30000) + "\nWindows↔macOS✓";
        manager.Receive("clipboard-check", (peer, payload) =>
        {
            var command = Encoding.UTF8.GetString(payload);
            if (command == "request-ready" && config.Mode == "listen")
                _ = Task.Run(async () =>
                {
                    if (context.Invoke(() => clipboard.Current is null))
                        await context.Invoke(() => clipboard.PublishText(longText));
                    await manager.SendAsync(peer, "clipboard-check", Encoding.UTF8.GetBytes("ready"));
                });
            if (command == "ready")
                ready.TrySetResult(true);
            if (command == "received" && config.Mode == "listen")
                _ = Task.Run(async () =>
                {
                    if (context.Invoke(() => requests) != 1)
                        throw new Exception("Text was not lazy or was requested more than once.");
                    Console.WriteLine("PASS: encrypted clipboard serves text only on request");
                    await manager.SendAsync(peer, "clipboard-check", Encoding.UTF8.GetBytes("lazy-ok"));
                });
            if (command == "lazy-ok")
                lazy.TrySetResult(true);
            if (command == "replacement" && config.Mode == "listen")
                _ = Task.Run(async () =>
                {
                    await WaitUntil(() => context.Invoke(() => clipboard.Current?.SourcePeerID == peer), 10);
                    if (await context.Invoke(() => clipboard.Text()) != "newest copy")
                        throw new Exception("Last Copy Wins failed.");
                    await context.Invoke(() => clipboard.PublishText("offline source"));
                    await manager.SendAsync(peer, "clipboard-check", Encoding.UTF8.GetBytes("replacement-ok"));
                });
            if (command == "replacement-ok")
                replacement.TrySetResult(true);
            return Task.CompletedTask;
        });
        if (config.Mode == "listen")
        {
            await WaitUntil(() => context.Invoke(() => requests) == 1, 25);
            await WaitUntil(() => group.Online.Length == 1, 25);
        }
        else
        {
            for (var retry = 0; retry < 50 && !ready.Task.IsCompleted; retry++)
            {
                await manager.SendAsync(config.ExpectedPeerID!, "clipboard-check", Encoding.UTF8.GetBytes("request-ready"));
                await Task.WhenAny(ready.Task, Task.Delay(100));
            }
            await ready.Task.WaitAsync(TimeSpan.FromSeconds(5));
            await WaitUntil(() => context.Invoke(() => clipboard.Current?.Kind == "text"), 10);
            if (await context.Invoke(() => clipboard.Text()) != longText)
                throw new Exception("Long Unicode text was corrupted.");
            await manager.SendAsync(config.ExpectedPeerID!, "clipboard-check", Encoding.UTF8.GetBytes("received"));
            await lazy.Task.WaitAsync(TimeSpan.FromSeconds(10));
            await context.Invoke(() => clipboard.PublishText("newest copy"));
            await manager.SendAsync(config.ExpectedPeerID!, "clipboard-check", Encoding.UTF8.GetBytes("replacement"));
            await replacement.Task.WaitAsync(TimeSpan.FromSeconds(15));
            await WaitUntil(() => context.Invoke(() => clipboard.Current?.SourcePeerID == config.ExpectedPeerID), 10);
            manager.Disconnect(config.ExpectedPeerID!);
            await WaitUntil(() => group.Online.Length == 1, 10);
            bool unavailable = false;
            try
            {
                await context.Invoke(() => clipboard.Text());
            }
            catch (IOException) { unavailable = true; }
            if (!unavailable)
                throw new Exception("Disconnected uncached source did not report an error.");
            Console.WriteLine("PASS: encrypted lazy Unicode text, Last Copy Wins, and offline-source error");
        }
        group.Changed -= changed;
        context.Invoke(() => { clipboard.Dispose(); return true; });
        await Task.Delay(TimeSpan.FromSeconds(config.Seconds));
        return;
    }
    if (config.Workload == "input")
    {
        using var context = new FixtureInputContext();
        using var clipboard = context.Invoke(() => new ClipboardService(id, manager, context, Console.WriteLine));
        var pasteEntryID = Guid.NewGuid().ToString("D");
        var pasteWaiting = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var pasteDone = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var held = new HashSet<string>();
        var buttons = new HashSet<int>();
        var observedHeld = false;
        var committedText = new StringBuilder();
        var semanticCommands = new List<string>();
        var imeText = string.Concat(Enumerable.Repeat("来源中文😀", 2000));
        var targetReady = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var advanced = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var targetHeld = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var input = context.Invoke(() => new InputService(id, "windows", manager, context,
            (value, _, _, _) =>
            {
                if (value.Type == "text")
                    committedText.Append(value.Text);
                if (value.Type == "command")
                    semanticCommands.Add(value.Command!);
                if (value.Type == "keyDown")
                    held.Add(value.Key!);
                if (value.Type == "keyUp")
                    held.Remove(value.Key!);
                if (value.Type == "buttonDown")
                    buttons.Add(value.Button);
                if (value.Type == "buttonUp")
                    buttons.Remove(value.Button);
                if (held.Contains("KeyA") && held.Contains("ControlLeft") && buttons.Contains(0))
                    observedHeld = true;
            }, (_, _) => { }, Console.WriteLine));
        context.Invoke(() =>
        {
            input.ClipboardEntryID = () => pasteEntryID;
            input.CommandHandler = async (command, source, entryID) =>
            {
                if (command != "paste")
                    return false;
                if (entryID is null)
                    throw new Exception("Paste entry binding absent.");
                await manager.SendAsync(source, "input-check", Encoding.UTF8.GetBytes("paste-waiting"));
                await clipboard.WaitForEntry(entryID, source);
                if (clipboard.Current?.Id != entryID)
                    throw new Exception("Paste used an older clipboard entry.");
                await manager.SendAsync(source, "input-check", Encoding.UTF8.GetBytes("paste-ok"));
                return true;
            };
            return true;
        });
        Action<SharedGroup?, GroupEditLock[], string[], SharedGroup[]> inputChanged = (state, locks, online, saved) => context.Post(_ => { input.Update(state, online, manager.CurrentSessions()); clipboard.Update(state, online); }, null);
        group.Changed += inputChanged;
        manager.Receive("input-check", (peer, payload) =>
        {
            var text = Encoding.UTF8.GetString(payload);
            if (text == "ready")
                targetReady.TrySetResult(true);
            if (text == "request-ready" && config.Mode == "listen")
                _ = Task.Run(async () =>
                {
                    await WaitUntil(() => context.Invoke(() => input.Enabled), 10);
                    await manager.SendAsync(peer, "input-check", Encoding.UTF8.GetBytes("ready"));
                });
            if (text == "held-ok")
                targetHeld.TrySetResult(true);
            if (text == "advanced-ok")
                advanced.TrySetResult(true);
            if (text == "paste-waiting")
                pasteWaiting.TrySetResult(true);
            if (text == "paste-ok")
                pasteDone.TrySetResult(true);
            if (text == "check-advanced")
                _ = Task.Run(async () => { await WaitUntil(() => context.Invoke(() => committedText.ToString() == imeText && semanticCommands.Contains("undo") && semanticCommands.Contains("redo") && held.Count == 0 && buttons.Contains(0)), 12); await manager.SendAsync(peer, "input-check", Encoding.UTF8.GetBytes("advanced-ok")); });
            if (text == "check-held")
                _ = Task.Run(async () =>
                {
                    await WaitUntil(() => context.Invoke(() => observedHeld), 10);
                    await manager.SendAsync(peer, "input-check", Encoding.UTF8.GetBytes("held-ok"));
                });
            return Task.CompletedTask;
        });
        context.Invoke(() => { input.Update(group.Active, group.Online, manager.CurrentSessions()); clipboard.Update(group.Active, group.Online); return true; });
        await context.Invoke(() => clipboard.Start());
        if (config.Mode == "listen")
        {
            await context.Invoke(() => input.Enable());
            await manager.SendAsync(group.Online.Single(p => p != id), "input-check", Encoding.UTF8.GetBytes("ready"));
            await WaitUntil(() => context.Invoke(() => observedHeld && held.Count == 0 && buttons.Count == 0), 25);
            Console.WriteLine("PASS: encrypted input disconnect releases keys, modifiers, and mouse buttons (protocol fixture)");
        }
        else
        {
            for (var retry = 0; retry < 50 && !targetReady.Task.IsCompleted; retry++)
            {
                await manager.SendAsync(config.ExpectedPeerID!, "input-check", Encoding.UTF8.GetBytes("request-ready"));
                await Task.WhenAny(targetReady.Task, Task.Delay(200));
            }
            await targetReady.Task.WaitAsync(TimeSpan.FromSeconds(5));
            await context.Invoke(() => input.Enable());
            context.Invoke(() =>
            {
                input.Update(group.Active, group.Online, manager.CurrentSessions());
                input.Capture(new("move", DeltaX: -2200));
                input.Capture(new("keyDown", "ControlLeft"));
                input.Capture(new("keyDown", "KeyA"));
                input.Capture(new("buttonDown", Button: 0));
                return true;
            });
            await manager.SendAsync(config.ExpectedPeerID!, "input-check", Encoding.UTF8.GetBytes("check-held"));
            await targetHeld.Task.WaitAsync(TimeSpan.FromSeconds(15));
            context.Invoke(() =>
            {
                input.Capture(new("keyUp", "KeyA"));
                input.Capture(new("keyDown", "KeyZ"));
                input.Capture(new("keyUp", "KeyZ"));
                input.Capture(new("keyDown", "ShiftLeft"));
                input.Capture(new("keyDown", "KeyZ"));
                input.Capture(new("keyUp", "KeyZ"));
                input.Capture(new("keyUp", "ShiftLeft"));
                var screen = input.RemoteScreenID ?? throw new Exception("No remote IME target.");
                if (!input.BeginSourceIME() || !input.SourceCommand("KeyZ", ["ControlLeft", "KeyZ"]) || !input.CommitText(imeText, screen) || input.CommitText("wrong target", Guid.NewGuid().ToString("D")))
                    throw new Exception("IME committed text target binding failed.");
                return true;
            });
            await manager.SendAsync(config.ExpectedPeerID!, "input-check", Encoding.UTF8.GetBytes("check-advanced"));
            await advanced.Task.WaitAsync(TimeSpan.FromSeconds(15));
            var oldEntry = new ClipboardEntry(Guid.NewGuid().ToString("D"), id, 1, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), "text", 0);
            await manager.SendAsync(config.ExpectedPeerID!, "clipboard", JsonSerializer.SerializeToUtf8Bytes(new ClipboardPacket { Type = "metadata", GroupID = group.Active!.Id, Entry = oldEntry }, json));
            context.Invoke(() => input.SourceCommand("KeyV", ["ControlLeft", "KeyV"]));
            await pasteWaiting.Task.WaitAsync(TimeSpan.FromSeconds(5));
            if (pasteDone.Task.IsCompleted)
                throw new Exception("Paste did not wait for its bound metadata.");
            await manager.SendAsync(config.ExpectedPeerID!, "clipboard", JsonSerializer.SerializeToUtf8Bytes(new ClipboardPacket { Type = "metadata", GroupID = group.Active!.Id, Entry = new ClipboardEntry(pasteEntryID, id, 2, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), "text", 0) }, json));
            await pasteDone.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Console.WriteLine("PASS: encrypted Paste command overtakes metadata and waits for its bound clipboard entry");
            context.Invoke(() => { input.Capture(new("keyDown", "ControlLeft")); input.Capture(new("keyDown", "KeyA")); return true; });
            Console.WriteLine("PASS: encrypted Undo/Redo, Unicode committed text, target binding and keyboard-only release");
            Console.WriteLine("PASS: encrypted input reaches active target (protocol fixture)");
            manager.Disconnect(config.ExpectedPeerID!);
        }
        group.Changed -= inputChanged;
        context.Invoke(() => { input.Dispose(); return true; });
        await Task.Delay(TimeSpan.FromSeconds(config.Seconds));
        return;
    }
    var groupId = group.Active!.Id;
    Console.WriteLine("PASS: three Peer group and direct mesh");
    if (config.GroupTest == "controller")
    {
        var observer = group.Active.Members.OrderBy(m => m.JoinOrder).Last().PeerID;
        var lease = await group.BeginEdit("layout");
        groupReply = new(TaskCreationOptions.RunContinuationsAsynchronously);
        await manager.SendAsync(observer, "group-check", Encoding.UTF8.GetBytes("try-locked"));
        if (await groupReply.Task.WaitAsync(TimeSpan.FromSeconds(20)) != "lock-denied")
            throw new Exception("Edit lock was not exclusive.");
        Console.WriteLine("PASS: layout lock excludes second editor");
        var layout = group.Active.Layout.Select((screen, index) => index == group.Active.Layout.Length - 1 ? screen with { Scale = 2 } : screen).ToArray();
        await group.CommitLayout(layout, lease);
        groupReply = new(TaskCreationOptions.RunContinuationsAsynchronously);
        await manager.SendAsync(observer, "group-check", Encoding.UTF8.GetBytes("verify-layout"));
        if (await groupReply.Task.WaitAsync(TimeSpan.FromSeconds(20)) != "layout-ok")
            throw new Exception("Layout did not synchronize.");
        Console.WriteLine("PASS: layout commit synchronized and persisted");
        var configLease = await group.BeginEdit("config");
        var before = group.Active!;
        if (before.Configs.Select(c => c.OwnerPeerID).Distinct().Count() != 3)
            throw new Exception("Joining peers did not share private configs.");
        var selected = before.Configs.First(c => c.OwnerPeerID == id);
        var configs = before.Configs.Select(c => c.Id == selected.Id ? c with { WindowsToMac = new() { { "ControlLeft", "AltLeft" } } } : c).ToArray();
        await group.CommitConfigs(configs, selected.Id, configLease);

        var saved = JsonSerializer.Deserialize<GroupStore>(File.ReadAllText(Path.Combine(config.Directory, "groups.json")), new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase })!;
        if (saved.Groups.Single(g => g.Id == saved.ActiveGroupID).CurrentConfigID != selected.Id)
            throw new Exception("Config selection did not persist.");
        groupReply = new(TaskCreationOptions.RunContinuationsAsynchronously);
        await manager.SendAsync(observer, "group-check", Encoding.UTF8.GetBytes("verify-config"));
        if (await groupReply.Task.WaitAsync(TimeSpan.FromSeconds(20)) != "config-ok")
            throw new Exception("Config failed to synchronize.");
        Console.WriteLine("PASS: member configs joined; locked mapping synchronized and selection persisted");
        await WaitUntil(() => group.Active?.LeaderID == id && group.Online.Length == 2, 45);
        if (group.Active!.Id != groupId)
            throw new Exception("Group dissolved after leader disconnect.");
        var stored = JsonSerializer.Deserialize<GroupStore>(File.ReadAllText(Path.Combine(config.Directory, "groups.json")), json)!;
        if (stored.ActiveGroupID != groupId || stored.Groups.Single(g => g.Id == groupId).Layout.Last().Scale != 2)
            throw new Exception("Group persistence failed.");
        Console.WriteLine("PASS: leader handoff retains group and shared state");
    }
    await Task.Delay(TimeSpan.FromSeconds(config.Seconds));
    return;
}
if (config.Mode == "connect" && config.Workload is { } workload)
{
    var count = workload == "load" ? 256 : 100;
    for (var index = 0; index < count; index++)
    {
        await manager.SendAsync(config.ExpectedPeerID!, "probe", Block(index, workload));
        if (workload != "load")
            await Task.Delay(20);
    }
    var deadline = DateTime.UtcNow.AddSeconds(20);
    while (Volatile.Read(ref echoCount) < count && DateTime.UtcNow < deadline)
        await Task.Delay(50);
    if (Volatile.Read(ref echoCount) != count || echoInvalid)
        throw new InvalidDataException("Transport payload mismatch.");
    Console.WriteLine($"PASS: TLS transport {workload} blocks={count} bytes={Interlocked.Read(ref echoBytes)}");
}
await Task.Delay(TimeSpan.FromSeconds(config.Seconds));
if (Volatile.Read(ref connected) == 0)
    throw new Exception("No authenticated peer Session.");
Console.WriteLine("PASS: authenticated TLS 1.3 Session");

static async Task WaitUntil(Func<bool> condition, int seconds)
{
    var deadline = DateTime.UtcNow.AddSeconds(seconds);
    while (!condition() && DateTime.UtcNow < deadline)
        await Task.Delay(50);
    if (!condition())
        throw new TimeoutException("Group condition not reached.");
}

static byte[] Block(int index, string workload)
{
    var text = Encoding.UTF8.GetBytes($"ShareMouse 双向通信 #{index}\n");
    if (workload != "load")
        return text;
    var result = new byte[32768];
    Array.Fill(result, (byte)(index % 251));
    text.CopyTo(result, 0);
    return result;
}

record ProbeConfig(string Mode, string Directory, string? Host, int Port, string PairCode, string Password,
    string? ExpectedPeerID, string? ExpectedPublicKey, bool Trusted, int Seconds, int? ListenPort = null, string? Workload = null, string? Transport = null, string? SecondaryTransport = null, bool DisconnectPrimary = false, string? GroupMode = null, string? GroupTest = null, Dictionary<string, string>? ExpectedPeers = null, string? GroupRecommendPeer = null, string[]? TrustedPeers = null);
