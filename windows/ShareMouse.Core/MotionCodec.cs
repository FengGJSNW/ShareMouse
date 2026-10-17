using System.Buffers.Binary;
using System.Text;
using System.Text.Json;

namespace ShareMouse.Core;

public static class MotionCodec
{
    public static byte[]? Encode(InputPacket packet, ScreenGeometry[] layout, bool extended = false, bool compactScroll = false, bool compactContext = false)
    {
        if (compactContext && EncodeContext(packet, layout) is { } contextual)
            return contextual;
        if (!Guid.TryParse(packet.GroupID, out var group))
            return null;
        var relative = packet.Type == "relative-move";
        var scroll = compactScroll && packet.Type == "scroll";
        var ack = packet.Type == "motionAck" && packet.AcknowledgedSequence.HasValue;
        if (!ack && ((!scroll && !relative && packet.Type != "move" && !(extended && packet.Type is "control" or "pointer")) || packet.Pointer is not { } candidate || candidate.OwnerPeerID != packet.SourcePeerID || !layout.Any(s => s.Id == candidate.ScreenID) || !double.IsFinite(candidate.X) || !double.IsFinite(candidate.Y)))
            return null;
        var name = ack ? Array.Empty<byte>() : Encoding.UTF8.GetBytes(packet.Pointer!.ScreenID);
        if (!ack && name.Length is < 1 or > 256)
            return null;
        var bytes = new byte[ack ? 28 : (relative ? 62 : scroll ? 59 : 46) + name.Length];
        Encoding.ASCII.GetBytes(ack ? "SMA1" : relative ? "SMR1" : scroll ? "SMS1" : packet.Type == "control" ? "SMC1" : packet.Type == "pointer" ? "SMP1" : "SMI1").CopyTo(bytes, 0);
        group.TryWriteBytes(bytes.AsSpan(4, 16), true, out _);
        BinaryPrimitives.WriteUInt64BigEndian(bytes.AsSpan(20), ack ? packet.AcknowledgedSequence!.Value : packet.Sequence);
        if (!ack)
        {
            var p = packet.Pointer!;
            BinaryPrimitives.WriteUInt64BigEndian(bytes.AsSpan(28), p.Epoch);
            BinaryPrimitives.WriteUInt16BigEndian(bytes.AsSpan(36), (ushort)name.Length);
            name.CopyTo(bytes, 38);
            BinaryPrimitives.WriteSingleBigEndian(bytes.AsSpan(38 + name.Length), (float)p.X);
            BinaryPrimitives.WriteSingleBigEndian(bytes.AsSpan(42 + name.Length), (float)p.Y);
        }
        if (scroll)
        {
            if (!double.IsFinite(packet.DeltaX) || !double.IsFinite(packet.DeltaY) || Math.Abs(packet.DeltaX) > 10000 || Math.Abs(packet.DeltaY) > 10000 || packet.ScrollPhase is < 0 or > 65535 || packet.MomentumPhase is < 0 or > 65535)
                return null;
            BinaryPrimitives.WriteSingleBigEndian(bytes.AsSpan(46 + name.Length), (float)packet.DeltaX);
            BinaryPrimitives.WriteSingleBigEndian(bytes.AsSpan(50 + name.Length), (float)packet.DeltaY);
            BinaryPrimitives.WriteUInt16BigEndian(bytes.AsSpan(54 + name.Length), (ushort)(packet.ScrollPhase ?? 0));
            BinaryPrimitives.WriteUInt16BigEndian(bytes.AsSpan(56 + name.Length), (ushort)(packet.MomentumPhase ?? 0));
            bytes[58 + name.Length] = (byte)(packet.PreciseScroll == true ? 1 : 0);
        }
        if (relative)
        {
            if (!double.IsFinite(packet.DeltaX) || !double.IsFinite(packet.DeltaY) || Math.Abs(packet.DeltaX) > 1e9 || Math.Abs(packet.DeltaY) > 1e9)
                return null;
            BinaryPrimitives.WriteDoubleBigEndian(bytes.AsSpan(46 + name.Length), packet.DeltaX);
            BinaryPrimitives.WriteDoubleBigEndian(bytes.AsSpan(54 + name.Length), packet.DeltaY);
        }
        return bytes;
    }
    public static InputPacket? Decode(byte[] bytes, SharedGroup group, string source, string target, PointerState? context = null)
    {
        if (IsContext(bytes))
            return DecodeContext(bytes, group, source, target, context);
        if (!IsCompact(bytes) || !Guid.TryParse(group.Id, out var id) || new Guid(bytes.AsSpan(4, 16), true) != id)
            return null;
        var prefix = Encoding.ASCII.GetString(bytes, 0, 4);
        if (prefix == "SMA1" && bytes.Length == 28)
            return new()
            {
                Type = "motionAck",
                GroupID = group.Id,
                SourcePeerID = source,
                TargetPeerID = target,
                AcknowledgedSequence = BinaryPrimitives.ReadUInt64BigEndian(bytes.AsSpan(20))
            };
        if (prefix is not ("SMI1" or "SMC1" or "SMP1" or "SMS1" or "SMR1") || bytes.Length < 46)
            return null;
        var relative = prefix == "SMR1";
        var scroll = prefix == "SMS1";
        var length = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(36));
        if (length is < 1 or > 256 || bytes.Length != (relative ? 62 : scroll ? 59 : 46) + length)
            return null;
        var name = Encoding.UTF8.GetString(bytes, 38, length);
        var screen = group.Layout.SingleOrDefault(s => s.Id == name);
        if (screen is null)
            return null;
        var x = BinaryPrimitives.ReadSingleBigEndian(bytes.AsSpan(38 + length));
        var y = BinaryPrimitives.ReadSingleBigEndian(bytes.AsSpan(42 + length));
        if (!float.IsFinite(x) || !float.IsFinite(y) || x < screen.X - .05 || x > screen.X + screen.Width + .05 || y < screen.Y - .05 || y > screen.Y + screen.Height + .05)
            return null;
        var result = new InputPacket
        {
            Type = relative ? "relative-move" : scroll ? "scroll" : prefix == "SMC1" ? "control" : prefix == "SMP1" ? "pointer" : "move",
            GroupID = group.Id,
            SourcePeerID = source,
            TargetPeerID = screen.PeerID,
            TargetScreenID = screen.Id,
            Sequence = BinaryPrimitives.ReadUInt64BigEndian(bytes.AsSpan(20)),
            Pointer = new(screen.Id,
                Math.Clamp(x, screen.X, screen.X + screen.Width), Math.Clamp(y, screen.Y, screen.Y + screen.Height), source, BinaryPrimitives.ReadUInt64BigEndian(bytes.AsSpan(28)))
        };
        if (scroll)
        {
            result.DeltaX = BinaryPrimitives.ReadSingleBigEndian(bytes.AsSpan(46 + length));
            result.DeltaY = BinaryPrimitives.ReadSingleBigEndian(bytes.AsSpan(50 + length));
            result.ScrollPhase = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(54 + length));
            result.MomentumPhase = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(56 + length));
            result.PreciseScroll = bytes[58 + length] == 1;
            if (!double.IsFinite(result.DeltaX) || !double.IsFinite(result.DeltaY) || Math.Abs(result.DeltaX) > 10000 || Math.Abs(result.DeltaY) > 10000 || bytes[58 + length] > 1)
                return null;
        }
        if (relative)
        {
            result.DeltaX = BinaryPrimitives.ReadDoubleBigEndian(bytes.AsSpan(46 + length));
            result.DeltaY = BinaryPrimitives.ReadDoubleBigEndian(bytes.AsSpan(54 + length));
            if (!double.IsFinite(result.DeltaX) || !double.IsFinite(result.DeltaY) || Math.Abs(result.DeltaX) > 1e9 || Math.Abs(result.DeltaY) > 1e9)
                return null;
        }
        return result;
    }
    public static bool IsContext(byte[] bytes)
    {
        if (bytes.Length < 4)
            return false;
        var p = Encoding.ASCII.GetString(bytes, 0, 4);
        return p == "SMA3" && bytes.Length == 28 || p == "SMI3" && bytes.Length == 44 || p == "SMS3" && bytes.Length == 57 || p == "SMR3" && bytes.Length == 60;
    }
    private static byte[]? EncodeContext(InputPacket packet, ScreenGeometry[] layout)
    {
        if (!Guid.TryParse(packet.GroupID, out var group))
            return null;
        var ack = packet.Type == "motionAck" && packet.AcknowledgedSequence.HasValue;
        if (!ack && (packet.Type is not ("move" or "scroll" or "relative-move") || packet.Pointer is not { } p || p.OwnerPeerID != packet.SourcePeerID || !double.IsFinite(p.X) || !double.IsFinite(p.Y) || !layout.Any(s => s.Id == p.ScreenID)))
            return null;
        var bytes = new byte[ack ? 28 : packet.Type == "scroll" ? 57 : packet.Type == "relative-move" ? 60 : 44];
        Encoding.ASCII.GetBytes(ack ? "SMA3" : packet.Type == "scroll" ? "SMS3" : packet.Type == "relative-move" ? "SMR3" : "SMI3").CopyTo(bytes, 0);
        group.TryWriteBytes(bytes.AsSpan(4, 16), true, out _);
        BinaryPrimitives.WriteUInt64BigEndian(bytes.AsSpan(20), ack ? packet.AcknowledgedSequence!.Value : packet.Sequence);
        if (ack)
            return bytes;
        var point = packet.Pointer!;
        BinaryPrimitives.WriteUInt64BigEndian(bytes.AsSpan(28), point.Epoch);
        BinaryPrimitives.WriteSingleBigEndian(bytes.AsSpan(36), (float)point.X);
        BinaryPrimitives.WriteSingleBigEndian(bytes.AsSpan(40), (float)point.Y);
        if (packet.Type == "scroll")
        {
            if (!double.IsFinite(packet.DeltaX) || !double.IsFinite(packet.DeltaY) || Math.Abs(packet.DeltaX) > 10000 || Math.Abs(packet.DeltaY) > 10000 || packet.ScrollPhase is < 0 or > 65535 || packet.MomentumPhase is < 0 or > 65535)
                return null;
            BinaryPrimitives.WriteSingleBigEndian(bytes.AsSpan(44), (float)packet.DeltaX);
            BinaryPrimitives.WriteSingleBigEndian(bytes.AsSpan(48), (float)packet.DeltaY);
            BinaryPrimitives.WriteUInt16BigEndian(bytes.AsSpan(52), (ushort)(packet.ScrollPhase ?? 0));
            BinaryPrimitives.WriteUInt16BigEndian(bytes.AsSpan(54), (ushort)(packet.MomentumPhase ?? 0));
            bytes[56] = packet.PreciseScroll == true ? (byte)1 : (byte)0;
        }
        else if (packet.Type == "relative-move")
        {
            if (!double.IsFinite(packet.DeltaX) || !double.IsFinite(packet.DeltaY) || Math.Abs(packet.DeltaX) > 1e9 || Math.Abs(packet.DeltaY) > 1e9)
                return null;
            BinaryPrimitives.WriteDoubleBigEndian(bytes.AsSpan(44), packet.DeltaX);
            BinaryPrimitives.WriteDoubleBigEndian(bytes.AsSpan(52), packet.DeltaY);
        }
        return bytes;
    }
    private static InputPacket? DecodeContext(byte[] bytes, SharedGroup group, string source, string target, PointerState? context)
    {
        if (!Guid.TryParse(group.Id, out var id) || new Guid(bytes.AsSpan(4, 16), true) != id)
            return null;
        var prefix = Encoding.ASCII.GetString(bytes, 0, 4);
        if (prefix == "SMA3")
            return new()
            {
                Type = "motionAck",
                GroupID = group.Id,
                SourcePeerID = source,
                TargetPeerID = target,
                AcknowledgedSequence = BinaryPrimitives.ReadUInt64BigEndian(bytes.AsSpan(20))
            };
        if (context is null || context.OwnerPeerID != source || context.Epoch != BinaryPrimitives.ReadUInt64BigEndian(bytes.AsSpan(28)))
            return null;
        var screen = group.Layout.SingleOrDefault(s => s.Id == context.ScreenID);
        if (screen is null)
            return null;
        var x = BinaryPrimitives.ReadSingleBigEndian(bytes.AsSpan(36));
        var y = BinaryPrimitives.ReadSingleBigEndian(bytes.AsSpan(40));
        if (!float.IsFinite(x) || !float.IsFinite(y) || x < screen.X - .05 || x > screen.X + screen.Width + .05 || y < screen.Y - .05 || y > screen.Y + screen.Height + .05)
            return null;
        var value = new InputPacket { Type = prefix == "SMS3" ? "scroll" : prefix == "SMR3" ? "relative-move" : "move", GroupID = group.Id, SourcePeerID = source, TargetPeerID = screen.PeerID, TargetScreenID = screen.Id, Sequence = BinaryPrimitives.ReadUInt64BigEndian(bytes.AsSpan(20)), Pointer = new(screen.Id, Math.Clamp(x, screen.X, screen.X + screen.Width), Math.Clamp(y, screen.Y, screen.Y + screen.Height), source, context.Epoch) };
        if (prefix == "SMS3")
        {
            value.DeltaX = BinaryPrimitives.ReadSingleBigEndian(bytes.AsSpan(44));
            value.DeltaY = BinaryPrimitives.ReadSingleBigEndian(bytes.AsSpan(48));
            value.ScrollPhase = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(52));
            value.MomentumPhase = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(54));
            value.PreciseScroll = bytes[56] == 1;
            if (!double.IsFinite(value.DeltaX) || !double.IsFinite(value.DeltaY) || Math.Abs(value.DeltaX) > 10000 || Math.Abs(value.DeltaY) > 10000 || bytes[56] > 1)
                return null;
        }
        if (prefix == "SMR3")
        {
            value.DeltaX = BinaryPrimitives.ReadDoubleBigEndian(bytes.AsSpan(44));
            value.DeltaY = BinaryPrimitives.ReadDoubleBigEndian(bytes.AsSpan(52));
            if (!double.IsFinite(value.DeltaX) || !double.IsFinite(value.DeltaY) || Math.Abs(value.DeltaX) > 1e9 || Math.Abs(value.DeltaY) > 1e9)
                return null;
        }
        return value;
    }
    public static bool IsCompact(byte[] bytes) => IsContext(bytes) || bytes.Length == 28 && bytes.AsSpan(0, 4).SequenceEqual("SMA1"u8) || bytes.Length is >= 46 and <= 318 && (bytes.AsSpan(0, 4).SequenceEqual("SMI1"u8) || bytes.AsSpan(0, 4).SequenceEqual("SMC1"u8) || bytes.AsSpan(0, 4).SequenceEqual("SMP1"u8) || bytes.AsSpan(0, 4).SequenceEqual("SMS1"u8) || bytes.AsSpan(0, 4).SequenceEqual("SMR1"u8));
}
public static class SessionFrameCodec
{
    private static readonly JsonSerializerOptions json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull };
    public static byte[] Encode(SessionMessage message)
    {
        if (message.Type == "data" && message.Channel == "diagnostics" && message.Mode == "compact-diagnostics-v1" && message.Payload is { } probeBytes)
        {
            var probe = JsonSerializer.Deserialize<LatencyProbe>(probeBytes, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            if (probe?.Type is "probe" or "reply" && Guid.TryParse(probe.Token, out var nonce))
            {
                var frame = new byte[29];
                "SLP1"u8.CopyTo(frame);
                BinaryPrimitives.WriteUInt64BigEndian(frame.AsSpan(4), message.Sequence);
                frame[12] = probe.Type == "probe" ? (byte)1 : (byte)2;
                nonce.TryWriteBytes(frame.AsSpan(13, 16), true, out _);
                return frame;
            }
        }
        if (message.Type == "data" && message.Channel == "input" && message.Payload is { } contextual && MotionCodec.IsContext(contextual))
        {
            var frame = new byte[12 + contextual.Length];
            "SMM3"u8.CopyTo(frame);
            BinaryPrimitives.WriteUInt64BigEndian(frame.AsSpan(4), message.Sequence);
            contextual.CopyTo(frame, 12);
            return frame;
        }
        if (message.Type == "data" && message.Mode == "compact-data-v1" && message.Channel is { } channel && message.Payload is { } body)
        {
            var name = System.Text.Encoding.UTF8.GetBytes(channel);
            var delivery = message.DeliveryID;
            if (name.Length is < 1 or > 32 || body.Length > 32768 || delivery is not null && !Guid.TryParse(delivery, out _))
                throw new InvalidDataException("Invalid compact data.");
            var bytes = new byte[14 + name.Length + (delivery is null ? 0 : 16) + body.Length];
            "SLD1"u8.CopyTo(bytes);
            BinaryPrimitives.WriteUInt64BigEndian(bytes.AsSpan(4), message.Sequence);
            bytes[12] = (byte)name.Length;
            bytes[13] = delivery is null ? (byte)0 : (byte)1;
            name.CopyTo(bytes, 14);
            if (delivery is not null)
                Guid.Parse(delivery).TryWriteBytes(bytes.AsSpan(14 + name.Length, 16), true, out _);
            body.CopyTo(bytes, bytes.Length - body.Length);
            return bytes;
        }
        if (message.Type == "data" && message.Channel == "input" && message.Payload is { } p && MotionCodec.IsCompact(p) && Guid.TryParse(message.SessionID, out var id))
        {
            var bytes = new byte[28 + p.Length];
            "SMM2"u8.CopyTo(bytes);
            id.TryWriteBytes(bytes.AsSpan(4, 16), true, out _);
            BinaryPrimitives.WriteUInt64BigEndian(bytes.AsSpan(20), message.Sequence);
            p.CopyTo(bytes, 28);
            return bytes;
        }
        return JsonSerializer.SerializeToUtf8Bytes(message, json);
    }
    public static SessionMessage Decode(byte[] bytes)
    {
        if (bytes.AsSpan().StartsWith("SLD1"u8))
        {
            if (bytes.Length < 15 || bytes[12] is < 1 or > 32 || bytes[13] > 1)
                throw new InvalidDataException("Invalid compact data.");
            var end = 14 + bytes[12];
            var body = end + (bytes[13] == 1 ? 16 : 0);
            if (bytes.Length < body || bytes.Length - body > 32768)
                throw new InvalidDataException("Invalid compact data.");
            return new()
            {
                Type = "compact-data",
                SourcePeerID = "",
                Sequence = BinaryPrimitives.ReadUInt64BigEndian(bytes.AsSpan(4)),
                Channel = new System.Text.UTF8Encoding(false, true).GetString(bytes, 14, bytes[12]),
                DeliveryID = bytes[13] == 1 ? new Guid(bytes.AsSpan(end, 16), true).ToString("D") : null,
                Payload = bytes[body..]
            };
        }
        if (bytes.AsSpan().StartsWith("SLP1"u8))
        {
            if (bytes.Length != 29 || bytes[12] is not (1 or 2))
                throw new InvalidDataException("Invalid compact probe.");
            var probe = new LatencyProbe(bytes[12] == 1 ? "probe" : "reply", new Guid(bytes.AsSpan(13, 16), true).ToString("D"));
            return new()
            {
                Type = "compact-diagnostics",
                SourcePeerID = "",
                Sequence = BinaryPrimitives.ReadUInt64BigEndian(bytes.AsSpan(4)),
                Channel = "diagnostics",
                Payload = JsonSerializer.SerializeToUtf8Bytes(probe, json)
            };
        }
        if (bytes.AsSpan().StartsWith("SMM3"u8))
        {
            if (bytes.Length is < 40 or > 72 || !MotionCodec.IsContext(bytes[12..]))
                throw new InvalidDataException("Invalid context frame.");
            return new()
            {
                Type = "compact-input-v3",
                SourcePeerID = "",
                Sequence = BinaryPrimitives.ReadUInt64BigEndian(bytes.AsSpan(4)),
                Channel = "input",
                Payload = bytes[12..]
            };
        }
        if (!bytes.AsSpan().StartsWith("SMM2"u8))
            return JsonSerializer.Deserialize<SessionMessage>(bytes, json) ?? throw new InvalidDataException("Invalid frame.");
        if (bytes.Length is < 56 or > 346 || !MotionCodec.IsCompact(bytes[28..]))
            throw new InvalidDataException("Invalid compact frame.");
        return new()
        {
            Type = "compact-input",
            SourcePeerID = "",
            SessionID = new Guid(bytes.AsSpan(4, 16), true).ToString("D"),
            Sequence = BinaryPrimitives.ReadUInt64BigEndian(bytes.AsSpan(20)),
            Channel = "input",
            Payload = bytes[28..]
        };
    }
}
