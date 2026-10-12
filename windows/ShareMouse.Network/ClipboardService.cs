using System.Text;
using System.Text.Json;
using ShareMouse.Core;
namespace ShareMouse.Network;

// Clipboard state and callbacks run on the native application's context; network reads never wait for a paste.
public sealed class ClipboardService : IDisposable {
    public const int MaximumTextBytes=4*1024*1024;
    public const int MaximumContentBytes=32*1024*1024;
    private readonly string id;
    private readonly SessionManager manager;
    private readonly SynchronizationContext context;
    private readonly Action<string> log;
    private SharedGroup? group;
    private HashSet<string> online=new();
    private ulong clock;
    private byte[]? owned,cached;
    private bool disposed;
    private string? stateFile;
    private sealed record Saved(string? GroupID,ulong Clock,ClipboardEntry? Current,byte[]? Body=null);
    private Saved? restored;
    private void Notify(ClipboardEntry? entry) { if(stateFile is not null && group is not null) { restored=new Saved(group.Id,clock,entry,entry?.SourcePeerID==id?owned:cached); try { var temporary=stateFile+".tmp"; File.WriteAllBytes(temporary,JsonSerializer.SerializeToUtf8Bytes(restored,json)); File.Move(temporary,stateFile,true); } catch { stateFile=null; log("ClipboardPersistenceDisabled"); } }; Changed?.Invoke(entry); }
    public Func<string,string?>? TextForEntry { get; set; }
    public ClipboardEntry? Current { get; private set; }
    public event Action<ClipboardEntry?>? Changed;
    private sealed class Download(ClipboardEntry entry,string peer) {
        public ClipboardEntry Entry=entry;
        public string Peer=peer;
        public MemoryStream Data=new();
        public TaskCompletionSource<byte[]> Result=new(TaskCreationOptions.RunContinuationsAsynchronously);
    }
    private readonly Dictionary<string,Download> downloads=new();
    private static readonly JsonSerializerOptions json=new() { PropertyNamingPolicy=JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition=System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull };
    public ClipboardService(string id,SessionManager manager,SynchronizationContext context,Action<string> log,string? directory=null) {
        this.id=id; this.manager=manager; this.context=context; this.log=log;
        stateFile=directory is null?null:Path.Combine(directory,"clipboard-current.json");
        if(stateFile is not null && File.Exists(stateFile)) { try { restored=JsonSerializer.Deserialize<Saved>(File.ReadAllBytes(stateFile),json)??throw new IOException("Invalid clipboard state."); clock=restored.Clock; } catch { stateFile=null; log("ClipboardPersistenceDisabled"); } }
        manager.Receive("clipboard",(peer,bytes)=> { context.Post(async _=> { try { await Receive(peer,bytes); } catch { log("ClipboardRequestFailed"); } },null); return Task.CompletedTask; });
    }
    public async Task Start() { await manager.SetCapabilityAsync("clipboard-text",true); await manager.SetCapabilityAsync("clipboard-rich",true); if(group is not null) foreach(var peer in online.Where(p=>p!=id)) await RequestCurrent(peer); }
    public void Update(SharedGroup? value,string[] peers) {
        var added=peers.Except(online).ToArray();
        if (group?.Id!=value?.Id) { CancelDownloads(); Current=null; owned=cached=null; }
        group=value; online=peers.ToHashSet();
        if(Current is null && restored is {} saved && saved.GroupID==group?.Id && group is not null) { Current=saved.Current; if(saved.Body is {} body && body.Length==Current?.ByteCount && body.Length<=MaximumContentBytes) { if(Current?.SourcePeerID==id) owned=body; else cached=body; }; Notify(Current); }
        else if(Current is null) Notify(null);
        foreach (var request in downloads.Where(p=>!online.Contains(p.Value.Peer)).Select(p=>p.Key).ToArray()) Fail(request);
        foreach(var peer in added.Where(p=>p!=id)) { if(Current is {} current) _=SendMetadata(peer,current); if(group is not null) _=RequestCurrent(peer); }
    }
    public Task PublishText(string? text)=>PublishContent(text is null?null:ClipboardContent.Text(text));
    public async Task PublishContent(ClipboardContent? content) {
        if(group is null) return; byte[]? bytes=null; Exception? failure=null;
        try { if(content is not null) { content.Validate(); bytes=content.Kind=="text"?content.Data:JsonSerializer.SerializeToUtf8Bytes(content,json); if(bytes.Length>MaximumContentBytes) throw new IOException("Clipboard content too large."); } }
        catch(Exception exception) { content=null; bytes=null; failure=exception; }
        if(clock>=ulong.MaxValue-1) throw new IOException("Clipboard clock exhausted.");
        var entry=new ClipboardEntry(Guid.NewGuid().ToString("D"),id,++clock,DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),content?.Kind??"unsupported",bytes?.Length??0);
        CancelDownloads(); Current=entry; owned=bytes; cached=null; Notify(entry);
        foreach(var peer in online.Where(p=>p!=id)) await SendMetadata(peer,entry);
        log("ClipboardMetadataPublished"); if(failure is not null) throw failure;
    }
    public async Task<ClipboardEntry> PublishFiles(int count,long bytes,bool cut,Action<ClipboardEntry>? prepare=null) {
        if(group is null || clock>=ulong.MaxValue-1) throw new IOException("No active group.");
        var entry=new ClipboardEntry(Guid.NewGuid().ToString("D"),id,++clock,DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),"files",0,[id],cut,count,bytes,1);
        prepare?.Invoke(entry);
        CancelDownloads(); Current=entry; owned=cached=null; Notify(entry);
        foreach(var peer in online.Where(p=>p!=id)) await SendMetadata(peer,entry);
        log("FileClipboardPublished"); return entry;
    }
    public void RestoreFiles(ClipboardEntry entry,string groupID) {
        if(group?.Id!=groupID || Current is not null || restored is not null || entry.Kind!="files") return;
        Current=entry; clock=Math.Max(clock,entry.Counter); Notify(entry);
        foreach(var peer in online.Where(p=>p!=id)) _=SendMetadata(peer,entry);
    }
    public async Task<ClipboardEntry> FileVersion(int count,long bytes) {
        if(group is null || Current is not { Kind:"files" } entry || entry.SourcePeerID!=id) throw new IOException("Clipboard changed.");
        entry=entry with { FileRevision=(entry.FileRevision??1)+1,FileCount=count,TotalBytes=bytes,Providers=[id] };
        Current=entry; Notify(entry);
        foreach(var peer in online.Where(p=>p!=id)) try { await Send(peer,new() { Type="fileVersion",GroupID=group.Id,Entry=entry }); } catch { }
        return entry;
    }
    private void ApplyProvider(string peer,bool present) {
        if(Current is not {} entry) return;
        var providers=(entry.Providers??[]).ToHashSet(); if(present) providers.Add(peer); else providers.Remove(peer);
        Current=entry with { Providers=providers.OrderBy(p=>p==entry.SourcePeerID?0:1).ThenBy(p=>p,StringComparer.Ordinal).ToArray() }; Notify(Current);
    }
    public async Task ProvideFiles(bool present) {
        if(group is null || Current is not { Kind:"files" } entry) return; ApplyProvider(id,present);
        foreach(var peer in online.Where(p=>p!=id)) try { await Send(peer,new() { Type="provider",GroupID=group.Id,EntryID=entry.Id,Present=present }); } catch { }
    }
    private async Task<byte[]> Body() {
        if (disposed || Current is not {} entry || entry.Kind is not ("text" or "png" or "url" or "html" or "rtf")) throw new IOException("当前剪贴板类型不可用。");
        if(entry.Kind=="text" && entry.SourcePeerID==id && owned is null && TextForEntry?.Invoke(entry.Id) is {} recovered && Encoding.UTF8.GetByteCount(recovered)==entry.ByteCount) owned=Encoding.UTF8.GetBytes(recovered);
        var bytes=entry.SourcePeerID==id?owned:cached;
        if (bytes is null) {
            if (entry.SourcePeerID==id || group is null || !online.Contains(entry.SourcePeerID) || downloads.Count>=4) throw new IOException("剪贴板来源设备不可达。");
            var request=Guid.NewGuid().ToString("D"); var download=new Download(entry,entry.SourcePeerID); downloads[request]=download;
            try {
                await Send(entry.SourcePeerID,new() { Type="request",GroupID=group.Id,EntryID=entry.Id,RequestID=request });
                bytes=await download.Result.Task.WaitAsync(TimeSpan.FromMinutes(10));
            } finally { downloads.Remove(request); download.Data.Dispose(); }
            if(Current?.Id!=entry.Id) throw new IOException("等待粘贴期间剪贴板已更新，请再次粘贴。"); cached=bytes; Notify(Current);
        }
        return bytes;
    }
    public async Task<ClipboardContent> Content() {
        var entry=Current??throw new IOException("Clipboard unavailable."); var bytes=await Body(); if(Current?.Id!=entry.Id) throw new IOException("Clipboard changed.");
        var result=entry.Kind=="text"?ClipboardContent.Text(new UTF8Encoding(false,true).GetString(bytes)):JsonSerializer.Deserialize<ClipboardContent>(bytes,json)??throw new IOException("Invalid content.");
        if(result.Kind!=entry.Kind) throw new IOException("Content type changed."); result.Validate(); return result;
    }
    public async Task<string> Text()=>(await Content()).PlainText??throw new IOException("No text representation.");
    public async Task WaitForEntry(string entryID,string peer) {
        if(!Guid.TryParse(entryID,out _) || group is null || disposed) throw new IOException("Clipboard changed.");
        var groupID=group.Id; if(Current?.Id==entryID) return;
        if(!online.Contains(peer) || peer==id) throw new IOException("Clipboard source unavailable.");
        await RequestCurrent(peer); var started=System.Diagnostics.Stopwatch.StartNew();
        while(Current?.Id!=entryID) {
            if(disposed || group?.Id!=groupID || !online.Contains(peer) || started.Elapsed>=TimeSpan.FromSeconds(2)) throw new IOException("Clipboard changed.");
            await Task.Delay(20);
        }
        if(disposed || group?.Id!=groupID) throw new IOException("Clipboard changed.");
    }
    private async Task RequestCurrent(string peer) { if(group is null) return; try { await Send(peer,new() { Type="current",GroupID=group.Id }); } catch { } }
    private Task Send(string peer,ClipboardPacket packet)=>manager.SendAsync(peer,"clipboard",JsonSerializer.SerializeToUtf8Bytes(packet,json));
    private async Task SendMetadata(string peer,ClipboardEntry entry) {
        if(group is null) return;
        try { await Send(peer,new() { Type="metadata",GroupID=group.Id,Entry=entry }); } catch { }
    }
    private async Task Receive(string peer,byte[] bytes) {
        if(disposed || group is null || !online.Contains(peer)) return;
        ClipboardPacket? packet; try { packet=JsonSerializer.Deserialize<ClipboardPacket>(bytes,json); } catch { return; }
        if(packet is null || packet.GroupID!=group.Id) return;
        var groupID=group.Id;
        if(packet.Type=="current") { if(Current is {} latest) await SendMetadata(peer,latest); }
        else if(packet.Type=="metadata" && packet.Entry is { } entry && Guid.TryParse(entry.Id,out _) && group.Members.Any(m=>m.PeerID==entry.SourcePeerID)
            && entry.Counter<ulong.MaxValue-1 && entry.Kind is "text" or "unsupported" or "files" or "png" or "url" or "html" or "rtf" && entry.ByteCount>=0 && entry.ByteCount<=(entry.Kind=="text"?MaximumTextBytes:MaximumContentBytes)) {
            clock=Math.Max(clock,entry.Counter);
            if(ClipboardEntry.Newer(entry,Current)) { CancelDownloads(); Current=entry; owned=cached=null; Notify(entry); log("ClipboardMetadataReceived"); }
            else if(Current is {} previous && previous.Id==entry.Id && previous.Kind=="files" && entry.Kind=="files" && previous.SourcePeerID==entry.SourcePeerID && previous.Counter==entry.Counter) {
                if(peer==entry.SourcePeerID && (entry.FileRevision??1)>(previous.FileRevision??1)) { Current=entry; Notify(entry); }
                else if(entry.FileRevision==previous.FileRevision) ApplyProvider(peer,entry.Providers?.Contains(peer)==true);
            }
        } else if(packet.Type=="provider" && Current is { Kind:"files" } providerEntry && providerEntry.Id==packet.EntryID && packet.Present is {} present) {
            ApplyProvider(peer,present);
        } else if(packet.Type=="fileVersion" && packet.Entry is {} version && Current is {} old && version.Id==old.Id && version.SourcePeerID==peer
            && version.Kind=="files" && (version.FileRevision??1)>(old.FileRevision??1)) { Current=version; Notify(version);
        } else if(packet.Type=="request" && packet.RequestID is { Length:<=64 } request && Current is { } current) {
            if(current.Kind=="text" && current.SourcePeerID==id && owned is null && TextForEntry?.Invoke(current.Id) is {} recovered && Encoding.UTF8.GetByteCount(recovered)==current.ByteCount) owned=Encoding.UTF8.GetBytes(recovered);
            if(current.SourcePeerID!=id || current.Id!=packet.EntryID || owned is null) { await Send(peer,new() { Type="error",GroupID=groupID,RequestID=request,Error="sourceUnavailable" }); return; }
            var data=owned; log("ClipboardTextRequested"); var offset=0;
            do {
                if(group?.Id!=groupID || Current?.Id!=current.Id) return;
                var count=Math.Min(20000,data.Length-offset);
                await Send(peer,new() { Type="data",GroupID=groupID,RequestID=request,EntryID=current.Id,Offset=offset,Total=data.Length,Data=data.AsSpan(offset,count).ToArray() }); offset+=count;
            } while(offset<data.Length);
        } else if(packet.Type=="data" && packet.RequestID is { } requestID && downloads.TryGetValue(requestID,out var download) && download.Peer==peer
            && packet.EntryID==download.Entry.Id && packet.Data is { Length:<=20000 } chunk && packet.Offset==download.Data.Length && packet.Total==download.Entry.ByteCount
            && download.Data.Length+chunk.Length<=download.Entry.ByteCount) {
            download.Data.Write(chunk);
            if(download.Data.Length==download.Entry.ByteCount) { downloads.Remove(requestID); download.Result.TrySetResult(download.Data.ToArray()); }
        } else if(packet.Type=="error" && packet.RequestID is { } failed && downloads.GetValueOrDefault(failed)?.Peer==peer) Fail(failed);
    }
    private void Fail(string request) { if(downloads.Remove(request,out var download)) download.Result.TrySetException(new IOException("剪贴板来源设备不可达或内容已改变。")); }
    private void CancelDownloads() { foreach(var request in downloads.Keys.ToArray()) Fail(request); }
    public void Dispose() { disposed=true; CancelDownloads(); }
}
