import Foundation
import Security
import XCTest

@testable import ShareMouseCore

final class ComputerUseQualityTests: XCTestCase {
    @MainActor func testNativeResolutionAndExplicitCaps() async throws {
        try ComputerUseService.validateObservationOptions(.object([:]))
        for cap in [0, 1, 1600, 3840, 16384] {
            try ComputerUseService.validateObservationOptions(.object(["max_dimension": .number(Double(cap))]))
        }
        for cap in [-1.0, 16385.0, 1.5] {
            XCTAssertThrowsError(
                try ComputerUseService.validateObservationOptions(.object(["max_dimension": .number(cap)]))
            ) { error in XCTAssertEqual(error.localizedDescription, "invalid_max_dimension") }
        }
    }
    @MainActor func testIndependentTargetContextAndNoForegroundFallback() async throws {
        let fixture = try Fixture();
        defer { fixture.cleanup() }
        let opened = try await fixture.service.tool(
            "open_computer",
            arguments: .object([
                "peer_id": .string("local"), "control_mode": .string("independent"), "application": .string("QA"),
            ]))
        XCTAssertEqual(opened["control_mode"], .string("independent"));
        XCTAssertEqual(opened["input_sharing_isolated"], .bool(true));
        XCTAssertEqual(fixture.suspends, 1);
        XCTAssertEqual(fixture.capturedContext["mode"], .string("independent"))
        fixture.window = "user-foreground-changed"
        var request: JSONValue = .object([
            "peer_id": .string("local"), "control_session_id": opened["control_session_id"],
            "observation_id": opened["observation_id"], "expected_window_id": .string("background-target"),
            "actions": .array([fixture.move]),
        ])
        let moved = try await fixture.service.tool("computer_action", arguments: request);
        XCTAssertEqual(moved["execution_status"], .string("injected"));
        XCTAssertEqual(fixture.window, "user-foreground-changed")
        request["observation_id"] = moved["observation"]["observation_id"];
        request["actions"] = .array([
            .object(["type": .string("focus_application"), "application": .string("different-app")])
        ])
        do {
            _ = try await fixture.service.tool("computer_action", arguments: request);
            XCTFail("Independent mode focused an app")
        } catch { XCTAssertEqual(error.localizedDescription, "independent_action_not_supported") };
        XCTAssertEqual(fixture.events.count, 1)
        fixture.service.endControl();
        XCTAssertEqual(fixture.restores, 1)
        let count = fixture.captures
        do {
            _ = try await fixture.service.tool(
                "open_computer", arguments: .object(["peer_id": .string("local"), "control_mode": .number(1)]));
            XCTFail("Invalid mode acquired control")
        } catch { XCTAssertEqual(error.localizedDescription, "invalid_control_mode") }
        XCTAssertEqual(fixture.suspends, 1);
        XCTAssertEqual(fixture.captures, count);
        XCTAssertFalse(fixture.service.controlling)
        await fixture.manager.stop()
    }
    @MainActor func testReadOnlyTextLeaseCropAndLowercaseKeys() async throws {
        let fixture = try Fixture();
        defer { fixture.cleanup() }
        let read: JSONValue = .object([
            "peer_id": .string("local"), "read_screen": .bool(true), "text_only": .bool(true),
        ])
        let text = try await fixture.service.tool("get_computer_info", arguments: read)
        XCTAssertEqual(text["observation"]["read_only"], .bool(true));
        XCTAssertFalse(fixture.service.controlling)
        _ = try await fixture.open();
        fixture.time = fixture.time.addingTimeInterval(5)
        let before = try await fixture.service.tool("get_control_status", arguments: fixture.args)
        _ = try await fixture.service.tool("get_computer_info", arguments: read)
        let after = try await fixture.service.tool("get_control_status", arguments: fixture.args)
        XCTAssertEqual(before["latest_observation_id"], after["latest_observation_id"]);
        XCTAssertEqual(before["lease_remaining_ms"], after["lease_remaining_ms"])
        var crop = fixture.args;
        crop["capture_region"] = .object([
            "x": .number(0.25), "y": .number(0.25), "width": .number(0.5), "height": .number(0.5),
        ])
        let image = try await fixture.service.tool("observe_computer", arguments: crop);
        fixture.args["observation_id"] = image["observation_id"]
        var request = fixture.args;
        request["actions"] = .array([
            .object(["type": .string("move"), "x": .number(500), "y": .number(360)]),
            .object(["type": .string("keypress"), "keys": .array([.string("delete")])]),
        ])
        _ = try await fixture.run(request);
        XCTAssertEqual(fixture.positions.last?.0, 0.5);
        XCTAssertEqual(fixture.positions.last?.1, 0.5);
        XCTAssertTrue(fixture.events.contains { $0.type == "keyDown" && $0.key == "Delete" })
        var invalid = read;
        invalid["capture_region"] = .object([
            "x": .number(0.9), "y": .number(0), "width": .number(0.5), "height": .number(0.5),
        ])
        let captures = fixture.captures
        do {
            _ = try await fixture.service.tool("get_computer_info", arguments: invalid);
            XCTFail("Invalid crop accepted")
        } catch { XCTAssertEqual(error.localizedDescription, "invalid_capture_region") };
        XCTAssertEqual(fixture.captures, captures)
        await fixture.manager.stop()
    }
    @MainActor func testCoordinatesErrorsCheckpointsAndRelativeMotion() async throws {
        let fixture = try Fixture();
        defer { fixture.cleanup() }
        let opened = try await fixture.open();
        let mapped = opened["input_state"]["cursor_position_screenshot"]
        XCTAssertEqual(mapped["x"], .number(500));
        XCTAssertEqual(mapped["y"], .number(360));
        XCTAssertEqual(opened["coordinate_transform"]["desktop_bounds"]["x"], .number(-2560))
        let status = try await fixture.service.tool("get_control_status", arguments: fixture.args)
        XCTAssertEqual(status["latest_observation_id"], opened["observation_id"]);
        XCTAssertEqual(status["renews_lease"], .bool(false));
        XCTAssertEqual(fixture.captures, 1)
        var bad = fixture.args;
        bad["observation_id"] = .string("wrong");
        bad["actions"] = .array([fixture.move])
        do {
            _ = try await fixture.service.tool("computer_action", arguments: bad);
            XCTFail("Wrong observation accepted")
        } catch {
            let details = ComputerUseService.errorDetails(error);
            XCTAssertEqual(details["code"], .string("observation_id_mismatch"));
            XCTAssertEqual(details["input_outcome"], .string("not_attempted"));
            XCTAssertEqual(details["expected_observation_id"], opened["observation_id"])
        }
        XCTAssertTrue(fixture.events.isEmpty)
        bad = fixture.args;
        bad["actions"] = .array([fixture.move]);
        bad["ocr_region"] = .object(["x": .number(900), "y": .number(0), "width": .number(200), "height": .number(10)])
        do {
            _ = try await fixture.service.tool("computer_action", arguments: bad);
            XCTFail("Invalid analysis region accepted")
        } catch { XCTAssertEqual(error.localizedDescription, "analysis_region_outside_observation") };
        XCTAssertTrue(fixture.events.isEmpty)
        fixture.window = "B";
        var request = fixture.args;
        request["actions"] = .array([fixture.move]);
        request["require_same_window"] = .bool(true)
        let rejected = try await fixture.run(request);
        XCTAssertEqual(rejected["error"], .string("target_window_changed"));
        XCTAssertEqual(rejected["executed_actions"], .number(0));
        XCTAssertTrue(fixture.service.controlling);
        XCTAssertTrue(fixture.events.isEmpty)
        request = fixture.args;
        request["actions"] = .array([
            fixture.move, .object(["type": .string("click"), "x": .number(20), "y": .number(20)]),
        ]);
        request["checkpoint_after"] = .number(1);
        request["step_images"] = .bool(true);
        request["settle_ms"] = .number(0);
        request["request_id"] = .string(UUID().uuidString)
        let checkpoint = try await fixture.run(request);
        XCTAssertEqual(checkpoint["execution_status"], .string("checkpoint"));
        XCTAssertEqual(checkpoint["remaining_actions"], .number(1));
        XCTAssertEqual(fixture.events.count, 1);
        XCTAssertEqual(checkpoint["step_results"].array[0]["screenshot"]["width"], .number(320))
        let captures = fixture.captures;
        let replay = try await fixture.service.tool("computer_action", arguments: request);
        XCTAssertEqual(replay, checkpoint);
        XCTAssertEqual(fixture.captures, captures);
        XCTAssertEqual(fixture.events.count, 1)
        request = fixture.args;
        request["actions"] = .array([
            .object(["type": .string("move_relative"), "dx": .number(250), "dy": .number(-50), "steps": .number(30)])
        ]);
        _ = try await fixture.run(request)
        let relative = fixture.events.filter { $0.type == "relativeMove" };
        XCTAssertEqual(relative.count, 30);
        XCTAssertEqual(relative.reduce(0) { $0 + $1.deltaX }, 250);
        XCTAssertEqual(relative.reduce(0) { $0 + $1.deltaY }, -50)
        await fixture.manager.stop()
    }
    @MainActor func testOccupancyPermissionErrorsAndExpiredOpenRecovery() async throws {
        let fixture = try Fixture();
        defer { fixture.cleanup() }
        let opened = try await fixture.open();
        fixture.time = fixture.time.addingTimeInterval(5)
        let info = try await fixture.service.tool(
            "get_computer_info", arguments: .object(["peer_id": .string("local")]))
        XCTAssertEqual(info["control_state"]["open_blocker"], .string("computer_control_in_use"));
        XCTAssertEqual(info["control_state"]["lease_remaining_ms"], .number(595000))
        XCTAssertNil(info["control_state"].object["control_session_id"]);
        XCTAssertEqual(fixture.captures, 1)
        do {
            _ = try await fixture.open();
            XCTFail("Existing session was replaced")
        } catch {
            let details = ComputerUseService.errorDetails(error);
            XCTAssertEqual(details["code"], .string("computer_control_in_use"));
            XCTAssertEqual(details["next_step"], .string("use_existing_session_or_wait_for_release"));
            XCTAssertEqual(details["input_outcome"], .string("not_attempted"))
        }
        let status = try await fixture.service.tool("get_control_status", arguments: fixture.args)
        XCTAssertEqual(status["latest_observation_id"], opened["observation_id"]);
        XCTAssertEqual(status["lease_remaining_ms"], .number(595000))
        fixture.time = fixture.time.addingTimeInterval(596)
        let fresh = try await fixture.open();
        XCTAssertNotEqual(fresh["control_session_id"], opened["control_session_id"]);
        XCTAssertEqual(fixture.captures, 2)
        fixture.service.endControl();
        fixture.available = false;
        fixture.permissions = .object(["desktop_available": .bool(false)])
        do {
            _ = try await fixture.open();
            XCTFail("Locked desktop accepted")
        } catch {
            XCTAssertEqual(ComputerUseService.errorDetails(error)["code"], .string("desktop_locked_or_unavailable"))
        }
        fixture.permissions = .object(["desktop_available": .bool(true), "input_injection": .bool(false)])
        do {
            _ = try await fixture.open();
            XCTFail("Missing input permission accepted")
        } catch { XCTAssertEqual(ComputerUseService.errorDetails(error)["code"], .string("input_permission_missing")) }
        fixture.available = true;
        fixture.permissions = .object(["screen_capture": .bool(false)])
        do {
            _ = try await fixture.open();
            XCTFail("Missing screenshot permission accepted")
        } catch {
            XCTAssertEqual(ComputerUseService.errorDetails(error)["code"], .string("screen_capture_permission_missing"))
        }
        XCTAssertEqual(fixture.captures, 2);
        XCTAssertFalse(fixture.service.controlling);
        XCTAssertTrue(fixture.events.isEmpty)
        await fixture.manager.stop()
    }
    @MainActor func testPointerPreviewIsPathIndependentAndCancellableBeforeInjection() async throws {
        let fixture = try Fixture();
        defer { fixture.cleanup() };
        _ = try await fixture.open();
        fixture.previewMilliseconds = 100
        var request = fixture.args;
        request["actions"] = .array([
            .object(["type": .string("click"), "x": .number(10), "y": .number(20)]),
            .object(["type": .string("double_click"), "x": .number(30), "y": .number(40)]),
            .object([
                "type": .string("drag"),
                "path": .array([
                    .object(["x": .number(20), "y": .number(20)]), .object(["x": .number(30), "y": .number(30)]),
                ]),
            ]), .object(["type": .string("move_relative"), "dx": .number(5), "dy": .number(0), "steps": .number(1)]),
        ])
        _ = try await fixture.run(request)
        XCTAssertEqual(fixture.previews, ["click", "double_click"]);
        XCTAssertEqual(fixture.events.filter { $0.type == "move" }.count, 4);
        XCTAssertEqual(fixture.events.filter { $0.type == "buttonDown" }.count, 4)
        fixture.events = [];
        fixture.previews = [];
        fixture.previewMilliseconds = 200;
        request = fixture.args;
        request["actions"] = .array([fixture.move])
        Task {
            try? await Task.sleep(for: .milliseconds(40));
            fixture.service.endControl(reason: "user_exit")
        }
        let stopped = try await fixture.service.tool("computer_action", arguments: request)
        XCTAssertEqual(stopped["error_details"]["input_outcome"], .string("not_attempted"));
        XCTAssertTrue(fixture.events.isEmpty)
        _ = try await fixture.open();
        request = fixture.args;
        request["actions"] = .array([fixture.move]);
        request["require_same_window"] = .bool(true)
        Task {
            try? await Task.sleep(for: .milliseconds(40));
            fixture.window = "changed"
        }
        let switched = try await fixture.service.tool("computer_action", arguments: request)
        XCTAssertEqual(switched["error"], .string("target_window_changed"));
        XCTAssertTrue(fixture.events.isEmpty);
        XCTAssertTrue(fixture.service.controlling)
        await fixture.manager.stop()
    }
    @MainActor func testManagedLeaseOwnerAndApplicationFocus() async throws {
        let fixture = try Fixture();
        defer { fixture.cleanup() }
        let opened = try await fixture.service.tool(
            "open_computer",
            arguments: .object([
                "peer_id": .string("local"), "control_session_idle_timeout_ms": .number(45000),
                "client_id": .string(UUID().uuidString), "client_name": .string("QA client"),
            ]))
        XCTAssertEqual(opened["control_session_idle_timeout_ms"], .number(45000))
        let info = try await fixture.service.tool(
            "get_computer_info", arguments: .object(["peer_id": .string("local")]))
        XCTAssertEqual(info["control_state"]["owner_client_name"], .string("QA client"))
        let request: JSONValue = .object([
            "peer_id": .string("local"), "control_session_id": opened["control_session_id"],
            "observation_id": opened["observation_id"],
            "actions": .array([
                .object([
                    "type": .string("focus_application"), "application": .string("QA app"),
                    "allow_window_change": .bool(true),
                ])
            ]),
        ])
        let focused = try await fixture.service.tool("computer_action", arguments: request)
        XCTAssertEqual(focused["observation"]["input_state"]["foreground_window"]["window_id"], .string("QA app"));
        XCTAssertTrue(fixture.events.isEmpty)
        fixture.time = fixture.time.addingTimeInterval(46)
        do {
            _ = try await fixture.service.tool("get_control_status", arguments: request);
            XCTFail("Short client lease remained active")
        } catch { XCTAssertEqual(ComputerUseService.errorDetails(error)["code"], .string("lease_expired")) }
        await fixture.manager.stop()
    }
    @MainActor func testHeldKeyExitAndPartialInjectionReporting() async throws {
        let fixture = try Fixture();
        defer { fixture.cleanup() };
        _ = try await fixture.open()
        var request = fixture.args;
        request["actions"] = .array([
            .object(["type": .string("key_hold"), "keys": .array([.string("W")]), "duration_ms": .number(800)])
        ])
        Task {
            try? await Task.sleep(for: .milliseconds(70));
            fixture.service.endControl(reason: "user_exit")
        }
        let held = try await fixture.service.tool("computer_action", arguments: request);
        XCTAssertEqual(held["error"], .string("control_session_unavailable:user_exit"));
        XCTAssertTrue(fixture.events.contains { $0.type == "keyDown" && $0.key == "KeyW" });
        XCTAssertTrue(fixture.events.contains { $0.type == "keyUp" && $0.key == "KeyW" });
        XCTAssertFalse(fixture.service.controlling)
        _ = try await fixture.open();
        fixture.failButtonUp = true;
        request = fixture.args;
        request["actions"] = .array([.object(["type": .string("click"), "x": .number(10), "y": .number(10)])]);
        let partial = try await fixture.run(request)
        XCTAssertEqual(partial["executed_actions"], .number(0));
        XCTAssertEqual(partial["error_details"]["input_outcome"], .string("partial_or_unknown"));
        XCTAssertEqual(partial["step_results"].array[0]["successful_injection_calls"], .number(2))
        await fixture.manager.stop()
    }
}

