import AppKit
@preconcurrency import ApplicationServices

public enum MacInputInterruption { case permissionRevoked, captureStopped, captureTimedOut }

@MainActor
public final class MacInputAdapter {
    public private(set) static var isCapturingRemotePointer = false
    private var relativeRemainderX = 0.0, relativeRemainderY = 0.0
    private var receivingRelative = false

    private let id: String
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var permissionMonitor: Task<Void, Never>?
    private var captureGeneration = 0
    private var permissionsGranted = false
    private struct CaptureDisplay { let id: UInt32; let bounds: CGRect; let scaleX: Double; let scaleY: Double }
    private var displays: [CaptureDisplay] = []
    private var slowCallbackAt = 0.0
    private var hidden = false
    private var suppressPhysical = false
    private var frozenPoint: CGPoint?
    private var captureWindow: PointerCaptureWindow?
    private var previousApplication: NSRunningApplication?
    private weak var previousWindow: NSWindow?
    private weak var previousMainWindow: NSWindow?
    private var detached = false
    private var associatedForeground = false
    private var coalescing: Bool?
    private var held: Set<String> = []
    private var heldButtons: Set<Int> = []
    private var physicalModifiers: Set<String> = []
    private let diagnostic: (String) -> Void
    private var warpFailureAt = 0.0
    public var captured: ((CapturedInput) -> Bool)?
    public var interrupted: ((MacInputInterruption) -> Void)?
    private let injectionSource = CGEventSource(stateID: .hidSystemState)
    private static let marker: Int64 = 0x534d494e
    public var canCapture: Bool { CGPreflightListenEventAccess() }
    public var canInject: Bool { CGPreflightPostEventAccess() && AXIsProcessTrusted() }
    public func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    public func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        if !canCapture, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
    public init(peerID: String, diagnostic: @escaping (String) -> Void = { _ in }) {
        id = peerID; self.diagnostic = diagnostic; injectionSource?.localEventsSuppressionInterval = 0
    }
    public func requestPermissions() {
        if !canInject { requestAccessibility() } else if !canCapture { requestInputMonitoring() }
    }
    public func start() throws {
        guard canCapture, canInject else { throw InputAdapterError.permission }
        if let tap { if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }; return }
        captureGeneration += 1; let generation = captureGeneration
        permissionsGranted = true; refreshDisplays()
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let suppress = MainActor.assumeIsolated {
                let adapter = Unmanaged<MacInputAdapter>.fromOpaque(info).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if adapter.canCapture && adapter.canInject, let tap = adapter.tap {
                        let reason: MacInputInterruption = type == .tapDisabledByTimeout ? .captureTimedOut : .captureStopped
                        if reason == .captureStopped { adapter.cursorState(remoteTarget: false, suppressPhysical: false) }
                        // Restore interception first; timeout recovery keeps the remote cursor.
                        // AppKit cleanup must not run inside WindowServer's callback deadline.
                        CGEvent.tapEnable(tap: tap, enable: true)
                        let generation = adapter.captureGeneration
                        Task { @MainActor [weak adapter] in
                            guard let adapter, adapter.captureGeneration == generation else { return }
                            adapter.interrupted?(reason)
                        }
                    } else { adapter.stop(); adapter.interrupted?(.permissionRevoked) }
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
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { throw InputAdapterError.permission }
        coalescing = NSEvent.isMouseCoalescingEnabled; NSEvent.isMouseCoalescingEnabled = false
        self.tap = tap; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes); CGEvent.tapEnable(tap: tap, enable: true)
        // Preflight and Accessibility calls can perform IPC. Poll off the event run loop
        // instead of synchronously querying the system for every captured/injected event.
        permissionMonitor = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200)); guard !Task.isCancelled else { return }
                let allowed = CGPreflightListenEventAccess() && CGPreflightPostEventAccess() && AXIsProcessTrusted()
                await MainActor.run { [weak self] in
                    guard let self, self.tap != nil, self.captureGeneration == generation else { return }
                    self.permissionsGranted = allowed
                    if !allowed { self.stop(); self.interrupted?(.permissionRevoked) }
                }
            }
        }
    }
    public func refreshDisplays() {
        displays = NSScreen.screens.map { screen in
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
            let bounds = CGDisplayBounds(displayID)
            return CaptureDisplay(id: displayID, bounds: bounds,
                scaleX: Double(CGDisplayPixelsWide(displayID)) / max(1, bounds.width),
                scaleY: Double(CGDisplayPixelsHigh(displayID)) / max(1, bounds.height))
        }
    }
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return false }
        guard permissionsGranted else { stop(); interrupted?(.permissionRevoked); return false }
        if type == .keyDown || type == .keyUp || type == .flagsChanged {
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard let key = Self.keyNames[code] else { return false }
            var down = type == .keyDown
            if type == .flagsChanged {
                if key == "CapsLock" {
                    let first = captured?(CapturedInput("keyDown", key: key)) ?? false
                    let second = captured?(CapturedInput("keyUp", key: key)) ?? false
                    return first || second
                }
                down = !physicalModifiers.contains(key)
                if down { physicalModifiers.insert(key) } else { physicalModifiers.remove(key) }
            }
            return captured?(CapturedInput(down ? "keyDown" : "keyUp", key: key)) ?? false
        }
        if receivingRelative, suppressPhysical, [.mouseMoved,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged].contains(type), event.getIntegerValueField(.eventSourceUnixProcessID) != 0 { return false }
        let point = event.location
        guard let display = displays.first(where: { $0.bounds.contains(point) }) ?? displays.first else { return false }
        let displayID = display.id; let bounds = display.bounds
        var input = CapturedInput("move", deltaX: event.getDoubleValueField(.mouseEventDeltaX), deltaY: event.getDoubleValueField(.mouseEventDeltaY),
            screenID: id + ":" + String(displayID),
            x: Self.normalizedPosition(point.x, origin: bounds.minX, extent: bounds.width),
            y: Self.normalizedPosition(point.y, origin: bounds.minY, extent: bounds.height), hardwareMotion: event.getIntegerValueField(.eventSourceUnixProcessID) == 0)
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type) {
            input.type = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) ? "buttonDown" : "buttonUp"
            input.button = Int(event.getIntegerValueField(.mouseEventButtonNumber)); if input.button > 2 { return false }
        } else if type == .scrollWheel {
            input.type = "scroll"
            let precise = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            input.deltaY = event.getDoubleValueField(precise ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventDeltaAxis1)
            input.deltaX = event.getDoubleValueField(precise ? .scrollWheelEventPointDeltaAxis2 : .scrollWheelEventDeltaAxis2)
            input.preciseScroll = precise; input.scrollPhase = Int(event.getIntegerValueField(.scrollWheelEventScrollPhase)); input.momentumPhase = Int(event.getIntegerValueField(.scrollWheelEventMomentumPhase))
            if !precise { input.deltaX *= 40; input.deltaY *= 40 }
        } else {
            // Logical layout uses pixels; Quartz mouse deltas use display coordinates.
            input.deltaX *= display.scaleX
            input.deltaY *= display.scaleY
        }
        let consumed = captured?(input) ?? false
        // Session taps can consume delivery after WindowServer has already moved its cursor.
        // Warping does not synthesize another event and also works while we are background.
        if consumed, suppressPhysical, input.type == "move", (!hidden || !associatedForeground), let frozenPoint, event.location != frozenPoint { _ = CGWarpMouseCursorPosition(frozenPoint) }
        return consumed
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
        if input.type == "text", let text = input.text {
            let units = Array(text.utf16); guard !units.isEmpty, text.utf8.count <= 4096 else { return }
            let saved = held.filter { KeyboardMapping.modifiers.contains($0) }; for key in saved { try inject(CapturedInput("keyUp", key: key), screen: screen, x: x, y: y) }
            defer { for key in saved { try? inject(CapturedInput("keyDown", key: key), screen: screen, x: x, y: y) } }
            // Small UTF-16 batches preserve surrogate pairs; no ordinary keyboard input uses this path.
            var offset = 0
            while offset < units.count { var count = min(20, units.count - offset); if offset + count < units.count, (0xD800...0xDBFF).contains(units[offset + count - 1]) { count -= 1 }
                for down in [true, false] { guard let event = CGEvent(keyboardEventSource: injectionSource, virtualKey: 0, keyDown: down) else { throw InputAdapterError.event }; units.withUnsafeBufferPointer { buffer in event.keyboardSetUnicodeString(stringLength: count, unicodeString: buffer.baseAddress!.advanced(by: offset)) }; event.flags = []; event.setIntegerValueField(.eventSourceUserData, value: Self.marker); event.post(tap: .cghidEventTap) }; offset += count
            }; return
        }
        if input.type == "command", let command = input.command, ["desktopPrevious", "desktopNext", "overview"].contains(command) {
            let saved = held.filter { KeyboardMapping.modifiers.contains($0) }
            for modifier in saved { try inject(CapturedInput("keyUp", key: modifier), screen: screen, x: x, y: y) }
            let key = command == "overview" ? "ArrowUp" : command == "desktopPrevious" ? "ArrowLeft" : "ArrowRight"
            defer {
                try? inject(CapturedInput("keyUp", key: key), screen: screen, x: x, y: y)
                try? inject(CapturedInput("keyUp", key: "ControlLeft"), screen: screen, x: x, y: y)
                for modifier in saved { try? inject(CapturedInput("keyDown", key: modifier), screen: screen, x: x, y: y) }
            }
            try inject(CapturedInput("keyDown", key: "ControlLeft"), screen: screen, x: x, y: y)
            try inject(CapturedInput("keyDown", key: key), screen: screen, x: x, y: y); return
        }
        if input.type == "command", let command = input.command, let key = ["copy":"KeyC", "cut":"KeyX", "paste":"KeyV", "moveFiles":"KeyV", "undo":"KeyZ", "redo":"KeyZ"][command] {
            let saved = held.filter { KeyboardMapping.modifiers.contains($0) }
            for modifier in saved { try inject(CapturedInput("keyUp", key: modifier), screen: screen, x: x, y: y) }
            defer { if held.contains(key) { try? inject(CapturedInput("keyUp", key: key), screen: screen, x: x, y: y) }; for modifier in ["MetaLeft", "ShiftLeft", "AltLeft"] where held.contains(modifier) { try? inject(CapturedInput("keyUp", key: modifier), screen: screen, x: x, y: y) }; for modifier in saved { try? inject(CapturedInput("keyDown", key: modifier), screen: screen, x: x, y: y) } }
            try inject(CapturedInput("keyDown", key: "MetaLeft"), screen: screen, x: x, y: y)
            if command == "moveFiles" { try inject(CapturedInput("keyDown", key: "AltLeft"), screen: screen, x: x, y: y) }
            if command == "redo" { try inject(CapturedInput("keyDown", key: "ShiftLeft"), screen: screen, x: x, y: y) }
            try inject(CapturedInput("keyDown", key: key), screen: screen, x: x, y: y); try inject(CapturedInput("keyUp", key: key), screen: screen, x: x, y: y); return
        }
        let source = injectionSource
        var event: CGEvent?
        if input.type == "keyDown" || input.type == "keyUp", let key = input.key, let code = Self.keyNames.first(where: { $0.value == key })?.key {
            let down = input.type == "keyDown"
            let repeatKey = down && held.contains(key)
            if down { held.insert(key) } else { held.remove(key) }
            event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        } else if input.type == "relativeBegin" { receivingRelative = true; return
        } else if input.type == "relativeEnd" { receivingRelative = false; relativeRemainderX = 0; relativeRemainderY = 0; return
        } else if input.type == "relativeReset" {
            receivingRelative = true; relativeRemainderX = 0; relativeRemainderY = 0; return
        } else if input.type == "relativeMove" {
            guard input.deltaX.isFinite, input.deltaY.isFinite, abs(input.deltaX) <= 10000, abs(input.deltaY) <= 10000 else { return }
            relativeRemainderX += input.deltaX; relativeRemainderY += input.deltaY
            let dx = relativeRemainderX.rounded(.towardZero), dy = relativeRemainderY.rounded(.towardZero)
            relativeRemainderX -= dx; relativeRemainderY -= dy
            guard dx != 0 || dy != 0 else { return }
            let type: CGEventType = heldButtons.contains(0) ? .leftMouseDragged : heldButtons.contains(1) ? .rightMouseDragged : heldButtons.contains(2) ? .otherMouseDragged : .mouseMoved
            event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGEvent(source: nil)?.location ?? .zero, mouseButton: heldButtons.contains(1) ? .right : heldButtons.contains(2) ? .center : .left)
            event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx)); event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        } else if input.type == "move", let screen, let displayID = UInt32(screen.id.split(separator: ":").last ?? "") {
            guard CGDisplayIsActive(displayID) != 0 else { throw InputAdapterError.display }
            let bounds = CGDisplayBounds(displayID)
            let type: CGEventType = heldButtons.contains(0) ? .leftMouseDragged : heldButtons.contains(1) ? .rightMouseDragged : heldButtons.contains(2) ? .otherMouseDragged : .mouseMoved
            let button: CGMouseButton = heldButtons.contains(0) ? .left : heldButtons.contains(1) ? .right : .center
            let point = CGPoint(x: bounds.minX + min(0.99999, max(0, x)) * bounds.width,
                                y: bounds.minY + min(0.99999, max(0, y)) * bounds.height)
            if suppressPhysical { frozenPoint = point }
            if detached && NSApp.isActive {
                // Warping assists a detached foreground cursor; the marked CGEvent below
                // still delivers movement if WindowServer temporarily refuses this call.
                let result = CGWarpMouseCursorPosition(point)
                let now = ProcessInfo.processInfo.systemUptime
                if result != .success, now - warpFailureAt >= 5 {
                    warpFailureAt = now; diagnostic("InputCursorWarpFailed code=\(result.rawValue)")
                }
            }
            event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        } else if input.type == "buttonDown" || input.type == "buttonUp" {
            guard let button = CGMouseButton(rawValue: UInt32(input.button)) else { return }
            let down = input.type == "buttonDown"
            if down { heldButtons.insert(input.button) } else { heldButtons.remove(input.button) }
            let type: CGEventType = input.button == 0 ? (down ? .leftMouseDown : .leftMouseUp)
                : input.button == 1 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
            event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGEvent(source: nil)?.location ?? .zero, mouseButton: button)
            if let count = input.clickCount { event?.setIntegerValueField(.mouseEventClickState, value: Int64(count)) }
        } else if input.type == "scroll" {
            event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                            wheel1: Int32(input.deltaY.rounded()), wheel2: Int32(input.deltaX.rounded()), wheel3: 0)
            event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: input.preciseScroll == true ? 1 : 0)
            event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(max(0, min(255, input.scrollPhase ?? 0))))
            event?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(max(0, min(255, input.momentumPhase ?? 0))))
        } else { return }
        guard let event else { throw InputAdapterError.event }
        var flags: CGEventFlags = CGEventSource.flagsState(.combinedSessionState).intersection(.maskAlphaShift)
        for key in held {
            if key.hasPrefix("Control") { flags.insert(.maskControl) }; if key.hasPrefix("Shift") { flags.insert(.maskShift) }
            if key.hasPrefix("Alt") { flags.insert(.maskAlternate) }; if key.hasPrefix("Meta") { flags.insert(.maskCommand) }
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker); event.post(tap: .cghidEventTap)
    }
    public func cursorState(remoteTarget: Bool, suppressPhysical: Bool) {
        if remoteTarget && !hidden {
            Self.isCapturingRemotePointer = true
            previousMainWindow = NSApp.mainWindow
            previousApplication = NSWorkspace.shared.frontmostApplication
            if previousApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { previousWindow = NSApp.keyWindow; previousApplication = nil }
            if captureWindow == nil {
                let window = PointerCaptureWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
                window.isOpaque = false; window.backgroundColor = .clear; window.alphaValue = 0.001; window.hasShadow = false; window.ignoresMouseEvents = true
                window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                window.isReleasedWhenClosed = false; captureWindow = window
            }
            // Keep management windows visible while the transparent cursor context is active.
            let closedWindows = NSApp.windows.filter { $0 !== captureWindow && !$0.isVisible }
            captureWindow?.makeKeyAndOrderFront(nil); NSApp.activate()
            if !NSApp.isActive {
                // Foreground fallback is optional and may wait for an AX response. Never
                // do that inside the event tap; also bound this particular AX object's IPC.
                let generation = captureGeneration
                Task { @MainActor [weak self] in
                    guard let self, self.captureGeneration == generation, self.hidden, self.suppressPhysical, !NSApp.isActive else { return }
                    let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
                    _ = AXUIElementSetMessagingTimeout(application, 0.02)
                    _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                }
            }
            for window in closedWindows where window.isVisible { window.orderOut(nil) }
            CGDisplayHideCursor(CGMainDisplayID()); hidden = true
        }
        if self.suppressPhysical != suppressPhysical { frozenPoint = suppressPhysical ? CGEvent(source: nil)?.location : nil }
        if !suppressPhysical { receivingRelative = false }
        self.suppressPhysical = suppressPhysical
        if !NSApp.isActive { associatedForeground = false }
        if detached != suppressPhysical || suppressPhysical && hidden && NSApp.isActive && !associatedForeground {
            if CGAssociateMouseAndMouseCursorPosition(suppressPhysical ? 0 : 1) == .success {
                detached = suppressPhysical; associatedForeground = suppressPhysical && NSApp.isActive
            }
        }
        if !remoteTarget && hidden {
            Self.isCapturingRemotePointer = false
            CGDisplayShowCursor(CGMainDisplayID()); hidden = false
            captureWindow?.orderOut(nil)
            if let previousApplication { NSApp.yieldActivation(to: previousApplication); previousApplication.activate(from: .current, options: []) }
            else { if previousMainWindow?.isVisible == true { previousMainWindow?.makeMain() }; if previousWindow?.isVisible == true { previousWindow?.makeKeyAndOrderFront(nil) } }
            previousApplication = nil; previousWindow = nil; previousMainWindow = nil
        }
    }
    public func stop() {
        captureGeneration += 1
        permissionMonitor?.cancel(); permissionMonitor = nil; permissionsGranted = false
        cursorState(remoteTarget: false, suppressPhysical: false)
        Self.isCapturingRemotePointer = false
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let coalescing { NSEvent.isMouseCoalescingEnabled = coalescing }; coalescing = nil
        tap = nil; source = nil; held = []; heldButtons = []; physicalModifiers = []
    }
    public static let keyNames: [UInt16: String] = [
        0:"KeyA",1:"KeyS",2:"KeyD",3:"KeyF",4:"KeyH",5:"KeyG",6:"KeyZ",7:"KeyX",8:"KeyC",9:"KeyV",11:"KeyB",
        12:"KeyQ",13:"KeyW",14:"KeyE",15:"KeyR",16:"KeyY",17:"KeyT",18:"Digit1",19:"Digit2",20:"Digit3",21:"Digit4",
        22:"Digit6",23:"Digit5",24:"Equal",25:"Digit9",26:"Digit7",27:"Minus",28:"Digit8",29:"Digit0",30:"BracketRight",
        31:"KeyO",32:"KeyU",33:"BracketLeft",34:"KeyI",35:"KeyP",36:"Enter",37:"KeyL",38:"KeyJ",39:"Quote",40:"KeyK",
        41:"Semicolon",42:"Backslash",43:"Comma",44:"Slash",45:"KeyN",46:"KeyM",47:"Period",48:"Tab",49:"Space",
        50:"Backquote",51:"Backspace",53:"Escape",54:"MetaRight",55:"MetaLeft",56:"ShiftLeft",57:"CapsLock",58:"AltLeft",
        59:"ControlLeft",60:"ShiftRight",61:"AltRight",62:"ControlRight",65:"NumpadDecimal",67:"NumpadMultiply",69:"NumpadAdd",
        71:"NumLock",75:"NumpadDivide",76:"NumpadEnter",78:"NumpadSubtract",82:"Numpad0",83:"Numpad1",84:"Numpad2",
        85:"Numpad3",86:"Numpad4",87:"Numpad5",88:"Numpad6",89:"Numpad7",91:"Numpad8",92:"Numpad9",96:"F5",97:"F6",
        98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",109:"F10",111:"F12",114:"Insert",115:"Home",116:"PageUp",117:"Delete",
        118:"F4",119:"End",120:"F2",121:"PageDown",122:"F1",123:"ArrowLeft",124:"ArrowRight",125:"ArrowDown",126:"ArrowUp"]
}
public enum InputAdapterError: Error { case permission, event, display }

// A one-pixel transparent key window supplies the foreground context required by
// Apple's public cursor API. No private WindowServer API or root event tap is used.
@MainActor
private final class PointerCaptureWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
