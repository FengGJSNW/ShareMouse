namespace ShareMouse.Core;

public sealed record FileItem(string Id, string RootID, string RelativePath, bool Directory, long Size, long Modified, string? Hash = null, bool Available = true, string? LinkTarget = null, bool? LinkDirectory = null);
public sealed record LocalFile(FileItem Item, string Path, string Identity);
public sealed record LocalRoot(string Id, string Path);
public sealed record FileTransaction(ClipboardEntry Entry, string GroupID, LocalRoot[] Roots, LocalFile[] Files, bool OriginalCut);
public sealed record FilePermit(string TaskID, string PeerID, FileTransaction Transaction, string[] Verified, FileTransaction? CutSource = null);
public sealed class TransferFile
{
    public required FileItem Item
    {
        get; set;
    }
    public required string Provider
    {
        get; set;
    }
    public required string Target
    {
        get; set;
    }
    public required string Partial
    {
        get; set;
    }
    public long Received
    {
        get; set;
    }
    public bool Completed
    {
        get; set;
    }
    public string? CompletedIdentity
    {
        get; set;
    }
    public bool Skipped
    {
        get; set;
    }
    public string? Error
    {
        get; set;
    }
}
public sealed class TransferTask
{
    public required string Id
    {
        get; set;
    }
    public required ClipboardEntry Entry
    {
        get; set;
    }
    public required string GroupID
    {
        get; set;
    }
    public required string Destination
    {
        get; set;
    }
    public string? Direction
    {
        get; set;
    }
    [System.Text.Json.Serialization.JsonIgnore]
    public string? Transport
    {
        get; set;
    }
    public string? RemotePeerID
    {
        get; set;
    }
    public ulong? ControlRevision
    {
        get; set;
    }
    public Dictionary<string, ulong>? ReceivedControls
    {
        get; set;
    }
    public string? PausedBy
    {
        get; set;
    }
    public string State { get; set; } = "queued";
    public List<TransferFile> Files { get; set; } = [];
    public string? Error
    {
        get; set;
    }
    public long Created { get; set; } = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    [System.Text.Json.Serialization.JsonIgnore]
    public long Received => Files.Where(f => !f.Item.Directory).Sum(f => f.Completed ? f.Item.Size : f.Received);
    [System.Text.Json.Serialization.JsonIgnore]
    public long Total => Files.Count == 0 ? Entry.TotalBytes ?? 0 : Files.Sum(f => f.Item.Size);
}
public sealed record FileTransferStore(FileTransaction[] Transactions, FilePermit[] Permits, TransferTask[] Tasks, FileTransaction[]? Replicas = null, string? ProgressGeneration = null);
public sealed record FileProgressStore(string Generation, Dictionary<string, Dictionary<string, long>> Tasks);
public sealed class FilePacket
{
    public required string Type
    {
        get; set;
    }
    public required string GroupID
    {
        get; set;
    }
    public required string EntryID
    {
        get; set;
    }
    public required string TaskID
    {
        get; set;
    }
    public ulong? ControlRevision
    {
        get; set;
    }
    public string? State
    {
        get; set;
    }
    public string? RequestID
    {
        get; set;
    }
    public ClipboardEntry? Entry
    {
        get; set;
    }
    public FileItem[]? Items
    {
        get; set;
    }
    public string? ItemID
    {
        get; set;
    }
    public int? Index
    {
        get; set;
    }
    public bool? Final
    {
        get; set;
    }
    public long? Offset
    {
        get; set;
    }
    public int? MaximumBytes
    {
        get; set;
    }
    public byte[]? Data
    {
        get; set;
    }
    public uint? Checksum
    {
        get; set;
    }
    public string? Hash
    {
        get; set;
    }
    public string? Error
    {
        get; set;
    }
    public bool? ExpandedCatalogue
    {
        get; set;
    }
    public string[]? Verified
    {
        get; set;
    }
}
public static class ChunkCheck
{
    public static uint Adler32(ReadOnlySpan<byte> bytes)
    {
        uint a = 1, b = 0;
        foreach (var value in bytes)
        {
            a = (a + value) % 65521;
            b = (b + a) % 65521;
        }
        return (b << 16) | a;
    }
}
