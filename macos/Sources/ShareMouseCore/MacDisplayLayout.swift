import AppKit
import Foundation

@MainActor
public enum MacDisplayLayout {
    public static func apply(_ layout: [ScreenGeometry], peerID: String, backup: URL) throws {
        let local = layout.filter { $0.peerID == peerID }
        guard local.count > 1 else { return }
        var displays: [String: CGDirectDisplayID] = [:], sizes: [String: (Double,Double)] = [:]
        for screen in local {
            guard let display = UInt32(screen.id.split(separator: ":").last ?? ""), CGDisplayIsActive(display) != 0, CGDisplayIsInMirrorSet(display) == 0 else { throw GroupError.invalidState }
            let bounds = CGDisplayBounds(display); displays[screen.id] = display; sizes[screen.id] = (Double(bounds.width),Double(bounds.height))
        }
        guard let plan = ScreenGeometry.nativeLayout(local,sizes: sizes) else { throw GroupError.invalidState }
        let changed = plan.filter { screen in let bounds = CGDisplayBounds(displays[screen.id]!); return abs(bounds.minX-screen.x) > 0.5 || abs(bounds.minY-screen.y) > 0.5 }
        guard !changed.isEmpty else { return }
        let original = local.map { screen -> ScreenGeometry in var next = screen;let bounds = CGDisplayBounds(displays[screen.id]!);next.x = bounds.minX;next.y = bounds.minY;return next }
        try JSONEncoder().encode(original).write(to: backup,options: .atomic)
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success else { throw InputAdapterError.display }
        for screen in plan {
            guard abs(screen.x) <= Double(Int32.max), abs(screen.y) <= Double(Int32.max), CGConfigureDisplayOrigin(configuration,displays[screen.id]!,Int32(screen.x),Int32(screen.y)) == .success else {
                CGCancelDisplayConfiguration(configuration);throw InputAdapterError.display
            }
        }
        guard CGCompleteDisplayConfiguration(configuration,.permanently) == .success else { throw InputAdapterError.display }
        // The OS can snap an unsupported placement; report it rather than pretend it matched.
        guard plan.allSatisfy({ screen in let bounds = CGDisplayBounds(displays[screen.id]!);return abs(bounds.minX-screen.x) <= 1 && abs(bounds.minY-screen.y) <= 1 }) else {
            var restore: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&restore) == .success {
                for screen in original { _ = CGConfigureDisplayOrigin(restore,displays[screen.id]!,Int32(screen.x),Int32(screen.y)) }
                _ = CGCompleteDisplayConfiguration(restore,.permanently)
            }
            throw InputAdapterError.display
        }
    }
}
