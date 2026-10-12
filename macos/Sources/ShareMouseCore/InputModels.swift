import Foundation

public struct PointerState: Codable, Sendable, Equatable {
    public var screenID: String
    public var x: Double
    public var y: Double
    public var ownerPeerID: String
    public var epoch: UInt64
}
public struct InputPacket: Codable, Sendable {
    public var type: String
    public var groupID: String
    public var sourcePeerID: String
    public var targetPeerID: String
    public var targetScreenID: String?
    public var sequence: UInt64 = 0
    public var acknowledgedSequence: UInt64?
    public var pointer: PointerState?
    public var key: String?
    public var command: String?
    public var clipboardEntryID: String?
    public var text: String?
    public var scrollPhase: Int?
    public var momentumPhase: Int?
    public var preciseScroll: Bool?
    public var sourcePlatform: String?
    public var button: Int = 0
    public var deltaX: Double = 0
    public var deltaY: Double = 0
    public var keys: [String]?
    public var buttons: [Int]?
    public var priority: [String]?
    public init(type: String, groupID: String, sourcePeerID: String, targetPeerID: String) {
        self.type = type; self.groupID = groupID; self.sourcePeerID = sourcePeerID; self.targetPeerID = targetPeerID
    }
}
public struct CapturedInput: Sendable {
    public var type: String
    public var key: String?
    public var command: String?
    public var text: String?
    public var scrollPhase: Int?
    public var momentumPhase: Int?
    public var preciseScroll: Bool?
    public var clickCount: Int?
    public var hardwareMotion: Bool?
    public var button: Int
    public var deltaX: Double
    public var deltaY: Double
    public var screenID: String?
    public var x: Double
    public var y: Double
    public init(_ type: String, key: String? = nil, command: String? = nil, text: String? = nil, button: Int = 0, deltaX: Double = 0, deltaY: Double = 0, scrollPhase: Int? = nil, momentumPhase: Int? = nil, preciseScroll: Bool? = nil,
                screenID: String? = nil, x: Double = 0, y: Double = 0, clickCount: Int? = nil, hardwareMotion: Bool? = nil) {
        self.hardwareMotion = hardwareMotion; self.type = type; self.key = key; self.command = command; self.text = text; self.clickCount = clickCount; self.button = button; self.deltaX = deltaX; self.deltaY = deltaY
        self.scrollPhase = scrollPhase; self.momentumPhase = momentumPhase; self.preciseScroll = preciseScroll; self.screenID = screenID; self.x = x; self.y = y
    }
}
public enum PointerRouter {
    public static func center(_ screen: ScreenGeometry, owner: String, epoch: UInt64) -> PointerState {
        PointerState(screenID: screen.id, x: screen.x + screen.width / 2, y: screen.y + screen.height / 2, ownerPeerID: owner, epoch: epoch)
    }
    public static func move(_ pointer: PointerState, screens: [ScreenGeometry], dx: Double, dy: Double) -> PointerState {
        guard dx.isFinite, dy.isFinite, var screen = screens.first(where: { $0.id == pointer.screenID }) else { return pointer }
        var result = pointer; var x = pointer.x; var y = pointer.y; var dx = dx; var dy = dy
        for _ in 0...screens.count {
            let tx = dx > 0 ? (screen.x + screen.width - x) / dx : dx < 0 ? (screen.x - x) / dx : Double.infinity
            let ty = dy > 0 ? (screen.y + screen.height - y) / dy : dy < 0 ? (screen.y - y) / dy : Double.infinity
            let t = max(0, min(1, min(tx, ty))); x += dx * t; y += dy * t
            if t >= 1 { break }
            let px = x + (dx > 0 ? 0.001 : dx < 0 ? -0.001 : 0), py = y + (dy > 0 ? 0.001 : dy < 0 ? -0.001 : 0)
            guard let next = screens.first(where: { $0.id != screen.id && ScreenGeometry.touches(screen, $0)
                && px >= $0.x && px < $0.x + $0.width && py >= $0.y && py < $0.y + $0.height }) else {
                if tx <= ty { x = max(screen.x, min(x, screen.x + screen.width - 0.001)); dx = 0 } else { dx *= 1 - t }
                if ty <= tx { y = max(screen.y, min(y, screen.y + screen.height - 0.001)); dy = 0 } else { dy *= 1 - t }
                if dx == 0 && dy == 0 { break }; continue
            }
            screen = next; dx *= 1 - t; dy *= 1 - t
        }
        result.screenID = screen.id; result.x = x; result.y = y; return result
    }
}
