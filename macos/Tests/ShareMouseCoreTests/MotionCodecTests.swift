import XCTest
@testable import ShareMouseCore
final class MotionCodecTests: XCTestCase {
    func testCompactV3ContextAndTinyDiagnosticEnvelope() throws {
        let source="66666666-7777-8888-9999-aaaaaaaaaaaa",target="bbbbbbbb-cccc-dddd-eeee-ffffffffffff",id="11111111-2222-3333-4444-555555555555"
        let screen=ScreenGeometry(id:target+":long-display-name",peerID:target,name:"Screen",number:1,pixelWidth:1000,pixelHeight:1000,primary:true,x:0,y:0)
        let group=SharedGroup(id:id,name:"Fixture",leaderID:source,revision:1,members:[],layout:[screen],configs:[],currentConfigID:"")
        let context=PointerState(screenID:screen.id,x:40.5,y:20.25,ownerPeerID:source,epoch:9)
        var packet=InputPacket(type:"scroll",groupID:id,sourcePeerID:source,targetPeerID:target);packet.sequence=123;packet.pointer=context;packet.deltaX=0.25;packet.deltaY = -2.75;packet.scrollPhase=2;packet.preciseScroll=true
        let bytes=try XCTUnwrap(MotionCodec.encode(packet,layout:group.layout,compactScroll:true,compactContext:true));XCTAssertEqual(bytes.count,57)
        XCTAssertNil(MotionCodec.decode(bytes,group:group,source:source,target:target),"A reduced frame cannot guess the current screen")
        var wrong=context;wrong.epoch+=1;XCTAssertNil(MotionCodec.decode(bytes,group:group,source:source,target:target,context:wrong))
        let decoded=try XCTUnwrap(MotionCodec.decode(bytes,group:group,source:source,target:target,context:context));XCTAssertEqual(decoded.deltaY,packet.deltaY);XCTAssertEqual(decoded.pointer,context)
        var envelope=SessionMessage(type:"data",sourcePeerID:source);envelope.sessionID=id;envelope.sequence=4;envelope.channel="input";envelope.payload=bytes
        let wire=try SessionFrameCodec.encode(envelope);XCTAssertEqual(wire.count,69);XCTAssertEqual(try SessionFrameCodec.decode(wire).type,"compact-input-v3")
        envelope.channel="diagnostics";envelope.mode="compact-diagnostics-v1";envelope.payload=try JSONEncoder().encode(LatencyProbe(type:"probe",token:id))
        let tiny=try SessionFrameCodec.encode(envelope);XCTAssertEqual(tiny.count,29)
        let reply=try SessionFrameCodec.decode(tiny);let probe=try JSONDecoder().decode(LatencyProbe.self,from:try XCTUnwrap(reply.payload));XCTAssertEqual(probe.token,id);XCTAssertEqual(probe.type,"probe")
        var damaged=tiny;damaged[12]=9;XCTAssertThrowsError(try SessionFrameCodec.decode(damaged))
    }

    func testRelativeMotionRetainsCumulativePrecisionAndRejectsInvalidFrames() throws {
        let source="66666666-7777-8888-9999-aaaaaaaaaaaa",target="bbbbbbbb-cccc-dddd-eeee-ffffffffffff",id="11111111-2222-3333-4444-555555555555"
        let screen=ScreenGeometry(id:"screen-一",peerID:target,name:"Screen",number:1,pixelWidth:1000,pixelHeight:1000,primary:true,x:0,y:0)
        let group=SharedGroup(id:id,name:"Fixture",leaderID:source,revision:1,members:[],layout:[screen],configs:[],currentConfigID:"")
        var packet=InputPacket(type:"relative-move",groupID:id,sourcePeerID:source,targetPeerID:target);packet.sequence=123;packet.pointer=PointerState(screenID:screen.id,x:40.5,y:20.25,ownerPeerID:source,epoch:9);packet.deltaX=12345.125;packet.deltaY = -0.25
        let bytes=try XCTUnwrap(MotionCodec.encode(packet,layout:group.layout));XCTAssertEqual(bytes.count,62+screen.id.utf8.count)
        let decoded=try XCTUnwrap(MotionCodec.decode(bytes,group:group,source:source,target:target));XCTAssertEqual(decoded.deltaX,packet.deltaX);XCTAssertEqual(decoded.deltaY,packet.deltaY);XCTAssertEqual(decoded.type,"relative-move")
        XCTAssertNil(MotionCodec.decode(Data(bytes.dropLast()),group:group,source:source,target:target))
        packet.deltaX = .infinity;XCTAssertNil(MotionCodec.encode(packet,layout:group.layout))
    }

