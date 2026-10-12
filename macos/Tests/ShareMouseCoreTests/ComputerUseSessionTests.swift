import Foundation
import Security
import XCTest
@testable import ShareMouseCore

final class ComputerUseSessionTests: XCTestCase {
    @MainActor
    func testSlowReasoningLeaseValidationAndExplicitExit() async throws {
        let id = UUID().uuidString.lowercased()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShareMouse-ComputerUse-" + id)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {
            try? FileManager.default.removeItem(at:directory)
            SecItemDelete([kSecClass as String:kSecClassCertificate,kSecAttrLabel as String:"ShareMouse identity " + id] as CFDictionary)
            SecItemDelete([kSecClass as String:kSecClassKey,kSecAttrApplicationTag as String:Data(("com.sharemouse.identity." + id).utf8)] as CFDictionary)
        }
        let identity = try IdentityKeychain(peerID:id), registry = try PeerRegistry(directory:directory)
        let manager = SessionManager(localID:id,name:"LeaseTest",identity:identity,registry:registry,pairCode:"123456",password:"",confirmCertificate:{ _ in true },confirmConnection:{ _ in true },changed:{ _ in },event:{ _ in })
        let clipboard = ClipboardService(id:id,manager:manager,changed:{ _ in },event:{ _ in })
        let screen = ScreenGeometry(id:id + ":test",peerID:id,name:"Fixture",number:1,pixelWidth:1000,pixelHeight:720,primary:true,x:0,y:0)
        var clock = Date(), injected = 0, restored = false, activity = 0
        var changes: [String] = [], logs: [String] = []
        let service = ComputerUseService(id:id,name:"LeaseTest",manager:manager,files:nil,clipboard:clipboard,
            screens:{ [screen] },info:{ .object([:]) },screenshot:{ _ in .object(["width":.number(1000),"height":.number(720)]) },
            inject:{ _,_,_,_ in injected += 1 },suspend:{ true },restore:{ restored = $0 },canControl:{ true },
            now:{ clock },diagnostic:{ logs.append($0) },controlChanged:{ changes.append($0 ? "opened" : $1) },activity:{ activity += 1 })
        defer { service.stop() }
        service.allowComputer = true
        let opened = try await service.tool("open_computer",arguments:.object(["peer_id":.string("local")]))
        XCTAssertEqual(opened["control_session_idle_timeout_ms"],.number(600000))
        XCTAssertNotNil(opened["control_session_expires_at"].string)
        var args: JSONValue = .object(["peer_id":.string("local"),"control_session_id":opened["control_session_id"],"observation_id":opened["observation_id"]])
        args["actions"] = .array([.object(["type":.string("move"),"x":.number(10),"y":.number(10)]),.object(["type":.string("wait"),"milliseconds":.number(30000)]),.object(["type":.string("wait"),"milliseconds":.number(30000)])])
        do { _ = try await service.tool("computer_action",arguments:args); XCTFail("Over-budget batch must reject before moving") }
        catch { XCTAssertEqual(error.localizedDescription,"batch_wait_exceeds_30000_ms"); XCTAssertEqual(injected,0) }
        for event in [CapturedInput("move",deltaX:50,deltaY:50),CapturedInput("buttonDown",button:0),CapturedInput("buttonUp",button:0),CapturedInput("scroll",deltaY:40),CapturedInput("keyDown",key:"Escape"),CapturedInput("keyUp",key:"Escape")] {
            XCTAssertTrue(service.physicalInput(event),"Local input must bypass sharing handlers")
            XCTAssertTrue(service.controlling,"Accidental local input must not end MCP")
        }
        clock += 134
        args["actions"] = .array([.object(["type":.string("move"),"x":.number(10),"y":.number(10)])])
        let done = try await service.tool("computer_action",arguments:args)
        XCTAssertEqual(done["execution_status"],.string("injected")); XCTAssertEqual(injected,1)
        clock += 601
        do { _ = try await service.tool("observe_computer",arguments:args); XCTFail("Idle expiry must release the session") }
        catch { XCTAssertEqual(error.localizedDescription,"control_session_unavailable:lease_expired") }
        XCTAssertTrue(restored); XCTAssertFalse(service.controlling)
        let reopened = try await service.tool("open_computer",arguments:.object(["peer_id":.string("local")]))
        args["control_session_id"] = reopened["control_session_id"]; args["observation_id"] = reopened["observation_id"]
        args["actions"] = .array([.object(["type":.string("wait"),"milliseconds":.number(15000)])])
        Task { try? await Task.sleep(for:.milliseconds(100)); service.endControl(reason:"user_exit") }
        let interrupted = try await service.tool("computer_action",arguments:args)
        XCTAssertEqual(interrupted["error"],.string("control_session_unavailable:user_exit"))
        XCTAssertEqual(interrupted["executed_actions"],.number(0)); XCTAssertFalse(service.controlling)
        XCTAssertEqual(changes,["opened","lease_expired","opened","user_exit"])
        XCTAssertTrue(logs.contains { $0.contains("reason=lease_expired") }); XCTAssertGreaterThan(activity,0)
        await manager.stop()
    }
}
