import Foundation

// Admission happens before TLS: one bounded fragment is acknowledged before
// another is admitted. Ciphertext and input event ordering are never changed.
enum BulkFrameCodec {
    static let channels:Set<String>=["files","history","clipboard","computer"]
    static func fragments(channel:String,payload:Data,size:Int)->[Data] {
        var id=UUID().uuid
        let name=Data(channel.utf8),count=max(1,(payload.count+size-1)/size)
        let header=Data("SBK1".utf8)+withUnsafeBytes(of:&id){Data($0)}
        return (0..<count).map {index in
            header+MotionCodec.integer(UInt64(index),count:2)+MotionCodec.integer(UInt64(count),count:2)+MotionCodec.integer(UInt64(payload.count),count:4)+Data([UInt8(name.count)])+name+payload.subdata(in:min(index*size,payload.count)..<min((index+1)*size,payload.count))
        }
    }
    struct Assembly {var channel:String;var total:Int;var count:Int;var next:Int;var bytes:Data}
    // Scope this dictionary to one authenticated transport's receive loop.
    static func consume(_ bytes:Data,assemblies:inout [Data:Assembly]) throws -> (String,Data)? {
        guard bytes.count>=30,bytes.prefix(4)==Data("SBK1".utf8) else{throw PairingError.invalidMessage}
        let key=bytes.subdata(in:4..<20),index=Int(MotionCodec.number(bytes,20,2)),count=Int(MotionCodec.number(bytes,22,2)),total=Int(MotionCodec.number(bytes,24,4)),nameEnd=29+Int(bytes[28])
        guard count>0,count<=256,total<=32768,index<count,nameEnd<=bytes.count,let channel=String(data:bytes.subdata(in:29..<nameEnd),encoding:.utf8),channels.contains(channel),bytes.count-nameEnd<=384 else{throw PairingError.invalidMessage}
        if index==0 {guard assemblies[key]==nil,assemblies.count<8 else{throw PairingError.invalidMessage};assemblies[key]=Assembly(channel:channel,total:total,count:count,next:0,bytes:Data())}
        guard var state=assemblies[key],state.channel==channel,state.total==total,state.count==count,state.next==index else{throw PairingError.invalidMessage}
        state.bytes.append(bytes.subdata(in:nameEnd..<bytes.count));state.next+=1
        guard state.bytes.count<=total else{throw PairingError.invalidMessage}
        if state.next==count {assemblies.removeValue(forKey:key);guard state.bytes.count==total else{throw PairingError.invalidMessage};return (channel,state.bytes)}
        assemblies[key]=state;return nil
    }
}

enum FilePacketCodec {
    static func encode(_ packet:FilePacket,compact:Bool) throws -> Data {
        guard compact,packet.type=="chunk-data",packet.index==0,packet.final==true,let data=packet.data,data.count<=32000,let offset=packet.offset,offset>=0,let checksum=packet.checksum else{let encoder=JSONEncoder();encoder.outputFormatting=[.withoutEscapingSlashes];return try encoder.encode(packet)}
        var bytes=Data("SFC1".utf8)
        for value in [packet.groupID,packet.entryID,packet.taskID,packet.requestID ?? "",packet.itemID ?? ""] {guard var id=UUID(uuidString:value)?.uuid else{throw PairingError.invalidMessage};bytes.append(withUnsafeBytes(of:&id){Data($0)})}
        bytes.append(MotionCodec.integer(UInt64(offset)));bytes.append(MotionCodec.integer(UInt64(checksum),count:4));bytes.append(data);return bytes
    }
    static func decode(_ bytes:Data,compact:Bool) throws -> FilePacket {
        guard bytes.prefix(4)==Data("SFC1".utf8) else{return try JSONDecoder().decode(FilePacket.self,from:bytes)}
        guard compact,bytes.count>=96,bytes.count<=32096,MotionCodec.number(bytes,84,8)<=UInt64(Int64.max) else{throw PairingError.invalidMessage}
        let ids=(0..<5).map {i in let b=Array(bytes[(4+i*16)..<(20+i*16)]);return UUID(uuid:(b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15])).uuidString.lowercased()}
        var packet=FilePacket("chunk-data",groupID:ids[0],entryID:ids[1],taskID:ids[2]);packet.requestID=ids[3];packet.itemID=ids[4];packet.index=0;packet.final=true;packet.offset=Int64(MotionCodec.number(bytes,84,8));packet.checksum=UInt32(MotionCodec.number(bytes,92,4));packet.data=bytes.subdata(in:96..<bytes.count);return packet
    }
}
