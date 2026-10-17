import AppKit
import QuartzCore
import ScreenCaptureKit
import Vision

@MainActor final class MacComputerAdapter {
    private var activeControl: JSONValue = .null
    private var virtualPoint = CGPoint.zero
    private var independentKeys = Set<String>(), independentButtons = Set<Int>()
    var defaultControlMode = "user_mouse"
    var independent: Bool { activeControl["mode"].string == "independent" }
    func prepareControl(_ args: JSONValue) throws -> JSONValue {
        let mode = args["control_mode"].string ?? defaultControlMode
        guard ["user_mouse", "independent"].contains(mode) else {
            throw ComputerUseError.message("control_mode_unsupported")
        }
        if mode == "user_mouse" { return .object(["mode": .string(mode)]) }
        guard AXIsProcessTrusted() else { throw ComputerUseError.message("input_permission_missing") }
        let query = args["application"].string?.lowercased()
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
                && (query == nil
                    ? app.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier
                    : app.localizedName?.lowercased() == query || app.bundleIdentifier?.lowercased() == query
                        || app.executableURL?.deletingPathExtension().lastPathComponent.lowercased() == query)
        }
        guard apps.count == 1, let app = apps.first else {
            throw ComputerUseError.message(apps.isEmpty ? "application_not_found" : "application_ambiguous")
        }
        let windows =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        guard
            let window = windows.first(where: {
                ($0[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier)
                    && ($0[kCGWindowLayer as String] as? Int) == 0
            }), let number = window[kCGWindowNumber as String] as? Int
        else { throw ComputerUseError.message("application_window_unavailable") }
        let context: JSONValue = .object([
            "mode": .string(mode), "process_id": .number(Double(app.processIdentifier)),
            "window_number": .number(Double(number)),
            "application": .string(app.localizedName ?? args["application"].string ?? "Application"),
        ])
        _ = try target(context)
        return context
    }
    private func target(_ context: JSONValue) throws -> (window: JSONValue, bounds: CGRect) {
        guard let pid = context["process_id"].number, let number = context["window_number"].number else {
            throw ComputerUseError.message("independent_target_missing")
        }
        let windows =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        guard
            let window = windows.first(where: {
                ($0[kCGWindowNumber as String] as? Int) == Int(number)
                    && ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid)
            }), let box = window[kCGWindowBounds as String] as? [String: Double], let x = box["X"], let y = box["Y"],
            let width = box["Width"], let height = box["Height"], width > 0, height > 0
        else { throw ComputerUseError.message("application_window_unavailable") }
        let value: JSONValue = .object([
            "window_id": .string("mac:\(Int(pid)):\(Int(number))"), "process_id": .number(pid),
            "process_name": context["application"], "title": .string(window[kCGWindowName as String] as? String ?? ""),
            "left": .number(x), "top": .number(y), "right": .number(x + width), "bottom": .number(y + height),
        ])
        return (value, CGRect(x: x, y: y, width: width, height: height))
    }
    func beginControl(_ context: JSONValue) {
        activeControl = context;
        logicalTextTarget = nil;
        independentKeys = [];
        independentButtons = []
        if let snapshot = try? target(context) {
            virtualPoint = CGPoint(x: snapshot.bounds.midX, y: snapshot.bounds.midY)
        }
        pointer.stop()
        if independent {
            pointer.keepVisible = showHints
            let height =
                NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                        == CGMainDisplayID()
                })?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
            if showHints { pointer.mark(at: NSPoint(x: virtualPoint.x, y: height - virtualPoint.y), kind: "position") }
        }
    }
    private var logicalTextTarget: AXUIElement?
    private func backgroundElement(at point: CGPoint) throws -> AXUIElement {
        guard let pid = activeControl["process_id"].number else {
            throw ComputerUseError.message("independent_target_missing")
        }
        let root = AXUIElementCreateApplication(pid_t(pid));
        AXUIElementSetMessagingTimeout(root, 0.08)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &element) == .success, let element
        else { throw ComputerUseError.message("background_click_requires_accessible_control") }
        AXUIElementSetMessagingTimeout(element, 0.08);
        return element
    }
    private func editable(_ element: AXUIElement) -> Bool {
        var available = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &available) == .success
            && available.boolValue
    }
    private func pressTarget(_ element: AXUIElement) throws -> AXUIElement {
        var current = element
        for _ in 0..<8 {
            var actions: CFArray?
            if AXUIElementCopyActionNames(current, &actions) == .success,
                (actions as? [String])?.contains(kAXPressAction) == true
            {
                return current
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                let parent, CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { break }
            current = parent as! AXUIElement;
            AXUIElementSetMessagingTimeout(current, 0.08)
        }
        throw ComputerUseError.message("background_click_requires_accessible_control")
    }
    func validatePlatformAction(_ action: JSONValue, screen: ScreenGeometry, x: Double, y: Double) throws {
        guard independent else { return }
        if action["type"].string == "click" {
            guard let id = UInt32(screen.id.split(separator: ":").last ?? "") else {
                throw ComputerUseError.message("screen_unavailable")
            }
            let bounds = CGDisplayBounds(id);
            let point = CGPoint(x: bounds.minX + x * bounds.width, y: bounds.minY + y * bounds.height)
            let element = try backgroundElement(at: point)
            if !editable(element) { _ = try pressTarget(element) }
        } else if action["type"].string == "type" && logicalTextTarget == nil {
            throw ComputerUseError.message("background_text_target_unavailable")
        }
    }
    func injectIndependent(_ input: CapturedInput, screen: ScreenGeometry?, x: Double, y: Double) throws {
        guard independent, AXIsProcessTrusted(), Self.desktopAvailable else {
            throw ComputerUseError.message("independent_input_unavailable")
        }
        let snapshot = try target(activeControl)
        switch input.type {
        case "move":
            guard let screen, let id = UInt32(screen.id.split(separator: ":").last ?? "") else {
                throw ComputerUseError.message("screen_unavailable")
            }
            let bounds = CGDisplayBounds(id);
            let point = CGPoint(x: bounds.minX + x * bounds.width, y: bounds.minY + y * bounds.height)
            guard snapshot.bounds.contains(point) else {
                throw ComputerUseError.message("coordinate_outside_target_window")
            };
            virtualPoint = point
        case "buttonDown":
            guard input.button == 0 else { throw ComputerUseError.message("independent_action_not_supported") }
            let element = try backgroundElement(at: virtualPoint)
            if editable(element) {
                logicalTextTarget = element;
                return
            }
            let target = try pressTarget(element)
            AXUIElementSetMessagingTimeout(target, 0.8)
            let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
            guard result == .success else {
                throw ComputerUseError.message("background_click_rejected:\(result.rawValue)")
            }
        case "buttonUp": break
        case "text":
            guard let element = logicalTextTarget, editable(element) else {
                throw ComputerUseError.message("background_text_target_unavailable")
            }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
                let text = value as? String, text.utf8.count <= 131072
            else { throw ComputerUseError.message("background_text_value_unavailable_or_too_large") }
            let old = text as NSString;
            var selected: CFTypeRef?;
            var range = CFRange(location: old.length, length: 0)
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selected) == .success,
                let selected, CFGetTypeID(selected) == AXValueGetTypeID()
            {
                _ = AXValueGetValue(selected as! AXValue, .cfRange, &range)
            }
            guard range.location >= 0, range.length >= 0, range.location + range.length <= old.length else {
                throw ComputerUseError.message("background_text_selection_invalid")
            }
            let replacement = old.replacingCharacters(
                in: NSRange(location: range.location, length: range.length), with: input.text ?? "")
            guard
                AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, replacement as CFString)
                    == .success
            else { throw ComputerUseError.message("background_text_rejected") }
            var end = CFRange(location: range.location + (input.text ?? "").utf16.count, length: 0)
            if let value = AXValueCreate(.cfRange, &end) {
                _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            }
        default: throw ComputerUseError.message("independent_action_not_supported")
        }
    }
    private func captureState(_ context: JSONValue) -> JSONValue {
        var state = inputState()
        if context["mode"].string != "independent" {
            state["control_target_window"] = .null;
            state["ai_cursor_position"] = .null
        }
        return state
    }
    var showHints = true { didSet { if !showHints { pointer.stop() } } }
    private let pointer = MCPPointerOverlay()
    private var hint: NSPanel? { pointer.panel }
    private var ocrJob: OCRJob?
    static var desktopAvailable: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool != true
    }
    func info(_ input: MacInputAdapter) -> JSONValue {
        let process = ProcessInfo.processInfo
        let available =
            (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey
            ]).volumeAvailableCapacityForImportantUsage) ?? 0
        return .object([
            "platform": .string("macos"), "os_version": .string(process.operatingSystemVersionString),
            "hostname": .string(process.hostName), "cpu": .string(cpuName()),
            "cpu_cores": .number(Double(process.processorCount)),
            "memory_bytes": .number(Double(process.physicalMemory)), "home_free_bytes": .number(Double(available)),
            "input_state": inputState(),
            "mcp_features": .object([
                "ocr": .bool(true), "controls": .bool(AXIsProcessTrusted()), "stable_region": .bool(true),
                "relative_move": .bool(true), "key_hold": .bool(true), "pointer_animation": .bool(true),
                "pointer_animation_enabled": .bool(showHints),
                "pointer_animation_scope": .string("presentation_overlay"),
                "cursor_style": .string(independent ? "independent" : "system"),
                "control_modes": .array([.string("user_mouse"), .string("independent")]),
                "default_control_mode": .string(defaultControlMode),
                "background_control_scope": .string("application_window"),
            ]),
            "permissions": .object([
                "screen_capture": .bool(CGPreflightScreenCaptureAccess()), "input_injection": .bool(input.canInject),
                "input_monitoring": .bool(input.canCapture), "desktop_available": .bool(Self.desktopAvailable),
            ]),
        ])
    }
    private func cpuName() -> String {
        var size = 0;
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" };
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "Unknown" };
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    func capture(_ screen: ScreenGeometry) async throws -> JSONValue {
        try await capture(screen, options: .object([:]), shouldContinue: { true })
    }
    func capture(_ screen: ScreenGeometry, options: JSONValue, shouldContinue: @escaping @MainActor () -> Bool)
        async throws -> JSONValue
    {
        try ComputerUseService.validateObservationOptions(options)
        guard Self.desktopAvailable else { throw ComputerUseError.message("desktop_locked_or_unavailable") }
        guard let displayID = UInt32(screen.id.split(separator: ":").last ?? "") else {
            throw ComputerUseError.message("screen_unavailable")
        }
        let screenBounds = CGDisplayBounds(displayID)
        let context = options["_control_context"]
        let captureWindowKey = context["mode"].string == "independent" ? "control_target_window" : "foreground_window"
        let independentWindow = context["mode"].string == "independent" ? try target(context) : nil
        let fullBounds = independentWindow?.bounds ?? screenBounds
        let defaultROI: JSONValue = .object([
            "x": .number((fullBounds.minX - screenBounds.minX) / screenBounds.width),
            "y": .number((fullBounds.minY - screenBounds.minY) / screenBounds.height),
            "width": .number(fullBounds.width / screenBounds.width),
            "height": .number(fullBounds.height / screenBounds.height),
        ])
        let roi = options["capture_region"] == .null ? defaultROI : options["capture_region"]
        let bounds = CGRect(
            x: screenBounds.minX + roi["x"].number! * screenBounds.width,
            y: screenBounds.minY + roi["y"].number! * screenBounds.height,
            width: roi["width"].number! * screenBounds.width, height: roi["height"].number! * screenBounds.height)
        let nativeWidth = CGDisplayCopyDisplayMode(displayID)?.pixelWidth ?? CGDisplayPixelsWide(displayID),
            nativeHeight = CGDisplayCopyDisplayMode(displayID)?.pixelHeight ?? CGDisplayPixelsHigh(displayID)
        let maximum = Int(options["thumbnail_max_dimension"].number ?? options["max_dimension"].number ?? 0)
        func size(_ scale: Double) -> (Int, Int) {
            let pixelWidth = bounds.width * scale, pixelHeight = bounds.height * scale
            let ratio = maximum > 0 ? min(1, Double(maximum) / max(pixelWidth, pixelHeight)) : 1
            return (max(1, Int((pixelWidth * ratio).rounded())), max(1, Int((pixelHeight * ratio).rounded())))
        }
        let backingScale =
            NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
            })?.backingScaleFactor ?? 1
        var (width, height) = size(backingScale >= 2 ? 2 : 1)
        let started = ContinuousClock.now
        if options["text_only"] == .bool(true), options["include_ocr"] != .bool(true) {
            let state = captureState(context);
            let semantic = controls(
                options: options, bounds: bounds, width: width, height: height, shouldContinue: shouldContinue)
            guard shouldContinue() else { throw ComputerUseError.message("capture_interrupted") }
            let current = captureState(context);
            let analysis: JSONValue = .object([
                "controls": current[captureWindowKey]["window_id"] == state[captureWindowKey]["window_id"]
                    ? semantic : .object(["status": .string("window_changed_during_inspection")])
            ])
            return .object([
                "width": .number(Double(width)), "height": .number(Double(height)),
                "captured_at": .string(ISO8601DateFormatter().string(from: Date())),
                "desktop_bounds": Self.rect(bounds), "screen_desktop_bounds": Self.rect(screenBounds),
                "normalized_capture_region": roi, "desktop_coordinate_space": .string("quartz_points"),
                "display_pixel_size": .object([
                    "width": .number(Double(nativeWidth)), "height": .number(Double(nativeHeight)),
                ]), "input_state": state, "analysis": analysis,
                "capture_and_analysis_ms": .number(ComputerUseService.elapsed(started)), "image_omitted": .bool(true),
                "pixels_captured": .bool(false),
            ])
        }
        guard CGPreflightScreenCaptureAccess(), Self.desktopAvailable else {
            throw ComputerUseError.message("screen_capture_permission_missing_or_desktop_locked")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let id = UInt32(screen.id.split(separator: ":").last ?? ""),
            let display = content.displays.first(where: { $0.displayID == id })
        else { throw ComputerUseError.message("screen_unavailable") }
        let config = SCStreamConfiguration();
        config.showsCursor = true
        config.sourceRect = CGRect(
            x: bounds.minX - screenBounds.minX, y: bounds.minY - screenBounds.minY, width: bounds.width,
            height: bounds.height)
        let excluded = content.windows.filter { Int($0.windowID) == hint?.windowNumber }
        let filter: SCContentFilter
        if let independentWindow {
            guard let window = content.windows.first(where: { Double($0.windowID) == context["window_number"].number })
            else { throw ComputerUseError.message("application_window_unavailable") }
            guard independentWindow.bounds.contains(bounds) else {
                throw ComputerUseError.message("capture_region_outside_target_window")
            }
            filter = SCContentFilter(desktopIndependentWindow: window);
            config.ignoreShadowsSingleWindow = true;
            config.showsCursor = false
            config.sourceRect =
                bounds == independentWindow.bounds
                ? .null
                : CGRect(
                    x: bounds.minX - independentWindow.bounds.minX, y: bounds.minY - independentWindow.bounds.minY,
                    width: bounds.width, height: bounds.height)
        } else {
            filter = SCContentFilter(display: display, excludingWindows: excluded)
        }
        // Capture Retina backing pixels directly; never enlarge a 1x bitmap to claim 2x.
        var renderScale = filter.pointPixelScale >= 2 ? 2.0 : 1.0
        var fallbackReason: JSONValue = renderScale == 2 ? .null : .string("source_render_scale_below_2")
        func configure(_ scale: Double) {
            (width, height) = size(scale);
            config.width = width;
            config.height = height
            config.captureResolution = scale == 2 ? .best : .nominal
        }
        configure(renderScale)
        func frame() async throws -> CGImage {
            guard shouldContinue() else { throw ComputerUseError.message("capture_interrupted") };
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
        var image: CGImage
        do { image = try await frame() } catch {
            guard renderScale == 2, !Task.isCancelled, shouldContinue(), CGPreflightScreenCaptureAccess(),
                Self.desktopAvailable
            else { throw error }
            renderScale = 1;
            fallbackReason = .string("retina_capture_failed");
            configure(1)
            image = try await frame()
        }
        var capturedAt = Date();
        var stability: JSONValue = .object(["status": .string("not_requested")])
        if options["wait_for_stable"] == .bool(true) {
            let region = try Self.region(options["stability_region"], width: image.width, height: image.height)
            let timeout = try ComputerUseService.integer(
                options, "stability_timeout_ms", default: 2000, range: 200...5000)
            let interval = try ComputerUseService.integer(
                options, "stability_interval_ms", default: 200, range: 100...1000)
            let required = try ComputerUseService.integer(options, "stability_samples", default: 3, range: 2...5)
            let threshold = options["stability_threshold"].number ?? 3
            var previous = Self.sample(image, region: region);
            var matching = 1, samples = 1, score = Double.infinity
            while ComputerUseService.elapsed(started) < Double(timeout) && matching < required {
                try await Task.sleep(
                    for: .milliseconds(min(interval, max(1, timeout - Int(ComputerUseService.elapsed(started))))));
                guard shouldContinue() else { throw ComputerUseError.message("capture_interrupted") }
                if ComputerUseService.elapsed(started) >= Double(timeout) { break }
                image = try await frame();
                capturedAt = Date();
                let next = Self.sample(image, region: region);
                score = Self.difference(previous, next);
                matching = score <= threshold ? matching + 1 : 1;
                previous = next;
                samples += 1
            }
            stability = .object([
                "status": .string(matching >= required ? "stable_in_region" : "timeout"),
                "samples_taken": .number(Double(samples)), "matched_frames": .number(Double(matching)),
                "difference_score": score.isFinite ? .number(score) : .null, "region": Self.rect(region),
                "elapsed_ms": .number(ComputerUseService.elapsed(started)), "proves_interactivity": .bool(false),
            ])
        }
        let state = captureState(context);
        var analysis: JSONValue = .object(["stability": stability])
        if options["include_ocr"] == .bool(true) {
            let region = try Self.region(options["ocr_region"], width: image.width, height: image.height)
            let box = ImageBox(image);
            let limit = try ComputerUseService.integer(options, "max_ocr_results", default: 100, range: 1...200)
            if let current = ocrJob, current.result == nil {
                analysis["ocr"] = .object(["status": .string("recognizer_busy")])
            } else {
                let job = OCRJob();
                ocrJob = job;
                let language = options["ocr_language"].string
                Task.detached(priority: .userInitiated) {
                    job.complete(
                        Self.recognize(
                            box.image, region: region, language: language, limit: limit, request: job.request))
                }
                let ocrStart = ContinuousClock.now
                while job.result == nil, ComputerUseService.elapsed(ocrStart) < 4000, shouldContinue() {
                    try await Task.sleep(for: .milliseconds(50))
                }
                if let result = job.result {
                    analysis["ocr"] = result
                } else {
                    job.request.cancel();
                    analysis["ocr"] = .object(["status": .string("recognition_timeout")])
                }
            }
        }
        if options["include_controls"] == .bool(true) {
            analysis["controls"] = controls(
                options: options, bounds: bounds, width: image.width, height: image.height,
                shouldContinue: shouldContinue)
        }
        guard shouldContinue() else { throw ComputerUseError.message("capture_interrupted") }
        let current = inputState()
        if current[captureWindowKey]["window_id"] != state[captureWindowKey]["window_id"]
            && analysis["controls"] != .null
        {
            analysis["controls"] = .object(["status": .string("window_changed_during_inspection")])
        }
        var result: JSONValue = .object([
            "width": .number(Double(image.width)), "height": .number(Double(image.height)),
            "captured_at": .string(ISO8601DateFormatter().string(from: capturedAt)),
            "desktop_bounds": Self.rect(bounds), "screen_desktop_bounds": Self.rect(screenBounds),
            "normalized_capture_region": roi, "desktop_coordinate_space": .string("quartz_points"),
            "display_pixel_size": .object([
                "width": .number(Double(nativeWidth)), "height": .number(Double(nativeHeight)),
            ]), "input_state": state, "analysis": analysis,
            "capture_and_analysis_ms": .number(ComputerUseService.elapsed(started)),
            "image_omitted": .bool(options["text_only"] == .bool(true)), "pixels_captured": .bool(true),
        ])
        result["capture_resolution"] = .object([
            "requested": .string("retina_2x"), "source_render_scale": .number(renderScale),
            "fallback_reason": fallbackReason, "max_dimension": .number(Double(maximum)),
        ])
        if options["text_only"] != .bool(true) {
            image = try Self.annotate(image, options: options, state: state, bounds: bounds)
            let transport = options["_transport_jpeg"] == .bool(true),
                jpeg = transport || options["image_format"].string == "jpeg"
            let rep = NSBitmapImageRep(cgImage: image);
            var bytes: Data?
            if transport {
                for quality in [0.72, 0.50, 0.32, 0.18] {
                    bytes = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]);
                    if (bytes?.count ?? Int.max) <= 300 * 1024 { break }
                }
            } else {
                bytes = rep.representation(
                    using: jpeg ? .jpeg : .png,
                    properties: jpeg ? [.compressionFactor: (options["jpeg_quality"].number ?? 80) / 100] : [:])
            }
            guard let bytes, bytes.count <= (transport ? 300 * 1024 : 10 * 1024 * 1024) else {
                throw ComputerUseError.message("screenshot_too_large")
            }
            result["data"] = .string(bytes.base64EncodedString());
            result["mime_type"] = .string(jpeg ? "image/jpeg" : "image/png")
            result["image_annotated"] = .bool(
                options["mark_cursor"] == .bool(true) || options["preview_point"] != .null)
        }
        return result
    }
    func inputState() -> JSONValue {
        let app = NSWorkspace.shared.frontmostApplication;
        let pid = app?.processIdentifier ?? 0
        let windows =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let window = windows.first {
            ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        let box = window?[kCGWindowBounds as String] as? [String: Double] ?? [:]
        let windowID = window?[kCGWindowNumber as String] as? Int;
        let point = CGEvent(source: nil)?.location ?? .zero
        var foreground: JSONValue = .object([
            "process_id": .number(Double(pid)), "process_name": .string(app?.localizedName ?? "Unknown"),
            "title": .string(window?[kCGWindowName as String] as? String ?? ""),
        ])
        foreground["window_id"] = windowID.map { .string("mac:\(pid):\($0)") } ?? .null
        foreground["bundle_id"] = app?.bundleIdentifier.map(JSONValue.string) ?? .null
        if let x = box["X"], let width = box["Width"] {
            foreground["left"] = .number(x);
            foreground["right"] = .number(x + width)
        }
        if let y = box["Y"], let height = box["Height"] {
            foreground["top"] = .number(y);
            foreground["bottom"] = .number(y + height)
        }
        var result: JSONValue = .object([
            "input_injection_blocked": .bool(!AXIsProcessTrusted()), "foreground_window": foreground,
            "cursor_position": .object([
                "x": .number(point.x), "y": .number(point.y), "coordinate_space": .string("quartz_points"),
            ]),
        ])
        if independent {
            result["control_target_window"] = (try? target(activeControl).window) ?? .null;
            result["ai_cursor_position"] = .object([
                "x": .number(virtualPoint.x), "y": .number(virtualPoint.y),
                "coordinate_space": .string("quartz_points"),
            ])
        }
        return result

    }
    func moveRelative(_ input: CapturedInput) throws {
        guard AXIsProcessTrusted(), Self.desktopAvailable, let source = CGEventSource(stateID: .hidSystemState),
            let old = CGEvent(source: nil)?.location,
            let event = CGEvent(
                mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: old.x + input.deltaX, y: old.y + input.deltaY), mouseButton: .left)
        else { throw InputAdapterError.permission }
        source.localEventsSuppressionInterval = 0;
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(input.deltaX.rounded()));
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(input.deltaY.rounded()));
        event.setIntegerValueField(.eventSourceUserData, value: 0x534d494e);
        event.post(tap: .cghidEventTap)
    }
    private final class OCRJob: @unchecked Sendable {
        let request = VNRecognizeTextRequest();
        private let lock = NSLock();
        private var value: JSONValue?
        var result: JSONValue? {
            lock.lock();
            defer { lock.unlock() };
            return value
        }
        func complete(_ result: JSONValue) {
            lock.lock();
            value = result;
            lock.unlock()
        }
    }
    private final class ImageBox: @unchecked Sendable {
        let image: CGImage;
        init(_ image: CGImage) { self.image = image }
    }
    nonisolated private static func rect(_ value: CGRect) -> JSONValue {
        .object([
            "x": .number(value.minX), "y": .number(value.minY), "width": .number(value.width),
            "height": .number(value.height),
        ])
    }
    nonisolated private static func region(_ value: JSONValue, width: Int, height: Int) throws -> CGRect {
        if value == .null { return CGRect(x: 0, y: 0, width: width, height: height) }
        let rect = CGRect(
            x: value["x"].number ?? -1, y: value["y"].number ?? -1, width: value["width"].number ?? 0,
            height: value["height"].number ?? 0)
        guard rect.minX >= 0, rect.minY >= 0, rect.width > 0, rect.height > 0, rect.maxX <= Double(width),
            rect.maxY <= Double(height)
        else { throw ComputerUseError.message("analysis_region_outside_observation") };
        return rect
    }
    nonisolated static func recognize(
        _ image: CGImage, region: CGRect, language: String?, limit: Int,
        request: VNRecognizeTextRequest = VNRecognizeTextRequest()
    ) -> JSONValue {
        guard let crop = image.cropping(to: region.integral) else { return .object(["status": .string("unavailable")]) }
        do {
            request.recognitionLevel = .accurate;
            request.usesLanguageCorrection = false;
            request.automaticallyDetectsLanguage = true
            if let language {
                request.recognitionLanguages = [language]
            } else {
                request.recognitionLanguages = ["zh-Hans", "en-US"]
            }
            try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
            let values = (request.results ?? []).prefix(limit).compactMap { item -> JSONValue? in
                guard let candidate = item.topCandidates(1).first else { return nil };
                let box = item.boundingBox
                return .object([
                    "text": .string(candidate.string), "confidence": .number(Double(candidate.confidence)),
                    "bounds": rect(
                        CGRect(
                            x: region.minX + box.minX * region.width, y: region.minY + (1 - box.maxY) * region.height,
                            width: box.width * region.width, height: box.height * region.height)),
                    "coordinate_space": .string("screenshot_pixels"),
                ])
            }
            return .object([
                "status": .string("available"), "engine": .string("apple_vision"),
                "language": language.map(JSONValue.string) ?? .null, "items": .array(values),
                "truncated": .bool((request.results?.count ?? 0) > limit), "region": rect(region),
                "text_does_not_prove_clickability": .bool(true),
            ])
        } catch {
            return .object([
                "status": .string("unavailable"), "engine": .string("apple_vision"),
                "error": .string("recognition_failed_or_language_unavailable"),
            ])
        }
    }
    nonisolated static func sample(_ image: CGImage, region: CGRect) -> [UInt8] {
        guard let crop = image.cropping(to: region.integral) else { return [] };
        var bytes = [UInt8](repeating: 0, count: 40 * 30 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            if let context = CGContext(
                data: buffer.baseAddress, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 160,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            {
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 40, height: 30))
            }
        }
        return bytes
    }
    nonisolated static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return .infinity };
        var total = 0;
        for i in 0..<a.count where i % 4 != 3 { total += abs(Int(a[i]) - Int(b[i])) };
        return Double(total) / Double(a.count / 4 * 3)
    }
    static func annotate(_ image: CGImage, options: JSONValue, state: JSONValue, bounds: CGRect) throws -> CGImage {
        var points: [CGPoint] = []
        if options["mark_cursor"] == .bool(true), let x = state["cursor_position"]["x"].number,
            let y = state["cursor_position"]["y"].number
        {
            points.append(
                CGPoint(
                    x: (x - bounds.minX) / bounds.width * Double(image.width),
                    y: (y - bounds.minY) / bounds.height * Double(image.height)))
        }
        if options["preview_point"] != .null {
            let point = CGPoint(
                x: options["preview_point"]["x"].number ?? -1, y: options["preview_point"]["y"].number ?? -1);
            guard point.x >= 0, point.y >= 0, point.x < Double(image.width), point.y < Double(image.height) else {
                throw ComputerUseError.message("preview_point_outside_observation")
            };
            points.append(point)
        }
        if points.isEmpty { return image }
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ComputerUseError.message("image_annotation_unavailable") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height));
        context.setStrokeColor(NSColor.systemRed.cgColor);
        context.setLineWidth(2)
        for point in points {
            let y = Double(image.height) - point.y;
            context.strokeEllipse(in: CGRect(x: point.x - 10, y: y - 10, width: 20, height: 20));
            context.move(to: CGPoint(x: point.x - 15, y: y));
            context.addLine(to: CGPoint(x: point.x + 15, y: y));
            context.move(to: CGPoint(x: point.x, y: y - 15));
            context.addLine(to: CGPoint(x: point.x, y: y + 15));
            context.strokePath()
        }
        guard let result = context.makeImage() else { throw ComputerUseError.message("image_annotation_unavailable") };
        return result
    }
    private func controls(options: JSONValue, bounds: CGRect, width: Int, height: Int, shouldContinue: () -> Bool)
        -> JSONValue
    {
        let context = options["_control_context"]
        let application =
            context["mode"].string == "independent"
            ? NSRunningApplication(processIdentifier: pid_t(context["process_id"].number ?? 0))
            : NSWorkspace.shared.frontmostApplication
        guard AXIsProcessTrusted(), let application else {
            return .object(["status": .string("permission_missing_or_no_target")])
        }
        let root = AXUIElementCreateApplication(application.processIdentifier);
        AXUIElementSetMessagingTimeout(root, 0.05)
        let started = ContinuousClock.now;
        let limit = Int(options["max_controls"].number ?? 50)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?;
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func item(_ element: AXUIElement) -> JSONValue? {
            guard let rawPosition = attribute(element, kAXPositionAttribute),
                let rawSize = attribute(element, kAXSizeAttribute), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
                CFGetTypeID(rawSize) == AXValueGetTypeID()
            else { return nil }
            var point = CGPoint.zero;
            var size = CGSize.zero;
            guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &point),
                AXValueGetValue(rawSize as! AXValue, .cgSize, &size)
            else { return nil }
            let box = CGRect(origin: point, size: size);
            guard box.width > 0, box.height > 0, box.intersects(bounds) else { return nil }
            let role = attribute(element, kAXRoleAttribute) as? String ?? "unknown"
            let name =
                attribute(element, kAXTitleAttribute) as? String ?? attribute(element, kAXDescriptionAttribute)
                as? String ?? ""
            var result: JSONValue = .object([
                "role": .string(role), "name": .string(String(name.prefix(512))),
                "enabled": .bool(attribute(element, kAXEnabledAttribute) as? Bool ?? true),
                "bounds": Self.rect(
                    CGRect(
                        x: (box.minX - bounds.minX) / bounds.width * Double(width),
                        y: (box.minY - bounds.minY) / bounds.height * Double(height),
                        width: box.width / bounds.width * Double(width),
                        height: box.height / bounds.height * Double(height))),
                "coordinate_space": .string("screenshot_pixels"), "source": .string("mac_accessibility"),
            ])
            if attribute(element, kAXSubroleAttribute) as? String == "AXSecureTextField" {
                result["value_redacted"] = .bool(true);
                result["name"] = .string("[protected field]")
            } else if let value = attribute(element, kAXValueAttribute) as? String {
                result["value"] = .string(String(value.prefix(1024)))
            }
            return result
        }
        var queue: [(AXUIElement, Int?, Int)] = []
        if context["mode"].string == "independent", let target = try? target(context),
            let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement]
        {
            let matches = windows.filter { element in
                guard let raw = attribute(element, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else {
                    return false
                };
                var p = CGPoint.zero;
                return AXValueGetValue(raw as! AXValue, .cgPoint, &p) && abs(p.x - target.bounds.minX) < 2
                    && abs(p.y - target.bounds.minY) < 2
            }
            if matches.count == 1 {
                queue = [(matches[0], nil, 0)]
            } else {
                return .object(["status": .string("target_window_accessibility_unavailable")])
            }
        } else if let focused = attribute(root, kAXFocusedWindowAttribute) {
            queue = [(focused as! AXUIElement, nil, 0)]
        }
        var visited = 0;
        var found: [JSONValue] = [], tree: [JSONValue] = []
        while !queue.isEmpty, visited < 200, tree.count < limit, ComputerUseService.elapsed(started) < 1200,
            shouldContinue()
        {
            let (element, oldParent, depth) = queue.removeFirst();
            visited += 1;
            AXUIElementSetMessagingTimeout(element, 0.03);
            var parent = oldParent
            if var value = item(element) {
                let index = tree.count;
                value["node_id"] = .number(Double(index));
                value["parent_id"] = parent.map { .number(Double($0)) } ?? .null;
                value["depth"] = .number(Double(depth));
                tree.append(value);
                parent = index
                if !["AXWindow", "AXGroup", "AXScrollArea", "AXUnknown"].contains(value["role"].string ?? "") {
                    found.append(value)
                }
            }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(
                    contentsOf: children.prefix(max(0, 200 - visited - queue.count)).map { ($0, parent, depth + 1) })
            }
        }
        var result: JSONValue = .object([
            "status": .string(found.isEmpty ? "no_semantic_controls" : "available"), "items": .array(found),
            "tree": .array(tree), "truncated": .bool(!queue.isEmpty),
            "elapsed_ms": .number(ComputerUseService.elapsed(started)), "occlusion_guarantee": .bool(false),
        ])
        if options["control_point"] != .null {
            let x = options["control_point"]["x"].number ?? -1, y = options["control_point"]["y"].number ?? -1
            if x >= 0, y >= 0, x < Double(width), y < Double(height) {
                let system = AXUIElementCreateSystemWide();
                AXUIElementSetMessagingTimeout(system, 0.05);
                var element: AXUIElement?
                if AXUIElementCopyElementAtPosition(
                    system, Float(bounds.minX + x / Double(width) * bounds.width),
                    Float(bounds.minY + y / Double(height) * bounds.height), &element) == .success, let element
                {
                    result["element_at_point"] = item(element) ?? .null;
                    var pid: pid_t = 0;
                    AXUIElementGetPid(element, &pid);
                    result["point_window_owner_matches_foreground"] = .bool(pid == application.processIdentifier)
                }
            }
        }
        return result
    }
    func focusApplication(_ query: String) async throws {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            let values = [
                app.localizedName ?? "", app.bundleIdentifier ?? "",
                app.executableURL?.deletingPathExtension().lastPathComponent ?? "",
            ].map { $0.lowercased() }
            return !app.isTerminated && app.activationPolicy == .regular
                && (values.contains(name) || (name == "微信" && values.contains(where: { $0.contains("wechat") })))
        }
        guard apps.count == 1, let app = apps.first else {
            throw ComputerUseError.message(apps.isEmpty ? "application_not_found" : "application_ambiguous")
        }
        guard app.activate(options: []) else { throw ComputerUseError.message("application_focus_denied") }
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return };
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ComputerUseError.message("application_focus_denied")
    }
    private func pointerPoint(_ screen: ScreenGeometry, _ x: Double, _ y: Double) -> NSPoint? {
        guard
            let display = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    == UInt32(screen.id.split(separator: ":").last ?? "")
            })
        else { return nil }
        return NSPoint(
            x: display.frame.minX + x * display.frame.width, y: display.frame.maxY - y * display.frame.height)
    }
    func preview(_ screen: ScreenGeometry, _ x: Double, _ y: Double, _ kind: String) -> Int {
        guard let point = pointerPoint(screen, x, y), showHints else { return 0 }
        pointer.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        return pointer.preview(
            to: point, source: independent ? pointer.point : NSEvent.mouseLocation, animated: !pointer.reduceMotion,
            kind: kind)
    }
    func mark(_ screen: ScreenGeometry, _ x: Double, _ y: Double, _ kind: String) {
        guard showHints else {
            pointer.stop();
            return
        }
        if !independent {
            if kind == "click", let point = pointerPoint(screen, x, y) {
                pointer.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                pointer.feedback(at: point)
            } else {
                pointer.stop()
            }
            return
        }
        if kind == "relative" || kind == "cancel" {
            pointer.cancelPreview();
            return
        }
        pointer.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let point = pointerPoint(screen, x, y) { pointer.mark(at: point, kind: kind) }
    }
    func stop() {
        ocrJob?.request.cancel();
        pointer.stop();
        activeControl = .null;
        logicalTextTarget = nil;
        independentKeys = [];
        independentButtons = []
    }

}

