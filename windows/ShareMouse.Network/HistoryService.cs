using System.Text;
using System.Text.Json;
using ShareMouse.Core;
namespace ShareMouse.Network;

public sealed record HistoryEntry(string Id, string Text, long Timestamp, bool Favorite);
public sealed class HistoryService : IDisposable
{
    private sealed record Saved(HistoryEntry[] Entries, int Capacity, string ShortcutKey, string[] Modifiers, int VisibleCount = 5, string PreferredSide = "right");
    private sealed record Packet(string Type, string GroupID, string RequestID, HistoryEntry? Entry = null, int? Total = null, int? Offset = null, byte[]? Data = null, bool? Sharing = null);
    private sealed class Incoming(string peer, TaskCompletionSource<bool>? completion = null)
    {
        public string Peer = peer; public TaskCompletionSource<bool>? Completion = completion; public HistoryEntry? Entry; public int Total, Count; public MemoryStream Data = new();
    }
    private readonly string id, file; private readonly SessionManager manager; private readonly SynchronizationContext context;
    private SharedGroup? group; private HashSet<string> online = []; private bool disposed, started, syncing, syncAgain;
    private readonly Dictionary<string, Incoming> incoming = [];
    private readonly HashSet<string> held = [], consumed = [];
    private readonly List<HistoryEntry> entries = [];
    public HistoryEntry[] Entries => entries.ToArray();
    public int VisibleCount { get; private set; } = 5;
    public string PreferredSide { get; private set; } = "right";
    public int Capacity { get; private set; } = 50;
    public string ShortcutKey { get; private set; } = "KeyV";
    public string[] Modifiers { get; private set; } = ["Control", "Alt"];
    public string Status { get; private set; } = "在线设备实时同步；离线历史保留在本机";
    public Action? Opened
    {
        get; set;
    }
    public event Action? Changed;
    private static readonly JsonSerializerOptions json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull };
    public HistoryService(string id, string directory, SessionManager manager, SynchronizationContext context)
    {
        this.id = id;
        this.manager = manager;
        this.context = context;
        file = Path.Combine(directory, "clipboard-history.json");
        if (File.Exists(file))
        {
            var saved = JsonSerializer.Deserialize<Saved>(File.ReadAllText(file), json) ?? throw new IOException("Invalid clipboard history.");
            entries.AddRange(saved.Entries);
            Capacity = saved.Capacity;
            ShortcutKey = saved.ShortcutKey;
            Modifiers = saved.Modifiers;
            VisibleCount = Math.Clamp(saved.VisibleCount, 1, 9);
            PreferredSide = saved.PreferredSide == "left" ? "left" : "right";
        }
        manager.Receive("history", (peer, data) => { context.Post(async _ => { try { await Receive(peer, data); } catch { Status = "历史同步未完成"; Changed?.Invoke(); } }, null); return Task.CompletedTask; });
    }
    public async Task Start()
    {
        await manager.SetCapabilityAsync("clipboard-history", true);
        started = true;
        if (online.Any(peer => peer != id))
            _ = Sync();
    }
    public void Update(SharedGroup? value, string[] peers)
    {
        var different = group?.Id != value?.Id;
        var joined = peers.Except(online).Any(peer => peer != id);
        group = value;
        online = peers.ToHashSet();
        foreach (var key in incoming.Where(p => different || !online.Contains(p.Value.Peer)).Select(p => p.Key).ToArray())
            Fail(key);
        if (started && value is not null && (different || joined))
            _ = Sync();
    }
    private void Save()
    {
        entries.Sort((a, b) => a.Timestamp == b.Timestamp ? string.CompareOrdinal(b.Id, a.Id) : b.Timestamp.CompareTo(a.Timestamp));
        var remaining = Math.Max(1, Capacity - entries.Count(e => e.Favorite));
        entries.RemoveAll(e => { if (e.Favorite) return false; if (remaining > 0) { remaining--; return false; } return true; });
        File.WriteAllText(file + ".tmp", JsonSerializer.Serialize(new Saved(Entries, Capacity, ShortcutKey, Modifiers, VisibleCount, PreferredSide), json));
        File.Move(file + ".tmp", file, true);
        Changed?.Invoke();
    }
    public void Remember(string text, string? entryID = null, long? timestamp = null, bool favorite = false, bool broadcast = true)
    {
        if (Encoding.UTF8.GetByteCount(text) > ClipboardService.MaximumTextBytes)
            throw new IOException("History entry too large.");
        var old = entries.FirstOrDefault(e => e.Text == text);
        entries.RemoveAll(e => e.Text == text);
        var time = timestamp ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var selectedID = (old?.Timestamp ?? 0) > time ? old!.Id : entryID ?? old?.Id ?? Guid.NewGuid().ToString("D");
        entries.Add(new(selectedID, text, Math.Max(time, old?.Timestamp ?? 0), favorite || old?.Favorite == true));
        Save();
        if (broadcast && entries.FirstOrDefault(e => e.Text == text) is { } item)
            _ = Broadcast(item);
    }
    private async Task Broadcast(HistoryEntry entry)
    {
        if (group is null || disposed)
            return;
        var groupID = group.Id;
        foreach (var peer in online.Where(p => p != id).ToArray())
        {
            try
            {
                await Transmit(peer, groupID, Guid.NewGuid().ToString("D"), [entry], true);
            }
            catch { Status = "部分设备同步未完成；可点击同步重试"; Changed?.Invoke(); }
        }
    }
    public string? Text(string entryID) => entries.FirstOrDefault(e => e.Id == entryID)?.Text;
    public void Favorite(string entryID)
    {
        var index = entries.FindIndex(e => e.Id == entryID);
        if (index >= 0)
        {
            entries[index] = entries[index] with
            {
                Favorite = !entries[index].Favorite
            };
            Save();
        }
    }
    public void Configure(int capacity, string key, string[] modifiers)
    {
        if (capacity is < 1 or > 1000 || key.Length is < 1 or > 32 || modifiers.Length == 0 || modifiers.Any(m => m is not ("Control" or "Alt" or "Shift" or "Meta")))
            throw new ArgumentException("Invalid history settings.");
        Capacity = capacity;
        ShortcutKey = key;
        Modifiers = modifiers;
        Save();
    }
    public void ConfigurePopup(int visibleCount, string preferredSide)
    {
        if (visibleCount is < 1 or > 9 || preferredSide is not ("left" or "right"))
            throw new ArgumentException("Invalid popup settings.");
        VisibleCount = visibleCount;
        PreferredSide = preferredSide;
        Save();
    }
    public bool Capture(CapturedInput input)
    {
        if (input.Key is not { } key || input.Type is not ("keyDown" or "keyUp"))
            return false;
        if (input.Type == "keyUp")
        {
            held.Remove(key);
            return consumed.Remove(key);
        }
        held.Add(key);
        if (consumed.Contains(key))
            return true;
        var current = held.Where(k => k != key).ToArray();
        if (key == ShortcutKey && Modifiers.All(m => current.Any(k => k.StartsWith(m, StringComparison.Ordinal))) && current.All(k => Modifiers.Any(m => k.StartsWith(m, StringComparison.Ordinal))))
        {
            consumed.Add(key);
            Opened?.Invoke();
            return true;
        }
        return false;
    }
    public async Task Sync()
    {
        if (group is null)
        {
            Status = "连接设备后自动同步；离线历史保留在本机";
            Changed?.Invoke();
            return;
        }
        if (disposed)
            return;
        if (syncing)
        {
            syncAgain = true;
            return;
        }
        syncing = true;
        try
        {
            var groupID = group.Id;
            Status = "正在拉取在线设备历史…";
            Changed?.Invoke();
            var failed = false;
            foreach (var peer in online.Where(p => p != id).ToArray())
            {
                var request = Guid.NewGuid().ToString("D");
                var result = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                incoming[request] = new(peer, result);
                try
                {
                    await Send(peer, new("pull", groupID, request));
                    await result.Task.WaitAsync(TimeSpan.FromMinutes(10));
                }
                catch { failed = true; }
                finally { if (incoming.Remove(request, out var remaining)) remaining.Data.Dispose(); }
            }
            Status = failed ? "部分设备不可达；已收到的历史已保存" : "同步完成";
            Changed?.Invoke();
        }
        finally { syncing = false; if (syncAgain && !disposed) { syncAgain = false; _ = Sync(); } }
    }
    public async Task ShareFavorites()
    {
        if (group is null)
            return;
        var groupID = group.Id;
        foreach (var peer in online.Where(p => p != id).ToArray())
        {
            try
            {
                await Transmit(peer, groupID, Guid.NewGuid().ToString("D"), Entries.Where(e => e.Favorite).ToArray(), true);
            }
            catch { Status = "收藏分享未全部完成"; Changed?.Invoke(); }
        }
    }
    private Task Send(string peer, Packet packet) => packet.Type is "item" or "done" ? manager.SendBackgroundAsync(peer, "history", JsonSerializer.SerializeToUtf8Bytes(packet, json)) : manager.SendAsync(peer, "history", JsonSerializer.SerializeToUtf8Bytes(packet, json));
    private async Task Transmit(string peer, string groupID, string request, HistoryEntry[] list, bool sharing)
    {
        foreach (var entry in list)
        {
            var bytes = Encoding.UTF8.GetBytes(entry.Text);
            var metadata = entry with
            {
                Text = ""
            };
            var offset = 0;
            do
            {
                if (disposed || group?.Id != groupID)
                    return;
                var count = Math.Min(manager.BackgroundPayloadLimit(peer), bytes.Length - offset);
                await Send(peer, new("item", groupID, request, metadata, bytes.Length, offset, bytes.AsSpan(offset, count).ToArray(), sharing));
                offset += count;
            } while (offset < bytes.Length);
        }
        await Send(peer, new("done", groupID, request, Sharing: sharing));
    }
    private async Task Receive(string peer, byte[] bytes)
    {
        if (disposed || group is null || !online.Contains(peer))
            return;
        Packet? packet;
        try
        {
            packet = JsonSerializer.Deserialize<Packet>(bytes, json);
        }
        catch { return; }
        if (packet is null || packet.GroupID != group.Id || !Guid.TryParse(packet.RequestID, out _))
            return;
        if (packet.Type == "pull")
        {
            await Transmit(peer, group.Id, packet.RequestID, Entries, false);
            return;
        }
        if (!incoming.ContainsKey(packet.RequestID) && packet.Sharing == true && incoming.Count < 4)
        {
            incoming[packet.RequestID] = new(peer);
            _ = Expire(packet.RequestID);
        }
        if (!incoming.TryGetValue(packet.RequestID, out var state) || state.Peer != peer)
            return;
        if (packet.Type == "done")
        {
            if (state.Entry is not null)
            {
                Fail(packet.RequestID);
                return;
            }
            incoming.Remove(packet.RequestID);
            state.Completion?.TrySetResult(true);
            state.Data.Dispose();
            Changed?.Invoke();
            return;
        }
        if (packet.Type != "item" || packet.Entry is not { } entry || !Guid.TryParse(entry.Id, out _) || entry.Text.Length != 0 || packet.Total is not (>= 0 and <= ClipboardService.MaximumTextBytes) || packet.Offset is not { } offset || packet.Data is not { Length: <= 20000 } data || state.Count >= 10000)
            return;
        if (state.Entry is null)
        {
            if (offset != 0)
                return;
            state.Entry = entry;
            state.Total = packet.Total.Value;
            state.Data.SetLength(0);
        }
        if (state.Entry != entry || state.Total != packet.Total || offset != state.Data.Length || state.Data.Length + data.Length > state.Total)
            return;
        state.Data.Write(data);
        if (state.Data.Length == state.Total)
        {
            var text = new UTF8Encoding(false, true).GetString(state.Data.ToArray());
            Remember(text, entry.Id, entry.Timestamp, entry.Favorite, false);
            state.Entry = null;
            state.Data.SetLength(0);
            state.Count++;
        }
    }
    private async Task Expire(string request)
    {
        await Task.Delay(TimeSpan.FromMinutes(10));
        context.Post(_ => Fail(request), null);
    }
    private void Fail(string request)
    {
        if (incoming.Remove(request, out var state))
        {
            state.Completion?.TrySetException(new IOException("History peer disconnected or stream incomplete."));
            state.Data.Dispose();
        }
    }
    public void ResetCapture()
    {
        held.Clear();
        consumed.Clear();
    }
    public void Dispose()
    {
        disposed = true;
        foreach (var key in incoming.Keys.ToArray())
            Fail(key);
        ResetCapture();
    }
}
