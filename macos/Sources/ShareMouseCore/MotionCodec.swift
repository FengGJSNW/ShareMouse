import Foundation

// Only the authenticated TLS session supplies the source and destination identities.
// Network order, RFC 4122 UUID bytes; screen identities survive layout array reordering.
public enum MotionCodec {
    static let move = Data("SMI1".utf8), ack = Data("SMA1".utf8)
    public static func encode(
        _ packet: InputPacket, layout: [ScreenGeometry], extended: Bool = false, compactScroll: Bool = false,
        compactContext: Bool = false
    ) -> Data? {
        if compactContext, let bytes = encodeContext(packet, layout: layout) { return bytes }
        guard let uuid = UUID(uuidString: packet.groupID) else { return nil }
        var value = uuid.uuid
        if packet.type == "motionAck", let sequence = packet.acknowledgedSequence {
            return ack + withUnsafeBytes(of: &value) { Data($0) } + integer(sequence)
        }
        guard
            (["move", "relative-move"].contains(packet.type)
                || extended && ["control", "pointer"].contains(packet.type)
                || compactScroll && packet.type == "scroll"), let p = packet.pointer,
            p.ownerPeerID == packet.sourcePeerID, layout.contains(where: { $0.id == p.screenID }), p.x.isFinite,
            p.y.isFinite
        else { return nil }
        let name = Data(p.screenID.utf8);
        guard !name.isEmpty, name.count <= 256 else { return nil }
        let prefix =
            packet.type == "relative-move"
            ? Data("SMR1".utf8)
            : packet.type == "scroll"
                ? Data("SMS1".utf8)
                : packet.type == "control" ? Data("SMC1".utf8) : packet.type == "pointer" ? Data("SMP1".utf8) : move
        var encoded =
            prefix + withUnsafeBytes(of: &value) { Data($0) } + integer(packet.sequence) + integer(p.epoch)
            + integer(UInt64(name.count), count: 2) + name + integer(UInt64(Float(p.x).bitPattern), count: 4)
            + integer(UInt64(Float(p.y).bitPattern), count: 4)
        if packet.type == "scroll" {
            guard packet.deltaX.isFinite, packet.deltaY.isFinite, abs(packet.deltaX) <= 10000,
                abs(packet.deltaY) <= 10000, (0...65535).contains(packet.scrollPhase ?? 0),
                (0...65535).contains(packet.momentumPhase ?? 0)
            else { return nil }
            encoded +=
                integer(UInt64(Float(packet.deltaX).bitPattern), count: 4)
                + integer(UInt64(Float(packet.deltaY).bitPattern), count: 4)
            encoded +=
                integer(UInt64(packet.scrollPhase ?? 0), count: 2)
                + integer(UInt64(packet.momentumPhase ?? 0), count: 2) + Data([packet.preciseScroll == true ? 1 : 0])
        }
        if packet.type == "relative-move" {
            guard packet.deltaX.isFinite, packet.deltaY.isFinite, abs(packet.deltaX) <= 1e9, abs(packet.deltaY) <= 1e9
            else { return nil }
            encoded += integer(packet.deltaX.bitPattern) + integer(packet.deltaY.bitPattern)
        }
        return encoded
    }
    public static func decode(
        _ bytes: Data, group: SharedGroup, source: String, target: String, context: PointerState? = nil
    ) -> InputPacket? {
        if isContext(bytes) {
            return decodeContext(bytes, group: group, source: source, target: target, context: context)
        }
        guard isCompact(bytes), let uuid = UUID(uuidString: group.id) else { return nil }
        var value = uuid.uuid
        guard bytes.subdata(in: 4..<20) == withUnsafeBytes(of: &value, { Data($0) }) else { return nil }
        if bytes.prefix(4) == ack, bytes.count == 28 {
            var result = InputPacket(type: "motionAck", groupID: group.id, sourcePeerID: source, targetPeerID: target)
            result.acknowledgedSequence = number(bytes, 20, 8);
            return result
        }
        guard bytes.count >= 46,
            [move, Data("SMC1".utf8), Data("SMP1".utf8), Data("SMS1".utf8), Data("SMR1".utf8)].contains(
                Data(bytes.prefix(4)))
        else { return nil }
        let scroll = bytes.prefix(4) == Data("SMS1".utf8)
        let relative = bytes.prefix(4) == Data("SMR1".utf8)
        let length = Int(number(bytes, 36, 2))
        guard length > 0, length <= 256, bytes.count == (relative ? 62 : scroll ? 59 : 46) + length,
            let screenID = String(data: bytes.subdata(in: 38..<(38 + length)), encoding: .utf8),
            let screen = group.layout.first(where: { $0.id == screenID })
        else { return nil }
        let x = Double(Float(bitPattern: UInt32(number(bytes, 38 + length, 4))))
        let y = Double(Float(bitPattern: UInt32(number(bytes, 42 + length, 4))))
        guard x.isFinite, y.isFinite, x >= screen.x - 0.05, x <= screen.x + screen.width + 0.05, y >= screen.y - 0.05,
            y <= screen.y + screen.height + 0.05
        else { return nil }
        let type =
            relative
            ? "relative-move"
            : scroll
                ? "scroll"
                : bytes.prefix(4) == Data("SMC1".utf8)
                    ? "control" : bytes.prefix(4) == Data("SMP1".utf8) ? "pointer" : "move"
        var result = InputPacket(type: type, groupID: group.id, sourcePeerID: source, targetPeerID: screen.peerID)
        result.sequence = number(bytes, 20, 8);
        result.targetScreenID = screen.id
        result.pointer = PointerState(
            screenID: screen.id, x: max(screen.x, min(screen.x + screen.width, x)),
            y: max(screen.y, min(screen.y + screen.height, y)), ownerPeerID: source, epoch: number(bytes, 28, 8))
        if scroll {
            result.deltaX = Double(Float(bitPattern: UInt32(number(bytes, 46 + length, 4))))
            result.deltaY = Double(Float(bitPattern: UInt32(number(bytes, 50 + length, 4))))
            result.scrollPhase = Int(number(bytes, 54 + length, 2));
            result.momentumPhase = Int(number(bytes, 56 + length, 2));
            result.preciseScroll = bytes[58 + length] == 1
            guard result.deltaX.isFinite, result.deltaY.isFinite, abs(result.deltaX) <= 10000,
                abs(result.deltaY) <= 10000, bytes[58 + length] <= 1
            else { return nil }
        }
        if relative {
            result.deltaX = Double(bitPattern: number(bytes, 46 + length, 8));
            result.deltaY = Double(bitPattern: number(bytes, 54 + length, 8))
            guard result.deltaX.isFinite, result.deltaY.isFinite, abs(result.deltaX) <= 1e9, abs(result.deltaY) <= 1e9
            else { return nil }
        }
        return result
    }
    public static func isCompact(_ bytes: Data) -> Bool {
        isContext(bytes) || bytes.count == 28 && bytes.prefix(4) == ack
            || (46...318).contains(bytes.count)
                && [move, Data("SMC1".utf8), Data("SMP1".utf8), Data("SMS1".utf8), Data("SMR1".utf8)].contains(
                    Data(bytes.prefix(4)))
    }
    public static func isContext(_ bytes: Data) -> Bool {
        let prefix = bytes.prefix(4)
        return bytes.count == 28 && prefix == Data("SMA3".utf8) || bytes.count == 44 && prefix == Data("SMI3".utf8)
            || bytes.count == 57 && prefix == Data("SMS3".utf8) || bytes.count == 60 && prefix == Data("SMR3".utf8)
    }
    private static func encodeContext(_ packet: InputPacket, layout: [ScreenGeometry]) -> Data? {
        guard let uuid = UUID(uuidString: packet.groupID) else { return nil };
        var id = uuid.uuid
        if packet.type == "motionAck", let seq = packet.acknowledgedSequence {
            return Data("SMA3".utf8) + withUnsafeBytes(of: &id) { Data($0) } + integer(seq)
        }
        guard ["move", "scroll", "relative-move"].contains(packet.type), let point = packet.pointer,
            point.ownerPeerID == packet.sourcePeerID, point.x.isFinite, point.y.isFinite,
            layout.contains(where: { $0.id == point.screenID })
        else { return nil }
        let prefix = packet.type == "scroll" ? "SMS3" : packet.type == "relative-move" ? "SMR3" : "SMI3"
        var bytes =
            Data(prefix.utf8) + withUnsafeBytes(of: &id) { Data($0) } + integer(packet.sequence) + integer(point.epoch)
            + integer(UInt64(Float(point.x).bitPattern), count: 4)
            + integer(UInt64(Float(point.y).bitPattern), count: 4)
        if packet.type == "scroll" {
            guard packet.deltaX.isFinite, packet.deltaY.isFinite, abs(packet.deltaX) <= 10000,
                abs(packet.deltaY) <= 10000, (0...65535).contains(packet.scrollPhase ?? 0),
                (0...65535).contains(packet.momentumPhase ?? 0)
            else { return nil }
            bytes +=
                integer(UInt64(Float(packet.deltaX).bitPattern), count: 4)
                + integer(UInt64(Float(packet.deltaY).bitPattern), count: 4)
                + integer(UInt64(packet.scrollPhase ?? 0), count: 2)
                + integer(UInt64(packet.momentumPhase ?? 0), count: 2) + Data([packet.preciseScroll == true ? 1 : 0])
        } else if packet.type == "relative-move" {
            guard packet.deltaX.isFinite, packet.deltaY.isFinite, abs(packet.deltaX) <= 1e9, abs(packet.deltaY) <= 1e9
            else { return nil }
            bytes += integer(packet.deltaX.bitPattern) + integer(packet.deltaY.bitPattern)
        }
        return bytes
    }
    private static func decodeContext(
        _ bytes: Data, group: SharedGroup, source: String, target: String, context: PointerState?
    ) -> InputPacket? {
        guard let uuid = UUID(uuidString: group.id) else { return nil };
        var id = uuid.uuid
        guard bytes.subdata(in: 4..<20) == withUnsafeBytes(of: &id, { Data($0) }) else { return nil }
        if bytes.prefix(4) == Data("SMA3".utf8) {
            var value = InputPacket(type: "motionAck", groupID: group.id, sourcePeerID: source, targetPeerID: target);
            value.acknowledgedSequence = number(bytes, 20, 8);
            return value
        }
        guard let context, context.ownerPeerID == source, context.epoch == number(bytes, 28, 8),
            let screen = group.layout.first(where: { $0.id == context.screenID })
        else { return nil }
        let x = Double(Float(bitPattern: UInt32(number(bytes, 36, 4)))),
            y = Double(Float(bitPattern: UInt32(number(bytes, 40, 4))))
        guard x.isFinite, y.isFinite, x >= screen.x - 0.05, x <= screen.x + screen.width + 0.05, y >= screen.y - 0.05,
            y <= screen.y + screen.height + 0.05
        else { return nil }
        let type =
            bytes.prefix(4) == Data("SMS3".utf8)
            ? "scroll" : bytes.prefix(4) == Data("SMR3".utf8) ? "relative-move" : "move"
        var value = InputPacket(type: type, groupID: group.id, sourcePeerID: source, targetPeerID: screen.peerID);
        value.sequence = number(bytes, 20, 8);
        value.targetScreenID = screen.id;
        value.pointer = PointerState(
            screenID: screen.id, x: max(screen.x, min(screen.x + screen.width, x)),
            y: max(screen.y, min(screen.y + screen.height, y)), ownerPeerID: source, epoch: context.epoch)
        if type == "scroll" {
            value.deltaX = Double(Float(bitPattern: UInt32(number(bytes, 44, 4))));
            value.deltaY = Double(Float(bitPattern: UInt32(number(bytes, 48, 4))));
            value.scrollPhase = Int(number(bytes, 52, 2));
            value.momentumPhase = Int(number(bytes, 54, 2));
            value.preciseScroll = bytes[56] == 1;
            guard value.deltaX.isFinite, value.deltaY.isFinite, abs(value.deltaX) <= 10000, abs(value.deltaY) <= 10000,
                bytes[56] <= 1
            else { return nil }
        }
        if type == "relative-move" {
            value.deltaX = Double(bitPattern: number(bytes, 44, 8));
            value.deltaY = Double(bitPattern: number(bytes, 52, 8));
            guard value.deltaX.isFinite, value.deltaY.isFinite, abs(value.deltaX) <= 1e9, abs(value.deltaY) <= 1e9
            else { return nil }
        }
        return value
    }
    static func integer(_ number: UInt64, count: Int = 8) -> Data {
        Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: number >> ($0 * 8)) })
    }
    static func number(_ bytes: Data, _ offset: Int, _ count: Int) -> UInt64 {
        bytes.subdata(in: offset..<(offset + count)).reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

public enum SessionFrameCodec {
    public static func encode(_ message: SessionMessage) throws -> Data {
        if message.type == "data", message.channel == "diagnostics", message.mode == "compact-diagnostics-v1",
            let payload = message.payload, let probe = try? JSONDecoder().decode(LatencyProbe.self, from: payload),
            let uuid = UUID(uuidString: probe.token), ["probe", "reply"].contains(probe.type)
        {
            var id = uuid.uuid;
            return Data("SLP1".utf8) + MotionCodec.integer(message.sequence) + Data([probe.type == "probe" ? 1 : 2])
                + withUnsafeBytes(of: &id) { Data($0) }
        }
        if message.type == "data", message.channel == "input", let payload = message.payload,
            MotionCodec.isContext(payload)
        {
            return Data("SMM3".utf8) + MotionCodec.integer(message.sequence) + payload
        }
        if message.type == "data", message.mode == "compact-data-v1", let channel = message.channel,
            let payload = message.payload
        {
            let name = Data(channel.utf8)
            guard !name.isEmpty, name.count <= 32, payload.count <= 32768 else { throw PairingError.invalidMessage }
            var bytes =
                Data("SLD1".utf8) + MotionCodec.integer(message.sequence)
                + Data([UInt8(name.count), message.deliveryID == nil ? 0 : 1]) + name
            if let delivery = message.deliveryID {
                guard var id = UUID(uuidString: delivery)?.uuid else { throw PairingError.invalidMessage };
                bytes.append(withUnsafeBytes(of: &id) { Data($0) })
            }
            bytes.append(payload);
            return bytes
        }
        if message.type == "data", message.channel == "input", let payload = message.payload,
            MotionCodec.isCompact(payload), let uuid = UUID(uuidString: message.sessionID ?? "")
        {
            var value = uuid.uuid
            return Data("SMM2".utf8) + withUnsafeBytes(of: &value) { Data($0) } + MotionCodec.integer(message.sequence)
                + payload
        }
        return try JSONEncoder().encode(message)
    }
    public static func decode(_ bytes: Data) throws -> SessionMessage {
        if bytes.prefix(4) == Data("SLD1".utf8) {
            guard bytes.count >= 15, bytes[12] > 0, bytes[12] <= 32, bytes[13] <= 1 else {
                throw PairingError.invalidMessage
            }
            let end = 14 + Int(bytes[12]), body = end + (bytes[13] == 1 ? 16 : 0)
            guard bytes.count >= body, bytes.count - body <= 32768,
                let name = String(data: bytes.subdata(in: 14..<end), encoding: .utf8)
            else { throw PairingError.invalidMessage }
            var value = SessionMessage(type: "compact-data", sourcePeerID: "");
            value.sequence = MotionCodec.number(bytes, 4, 8);
            value.channel = name;
            value.payload = bytes.subdata(in: body..<bytes.count)
            if bytes[13] == 1 {
                let b = Array(bytes[end..<body]);
                value.deliveryID = UUID(
                    uuid: (
                        b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14],
                        b[15]
                    )
                ).uuidString.lowercased()
            }
            return value
        }
        if bytes.prefix(4) == Data("SLP1".utf8) {
            guard bytes.count == 29, [1, 2].contains(bytes[12]) else { throw PairingError.invalidMessage }
            let b = Array(bytes[13..<29]);
            let uuid = UUID(
                uuid: (
                    b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
                ))
            var value = SessionMessage(type: "compact-diagnostics", sourcePeerID: "");
            value.sequence = MotionCodec.number(bytes, 4, 8);
            value.channel = "diagnostics";
            value.payload = try JSONEncoder().encode(
                LatencyProbe(type: bytes[12] == 1 ? "probe" : "reply", token: uuid.uuidString.lowercased()));
            return value
        }
        if bytes.prefix(4) == Data("SMM3".utf8) {
            guard bytes.count >= 40, bytes.count <= 72, MotionCodec.isContext(bytes.subdata(in: 12..<bytes.count))
            else { throw PairingError.invalidMessage };
            var value = SessionMessage(type: "compact-input-v3", sourcePeerID: "");
            value.sequence = MotionCodec.number(bytes, 4, 8);
            value.channel = "input";
            value.payload = bytes.subdata(in: 12..<bytes.count);
            return value
        }
        guard bytes.prefix(4) == Data("SMM2".utf8) else {
            return try JSONDecoder().decode(SessionMessage.self, from: bytes)
        }
        guard bytes.count >= 56, bytes.count <= 346, MotionCodec.isCompact(bytes.subdata(in: 28..<bytes.count)) else {
            throw PairingError.invalidMessage
        }
        let b = Array(bytes[4..<20]);
        let uuid = UUID(
            uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
        )
        var result = SessionMessage(type: "compact-input", sourcePeerID: "")
        result.sessionID = uuid.uuidString.lowercased();
        result.sequence = MotionCodec.number(bytes, 20, 8)
        result.channel = "input";
        result.payload = bytes.subdata(in: 28..<bytes.count);
        return result
    }
}