// MARK: MCP pointer presentation
// The small, click-through panel moves; it never moves or captures the OS cursor.
@MainActor final class MCPPointerOverlay {
    private(set) var panel: NSPanel?
    private(set) var point = NSPoint.zero
    var reduceMotion = false { didSet { view.reduceMotion = reduceMotion } }
    var keepVisible = false
    private let view = MCPPointerView(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
    private var timer: Timer?
    private var from = NSPoint.zero, target = NSPoint.zero
    private var began = 0.0, duration = 0.0, lastActivity = 0.0
    private var moving = false
    private var curved = false
    private func show() {
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 56, height: 56), styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            p.isOpaque = false;
            p.backgroundColor = .clear;
            p.hasShadow = false;
            p.ignoresMouseEvents = true;
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary];
            p.isReleasedWhenClosed = false;
            p.contentView = view;
            panel = p
        }
        panel?.alphaValue = 1;
        panel?.orderFrontRegardless()
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer = t;
            RunLoop.main.add(t, forMode: .common)
        }
    }
    func preview(to destination: NSPoint, source: NSPoint, animated: Bool, kind: String = "move") -> Int {
        // Only a discrete click has an explicitly independent destination. Absolute
        // moves may be waypoints; drag markers always follow the supplied path exactly.
        if moving { tick() }
        view.showsPointer = true
        curved = kind == "click" || kind == "double_click"
        let start = moving || keepVisible && panel?.isVisible == true ? point : source
        from = start;
        target = destination;
        point = start;
        began = CACurrentMediaTime();
        lastActivity = began
        let distance = hypot(destination.x - start.x, destination.y - start.y)
        duration = animated && distance > 3 ? min(0.34, max(0.16, 0.13 + distance / 4600)) : 0
        moving = duration > 0;
        view.clicks = [];
        show();
        tick()
        if !moving { position(destination) }
        return Int(ceil(duration * 1000))
    }
    func feedback(at destination: NSPoint) {
        mark(at: destination, kind: "click");
        view.showsPointer = false;
        keepVisible = false
    }
    func mark(at destination: NSPoint, kind: String) {
        view.showsPointer = true
        if kind == "relative" || kind == "cancel" {
            stop();
            return
        }
        moving = false;
        duration = 0;
        lastActivity = CACurrentMediaTime();
        show();
        position(destination)
        view.tilt = 0;
        view.tail = .zero
        if kind == "click" {
            view.clicks = Array((view.clicks + [lastActivity]).suffix(4))
        } else if kind == "drag" {
            view.clicks = []
        }
        view.needsDisplay = true
    }
    private func position(_ value: NSPoint) {
        point = value;
        panel?.setFrameOrigin(NSPoint(x: value.x - 28, y: value.y - 28))
    }
    private func tick() {
        let now = CACurrentMediaTime()
        if moving {
            let t = min(1, max(0, (now - began) / duration))
            // Quintic easing gives zero endpoint velocity AND acceleration. The Bézier
            // controls stay inside the endpoint rectangle; no overshoot or random arc.
            let e = t * t * t * (t * (t * 6 - 15) + 10), u = 1 - e
            let dx = target.x - from.x, dy = target.y - from.y
            let x = curved ? 3 * u * u * e * 0.25 + 3 * u * e * e * 0.75 + e * e * e : e
            let y = curved ? 3 * u * u * e * 0.08 + 3 * u * e * e * 0.92 + e * e * e : e
            let next = NSPoint(x: from.x + dx * x, y: from.y + dy * y)
            let vx = next.x - point.x, vy = next.y - point.y, speed = hypot(vx, vy)
            position(next)
            view.tilt = speed > 0.01 ? -vx / max(1, speed) * 0.09 * sin(.pi * t) : 0
            let tail = min(18, speed * 0.7)
            view.tail = NSPoint(x: -vx / max(1, speed) * tail, y: -vy / max(1, speed) * tail)
            if t >= 1 {
                moving = false;
                position(target);
                view.tilt = 0;
                view.tail = .zero
            }
        }
        view.time = now;
        view.clicks.removeAll { now - $0 > 0.55 };
        view.needsDisplay = true
        let idle = now - lastActivity
        let alpha = moving || keepVisible ? 1 : max(0, min(1, (1.05 - idle) / 0.3))
        panel?.alphaValue = alpha
        if alpha <= 0 {
            panel?.orderOut(nil);
            timer?.invalidate();
            timer = nil
        }
    }
    func cancelPreview() {
        moving = false;
        view.tail = .zero;
        view.tilt = 0;
        if !keepVisible { stop() }
    }
    func stop() {
        keepVisible = false;
        timer?.invalidate();
        timer = nil;
        moving = false;
        view.clicks = [];
        panel?.orderOut(nil)
    }
    // Used by the native preview recorder; no screenshot permission or input injection.
    func previewImage() -> NSImage {
        let image = NSImage(size: view.bounds.size)
        image.lockFocus();
        view.draw(view.bounds);
        image.unlockFocus();
        return image
    }
}

