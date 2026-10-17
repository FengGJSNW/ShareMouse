import AppKit
@preconcurrency import ApplicationServices
import Darwin

public enum MacInputInterruption { case permissionRevoked, captureStopped, captureTimedOut }

@MainActor public final class MacInputAdapter {
    public private(set) static var isCapturingRemotePointer = false
    private var relativeRemainderX = 0.0, relativeRemainderY = 0.0
    private var receivingRelative = false

    private let id: String
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var permissionMonitor: Task<Void, Never>?
    private var captureGeneration = 0
    private var permissionsGranted = false
    private struct CaptureDisplay {
        let id: UInt32;
        let bounds: CGRect;
        let scaleX: Double;
        let scaleY: Double
    }
    private var displays: [CaptureDisplay] = []
    private var slowCallbackAt = 0.0
    private var hidden = false
    private var backgroundCursorEnabled = false
    private var suppressPhysical = false
    private var frozenPoint: CGPoint?
    private var detached = false
    private var associatedForeground = false
    private var associationAttemptAt = -Double.infinity
    private var associationRequested: Bool?
    private var foregroundObserver: NSObjectProtocol?
    private var coalescing: Bool?
    private var held: Set<String> = []
    private var heldButtons: Set<Int> = []
    private var physicalModifiers: Set<String> = []
    private var remoteFnGesture = false
    private var remoteFnEmojiUntil = 0.0
    private var systemFnCommandSwapped = false
    private let diagnostic: (String) -> Void
    private var warpFailureAt = 0.0
    private var awaitingLocalMotionAt: Double?
    private var resumePositionTrace: (count: Int, delta: Double, distance: Double, last: CGPoint?)?
    public var captured: ((CapturedInput) -> Bool)?
    public var interceptRemoteFn: (() -> Bool)?
    public var modifierDiagnostic: ((String) -> Void)?
    public var interrupted: ((MacInputInterruption) -> Void)?
    private let injectionSource = CGEventSource(stateID: .hidSystemState)
    private static let marker: Int64 = 0x534d494e
    // CGDisplayHideCursor otherwise silently leaves the rendered cursor visible
    // while we are inactive. Input Leap/Teleport use this connection-local policy.
    // These are private symbols: resolve them optionally, without a link dependency
    // or changing another application's WindowServer connection.
    private static let backgroundCursorPolicy: ((Bool) -> Int32)? = {
        typealias Connection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let symbols = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connectionSymbol = dlsym(symbols, "CGSMainConnectionID"),
            let propertySymbol = dlsym(symbols, "CGSSetConnectionProperty")
        else { return nil }
        let connection = unsafeBitCast(connectionSymbol, to: Connection.self)
        let setProperty = unsafeBitCast(propertySymbol, to: SetProperty.self)
        return { enabled in
            let id = connection()
            return setProperty(id, id, "SetsCursorInBackground" as CFString, enabled ? kCFBooleanTrue : kCFBooleanFalse)
        }
    }()
    public var canCapture: Bool { CGPreflightListenEventAccess() }
    public var canInject: Bool { CGPreflightPostEventAccess() && AXIsProcessTrusted() }
    public func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    public func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        if !canCapture,
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        {
            NSWorkspace.shared.open(url)
        }
    }
    public init(peerID: String, diagnostic: @escaping (String) -> Void = { _ in }) {
        id = peerID;
        self.diagnostic = diagnostic;
        injectionSource?.localEventsSuppressionInterval = 0
    }
    public func requestPermissions() {
        if !canInject { requestAccessibility() } else if !canCapture { requestInputMonitoring() }
    }
    public func start() throws {
        guard canCapture, canInject else { throw InputAdapterError.permission }
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) };
            return
        }
        captureGeneration += 1;
        let generation = captureGeneration
        permissionsGranted = true;
        refreshDisplays()
        let rows =
            (CFPreferencesCopyValue(
                "com.apple.keyboard.modifiermapping.0-0-0" as CFString, kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? [[String: NSNumber]] ?? []).map {
                $0.mapValues { $0.uint64Value }
            }
        systemFnCommandSwapped = Self.fnCommandSwapped(rows)
        diagnostic("MacKeyboardRoles systemFnCommandSwapped=\(systemFnCommandSwapped)")
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown, .keyUp,
            .flagsChanged, CGEventType(rawValue: 14)!,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let suppress = MainActor.assumeIsolated {
                let adapter = Unmanaged<MacInputAdapter>.fromOpaque(info).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if adapter.canCapture && adapter.canInject, let tap = adapter.tap {
                        let reason: MacInputInterruption =
                            type == .tapDisabledByTimeout ? .captureTimedOut : .captureStopped
                        if reason == .captureStopped {
                            adapter.cursorState(remoteTarget: false, suppressPhysical: false)
                        }
                        // Restore interception first; timeout recovery keeps the remote cursor.
                        // AppKit cleanup must not run inside WindowServer's callback deadline.
                        CGEvent.tapEnable(tap: tap, enable: true)
                        let generation = adapter.captureGeneration
                        Task { @MainActor [weak adapter] in
                            guard let adapter, adapter.captureGeneration == generation else { return }
                            adapter.interrupted?(reason)
                        }
                    } else {
                        adapter.stop();
                        adapter.interrupted?(.permissionRevoked)
                    }
                    return false
                }
                let start = ProcessInfo.processInfo.systemUptime
                let consumed = adapter.handle(type, event)
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                if elapsed > 0.008, start - adapter.slowCallbackAt >= 5 {
                    adapter.slowCallbackAt = start
                    let message = "InputTapCallbackSlow eventType=\(type.rawValue) durationMs=\(Int(elapsed * 1000))"
                    Task { @MainActor [weak adapter] in adapter?.diagnostic(message) }
                }
                return consumed
            }
            return suppress ? nil : Unmanaged.passUnretained(event)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        else { throw InputAdapterError.permission }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Restore while still foreground, rather than on the first packet
                // returning from another computer after a Space/application change.
                if self.detached, CGAssociateMouseAndMouseCursorPosition(1) == .success { self.detached = false }
                self.associatedForeground = false;
                self.associationRequested = nil
            }
        }
        coalescing = NSEvent.isMouseCoalescingEnabled;
        NSEvent.isMouseCoalescingEnabled = false
        self.tap = tap;
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes);
        CGEvent.tapEnable(tap: tap, enable: true)
        // Preflight and Accessibility calls can perform IPC. Poll off the event run loop
        // instead of synchronously querying the system for every captured/injected event.
        permissionMonitor = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200));
                guard !Task.isCancelled else { return }
                let allowed = CGPreflightListenEventAccess() && CGPreflightPostEventAccess() && AXIsProcessTrusted()
                await MainActor.run { [weak self] in
                    guard let self, self.tap != nil, self.captureGeneration == generation else { return }
                    self.permissionsGranted = allowed
                    if !allowed {
                        self.stop();
                        self.interrupted?(.permissionRevoked)
                    }
                }
            }
        }
    }
    public func refreshDisplays() {
        displays = NSScreen.screens.map { screen in
            let displayID =
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                ?? CGMainDisplayID()
            let bounds = CGDisplayBounds(displayID)
            return CaptureDisplay(
                id: displayID, bounds: bounds, scaleX: Double(CGDisplayPixelsWide(displayID)) / max(1, bounds.width),
                scaleY: Double(CGDisplayPixelsHigh(displayID)) / max(1, bounds.height))
        }
    }
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return false }
        guard permissionsGranted else {
            stop();
            interrupted?(.permissionRevoked);
            return false
        }
        if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type),
            var trace = resumePositionTrace
        {
            let point = event.location
            trace.count += 1;
            trace.delta += hypot(
                event.getDoubleValueField(.mouseEventDeltaX), event.getDoubleValueField(.mouseEventDeltaY))
            if let last = trace.last { trace.distance += hypot(point.x - last.x, point.y - last.y) };
            trace.last = point
            if trace.count >= 12 {
                diagnostic(
                    "InputLocalResumePositions frames=\(trace.count) hardwareDelta=\(Int(trace.delta)) cursorDistance=\(Int(trace.distance))"
                )
                resumePositionTrace = nil
            } else {
                resumePositionTrace = trace
            }
        }
        if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type),
            let resumed = awaitingLocalMotionAt
        {
            awaitingLocalMotionAt = nil
            diagnostic("InputLocalResumeMotion gapMs=\(Int((ProcessInfo.processInfo.systemUptime-resumed)*1000))")
        }
        if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .keyDown, .keyUp].contains(type) {
            // Repair missed releases using the actual flags, never turn an unseen release
            // into a press. Fn is excluded: function-layer events may carry Fn themselves.
            for key in physicalModifiers.filter({
                $0 != "Fn" && !Self.modifierDown($0, flags: event.flags, previous: physicalModifiers, changing: false)
            }) {
                physicalModifiers.remove(key);
                _ = captured?(CapturedInput("keyUp", key: key))
            }
        }
        if type.rawValue == 14 {
            guard let native = NSEvent(cgEvent: event), native.subtype.rawValue == 8,
                let key = Self.mediaKeys[(native.data1 >> 16) & 0xffff]
            else { return false }
            let state = (native.data1 >> 8) & 0xff
            guard state == 0x0a || state == 0x0b else { return false }
            return captured?(CapturedInput(state == 0x0a ? "keyDown" : "keyUp", key: key)) ?? false
        }
        if type == .keyDown || type == .keyUp || type == .flagsChanged {
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let now = ProcessInfo.processInfo.systemUptime
            // 179 follows a standalone Globe release in the captured record. Consume it
            // only for a recent remotely routed Fn gesture; leave other/local uses alone.
            if code == 179, remoteFnGesture || now < remoteFnEmojiUntil { return true }
            guard let key = Self.keyNames[code] else { return false }
            let down = type == .keyDown
            if type == .flagsChanged {
                if key == "CapsLock" {
                    let first = captured?(CapturedInput("keyDown", key: key)) ?? false
                    let second = captured?(CapturedInput("keyUp", key: key)) ?? false
                    return first || second
                }
                if key == "Fn" || KeyboardMapping.modifiers.contains(key) {
                    let next = Self.modifierState(changing: key, flags: event.flags, previous: physicalModifiers)
                    let released = physicalModifiers.subtracting(next), pressed = next.subtracting(physicalModifiers)
                    physicalModifiers = next
                    var consumed = false
                    for changed in released.sorted() {
                        let used = captured?(CapturedInput("keyUp", key: changed)) ?? false;
                        consumed = used || consumed
                    }
                    for changed in pressed.sorted(by: {
                        $0 == "Fn" && $1 != "Fn" || $0 != "Fn" && $1 != "Fn" && $0 < $1
                    }) {
                        let used = captured?(CapturedInput("keyDown", key: changed)) ?? false;
                        consumed = used || consumed
                    }
                    if released.contains("Fn") || pressed.contains("Fn") {
                        let intercept = interceptRemoteFn?() == true || remoteFnGesture
                        remoteFnGesture = pressed.contains("Fn") && intercept
                        remoteFnEmojiUntil = released.contains("Fn") && intercept ? now + 0.7 : 0
                        consumed = consumed || intercept
                    }
                    let changed = released.union(pressed)
                    if !changed.isEmpty, changed != [key], interceptRemoteFn?() == true {
                        modifierDiagnostic?(
                            "MacModifierRole keyCode=\(code) source=\(key) pressed=\(pressed.sorted().joined(separator:",")) released=\(released.sorted().joined(separator:","))"
                        )
                    }
                    return consumed
                }
            }
            let consumed = captured?(CapturedInput(down ? "keyDown" : "keyUp", key: key)) ?? false
            return consumed
        }
        if receivingRelative, suppressPhysical,
            [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type),
            event.getIntegerValueField(.eventSourceUnixProcessID) != 0
        {
            return false
        }
        let point = event.location
        guard let display = displays.first(where: { $0.bounds.contains(point) }) ?? displays.first else { return false }
        let displayID = display.id;
        let bounds = display.bounds
        var input = CapturedInput(
            "move", deltaX: event.getDoubleValueField(.mouseEventDeltaX),
            deltaY: event.getDoubleValueField(.mouseEventDeltaY), screenID: id + ":" + String(displayID),
            x: Self.normalizedPosition(point.x, origin: bounds.minX, extent: bounds.width),
            y: Self.normalizedPosition(point.y, origin: bounds.minY, extent: bounds.height),
            hardwareMotion: event.getIntegerValueField(.eventSourceUnixProcessID) == 0)
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type)
        {
            input.type = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) ? "buttonDown" : "buttonUp"
            input.button = Int(event.getIntegerValueField(.mouseEventButtonNumber));
            if input.button > 2 { return false }
        } else if type == .scrollWheel {
            input.type = "scroll"
            let precise = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            input.deltaY = event.getDoubleValueField(
                precise ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventDeltaAxis1)
            input.deltaX = event.getDoubleValueField(
                precise ? .scrollWheelEventPointDeltaAxis2 : .scrollWheelEventDeltaAxis2)
            input.preciseScroll = precise;
            input.scrollPhase = Int(event.getIntegerValueField(.scrollWheelEventScrollPhase));
            input.momentumPhase = Int(event.getIntegerValueField(.scrollWheelEventMomentumPhase))
            if !precise {
                input.deltaX *= 40;
                input.deltaY *= 40
            }
        } else {
            // Logical layout uses pixels; Quartz mouse deltas use display coordinates.
            input.deltaX *= display.scaleX
            input.deltaY *= display.scaleY
        }
        let consumed = captured?(input) ?? false
        // A hardware cursor has moved before the session tap runs. Editing the
        // intercepted event's location alone does not restore that cursor. Post
        // a separate marked absolute move with suppressionInterval=0 instead of
        // warping, and discard the original event. Capture the full deltas first.
        if consumed, suppressPhysical, input.type == "move", (!hidden || !associatedForeground), let frozenPoint {
            let correction = CGEvent(
                mouseEventSource: injectionSource, mouseType: .mouseMoved, mouseCursorPosition: frozenPoint,
                mouseButton: .left)
            correction?.flags = []
            correction?.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            correction?.setDoubleValueField(.mouseEventDeltaX, value: 0)
            correction?.setDoubleValueField(.mouseEventDeltaY, value: 0)
            correction?.post(tap: .cghidEventTap)
        }
        return consumed
    }
    public static func modifierDown(_ key: String, flags: CGEventFlags, previous: Set<String>, changing: Bool = true)
        -> Bool
    {
        if key == "Fn" { return flags.contains(.maskSecondaryFn) }
        let groups: [String: (CGEventFlags, UInt64, UInt64)] = [
            "ControlLeft": (.maskControl, 0x0001, 0x2001), "ControlRight": (.maskControl, 0x2000, 0x2001),
            "ShiftLeft": (.maskShift, 0x0002, 0x0006), "ShiftRight": (.maskShift, 0x0004, 0x0006),
            "MetaLeft": (.maskCommand, 0x0008, 0x0018), "MetaRight": (.maskCommand, 0x0010, 0x0018),
            "AltLeft": (.maskAlternate, 0x0020, 0x0060), "AltRight": (.maskAlternate, 0x0040, 0x0060),
        ]
        guard let (aggregate, side, both) = groups[key], flags.contains(aggregate) else { return false }
        if flags.rawValue & both != 0 { return flags.rawValue & side != 0 }
        // Some external keyboards omit device-side bits; aggregate-off is still absolute.
        return changing ? !previous.contains(key) : previous.contains(key)
    }
    public static func modifierState(changing key: String, flags: CGEventFlags, previous: Set<String>) -> Set<String> {
        // Modifier remapping can retain the physical keyCode while changing its
        // logical flags. Resolve the role from flags before applying ShareMouse's mapping.
        var result: Set<String> = flags.contains(.maskSecondaryFn) ? ["Fn"] : []
        for (prefix, aggregate, bits) in [
            ("Control", CGEventFlags.maskControl, UInt64(0x2001)), ("Shift", .maskShift, 0x0006),
            ("Meta", .maskCommand, 0x0018), ("Alt", .maskAlternate, 0x0060),
        ] {
            guard flags.contains(aggregate) else { continue }
            let sides = [prefix + "Left", prefix + "Right"]
            if flags.rawValue & bits != 0 {
                for side in sides where modifierDown(side, flags: flags, previous: previous, changing: false) {
                    result.insert(side)
                }
            } else {
                var held = previous.filter { $0.hasPrefix(prefix) }
                if sides.contains(key) { if held.contains(key) { held.remove(key) } else { held.insert(key) } }
                if held.isEmpty { held.insert(sides.contains(key) ? key : sides[0]) }
                result.formUnion(held)
            }
        }
        return result
    }
    public static func fnCommandSwapped(_ rows: [[String: UInt64]]) -> Bool {
        let fn: Set<UInt64> = [0xff00000003, 0xff0100000003], command: Set<UInt64> = [0x7000000e3, 0x7000000e7]
        func maps(_ sources: Set<UInt64>, _ targets: Set<UInt64>) -> Bool {
            rows.contains { row in
                guard let src = row["HIDKeyboardModifierMappingSrc"], let dst = row["HIDKeyboardModifierMappingDst"]
                else { return false };
                return sources.contains(src) && targets.contains(dst)
            }
        }
        return maps(fn, command) && maps(command, fn)
    }
    public static func sourceKey(_ key: String, to platform: String, fnCommandSwapped: Bool) -> String {
        guard platform == "windows", fnCommandSwapped else { return key }
        if key == "Fn" { return "MetaLeft" }
        if key == "MetaLeft" || key == "MetaRight" { return "Fn" }
        return key
    }
    public func sourceKey(_ key: String, to platform: String) -> String {
        Self.sourceKey(key, to: platform, fnCommandSwapped: systemFnCommandSwapped)
    }
    // Quartz coordinates may be points on Retina displays, while layout sizes are pixels.
    static func normalizedPosition(_ point: CGFloat, origin: CGFloat, extent: CGFloat) -> Double {
        guard extent > 1 else { return 0 }
        if point <= origin { return 0 }
        if point >= origin + extent - 1 { return 1 }
        return Double((point - origin) / extent)
    }
    public func inject(_ input: CapturedInput, screen: ScreenGeometry?, x: Double, y: Double) throws {
        guard tap == nil ? canInject : permissionsGranted else { throw InputAdapterError.permission }
        if input.type == "command", input.command == "screenshot" {
            let saved = held.filter { KeyboardMapping.modifiers.contains($0) }
            for key in saved { try inject(CapturedInput("keyUp", key: key), screen: screen, x: x, y: y) }
            defer {
                for key in ["Digit3", "ShiftLeft", "MetaLeft"] {
                    try? inject(CapturedInput("keyUp", key: key), screen: screen, x: x, y: y)
                }
                for key in saved { try? inject(CapturedInput("keyDown", key: key), screen: screen, x: x, y: y) }
            }
            for key in ["MetaLeft", "ShiftLeft", "Digit3"] {
                try inject(CapturedInput("keyDown", key: key), screen: screen, x: x, y: y)
            }
            return
        }
        if input.type == "text", let text = input.text {
            let units = Array(text.utf16);
            guard !units.isEmpty, text.utf8.count <= 4096 else { return }
            let saved = held.filter { KeyboardMapping.modifiers.contains($0) };
            for key in saved { try inject(CapturedInput("keyUp", key: key), screen: screen, x: x, y: y) }
            defer { for key in saved { try? inject(CapturedInput("keyDown", key: key), screen: screen, x: x, y: y) } }
            // Small UTF-16 batches preserve surrogate pairs; no ordinary keyboard input uses this path.
            var offset = 0
            while offset < units.count {
                var count = min(20, units.count - offset);
                if offset + count < units.count, (0xD800...0xDBFF).contains(units[offset + count - 1]) { count -= 1 }
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: injectionSource, virtualKey: 0, keyDown: down) else {
                        throw InputAdapterError.event
                    };
                    units.withUnsafeBufferPointer { buffer in
                        event.keyboardSetUnicodeString(
                            stringLength: count, unicodeString: buffer.baseAddress!.advanced(by: offset))
                    };
                    event.flags = [];
                    event.setIntegerValueField(.eventSourceUserData, value: Self.marker);
                    event.post(tap: .cghidEventTap)
                };
                offset += count
            };
            return
        }
        if input.type == "command", let command = input.command,
            ["desktopPrevious", "desktopNext", "overview"].contains(command)
        {
            let saved = held.filter { KeyboardMapping.modifiers.contains($0) }
            for modifier in saved { try inject(CapturedInput("keyUp", key: modifier), screen: screen, x: x, y: y) }
            let key = command == "overview" ? "ArrowUp" : command == "desktopPrevious" ? "ArrowLeft" : "ArrowRight"
            defer {
                try? inject(CapturedInput("keyUp", key: key), screen: screen, x: x, y: y)
                try? inject(CapturedInput("keyUp", key: "ControlLeft"), screen: screen, x: x, y: y)
                for modifier in saved {
                    try? inject(CapturedInput("keyDown", key: modifier), screen: screen, x: x, y: y)
                }
            }
            try inject(CapturedInput("keyDown", key: "ControlLeft"), screen: screen, x: x, y: y)
            try inject(CapturedInput("keyDown", key: key), screen: screen, x: x, y: y);
            return
        }
        if input.type == "command", let command = input.command,
            let key = [
                "copy": "KeyC", "cut": "KeyX", "paste": "KeyV", "moveFiles": "KeyV", "undo": "KeyZ", "redo": "KeyZ",
            ][command]
        {
            let saved = held.filter { KeyboardMapping.modifiers.contains($0) }
            for modifier in saved { try inject(CapturedInput("keyUp", key: modifier), screen: screen, x: x, y: y) }
            defer {
                if held.contains(key) { try? inject(CapturedInput("keyUp", key: key), screen: screen, x: x, y: y) };
                for modifier in ["MetaLeft", "ShiftLeft", "AltLeft"] where held.contains(modifier) {
                    try? inject(CapturedInput("keyUp", key: modifier), screen: screen, x: x, y: y)
                };
                for modifier in saved {
                    try? inject(CapturedInput("keyDown", key: modifier), screen: screen, x: x, y: y)
                }
            }
            try inject(CapturedInput("keyDown", key: "MetaLeft"), screen: screen, x: x, y: y)
            if command == "moveFiles" {
                try inject(CapturedInput("keyDown", key: "AltLeft"), screen: screen, x: x, y: y)
            }
            if command == "redo" { try inject(CapturedInput("keyDown", key: "ShiftLeft"), screen: screen, x: x, y: y) }
            try inject(CapturedInput("keyDown", key: key), screen: screen, x: x, y: y);
            try inject(CapturedInput("keyUp", key: key), screen: screen, x: x, y: y);
            return
        }
        let source = injectionSource
        var event: CGEvent?
        if input.type == "keyDown" || input.type == "keyUp", let key = input.key, let code = Self.mediaCodes[key] {
            let down = input.type == "keyDown"
            let repeating = down && held.contains(key)
            if down { held.insert(key) } else { held.remove(key) }
            let state = down ? 0x0a : 0x0b
            event =
                NSEvent.otherEvent(
                    with: .systemDefined, location: .zero,
                    modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)), timestamp: 0, windowNumber: 0,
                    context: nil, subtype: 8, data1: (code << 16) | (state << 8) | (repeating ? 1 : 0), data2: -1)?
                .cgEvent
        } else if input.type == "keyDown" || input.type == "keyUp", input.key == "Screenshot" {
            if input.type == "keyUp" { return }
            try inject(CapturedInput("command", command: "screenshot"), screen: screen, x: x, y: y);
            return
        } else if input.type == "keyDown" || input.type == "keyUp", let key = input.key, let code = Self.keyCodes[key] {
            let down = input.type == "keyDown"
            let repeatKey = down && held.contains(key)
            if down { held.insert(key) } else { held.remove(key) }
            event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
            if key == "Fn" {
                event?.type = .flagsChanged
                var flags = event?.flags ?? []
                if down { flags.insert(.maskSecondaryFn) } else { flags.remove(.maskSecondaryFn) }
                event?.flags = flags
            } else if held.contains("Fn") {
                var flags = event?.flags ?? []
                flags.insert(.maskSecondaryFn)
                event?.flags = flags
            }
        } else if input.type == "relativeBegin" {
            receivingRelative = true;
            return
        } else if input.type == "relativeEnd" {
            receivingRelative = false;
            relativeRemainderX = 0;
            relativeRemainderY = 0;
            return
        } else if input.type == "relativeReset" {
            receivingRelative = true;
            relativeRemainderX = 0;
            relativeRemainderY = 0;
            return
        } else if input.type == "relativeMove" {
            guard input.deltaX.isFinite, input.deltaY.isFinite, abs(input.deltaX) <= 10000, abs(input.deltaY) <= 10000
            else { return }
            relativeRemainderX += input.deltaX;
            relativeRemainderY += input.deltaY
            let dx = relativeRemainderX.rounded(.towardZero), dy = relativeRemainderY.rounded(.towardZero)
            relativeRemainderX -= dx;
            relativeRemainderY -= dy
            guard dx != 0 || dy != 0 else { return }
            let type: CGEventType =
                heldButtons.contains(0)
                ? .leftMouseDragged
                : heldButtons.contains(1)
                    ? .rightMouseDragged : heldButtons.contains(2) ? .otherMouseDragged : .mouseMoved
            event = CGEvent(
                mouseEventSource: source, mouseType: type, mouseCursorPosition: CGEvent(source: nil)?.location ?? .zero,
                mouseButton: heldButtons.contains(1) ? .right : heldButtons.contains(2) ? .center : .left)
            event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx));
            event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        } else if input.type == "move", let screen, let displayID = UInt32(screen.id.split(separator: ":").last ?? "") {
            guard CGDisplayIsActive(displayID) != 0 else { throw InputAdapterError.display }
            let bounds = CGDisplayBounds(displayID)
            let type: CGEventType =
                heldButtons.contains(0)
                ? .leftMouseDragged
                : heldButtons.contains(1)
                    ? .rightMouseDragged : heldButtons.contains(2) ? .otherMouseDragged : .mouseMoved
            let button: CGMouseButton = heldButtons.contains(0) ? .left : heldButtons.contains(1) ? .right : .center
            let point = CGPoint(
                x: bounds.minX + min(0.99999, max(0, x)) * bounds.width,
                y: bounds.minY + min(0.99999, max(0, y)) * bounds.height)
            if suppressPhysical { frozenPoint = point }
            if detached && NSApp.isActive {
                let result = CGWarpMouseCursorPosition(point)
                let now = ProcessInfo.processInfo.systemUptime
                if result != .success, now - warpFailureAt >= 5 {
                    warpFailureAt = now;
                    diagnostic("InputCursorWarpFailed code=\(result.rawValue)")
                }
            }
            event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        } else if input.type == "buttonDown" || input.type == "buttonUp" {
            guard let button = CGMouseButton(rawValue: UInt32(input.button)) else { return }
            let down = input.type == "buttonDown"
            if down { heldButtons.insert(input.button) } else { heldButtons.remove(input.button) }
            let type: CGEventType =
                input.button == 0
                ? (down ? .leftMouseDown : .leftMouseUp)
                : input.button == 1
                    ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
            event = CGEvent(
                mouseEventSource: source, mouseType: type, mouseCursorPosition: CGEvent(source: nil)?.location ?? .zero,
                mouseButton: button)
            if let count = input.clickCount { event?.setIntegerValueField(.mouseEventClickState, value: Int64(count)) }
        } else if input.type == "scroll" {
            event = CGEvent(
                scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(input.deltaY.rounded()),
                wheel2: Int32(input.deltaX.rounded()), wheel3: 0)
            event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: input.preciseScroll == true ? 1 : 0)
            event?.setIntegerValueField(
                .scrollWheelEventScrollPhase, value: Int64(max(0, min(255, input.scrollPhase ?? 0))))
            event?.setIntegerValueField(
                .scrollWheelEventMomentumPhase, value: Int64(max(0, min(255, input.momentumPhase ?? 0))))
        } else {
            return
        }
        guard let event else { throw InputAdapterError.event }
        var flags: CGEventFlags = CGEventSource.flagsState(.combinedSessionState).intersection(.maskAlphaShift)
        for key in held {
            if key.hasPrefix("Control") { flags.insert(.maskControl) };
            if key.hasPrefix("Shift") { flags.insert(.maskShift) }
            if key.hasPrefix("Alt") { flags.insert(.maskAlternate) };
            if key.hasPrefix("Meta") { flags.insert(.maskCommand) }
            if key == "Fn" { flags.insert(.maskSecondaryFn) }
        }
        if event.type.rawValue == 14 { flags.formUnion(CGEventFlags(rawValue: event.flags.rawValue & 0xffff)) }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker);
        event.post(tap: .cghidEventTap)
    }
    public func cursorState(remoteTarget: Bool, suppressPhysical: Bool) {
        if remoteTarget && !hidden {
            Self.isCapturingRemotePointer = true
            let policy = Self.backgroundCursorPolicy?(true)
            backgroundCursorEnabled = policy == 0
            let result = CGDisplayHideCursor(CGMainDisplayID())
            hidden = result == .success
            diagnostic(
                "InputCursorHidden foreground=\(NSApp.isActive) backgroundPolicy=\(backgroundCursorEnabled) code=\(result.rawValue)"
            )
        }
        let resumingLocalHardware = self.suppressPhysical && !suppressPhysical
        if self.suppressPhysical != suppressPhysical {
            frozenPoint = suppressPhysical ? CGEvent(source: nil)?.location : nil
        }
        if !suppressPhysical { receivingRelative = false }
        self.suppressPhysical = suppressPhysical
        // Quartz disassociation is a foreground-only operation. Background capture
        // restores its frozen position with marked events, without warp/activation.
        let foreground = NSApp.isActive
        let shouldDetach = suppressPhysical && foreground
        let now = ProcessInfo.processInfo.systemUptime
        if foreground && !resumingLocalHardware && (detached != shouldDetach || shouldDetach && !associatedForeground)
            && (associationRequested != shouldDetach || now - associationAttemptAt >= 1)
        {
            associationRequested = shouldDetach;
            associationAttemptAt = now
            let result = CGAssociateMouseAndMouseCursorPosition(shouldDetach ? 0 : 1)
            if result == .success {
                detached = shouldDetach
            } else {
                diagnostic(
                    "InputCursorAssociationFailed detach=\(shouldDetach) foreground=\(foreground) code=\(result.rawValue)"
                )
            }
        }
        associatedForeground = detached && foreground
        if resumingLocalHardware {
            // Only foreground capture disassociates/warps. Background capture now
            // posts cursor corrections and must not rely on this foreground-only API.
            let began = ProcessInfo.processInfo.systemUptime
            let result = foreground || detached ? CGAssociateMouseAndMouseCursorPosition(1) : CGError.success
            if result == .success {
                detached = false;
                associatedForeground = false;
                associationRequested = false
            }
            awaitingLocalMotionAt = ProcessInfo.processInfo.systemUptime
            resumePositionTrace = (0, 0, 0, nil)
            let visibleWindow = NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized }
            diagnostic(
                "InputLocalHardwareResumed foreground=\(foreground) visibleWindow=\(visibleWindow) result=\(result.rawValue) durationMs=\(Int((ProcessInfo.processInfo.systemUptime-began)*1000))"
            )
        }
        if !remoteTarget {
            Self.isCapturingRemotePointer = false
            if hidden {
                let result = CGDisplayShowCursor(CGMainDisplayID());
                hidden = false
                if result != .success { diagnostic("InputCursorShowFailed code=\(result.rawValue)") }
            }
            // Show before restoring the policy, so background return, pause,
            // permission loss and stop all balance the very same hide request.
            if backgroundCursorEnabled {
                let result = Self.backgroundCursorPolicy?(false)
                backgroundCursorEnabled = result != 0
                if result != 0 { diagnostic("InputBackgroundCursorResetFailed") }
            }
        }
    }
    public func stop() {
        captureGeneration += 1
        permissionMonitor?.cancel();
        permissionMonitor = nil;
        permissionsGranted = false
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver);
            self.foregroundObserver = nil
        }
        cursorState(remoteTarget: false, suppressPhysical: false)
        if detached {
            _ = CGAssociateMouseAndMouseCursorPosition(1);
            detached = false;
            associatedForeground = false
        }
        Self.isCapturingRemotePointer = false
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false);
            CFMachPortInvalidate(tap)
        }
        if let coalescing { NSEvent.isMouseCoalescingEnabled = coalescing };
        coalescing = nil
        tap = nil;
        source = nil;
        held = [];
        heldButtons = [];
        physicalModifiers = []
        remoteFnGesture = false;
        remoteFnEmojiUntil = 0
    }
    public static let keyNames: [UInt16: String] = [
        0: "KeyA", 1: "KeyS", 2: "KeyD", 3: "KeyF", 4: "KeyH", 5: "KeyG", 6: "KeyZ", 7: "KeyX", 8: "KeyC", 9: "KeyV",
        11: "KeyB", 12: "KeyQ", 13: "KeyW", 14: "KeyE", 15: "KeyR", 16: "KeyY", 17: "KeyT", 18: "Digit1", 19: "Digit2",
        20: "Digit3", 21: "Digit4", 22: "Digit6", 23: "Digit5", 24: "Equal", 25: "Digit9", 26: "Digit7", 27: "Minus",
        28: "Digit8", 29: "Digit0", 30: "BracketRight", 31: "KeyO", 32: "KeyU", 33: "BracketLeft", 34: "KeyI",
        35: "KeyP", 36: "Enter", 37: "KeyL", 38: "KeyJ", 39: "Quote", 40: "KeyK", 41: "Semicolon", 42: "Backslash",
        43: "Comma", 44: "Slash", 45: "KeyN", 46: "KeyM", 47: "Period", 48: "Tab", 49: "Space", 50: "Backquote",
        51: "Backspace", 53: "Escape", 54: "MetaRight", 55: "MetaLeft", 56: "ShiftLeft", 57: "CapsLock", 58: "AltLeft",
        59: "ControlLeft", 60: "ShiftRight", 61: "AltRight", 62: "ControlRight", 63: "Fn", 65: "NumpadDecimal",
        67: "NumpadMultiply", 69: "NumpadAdd", 71: "NumLock", 75: "NumpadDivide", 76: "NumpadEnter",
        78: "NumpadSubtract", 82: "Numpad0", 83: "Numpad1", 84: "Numpad2", 85: "Numpad3", 86: "Numpad4", 87: "Numpad5",
        88: "Numpad6", 89: "Numpad7", 91: "Numpad8", 92: "Numpad9", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
        101: "F9", 103: "F11", 109: "F10", 111: "F12", 114: "Insert", 115: "Home", 116: "PageUp", 117: "Delete",
        118: "F4", 119: "End", 120: "F2", 121: "PageDown", 122: "F1", 123: "ArrowLeft", 124: "ArrowRight",
        125: "ArrowDown", 126: "ArrowUp", 64: "F17", 79: "F18", 80: "F19", 90: "F20", 105: "F13", 106: "F16",
        107: "F14", 113: "F15", 160: "MissionControl", 176: "Dictation", 177: "Spotlight", 178: "DoNotDisturb",
    ]
    private static let mediaKeys: [Int: String] = [
        0: "VolumeUp", 1: "VolumeDown", 2: "BrightnessUp", 3: "BrightnessDown", 7: "VolumeMute", 16: "MediaPlayPause",
        17: "MediaNext", 18: "MediaPrevious", 19: "MediaFastForward", 20: "MediaRewind", 21: "KeyboardBrightnessUp",
        22: "KeyboardBrightnessDown",
    ]
    // Build these inverses once instead of searching the full key table on every injected edge.
    private static let mediaCodes = Dictionary(uniqueKeysWithValues: mediaKeys.map { ($0.value, $0.key) })
    private static let keyCodes = Dictionary(uniqueKeysWithValues: keyNames.map { ($0.value, $0.key) })

}
public enum InputAdapterError: Error { case permission, event, display }
