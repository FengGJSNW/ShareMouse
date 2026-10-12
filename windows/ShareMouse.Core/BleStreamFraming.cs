using System.Buffers.Binary;
namespace ShareMouse.Core;

// Headers order opaque TLS ciphertext, without weakening TLS authentication.
public sealed class BleStreamFraming {
    private ulong sent,expected;
    private readonly Dictionary<ulong,byte[]> waiting=new();
    public int Reordered {get;private set;}
    public int Duplicates {get;private set;}
    public ulong NextExpected => expected;
    public int PendingCount => waiting.Count;
    public byte[] Encode(byte[] bytes) {
        var frame=new byte[12+bytes.Length]; "SBF1"u8.CopyTo(frame);
        BinaryPrimitives.WriteUInt64BigEndian(frame.AsSpan(4),sent++); bytes.CopyTo(frame,12); return frame;
    }
    public byte[][] Receive(byte[] frame) {
        if(frame.Length is <=12 or >512 || !frame.AsSpan(0,4).SequenceEqual("SBF1"u8)) throw new InvalidDataException("Invalid BLE stream fragment.");
        var sequence=BinaryPrimitives.ReadUInt64BigEndian(frame.AsSpan(4));
        if(sequence<expected){Duplicates++;return [];}
        if(sequence-expected>=64)throw new InvalidDataException("BLE stream gap exceeds window.");
        var payload=frame[12..];
        if(waiting.TryGetValue(sequence,out var previous)) {if(!previous.SequenceEqual(payload))throw new InvalidDataException("Conflicting BLE fragment.");return [];}
        if(sequence!=expected)Reordered++;
        waiting[sequence]=payload;var ordered=new List<byte[]>();
        while(waiting.Remove(expected,out var bytes)) {ordered.Add(bytes);expected++;}
        return ordered.ToArray();
    }
}