@MainActor private final class MCPPointerView: NSView {
    var time = 0.0, tilt = 0.0
    var tail = NSPoint.zero, clicks: [Double] = []
    var reduceMotion = false
    var showsPointer = true
    private let accent = NSColor(name: nil) { @Sendable appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.64, green: 0.71, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0.275, green: 0.373, blue: 0.769, alpha: 1)
    }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState();
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.clear.setFill();
        bounds.fill(using: .copy)
        let presentation = NSAffineTransform();
        presentation.scale(by: 0.5);
        presentation.concat()
        let origin = NSPoint(x: 56, y: 56)
        if hypot(tail.x, tail.y) > 1 {
            let path = NSBezierPath();
            path.move(to: origin);
            path.curve(
                to: NSPoint(x: origin.x + tail.x, y: origin.y + tail.y),
                controlPoint1: NSPoint(x: origin.x + tail.x * 0.25, y: origin.y + tail.y * 0.1),
                controlPoint2: NSPoint(x: origin.x + tail.x * 0.8, y: origin.y + tail.y * 0.8))
            path.lineWidth = 9;
            path.lineCapStyle = .round;
            accent.withAlphaComponent(0.13).setStroke();
            path.stroke()
        }
        for click in clicks {
            let t = min(1, max(0, (time - click) / 0.55)), r = reduceMotion ? 14 : 7 + 28 * (1 - pow(1 - t, 3))
            let circle = NSBezierPath(ovalIn: NSRect(x: 56 - r, y: 56 - r, width: r * 2, height: r * 2));
            circle.lineWidth = 2.2
            accent.withAlphaComponent((1 - t) * (1 - t) * 0.7).setStroke();
            circle.stroke()
            if t < 0.35 {
                accent.withAlphaComponent((0.35 - t) * 0.3).setFill();
                NSBezierPath(ovalIn: NSRect(x: 48, y: 48, width: 16, height: 16)).fill()
            }
        }
        guard showsPointer else { return }
        var scale = 1.0
        if !reduceMotion, let click = clicks.last {
            let age = max(0, time - click);
            if age < 0.12 {
                scale = 1 - 0.18 * sin(.pi * age / 0.12)
            } else if age < 0.3 {
                scale = 1 + 0.065 * sin(.pi * (age - 0.12) / 0.18)
            }
        }
        let transform = NSAffineTransform();
        transform.translateX(by: 56, yBy: 56);
        transform.rotate(byRadians: tilt);
        transform.scale(by: scale);
        transform.concat()
        // Compact rounded north-west pointer inspired by the installed cursor SVG.
        let arrow = NSBezierPath();
        arrow.move(to: .zero)
        arrow.curve(
            to: NSPoint(x: -0.8, y: -0.7), controlPoint1: NSPoint(x: -0.4, y: 0.4), controlPoint2: NSPoint(x: -1, y: 0))
        arrow.line(to: NSPoint(x: 9.3, y: -28.8));
        arrow.curve(
            to: NSPoint(x: 12.5, y: -28.7), controlPoint1: NSPoint(x: 9.8, y: -30.3),
            controlPoint2: NSPoint(x: 11.8, y: -30.2))
        arrow.line(to: NSPoint(x: 17.7, y: -17.7));
        arrow.line(to: NSPoint(x: 28.7, y: -12.5));
        arrow.curve(
            to: NSPoint(x: 28.8, y: -9.3), controlPoint1: NSPoint(x: 30.2, y: -11.8),
            controlPoint2: NSPoint(x: 30.3, y: -9.8));
        arrow.close()
        arrow.lineJoinStyle = .round;
        arrow.lineWidth = 1.5
        let shadow = NSShadow();
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22);
        shadow.shadowBlurRadius = 3;
        shadow.shadowOffset = NSSize(width: 0, height: -1);
        shadow.set()
        NSColor(calibratedWhite: 0.05, alpha: 1).setFill();
        arrow.fill();
        NSColor.white.setStroke();
        arrow.stroke()
        shadow.shadowColor = .clear;
        shadow.set()
        let dot = NSBezierPath(ovalIn: NSRect(x: 21, y: -27, width: 6, height: 6));
        accent.setFill();
        dot.fill();
        dot.lineWidth = 1.2;
        NSColor.white.setStroke();
        dot.stroke()
    }
}
