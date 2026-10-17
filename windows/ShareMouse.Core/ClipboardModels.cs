namespace ShareMouse.Core;

public sealed record ClipboardEntry(string Id, string SourcePeerID, ulong Counter, long Timestamp, string Kind, int ByteCount, string[]? Providers = null, bool? Cut = null, int? FileCount = null, long? TotalBytes = null, ulong? FileRevision = null)
{
    public static bool Newer(ClipboardEntry a, ClipboardEntry? b) => b is null || a.Counter > b.Counter || a.Counter == b.Counter
        && (a.Timestamp > b.Timestamp || a.Timestamp == b.Timestamp && string.CompareOrdinal(a.SourcePeerID, b.SourcePeerID) > 0);
}
public sealed class ClipboardPacket
{
    public required string Type
    {
        get; set;
    }
    public required string GroupID
    {
        get; set;
    }
    public ClipboardEntry? Entry
    {
        get; set;
    }
    public string? EntryID
    {
        get; set;
    }
    public string? RequestID
    {
        get; set;
    }
    public int? Offset
    {
        get; set;
    }
    public int? Total
    {
        get; set;
    }
    public byte[]? Data
    {
        get; set;
    }
    public string? Error
    {
        get; set;
    }
    public bool? Present
    {
        get; set;
    }
}

public sealed record ClipboardContent(string Kind, byte[] Data, string? PlainText = null)
{
    public static ClipboardContent Text(string value) => new("text", System.Text.Encoding.UTF8.GetBytes(value), value);
    public void Validate()
    {
        if (Kind is not ("text" or "png" or "url" or "html" or "rtf") || Data.Length > (Kind == "text" ? 4 * 1024 * 1024 : 16 * 1024 * 1024) || System.Text.Encoding.UTF8.GetByteCount(PlainText ?? "") > 4 * 1024 * 1024)
            throw new System.IO.InvalidDataException("Unsupported clipboard content size or type.");
        if (Kind == "png")
        {
            if (Data.Length < 24 || !Data.AsSpan(0, 8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }) || !Data.AsSpan(12, 4).SequenceEqual(new byte[] { 73, 72, 68, 82 }))
                throw new System.IO.InvalidDataException("Invalid PNG.");
            var w = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(Data.AsSpan(16, 4));
            var h = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(Data.AsSpan(20, 4));
            if (w == 0 || h == 0 || w > 16384 || h > 16384 || (ulong)w * h > 64_000_000)
                throw new System.IO.InvalidDataException("Image dimensions exceed limit.");
        }
        else if (Kind != "rtf")
        {
            var value = new System.Text.UTF8Encoding(false, true).GetString(Data);
            if (Kind == "url" && !Uri.TryCreate(value, UriKind.Absolute, out _))
                throw new System.IO.InvalidDataException("Invalid URL.");
        }
    }
}

// CF_HTML offsets count UTF-8 bytes, including the ASCII header.
public static class HtmlClipboard
{
    public static string Decode(string value)
    {
        var bytes = System.Text.Encoding.UTF8.GetBytes(value);
        var header = value[..Math.Min(value.Length, 4096)];
        int Offset(string key)
        {
            var match = System.Text.RegularExpressions.Regex.Match(header, @"(?m)^" + key + @":\s*(\d+)");
            return match.Success && int.TryParse(match.Groups[1].Value, out var result) ? result : -1;
        }
        var start = Offset("StartFragment");
        var end = Offset("EndFragment");
        if (start < 0 || end < start || end > bytes.Length)
            throw new System.IO.InvalidDataException("Invalid CF_HTML offsets.");
        return new System.Text.UTF8Encoding(false, true).GetString(bytes, start, end - start);
    }
    public static string Encode(string fragment)
    {
        const string pattern = "Version:1.0\r\nStartHTML:{0:D10}\r\nEndHTML:{1:D10}\r\nStartFragment:{2:D10}\r\nEndFragment:{3:D10}\r\n";
        const string before = "<html><body><!--StartFragment-->";
        const string after = "<!--EndFragment--></body></html>";
        var start = System.Text.Encoding.UTF8.GetByteCount(string.Format(System.Globalization.CultureInfo.InvariantCulture, pattern, 0, 0, 0, 0));
        var first = start + System.Text.Encoding.UTF8.GetByteCount(before);
        var last = first + System.Text.Encoding.UTF8.GetByteCount(fragment);
        var end = last + System.Text.Encoding.UTF8.GetByteCount(after);
        return string.Format(System.Globalization.CultureInfo.InvariantCulture, pattern, start, end, first, last) + before + fragment + after;
    }
}
