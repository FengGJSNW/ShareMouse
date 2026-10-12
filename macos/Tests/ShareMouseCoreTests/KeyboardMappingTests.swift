import XCTest
@testable import ShareMouseCore
final class KeyboardMappingTests: XCTestCase {
    func testDirectionAndCustomCommand() {
        XCTAssertEqual(KeyboardMapping.map("ControlLeft", from: "windows", to: "macos", config: nil), "MetaLeft")
        let custom = KeyboardConfig(id: UUID().uuidString, ownerPeerID: UUID().uuidString, name: "Custom", windowsToMac: ["ControlLeft":"AltLeft"], macToWindows: [:])
        XCTAssertEqual(KeyboardMapping.map("ControlLeft", from: "windows", to: "macos", config: custom), "AltLeft")
        XCTAssertEqual(KeyboardMapping.map("ControlLeft", from: "windows", to: "windows", config: custom), "ControlLeft")
        XCTAssertEqual(KeyboardMapping.command("KeyC", held: ["ControlLeft", "KeyC"], from: "windows", to: "macos", config: nil), "copy")
        XCTAssertEqual(KeyboardMapping.command("KeyZ", held: ["ControlLeft", "ShiftRight", "KeyZ"], from: "windows", to: "macos", config: nil), "redo")
        XCTAssertEqual(KeyboardMapping.command("KeyZ", held: ["MetaLeft", "KeyZ"], from: "macos", to: "windows", config: nil), "undo")
        XCTAssertNil(KeyboardMapping.command("KeyZ", held: ["ControlLeft", "KeyZ"], from: "windows", to: "macos", config: custom))
        XCTAssertNil(KeyboardMapping.command("KeyC", held: ["ControlLeft", "KeyC"], from: "windows", to: "macos", config: custom))
    }
}
extension KeyboardMappingTests {
    func testFullKeyMappingNoActionAndDirections() throws {
        let owner=UUID().uuidString,id=UUID().uuidString
        var config=KeyboardConfig(id:id,ownerPeerID:owner,name:"双向",windowsToMac:["KeyA":"KeyB","ControlLeft":"ControlRight","MetaRight":"NoAction","F12":"F1"],macToWindows:["KeyA":"KeyC","ShiftLeft":"ShiftRight"])
        XCTAssertTrue(KeyboardMapping.valid([config],members:[],selected:id))
        XCTAssertEqual(KeyboardMapping.map("KeyA",from:"windows",to:"macos",config:config),"KeyB")
        XCTAssertEqual(KeyboardMapping.map("KeyA",from:"macos",to:"windows",config:config),"KeyC")
        XCTAssertEqual(KeyboardMapping.map("ControlLeft",from:"windows",to:"macos",config:config),"ControlRight")
        XCTAssertEqual(KeyboardMapping.map("MetaRight",from:"windows",to:"macos",config:config),"NoAction")
        XCTAssertEqual(KeyboardMapping.map("F12",from:"windows",to:"macos",config:config),"F1")
        config.macToWindows["ControlLeft"]="NoAction"
        XCTAssertNil(KeyboardMapping.command("ArrowUp",held:["ControlLeft","ArrowUp"],from:"macos",to:"windows",config:config))
        config.windowsToMac["KeyC"]="KeyB"
        XCTAssertNil(KeyboardMapping.command("KeyC",held:["ControlRight","KeyC"],from:"windows",to:"macos",config:config))
        config.windowsToMac.removeValue(forKey:"ControlLeft")
        XCTAssertEqual(KeyboardMapping.map("ControlLeft",from:"windows",to:"macos",config:config),"MetaLeft")
        let restored=try JSONDecoder().decode(KeyboardConfig.self,from:JSONEncoder().encode(config))
        XCTAssertEqual(restored.id,id);XCTAssertEqual(restored.macToWindows,config.macToWindows)
        config.macToWindows["Fn"]="KeyA"
        XCTAssertFalse(KeyboardMapping.valid([config],members:[owner],selected:id))
    }
    func testAdaptiveRouteDoesNotOscillateDuringContinuousInput() {
        var policy=InputRoutePolicy()
        XCTAssertEqual(policy.choose(["tcp","ble"],bluetoothPreferred:true,now:0),"ble")
        for t in [5.0,10,15] {policy.observe("ble",milliseconds:90,now:t);policy.observe("tcp",milliseconds:10,now:t)}
        for i in 1...150 {XCTAssertEqual(policy.choose(["tcp","ble"],bluetoothPreferred:true,now:Double(i)/10),"ble")}
        XCTAssertEqual(policy.choose(["tcp","ble"],bluetoothPreferred:true,now:16),"tcp")
        XCTAssertEqual(policy.choose(["ble"],bluetoothPreferred:true,now:16.01),"ble")
    }
    func testNetworkInputKeepsQuicAndUsesTcpOnlyWhenQuicUnavailable() {
        var policy=InputRoutePolicy()
        for i in 0..<4 {policy.observe("quic",milliseconds:30,now:Double(i));policy.observe("tcp",milliseconds:1,now:Double(i))}
        XCTAssertEqual(policy.choose(["quic","tcp"],bluetoothPreferred:false,now:0),"quic")
        XCTAssertEqual(policy.choose(["quic","tcp"],bluetoothPreferred:false,now:12),"quic")
        XCTAssertEqual(policy.choose(["tcp"],bluetoothPreferred:false,now:13),"tcp")
    }

}
