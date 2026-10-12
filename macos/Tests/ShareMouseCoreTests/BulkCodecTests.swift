import Foundation
import XCTest
@testable import ShareMouseCore

final class BulkCodecTests:XCTestCase {
    func testRawFileFrameAndCrossPlatformVector() throws {
        let id="11111111-2222-3333-4444-555555555555"
        var packet=FilePacket("chunk-data",groupID:id,entryID:id,taskID:id);packet.requestID=id;packet.itemID=id;packet.offset=123;packet.index=0;packet.final=true;packet.data=Data(repeating:255,count:32000);packet.checksum=ChunkCheck.adler32(packet.data!)
        let raw=try FilePacketCodec.encode(packet,compact:true),back=try FilePacketCodec.decode(raw,compact:true)
        XCTAssertEqual(raw.count,32096);XCTAssertEqual(back.data,packet.data);XCTAssertEqual(back.checksum,packet.checksum);XCTAssertEqual(back.offset,123)
        XCTAssertThrowsError(try FilePacketCodec.decode(raw,compact:false));XCTAssertThrowsError(try FilePacketCodec.decode(raw.prefix(90),compact:true))
        var frame=SessionMessage(type:"data",sourcePeerID:id);frame.sequence=44;frame.channel="files";frame.mode="compact-data-v1";frame.deliveryID=id;frame.payload=Data([0,255,128])
        let bytes=try SessionFrameCodec.encode(frame);XCTAssertEqual(bytes.map{String(format:"%02x",$0)}.joined(),"534c4431000000000000002c050166696c65731111111122223333444455555555555500ff80")
        let decoded=try SessionFrameCodec.decode(bytes);XCTAssertEqual(decoded.payload,frame.payload);XCTAssertEqual(decoded.deliveryID,id)
        let legacy=try FilePacketCodec.encode(packet,compact:false);frame.mode=nil;frame.payload=legacy;frame.deliveryID=nil
        let old=try SessionFrameCodec.encode(frame);XCTAssertGreaterThan(old.count,raw.count*17/10)
        print("File wire bytes: old double Base64=\(old.count), binary data=\(raw.count)")
    }
    func testFragmentBoundsAndOrdering() throws {
        let payload=Data((0..<32000).map{UInt8($0%251)}),parts=BulkFrameCodec.fragments(channel:"files",payload:Data((0..<32000).map{UInt8($0%251)}),size:160)
        var state:[Data:BulkFrameCodec.Assembly]=[:]
        XCTAssertThrowsError(try BulkFrameCodec.consume(parts[1],assemblies:&state))
        XCTAssertNil(try BulkFrameCodec.consume(parts[0],assemblies:&state))
        XCTAssertThrowsError(try BulkFrameCodec.consume(parts[0],assemblies:&state))
        var result:(String,Data)?
        for part in parts.dropFirst(){result=try BulkFrameCodec.consume(part,assemblies:&state)}
        XCTAssertEqual(result?.0,"files");XCTAssertEqual(result?.1,payload);XCTAssertTrue(state.isEmpty)
        var invalid=parts[0];invalid[24]=1;XCTAssertThrowsError(try BulkFrameCodec.consume(invalid,assemblies:&state))
    }
}
