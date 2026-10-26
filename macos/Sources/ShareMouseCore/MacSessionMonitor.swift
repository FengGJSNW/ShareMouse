import AppKit
import IOKit

/// Reads closed/open state, rather than a device-specific hinge angle.
@MainActor public final class MacSessionMonitor {
    public private(set) var lidClosed: Bool?
    public private(set) var screenLocked = false
    public var changed: (() -> Void)?
    private var root: io_service_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    public init() {}
    public func start() {
        guard workspaceObservers.isEmpty else { return }
        root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if root != 0, let notificationPort = IONotificationPortCreate(kIOMainPortDefault) {
            port = notificationPort
            IONotificationPortSetDispatchQueue(notificationPort, .main)
            IOServiceAddInterestNotification(
                notificationPort, root, kIOGeneralInterest,
                { context, _, _, _ in
                    guard let context else { return }
                    MainActor.assumeIsolated {
                        Unmanaged<MacSessionMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
                    }
                }, Unmanaged.passUnretained(self).toOpaque(), &notifier)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didWakeNotification, NSWorkspace.willSleepNotification,
            NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification,
        ] {
            workspaceObservers.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
        }
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            lockObservers.append(
                DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.apply(lid: self.readLid(), locked: locked)
                    }
                })
        }
        refresh()
    }
    private func readLid() -> Bool? {
        guard root != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }
    public func refresh() {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked =
            session == nil || (session?["CGSSessionScreenIsLocked"] as? Bool == true)
            || (session?[kCGSessionOnConsoleKey as String] as? Bool == false)
        apply(lid: readLid(), locked: locked)
    }
    private func apply(lid: Bool?, locked: Bool) {
        guard lidClosed != lid || screenLocked != locked else { return }
        lidClosed = lid;
        screenLocked = locked
        changed?()
    }
    public func stop() {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in lockObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        workspaceObservers = [];
        lockObservers = []
        if notifier != 0 {
            IOObjectRelease(notifier);
            notifier = 0
        }
        if let port {
            IONotificationPortDestroy(port);
            self.port = nil
        }
        if root != 0 {
            IOObjectRelease(root);
            root = 0
        }
    }
}
