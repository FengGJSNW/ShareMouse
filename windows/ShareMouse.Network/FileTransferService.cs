using System.Text.Json;
using ShareMouse.Core;
namespace ShareMouse.Network;

public sealed class FileTransferService : IDisposable
{
    private readonly string id, file, progressFile;
    private string progressGeneration = Guid.NewGuid().ToString("D");
    private Dictionary<string, Dictionary<string, long>> progressOffsets = new();
    private readonly SessionManager manager;
    private readonly ClipboardService clipboard;
    private readonly SynchronizationContext context;
    private readonly Action<string> log;
    private readonly Func<string[], Task<bool>> sourceChanged, deleteAll;
    private readonly Func<string[], Task<string>> additionalFiles;
    private readonly Func<string, bool, bool, Task<string>> conflict;
    private readonly Dictionary<string, string> conflictRules = new();
    private readonly Func<TransferTask, Task<string>> partialFailure;
    private SharedGroup? group;
    private HashSet<string> online = new();
    private readonly Dictionary<string, FileTransaction> transactions = new();
    private readonly Dictionary<string, TaskCompletionSource<bool>> pendingCopies = new();
    private readonly Dictionary<string, string[]> pendingPaths = new();
    private readonly Dictionary<string, FileTransaction> replicas = new();
    private readonly Dictionary<string, FilePermit> permits = new();
    private readonly Dictionary<string, TransferTask> tasks = new();
    private readonly HashSet<string> running = new();
    private readonly Dictionary<string, SemaphoreSlim> sourceGates = new();
    private readonly Dictionary<string, CancellationTokenSource> cutCancellation = new();
    private readonly Dictionary<string, string> cutOwners = new();
    private readonly Dictionary<string, string> transports = new();
    private bool disposed;
    public event Action<TransferTask[]>? Changed;
    public TransferTask[] Tasks => tasks.Values.OrderByDescending(t => t.Created).ToArray();
    private static readonly JsonSerializerOptions json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping, DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull };
    private sealed class Pending(string peer, FilePacket request)
    {
        public string Peer = peer; public FilePacket Request = request; public List<FilePacket> Packets = [];
        public TaskCompletionSource<FilePacket[]> Result = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }
    private readonly Dictionary<string, Pending> pending = new();
    private readonly Dictionary<string, int> chunkRequests = new();
    public FileTransferService(string id, string directory, SessionManager manager, ClipboardService clipboard, SynchronizationContext context, Action<string> log,
        Func<string[], Task<bool>> sourceChanged, Func<string, bool, bool, Task<string>> conflict, Func<TransferTask, Task<string>> partialFailure, Func<string[], Task<bool>> deleteAll, Func<string[], Task<string>>? additionalFiles = null)
    {
        this.id = id;
        this.manager = manager;
        this.clipboard = clipboard;
        this.context = context;
        this.log = log;
        this.additionalFiles = additionalFiles ?? (_ => Task.FromResult("exclude"));
        this.sourceChanged = sourceChanged;
        this.conflict = conflict;
        this.partialFailure = partialFailure;
        this.deleteAll = deleteAll;
        file = Path.Combine(directory, "file-transfers.json");
        progressFile = Path.Combine(directory, "file-transfers-progress.json");
        if (File.Exists(file))
        {
            var saved = JsonSerializer.Deserialize<FileTransferStore>(File.ReadAllText(file), json) ?? throw new IOException("Invalid transfer store.");
            progressGeneration = saved.ProgressGeneration ?? Guid.NewGuid().ToString("D");
            foreach (var transaction in saved.Transactions)
                transactions[transaction.Entry.Id] = transaction;
            foreach (var replica in saved.Replicas ?? [])
                replicas[replica.Entry.Id] = replica;
            foreach (var permit in saved.Permits)
                permits[permit.TaskID] = permit;
            foreach (var task in saved.Tasks)
            {
                if (task.State is "running" or "queued")
                {
                    task.State = "paused";
                    task.PausedBy = task.Direction == "send" ? task.RemotePeerID : id;
                }
                tasks[task.Id] = task;
            }
            // Ignore incomplete/stale progress; the durable full store remains authoritative.
            try
            {
                if (File.Exists(progressFile) && JsonSerializer.Deserialize<FileProgressStore>(File.ReadAllText(progressFile), json) is { } progress
                    && progress.Generation == saved.ProgressGeneration)
                {
                    progressOffsets = progress.Tasks;
                    foreach (var task in tasks.Values)
                        foreach (var item in task.Files.Where(f => !f.Completed))
                            if (progress.Tasks.GetValueOrDefault(task.Id)?.GetValueOrDefault(item.Item.Id) is { } offset
                                && offset >= item.Received && offset <= item.Item.Size)
                                item.Received = offset;
                }
            }
            catch (Exception error) when (error is IOException or JsonException) { }
        }
        clipboard.Changed += ClipboardChanged;
        manager.Receive("files", (peer, bytes) => { context.Post(async _ => { try { await Receive(peer, bytes); } catch { log("FileRequestRejected"); } }, null); return Task.CompletedTask; });
    }
    private void ClipboardChanged(ClipboardEntry? entry)
    {
        if (entry is null)
            return;
        var changed = false;
        foreach (var key in cutCancellation.Keys.Where(key => key != entry.Id).ToArray())
            cutCancellation[key].Cancel();
        foreach (var key in transactions.Where(p => p.Value.OriginalCut && p.Key != entry.Id).Select(p => p.Key).ToArray())
        {
            transactions[key] = transactions[key] with
            {
                OriginalCut = false
            };
            changed = true;
        }
        foreach (var key in permits.Where(p => p.Value.Transaction.OriginalCut && p.Value.Transaction.Entry.Id != entry.Id).Select(p => p.Key).ToArray())
        {
            permits[key] = permits[key] with
            {
                Transaction = permits[key].Transaction with
                {
                    OriginalCut = false
                },
                CutSource = permits[key].CutSource is { } original ? original with
                {
                    OriginalCut = false
                } : null
            };
            changed = true;
        }
        if (changed)
            Save();
    }
    public async Task Start()
    {
        await manager.SetCapabilityAsync("files", true);
        await manager.SetCapabilityAsync("file-symlink-v1", true);
        await manager.SetCapabilityAsync("compact-file-v1", true);
    }
    private readonly Dictionary<string, (long bytes, long time)> checkpoints = new();
    private void Progress(TransferTask task, long bytes)
    {
        var now = Environment.TickCount64;
        var previous = checkpoints.GetValueOrDefault(task.Id);
        if (now - previous.time >= 500 || bytes - previous.bytes >= 1024 * 1024)
        {
            var offsets = new Dictionary<string, Dictionary<string, long>>(progressOffsets)
            {
                [task.Id] = task.Files.Where(f => !f.Completed && !f.Item.Directory).ToDictionary(f => f.Item.Id, f => f.Received)
            };
            File.WriteAllText(progressFile + ".tmp", JsonSerializer.Serialize(new FileProgressStore(progressGeneration, offsets), json));
            File.Move(progressFile + ".tmp", progressFile, true);
            progressOffsets = offsets;
            checkpoints[task.Id] = (bytes, now);
            Changed?.Invoke(Tasks);
        }
    }
    private void Save()
    {
        var generation = Guid.NewGuid().ToString("D");
        var saved = new FileTransferStore(transactions.Values.ToArray(), permits.Values.ToArray(), tasks.Values.ToArray(), replicas.Values.ToArray(), generation);
        File.WriteAllText(file + ".tmp", JsonSerializer.Serialize(saved, json));
        File.Move(file + ".tmp", file, true);
        progressGeneration = generation;
        progressOffsets.Clear();
        Changed?.Invoke(Tasks);
    }
    public void Update(SharedGroup? value, string[] peers, SessionInfo[] sessions)
    {
        var changed = group?.Id != value?.Id;
        group = value;
        online = peers.ToHashSet();
        foreach (var session in sessions)
        {
            var selected = session.Capabilities.Contains("tcp") ? "tcp" : session.Capabilities.Contains("quic") ? "quic" : session.Capabilities.Contains("ble") ? "ble" : "none";
            if (transports.TryGetValue(session.PeerID, out var before) && before != selected && tasks.Values.Any(t => t.State == "running" && t.Files.Any(f => f.Provider == session.PeerID)))
                log("TransferTransportChanged kind=" + selected);
            transports[session.PeerID] = selected;
        }
        if (changed)
            foreach (var cancellation in cutCancellation.Values)
                cancellation.Cancel();
        if (changed)
            foreach (var task in tasks.Values.Where(t => t.State == "running"))
                task.State = "paused";
        var taskChanged = false;
        foreach (var task in tasks.Values.Where(t => t.Direction == "send" && t.State is "queued" or "running" && t.RemotePeerID is not null && !online.Contains(t.RemotePeerID)))
        {
            task.State = "paused";
            task.PausedBy = task.RemotePeerID;
            StopCut(task);
            taskChanged = true;
        }
        foreach (var request in pending.Where(p => !online.Contains(p.Value.Peer) || changed).Select(p => p.Key).ToArray())
            Fail(request, "Provider disconnected.");
        if (group is not null && clipboard.Current is null)
        {
            var restored = transactions.Values.Where(t => t.GroupID == group.Id).OrderByDescending(t => t.Entry.Counter).FirstOrDefault();
            if (restored is not null)
                clipboard.RestoreFiles(restored.Entry, group.Id);
        }
        if (changed || taskChanged)
            Save();
    }
    public async Task Copy(string[] paths, bool cut, Func<bool>? stillCurrent = null)
    {
        if (group is null || paths.Length == 0)
            throw new IOException("No active group or selected files.");
        var selectedGroup = group.Id;
        var ready = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var entry = await clipboard.PublishFiles(0, 0, cut, reserved => { pendingCopies[reserved.Id] = ready; pendingPaths[reserved.Id] = paths; });
        try
        {
            var (roots, files) = await FileStorage.Scan(paths);
            if (group?.Id != selectedGroup || clipboard.Current?.Id != entry.Id || stillCurrent?.Invoke() == false)
                throw new IOException("A newer Copy replaced this selection.");
            entry = await clipboard.FileVersion(files.Length, files.Sum(f => f.Item.Size));
            transactions[entry.Id] = new(entry, selectedGroup, roots, files, cut && clipboard.Current?.Id == entry.Id);
            Save();
            ready.TrySetResult(true);
        }
        catch { ready.TrySetResult(false); if (clipboard.Current?.Id == entry.Id) await clipboard.ProvideFiles(false); throw; }
        finally { pendingCopies.Remove(entry.Id); pendingPaths.Remove(entry.Id); }
    }
    private static bool ReplicaUnchanged(LocalFile file)
    {
        try
        {
            return file.Item.Directory ? FileStorage.Inspect(file.Path, file.Item).Identity == file.Identity : FileStorage.Unchanged(file);
        }
        catch { return false; }
    }
    private async Task Send(string peer, FilePacket packet)
    {
        var bytes = FilePacketCodec.Encode(packet, peer != id && manager.HasCapability(peer, "compact-file-v1"));
        if (peer == id)
        {
            context.Post(async _ => { try { await Receive(id, bytes); } catch { log("LocalFileRequestFailed"); } }, null);
            return;
        }
        var kind = await manager.SendBulkTrackedAsync(peer, "files", bytes);
        if (tasks.GetValueOrDefault(packet.TaskID) is { } task && task.Transport != kind)
        {
            task.Transport = kind;
            Changed?.Invoke(Tasks);
        }
    }
    private async Task<FilePacket[]> Exchange(string peer, FilePacket packet)
    {
        packet.RequestID = Guid.NewGuid().ToString("D");
        var request = new Pending(peer, packet);
        pending[packet.RequestID] = request;
        try
        {
            await Send(peer, packet);
            return await request.Result.Task.WaitAsync(packet.Type is "offer" or "receipt" or "delete-all" ? TimeSpan.FromMinutes(10) : TimeSpan.FromSeconds(20));
        }
        finally { pending.Remove(packet.RequestID); }
    }
    private void Fail(string request, string error)
    {
        if (pending.Remove(request, out var waiting))
            waiting.Result.TrySetException(error == "cancelledByUser" ? new OperationCanceledException(error) : new IOException(error));
    }
    private async Task Receive(string peer, byte[] bytes)
    {
        if (disposed || group is null || !online.Contains(peer))
            return;
        FilePacket? packet;
        try
        {
            packet = FilePacketCodec.Decode(bytes, peer != id && manager.HasCapability(peer, "compact-file-v1"));
        }
        catch { return; }
        if (packet is null || packet.GroupID != group.Id || !Guid.TryParse(packet.TaskID, out _) || !Guid.TryParse(packet.EntryID, out _))
            return;
        if (packet.Type is "offer-data" or "chunk-data" or "receipt-ok" or "delete-ok" or "error")
        {
            if (packet.RequestID is not { } request || !pending.TryGetValue(request, out var waiting) || waiting.Peer != peer
                || waiting.Request.EntryID != packet.EntryID || waiting.Request.TaskID != packet.TaskID)
                return;
            var expected = waiting.Request.Type switch
            {
                "offer" => "offer-data",
                "chunk" => "chunk-data",
                "receipt" => "receipt-ok",
                "delete-all" => "delete-ok",
                _ => ""
            };
            if (packet.Type == "error")
            {
                Fail(request, packet.Error ?? "File request failed.");
                return;
            }
            if (packet.Type != expected || waiting.Packets.Count >= 12501 || packet.Index != waiting.Packets.Count)
            {
                Fail(request, "Invalid file response.");
                return;
            }
            waiting.Packets.Add(packet);
            if (packet.Final == true)
            {
                pending.Remove(request);
                waiting.Result.TrySetResult(waiting.Packets.ToArray());
            }
            return;
        }
        if (packet.Type == "finish" && tasks.GetValueOrDefault(packet.TaskID) is { Direction: "send" } finished && finished.RemotePeerID == peer && finished.Entry.Id == packet.EntryID
            && packet.State is "completed" or "failed" or "paused" or "cancelled" && finished.PausedBy != id
            && (packet.ControlRevision ?? 0) >= (finished.ReceivedControls?.GetValueOrDefault(peer) ?? 0) && packet.Entry?.FileRevision == finished.Entry.FileRevision)
        {
            finished.State = finished.Error is not null ? "failed" : packet.State;
            finished.Error ??= packet.Error;
            Save();
            return;
        }
        if (packet.Type is "pause" or "resume" or "cancel" && tasks.TryGetValue(packet.TaskID, out var controlled) && controlled.Entry.Id == packet.EntryID
            && (controlled.Direction == "send" ? controlled.RemotePeerID == peer : controlled.Files.Any(f => f.Provider == peer)))
        {
            if (packet.ControlRevision is not { } revision || revision <= (controlled.ReceivedControls?.GetValueOrDefault(peer) ?? 0))
                return;
            controlled.ReceivedControls ??= new();
            controlled.ReceivedControls[peer] = revision;
            if (packet.Type == "resume")
            {
                if (controlled.PausedBy == peer || controlled.PausedBy is null && controlled.Direction == "send" && controlled.State == "paused")
                {
                    controlled.PausedBy = null;
                    if (controlled.Direction == "send")
                        controlled.State = "running";
                    else
                        _ = Run(controlled);
                    Save();
                }
            }
            else
            {
                controlled.PausedBy = peer;
                controlled.State = packet.Type == "pause" ? "paused" : "cancelled";
                StopCut(controlled);
                foreach (var key in pending.Where(p => p.Value.Request.TaskID == controlled.Id).Select(p => p.Key).ToArray())
                    Fail(key, "Transfer controlled by peer.");
                Save();
            }
            return;
        }
        if (packet.Type == "offer" && peer != id && !tasks.ContainsKey(packet.TaskID) && pendingPaths.TryGetValue(packet.EntryID, out var paths) && clipboard.Current is { } preparing && preparing.Id == packet.EntryID)
        {
            tasks[packet.TaskID] = new TransferTask { Id = packet.TaskID, Entry = preparing, GroupID = packet.GroupID, Destination = Path.GetDirectoryName(paths[0]) ?? paths[0], Direction = "send", RemotePeerID = peer, State = "queued" };
            Save();
        }
        if (packet.Type == "offer" && peer != id && !tasks.ContainsKey(packet.TaskID) && transactions.TryGetValue(packet.EntryID, out var preview) && preview.Roots.Length > 0)
        {
            tasks[packet.TaskID] = new TransferTask { Id = packet.TaskID, Entry = preview.Entry, GroupID = preview.GroupID, Destination = Path.GetDirectoryName(preview.Roots[0].Path)!, Direction = "send", RemotePeerID = peer, State = "queued", Files = preview.Files.Select(f => new TransferFile { Item = f.Item, Provider = id, Target = f.Path, Partial = "" }).ToList() };
            Save();
        }
        _ = Serve(peer, packet);
    }
    private FilePacket Reply(FilePacket request, string type) => new() { Type = type, GroupID = request.GroupID, EntryID = request.EntryID, TaskID = request.TaskID, RequestID = request.RequestID, Index = 0, Final = true };
    private async Task Serve(string peer, FilePacket request)
    {
        SemaphoreSlim? heldGate = null;
        try
        {
            if (request.Type is "offer" or "receipt" or "delete-all")
            {
                if (!sourceGates.TryGetValue(request.EntryID, out heldGate))
                    sourceGates[request.EntryID] = heldGate = new SemaphoreSlim(1, 1);
                await heldGate.WaitAsync();
            }
            if (request.RequestID is not { Length: <= 64 })
                return;
            if (disposed || group?.Id != request.GroupID || !online.Contains(peer))
                throw new IOException("Group changed.");
            if (request.Type == "offer")
            {
                if (pendingCopies.TryGetValue(request.EntryID, out var pendingCopy) && !await pendingCopy.Task)
                    throw new IOException("Clipboard selection was replaced or unavailable.");
                var previous = permits.GetValueOrDefault(request.TaskID);
                if (tasks.TryGetValue(request.TaskID, out var outgoingBefore) && outgoingBefore.Direction == "send" && outgoingBefore.State is "paused" or "cancelled")
                    throw new IOException("Sender paused or cancelled the task.");
                if (previous is not null && (previous.PeerID != peer || previous.Transaction.Entry.Id != request.EntryID))
                    throw new IOException("Transfer identity mismatch.");
                if (!transactions.TryGetValue(request.EntryID, out var transaction) || transaction.GroupID != request.GroupID
                    || clipboard.Current?.Id != request.EntryID && previous is null)
                    throw new IOException("Clipboard provider is unavailable.");
                var livePaths = transaction.Roots.Select(r => r.Path).Where(p => File.Exists(p) || Directory.Exists(p)).ToArray();
                if (previous is null && livePaths.Length > 0 && transaction.Files.Any(f => f.Item.Directory))
                {
                    var scan = await FileStorage.Scan(livePaths, transaction);
                    var added = FileStorage.Additions(transaction.Files, scan.Item2);
                    if (added.Length > 0)
                    {
                        var choice = await additionalFiles(added.Select(f => f.Item.RelativePath).ToArray());
                        if (choice == "cancel")
                            throw new OperationCanceledException("cancelledByUser");
                        if (clipboard.Current?.Id != request.EntryID)
                            throw new IOException("Clipboard changed during confirmation.");
                        if (choice == "include")
                            transaction = transaction with
                            {
                                Roots = scan.Item1,
                                Files = scan.Item2,
                                Entry = transaction.Entry with
                                {
                                    FileCount = scan.Item2.Length,
                                    TotalBytes = scan.Item2.Sum(f => f.Item.Size)
                                }
                            };
                        else
                        {
                            var directories = scan.Item2.Where(f => f.Item.Directory).ToDictionary(f => f.Item.Id);
                            transaction = transaction with
                            {
                                Files = transaction.Files.Select(old => old.Item.Directory && directories.TryGetValue(old.Item.Id, out var actual) && actual.Identity == old.Identity ? actual : old).ToArray()
                            };
                        }
                    }
                }
                var original = transaction.Entry.SourcePeerID == id;
                if (original && transaction.Files.Where(f => f.Item.Available).Any(f => !FileStorage.Unchanged(f)))
                {
                    if (!await sourceChanged(transaction.Roots.Select(r => r.Path).ToArray()))
                        throw new IOException("Source version was declined.");
                    var scan = await FileStorage.Scan(transaction.Roots.Select(r => r.Path).Where(p => File.Exists(p) || Directory.Exists(p)).ToArray(), transaction);
                    if (scan.Item2.Length == 0)
                        throw new IOException("The selected source no longer exists.");
                    var entry = clipboard.Current?.Id == transaction.Entry.Id ? await clipboard.FileVersion(scan.Item2.Length, scan.Item2.Sum(f => f.Item.Size)) : transaction.Entry;
                    transaction = transaction with
                    {
                        Entry = entry,
                        Roots = scan.Item1,
                        Files = scan.Item2
                    };
                }
                if (peer != id && transaction.Files.Any(f => f.Item.LinkTarget is not null) && manager.CurrentSessions().FirstOrDefault(s => s.PeerID == peer)?.Capabilities.Contains("file-symlink-v1") != true)
                    throw new IOException("The other device needs the folder link update.");
                var prepared = new List<LocalFile>();
                var cached = transaction.Files.ToDictionary(f => f.Item.Id);
                foreach (var originalLocal in transaction.Files)
                {
                    var local = originalLocal;
                    if ((!local.Item.Available || !FileStorage.Unchanged(local)) && replicas.TryGetValue(request.EntryID, out var replica) && replica.Entry.FileRevision == transaction.Entry.FileRevision
                        && replica.Files.FirstOrDefault(f => f.Item.Id == local.Item.Id && f.Item.Available && ReplicaUnchanged(f)) is { } alternate)
                        local = alternate;
                    var current = local;
                    var valid = local.Path == originalLocal.Path && original ? FileStorage.Unchanged(local) : ReplicaUnchanged(local);
                    if (!local.Item.Available || !valid)
                        current = local with
                        {
                            Item = local.Item with
                            {
                                Available = false
                            }
                        };
                    else if (!local.Item.Directory && local.Item.LinkTarget is null && local.Item.Hash is null)
                    {
                        try
                        {
                            var hash = await FileStorage.Hash(local.Path);
                            if (!FileStorage.Unchanged(local))
                                throw new IOException("Source changed during verification.");
                            current = local with
                            {
                                Item = local.Item with
                                {
                                    Hash = hash
                                }
                            };
                            if (local.Path == originalLocal.Path)
                                cached[local.Item.Id] = current;
                        }
                        catch { current = local with { Item = local.Item with { Available = false } }; }
                    }
                    prepared.Add(current);
                }
                if (disposed || group?.Id != request.GroupID || !online.Contains(peer))
                    throw new IOException("Group changed.");
                transaction = transaction with
                {
                    OriginalCut = transaction.OriginalCut && transactions.GetValueOrDefault(request.EntryID)?.OriginalCut == true && clipboard.Current?.Id == request.EntryID,
                    Files = transaction.Files.Select(f => cached[f.Item.Id]).ToArray()
                };
                transactions[request.EntryID] = transaction;
                if (tasks.GetValueOrDefault(request.TaskID) is { Direction: "send", State: "paused" or "cancelled" })
                    throw new IOException("Source task paused.");
                var snapshot = transaction with
                {
                    Files = prepared.ToArray()
                };
                permits[request.TaskID] = new(request.TaskID, peer, snapshot, [], transaction.OriginalCut ? transaction : null);
                if (peer != id)
                {
                    if (tasks.TryGetValue(request.TaskID, out var existingTask) && existingTask.Direction != "send")
                        throw new IOException("Transfer task identity conflict.");
                    var outgoing = existingTask ?? new TransferTask { Id = request.TaskID, Entry = snapshot.Entry, GroupID = snapshot.GroupID, Destination = Path.GetDirectoryName(snapshot.Roots.First().Path)!, Direction = "send", RemotePeerID = peer };
                    outgoing.State = "running";
                    outgoing.Error = null;
                    outgoing.PausedBy = null;
                    outgoing.Entry = snapshot.Entry;
                    var old = outgoing.Files.ToDictionary(f => f.Item.Id);
                    outgoing.Files = snapshot.Files.Select(f => new TransferFile { Item = f.Item, Provider = id, Target = f.Path, Partial = "", Received = old.GetValueOrDefault(f.Item.Id)?.Received ?? 0 }).ToList();
                    tasks[request.TaskID] = outgoing;
                }
                Save();
                var pages = Math.Max(1, (snapshot.Files.Length + 7) / 8);
                for (var index = 0; index < pages; index++)
                {
                    var reply = Reply(request, "offer-data");
                    reply.Entry = snapshot.Entry;
                    reply.Index = index;
                    reply.Final = index == pages - 1;
                    reply.ExpandedCatalogue = snapshot.Entry.FileCount != clipboard.Current?.FileCount;
                    reply.Items = snapshot.Files.Skip(index * 8).Take(8).Select(f => f.Item).ToArray();
                    await Send(peer, reply);
                }
            }
            else if (permits.TryGetValue(request.TaskID, out var permit) && permit.PeerID == peer && permit.Transaction.Entry.Id == request.EntryID)
            {
                if (request.Type == "chunk" && request.ItemID is { } itemID && request.Offset is { } offset)
                {
                    var local = permit.Transaction.Files.Single(f => f.Item.Id == itemID && !f.Item.Directory && f.Item.LinkTarget is null && f.Item.Available);
                    if (tasks.TryGetValue(request.TaskID, out var sourceTask) && sourceTask.Direction == "send" && sourceTask.State != "running")
                        throw new IOException("Source task paused.");
                    var window = manager.FileTransferWindow(peer);
                    if (request.MaximumBytes is < 1 or > 32000)
                        throw new InvalidDataException("Invalid requested chunk size.");
                    var data = await FileStorage.Read(local, offset, Math.Min(window.Bytes, request.MaximumBytes ?? window.Bytes));
                    if (sourceTask?.Direction == "send" && sourceTask.Files.FirstOrDefault(f => f.Item.Id == itemID) is { } progress)
                    {
                        progress.Received = Math.Max(progress.Received, offset + data.Length);
                        Progress(sourceTask, progress.Received);
                    }
                    var reply = Reply(request, "chunk-data");
                    reply.ItemID = itemID;
                    reply.Offset = offset;
                    reply.Data = data;
                    reply.Checksum = ChunkCheck.Adler32(data);
                    await Send(peer, reply);
                }
                else if (request.Type == "receipt" && request.Items is { } received)
                {
                    if (tasks.GetValueOrDefault(request.TaskID) is { Direction: "send", State: "paused" or "cancelled" })
                        throw new IOException("Source task paused or cancelled.");
                    var verified = permit.Verified.ToHashSet();
                    foreach (var item in received)
                    {
                        var expected = permit.Transaction.Files.Single(f => f.Item.Id == item.Id);
                        if (expected.Item.Size != item.Size || expected.Item.Hash != item.Hash || expected.Item.Directory != item.Directory || expected.Item.LinkTarget != item.LinkTarget)
                            throw new IOException("Completion verification failed.");
                        verified.Add(item.Id);
                        if (tasks.GetValueOrDefault(request.TaskID)?.Direction == "send" && tasks[request.TaskID].Files.FirstOrDefault(f => f.Item.Id == item.Id) is { } progress)
                            progress.Completed = true;
                    }
                    permits[request.TaskID] = permit with
                    {
                        Verified = verified.ToArray()
                    };
                    if (permit.Transaction.OriginalCut)
                        Save();
                    else if (tasks.TryGetValue(request.TaskID, out var outgoing))
                        Progress(outgoing, outgoing.Received);
                    var cutSource = permit.CutSource ?? permit.Transaction;
                    if (cutSource.OriginalCut && clipboard.Current?.Id == request.EntryID && (clipboard.Current.FileRevision ?? 1) == (cutSource.Entry.FileRevision ?? 1))
                    {
                        for (var retry = 0; retry < 30 && !(clipboard.Current?.Providers ?? []).Contains(peer); retry++)
                            await Task.Delay(100);
                        if (!(clipboard.Current?.Providers ?? []).Contains(peer))
                            throw new IOException("Target provider has not been confirmed; source kept.");
                        foreach (var root in cutSource.Roots)
                        {
                            var originals = cutSource.Files.Where(f => f.Item.RootID == root.Id).ToArray();
                            if (originals.Length == 0 || originals.Any(f => !verified.Contains(f.Item.Id) || !permit.Transaction.Files.Any(provided => provided.Item.Id == f.Item.Id && provided.Item.Hash == f.Item.Hash && provided.Item.Size == f.Item.Size) || !f.Item.Available && (File.Exists(f.Path) || Directory.Exists(f.Path))) || !File.Exists(root.Path) && !Directory.Exists(root.Path))
                                continue;
                            if (clipboard.Current?.Id != request.EntryID || !permits[request.TaskID].Transaction.OriginalCut)
                                break;
                            if (!cutCancellation.TryGetValue(request.EntryID, out var cancellation))
                                cutCancellation[request.EntryID] = cancellation = new CancellationTokenSource();
                            try
                            {
                                await FileStorage.DeleteVerifiedRoot(cutSource, root.Id, cancellation.Token);
                            }
                            catch
                            {
                                var remaining = transactions[request.EntryID];
                                transactions[request.EntryID] = remaining with
                                {
                                    Files = remaining.Files.Select(f =>
                                    {
                                        if (!permit.Transaction.Files.Any(old => old.Item.Id == f.Item.Id && old.Path == f.Path))
                                            return f;
                                        if (!File.Exists(f.Path) && !Directory.Exists(f.Path))
                                            return f with
                                            {
                                                Item = f.Item with
                                                {
                                                    Available = false
                                                }
                                            };
                                        return f.Item.Directory ? FileStorage.Inspect(f.Path, f.Item) : f;
                                    }).ToArray()
                                };
                                Save();
                                throw;
                            }
                            var current = transactions[request.EntryID];
                            transactions[request.EntryID] = current with
                            {
                                Files = current.Files.Select(f => f.Item.RootID == root.Id && permit.Transaction.Files.Any(old => old.Item.Id == f.Item.Id && old.Path == f.Path) ? f with { Item = f.Item with { Available = false } } : f).ToArray()
                            };
                            Save();
                            log("CutRootDeletedAfterVerification");
                        }
                        if (transactions[request.EntryID].Files.All(f => !f.Item.Available) && (!replicas.TryGetValue(request.EntryID, out var availableReplica) || availableReplica.Files.All(f => !f.Item.Available)))
                            await clipboard.ProvideFiles(false);
                    }
                    if (tasks.GetValueOrDefault(request.TaskID) is { Direction: "send", State: "running" } completedTask && completedTask.Files.All(f => f.Completed))
                    {
                        completedTask.State = "completed";
                        Save();
                    }
                    await Send(peer, Reply(request, "receipt-ok"));
                }
                else if (request.Type == "delete-all" && (permit.CutSource ?? permit.Transaction).OriginalCut && clipboard.Current?.Id == request.EntryID && clipboard.Current.Cut == true)
                {
                    var transaction = transactions[request.EntryID];
                    if (!await deleteAll((permit.CutSource ?? permit.Transaction).Roots.Select(r => r.Path).ToArray()) || clipboard.Current?.Id != request.EntryID)
                        throw new IOException("Delete all cancelled.");
                    FileStorage.DeleteAll(permit.CutSource ?? permit.Transaction);
                    transactions[request.EntryID] = transaction with
                    {
                        Files = transaction.Files.Select(f => permit.Transaction.Files.Any(old => old.Path == f.Path) ? f with { Item = f.Item with { Available = false } } : f).ToArray()
                    };
                    Save();
                    if (transactions[request.EntryID].Files.All(f => !f.Item.Available) && (!replicas.TryGetValue(request.EntryID, out var availableReplica) || availableReplica.Files.All(f => !f.Item.Available)))
                        await clipboard.ProvideFiles(false);
                    await Send(peer, Reply(request, "delete-ok"));
                }
            }
            else
                throw new IOException("File request was not authorized for this task.");
        }
        catch (Exception error)
        {
            if (request.Type is "offer" or "receipt" or "delete-all" && tasks.GetValueOrDefault(request.TaskID) is { Direction: "send", State: "queued" or "running" or "completed" } sourceTask)
            {
                sourceTask.State = error is OperationCanceledException ? "cancelled" : "failed";
                sourceTask.Error = error is OperationCanceledException ? null : request.Type == "offer" ? "来源不可用或当前版本未获确认" : "目标已保存；源删除或确认未完成";
                Save();
            }
            log("FileRequestFailed type=" + request.Type);
            var reply = Reply(request, "error");
            reply.Error = error is OperationCanceledException ? "cancelledByUser" : error is IOException ? error.Message : "The provider could not complete this file operation.";
            try
            {
                await Send(peer, reply);
            }
            catch { }
        }
        finally { heldGate?.Release(); }
    }
    public async Task<string> Paste(string destination)
    {
        if (group is null || clipboard.Current is not { Kind: "files" } entry)
            throw new IOException("No file clipboard.");
        var task = new TransferTask { Id = Guid.NewGuid().ToString("D"), Entry = entry, GroupID = group.Id, Destination = Path.GetFullPath(destination) };
        tasks[task.Id] = task;
        Save();
        await Run(task);
        return task.Id;
    }
    public string BeginPaste(string destination)
    {
        if (group is null || clipboard.Current is not { Kind: "files" } entry)
            throw new IOException("No file clipboard.");
        var task = new TransferTask { Id = Guid.NewGuid().ToString("D"), Entry = entry, GroupID = group.Id, Destination = Path.GetFullPath(destination) };
        tasks[task.Id] = task;
        Save();
        _ = Run(task);
        return task.Id;
    }
    private void StopCut(TransferTask task)
    {
        if (cutOwners.GetValueOrDefault(task.Entry.Id) == task.Id)
            cutCancellation.GetValueOrDefault(task.Entry.Id)?.Cancel();
    }
    private async Task ControlAsync(TransferTask task, string type)
    {
        task.ControlRevision = (task.ControlRevision ?? 0) + 1;
        var revision = task.ControlRevision.Value;
        Save();
        foreach (var peer in task.Direction == "send" ? new[] { task.RemotePeerID! } : (task.Files.Count > 0 ? task.Files.Select(f => f.Provider) : task.Entry.Providers ?? [task.Entry.SourcePeerID]).Where(p => p != id).Distinct())
            await SendControl(peer, task, type, revision);
    }
    private async Task SendControl(string peer, TransferTask task, string type, ulong revision)
    {
        try
        {
            await Send(peer, new()
            {
                Type = type,
                GroupID = task.GroupID,
                EntryID = task.Entry.Id,
                TaskID = task.Id,
                ControlRevision = revision
            });
        }
        catch { }
    }
    public void Pause(string taskID)
    {
        if (tasks.TryGetValue(taskID, out var task) && task.State is "running" or "queued")
        {
            task.PausedBy = id;
            task.State = "paused";
            StopCut(task);
            foreach (var request in pending.Where(p => p.Value.Request.TaskID == taskID).Select(p => p.Key).ToArray())
                Fail(request, "Transfer paused.");
            _ = ControlAsync(task, "pause");
            Save();
        }
    }
    public void Cancel(string taskID)
    {
        if (tasks.TryGetValue(taskID, out var task))
        {
            task.PausedBy = id;
            task.State = "cancelled";
            StopCut(task);
            foreach (var request in pending.Where(p => p.Value.Request.TaskID == taskID).Select(p => p.Key).ToArray())
                Fail(request, "Transfer cancelled.");
            _ = ControlAsync(task, "cancel");
            Save();
        }
    }
    public async Task Resume(string taskID)
    {
        if (!tasks.TryGetValue(taskID, out var task))
            return;
        task.PausedBy = null;
        if (task.Direction == "send")
            task.State = "running";
        await ControlAsync(task, "resume");
        if (task.Direction == "send")
        {
            Save();
            return;
        }
        await Run(task);
    }
    private async Task Run(TransferTask task)
    {
        if (disposed || !running.Add(task.Id))
            return;
        task.State = "running";
        task.Error = null;
        if (clipboard.Current?.Id == task.Entry.Id && clipboard.Current.FileRevision == task.Entry.FileRevision)
            task.Entry = clipboard.Current;
        Save();
        try
        {
            if (group?.Id != task.GroupID)
                throw new IOException("Reconnect the saved group before continuing this transfer.");
            var catalogue = new Dictionary<string, (FileItem Item, string Peer)>();
            foreach (var peer in task.Entry.Providers ?? [task.Entry.SourcePeerID])
            {
                if (!online.Contains(peer))
                    continue;
                try
                {
                    var offered = await Exchange(peer, new()
                    {
                        Type = "offer",
                        GroupID = task.GroupID,
                        EntryID = task.Entry.Id,
                        TaskID = task.Id
                    });
                    if (offered[0].Entry is not { } entry || entry.Id != task.Entry.Id || entry.SourcePeerID != task.Entry.SourcePeerID || entry.Kind != "files" || entry.Counter != task.Entry.Counter || entry.Timestamp != task.Entry.Timestamp || entry.FileCount is not (> 0 and <= 100000))
                        throw new IOException("Invalid provider entry.");
                    if ((entry.FileRevision ?? 1) > (task.Entry.FileRevision ?? 1) && peer == task.Entry.SourcePeerID)
                    {
                        task.Entry = entry;
                        catalogue.Clear();
                    }
                    if ((entry.FileRevision ?? 1) != (task.Entry.FileRevision ?? 1))
                        continue;
                    if (offered[0].ExpandedCatalogue == true)
                    {
                        task.Entry = entry;
                        catalogue.Clear();
                    }
                    foreach (var item in offered.SelectMany(p => p.Items ?? []))
                    {
                        if (!Guid.TryParse(item.Id, out _) || !Guid.TryParse(item.RootID, out _) || item.Size < 0 || System.Text.Encoding.UTF8.GetByteCount(item.RelativePath) > 1024
                            || item.LinkTarget is { } link && (!FileStorage.ValidLink(item.RelativePath, link) || item.Size != 0 || item.Directory || item.Id == item.RootID) || !item.Directory && item.LinkTarget is null && item.Available && (item.Hash is not { Length: 64 } || item.Hash.Any(c => !Uri.IsHexDigit(c))))
                            throw new IOException("Invalid file catalogue.");
                        _ = FileStorage.Target(task.Destination, item.RelativePath);
                        if (!catalogue.TryGetValue(item.Id, out var old) || !old.Item.Available && item.Available)
                            catalogue[item.Id] = (item, peer);
                    }
                    // Inspect every completed provider before deciding whether the directory index is current.
                }
                catch (OperationCanceledException) { throw; }
                catch { log("FileProviderUnavailable"); }
            }
            if (catalogue.Count == 0 || catalogue.Count != task.Entry.FileCount)
                throw new IOException("All complete providers are offline or files are missing.");
            var reserved = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var roots = new Dictionary<string, string>();
            var skipped = new HashSet<string>();
            foreach (var root in catalogue.Values.Where(v => v.Item.Id == v.Item.RootID))
            {
                var previous = task.Files.FirstOrDefault(f => f.Item.Id == root.Item.Id);
                var target = previous?.Target ?? FileStorage.Target(task.Destination, root.Item.RelativePath);
                if (previous?.Completed != true && (File.Exists(target) || Directory.Exists(target) || reserved.Contains(target)))
                {
                    var allow = !reserved.Contains(target) && root.Item.Directory == Directory.Exists(target);
                    var action = await ResolveConflict(task, target, root.Item.Directory, allow);
                    if (action == "overwrite" && !allow)
                        throw new IOException("Cannot overwrite a different item type.");
                    if (action == "cancel")
                    {
                        task.State = "cancelled";
                        return;
                    }
                    if (action == "skip")
                        skipped.Add(root.Item.RootID);
                    if (action == "keepBoth")
                        target = Unique(target, root.Item.Directory, reserved);
                    if (action is not ("skip" or "keepBoth" or "overwrite"))
                        throw new IOException("Invalid conflict decision.");
                }
                reserved.Add(target);
                roots[root.Item.RootID] = target;
            }
            var previousFiles = task.Files.ToDictionary(f => f.Item.Id);
            var ordered = catalogue.Values.OrderBy(v => v.Item.LinkTarget is null ? 0 : 1).ThenBy(v => v.Item.RelativePath.Count(c => c == '/')).ThenByDescending(v => v.Item.Directory).ToArray();
            task.Files = [];
            foreach (var pair in ordered)
            {
                var item = pair.Item;
                if (!roots.TryGetValue(item.RootID, out var root))
                    throw new IOException("Invalid root catalogue.");
                var rootItem = catalogue[item.RootID].Item;
                if (rootItem.RelativePath.Contains('/') || item.Id != rootItem.Id && (!rootItem.Directory || !item.RelativePath.StartsWith(rootItem.RelativePath + "/", StringComparison.Ordinal)))
                    throw new IOException("Invalid root path in the file catalogue.");
                var suffix = item.RelativePath[rootItem.RelativePath.Length..];
                var target = root + suffix.Replace('/', Path.DirectorySeparatorChar);
                var partial = FileStorage.Partial(task.Destination, task.Id, item.Id);
                var old = previousFiles.GetValueOrDefault(item.Id);
                var unchanged = old is not null && old.Item.Hash == item.Hash && old.Item.LinkTarget == item.LinkTarget && old.Item.Size == item.Size && old.Target == target;
                var fileState = unchanged ? old! : new TransferFile { Item = item, Provider = pair.Peer, Target = target, Partial = partial };
                fileState.Item = item;
                fileState.Provider = pair.Peer;
                fileState.Partial = partial;
                fileState.Skipped = skipped.Contains(item.RootID);
                fileState.Error = null;
                if (fileState.Completed && !FileStorage.CompletedUnchanged(fileState))
                {
                    fileState.Completed = false;
                    fileState.Received = 0;
                }
                if (!fileState.Completed)
                    fileState.Received = Math.Min(fileState.Received, File.Exists(partial) ? new FileInfo(partial).Length : 0);
                task.Files.Add(fileState);
            }
            Save();
            foreach (var transfer in task.Files)
            {
                if (task.State != "running")
                    return;
                if (transfer.Completed || transfer.Skipped)
                    continue;
                try
                {
                    await Download(task, transfer);
                }
                catch (Exception error) { transfer.Error = error.Message; Save(); }
            }
            if (task.State != "running")
                return;
            foreach (var transfer in task.Files.Where(f => f.Completed && !FileStorage.CompletedUnchanged(f)))
            {
                transfer.Completed = false;
                transfer.Received = 0;
                transfer.Error = "Verified target was changed; retry before Cut can finish.";
            }
            var completed = task.Files.Where(f => f.Completed).ToArray();
            if (completed.Length > 0 && clipboard.Current?.Id == task.Entry.Id && (clipboard.Current.FileRevision ?? 1) == (task.Entry.FileRevision ?? 1))
            {
                var existing = transactions.GetValueOrDefault(task.Entry.Id);
                var available = completed.ToDictionary(f => f.Item.Id);
                var locals = new List<LocalFile>();
                foreach (var transfer in task.Files)
                {
                    if (available.ContainsKey(transfer.Item.Id))
                        locals.Add(FileStorage.Inspect(transfer.Target, transfer.Item with
                        {
                            Available = true
                        }));
                    else if (existing?.Files.FirstOrDefault(f => f.Item.Id == transfer.Item.Id && f.Item.Available) is { } old && FileStorage.Unchanged(old))
                        locals.Add(old);
                    else
                        locals.Add(new(transfer.Item with
                        {
                            Available = false
                        }, transfer.Target, ""));
                }
                var localProvider = new FileTransaction(task.Entry, task.GroupID, roots.Select(p => new LocalRoot(p.Key, p.Value)).ToArray(), locals.ToArray(), false);
                if (task.Entry.SourcePeerID == id && transactions.ContainsKey(task.Entry.Id))
                    replicas[task.Entry.Id] = localProvider;
                else
                    transactions[task.Entry.Id] = localProvider;
                Save();
                await clipboard.ProvideFiles(true);
            }
            foreach (var provider in completed.Select(f => f.Provider).Distinct())
            {
                try
                {
                    var items = completed.Where(f => f.Provider == provider).Select(f => f.Item).ToArray();
                    for (var offset = 0; offset < items.Length; offset += 8)
                        await Exchange(provider, new()
                        {
                            Type = "receipt",
                            GroupID = task.GroupID,
                            EntryID = task.Entry.Id,
                            TaskID = task.Id,
                            Items = items.Skip(offset).Take(8).ToArray()
                        });
                }
                catch (Exception error) { task.Error = "Files saved; Cut source kept or completion confirmation unavailable: " + error.Message; }
            }
            if (task.Files.Any(f => f.Error is not null || task.Entry.Cut == true && f.Skipped))
            {
                task.State = "failed";
                task.Error ??= "Some selected files were not transferred.";
                Save();
                if (task.Entry.Cut == true)
                {
                    var decision = await partialFailure(task);
                    if (decision == "deleteAll")
                        await Exchange(task.Entry.SourcePeerID, new()
                        {
                            Type = "delete-all",
                            GroupID = task.GroupID,
                            EntryID = task.Entry.Id,
                            TaskID = task.Id
                        });
                    if (decision == "retry")
                    {
                        task.State = "queued";
                    }
                    else if (decision == "abort")
                        task.State = "cancelled";
                }
            }
            else
                task.State = task.Error is null ? "completed" : "failed";
        }
        catch (OperationCanceledException) { task.State = "cancelled"; task.Error = null; }
        catch (Exception error) { if (task.State == "running") task.State = "failed"; task.Error = error.Message; log("TransferFailed taskId=" + task.Id); }
        finally { running.Remove(task.Id); conflictRules.Remove(task.Id); Save(); foreach (var peer in (task.Entry.Providers ?? [task.Entry.SourcePeerID]).Concat(task.Files.Select(f => f.Provider)).Where(p => p != id).Distinct()) _ = Finish(peer, task); if (task.State == "queued") _ = Run(task); }
    }
    private async Task Finish(string peer, TransferTask task)
    {
        try
        {
            await Send(peer, new()
            {
                Type = "finish",
                GroupID = task.GroupID,
                EntryID = task.Entry.Id,
                TaskID = task.Id,
                State = task.State,
                Error = task.Error,
                ControlRevision = task.ControlRevision,
                Entry = task.Entry
            });
        }
        catch { }
    }
    private async Task<string> ResolveConflict(TransferTask task, string path, bool directory, bool allow)
    {
        if (conflictRules.TryGetValue(task.Id, out var rule) && (rule != "overwrite" || allow))
            return rule;
        var decision = await conflict(path, directory, allow);
        var action = decision.EndsWith(":all", StringComparison.Ordinal) ? decision[..^4] : decision;
        if (action is not ("overwrite" or "keepBoth" or "skip" or "cancel") || action == "overwrite" && !allow)
            return "cancel";
        if (decision.EndsWith(":all", StringComparison.Ordinal) && action != "cancel")
            conflictRules[task.Id] = action;
        return action;
    }
    private async Task Download(TransferTask task, TransferFile transfer)
    {
        var item = transfer.Item;
        if (!item.Available)
            throw new IOException("The selected file has no online provider.");
        FileStorage.EnsureParent(task.Destination, transfer.Target);
        if ((File.Exists(transfer.Target) || Directory.Exists(transfer.Target)) && !transfer.Completed && transfer.Received == 0 && item.Id != item.RootID)
        {
            var allow = item.Directory == Directory.Exists(transfer.Target);
            var action = await ResolveConflict(task, transfer.Target, item.Directory, allow);
            if (action == "cancel")
            {
                task.State = "cancelled";
                return;
            }
            if (action == "overwrite" && !allow)
                throw new IOException("Cannot overwrite a different item type.");
            if (action == "skip")
            {
                foreach (var child in task.Files.Where(f => f.Target == transfer.Target || item.Directory && f.Target.StartsWith(transfer.Target + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)))
                    child.Skipped = true;
                Save();
                return;
            }
            if (action == "keepBoth")
            {
                var old = transfer.Target;
                var target = Unique(old, item.Directory, new(StringComparer.OrdinalIgnoreCase));
                foreach (var child in task.Files.Where(f => f.Target == old || item.Directory && f.Target.StartsWith(old + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)))
                    child.Target = target + child.Target[old.Length..];
            }
            if (action is not ("overwrite" or "keepBoth"))
                throw new IOException("Invalid conflict decision.");
        }
        if (item.LinkTarget is not null)
        {
            var root = task.Files.First(f => f.Item.Id == item.RootID).Target;
            FileStorage.FinishLink(transfer, task.Destination, root);
            transfer.Completed = true;
            Progress(task, task.Received);
            return;
        }
        if (item.Directory)
        {
            Directory.CreateDirectory(transfer.Target);
            transfer.CompletedIdentity = FileStorage.Inspect(transfer.Target, item).Identity;
            transfer.Completed = true;
            Progress(task, task.Received);
            return;
        }
        // Finishing a previous file removes empty staging; recreate it for this file.
        transfer.Partial = FileStorage.Partial(task.Destination, task.Id, item.Id);
        if (item.Size == 0)
            await FileStorage.Append(transfer, []);
        while (transfer.Received < item.Size)
        {
            if (task.State != "running")
                return;
            var window = manager.FileTransferWindow(transfer.Provider);
            var start = transfer.Received;
            var offsets = Enumerable.Range(0, window.Count).Select(i => start + (long)i * window.Bytes).Where(offset => offset < item.Size).ToArray();
            var parts = await Task.WhenAll(offsets.Select(async offset => (Offset: offset, Data: await ReadChunk(transfer.Provider, task.GroupID, task.Entry.Id, task.Id, item.Id, offset, (int)Math.Min(window.Bytes, item.Size - offset)))));
            if (task.State != "running")
                return;
            using var batch = new MemoryStream();
            foreach (var part in parts.OrderBy(p => p.Offset))
            {
                if (part.Offset != start + batch.Length || part.Data is null)
                    break;
                batch.Write(part.Data);
            }
            if (batch.Length == 0 || batch.Length > item.Size - start)
                throw new IOException("Chunk unavailable or failed verification; progress was kept.");
            await FileStorage.Append(transfer, batch.ToArray());
            transfer.Received += batch.Length;
            Progress(task, transfer.Received);
        }
        if (await FileStorage.Hash(transfer.Partial) != item.Hash)
        {
            transfer.Received = 0;
            throw new IOException("Final file hash failed; source kept. Retry this file.");
        }
        if (task.State != "running")
            return;
        FileStorage.Finish(transfer, task.Destination);
        transfer.Completed = true;
        Progress(task, task.Received);
    }
    private async Task<byte[]?> ReadChunk(string provider, string groupID, string entryID, string taskID, string itemID, long offset, int maximum)
    {
        while (true)
        {
            if (disposed || !tasks.TryGetValue(taskID, out var current) || current.State != "running")
                return null;
            if (chunkRequests.GetValueOrDefault(provider) < manager.FileTransferWindow(provider).Count)
            {
                chunkRequests[provider] = chunkRequests.GetValueOrDefault(provider) + 1;
                break;
            }
            await Task.Delay(5);
        }
        try
        {
            for (var retry = 0; retry < 3; retry++)
            {
                try
                {
                    var packets = await Exchange(provider, new()
                    {
                        Type = "chunk",
                        GroupID = groupID,
                        EntryID = entryID,
                        TaskID = taskID,
                        ItemID = itemID,
                        Offset = offset,
                        MaximumBytes = manager.HasCapability(provider, "adaptive-file-window-v1") ? maximum : null
                    });
                    var response = packets.Single();
                    if (response.ItemID == itemID && response.Offset == offset && response.Data is { Length: > 0 } data && data.Length <= maximum && response.Checksum == ChunkCheck.Adler32(data))
                        return data;
                }
                catch { if (!tasks.TryGetValue(taskID, out var task) || task.State != "running") return null; }
            }
            return null;
        }
        finally { chunkRequests[provider]--; }
    }
    private static string Unique(string target, bool directory, HashSet<string> reserved)
    {
        var parent = Path.GetDirectoryName(target)!;
        var extension = directory ? "" : Path.GetExtension(target);
        var stem = directory ? Path.GetFileName(target) : Path.GetFileNameWithoutExtension(target);
        for (var number = 2; ; number++)
        {
            var candidate = Path.Combine(parent, $"{stem} ({number}){extension}");
            if (!File.Exists(candidate) && !Directory.Exists(candidate) && !reserved.Contains(candidate))
                return candidate;
        }
    }
    public void Dispose()
    {
        if (disposed)
            return;
        disposed = true;
        foreach (var copy in pendingCopies.Values)
            copy.TrySetResult(false);
        clipboard.Changed -= ClipboardChanged;
        foreach (var cancellation in cutCancellation.Values)
            cancellation.Cancel();
        foreach (var task in tasks.Values.Where(t => t.State == "running"))
        {
            task.State = "paused";
            task.PausedBy = task.Direction == "send" ? task.RemotePeerID : id;
        }
        foreach (var request in pending.Keys.ToArray())
            Fail(request, "Application stopped.");
        Save();
    }
}