    func testCompactScrollVectorRequiresCapabilityAndRejectsMalformedPayload() throws {
        let source = "66666666-7777-8888-9999-aaaaaaaaaaaa", target = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff", id = "11111111-2222-3333-4444-555555555555"
        let screen = ScreenGeometry(id: "screen-一", peerID: target, name: "Screen", number: 1, pixelWidth: 1000, pixelHeight: 1000, primary: true, x: 0, y: 0)
        let group = SharedGroup(id: id, name: "Fixture", leaderID: source, revision: 1, members: [], layout: [screen], configs: [], currentConfigID: "")
        var packet = InputPacket(type: "scroll", groupID: id, sourcePeerID: source, targetPeerID: target)
        packet.sequence = 123; packet.pointer = PointerState(screenID: screen.id, x: 40.5, y: 20.25, ownerPeerID: source, epoch: 9)
        packet.deltaX = 1.5; packet.deltaY = -2.25; packet.scrollPhase = 2; packet.momentumPhase = 3; packet.preciseScroll = true
        XCTAssertNil(MotionCodec.encode(packet, layout: group.layout), "Old peers must retain JSON scroll")
        let bytes = try XCTUnwrap(MotionCodec.encode(packet, layout: group.layout, compactScroll: true))
        XCTAssertEqual(bytes.map { String(format: "%02x", $0) }.joined(), "534d533111111111222233334444555555555555000000000000007b0000000000000009000a73637265656e2de4b8804222000041a200003fc00000c01000000002000301")
        let decoded = try XCTUnwrap(MotionCodec.decode(bytes, group: group, source: source, target: target))
        XCTAssertEqual(decoded.type, "scroll"); XCTAssertEqual(decoded.pointer, packet.pointer)
        XCTAssertEqual(decoded.deltaX, 1.5); XCTAssertEqual(decoded.deltaY, -2.25)
        XCTAssertEqual(decoded.scrollPhase, 2); XCTAssertEqual(decoded.momentumPhase, 3); XCTAssertEqual(decoded.preciseScroll, true)
        var invalid = bytes; invalid[invalid.count-1] = 2
        XCTAssertNil(MotionCodec.decode(invalid, group: group, source: source, target: target))
        XCTAssertNil(MotionCodec.decode(Data(bytes.dropLast()), group: group, source: source, target: target))
        packet.deltaY = 10001
        XCTAssertNil(MotionCodec.encode(packet, layout: group.layout, compactScroll: true))
    }
    func testSharedWireVectorAndAuthenticatedSessionEnvelope() throws {
        let source = "66666666-7777-8888-9999-aaaaaaaaaaaa", target = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff", id = "11111111-2222-3333-4444-555555555555"
        let screen = ScreenGeometry(id: "screen-一", peerID: target, name: "Screen", number: 1, pixelWidth: 1000, pixelHeight: 1000, primary: true, x: 0, y: 0)
        let group = SharedGroup(id: id, name: "Fixture", leaderID: source, revision: 1, members: [], layout: [screen], configs: [], currentConfigID: "")
        var packet = InputPacket(type: "move", groupID: id, sourcePeerID: source, targetPeerID: target); packet.sequence = 123
        packet.pointer = PointerState(screenID: screen.id, x: 40.5, y: 20.25, ownerPeerID: source, epoch: 9)
        let bytes = try XCTUnwrap(MotionCodec.encode(packet, layout: group.layout))
        XCTAssertEqual(bytes.map { String(format: "%02x", $0) }.joined(), "534d493111111111222233334444555555555555000000000000007b0000000000000009000a73637265656e2de4b8804222000041a20000")
        XCTAssertEqual(MotionCodec.decode(bytes, group: group, source: source, target: target)?.pointer, packet.pointer)
        var frame = SessionMessage(type: "data", sourcePeerID: source); frame.targetPeerID = target; frame.sessionID = id; frame.sequence = 44; frame.channel = "input"; frame.payload = bytes
        let compact = try SessionFrameCodec.encode(frame); XCTAssertEqual(compact.count, bytes.count + 28)
        let decoded = try SessionFrameCodec.decode(compact); XCTAssertEqual(decoded.sessionID, id); XCTAssertEqual(decoded.sequence, 44); XCTAssertEqual(decoded.payload, bytes)
        for type in ["control", "pointer"] {
            var boundary = packet; boundary.type = type
            XCTAssertNil(MotionCodec.encode(boundary, layout: group.layout))
            let encoded = try XCTUnwrap(MotionCodec.encode(boundary, layout: group.layout, extended: true))
            XCTAssertEqual(encoded.dropFirst(4), bytes.dropFirst(4))
            let restored = try XCTUnwrap(MotionCodec.decode(encoded, group: group, source: source, target: target))
            XCTAssertEqual(restored.type, type); XCTAssertEqual(restored.pointer, packet.pointer)
            frame.payload = encoded
            XCTAssertEqual(try SessionFrameCodec.decode(SessionFrameCodec.encode(frame)).payload, encoded)
        }
        var invalid = bytes; invalid[38 + "screen-一".utf8.count] = 0x7f; invalid[39 + "screen-一".utf8.count] = 0xc0
        XCTAssertNil(MotionCodec.decode(invalid, group: group, source: source, target: target))
    }
}
