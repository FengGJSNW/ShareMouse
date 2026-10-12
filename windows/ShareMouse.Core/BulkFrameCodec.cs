using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
namespace ShareMouse.Core;

public static class BulkFrameCodec {
    private static readonly HashSet<string> channels=["files","history","clipboard","computer"];
    public static byte[][] Fragments(string channel,byte[] payload,int size) {
        var id=Guid.NewGuid();var name=Encoding.UTF8.GetBytes(channel);var count=Math.Max(1,(payload.Length+size-1)/size);
        return Enumerable.Range(0,count).Select(index=> {
            var offset=Math.Min(index*size,payload.Length);var length=Math.Min(size,payload.Length-offset);var bytes=new byte[29+name.Length+length];"SBK1"u8.CopyTo(bytes);id.TryWriteBytes(bytes.AsSpan(4,16),true,out _);
            BinaryPrimitives.WriteUInt16BigEndian(bytes.AsSpan(20),(ushort)index);BinaryPrimitives.WriteUInt16BigEndian(bytes.AsSpan(22),(ushort)count);BinaryPrimitives.WriteUInt32BigEndian(bytes.AsSpan(24),(uint)payload.Length);bytes[28]=(byte)name.Length;name.CopyTo(bytes,29);payload.AsSpan(offset,length).CopyTo(bytes.AsSpan(29+name.Length));return bytes;
        }).ToArray();
    }
    public sealed class Assembly(string channel,int total,int count) {public string Channel=channel;public int Total=total,Count=count,Next;public MemoryStream Bytes=new();}
    // This state belongs to one authenticated transport, never a peer-wide fallback.
    public static (string Channel,byte[] Payload)? Consume(byte[] bytes,Dictionary<Guid,Assembly> assemblies) {
        if(bytes.Length<30||!bytes.AsSpan().StartsWith("SBK1"u8))throw new InvalidDataException("Invalid bulk fragment.");
        var key=new Guid(bytes.AsSpan(4,16),true);var index=BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(20));var count=BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(22));var total=BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(24));var end=29+bytes[28];
        if(count is 0 or >256||total>32768||index>=count||end>bytes.Length||bytes.Length-end>384)throw new InvalidDataException("Invalid bulk fragment.");
        var channel=new UTF8Encoding(false,true).GetString(bytes,29,bytes[28]);if(!channels.Contains(channel))throw new InvalidDataException("Invalid bulk channel.");
        if(index==0){if(assemblies.ContainsKey(key)||assemblies.Count>=8)throw new InvalidDataException("Bulk reassembly limit.");assemblies[key]=new(channel,(int)total,count);}
        if(!assemblies.TryGetValue(key,out var state)||state.Channel!=channel||state.Total!=total||state.Count!=count||state.Next!=index)throw new InvalidDataException("Invalid bulk order.");
        state.Bytes.Write(bytes,end,bytes.Length-end);state.Next++;
        if(state.Bytes.Length>total)throw new InvalidDataException("Invalid bulk length.");
        if(state.Next!=count)return null;
        assemblies.Remove(key);if(state.Bytes.Length!=total)throw new InvalidDataException("Invalid bulk length.");return (channel,state.Bytes.ToArray());
    }
}

public static class FilePacketCodec {
    private static readonly JsonSerializerOptions json=new(){PropertyNamingPolicy=JsonNamingPolicy.CamelCase,Encoder=System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,DefaultIgnoreCondition=System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull};
    public static byte[] Encode(FilePacket packet,bool compact) {
        if(!compact||packet.Type!="chunk-data"||packet.Index!=0||packet.Final!=true||packet.Data is not {} data||data.Length>32000||packet.Offset is not >=0||packet.Checksum is null)return JsonSerializer.SerializeToUtf8Bytes(packet,json);
        var bytes=new byte[96+data.Length];"SFC1"u8.CopyTo(bytes);var ids=new[]{packet.GroupID,packet.EntryID,packet.TaskID,packet.RequestID,packet.ItemID};
        for(var i=0;i<5;i++){if(!Guid.TryParse(ids[i],out var id))throw new InvalidDataException("Invalid file ID.");id.TryWriteBytes(bytes.AsSpan(4+i*16,16),true,out _);}
        BinaryPrimitives.WriteInt64BigEndian(bytes.AsSpan(84),packet.Offset.Value);BinaryPrimitives.WriteUInt32BigEndian(bytes.AsSpan(92),packet.Checksum.Value);data.CopyTo(bytes,96);return bytes;
    }
    public static FilePacket Decode(byte[] bytes,bool compact) {
        if(!bytes.AsSpan().StartsWith("SFC1"u8))return JsonSerializer.Deserialize<FilePacket>(bytes,json)??throw new InvalidDataException("Invalid file packet.");
        if(!compact||bytes.Length is <96 or >32096||BinaryPrimitives.ReadInt64BigEndian(bytes.AsSpan(84))<0)throw new InvalidDataException("Invalid compact file.");
        var ids=Enumerable.Range(0,5).Select(i=>new Guid(bytes.AsSpan(4+i*16,16),true).ToString("D")).ToArray();
        return new(){Type="chunk-data",GroupID=ids[0],EntryID=ids[1],TaskID=ids[2],RequestID=ids[3],ItemID=ids[4],Index=0,Final=true,Offset=BinaryPrimitives.ReadInt64BigEndian(bytes.AsSpan(84)),Checksum=BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(92)),Data=bytes[96..]};
    }
}
