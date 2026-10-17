import Foundation
import Network
import Security
import XCTest

@testable import ShareMouseCore

final class SharingTests: XCTestCase {
    @MainActor func testWindowsFunctionSlotsSurviveCrossingAndReleaseBindings() async throws {
        // Keep the mapping fixture's source first in peer priority; ownership arbitration has separate tests.
        let
            a = try SharingFixture(
                name: "WindowsFunctionSource", id: "0000" + UUID().uuidString.lowercased().dropFirst(4)),
            b = try SharingFixture(name: "MacFunctionTarget", id: "ffff" + UUID().uuidString.lowercased().dropFirst(4))
        var sender: InputService?, receiver: InputService?
        var stage = "connect"
        do {
            try await connect(a, b, directLAN: false)
            try await waitFor { await self.sameDesktop(a, b) }
            let state = await a.group.active, group = try XCTUnwrap(state)
            var events: [CapturedInput] = []
            let source = InputService(
                id: a.id, platform: "windows", manager: a.manager, inject: { _, _, _, _ in }, restrict: { _, _ in },
                status: { _ in }, event: { print("Windows source input: \($0)") })
            let target = InputService(
                id: b.id, platform: "macos", manager: b.manager, inject: { e, _, _, _ in events.append(e) },
                restrict: { _, _ in }, status: { _ in }, event: { print("Mac target input: \($0)") })
            sender = source;
            receiver = target
            await source.start();
            await target.start()
            source.update(group, online: [a.id, b.id], sessions: await a.manager.currentSessions())
            target.update(group, online: [a.id, b.id], sessions: await b.manager.currentSessions())
            try await source.enable();
            try await target.enable()
            stage = "capabilities"
            try await waitFor {
                let x = await a.manager.currentSessions(), y = await b.manager.currentSessions()
                source.update(group, online: [a.id, b.id], sessions: x);
                target.update(group, online: [a.id, b.id], sessions: y)
                // Codec support is advertised while paused; wait for both input-ready snapshots.
                return x.first?.capabilities.contains("input-function-slots-v1") == true
                    && x.first?.capabilities.contains("input") == true
                    && y.first?.capabilities.contains("input") == true
            }
            let local = try XCTUnwrap(group.layout.first { $0.peerID == a.id }),
                remote = try XCTUnwrap(group.layout.first { $0.peerID == b.id })
            // Wait for simultaneous enable to converge, then give this fixture's source a newer epoch.
            stage = "convergence"
            try await waitFor { source.pointer != nil && source.pointer == target.pointer }
            stage = "source-ownership"
            try await source.enable()
            try await waitFor {
                source.pointer?.ownerPeerID == a.id && target.pointer?.ownerPeerID == a.id
                    && target.pointer?.screenID == local.id
            }
            stage = "held-crossing"
            XCTAssertFalse(source.capture(CapturedInput("keyDown", key: "Fn")))
            XCTAssertFalse(source.capture(CapturedInput("keyDown", key: "VolumeMute", functionSlot: "F1")))
            let right = remote.x > local.x
            _ = source.capture(
                CapturedInput("move", deltaX: right ? 8 : -8, screenID: local.id, x: right ? 1 : 0, y: 0.5))
            try await waitFor { events.contains { $0.type == "keyDown" && $0.key == "BrightnessDown" } }
            XCTAssertFalse(events.contains { $0.key == "VolumeMute" }, "Held repair lost the physical F1 slot")
            _ = source.capture(CapturedInput("keyUp", key: "Fn"))
            _ = source.capture(CapturedInput("keyUp", key: "VolumeMute", functionSlot: "F1"))
            try await waitFor { events.contains { $0.type == "keyUp" && $0.key == "BrightnessDown" } }
            stage = "all-slots"
            for number in 1...12 {
                events = []
                let slot = "F\(number)", semantic = KeyboardMapping.windowsFunctions[slot]!,
                    expected = KeyboardMapping.macFunction(slot)!
                _ = source.capture(CapturedInput("keyDown", key: semantic, functionSlot: slot))
                _ = source.capture(CapturedInput("keyUp", key: semantic, functionSlot: slot))
                try await waitFor { events.contains { $0.type == "keyUp" && $0.key == expected } }
                XCTAssertEqual(events.filter { $0.type == "keyDown" }.map(\.key), [expected])
                XCTAssertEqual(events.filter { $0.type == "keyUp" }.map(\.key), [expected])
            }
            source.stop();
            target.stop();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            print(
                "Mapping fixture failed at \(stage): source=\(String(describing: sender?.pointer)) target=\(String(describing: receiver?.pointer))"
            )
            sender?.stop();
            receiver?.stop();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testRemoteScrollInversionIsPerTargetAndAppliedOnce() async throws {
        for platform in ["macos", "windows"] {
            let a = try SharingFixture(name: "ScrollSource"), b = try SharingFixture(name: "ScrollTarget")
            var sender: InputService?, receiver: InputService?
            do {
                try await connect(a, b, directLAN: false)
                try await waitFor { await self.sameDesktop(a, b) }
                let state = await a.group.active, group = try XCTUnwrap(state)
                var received: [CapturedInput] = [], queried: [String] = []
                var horizontal = false, vertical = false, angle = 0.0
                let source = InputService(
                    id: a.id, platform: platform, manager: a.manager, inject: { _, _, _, _ in }, restrict: { _, _ in },
                    status: { _ in })
                let target = InputService(
                    id: b.id, platform: platform == "macos" ? "windows" : "macos", manager: b.manager,
                    inject: { event, _, _, _ in if event.type == "scroll" { received.append(event) } },
                    restrict: { _, _ in }, status: { _ in })
                sender = source;
                receiver = target
                source.scrollInversion = { peer in
                    queried.append(peer);
                    return peer == b.id ? (horizontal, vertical) : (true, true)
                }
                source.horizontalScrollAngle = { _ in angle }
                target.horizontalScrollAngle = { _ in 90 }
                // Receiving must not apply the target's outgoing preference.
                target.scrollInversion = { _ in (true, true) }
                source.pointerSensitivity = { _ in 2 }  // Sensitivity must not scale scroll deltas.
                await source.start();
                await target.start()
                source.update(group, online: [a.id, b.id], sessions: await a.manager.currentSessions())
                target.update(group, online: [a.id, b.id], sessions: await b.manager.currentSessions())
                try await source.enable();
                try await target.enable()
                try await waitFor {
                    let x = await a.manager.currentSessions(), y = await b.manager.currentSessions()
                    source.update(group, online: [a.id, b.id], sessions: x);
                    target.update(group, online: [a.id, b.id], sessions: y)
                    return x.first?.capabilities.contains("input") == true
                        && y.first?.capabilities.contains("input") == true
                }
                XCTAssertFalse(source.capture(CapturedInput("scroll", deltaX: 2.5, deltaY: -7.25)))
                XCTAssertTrue(queried.isEmpty, "Local scroll must stay native without consulting remote settings")
                let local = try XCTUnwrap(group.layout.first { $0.peerID == a.id }),
                    remote = try XCTUnwrap(group.layout.first { $0.peerID == b.id })
                let right = remote.x > local.x
                XCTAssertTrue(
                    source.capture(
                        CapturedInput("move", deltaX: right ? 8 : -8, screenID: local.id, x: right ? 1 : 0, y: 0.5)))
                XCTAssertEqual(source.remoteScreenID, remote.id)
                for (h, v) in [(false, false), (true, false), (false, true), (true, true)] {
                    horizontal = h;
                    vertical = v
                    let count = received.count
                    XCTAssertTrue(
                        source.capture(
                            CapturedInput(
                                "scroll", deltaX: 2.5, deltaY: -7.25, scrollPhase: 1, momentumPhase: 0,
                                preciseScroll: true)))
                    try await waitFor { received.count == count + 1 }
                    let event = try XCTUnwrap(received.last)
                    XCTAssertEqual(event.deltaX, h ? -2.5 : 2.5);
                    XCTAssertEqual(event.deltaY, v ? 7.25 : -7.25)
                    XCTAssertEqual(event.scrollPhase, 1);
                    XCTAssertEqual(event.momentumPhase, 0);
                    XCTAssertEqual(event.preciseScroll, true)
                }
                let count = received.count
                XCTAssertTrue(
                    source.capture(
                        CapturedInput(
                            "scroll", deltaX: -1.5, deltaY: 3.5, scrollPhase: 0, momentumPhase: 1, preciseScroll: true))
                )
                try await waitFor { received.count == count + 1 }
                XCTAssertEqual(received.last?.deltaX, 1.5);
                XCTAssertEqual(received.last?.deltaY, -3.5)
                XCTAssertEqual(received.last?.momentumPhase, 1)
                XCTAssertTrue(
                    source.capture(CapturedInput("scroll", scrollPhase: 8, momentumPhase: 4, preciseScroll: true)))
                try await waitFor { received.count == count + 2 }
                XCTAssertEqual(received.last?.scrollPhase, 8);
                XCTAssertEqual(received.last?.momentumPhase, 4)
                angle = 45;
                horizontal = true;
                vertical = false
                for (dx, phase, expected) in [(3.0, 1, 0.0), (10.0, 2, 0.0), (12.0, 2, -2.0), (14.0, 2, -4.0)] {
                    let count = received.count
                    XCTAssertTrue(
                        source.capture(
                            CapturedInput(
                                "scroll", deltaX: dx, deltaY: -10, scrollPhase: phase, momentumPhase: 0,
                                preciseScroll: true)))
                    try await waitFor { received.count == count + 1 }
                    XCTAssertEqual(
                        received.last?.deltaX ?? .nan, expected, accuracy: 0.01,
                        "Angle boundary maps to zero before inversion, without a large jump")
                    XCTAssertEqual(received.last?.deltaY, -10, "Horizontal angle must not alter vertical scroll")
                }
                XCTAssertEqual(
                    Set(queried), [b.id], "Use the actual target peer, not the source or another saved device")
                source.stop();
                target.stop();
                await a.manager.stop();
                await b.manager.stop()
            } catch {
                sender?.stop();
                receiver?.stop();
                await a.manager.stop();
                await b.manager.stop();
                throw error
            }
        }
    }
    @MainActor func testDelayedInputAcknowledgementKeepsLiveSessionButRecoversOnLinkLoss() async throws {
        let a = try SharingFixture(name: "SlowInputA"), b = try SharingFixture(name: "SlowInputB")
        var service: InputService?
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            await b.manager.setCapabilities(["input": true, "compact-input": true])
            let state = await a.group.active;
            let group = try XCTUnwrap(state), packets = SharingInputPackets()
            await b.manager.receive(channel: "input") { peer, bytes in
                await packets.add(bytes, group: group, source: peer, target: b.id)
            }
            var events: [String] = []
            let input = InputService(
                id: a.id, platform: "macos", manager: a.manager, inject: { _, _, _, _ in }, restrict: { _, _ in },
                status: { _ in }, event: { events.append($0) })
            service = input;
            await input.start();
            input.update(group, online: [a.id, b.id], sessions: await a.manager.currentSessions());
            try await input.enable()
            try await waitFor {
                let sessions = await a.manager.currentSessions();
                input.update(group, online: [a.id, b.id], sessions: sessions);
                return sessions.first?.capabilities.contains("compact-input") == true
            }
            let local = try XCTUnwrap(group.layout.first { $0.peerID == a.id })
            _ = input.capture(CapturedInput("move", deltaX: 8, screenID: local.id, x: 1, y: 0.5))
            for _ in 0..<60 {
                _ = input.capture(CapturedInput("move", deltaX: 1));
                try await Task.sleep(for: .milliseconds(2))
            }
            try await waitFor { await packets.packets.filter { $0.type == "move" }.count == 8 }
            let remoteScreen = try XCTUnwrap(input.remoteScreenID)
            var ack = InputPacket(type: "motionAck", groupID: group.id, sourcePeerID: b.id, targetPeerID: a.id)
            ack.acknowledgedSequence = 0
            try await b.manager.send(
                peerID: a.id, channel: "input", payload: XCTUnwrap(MotionCodec.encode(ack, layout: group.layout)))
            // The old 1s delivery / 3s source watchdogs both expired while a native window was blocked.
            try await Task.sleep(for: .milliseconds(3500))
            XCTAssertTrue(input.enabled);
            XCTAssertEqual(input.remoteScreenID, remoteScreen)
            let stalledPackets = await packets.packets
            XCTAssertEqual(
                stalledPackets.filter { $0.type == "move" }.count, 8, "A live session must not bypass delivery credit")
            XCTAssertTrue(events.contains { $0.contains("InputDeliveryWaiting") })
            XCTAssertFalse(events.contains { $0.contains("InputRecovered") })
            ack.acknowledgedSequence = stalledPackets.filter { $0.type == "move" }.last?.sequence
            try await b.manager.send(
                peerID: a.id, channel: "input", payload: XCTUnwrap(MotionCodec.encode(ack, layout: group.layout)))
            try await waitFor { events.contains { $0.contains("InputDeliveryResumed") } }
            _ = input.capture(CapturedInput("move", deltaX: 1))
            try await waitFor { await packets.packets.filter { $0.type == "move" }.count > 8 }
            await b.manager.disconnect(a.id)
            try await waitFor { await !a.manager.inputSessionAlive(b.id) }
            try await waitFor { input.pointer?.screenID == local.id }
            input.stop();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            service?.stop();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }

    @MainActor func testActualInputAckTailControlsFileWindow() async throws {
        let a = try SharingFixture(name: "TailA"), b = try SharingFixture(name: "TailB"), acks = SharingPackets()
        do {
            try await connect(a, b)
            await b.manager.receiveWithTransport(channel: "input") { peer, bytes, link in
                try? await Task.sleep(for: .milliseconds(80))
                try? await b.manager.sendOnTransport(peerID: peer, channel: "input", payload: bytes, transport: link)
            }
            await a.manager.receiveWithTransport(channel: "input") { peer, bytes, link in
                if let seq = bytes.first {
                    await a.manager.inputAcknowledged(peer, sequence: UInt64(seq), transport: link)
                }
                await acks.add(bytes)
            }
            for seq in 1...8 {
                try await a.manager.sendInput(
                    peerID: b.id, payload: Data([UInt8(seq)]), acknowledgedSequence: UInt64(seq))
                try await waitFor { await acks.count == seq }
            }
            let window = await a.manager.fileTransferWindow(b.id);
            XCTAssertLessThanOrEqual(window.count, 2)
            try await waitFor { await b.manager.fileTransferWindow(a.id).count <= 2 }
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testFileWindowFeedbackAcrossEncryptedSession() async throws {
        let a = try SharingFixture(name: "WindowA"), b = try SharingFixture(name: "WindowB")
        do {
            try await connect(a, b)
            let negotiated = await a.manager.hasCapability(b.id, "adaptive-file-window-v1");
            XCTAssertTrue(negotiated)
            await a.manager.yieldBulkForInput(b.id)
            let local = await a.manager.fileTransferWindow(b.id);
            XCTAssertEqual(local.count, 4)
            try await waitFor { await b.manager.fileTransferWindow(a.id).count == 4 }
            try await Task.sleep(for: .milliseconds(600));
            await a.manager.yieldBulkForInput(b.id)
            try await waitFor { await b.manager.fileTransferWindow(a.id).count == 2 }
            await b.manager.setCapability("adaptive-file-window-v1", enabled: false)
            try await waitFor { await !a.manager.hasCapability(b.id, "adaptive-file-window-v1") }
            try await a.manager.send(peerID: b.id, channel: "input", payload: Data([0]))
            let legacy = await a.manager.fileTransferWindow(b.id);
            XCTAssertEqual(legacy.count, 2)
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testInputAcknowledgementUsesIngressBLEDespiteNetworkPreference() async throws {
        let a = try SharingFixture(name: "AckA", bluetoothInputOnly: true),
            b = try SharingFixture(name: "AckB", bluetoothInputOnly: false)
        var service: InputService?
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            try await b.manager.startBluetoothListener(port: b.port + 1)
            _ = try await a.manager.connect(
                endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: b.port + 1)!), pairCode: nil,
                password: nil, kind: "ble")
            await a.manager.setCapabilities(["input": true, "compact-input": true, "compact-input-v3": true])
            let state = await a.group.active;
            let group = try XCTUnwrap(state)
            let input = InputService(
                id: b.id, platform: "macos", manager: b.manager, inject: { _, _, _, _ in }, restrict: { _, _ in },
                status: { _ in });
            service = input;
            await input.start()
            input.update(group, online: [a.id, b.id], sessions: await b.manager.currentSessions());
            try await input.enable()
            try await waitFor {
                let s = await b.manager.currentSessions();
                input.update(group, online: [a.id, b.id], sessions: s);
                return s.first?.capabilities.contains("compact-input-v3") == true
            }
            let received = SharingPackets()
            await a.manager.receiveWithTransport(channel: "input") { peer, bytes, link in
                if let packet = MotionCodec.decode(bytes, group: group, source: peer, target: a.id),
                    packet.type == "motionAck", (packet.acknowledgedSequence ?? 0) >= 102
                {
                    await received.add(Data(link.kind.utf8))
                }
            }
            let screen = try XCTUnwrap(group.layout.first { $0.peerID == b.id }),
                point = PointerState(
                    screenID: screen.id, x: screen.x + 50, y: screen.y + 50, ownerPeerID: a.id, epoch: 100)
            var control = InputPacket(type: "control", groupID: group.id, sourcePeerID: a.id, targetPeerID: b.id);
            control.sequence = 101;
            control.pointer = point
            try await a.manager.send(peerID: b.id, channel: "input", payload: JSONEncoder().encode(control))
            var move = control;
            move.type = "move";
            move.sequence = 102
            try await a.manager.send(
                peerID: b.id, channel: "input",
                payload: MotionCodec.encode(move, layout: group.layout, compactContext: true)!)
            try await waitFor { await received.count > 0 };
            let values = await received.values;
            XCTAssertTrue(values.allSatisfy { $0 == Data("ble".utf8) })
            service?.stop();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            service?.stop();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testBulkFragmentsYieldToContinuousInputAndReassembleExactly() async throws {
        let a = try SharingFixture(name: "BulkA"), b = try SharingFixture(name: "BulkB")
        do {
            try await b.manager.startBluetoothListener(port: b.port)
            _ = try await a.manager.connect(
                endpoint: endpoint(b), pairCode: "123456", password: "fixture-secret", kind: "ble")
            let files = SharingPackets(), input = SharingPackets(), data = Data((0..<32000).map { UInt8($0 % 251) })
            await b.manager.receive(channel: "files") { _, bytes in await files.add(bytes) }
            await b.manager.receive(channel: "input") { _, bytes in await input.add(bytes) }
            try await a.manager.send(peerID: b.id, channel: "input", payload: Data([0]))
            let work = Task { try await a.manager.sendBulkTracked(peerID: b.id, channel: "files", payload: data) }
            for n in 1...40 {
                try await a.manager.send(peerID: b.id, channel: "input", payload: Data([UInt8(n)]));
                try await Task.sleep(for: .milliseconds(10))
            }
            let control = await input.values, earlyFiles = await files.count
            XCTAssertEqual(control.count, 41);
            XCTAssertEqual(earlyFiles, 0, "Bulk must not fill the stream before continuous input finishes")
            let kind = try await work.value;
            XCTAssertEqual(kind, "ble")
            try await waitFor { await files.count == 1 };
            let received = await files.values;
            XCTAssertEqual(received, [data])
            try await a.manager.send(peerID: b.id, channel: "input", payload: Data([0]));
            await a.manager.yieldBulkForInput(b.id)
            let began = ContinuousClock.now,
                delayed = Task {
                    try await a.manager.sendBulkTracked(peerID: b.id, channel: "files", payload: Data([1]))
                }
            try await Task.sleep(for: .milliseconds(80));
            try await a.manager.send(peerID: b.id, channel: "input", payload: Data([0]));
            _ = try await delayed.value
            XCTAssertGreaterThanOrEqual(
                began.duration(to: .now), .milliseconds(180), "Bulk ignored active input congestion feedback")
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testBackgroundFlowAndConfirmedDualLinkThroughput() async throws {
        let a = try SharingFixture(name: "SpeedA"), b = try SharingFixture(name: "SpeedB")
        do {
            try await b.manager.startBluetoothListener(port: b.port)
            _ = try await a.manager.connect(
                endpoint: endpoint(b), pairCode: "123456", password: "fixture-secret", kind: "ble")
            let background = SharingPackets(), control = SharingPackets()
            await b.manager.receive(channel: "background-qa") { _, data in
                try? await Task.sleep(for: .milliseconds(80));
                await background.add(data)
            }
            await b.manager.receive(channel: "input") { _, data in await control.add(data) }
            let work = Task {
                await withTaskGroup(of: Void.self) { group in
                    for n in 0..<10 {
                        group.addTask {
                            try? await a.manager.sendBackground(
                                peerID: b.id, channel: "background-qa", payload: Data(repeating: UInt8(n), count: 128))
                        }
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(20))
            try await a.manager.send(peerID: b.id, channel: "input", payload: Data("responsive".utf8))
            try await waitFor { await control.count == 1 }
            let delivered = await background.count;
            XCTAssertLessThan(delivered, 10, "Background data must not all queue ahead of input")
            await work.value
            let values = await background.values;
            XCTAssertEqual(values.count, 10);
            XCTAssertEqual(values.reduce(0) { $0 + $1.count }, 1280)
            let port = UInt16.random(in: 45000...48000);
            try await b.manager.start(port: port)
            _ = try await a.manager.connect(
                endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!), pairCode: nil, password: nil)
            let results = try await a.manager.testThroughput(peerID: b.id)
            XCTAssertEqual(Set(results.map(\.kind)), Set(["tcp", "ble"]))
            XCTAssertTrue(results.allSatisfy { $0.bytes > 0 && $0.seconds > 0 && $0.error == nil })
            XCTAssertLessThanOrEqual(results.first { $0.kind == "ble" }!.bytes, 65536)
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testIndependentResumePreservesLocalCursorWithoutWarp() async throws {
        let a = try SharingFixture(name: "IndependentSource"), b = try SharingFixture(name: "IndependentTarget")
        var service: InputService?
        defer { service?.stop() }
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            let state = await a.group.active;
            let group = try XCTUnwrap(state)
            let local = try XCTUnwrap(group.layout.first { $0.peerID == a.id && $0.primary })
            var moves = 0
            let input = InputService(
                id: a.id, platform: "macos", manager: a.manager,
                inject: { event, _, _, _ in if event.type == "move" { moves += 1 } }, restrict: { _, _ in },
                status: { _ in })
            service = input;
            await input.start();
            input.update(group, online: [a.id, b.id], sessions: await a.manager.currentSessions())
            try await input.enable();
            XCTAssertEqual(moves, 1, "Normal enable keeps its existing centering behavior")
            input.pause();
            moves = 0
            try await input.enable(preservingLocalCursor: CapturedInput("move", screenID: local.id, x: 0.73, y: 0.29))
            XCTAssertEqual(moves, 0, "Restoring independent control must not inject any cursor movement")
            let point = local.logical(0.73, 0.29)
            XCTAssertEqual(try XCTUnwrap(input.pointer).x, local.x + point.0 * local.width, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(input.pointer).y, local.y + point.1 * local.height, accuracy: 0.001)
            XCTAssertFalse(
                input.capture(CapturedInput("move", deltaX: 1, screenID: local.id, x: 0.73, y: 0.29)),
                "Local input passes through after restoring sharing")
            input.stop();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            service?.stop();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testMacModifierSwapRoutesCtrlPasteZoomAndAltWithoutChangingLocalCopy() async throws {
        for swapped in [false, true] {
            let
                a = try SharingFixture(
                    name: "ModifierSource", id: "0000" + UUID().uuidString.lowercased().dropFirst(4)),
                b = try SharingFixture(name: "ModifierTarget", id: "ffff" + UUID().uuidString.lowercased().dropFirst(4))
            var sender: InputService?, receiver: InputService?
            do {
                try await connect(a, b, directLAN: false);
                try await waitFor { await self.sameDesktop(a, b) }
                let state = await a.group.active;
                let group = try XCTUnwrap(state)
                var events: [CapturedInput] = [], pasted = false, localCopies = 0
                let entry = UUID().uuidString.lowercased()
                let source = InputService(
                    id: a.id, platform: "macos", manager: a.manager, inject: { _, _, _, _ in }, restrict: { _, _ in },
                    status: { _ in })
                let target = InputService(
                    id: b.id, platform: "windows", manager: b.manager, inject: { e, _, _, _ in events.append(e) },
                    restrict: { _, _ in }, status: { _ in })
                sender = source;
                receiver = target
                source.sourceKeyTransform = { MacInputAdapter.sourceKey($0, to: $1, fnCommandSwapped: swapped) }
                source.clipboardEntryID = { entry };
                source.localClipboardCommand = { localCopies += 1 }
                target.commandHandler = { command, peer, id in
                    if command == "paste" {
                        XCTAssertEqual(peer, a.id);
                        XCTAssertEqual(id, entry);
                        pasted = true;
                        return true
                    };
                    return false
                }
                await source.start();
                await target.start()
                var sourceSessions = await a.manager.currentSessions();
                for i in sourceSessions.indices { sourceSessions[i].remotePlatform = "windows" };
                source.update(group, online: [a.id, b.id], sessions: sourceSessions);
                target.update(group, online: [a.id, b.id], sessions: await b.manager.currentSessions())
                try await source.enable();
                try await target.enable()
                try await waitFor {
                    var x = await a.manager.currentSessions();
                    let y = await b.manager.currentSessions();
                    for i in x.indices { x[i].remotePlatform = "windows" };
                    source.update(group, online: [a.id, b.id], sessions: x);
                    target.update(group, online: [a.id, b.id], sessions: y);
                    return x.first?.capabilities.contains("input-function-keys-v1") == true
                        && x.first?.capabilities.contains("input") == true
                        && y.first?.capabilities.contains("input") == true
                }
                let local = try XCTUnwrap(group.layout.first { $0.peerID == a.id }),
                    remote = try XCTUnwrap(group.layout.first { $0.peerID == b.id })
                try await waitFor { source.pointer != nil && source.pointer == target.pointer }
                try await source.enable()
                try await waitFor {
                    source.pointer?.ownerPeerID == a.id && target.pointer?.ownerPeerID == a.id
                        && target.pointer?.screenID == local.id
                }
                // Local Command+C stays native even when that system role came from Fn.
                XCTAssertFalse(source.capture(CapturedInput("keyDown", key: "MetaRight")))
                XCTAssertFalse(source.capture(CapturedInput("keyDown", key: "KeyC")))
                _ = source.capture(CapturedInput("keyUp", key: "KeyC"));
                _ = source.capture(CapturedInput("keyUp", key: "MetaRight"))
                XCTAssertEqual(localCopies, 1)
                let ctrl = swapped ? "MetaRight" : "Fn", alt = swapped ? "Fn" : "MetaLeft"
                _ = source.capture(CapturedInput("keyDown", key: ctrl))
                let right = remote.x > local.x
                _ = source.capture(
                    CapturedInput("move", deltaX: right ? 8 : -8, screenID: local.id, x: right ? 1 : 0, y: 0.5))
                try await waitFor { events.contains { $0.type == "keyDown" && $0.key == "ControlLeft" } }
                _ = source.capture(CapturedInput("keyDown", key: "Equal"));
                _ = source.capture(CapturedInput("keyUp", key: "Equal"))
                try await waitFor { events.contains { $0.type == "keyUp" && $0.key == "Equal" } }
                XCTAssertTrue(source.capture(CapturedInput("keyDown", key: "KeyV")))
                _ = source.capture(CapturedInput("keyUp", key: "KeyV"));
                _ = source.capture(CapturedInput("keyUp", key: ctrl))
                try await waitFor { pasted && events.contains { $0.type == "keyUp" && $0.key == "ControlLeft" } }
                XCTAssertFalse(events.contains { $0.key == "KeyV" }, "Paste command must not also inject a raw V")
                _ = source.capture(CapturedInput("keyDown", key: alt));
                _ = source.capture(CapturedInput("keyDown", key: "Tab"));
                _ = source.capture(CapturedInput("keyUp", key: "Tab"));
                _ = source.capture(CapturedInput("keyUp", key: alt))
                try await waitFor { events.contains { $0.type == "keyUp" && $0.key == "AltLeft" } }
                source.stop();
                target.stop();
                await a.manager.stop();
                await b.manager.stop()
            } catch {
                sender?.stop();
                receiver?.stop();
                await a.manager.stop();
                await b.manager.stop();
                throw error
            }
        }
    }
    @MainActor func testCaptureTimeoutKeepsRemoteScreenReleasesHeldAndResumesScroll() async throws {
        for relative in [false, true] {
            let a = try SharingFixture(name: "TimeoutSource"), b = try SharingFixture(name: "TimeoutTarget")
            var sender: InputService?, receiver: InputService?
            do {
                try await connect(a, b);
                try await waitFor { await self.sameDesktop(a, b) }
                let state = await a.group.active;
                let group = try XCTUnwrap(state)
                var events: [CapturedInput] = [], restrictions: [(Bool, Bool)] = [], started = 0
                let source = InputService(
                    id: a.id, platform: "macos", manager: a.manager, inject: { _, _, _, _ in },
                    restrict: { restrictions.append(($0, $1)) }, status: { _ in },
                    event: { if $0.hasPrefix("InputRelativeModeStarted") { started += 1 } })
                let target = InputService(
                    id: b.id, platform: "windows", manager: b.manager, inject: { e, _, _, _ in events.append(e) },
                    restrict: { _, _ in }, status: { _ in })
                sender = source;
                receiver = target;
                target.relativePointerCaptured = { relative }
                await source.start();
                await target.start()
                source.update(group, online: [a.id, b.id], sessions: await a.manager.currentSessions());
                target.update(group, online: [a.id, b.id], sessions: await b.manager.currentSessions())
                try await source.enable();
                try await target.enable()
                try await waitFor {
                    let x = await a.manager.currentSessions(), y = await b.manager.currentSessions()
                    source.update(group, online: [a.id, b.id], sessions: x);
                    target.update(group, online: [a.id, b.id], sessions: y)
                    return x.first?.capabilities.contains("scroll-flow-v1") == true
                        && x.first?.capabilities.contains("input") == true
                        && y.first?.capabilities.contains("input") == true
                }
                let session = await a.manager.currentSessions().first?.sessionID
                let local = try XCTUnwrap(group.layout.first { $0.peerID == a.id })
                let remote = try XCTUnwrap(group.layout.first { $0.peerID == b.id })
                let toRight = remote.x > local.x
                _ = source.capture(
                    CapturedInput("move", deltaX: toRight ? 8 : -8, screenID: local.id, x: toRight ? 1 : 0, y: 0.5))
                try await waitFor {
                    target.pointer?.ownerPeerID == a.id && target.pointer?.screenID == source.remoteScreenID
                        && (!relative || started == 1)
                }
                _ = source.capture(CapturedInput("buttonDown", button: 0))
                try await waitFor { events.contains { $0.type == "buttonDown" } }
                let before = try XCTUnwrap(source.pointer);
                restrictions = [];
                events = []
                source.recoverCaptureTimeout()
                XCTAssertTrue(source.enabled);
                XCTAssertEqual(source.pointer?.screenID, before.screenID)
                XCTAssertEqual(source.pointer?.x, before.x);
                XCTAssertEqual(source.pointer?.y, before.y)
                XCTAssertEqual(source.pointer?.ownerPeerID, a.id);
                XCTAssertEqual(source.pointer?.epoch, before.epoch + 1)
                XCTAssertTrue(
                    restrictions.last?.0 == true && restrictions.last?.1 == true,
                    "Timeout must retain remote cursor interception")
                try await waitFor {
                    events.contains { $0.type == "buttonUp" } && target.pointer?.epoch == before.epoch + 1
                        && (!relative || started == 2)
                }
                events = []
                // A receiving Mac tap timeout must likewise not steal the sender's ownership.
                let receiverPointer = target.pointer;
                target.recoverCaptureTimeout();
                XCTAssertEqual(target.pointer, receiverPointer)
                _ = source.capture(CapturedInput("scroll", deltaY: 3.25, scrollPhase: 2, preciseScroll: true))
                _ = source.capture(CapturedInput("scroll", scrollPhase: 4, preciseScroll: true))
                if relative { _ = source.capture(CapturedInput("move", deltaX: 4.5, deltaY: 1.25)) }
                try await waitFor {
                    events.contains { $0.type == "scroll" && $0.deltaY == 3.25 }
                        && (!relative || events.contains { $0.type == "relativeMove" && $0.deltaX == 4.5 })
                }
                let afterSession = await a.manager.currentSessions().first?.sessionID;
                XCTAssertEqual(afterSession, session)
                source.stop();
                target.stop();
                await a.manager.stop();
                await b.manager.stop()
            } catch {
                sender?.stop();
                receiver?.stop();
                await a.manager.stop();
                await b.manager.stop();
                throw error
            }
        }
    }

    @MainActor func testCompactInputAfterOwnershipChangeAcknowledgesWithoutInjectingOldGesture() async throws {
        for platform in ["macos", "windows"] {
            let a = try SharingFixture(name: "OldController"), b = try SharingFixture(name: "NewController")
            var service: InputService?
            do {
                try await connect(a, b);
                try await waitFor { await self.sameDesktop(a, b) }
                let state = await a.group.active;
                let group = try XCTUnwrap(state)
                let screen = try XCTUnwrap(group.layout.first { $0.peerID == b.id })
                var events: [CapturedInput] = [], acks: [UInt64] = []
                await a.manager.receive(channel: "input") { peer, bytes in
                    let value =
                        MotionCodec.decode(bytes, group: group, source: peer, target: a.id)
                        ?? (try? JSONDecoder().decode(InputPacket.self, from: bytes))
                    if let sequence = value?.acknowledgedSequence { await MainActor.run { acks.append(sequence) } }
                }
                await a.manager.setCapabilities([
                    "input": true, "compact-input": true, "compact-input-v3": true, "compact-scroll-v1": true,
                    "scroll-flow-v1": true,
                ])
                let target = InputService(
                    id: b.id, platform: platform, manager: b.manager, inject: { e, _, _, _ in events.append(e) },
                    restrict: { _, _ in }, status: { _ in })
                service = target;
                await target.start();
                target.update(group, online: [a.id, b.id], sessions: await b.manager.currentSessions());
                try await target.enable()
                try await waitFor {
                    let sessions = await b.manager.currentSessions();
                    target.update(group, online: [a.id, b.id], sessions: sessions);
                    return sessions.first?.capabilities.contains("input") == true
                }
                var control = InputPacket(type: "control", groupID: group.id, sourcePeerID: a.id, targetPeerID: b.id)
                control.sequence = 10;
                control.pointer = PointerRouter.center(screen, owner: a.id, epoch: 100);
                control.targetScreenID = screen.id
                try await a.manager.send(peerID: b.id, channel: "input", payload: JSONEncoder().encode(control))
                try await waitFor { target.pointer?.ownerPeerID == a.id }
                _ = target.capture(CapturedInput("move", deltaX: 10, screenID: screen.id, x: 0.5, y: 0.5))
                XCTAssertEqual(target.pointer?.ownerPeerID, b.id)
                events = []
                var stale = control;
                stale.type = "scroll";
                stale.sequence = 11;
                stale.deltaY = 9;
                stale.scrollPhase = 2
                try await a.manager.send(
                    peerID: b.id, channel: "input",
                    payload: try XCTUnwrap(MotionCodec.encode(stale, layout: group.layout, compactContext: true)))
                stale.type = "move";
                stale.sequence = 12
                try await a.manager.send(
                    peerID: b.id, channel: "input",
                    payload: try XCTUnwrap(MotionCodec.encode(stale, layout: group.layout, compactContext: true)))
                try await Task.sleep(for: .milliseconds(250))
                XCTAssertTrue(
                    acks.contains { $0 >= 12 },
                    "Old controller packets must still receive transport credit after local takeover")
                XCTAssertFalse(
                    events.contains { $0.type == "scroll" }, "An old gesture must not scroll after local takeover")
                XCTAssertEqual(target.pointer?.ownerPeerID, b.id)
                control.sequence = 13;
                control.pointer = PointerRouter.center(screen, owner: a.id, epoch: 102)
                try await a.manager.send(peerID: b.id, channel: "input", payload: JSONEncoder().encode(control))
                try await waitFor { target.pointer?.ownerPeerID == a.id }
                stale = control;
                stale.type = "scroll";
                stale.sequence = 14;
                stale.deltaY = 0.25;
                stale.scrollPhase = 2
                try await a.manager.send(
                    peerID: b.id, channel: "input",
                    payload: try XCTUnwrap(MotionCodec.encode(stale, layout: group.layout, compactContext: true)))
                try await waitFor { events.contains { $0.type == "scroll" && $0.deltaY == 0.25 } }
                target.stop();
                await a.manager.stop();
                await b.manager.stop()
            } catch {
                service?.stop();
                await a.manager.stop();
                await b.manager.stop();
                throw error
            }
        }
    }

    @MainActor func testBLEScrollBackpressurePreservesSwipeAndCriticalOrder() async throws {
        let a = try SharingFixture(name: "ScrollCreditsA", bluetoothInputOnly: true),
            b = try SharingFixture(name: "ScrollCreditsB", bluetoothInputOnly: true)
        var service: InputService?
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            try await b.manager.startBluetoothListener(port: b.port + 1)
            _ = try await a.manager.connect(
                endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: b.port + 1)!), pairCode: nil,
                password: nil, kind: "ble")
            let state = await a.group.active;
            let group = try XCTUnwrap(state)
            var context: PointerState?, events: [InputPacket] = [], warnings: [String] = []
            await b.manager.receive(channel: "input") { peer, bytes in
                let parsed = await MainActor.run { () -> InputPacket? in
                    let value =
                        MotionCodec.decode(bytes, group: group, source: peer, target: b.id, context: context)
                        ?? (try? JSONDecoder().decode(InputPacket.self, from: bytes))
                    if let value {
                        if ["control", "pointer", "move"].contains(value.type) { context = value.pointer };
                        events.append(value)
                    }
                    return value
                }
                if let value = parsed, ["scroll", "move"].contains(value.type) {
                    Task {
                        try? await Task.sleep(for: .milliseconds(100));
                        var ack = InputPacket(
                            type: "motionAck", groupID: group.id, sourcePeerID: b.id, targetPeerID: a.id);
                        ack.acknowledgedSequence = value.sequence
                        if let bytes = MotionCodec.encode(ack, layout: group.layout, compactContext: true) {
                            try? await b.manager.send(peerID: a.id, channel: "input", payload: bytes)
                        }
                    }
                }
            }
            await b.manager.setCapabilities([
                "input": true, "compact-input": true, "compact-input-v3": true, "compact-scroll-v1": true,
                "scroll-flow-v1": true, "ble-input-v2": true,
            ])
            let input = InputService(
                id: a.id, platform: "macos", manager: a.manager, inject: { _, _, _, _ in }, restrict: { _, _ in },
                status: { _ in }, event: { warnings.append($0) });
            input.horizontalScrollAngle = { _ in 0 };
            service = input;
            await input.start();
            input.update(group, online: [a.id, b.id], sessions: await a.manager.currentSessions());
            try await input.enable()
            try await waitFor {
                let sessions = await a.manager.currentSessions();
                input.update(group, online: [a.id, b.id], sessions: sessions);
                return sessions.first?.capabilities.contains("scroll-flow-v1") == true
            }
            let local = try XCTUnwrap(group.layout.first { $0.peerID == a.id });
            _ = input.capture(CapturedInput("move", deltaX: 8, screenID: local.id, x: 1, y: 0.5))
            for _ in 0..<300 {
                XCTAssertTrue(
                    input.capture(
                        CapturedInput(
                            "scroll", deltaX: 0.125, deltaY: 0.25, scrollPhase: 2, momentumPhase: 0, preciseScroll: true
                        )));
                _ = input.capture(CapturedInput("move", deltaX: 0.02));
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertFalse(
                events.contains { $0.type == "pointer" },
                "Interleaved motion must not bypass a full delivery window with reliable pointer frames")
            _ = input.capture(CapturedInput("scroll", scrollPhase: 4, momentumPhase: 0, preciseScroll: true));
            _ = input.capture(CapturedInput("buttonDown"));
            _ = input.capture(CapturedInput("buttonUp"))
            try await waitFor { events.contains { $0.type == "buttonUp" } }
            XCTAssertEqual(events.filter { $0.type == "scroll" }.reduce(0) { $0 + $1.deltaY }, 75, accuracy: 0.01)
            XCTAssertEqual(events.filter { $0.type == "scroll" }.reduce(0) { $0 + $1.deltaX }, 37.5, accuracy: 0.01)
            let end = try XCTUnwrap(events.firstIndex { $0.type == "scroll" && $0.scrollPhase == 4 });
            let click = try XCTUnwrap(events.firstIndex { $0.type == "buttonDown" });
            XCTAssertLessThan(end, click)
            XCTAssertTrue(input.enabled);
            XCTAssertFalse(warnings.contains { $0.contains("Congested") || $0.contains("AckStalled") })
            let latencies = try await a.manager.testLatency(peerID: b.id, onlyKind: "ble");
            XCTAssertTrue(
                latencies.first?.lost == 0, "Compact probes must round trip through the real authenticated transport")
            input.stop();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            service?.stop();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }

    @MainActor func testRelativeGameMotionBothDirectionsKeepsAllDeltasAndExits() async throws {
        for (sourcePlatform, targetPlatform) in [("macos", "windows"), ("windows", "macos")] {
            let a = try SharingFixture(name: "RelativeSource"), b = try SharingFixture(name: "RelativeTarget")
            var sa: InputService?, sb: InputService?
            do {
                try await connect(a, b);
                try await waitFor { await self.sameDesktop(a, b) }
                let state = await a.group.active;
                let group = try XCTUnwrap(state)
                var delivered: [CapturedInput] = [], captured = true, started = false, ended = false
                let source = InputService(
                    id: a.id, platform: sourcePlatform, manager: a.manager, inject: { _, _, _, _ in },
                    restrict: { _, _ in }, status: { _ in },
                    event: {
                        if $0.hasPrefix("InputRelativeModeStarted") { started = true };
                        if $0 == "InputRelativeModeEnded" { ended = true }
                    })
                let target = InputService(
                    id: b.id, platform: targetPlatform, manager: b.manager,
                    inject: { e, _, _, _ in delivered.append(e) }, restrict: { _, _ in }, status: { _ in })
                sa = source;
                sb = target;
                target.relativePointerCaptured = { captured }
                await source.start();
                await target.start();
                source.update(group, online: [a.id, b.id], sessions: await a.manager.currentSessions());
                target.update(group, online: [a.id, b.id], sessions: await b.manager.currentSessions())
                try await source.enable();
                try await target.enable()
                try await waitFor {
                    let x = await a.manager.currentSessions(), y = await b.manager.currentSessions();
                    source.update(group, online: [a.id, b.id], sessions: x);
                    target.update(group, online: [a.id, b.id], sessions: y);
                    return x.first?.capabilities.contains("relative-pointer-v1") == true
                        && y.first?.capabilities.contains("relative-pointer-v1") == true
                        && x.first?.capabilities.contains("input") == true
                        && y.first?.capabilities.contains("input") == true
                }
                let local = try XCTUnwrap(group.layout.first { $0.peerID == a.id })
                _ = source.capture(CapturedInput("move", deltaX: 8, screenID: local.id, x: 1, y: 0.5))
                try await waitFor { started && delivered.contains { $0.type == "relativeReset" } }
                let anchor = source.pointer
                let targetOwner = target.pointer
                XCTAssertFalse(target.capture(CapturedInput("move", deltaX: 500, deltaY: -500, hardwareMotion: false)))
                XCTAssertEqual(target.pointer, targetOwner, "A game's software cursor warp must not steal ownership")
                for _ in 0..<200 { XCTAssertTrue(source.capture(CapturedInput("move", deltaX: 12.25, deltaY: -0.25))) }
                try await waitFor {
                    abs(delivered.filter { $0.type == "relativeMove" }.reduce(0) { $0 + $1.deltaX } - 2450) < 0.001
                }
                XCTAssertEqual(
                    delivered.filter { $0.type == "relativeMove" }.reduce(0) { $0 + $1.deltaY }, -50, accuracy: 0.001)
                XCTAssertEqual(source.pointer, anchor, "A camera turn must not cross screen edges")
                captured = false;
                try await waitFor { ended }
                _ = source.capture(CapturedInput("move", deltaX: -4000))
                XCTAssertEqual(source.pointer?.screenID, local.id, "Leaving game mode must restore desktop crossing")
                source.stop();
                target.stop();
                await a.manager.stop();
                await b.manager.stop()
            } catch {
                sa?.stop();
                sb?.stop();
                await a.manager.stop();
                await b.manager.stop();
                throw error
            }
        }
    }

    @MainActor func testNetworkRecoveryWithoutBonjourKeepsBLEAndPinnedIdentity() async throws {
        let a = try SharingFixture(name: "RecoveryA", id: "11111111-1111-4111-8111-111111111111")
        let b = try SharingFixture(name: "RecoveryB", id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        let wrong = try SharingFixture(name: "WrongRecoveryPeer")
        do {
            try await connect(a, b)
            try await b.manager.startBluetoothListener(port: b.port + 1)
            _ = try await a.manager.connect(
                endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: b.port + 1)!), pairCode: nil,
                password: nil, kind: "ble")
            try await waitFor { await a.manager.currentSessions().first?.capabilities.contains("ble") == true }
            let original = await a.manager.currentSessions().first?.sessionID
            let prompts = a.connectionPrompts.value + b.connectionPrompts.value
            let cached = try PeerRegistry(directory: a.directory).find(b.id)?.networkEndpoints
            XCTAssertTrue(cached?.contains(NetworkEndpoint(host: "127.0.0.1", port: b.port)) == true)
            await a.manager.disconnectTransport(b.id, kind: "tcp")
            try await waitFor { await a.manager.currentSessions().first?.capabilities.contains("tcp") == false }
            await a.manager.setNetworkAvailable(false);
            await a.manager.recoverNetworkLinks()
            let offline = await a.manager.currentSessions();
            XCTAssertEqual(offline.first?.capabilities.contains("tcp"), false)
            await a.manager.setNetworkAvailable(true)
            await a.manager.recoverNetworkLinks()
            try await waitFor {
                let sessions = await a.manager.currentSessions();
                return sessions.first?.capabilities.contains("tcp") == true
                    && sessions.first?.capabilities.contains("ble") == true
            }
            let current = await a.manager.currentSessions().first
            XCTAssertEqual(current?.sessionID, original);
            XCTAssertEqual(a.connectionPrompts.value + b.connectionPrompts.value, prompts)
            let peers = await a.manager.currentSessions();
            XCTAssertEqual(peers.count, 1)
            await a.manager.recoverNetworkLinks();
            await a.manager.recoverNetworkLinks()
            XCTAssertEqual(
                a.connectionPrompts.value + b.connectionPrompts.value, prompts,
                "Recovery must not create extra approvals")
            await a.manager.disconnect(b.id);
            try await waitFor {
                let left = await a.manager.currentSessions(), right = await b.manager.currentSessions();
                return left.isEmpty && right.isEmpty
            }
            try a.registry.setPreferences(b.id, trusted: false, autoConnect: true)
            try await wrong.manager.start(port: wrong.port)
            try a.registry.rememberNetworkEndpoint(b.id, endpoint: NetworkEndpoint(host: "127.0.0.1", port: wrong.port))
            await a.manager.recoverNetworkLinks()
            let absent = await a.manager.currentSessions();
            XCTAssertTrue(absent.isEmpty)
            XCTAssertEqual(
                wrong.connectionPrompts.value + wrong.certificatePrompts.value, 0,
                "A stale address must fail before pairing a different identity")
            await a.manager.recoverNetworkLinks();
            let stillAbsent = await a.manager.currentSessions();
            XCTAssertTrue(stillAbsent.isEmpty, "Failure must back off")
            try await Task.sleep(for: .milliseconds(2100));
            await a.manager.recoverNetworkLinks()
            try await waitFor { await a.manager.currentSessions().first?.capabilities.contains("tcp") == true }
            XCTAssertEqual(
                a.connectionPrompts.value + b.connectionPrompts.value, prompts + 1,
                "A new session still requires receiver approval")
            await a.manager.stop();
            await b.manager.stop();
            await wrong.manager.stop()
        } catch {
            await a.manager.stop();
            await b.manager.stop();
            await wrong.manager.stop();
            throw error
        }
    }

    @MainActor func testRemoteOpenRequiresMatchingAcknowledgementAndExpiresUnconfirmed() async throws {
        let a = try SharingFixture(name: "OpenA"), b = try SharingFixture(name: "OpenB")
        let clipboard = ClipboardService(id: b.id, manager: b.manager, changed: { _ in }, event: { _ in })
        let screen = ScreenGeometry(
            id: b.id + ":test", peerID: b.id, name: "Fixture", number: 1, pixelWidth: 1000, pixelHeight: 720,
            primary: true, x: 0, y: 0)
        var clock = Date(), restored = false, injections = 0
        let target = ComputerUseService(
            id: b.id, name: "OpenB", manager: b.manager, files: nil, clipboard: clipboard, screens: { [screen] },
            info: { .object([:]) }, screenshot: { _ in .object(["width": .number(1000), "height": .number(720)]) },
            inject: { _, _, _, _ in injections += 1 }, suspend: { true }, restore: { restored = $0 },
            canControl: { true }, now: { clock })
        func send(_ type: String, _ request: String, _ value: JSONValue? = nil) async throws {
            let data = try value?.data() ?? Data()
            let packet: JSONValue = .object([
                "type": .string(type), "requestID": .string(request), "offset": .number(0),
                "total": .number(Double(data.count)), "data": .string(data.base64EncodedString()),
            ])
            try await a.manager.send(peerID: b.id, channel: "computer", payload: packet.data())
        }
        do {
            try await connect(a, b);
            await a.manager.setCapability("computer-open-ack-v1", enabled: true)
            await a.manager.receive(channel: "computer") { _, _ in };
            target.allowComputer = true;
            await target.start()
            try await waitFor {
                await b.manager.currentSessions().first?.capabilities.contains("computer-open-ack-v1") == true
            }
            let first = UUID().uuidString
            try await send("request", first, .object(["operation": .string("open"), "arguments": .object([:])]))
            try await waitFor { target.controlling }
            try await send("open_cancel", UUID().uuidString);
            try await Task.sleep(for: .milliseconds(50));
            XCTAssertTrue(target.controlling)
            try await send("open_ack", first);
            try await Task.sleep(for: .milliseconds(50));
            clock.addTimeInterval(46)
            try await Task.sleep(for: .milliseconds(1100));
            XCTAssertTrue(target.controlling, "Confirmed opens retain the ten-minute lease")
            target.endControl();
            restored = false
            let second = UUID().uuidString
            try await send("request", second, .object(["operation": .string("open"), "arguments": .object([:])]))
            try await waitFor { target.controlling };
            clock.addTimeInterval(46)
            try await waitFor { !target.controlling };
            XCTAssertTrue(restored);
            XCTAssertEqual(injections, 0)
            target.stop();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            target.stop();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testSingleSideResumeKeepsSessionAndCoalescesScrollBeforeClick() async throws {
        let a = try SharingFixture(name: "ResumeA", bluetoothInputOnly: false),
            b = try SharingFixture(name: "ResumeB", bluetoothInputOnly: false)
        var sender: InputService?, receiver: InputService?
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            let state = await a.group.active;
            let group = try XCTUnwrap(state)
            var delivered: [CapturedInput] = [], resumes = 0
            let sa = InputService(
                id: a.id, platform: "macos", manager: a.manager, inject: { _, _, _, _ in }, restrict: { _, _ in },
                status: { _ in })
            let sb = InputService(
                id: b.id, platform: "windows", manager: b.manager,
                inject: { value, _, _, _ in delivered.append(value) }, restrict: { _, _ in }, status: { _ in })
            sender = sa;
            receiver = sb;
            await sa.start();
            await sb.start()
            sa.update(group, online: [a.id, b.id], sessions: await a.manager.currentSessions());
            sb.update(group, online: [a.id, b.id], sessions: await b.manager.currentSessions())
            try await sa.enable();
            try await sb.enable()
            try await waitFor {
                let x = await a.manager.currentSessions(), y = await b.manager.currentSessions();
                return x.first?.capabilities.contains("input") == true
                    && y.first?.capabilities.contains("input") == true
            }
            let original = await a.manager.currentSessions().first?.sessionID
            let approvalCount = a.connectionPrompts.value + b.connectionPrompts.value
            sa.pause();
            sb.pause()
            try await waitFor {
                let x = await a.manager.currentSessions(), y = await b.manager.currentSessions();
                return x.first?.capabilities.contains("input") == false
                    && y.first?.capabilities.contains("input") == false
            }
            sb.resumeRequested = {
                resumes += 1;
                Task { try await sb.enable() }
            }
            try await sa.enable();
            sa.requestPeerResume()
            try await waitFor {
                let sessions = await a.manager.currentSessions();
                return sb.enabled && resumes == 1 && sessions.first?.capabilities.contains("input") == true
            }
            sa.update(group, online: [a.id, b.id], sessions: await a.manager.currentSessions());
            sb.update(group, online: [a.id, b.id], sessions: await b.manager.currentSessions())
            let local = try XCTUnwrap(group.layout.first { $0.peerID == a.id })
            _ = sa.capture(CapturedInput("move", deltaX: 8, screenID: local.id, x: 1, y: 0.5))
            try await Task.sleep(for: .milliseconds(30));
            delivered = []
            for _ in 0..<250 {
                XCTAssertTrue(
                    sa.capture(
                        CapturedInput("scroll", deltaY: 1, scrollPhase: 2, momentumPhase: 0, preciseScroll: true)))
            }
            _ = sa.capture(CapturedInput("buttonDown"));
            _ = sa.capture(CapturedInput("buttonUp"))
            try await waitFor { delivered.contains { $0.type == "buttonUp" } }
            let scrolling = delivered.filter { $0.type == "scroll" }
            XCTAssertLessThan(scrolling.count, 10);
            XCTAssertEqual(scrolling.reduce(0) { $0 + $1.deltaY }, 250, accuracy: 0.001)
            XCTAssertLessThan(
                try XCTUnwrap(delivered.firstIndex { $0.type == "scroll" }),
                try XCTUnwrap(delivered.firstIndex { $0.type == "buttonDown" }))
            let latest = await a.manager.currentSessions();
            XCTAssertEqual(latest.count, 1);
            XCTAssertEqual(latest.first?.sessionID, original)
            XCTAssertEqual(
                a.connectionPrompts.value + b.connectionPrompts.value, approvalCount,
                "Input resume must not request pairing approval")
            sa.stop();
            sb.stop();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            sender?.stop();
            receiver?.stop();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testApplyAllConflictDecisionIsLimitedToOneTransfer() async throws {
        let a = try SharingFixture(name: "ConflictA"), b = try SharingFixture(name: "ConflictB")
        let ca = ClipboardService(
            id: a.id, manager: a.manager, changed: { _ in }, event: { _ in }, directory: a.directory)
        let cb = ClipboardService(
            id: b.id, manager: b.manager, changed: { _ in }, event: { _ in }, directory: b.directory)
        var decision = "overwrite:all", prompts = 0
        func service(_ fixture: SharingFixture, _ clipboard: ClipboardService) throws -> FileTransferService {
            try FileTransferService(
                id: fixture.id, directory: fixture.directory, manager: fixture.manager, clipboard: clipboard,
                changed: { _ in }, event: { _ in }, sourceChanged: { _ in false },
                conflict: { _, _, _ in
                    prompts += 1;
                    return decision
                }, partialFailure: { _ in "abort" }, deleteAll: { _ in false })
        }
        let fa = try service(a, ca), fb = try service(b, cb)
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) };
            let group = await a.group.active
            ca.update(group, online: [a.id, b.id]);
            cb.update(group, online: [a.id, b.id]);
            fa.update(group, online: [a.id, b.id], sessions: await a.manager.currentSessions());
            fb.update(group, online: [a.id, b.id], sessions: await b.manager.currentSessions())
            await ca.start();
            await cb.start();
            await fa.start();
            await fb.start()
            let target = b.directory.appendingPathComponent("target");
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let files = ["one.txt", "two.txt", "three.txt"].map { a.directory.appendingPathComponent($0) }
            for file in files {
                try Data("new".utf8).write(to: file);
                try Data("old".utf8).write(to: target.appendingPathComponent(file.lastPathComponent))
            }
            try await fa.copy(files.map(\.path), cut: false);
            try await waitFor { cb.current?.id == ca.current?.id }
            let first = try await fb.paste(target.path);
            XCTAssertEqual(fb.currentTasks.first { $0.id == first }?.state, "completed");
            XCTAssertEqual(prompts, 1)
            for file in files {
                XCTAssertEqual(
                    try String(contentsOf: target.appendingPathComponent(file.lastPathComponent), encoding: .utf8),
                    "new")
            }
            decision = "skip:all";
            let second = try await fb.paste(target.path)
            XCTAssertEqual(fb.currentTasks.first { $0.id == second }?.state, "completed");
            XCTAssertEqual(prompts, 2, "A later paste must ask again")
            fa.stop();
            fb.stop();
            ca.stop();
            cb.stop();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            fa.stop();
            fb.stop();
            ca.stop();
            cb.stop();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testHigherStoredFollowerLayoutConvergesOnUnchangedSession() async throws {
        let a = try SharingFixture(name: "LayoutLeader"), b = try SharingFixture(name: "LayoutFollower")
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            let value = await a.group.active;
            var newer = try XCTUnwrap(value)
            XCTAssertEqual(newer.leaderID, a.id)
            newer.revision += 7;
            newer.layout[1].y = 180
            let saved = GroupStore(groups: [newer], activeGroupID: newer.id)
            try JSONEncoder().encode(saved).write(
                to: b.directory.appendingPathComponent("groups.json"), options: .atomic)
            b.group = try GroupManager(
                localID: b.id, name: "LayoutFollower", publicKey: b.identity.certificatePeer.publicKey,
                screens: newer.layout.filter { $0.peerID == b.id }, directory: b.directory, manager: b.manager,
                registry: b.registry, confirm: { _ in false }, changed: { _, _, _, _ in }, event: { _ in },
                automaticSharing: true)
            await b.group.start();
            await b.group.connectionsChanged(b.manager.currentSessions())
            let arranged = newer.layout
            try await waitFor {
                let x = await a.group.active, y = await b.group.active
                return x?.layout == arranged && y?.layout == arranged && x?.revision == y?.revision
                    && x?.leaderID == a.id && y?.leaderID == a.id
            }
            let lease = try await b.group.beginEdit("layout")
            var next = arranged;
            next[1].y = 90
            try await b.group.commitLayout(next, lock: lease)
            try await waitFor { await a.group.active?.layout == next }
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testUnchangedScreenReportsPreserveEditLock() async throws {
        let a = try SharingFixture(name: "ScreenLeader"), b = try SharingFixture(name: "ScreenFollower")
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            let value = await a.group.active;
            let first = try XCTUnwrap(value)
            let lease = try await b.group.beginEdit("layout")
            for _ in 0..<3 {
                await a.group.updateScreens(first.layout.filter { $0.peerID == a.id })
                await b.group.updateScreens(first.layout.filter { $0.peerID == b.id })
            }
            var arranged = first.layout;
            arranged[1].y = 100
            try await b.group.commitLayout(arranged, lock: lease)
            try await waitFor { await a.group.active?.layout == arranged }
            let committed = await a.group.active
            XCTAssertEqual(
                committed?.revision, first.revision + 1, "Unchanged display reports must not advance the shared version"
            )
            let again = try await b.group.beginEdit("layout")
            let reused = try await b.group.beginEdit("layout")
            XCTAssertEqual(again, reused, "The owner may recover its existing edit lease")
            await b.group.release(again)
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testRealtimeHistoryAndReconnectPreserveLocalDisplaySettings() async throws {
        let a = try SharingFixture(name: "HistoryA"), b = try SharingFixture(name: "HistoryB")
        let ha = try HistoryService(id: a.id, directory: a.directory, manager: a.manager, changed: {})
        let hb = try HistoryService(id: b.id, directory: b.directory, manager: b.manager, changed: {})
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            let shared = await a.group.active;
            let group = try XCTUnwrap(shared)
            await ha.start();
            await hb.start()
            ha.update(group, online: [a.id, b.id]);
            hb.update(group, online: [a.id, b.id])
            try ha.configurePopup(visibleCount: 9, preferredSide: "right");
            try hb.configurePopup(visibleCount: 3, preferredSide: "left")
            let text = String(repeating: "实时中文🙂/", count: 8000)
            try ha.remember(text)
            try await waitFor { hb.entries.contains { $0.text == text } }
            try hb.remember("来自另一端的文本", favorite: true)
            try await waitFor { ha.entries.contains { $0.text == "来自另一端的文本" && $0.favorite } }
            XCTAssertEqual(ha.entries.filter { $0.text == text }.count, 1);
            XCTAssertEqual(hb.entries.filter { $0.text == text }.count, 1)
            ha.update(group, online: [a.id]);
            hb.update(group, online: [b.id])
            try ha.remember("离线 A");
            try hb.remember("离线 B")
            await Task.yield()
            XCTAssertFalse(hb.entries.contains { $0.text == "离线 A" });
            XCTAssertFalse(ha.entries.contains { $0.text == "离线 B" })
            ha.update(group, online: [a.id, b.id]);
            hb.update(group, online: [a.id, b.id])
            try await waitFor { ha.entries.contains { $0.text == "离线 B" } && hb.entries.contains { $0.text == "离线 A" } }
            hb.stop()
            let restored = try HistoryService(id: b.id, directory: b.directory, manager: b.manager, changed: {})
            XCTAssertEqual(restored.visibleCount, 3);
            XCTAssertEqual(restored.preferredSide, "left")
            XCTAssertTrue(restored.entries.contains { $0.text == text });
            XCTAssertEqual(ha.visibleCount, 9)
            restored.stop();
            ha.stop();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            ha.stop();
            hb.stop();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testConfiguredBluetoothInputUsesBLEWithNetworkAttached() async throws {
        let a = try SharingFixture(name: "SavedModeA", bluetoothInputOnly: true)
        let b = try SharingFixture(name: "SavedModeB", bluetoothInputOnly: true)
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            let fallback = SharingPackets()
            await b.manager.receive(channel: "input") { _, bytes in await fallback.add(bytes) }
            let initialRoute = try await a.manager.sendTracked(
                peerID: b.id, channel: "input", payload: Data("network fallback".utf8))
            XCTAssertEqual(initialRoute, "tcp");
            try await waitFor { await fallback.count == 1 }
            let blePort = b.port + 1
            try await b.manager.startBluetoothListener(port: blePort)
            _ = try await a.manager.connect(
                endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: blePort)!), pairCode: nil, password: nil,
                kind: "ble")
            let receivedA = SharingPackets(), receivedB = SharingPackets()
            await a.manager.receive(channel: "input") { _, data in await receivedA.add(data) }
            await b.manager.receive(channel: "input") { _, data in await receivedB.add(data) }
            // Both TCP and BLE remain attached; input must reach the strict receiver
            // through BLE in both directions, independent of the general network preference.
            let kindA = try await a.manager.sendTracked(
                peerID: b.id, channel: "input", payload: Data("cross to B".utf8))
            let kindB = try await b.manager.sendTracked(
                peerID: a.id, channel: "input", payload: Data("cross to A".utf8))
            XCTAssertEqual(kindA, "ble");
            XCTAssertEqual(kindB, "ble")
            await a.manager.setInputLinkPreference(bluetooth: false)
            let switched = try await a.manager.sendTracked(
                peerID: b.id, channel: "input", payload: Data("network chosen".utf8))
            XCTAssertEqual(switched, "tcp")
            await a.manager.setInputLinkPreference(bluetooth: true)
            try await waitFor {
                let countA = await receivedA.count;
                let countB = await receivedB.count;
                return countA == 1 && countB >= 1
            }
            let sessions = await a.manager.currentSessions()
            XCTAssertTrue(sessions.first?.capabilities.contains("tcp") == true)
            XCTAssertTrue(sessions.first?.capabilities.contains("ble") == true)
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testLateReverseApprovalPreservesEstablishedBluetoothLink() async throws {
        let ids = [UUID().uuidString.lowercased(), UUID().uuidString.lowercased()].sorted()
        let low = try SharingFixture(name: "Low", approvalDelay: .milliseconds(800), id: ids[0])
        let high = try SharingFixture(name: "High", id: ids[1])
        do {
            try low.registry.remember(high.identity.certificatePeer, name: "High")
            try high.registry.remember(low.identity.certificatePeer, name: "Low")
            try await low.manager.startBluetoothListener(port: low.port)
            try await high.manager.startBluetoothListener(port: high.port)
            let reverse = Task {
                try await high.manager.connect(endpoint: self.endpoint(low), pairCode: nil, password: nil, kind: "ble")
            }
            try await waitFor { low.bluetoothPrompts.value == 1 }
            _ = try await low.manager.connect(endpoint: endpoint(high), pairCode: nil, password: nil, kind: "ble")
            let before = await low.manager.currentSessions().first?.sessionID
            do {
                _ = try await reverse.value;
                XCTFail("Late opposite-direction approval replaced the already committed BLE link")
            } catch { XCTAssertTrue(error is PairingError || error is NWError) }
            let after = await low.manager.currentSessions().first?.sessionID
            XCTAssertEqual(before, after)
            let packets = SharingPackets()
            await high.manager.receive(channel: "still-live") { _, bytes in await packets.add(bytes) }
            try await low.manager.send(peerID: high.id, channel: "still-live", payload: Data("link retained".utf8))
            try await waitFor { await packets.count == 1 }
            let retained = await low.manager.currentSessions()
            XCTAssertTrue(retained.first?.capabilities.contains("ble") == true)
            await low.manager.stop();
            await high.manager.stop()
        } catch {
            await low.manager.stop();
            await high.manager.stop();
            throw error
        }
    }
    @MainActor func testReturnCrossingReleasesCaptureAndRecoversTransientPlacement() async throws {
        let a = try SharingFixture(name: "PlacementA"), b = try SharingFixture(name: "PlacementB")
        var input: InputService?
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            await b.manager.setCapability("input", enabled: true)
            let active = await a.group.active;
            let state = try XCTUnwrap(active)
            let local = try XCTUnwrap(state.layout.first { $0.peerID == a.id })
            var hidden = false, suppress = false, placements = 0
            var failure: InputAdapterError?
            var events: [String] = []
            let service = InputService(
                id: a.id, platform: "macos", manager: a.manager,
                inject: { event, _, _, _ in
                    guard event.type == "move" else { return }
                    XCTAssertFalse(hidden, "Returning placement must leave the hidden remote capture context first")
                    placements += 1
                    if let error = failure {
                        failure = nil;
                        throw error
                    }
                },
                restrict: { remote, blocked in
                    hidden = remote;
                    suppress = blocked
                }, status: { _ in }, event: { events.append($0) })
            input = service;
            await service.start()
            service.update(state, online: [a.id, b.id], sessions: await a.manager.currentSessions())
            try await service.enable()
            service.update(state, online: [a.id, b.id], sessions: await a.manager.currentSessions())
            XCTAssertTrue(service.capture(CapturedInput("move", deltaX: 8, screenID: local.id, x: 1, y: 0.5)))
            XCTAssertTrue(hidden)
            var sequence: UInt64 = 100
            func returnControl() async throws {
                sequence += 1
                var packet = InputPacket(type: "control", groupID: state.id, sourcePeerID: b.id, targetPeerID: a.id)
                packet.sequence = sequence
                packet.pointer = PointerRouter.center(local, owner: b.id, epoch: (service.pointer?.epoch ?? 0) + 1)
                try await b.manager.send(peerID: a.id, channel: "input", payload: JSONEncoder().encode(packet))
            }
            for error in [InputAdapterError.event, .display] {
                let before = placements;
                failure = error
                try await returnControl()
                try await waitFor { placements > before }
                XCTAssertEqual(placements, before + 1, "Recovery must not recursively retry failed placement")
                XCTAssertTrue(service.enabled)
                XCTAssertFalse(hidden);
                XCTAssertFalse(suppress)
                XCTAssertEqual(service.pointer?.ownerPeerID, a.id)
            }
            let recoveredPlacements = placements
            try await returnControl()
            try await waitFor { placements > recoveredPlacements }
            XCTAssertTrue(service.enabled);
            XCTAssertFalse(hidden);
            XCTAssertTrue(suppress)
            XCTAssertEqual(
                service.pointer?.ownerPeerID, b.id, "A later crossing must still work after transient recovery")
            failure = .permission
            try await returnControl();
            try await waitFor { !service.enabled }
            XCTAssertFalse(hidden);
            XCTAssertFalse(suppress)
            service.update(state, online: [a.id, b.id], sessions: await a.manager.currentSessions())
            XCTAssertFalse(service.enabled, "Permission loss must remain paused")
            XCTAssertEqual(events.filter { $0.hasPrefix("InputMovementFailed") }.count, 3)
            service.stop();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            input?.stop();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }

    @MainActor func testRestartedGroupReceivesPresenceOnUnchangedSession() async throws {
        let a = try SharingFixture(name: "PresenceA"), b = try SharingFixture(name: "PresenceB")
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            try await Task.sleep(for: .milliseconds(200))
            let before = await b.manager.currentSessions().first?.sessionID
            let observed = SharingPresence()
            b.group = try GroupManager(
                localID: b.id, name: "RestartedB", publicKey: b.identity.certificatePeer.publicKey,
                screens: [
                    ScreenGeometry(
                        id: b.id + ":test", peerID: b.id, name: "Fixture", number: 1, pixelWidth: 1000,
                        pixelHeight: 720, primary: true, x: 0, y: 0)
                ], directory: b.directory, manager: b.manager, registry: b.registry, confirm: { _ in false },
                changed: { _, _, online, _ in Task { await observed.set(online) } }, event: { _ in },
                automaticSharing: true)
            await b.group.start();
            await b.group.connectionsChanged(b.manager.currentSessions())
            try await waitFor { Set(await observed.online) == Set([a.id, b.id]) }
            let after = await b.manager.currentSessions().first?.sessionID
            XCTAssertEqual(after, before, "Presence recovery must not require a new session")
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testAttachedProcessDoesNotRetainStaleInputCapability() async throws {
        let a = try SharingFixture(name: "CapsA"), b = try SharingFixture(name: "CapsB")
        let restarted = SessionManager(
            localID: b.id, name: "RestartedB", identity: b.identity, registry: b.registry, pairCode: "123456",
            password: "fixture-secret", confirmCertificate: { _ in true }, confirmConnection: { _ in true },
            changed: { _ in }, event: { _ in })
        do {
            try await connect(a, b)
            await a.manager.setCapability("input", enabled: true);
            await b.manager.setCapability("input", enabled: true)
            try await waitFor { await a.manager.currentSessions().first?.capabilities.contains("input") == true }
            let before = await a.manager.currentSessions().first?.sessionID
            await restarted.setApplicationCapabilities(["group"])
            let port = UInt16.random(in: 45100...48000);
            try await a.manager.startBluetoothListener(port: port)
            try await Task.sleep(for: .milliseconds(100))
            _ = try await restarted.connect(
                endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!), pairCode: nil, password: nil,
                kind: "ble")
            let attached = await a.manager.currentSessions().first
            XCTAssertEqual(attached?.sessionID, before)
            XCTAssertTrue(attached?.capabilities.contains("ble") == true)
            XCTAssertFalse(
                attached?.capabilities.contains("input") == true, "Remote input is not ready in the new process")
            await restarted.stop();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            await restarted.stop();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testInputEnabledDuringBluetoothHandshakeIsPublishedAfterCommit() async throws {
        let a = try SharingFixture(name: "FreshCapsA"),
            b = try SharingFixture(name: "FreshCapsB", approvalDelay: .milliseconds(800))
        try a.registry.remember(b.identity.certificatePeer, name: "FreshCapsB")
        try b.registry.remember(a.identity.certificatePeer, name: "FreshCapsA")
        let port = UInt16.random(in: 45100...48000)
        do {
            await a.manager.setApplicationCapabilities(["group"]);
            await b.manager.setApplicationCapabilities(["group"])
            try await b.manager.startBluetoothListener(port: port)
            try await Task.sleep(for: .milliseconds(150))
            let connecting = Task {
                try await a.manager.connect(
                    endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!), pairCode: nil, password: nil,
                    kind: "ble")
            }
            // Both hello and pair have been sent with input off when approval begins.
            try await waitFor { b.bluetoothPrompts.value == 1 }
            await a.manager.setCapability("input", enabled: true);
            await b.manager.setCapability("input", enabled: true)
            _ = try await connecting.value
            try await waitFor {
                let aa = await a.manager.currentSessions().first?.capabilities.contains("input") == true
                let bb = await b.manager.currentSessions().first?.capabilities.contains("input") == true
                return aa && bb
            }
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }

    // Real TLS on both listener kinds; no physical pointer or radio automation.
    @MainActor func testUnifiedPairingOptionalKeyAndAvailability() async throws {
        for kind in ["tcp", "ble"] {
            let a = try SharingFixture(name: "OptionsA"), b = try SharingFixture(name: "OptionsB")
            let port = UInt16.random(in: 45100...48000)
            let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: port)!)
            do {
                try await b.manager.updateCredentials(pairCode: "123456", password: "")
                if kind == "ble" {
                    try await b.manager.startBluetoothListener(port: port)
                } else {
                    try await b.manager.start(port: port)
                }
                try await Task.sleep(for: .milliseconds(150))
                do {
                    _ = try await a.manager.connect(endpoint: endpoint, pairCode: "000000", password: "", kind: kind)
                    XCTFail("Wrong code accepted without optional key")
                } catch {}
                if kind == "ble" {
                    await b.manager.setBluetoothAvailable(false)
                } else {
                    await b.manager.setNetworkAvailable(false)
                }
                do {
                    _ = try await a.manager.connect(endpoint: endpoint, pairCode: "123456", password: "", kind: kind)
                    XCTFail("Disabled incoming transport accepted a connection")
                } catch {}
                if kind == "ble" {
                    await b.manager.setBluetoothAvailable(true)
                } else {
                    await b.manager.setNetworkAvailable(true)
                }
                try await b.manager.updateCredentials(pairCode: "123456", password: "fixture-secret")
                do {
                    _ = try await a.manager.connect(endpoint: endpoint, pairCode: "123456", password: "", kind: kind)
                    XCTFail("Configured key bypassed")
                } catch {}
                try await b.manager.updateCredentials(pairCode: "123456", password: "")
                _ = try await a.manager.connect(endpoint: endpoint, pairCode: "123456", password: "", kind: kind)
                let sessions = await a.manager.currentSessions()
                XCTAssertEqual(sessions.count, 1)
                XCTAssertEqual(a.registry.find(b.id)?.trust, .known)
                await a.manager.stop();
                await b.manager.stop()
            } catch {
                await a.manager.stop();
                await b.manager.stop();
                throw error
            }
        }
    }

    @MainActor func testConcurrentTransportsSharePendingApproval() async throws {
        let a = try SharingFixture(name: "ConcurrentA"),
            b = try SharingFixture(name: "ConcurrentB", approvalDelay: .milliseconds(800))
        try a.registry.remember(b.identity.certificatePeer, name: "ConcurrentB")
        try b.registry.remember(a.identity.certificatePeer, name: "ConcurrentA")
        let port = UInt16.random(in: 45100...48000)
        do {
            try await b.manager.start(port: b.port);
            try await b.manager.startBluetoothListener(port: port)
            try await Task.sleep(for: .milliseconds(150))
            let tcpEndpoint = endpoint(b)
            async let tcp = try? a.manager.connect(endpoint: tcpEndpoint, pairCode: nil, password: nil)
            async let ble = try? a.manager.connect(
                endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!), pairCode: nil, password: nil,
                kind: "ble")
            _ = await (tcp, ble)
            XCTAssertEqual(b.connectionPrompts.value + b.bluetoothPrompts.value, 1)
            let merged = await a.manager.currentSessions()
            XCTAssertEqual(merged.count, 1)
            XCTAssertTrue(merged.first?.capabilities.contains("tcp") == true)
            XCTAssertTrue(merged.first?.capabilities.contains("ble") == true)
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }

    // Exercises BLE input policy over a local authenticated fixture, not radio performance.
    @MainActor func testBLEWindowAndCrossingDoNotDrainStaleMotion() async throws {
        let a = try SharingFixture(name: "BLEPolicyA"), b = try SharingFixture(name: "BLEPolicyB")
        var input: InputService?
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            for manager in [a.manager!, b.manager!] {
                await manager.setCapability("input", enabled: true)
                await manager.setCapability("compact-input", enabled: true)
                await manager.setCapability("ble-input-v2", enabled: true)
            }
            try await waitFor { await a.manager.currentSessions().first?.capabilities.contains("ble-input-v2") == true }
            let value = await a.group.active;
            let group = try XCTUnwrap(value)
            let packets = SharingInputPackets()
            await b.manager.receive(channel: "input") { peer, bytes in
                await packets.add(bytes, group: group, source: peer, target: b.id)
            }
            let service = InputService(
                id: a.id, platform: "macos", manager: a.manager, inject: { _, _, _, _ in }, restrict: { _, _ in },
                status: { _ in })
            input = service;
            await service.start()
            var sessions = await a.manager.currentSessions()
            sessions[0].capabilities.removeAll { ["tcp", "quic"].contains($0) }
            sessions[0].capabilities.append("ble")
            service.update(group, online: [a.id, b.id], sessions: sessions);
            try await service.enable()
            let local = try XCTUnwrap(group.layout.first { $0.peerID == a.id })
            _ = service.capture(CapturedInput("move", deltaX: 8, screenID: local.id, x: 1, y: 0.5))
            for _ in 0..<40 {
                _ = service.capture(CapturedInput("move", deltaX: 1, screenID: local.id, x: 1, y: 0.5))
                try await Task.sleep(for: .milliseconds(3))
            }
            try await Task.sleep(for: .milliseconds(30))
            let before = await packets.packets
            XCTAssertEqual(before.filter { $0.type == "move" }.count, 4)
            _ = service.capture(CapturedInput("move", deltaX: -200, screenID: local.id, x: 0, y: 0.5))
            try await waitFor {
                await packets.packets.contains { $0.type == "control" && $0.pointer?.screenID == local.id }
            }
            let after = await packets.packets
            XCTAssertEqual(
                after.filter { $0.type == "move" }.count, 4, "Crossing must supersede the unsent old-screen move")
            XCTAssertEqual(after.map(\.sequence), after.map(\.sequence).sorted())
            XCTAssertTrue(service.enabled);
            service.stop();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            input?.stop();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }

    @MainActor func testAutomaticDesktopInputAndConcurrentFrames() async throws {
        let a = try SharingFixture(name: "A"), b = try SharingFixture(name: "B")
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            let initial = await a.group.active;
            let first = try XCTUnwrap(initial)
            XCTAssertEqual(a.prompts.value + b.prompts.value, 0)
            print("Regression: edit layout")
            let lock = try await a.group.beginEdit("layout")
            var arranged = first.layout;
            arranged[1].y = 100
            try await a.group.commitLayout(arranged, lock: lock);
            await a.group.release(lock)
            try await waitFor { await b.group.active?.layout == arranged }
            print("Regression: 512 frames")
            let packets = SharingPackets()
            await b.manager.receive(channel: "stress") { _, data in await packets.add(data) }
            try await withThrowingTaskGroup(of: Void.self) { tasks in
                for index in 0..<512 {
                    tasks.addTask {
                        try await a.manager.send(peerID: b.id, channel: "stress", payload: Data("\(index)".utf8))
                    }
                }
                try await tasks.waitForAll()
            }
            print("Regression: frames sent, received=\(await packets.count)")
            try await waitFor { await packets.count == 512 }
            let sessions = await a.manager.currentSessions();
            XCTAssertEqual(sessions.count, 1)
            await a.manager.setCapability("input", enabled: true)
            await b.manager.setCapability("input", enabled: true)
            try await waitFor { await a.manager.currentSessions().first?.capabilities.contains("input") == true }
            print("Regression: input")
            let inputPackets = SharingInputPackets()
            await b.manager.receive(channel: "input") { _, data in await inputPackets.add(data) }
            var injections = 0
            let input = InputService(
                id: a.id, platform: "macos", manager: a.manager, inject: { _, _, _, _ in injections += 1 },
                restrict: { _, _ in }, status: { _ in }, event: { _ in })
            let active = await a.group.active;
            let state = try XCTUnwrap(active)
            input.update(state, online: [a.id, b.id], sessions: await a.manager.currentSessions())
            try await input.enable();
            injections = 0
            let local = try XCTUnwrap(state.layout.first { $0.peerID == a.id })
            for event in [
                CapturedInput("keyDown", key: "KeyA"), CapturedInput("keyUp", key: "KeyA"), CapturedInput("buttonDown"),
                CapturedInput("buttonUp"), CapturedInput("scroll", deltaY: 30),
                CapturedInput("move", deltaX: 10, screenID: local.id, x: 0.5, y: 0.5),
            ] { XCTAssertFalse(input.capture(event)) }
            XCTAssertEqual(injections, 0, "Local input must pass through without synthetic injection")
            for key in ["KeyC", "KeyX", "KeyV", "KeyZ"] {
                for event in [
                    CapturedInput("keyDown", key: "MetaLeft"), CapturedInput("keyDown", key: key),
                    CapturedInput("keyUp", key: key), CapturedInput("keyUp", key: "MetaLeft"),
                ] { XCTAssertFalse(input.capture(event), "Local clipboard/undo chords must remain native") }
            }
            XCTAssertEqual(injections, 0, "Native shortcuts must not schedule synthetic copy/paste")
            XCTAssertTrue(input.capture(CapturedInput("move", deltaX: 8, screenID: local.id, x: 1, y: 0.5)))
            for _ in 0..<200 { _ = input.capture(CapturedInput("move", deltaX: 1, screenID: local.id, x: 1, y: 0.5)) }
            _ = input.capture(CapturedInput("buttonDown"));
            _ = input.capture(CapturedInput("buttonUp"))
            _ = input.capture(CapturedInput("keyDown", key: "KeyA"));
            _ = input.capture(CapturedInput("keyUp", key: "KeyA"))
            try await waitFor { await inputPackets.hasKeyUp }
            let received = await inputPackets.packets
            XCTAssertLessThan(received.filter { $0.type == "move" }.count, 20)
            let critical = received.filter { ["buttonDown", "buttonUp", "keyDown", "keyUp"].contains($0.type) }.map(
                \.type)
            XCTAssertEqual(critical, ["buttonDown", "buttonUp", "keyDown", "keyUp"])
            XCTAssertEqual(received.map(\.sequence), received.map(\.sequence).sorted())
            input.pause();
            XCTAssertFalse(input.capture(CapturedInput("keyDown", key: "KeyA")))
            print("Regression: reconnect")
            try a.registry.setPreferences(b.id, trusted: true, autoConnect: true)
            try b.registry.setPreferences(a.id, trusted: true, autoConnect: true)
            await a.manager.disconnect(b.id)
            try await waitFor {
                let x = await a.manager.currentSessions();
                let y = await b.manager.currentSessions();
                return x.isEmpty && y.isEmpty
            }
            _ = try await a.manager.connect(endpoint: endpoint(b), pairCode: nil, password: nil, autoOnly: true)
            try await waitFor {
                let x = await a.group.active;
                let y = await b.group.active;
                return x?.layout == arranged && y?.layout == arranged
            }
            XCTAssertEqual(b.connectionPrompts.value, 1, "AutoConnect must ask before a fresh sharing session")
            let restored = await a.group.active;
            XCTAssertEqual(restored?.id, first.id)
            let store = try JSONDecoder().decode(
                GroupStore.self, from: Data(contentsOf: a.directory.appendingPathComponent("groups.json")))
            XCTAssertEqual(store.groups.count, 1)
            await a.manager.disconnect(b.id)
            try await waitFor {
                let x = await a.manager.currentSessions();
                let y = await b.manager.currentSessions();
                return x.isEmpty && y.isEmpty
            }
            b.connectionPrompts.allowed = false
            for _ in 0..<2 {
                do {
                    _ = try await a.manager.connect(
                        endpoint: endpoint(b), pairCode: nil, password: nil, autoOnly: true);
                    XCTFail("Declined automatic connection was accepted")
                } catch { XCTAssertTrue(error is PairingError) }
            }
            XCTAssertEqual(b.connectionPrompts.value, 2, "Declining must not trigger repeated confirmation dialogs")
            _ = try await a.manager.connect(endpoint: endpoint(b), pairCode: "123456", password: "fixture-secret")
            try await waitFor { await self.sameDesktop(a, b) }
            await a.manager.disconnect(b.id)
            try await waitFor {
                let x = await a.manager.currentSessions();
                let y = await b.manager.currentSessions();
                return x.isEmpty && y.isEmpty
            }
            await a.group.connectionsChanged([]);
            await b.group.connectionsChanged([])
            try await a.group.leave();
            try await b.group.leave()
            try await a.group.create(name: "我的桌面");
            try await b.group.create(name: "我的桌面")
            _ = try await a.manager.connect(endpoint: endpoint(b), pairCode: "123456", password: "fixture-secret")
            try await waitFor {
                let x = await a.group.active;
                let y = await b.group.active;
                return x?.id == first.id && y?.id == first.id && y?.layout == arranged
            }
            let retained = try JSONDecoder().decode(
                GroupStore.self, from: Data(contentsOf: a.directory.appendingPathComponent("groups.json")))
            XCTAssertEqual(
                retained.groups.count, 2,
                "Restore should preserve both the old shared desktop and the legacy solo desktop")
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testCompactInputBackpressureDragReleaseAndTemporaryRecovery() async throws {
        let a = try SharingFixture(name: "InputA"), b = try SharingFixture(name: "InputB")
        var input: InputService?
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            try a.registry.setPreferences(b.id, trusted: false, autoConnect: true);
            try b.registry.setPreferences(a.id, trusted: false, autoConnect: true)
            await a.manager.disconnect(b.id)
            try await waitFor {
                let x = await a.manager.currentSessions();
                let y = await b.manager.currentSessions();
                return x.isEmpty && y.isEmpty
            }
            _ = try await a.manager.connect(endpoint: endpoint(b), pairCode: nil, password: nil, autoOnly: true)
            try await waitFor { await self.sameDesktop(a, b) }
            XCTAssertEqual(b.connectionPrompts.value, 1)
            for manager in [a.manager!, b.manager!] {
                await manager.setCapability("compact-input", enabled: true);
                await manager.setCapability("input", enabled: true)
            }
            try await waitFor {
                await a.manager.currentSessions().first?.capabilities.contains("compact-input") == true
            }
            let value = await a.group.active;
            let group = try XCTUnwrap(value)
            let packets = SharingInputPackets()
            await b.manager.receive(channel: "input") { peer, bytes in
                await packets.add(bytes, group: group, source: peer, target: b.id)
            }
            var sourceEvents: [CapturedInput] = []
            let service = InputService(
                id: a.id, platform: "macos", manager: a.manager, inject: { e, _, _, _ in sourceEvents.append(e) },
                restrict: { _, _ in }, status: { _ in })
            input = service;
            await service.start();
            service.update(group, online: [a.id, b.id], sessions: await a.manager.currentSessions());
            try await service.enable()
            let local = try XCTUnwrap(group.layout.first { $0.peerID == a.id })
            XCTAssertFalse(service.capture(CapturedInput("buttonDown")))
            _ = service.capture(CapturedInput("move", deltaX: 8, screenID: local.id, x: 1, y: 0.5))
            XCTAssertTrue(
                sourceEvents.contains { $0.type == "buttonUp" }, "Crossing must end the original desktop marquee/drag")
            for _ in 0..<50 {
                _ = service.capture(CapturedInput("move", deltaX: 1, screenID: local.id, x: 1, y: 0.5));
                try await Task.sleep(for: .milliseconds(2))
            }
            try await Task.sleep(for: .milliseconds(20))
            let blocked = await packets.packets
            let moves = blocked.filter { $0.type == "move" }
            XCTAssertEqual(moves.count, 8, "A receiver that has not acknowledged must not accumulate old positions")
            XCTAssertFalse(
                blocked.contains { $0.type == "buttonDown" }, "Held drag must not carry across the screen boundary")
            var ack = InputPacket(type: "motionAck", groupID: group.id, sourcePeerID: b.id, targetPeerID: a.id)
            ack.acknowledgedSequence = moves.last?.sequence
            try await b.manager.send(
                peerID: a.id, channel: "input", payload: XCTUnwrap(MotionCodec.encode(ack, layout: group.layout)))
            try await waitFor { await packets.packets.filter { $0.type == "move" }.count > 8 }
            _ = service.capture(CapturedInput("buttonDown"));
            _ = service.capture(CapturedInput("buttonUp"))
            try await waitFor { await packets.packets.contains { $0.type == "buttonUp" } }
            let delivered = await packets.packets
            XCTAssertEqual(delivered.map(\.sequence), delivered.map(\.sequence).sorted())
            var release = InputPacket(type: "release", groupID: group.id, sourcePeerID: b.id, targetPeerID: a.id);
            release.sequence = 1
            try await b.manager.send(peerID: a.id, channel: "input", payload: JSONEncoder().encode(release))
            try await waitFor { service.pointer?.screenID == local.id }
            XCTAssertTrue(service.enabled, "Temporary remote interruption must keep sharing enabled")
            let latency = try await a.manager.testLatency(peerID: b.id)
            XCTAssertEqual(latency.first?.kind, "tcp");
            XCTAssertGreaterThan(latency.first?.values.count ?? 0, 150)
            XCTAssertTrue(latency.first?.samples.allSatisfy { $0.seconds < 10.1 } == true)
            service.stop();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            input?.stop();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testContinuousMotionDoesNotEmitPeriodicRepairSnapshots() async throws {
        let a = try SharingFixture(name: "MotionA"), b = try SharingFixture(name: "MotionB")
        var input: InputService?
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            for manager in [a.manager!, b.manager!] {
                await manager.setCapability("compact-input", enabled: true);
                await manager.setCapability("input", enabled: true)
            }
            try await waitFor {
                await a.manager.currentSessions().first?.capabilities.contains("compact-input") == true
            }
            let state = await a.group.active;
            let group = try XCTUnwrap(state), packets = SharingInputPackets()
            await b.manager.receive(channel: "input") { peer, bytes in
                await packets.add(bytes, group: group, source: peer, target: b.id)
                if let move = MotionCodec.decode(bytes, group: group, source: peer, target: b.id), move.type == "move" {
                    var ack = InputPacket(type: "motionAck", groupID: group.id, sourcePeerID: b.id, targetPeerID: a.id);
                    ack.acknowledgedSequence = move.sequence
                    try? await b.manager.send(
                        peerID: a.id, channel: "input", payload: MotionCodec.encode(ack, layout: group.layout)!)
                }
            }
            let service = InputService(
                id: a.id, platform: "macos", manager: a.manager, inject: { _, _, _, _ in }, restrict: { _, _ in },
                status: { _ in })
            input = service;
            await service.start();
            service.update(group, online: [a.id, b.id], sessions: await a.manager.currentSessions());
            try await service.enable()
            let local = try XCTUnwrap(group.layout.first { $0.peerID == a.id })
            _ = service.capture(CapturedInput("move", deltaX: 8, screenID: local.id, x: 1, y: 0.5))
            try await Task.sleep(for: .milliseconds(30));
            let start = await packets.packets.count
            let until = ContinuousClock.now.advanced(by: .milliseconds(1250))
            while ContinuousClock.now < until {
                _ = service.capture(CapturedInput("move", deltaX: 0.5, screenID: local.id, x: 1, y: 0.5));
                try await Task.sleep(for: .milliseconds(2))
            }
            try await Task.sleep(for: .milliseconds(30))
            let moving = Array((await packets.packets).dropFirst(start))
            XCTAssertGreaterThan(moving.filter { $0.type == "move" }.count, 100)
            XCTAssertFalse(
                moving.contains { $0.type == "pointer" || $0.type == "held" },
                "Half-second repair must not interrupt continuous motion")
            try await waitFor { await packets.packets.dropFirst(start).contains { $0.type == "pointer" } }
            service.stop();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            input?.stop();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testDifferentLegacyDesktopsConvergeWithoutDeletingSavedGroups() async throws {
        let a = try SharingFixture(name: "A"), b = try SharingFixture(name: "B")
        do {
            try await a.group.create(name: "我的桌面");
            try await b.group.create(name: "我的桌面")
            let original = await a.group.active?.id
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            let shared = await b.group.active?.id;
            XCTAssertEqual(shared, original)
            XCTAssertEqual(a.prompts.value + b.prompts.value, 0)
            let store = try JSONDecoder().decode(
                GroupStore.self, from: Data(contentsOf: b.directory.appendingPathComponent("groups.json")))
            XCTAssertEqual(store.groups.count, 2, "Legacy saved groups must be preserved")
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testCutDirectoryAdditionsIncludeExcludeCancelBothDirections() async throws {
        let a = try SharingFixture(name: "AdditionsA"), b = try SharingFixture(name: "AdditionsB")
        let ca = ClipboardService(
            id: a.id, manager: a.manager, changed: { _ in }, event: { _ in }, directory: a.directory)
        let cb = ClipboardService(
            id: b.id, manager: b.manager, changed: { _ in }, event: { _ in }, directory: b.directory)
        var decision = "exclude", prompts = 0
        func service(_ fixture: SharingFixture, _ clipboard: ClipboardService) throws -> FileTransferService {
            try FileTransferService(
                id: fixture.id, directory: fixture.directory, manager: fixture.manager, clipboard: clipboard,
                changed: { _ in }, event: { print($0) }, sourceChanged: { _ in false },
                conflict: { _, _, _ in "overwrite" }, partialFailure: { _ in "abort" }, deleteAll: { _ in false },
                additionalFiles: { paths in
                    prompts += 1;
                    XCTAssertTrue(paths.contains { $0.hasSuffix("/new.txt") });
                    return decision
                })
        }
        let fa = try service(a, ca), fb = try service(b, cb)
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) };
            let active = await a.group.active;
            let group = try XCTUnwrap(active)
            ca.update(group, online: [a.id, b.id]);
            cb.update(group, online: [a.id, b.id])
            fa.update(group, online: [a.id, b.id], sessions: await a.manager.currentSessions());
            fb.update(group, online: [a.id, b.id], sessions: await b.manager.currentSessions())
            await ca.start();
            await cb.start();
            await fa.start();
            await fb.start()
            for reverse in [false, true] {
                let origin = reverse ? b : a, target = reverse ? a : b
                let sender = reverse ? fb : fa, receiver = reverse ? fa : fb
                let source = origin.directory.appendingPathComponent("selected-" + String(reverse)),
                    destination = target.directory.appendingPathComponent("received-" + String(reverse))
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true);
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try Data("old".utf8).write(to: source.appendingPathComponent("old.txt"))
                try await sender.copy([source.path], cut: true);
                try await waitFor { ca.current?.id == cb.current?.id }
                let moved = try await receiver.paste(destination.path)
                XCTAssertEqual(receiver.currentTasks.first { $0.id == moved }?.state, "completed")
                try await waitFor { !FileManager.default.fileExists(atPath: source.path) }
                let provider = destination.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.createDirectory(
                    at: provider.appendingPathComponent("nested"), withIntermediateDirectories: true)
                try Data("new".utf8).write(to: provider.appendingPathComponent("nested/new.txt"))
                for action in ["exclude", "cancel", "include"] {
                    decision = action;
                    let before = prompts
                    let output = origin.directory.appendingPathComponent(action + String(reverse));
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    let paste = try await sender.paste(output.path)
                    XCTAssertEqual(
                        sender.currentTasks.first { $0.id == paste }?.state,
                        action == "cancel" ? "cancelled" : "completed")
                    try await waitFor {
                        receiver.currentTasks.first { $0.id == paste }?.state
                            == (action == "cancel" ? "cancelled" : "completed")
                    }
                    XCTAssertEqual(prompts, before + 1)
                    XCTAssertEqual(
                        FileManager.default.fileExists(
                            atPath: output.appendingPathComponent(source.lastPathComponent + "/nested/new.txt").path),
                        action == "include")
                    if action == "cancel" {
                        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
                    }
                    XCTAssertTrue(
                        FileManager.default.fileExists(atPath: provider.appendingPathComponent("nested/new.txt").path),
                        "Repeat paste must keep the completed Cut provider")
                }
            }
            fa.stop();
            fb.stop();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            fa.stop();
            fb.stop();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testDirectoryStagingAndConflictFinishReachBothPeers() async throws {
        let a = try SharingFixture(name: "A"), b = try SharingFixture(name: "B")
        let ca = ClipboardService(
            id: a.id, manager: a.manager, changed: { _ in }, event: { _ in }, directory: a.directory)
        let cb = ClipboardService(
            id: b.id, manager: b.manager, changed: { _ in }, event: { _ in }, directory: b.directory)
        var decision = "overwrite"
        func service(_ fixture: SharingFixture, _ clipboard: ClipboardService) throws -> FileTransferService {
            try FileTransferService(
                id: fixture.id, directory: fixture.directory, manager: fixture.manager, clipboard: clipboard,
                changed: { _ in }, event: { print($0) }, sourceChanged: { _ in false },
                conflict: { _, _, _ in decision }, partialFailure: { _ in "abort" }, deleteAll: { _ in false })
        }
        var fa = try service(a, ca);
        let fb = try service(b, cb)
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            let group = await a.group.active
            ca.update(group, online: [a.id, b.id]);
            cb.update(group, online: [a.id, b.id])
            fa.update(group, online: [a.id, b.id], sessions: await a.manager.currentSessions());
            fb.update(group, online: [a.id, b.id], sessions: await b.manager.currentSessions())
            await ca.start();
            await cb.start();
            await fa.start();
            await fb.start()
            let source = a.directory.appendingPathComponent("selected"),
                target = b.directory.appendingPathComponent("target")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true);
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for name in ["one.txt", "中文.txt", "empty.txt"] {
                try Data((name == "empty.txt" ? "" : name).utf8).write(to: source.appendingPathComponent(name))
            }
            // Dense 0xff chunks reproduce JSONEncoder's Base64 slash expansion past 32 KiB.
            // An optional real file exercises the same full transfer without touching the original.
            let actualFile = ProcessInfo.processInfo.environment["SHAREMOUSE_LARGE_FILE_PATH"].map {
                URL(fileURLWithPath: $0)
            }
            let binaryName = actualFile?.lastPathComponent ?? "binary.apk"
            let binary = source.appendingPathComponent(binaryName)
            if let actualFile {
                try FileManager.default.copyItem(at: actualFile, to: binary)
            } else {
                try Data(repeating: 0xff, count: 2 * 1024 * 1024).write(to: binary)
            }
            try FileManager.default.createSymbolicLink(
                atPath: source.appendingPathComponent("中文链接.txt").path, withDestinationPath: "中文.txt")
            try await fa.copy([source.path], cut: false)
            try await waitFor { cb.current?.id == ca.current?.id }
            let first = try await fb.paste(target.path)
            XCTAssertEqual(fb.currentTasks.first { $0.id == first }?.state, "completed")
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: target.appendingPathComponent("selected/中文链接.txt").path), "中文.txt")
            XCTAssertEqual(
                fb.currentTasks.first { $0.id == first }?.transport, "tcp",
                "Transfer display must report the actual data link")
            for name in ["one.txt", "中文.txt", "empty.txt", binaryName] {
                XCTAssertEqual(
                    try Data(contentsOf: target.appendingPathComponent("selected/" + name)),
                    try Data(contentsOf: source.appendingPathComponent(name)))
            }
            XCTAssertFalse(
                try FileManager.default.contentsOfDirectory(atPath: target.path).contains {
                    $0.hasPrefix(".ShareMouse-")
                }, "Successful transfers must not leave staging folders")
            let received = try XCTUnwrap(
                fb.currentTasks.first { $0.id == first }?.files.first {
                    $0.item.relativePath.hasSuffix("/" + binaryName)
                })
            XCTAssertTrue(received.completed)
            let hash = try await FileStorage.hash(received.target)
            XCTAssertEqual(hash, received.item.hash)
            print(
                "PASS: encrypted large-file transfer bytes=\(received.item.size) name=\(binaryName), full contents and final SHA256 match; staging removed"
            )
            fa.stop()
            let record = a.directory.appendingPathComponent("file-transfers.json")
            let saved = try JSONDecoder().decode(FileTransferStore.self, from: Data(contentsOf: record))
            let legacy = try XCTUnwrap(saved.tasks.first { $0.id == first })
            legacy.state = "paused";
            legacy.pausedBy = nil  // Older shutdowns saved no pause owner.
            try JSONEncoder().encode(saved).write(to: record, options: .atomic)
            fa = try service(a, ca);
            fa.update(group, online: [a.id, b.id], sessions: await a.manager.currentSessions());
            await fa.start()
            received.completed = false;
            received.received = 20000
            received.partial = try FileStorage.partial(target.path, taskID: first, itemID: received.item.id)
            let original = try FileHandle(forReadingFrom: binary)
            let prefix = try XCTUnwrap(original.read(upToCount: 20000));
            try original.close()
            try prefix.write(to: URL(fileURLWithPath: received.partial))
            await fb.resume(first)
            XCTAssertEqual(fb.currentTasks.first { $0.id == first }?.state, "completed")
            try await waitFor { fa.currentTasks.first { $0.id == first }?.state == "completed" }
            let resumedHash = try await FileStorage.hash(received.target)
            XCTAssertEqual(resumedHash, received.item.hash)
            print("PASS: partial large-file resume after legacy sender restart; final SHA256 matches")
            try FileManager.default.removeItem(atPath: received.target)
            received.completed = false;
            received.received = 20000
            XCTAssertFalse(FileManager.default.fileExists(atPath: received.partial))
            await fb.resume(first)
            _ = try XCTUnwrap(
                fb.currentTasks.first { $0.id == first && $0.state == "completed" },
                "Missing partial data must restart from zero on the first retry")
            try await waitFor { fa.currentTasks.first { $0.id == first }?.state == "completed" }
            let restartedHash = try await FileStorage.hash(received.target)
            XCTAssertEqual(restartedHash, received.item.hash)
            print("PASS: missing partial data resets saved progress; first retry produces the complete original file")
            for action in ["cancel", "skip"] {
                decision = action;
                let taskID = try await fb.paste(target.path)
                let expected = action == "cancel" ? "cancelled" : "completed"
                XCTAssertEqual(fb.currentTasks.first { $0.id == taskID }?.state, expected)
                try await waitFor { fa.currentTasks.first { $0.id == taskID }?.state == expected }
            }
            fa.stop();
            fb.stop();
            ca.stop();
            cb.stop();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            fa.stop();
            fb.stop();
            ca.stop();
            cb.stop();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor private func sameDesktop(_ a: SharingFixture, _ b: SharingFixture) async -> Bool {
        let x = await a.group.active;
        let y = await b.group.active;
        return x?.members.count == 2 && x?.id == y?.id
    }
    private func endpoint(_ peer: SharingFixture) -> NWEndpoint {
        .hostPort(host: "127.0.0.1", port: .init(rawValue: peer.port)!)
    }
    @MainActor private func connect(_ a: SharingFixture, _ b: SharingFixture, directLAN: Bool = true) async throws {
        await a.group.start();
        await b.group.start()
        try await a.manager.start(port: a.port);
        try await b.manager.start(port: b.port)
        try await Task.sleep(for: .milliseconds(150))
        _ = try await a.manager.connect(
            endpoint: endpoint(b), pairCode: "123456", password: "fixture-secret", directLAN: directLAN)
    }
    @MainActor private func waitFor(_ ready: @MainActor () async -> Bool) async throws {
        let limit = Date().addingTimeInterval(12)
        while !(await ready()) {
            guard Date() < limit else { throw PairingError.timedOut };
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
extension SharingTests {
    @MainActor func testMCPDiscoveryVersionsAndDisabledAccess() async throws {
        let fixture = try SharingFixture(name: "MCPProtocol")
        let clipboard = ClipboardService(id: fixture.id, manager: fixture.manager, changed: { _ in }, event: { _ in })
        let service = ComputerUseService(
            id: fixture.id, name: "MCPProtocol", manager: fixture.manager, files: nil, clipboard: clipboard,
            screens: { [] }, info: { .object([:]) }, screenshot: { _ in .null },
            inject: { _, _, _, _ in XCTFail("Disabled access must never inject") }, suspend: { false },
            restore: { _ in }, canControl: { true })
        let server = try MCPServer(
            service: service, directory: fixture.directory, tools: Data("[{\"name\":\"open_computer\"}]".utf8))
        let meta: JSONValue = .object([
            "io.modelcontextprotocol/protocolVersion": .string("2026-07-28"),
            "io.modelcontextprotocol/clientCapabilities": .object([:]),
        ])
        var request: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("server/discover"),
            "params": .object(["_meta": meta]),
        ])
        let discovered = await server.process(request)
        XCTAssertEqual(discovered?["result"]["supportedVersions"].array.first, .string("2026-07-28"))
        XCTAssertEqual(
            discovered?["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]["name"], .string("ShareMouse"))
        request["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] = .string("2999-01-01")
        let incompatible = await server.process(request)
        XCTAssertEqual(incompatible?["error"]["code"], .number(-32022))
        request["method"] = .string("tools/call");
        request["params"] = .object([
            "name": .string("open_computer"), "arguments": .object(["peer_id": .string("local")]),
        ])
        let refused = await server.process(request)
        XCTAssertEqual(refused?["result"]["isError"], .bool(true))
        XCTAssertFalse(service.controlling)
        server.stop();
        service.stop()
    }
    @MainActor func testComputerUseTLSChunkingReplayValidationAndTakeover() async throws {
        let a = try SharingFixture(name: "ComputerA"), b = try SharingFixture(name: "ComputerB")
        let ca = ClipboardService(id: a.id, manager: a.manager, changed: { _ in }, event: { _ in })
        let cb = ClipboardService(id: b.id, manager: b.manager, changed: { _ in }, event: { _ in })
        let screen = ScreenGeometry(
            id: b.id + ":test", peerID: b.id, name: "Fixture", number: 1, pixelWidth: 1000, pixelHeight: 720,
            primary: true, x: 0, y: 0)
        let payload = Data(repeating: 42, count: 48000).base64EncodedString()
        var injected: [CapturedInput] = [], restored = false
        let target = ComputerUseService(
            id: b.id, name: "ComputerB", manager: b.manager, files: nil, clipboard: cb, screens: { [screen] },
            info: { .object([:]) },
            screenshot: { _ in
                .object([
                    "width": .number(1000), "height": .number(720), "data": .string(payload),
                    "mime_type": .string("image/png"),
                ])
            }, inject: { event, _, _, _ in injected.append(event) }, suspend: { true }, restore: { restored = $0 },
            canControl: { true })
        let source = ComputerUseService(
            id: a.id, name: "ComputerA", manager: a.manager, files: nil, clipboard: ca, screens: { [] },
            info: { .object([:]) }, screenshot: { _ in .null }, inject: { _, _, _, _ in }, suspend: { false },
            restore: { _ in }, canControl: { true })
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            target.allowComputer = true;
            await target.start();
            await source.start()
            try await waitFor {
                await a.manager.currentSessions().first?.capabilities.contains(ComputerUseService.capability) == true
            }
            let opened = try await source.tool("open_computer", arguments: .object(["peer_id": .string(b.id)]))
            XCTAssertEqual(
                opened["screenshot"]["data"].string, payload,
                "Screenshot must survive multiple authenticated business frames")
            var args: JSONValue = .object([
                "peer_id": .string(b.id), "control_session_id": opened["control_session_id"],
                "observation_id": opened["observation_id"], "request_id": .string(UUID().uuidString),
                "actions": .array([
                    .object(["type": .string("keypress"), "keys": .array([.string("CTRL"), .string("L")])]),
                    .object(["type": .string("click"), "x": .number(1000), "y": .number(0)]),
                ]),
            ])
            do {
                _ = try await source.tool("computer_action", arguments: args);
                XCTFail("Whole batch must reject coordinates outside the captured image")
            } catch { XCTAssertTrue(injected.isEmpty) }
            args["actions"] = .array([
                .object(["type": .string("keypress"), "keys": .array([.string("CTRL"), .string("L")])])
            ])
            let done = try await source.tool("computer_action", arguments: args)
            XCTAssertEqual(done["executed_actions"], .number(1));
            XCTAssertEqual(injected.count, 4)
            XCTAssertEqual(injected.last?.type, "keyUp");
            XCTAssertEqual(injected.last?.key, "ControlLeft")
            let replay = try await source.tool("computer_action", arguments: args)
            XCTAssertEqual(replay, done);
            XCTAssertEqual(injected.count, 4, "Retrying an identical request must not inject twice")
            args["request_id"] = .string(UUID().uuidString)
            do {
                _ = try await source.tool("computer_action", arguments: args);
                XCTFail("Previous screenshot is stale after a completed action")
            } catch { XCTAssertEqual(injected.count, 4) }
            args["observation_id"] = done["observation"]["observation_id"]
            args["actions"] = .array([
                .object([
                    "type": .string("drag"),
                    "path": .array([
                        .object(["x": .number(1), "y": .number(1)]), .object(["x": .number(20), "y": .number(20)]),
                        .object(["x": .number(40), "y": .number(40)]),
                    ]),
                ])
            ])
            Task {
                try? await Task.sleep(for: .milliseconds(10));
                target.endControl(reason: "user_exit")
            }
            let interrupted = try await source.tool("computer_action", arguments: args)
            XCTAssertEqual(interrupted["execution_status"], .string("interrupted"));
            XCTAssertTrue(restored);
            XCTAssertFalse(target.controlling)
            XCTAssertEqual(injected.last?.type, "buttonUp", "Explicit exit must release an in-progress drag")
            source.stop();
            target.stop();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            source.stop();
            target.stop();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
}
private final class SharingCounter: @unchecked Sendable {
    private let lock = NSLock();
    private var count = 0;
    private var accepts = true
    var allowed: Bool {
        get { lock.withLock { accepts } }
        set { lock.withLock { accepts = newValue } }
    }
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
private actor SharingPackets {
    var values: Set<Data> = [];
    var count: Int { values.count }
    func add(_ data: Data) {
        values.insert(data);
        if values.count % 100 == 0 { print("Regression received frames=\(values.count)") }
    }
}
private actor SharingPresence {
    var online: [String] = []
    func set(_ peers: [String]) { online = peers }
}
private actor SharingInputPackets {
    var packets: [InputPacket] = [];
    var hasKeyUp: Bool { packets.contains { $0.type == "keyUp" } }
    func add(_ data: Data, group: SharedGroup? = nil, source: String = "", target: String = "") {
        if let group, let packet = MotionCodec.decode(data, group: group, source: source, target: target) {
            packets.append(packet)
        } else if let packet = try? JSONDecoder().decode(InputPacket.self, from: data) {
            packets.append(packet)
        }
    }
}
private final class SharingFixture: @unchecked Sendable {
    let id: String
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ShareMouse-SharingTests-" + UUID().uuidString)
    let port = UInt16.random(in: 35000...45000)
    let registry: PeerRegistry
    let identity: IdentityKeychain
    let prompts = SharingCounter(), connectionPrompts = SharingCounter(), certificatePrompts = SharingCounter(),
        bluetoothPrompts = SharingCounter()
    var manager: SessionManager!;
    var group: GroupManager!
    init(
        name: String, approvalDelay: Duration = .zero, id: String = UUID().uuidString.lowercased(),
        bluetoothInputOnly: Bool? = nil
    ) throws {
        self.id = id
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        registry = try PeerRegistry(directory: directory);
        identity = try IdentityKeychain(peerID: id)
        manager = SessionManager(
            localID: id, name: name, identity: identity, registry: registry, pairCode: "123456",
            password: "fixture-secret",
            confirmCertificate: { [certificatePrompts] _ in
                certificatePrompts.increment();
                return true
            },
            confirmConnection: { [connectionPrompts] _ in
                connectionPrompts.increment();
                try? await Task.sleep(for: approvalDelay);
                return connectionPrompts.allowed
            },
            changed: { [weak self] sessions in
                guard let group = self?.group else { return };
                Task { await group.connectionsChanged(sessions) }
            }, event: { print(name + " session: " + $0) },
            confirmBluetoothConnection: { [bluetoothPrompts] _ in
                bluetoothPrompts.increment();
                try? await Task.sleep(for: approvalDelay);
                return bluetoothPrompts.allowed
            }, bluetoothInputOnly: bluetoothInputOnly)
        group = try GroupManager(
            localID: id, name: name, publicKey: identity.certificatePeer.publicKey,
            screens: [
                ScreenGeometry(
                    id: id + ":test", peerID: id, name: "Fixture", number: 1, pixelWidth: 1000, pixelHeight: 720,
                    primary: true, x: 0, y: 0)
            ], directory: directory, manager: manager, registry: registry,
            confirm: { [prompts] _ in
                prompts.increment();
                return false
            }, changed: { _, _, _, _ in }, event: { print(name + " group: " + $0) }, automaticSharing: true)
    }
    deinit {
        try? FileManager.default.removeItem(at: directory)
        SecItemDelete(
            [kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: "ShareMouse identity " + id]
                as CFDictionary)
        SecItemDelete(
            [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: Data(("com.sharemouse.identity." + id).utf8),
            ] as CFDictionary)
    }
}

extension SharingTests {
    @MainActor func testApprovalSurvivesUntilConcurrentHandshakeCommits() async throws {
        let a = try SharingFixture(name: "ApprovalA"), b = try SharingFixture(name: "ApprovalB")
        let queue = DispatchQueue(label: "ApprovalFixture")
        let parameters = SecureNetwork.parameters(identity: a.identity, verify: { _, done in done(true) }, queue: queue)
        let waiting = SecureNetwork(connection: NWConnection(to: endpoint(b), using: parameters), queue: queue)
        do {
            try b.registry.remember(a.identity.certificatePeer, name: "ApprovalA")
            try a.registry.remember(b.identity.certificatePeer, name: "ApprovalB")
            try await b.manager.start(port: b.port);
            try await b.manager.startBluetoothListener(port: b.port + 1)
            try await waiting.startAsync();
            _ = try await waiting.receiveAsync()
            var pair = SessionMessage(type: "pair", sourcePeerID: a.id)
            pair.targetPeerID = b.id;
            pair.mode = "known";
            pair.name = "ApprovalA";
            pair.capabilities = ["group"]
            try await waiting.sendAsync(pair)
            let accepted = try await waiting.receiveAsync();
            XCTAssertEqual(accepted.type, "accepted")
            // The first approved stream deliberately has not sent ready yet.
            _ = try await a.manager.connect(
                endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: b.port + 1)!), pairCode: nil,
                password: nil, kind: "ble")
            XCTAssertEqual(
                b.connectionPrompts.value + b.bluetoothPrompts.value, 1,
                "A second transport must reuse approval while the first handshake is awaiting ready")
            let liveID = await b.manager.currentSessions().first?.sessionID
            XCTAssertEqual(liveID, accepted.sessionID)
            var ready = SessionMessage(type: "ready", sourcePeerID: a.id);
            ready.targetPeerID = b.id;
            ready.sessionID = accepted.sessionID
            try await waiting.sendAsync(ready);
            let committed = try await waiting.receiveAsync()
            XCTAssertEqual(committed.type, "established")
            waiting.cancel();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            waiting.cancel();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testRepeatedAttachKeepsLiveStreamButNewProcessReplacesIt() async throws {
        let a = try SharingFixture(name: "AttachA"), b = try SharingFixture(name: "AttachB")
        let generation = UUID().uuidString.lowercased()
        var streams: [SecureNetwork] = []
        func prepare(instance: String, mode: String) async throws -> (SecureNetwork, SessionMessage) {
            let queue = DispatchQueue(label: "AttachFixture")
            let options = SecureNetwork.parameters(
                identity: a.identity, verify: { _, done in done(true) }, queue: queue, kind: "ble")
            let stream = SecureNetwork(
                connection: NWConnection(to: endpoint(b), using: options), queue: queue, kind: "ble")
            streams.append(stream);
            try await stream.startAsync();
            let hello = try await stream.receiveAsync()
            var pair = SessionMessage(type: "pair", sourcePeerID: a.id)
            pair.targetPeerID = b.id;
            pair.mode = mode;
            pair.instanceID = instance;
            pair.sessionID = mode == "attach" ? hello.sessionID : nil;
            pair.name = "AttachA"
            try await stream.sendAsync(pair);
            let accepted = try await stream.receiveAsync()
            XCTAssertEqual(accepted.type, "accepted")
            var ready = SessionMessage(type: "ready", sourcePeerID: a.id);
            ready.targetPeerID = b.id;
            ready.sessionID = accepted.sessionID
            try await stream.sendAsync(ready);
            return (stream, accepted)
        }
        func receivesProbe(_ stream: SecureNetwork) async throws -> Bool {
            for _ in 0..<12 {
                let packet = try await stream.receiveAsync();
                if packet.channel == "retained" { return packet.payload == Data("alive".utf8) }
            }
            return false
        }
        do {
            try b.registry.remember(a.identity.certificatePeer, name: "AttachA")
            try await b.manager.startBluetoothListener(port: b.port)
            let (first, _) = try await prepare(instance: generation, mode: "known")
            let firstCommit = try await first.receiveAsync();
            XCTAssertEqual(firstCommit.type, "established")
            let (duplicate, _) = try await prepare(instance: generation, mode: "attach")
            do {
                _ = try await duplicate.receiveAsync();
                XCTFail("Same-process attach replaced the healthy stream")
            } catch {}
            try await b.manager.send(peerID: a.id, channel: "retained", payload: Data("alive".utf8))
            let retained = try await receivesProbe(first);
            XCTAssertTrue(retained)
            let (restarted, _) = try await prepare(instance: UUID().uuidString.lowercased(), mode: "attach")
            let restartCommit = try await restarted.receiveAsync();
            XCTAssertEqual(restartCommit.type, "established")
            try await b.manager.send(peerID: a.id, channel: "retained", payload: Data("alive".utf8))
            let restored = try await receivesProbe(restarted);
            XCTAssertTrue(restored)
            XCTAssertEqual(b.bluetoothPrompts.value, 1)
            streams.forEach { $0.cancel() };
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            streams.forEach { $0.cancel() };
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
}

extension SharingTests {
    @MainActor func testNewProcessResetsInputSequenceOnRetainedSession() async throws {
        let a = try SharingFixture(name: "InputEpochA"), b = try SharingFixture(name: "InputEpochB")
        let input = InputService(
            id: a.id, platform: "macos", manager: a.manager, inject: { _, _, _, _ in }, restrict: { _, _ in },
            status: { _ in })
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            await b.manager.setCapability("input", enabled: true)
            await input.start()
            let value = await a.group.active;
            let state = try XCTUnwrap(value)
            var sessions = await a.manager.currentSessions()
            input.update(state, online: [a.id, b.id], sessions: sessions);
            try await input.enable()
            try await waitFor { await a.manager.currentSessions().first?.capabilities.contains("input") == true }
            sessions = await a.manager.currentSessions();
            input.update(state, online: [a.id, b.id], sessions: sessions)
            let local = try XCTUnwrap(state.layout.first { $0.peerID == a.id })
            var packet = InputPacket(type: "control", groupID: state.id, sourcePeerID: b.id, targetPeerID: a.id)
            packet.sequence = 100;
            packet.pointer = PointerRouter.center(local, owner: b.id, epoch: 100)
            try await b.manager.send(peerID: a.id, channel: "input", payload: JSONEncoder().encode(packet))
            try await waitFor { input.pointer?.ownerPeerID == b.id && input.pointer?.epoch == 100 }
            sessions[0].remoteInstanceID = UUID().uuidString.lowercased()
            input.update(state, online: [a.id, b.id], sessions: sessions)
            XCTAssertEqual(input.pointer?.ownerPeerID, a.id, "Restart must release stale remote control")
            packet.sequence = 1;
            packet.pointer = PointerRouter.center(local, owner: b.id, epoch: (input.pointer?.epoch ?? 0) + 1)
            try await b.manager.send(peerID: a.id, channel: "input", payload: JSONEncoder().encode(packet))
            try await waitFor { input.pointer?.ownerPeerID == b.id }
            XCTAssertTrue(input.enabled)
            input.stop();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            input.stop();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
}

extension SharingTests {
    @MainActor func testDualLinkCapabilitySnapshotsCannotRollBack() async throws {
        let a = try SharingFixture(name: "OrderedA", bluetoothInputOnly: true)
        let b = try SharingFixture(name: "OrderedB", bluetoothInputOnly: true)
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            try await b.manager.startBluetoothListener(port: b.port + 1)
            _ = try await a.manager.connect(
                endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: b.port + 1)!), pairCode: nil,
                password: nil, kind: "ble")
            let flags: [String: Bool] = [
                "input": true, "compact-input": true, "ble-input-v2": true, "remote-computer-v1": true,
            ]
            await a.manager.setCapabilities(flags);
            await b.manager.setCapabilities(flags)
            try await waitFor { await a.manager.currentSessions().first?.capabilities.contains("input") == true }
            let saved = await a.manager.currentSessions().first!
            let enabled = Set(saved.capabilities).subtracting(["tcp", "ble", "quic"])
            await a.manager.applyRemoteCapabilities(b.id, values: enabled.subtracting(["input"]), sequence: 80000)
            await a.manager.applyRemoteCapabilities(b.id, values: enabled, sequence: 79999)
            await a.manager.applyRemoteCapabilities(b.id, values: enabled, sequence: 80000)
            let paused = await a.manager.currentSessions().first!
            XCTAssertFalse(
                paused.capabilities.contains("input"),
                "Delayed/duplicate BLE snapshot must not undo the newer TCP pause")
            XCTAssertTrue(paused.capabilities.contains("ble-input-v2"));
            XCTAssertTrue(paused.capabilities.contains("remote-computer-v1"))
            XCTAssertTrue(paused.capabilities.contains("ble") && paused.capabilities.contains("tcp"))
            XCTAssertEqual(paused.sessionID, saved.sessionID)
            await a.manager.applyRemoteCapabilities(b.id, values: enabled, sequence: 80001)
            let resumed = await a.manager.currentSessions().first!
            XCTAssertTrue(resumed.capabilities.contains("input"));
            XCTAssertEqual(resumed.sessionID, saved.sessionID)
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testRepeatedInputReconnectKeepsCompactMotionAndMCPAlive() async throws {
        let a = try SharingFixture(name: "ReconnectA", bluetoothInputOnly: true)
        let b = try SharingFixture(name: "ReconnectB", bluetoothInputOnly: true)
        let service = InputService(
            id: a.id, platform: "macos", manager: a.manager, inject: { _, _, _, _ in }, restrict: { _, _ in },
            status: { _ in })
        let ca = ClipboardService(id: a.id, manager: a.manager, changed: { _ in }, event: { _ in })
        let cb = ClipboardService(id: b.id, manager: b.manager, changed: { _ in }, event: { _ in })
        let source = ComputerUseService(
            id: a.id, name: "ReconnectA", manager: a.manager, files: nil, clipboard: ca, screens: { [] },
            info: { .object(["marker": .string("A")]) }, screenshot: { _ in .null }, inject: { _, _, _, _ in },
            suspend: { false }, restore: { _ in }, canControl: { true })
        let targetScreen = ScreenGeometry(
            id: b.id + ":test", peerID: b.id, name: "Fixture", number: 1, pixelWidth: 1000, pixelHeight: 720,
            primary: true, x: 0, y: 0)
        let target = ComputerUseService(
            id: b.id, name: "ReconnectB", manager: b.manager, files: nil, clipboard: cb, screens: { [targetScreen] },
            info: { .object(["marker": .string("B")]) },
            screenshot: { _ in .object(["width": .number(1000), "height": .number(720)]) }, inject: { _, _, _, _ in },
            suspend: {
                Task { await b.manager.setCapability("input", enabled: false) };
                return true
            }, restore: { _ in Task { await b.manager.setCapability("input", enabled: true) } }, canControl: { true })
        source.allowComputer = true;
        target.allowComputer = true
        let packets = SharingInputPackets()
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            try await b.manager.startBluetoothListener(port: b.port + 1)
            _ = try await a.manager.connect(
                endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: b.port + 1)!), pairCode: nil,
                password: nil, kind: "ble")
            let current = await a.group.active;
            let state = try XCTUnwrap(current)
            await b.manager.setCapabilities(["input": true, "compact-input": true, "ble-input-v2": true])
            await source.start();
            await target.start();
            await service.start();
            await service.start()
            service.update(state, online: [a.id, b.id], sessions: await a.manager.currentSessions());
            try await service.enable()
            try await waitFor { await a.manager.currentSessions().first?.capabilities.contains("input") == true }
            await b.manager.receive(channel: "input") { peer, bytes in
                await packets.add(bytes, group: state, source: peer, target: b.id)
                if let packet = MotionCodec.decode(bytes, group: state, source: peer, target: b.id),
                    packet.type == "move"
                {
                    var ack = InputPacket(type: "motionAck", groupID: state.id, sourcePeerID: b.id, targetPeerID: a.id);
                    ack.acknowledgedSequence = packet.sequence
                    if let data = MotionCodec.encode(ack, layout: state.layout) {
                        try? await b.manager.send(peerID: a.id, channel: "input", payload: data)
                    }
                }
            }
            for _ in 0..<20 {
                service.pause();
                service.update(state, online: [a.id, b.id], sessions: await a.manager.currentSessions());
                try await service.enable()
            }
            service.update(state, online: [a.id, b.id], sessions: await a.manager.currentSessions())
            try await Task.sleep(for: .milliseconds(120))
            let before = await packets.packets.filter { $0.type == "priority" }.count
            for _ in 0..<36 {
                service.update(state, online: [a.id, b.id], sessions: await a.manager.currentSessions())
            }
            try await Task.sleep(for: .milliseconds(120))
            let after = await packets.packets.filter { $0.type == "priority" }.count
            XCTAssertEqual(after, before, "Unchanged connection/UI refresh must not fill BLE with priority packets")
            let opened = try await source.tool("open_computer", arguments: .object(["peer_id": .string(b.id)]))
            try await waitFor { await a.manager.currentSessions().first?.capabilities.contains("input") == false }
            for _ in 0..<6 {
                service.pause();
                service.update(state, online: [a.id, b.id], sessions: await a.manager.currentSessions());
                try await service.enable()
                let info = try await source.tool("get_computer_info", arguments: .object(["peer_id": .string(b.id)]));
                XCTAssertEqual(info["marker"], .string("B"))
                let reverse = try await target.tool(
                    "get_computer_info", arguments: .object(["peer_id": .string(a.id)]));
                XCTAssertEqual(reverse["marker"], .string("A"))
                XCTAssertTrue(target.controlling, "Input reconnect must not end the MCP lease")
            }
            _ = try await source.tool(
                "close_computer",
                arguments: .object(["peer_id": .string(b.id), "control_session_id": opened["control_session_id"]]))
            try await waitFor { await a.manager.currentSessions().first?.capabilities.contains("input") == true }
            service.update(state, online: [a.id, b.id], sessions: await a.manager.currentSessions())
            let local = try XCTUnwrap(state.layout.first { $0.peerID == a.id })
            let dx = state.layout.first { $0.peerID == b.id }!.x > local.x ? 8.0 : -8.0
            _ = service.capture(CapturedInput("move", deltaX: dx, screenID: local.id, x: dx > 0 ? 1 : 0, y: 0.5))
            for _ in 0..<80 {
                _ = service.capture(
                    CapturedInput("move", deltaX: dx > 0 ? 0.5 : -0.5, screenID: local.id, x: dx > 0 ? 1 : 0, y: 0.5));
                try await Task.sleep(for: .milliseconds(3))
            }
            try await waitFor { await packets.packets.filter { $0.type == "move" }.count > 40 }
            let heldBefore = await packets.packets.filter { $0.type == "held" }.count
            try await Task.sleep(for: .milliseconds(1200))
            let heldIdle = await packets.packets.filter { $0.type == "held" }.count
            XCTAssertEqual(heldIdle, heldBefore, "Empty repair must not repeatedly fill the idle BLE stream")
            _ = service.capture(CapturedInput("keyDown", key: "ShiftLeft"))
            try await waitFor {
                await packets.packets.contains { $0.type == "held" && $0.keys?.contains("ShiftLeft") == true }
            }
            _ = service.capture(CapturedInput("keyUp", key: "ShiftLeft"))
            try await waitFor { await packets.packets.filter { $0.type == "held" }.count > heldIdle + 1 }
            let lastHeld = await packets.packets.last { $0.type == "held" }
            XCTAssertEqual(lastHeld?.keys, [], "The changed empty state must still clear held input")
            XCTAssertTrue(service.enabled);
            XCTAssertFalse(target.controlling)
            let links = await a.manager.currentSessions();
            XCTAssertEqual(links.count, 1)
            XCTAssertTrue(links[0].capabilities.contains("tcp") && links[0].capabilities.contains("ble"))
            service.stop();
            source.stop();
            target.stop();
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            service.stop();
            source.stop();
            target.stop();
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
}

extension SharingTests {
    @MainActor func testBLEFirstBulkWaitsForNetworkWithoutBlockingInputAndStillFallsBack() async throws {
        let a = try SharingFixture(name: "BulkA", bluetoothInputOnly: true)
        let b = try SharingFixture(name: "BulkB", bluetoothInputOnly: true)
        let history = SharingPackets(), input = SharingPackets()
        do {
            await a.group.start();
            await b.group.start()
            try await b.manager.startBluetoothListener(port: b.port + 1)
            _ = try await a.manager.connect(
                endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: b.port + 1)!), pairCode: "123456",
                password: "fixture-secret", kind: "ble")
            await b.manager.receive(channel: "history") { _, data in await history.add(data) }
            await b.manager.receive(channel: "input") { _, data in await input.add(data) }
            let bulk = Task {
                try await a.manager.sendTracked(
                    peerID: b.id, channel: "history", payload: Data(repeating: 42, count: 3000))
            }
            try await Task.sleep(for: .milliseconds(150))
            let notYet = await history.count;
            XCTAssertEqual(notYet, 0, "History must not fill BLE while TCP is attaching")
            let kind = try await a.manager.sendTracked(peerID: b.id, channel: "input", payload: Data("input now".utf8));
            XCTAssertEqual(kind, "ble")
            try await waitFor { await input.count == 1 }
            try await b.manager.start(port: b.port)
            _ = try await a.manager.connect(endpoint: endpoint(b), pairCode: nil, password: nil)
            let route = try await bulk.value;
            XCTAssertEqual(route, "tcp")
            try await waitFor { await history.count == 1 }
            let sessions = await a.manager.currentSessions();
            XCTAssertEqual(sessions.count, 1)
            XCTAssertTrue(sessions[0].capabilities.contains("ble") && sessions[0].capabilities.contains("tcp"))
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
        let c = try SharingFixture(name: "FallbackA", bluetoothInputOnly: true)
        let d = try SharingFixture(name: "FallbackB", bluetoothInputOnly: true)
        do {
            await c.group.start();
            await d.group.start();
            try await d.manager.startBluetoothListener(port: d.port + 1)
            _ = try await c.manager.connect(
                endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: d.port + 1)!), pairCode: "123456",
                password: "fixture-secret", kind: "ble")
            await d.manager.receive(channel: "history") { _, _ in }
            let began = ContinuousClock.now
            let fallback = try await c.manager.sendTracked(peerID: d.id, channel: "history", payload: Data([1]))
            XCTAssertEqual(fallback, "ble");
            XCTAssertLessThan(
                began.duration(to: .now), .seconds(6), "Network grace must have a bounded BLE-only fallback")
            await c.manager.setNetworkAvailable(false)
            let direct = ContinuousClock.now
            _ = try await c.manager.sendTracked(peerID: d.id, channel: "history", payload: Data([2]))
            XCTAssertLessThan(direct.duration(to: .now), .milliseconds(500))
            await c.manager.stop();
            await d.manager.stop()
        } catch {
            await c.manager.stop();
            await d.manager.stop();
            throw error
        }
    }
}
extension SharingTests {
    @MainActor func testKeyboardConflictCopyPreservesBothLibraries() async throws {
        let a = try SharingFixture(name: "ConfigA"), b = try SharingFixture(name: "ConfigB")
        let id = UUID().uuidString.lowercased()
        let local = KeyboardConfig(
            id: id, ownerPeerID: a.id, name: "共同配置", windowsToMac: ["KeyA": "KeyB"], macToWindows: [:], revision: 2,
            modified: 1000)
        var remote = local;
        remote.windowsToMac = ["KeyA": "KeyC"];
        remote.modified = 2000
        let aLibrary = await a.group.keyboardLibrary, bLibrary = await b.group.keyboardLibrary
        try await a.group.saveKeyboardLibrary(aLibrary + [local], selected: id)
        try await b.group.saveKeyboardLibrary(bLibrary + [remote], selected: id)
        await a.group.setConfigConfirmation { _, _, _ in "skip" }
        await b.group.setConfigConfirmation { _, offered, existing in
            if offered.id == id {
                XCTAssertEqual(existing?.windowsToMac["KeyA"], "KeyC");
                return "copy"
            };
            return "skip"
        }
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            try await waitFor {
                let state = await b.group.active, other = await a.group.active;
                return state?.configs.first { $0.id == state?.currentConfigID }?.name == "共同配置（副本）"
                    && state?.currentConfigID == other?.currentConfigID
            }
            let values = await b.group.keyboardLibrary
            XCTAssertTrue(values.contains { $0.id == bLibrary[0].id }, "Unrelated local configuration was deleted")
            XCTAssertEqual(values.first { $0.id == id }?.windowsToMac["KeyA"], "KeyC")
            XCTAssertEqual(values.first { $0.name == "共同配置（副本）" }?.windowsToMac["KeyA"], "KeyB")
            let active = await b.group.active, other = await a.group.active
            XCTAssertEqual(active?.currentConfigID, other?.currentConfigID)
            XCTAssertEqual(active?.configs.first { $0.id == active?.currentConfigID }?.name, "共同配置（副本）")
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testTrustedIsReceiverPrivilegeAndManualQuickOverridesAutoDecline() async throws {
        let a = try SharingFixture(name: "TrustA"), b = try SharingFixture(name: "TrustB")
        do {
            try await connect(a, b);
            try await waitFor { await self.sameDesktop(a, b) }
            try b.registry.setPreferences(a.id, trusted: true, autoConnect: false)
            try a.registry.setPreferences(b.id, trusted: false, autoConnect: false)
            await a.manager.disconnect(b.id);
            try await waitFor {
                let x = await a.manager.currentSessions(), y = await b.manager.currentSessions();
                return x.isEmpty && y.isEmpty
            }
            do {
                _ = try await b.manager.connect(endpoint: endpoint(a), pairCode: nil, password: nil, quickOnly: true);
                XCTFail("Reverse quick connection ignored receiver trust")
            } catch {}
            _ = try await a.manager.connect(endpoint: endpoint(b), pairCode: nil, password: nil, quickOnly: true)
            await a.manager.disconnect(b.id);
            try await waitFor {
                let x = await a.manager.currentSessions(), y = await b.manager.currentSessions();
                return x.isEmpty && y.isEmpty
            }
            try a.registry.setPreferences(b.id, trusted: true, autoConnect: true)
            b.connectionPrompts.allowed = false
            do {
                _ = try await a.manager.connect(endpoint: endpoint(b), pairCode: nil, password: nil, autoOnly: true);
                XCTFail("Rejected automatic connection accepted")
            } catch {}
            let declined = await a.manager.autoConnectionDeclined(b.id);
            XCTAssertTrue(declined)
            b.connectionPrompts.allowed = true
            _ = try await a.manager.connect(endpoint: endpoint(b), pairCode: nil, password: nil, quickOnly: true)
            let connected = await a.manager.currentSessions();
            XCTAssertEqual(connected.count, 1)
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
    @MainActor func testPureBluetoothInitialHandshakeNeedsNoPassword() async throws {
        let a = try SharingFixture(name: "PureBLEA"), b = try SharingFixture(name: "PureBLEB")
        do {
            try await b.manager.updateCredentials(pairCode: "123456", password: "")
            await a.manager.setNetworkAvailable(false);
            await b.manager.setNetworkAvailable(false)
            try await b.manager.startBluetoothListener(port: b.port)
            _ = try await a.manager.connect(endpoint: endpoint(b), pairCode: "123456", password: nil, kind: "ble")
            XCTAssertEqual(b.bluetoothPrompts.value, 1);
            XCTAssertEqual(a.certificatePrompts.value, 0)
            let sessions = await a.manager.currentSessions();
            XCTAssertEqual(sessions.count, 1);
            XCTAssertTrue(sessions[0].capabilities.contains("ble"));
            XCTAssertFalse(sessions[0].capabilities.contains("tcp"))
            await a.manager.stop();
            await b.manager.stop()
        } catch {
            await a.manager.stop();
            await b.manager.stop();
            throw error
        }
    }
}