@MainActor private final class Fixture {
    let id = UUID().uuidString.lowercased();
    let directory: URL;
    let manager: SessionManager;
    let clipboard: ClipboardService
    var service: ComputerUseService!;
    var events: [CapturedInput] = [];
    var captures = 0;
    var window = "A";
    var args: JSONValue = .object([:]);
    var backgroundMode = false;
    var suspends = 0;
    var restores = 0;
    var capturedContext: JSONValue = .null;
    var positions: [(Double, Double)] = [];
    var previews: [String] = [];
    var previewMilliseconds = 0;
    var failButtonUp = false;
    var time = Date();
    var available = true;
    var permissions: JSONValue = .object([:])
    var move: JSONValue { .object(["type": .string("move"), "x": .number(10), "y": .number(10)]) }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShareMouse-Quality-" + id);
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager = SessionManager(
            localID: id, name: "Quality", identity: try IdentityKeychain(peerID: id),
            registry: try PeerRegistry(directory: directory), pairCode: "123456", password: "",
            confirmCertificate: { _ in true }, confirmConnection: { _ in true }, changed: { _ in }, event: { _ in })
        clipboard = ClipboardService(id: id, manager: manager, changed: { _ in }, event: { _ in })
        let screen = ScreenGeometry(
            id: id + ":test", peerID: id, name: "Fixture", number: 1, pixelWidth: 2560, pixelHeight: 1600,
            primary: true, x: 99, y: 77)
        service = ComputerUseService(
            id: id, name: "Quality", manager: manager, files: nil, clipboard: clipboard, screens: { [screen] },
            info: { [weak self] in .object(["permissions": self?.permissions ?? .null]) },
            screenshot: { _ in .object(["width": .number(1000), "height": .number(720)]) },
            inject: { [weak self] event, _, x, y in
                guard let self else { return };
                if event.type == "buttonUp" && self.failButtonUp {
                    throw ComputerUseError.message("fixture_native_failure")
                };
                self.events.append(event);
                if event.type == "move" { self.positions.append((x, y)) }
            },
            suspend: { [weak self] in
                self?.suspends += 1;
                return true
            }, restore: { [weak self] _ in self?.restores += 1 },
            canControl: { [weak self] in self?.available ?? false }, now: { [weak self] in self?.time ?? Date() },
            inputState: { [weak self] in self?.state() ?? .null },
            captureWithOptions: { [weak self] _, options, active in
                guard let self else { throw ComputerUseError.message("fixture_missing") };
                XCTAssertTrue(active());
                self.captures += 1;
                self.capturedContext = options["_control_context"];
                let width = options["thumbnail_max_dimension"].number ?? 1000;
                return .object([
                    "width": .number(width), "height": .number(width == 320 ? 200 : 720),
                    "captured_at": .string("fixture"),
                    "desktop_bounds": .object([
                        "x": .number(-2560), "y": .number(120), "width": .number(2560), "height": .number(1600),
                    ]), "normalized_capture_region": options["capture_region"],
                    "desktop_coordinate_space": .string("desktop_pixels"), "input_state": self.state(),
                ])
            },
            pointerPreview: { [weak self] _, _, _, kind in
                self?.previews.append(kind);
                return self?.previewMilliseconds ?? 0
            }, focusApplication: { [weak self] name in self?.window = name },
            prepareControl: { [weak self] args in
                let mode = args["control_mode"].string ?? "user_mouse"
                guard ["user_mouse", "independent"].contains(mode) else {
                    throw ComputerUseError.message("control_mode_unsupported")
                }
                self?.backgroundMode = mode == "independent";
                return .object(["mode": .string(mode)])
            })
        service.allowComputer = true
    }
    func state() -> JSONValue {
        .object([
            "control_target_window": backgroundMode ? .object(["window_id": .string("background-target")]) : .null,
            "foreground_window": .object(["window_id": .string(window)]),
            "cursor_position": .object(["x": .number(-1280), "y": .number(920)]),
            "input_injection_blocked": .bool(false),
        ])
    }
    func open() async throws -> JSONValue {
        let result = try await service.tool("open_computer", arguments: .object(["peer_id": .string("local")]));
        args = .object([
            "peer_id": .string("local"), "control_session_id": result["control_session_id"],
            "observation_id": result["observation_id"],
        ]);
        return result
    }
    func run(_ value: JSONValue) async throws -> JSONValue {
        let result = try await service.tool("computer_action", arguments: value);
        if result["observation"]["observation_id"] != .null {
            args["observation_id"] = result["observation"]["observation_id"]
        };
        return result
    }
    func cleanup() {
        service.stop();
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(("com.sharemouse.identity." + id).utf8),
        ]
            ;
        SecItemDelete(query as CFDictionary);
        SecItemDelete(
            [kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: "ShareMouse identity " + id]
                as CFDictionary);
        try? FileManager.default.removeItem(at: directory)
    }
}
