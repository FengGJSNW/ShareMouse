import Foundation

public struct GroupMember: Codable, Sendable, Equatable {
    public var peerID: String
    public var name: String
    public var publicKey: String
    public var joinOrder: UInt64
    public var host: String?
    public var port: UInt16
}

public struct ScreenGeometry: Codable, Sendable, Equatable {
    public var id: String
    public var peerID: String
    public var name: String
    public var number: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var primary: Bool
    public var x: Double
    public var y: Double
    public var scale: Double
    public var scaleX: Double? = nil
    public var scaleY: Double? = nil
    public var rotation: Int? = nil
    public var angle: Int { rotation ?? 0 }
    public var baseWidth: Double { Double(angle == 90 || angle == 270 ? pixelHeight : pixelWidth) }
    public var baseHeight: Double { Double(angle == 90 || angle == 270 ? pixelWidth : pixelHeight) }
    public var width: Double { baseWidth * (scaleX ?? scale) }
    public var height: Double { baseHeight * (scaleY ?? scale) }
    public mutating func setSize(width: Double, height: Double) { scaleX = width / baseWidth; scaleY = height / baseHeight }
    public func logical(_ u: Double, _ v: Double) -> (Double, Double) {
        switch angle { case 90: return (1-v,u); case 180: return (1-u,1-v); case 270: return (v,1-u); default: return (u,v) }
    }
    public func native(_ u: Double, _ v: Double) -> (Double, Double) {
        switch angle { case 90: return (v,1-u); case 180: return (1-u,1-v); case 270: return (1-v,u); default: return (u,v) }
    }
    public func delta(_ dx: Double, _ dy: Double) -> (Double, Double) {
        let rotated: (Double, Double)
        switch angle { case 90: rotated = (-dy,dx); case 180: rotated = (-dx,-dy); case 270: rotated = (dy,-dx); default: rotated = (dx,dy) }
        return (rotated.0 * (scaleX ?? scale), rotated.1 * (scaleY ?? scale))
    }
    public static func resize(_ screen: ScreenGeometry, dx: Double, dy: Double, edge: String, proportional: Bool, others: [ScreenGeometry], tolerance: Double = 0) -> ScreenGeometry {
        var left = screen.x, right = screen.x + screen.width, top = screen.y, bottom = screen.y + screen.height
        if edge.contains("w") { left = min(right-1,left+dx) }; if edge.contains("e") { right = max(left+1,right+dx) }
        if edge.contains("n") { top = min(bottom-1,top+dy) }; if edge.contains("s") { bottom = max(top+1,bottom+dy) }
        if proportional {
            var factor = edge == "n" || edge == "s" ? (bottom-top)/screen.height : (right-left)/screen.width
            if tolerance > 0 {
                var candidates: [(distance: Double, factor: Double)] = []
                for other in others where other.id != screen.id {
                    for target in [other.x,other.x+other.width] {
                        if edge.contains("w") { candidates.append((abs(screen.x+screen.width-screen.width*factor-target),(screen.x+screen.width-target)/screen.width)) }
                        if edge.contains("e") { candidates.append((abs(screen.x+screen.width*factor-target),(target-screen.x)/screen.width)) }
                    }
                    for target in [other.y,other.y+other.height] {
                        if edge.contains("n") { candidates.append((abs(screen.y+screen.height-screen.height*factor-target),(screen.y+screen.height-target)/screen.height)) }
                        if edge.contains("s") { candidates.append((abs(screen.y+screen.height*factor-target),(target-screen.y)/screen.height)) }
                    }
                }
                if let snap = candidates.filter({ $0.distance < tolerance && $0.factor*min(screen.width,screen.height) >= 1 }).min(by: { $0.distance < $1.distance }) { factor = snap.factor }
            }
            if edge.contains("w") { left = right-screen.width*factor } else { right = left+screen.width*factor }
            if edge.contains("n") { top = bottom-screen.height*factor } else { bottom = top+screen.height*factor }
        } else if tolerance > 0 {
            func nearest(_ value: Double, _ targets: [Double]) -> Double { targets.filter { abs($0-value) < tolerance }.min(by: { abs($0-value) < abs($1-value) }) ?? value }
            let rest = others.filter { $0.id != screen.id }
            let xs = rest.flatMap { [$0.x,$0.x+$0.width] }, ys = rest.flatMap { [$0.y,$0.y+$0.height] }
            if edge.contains("w") { left = nearest(left,xs) }; if edge.contains("e") { right = nearest(right,xs) }
            if edge.contains("n") { top = nearest(top,ys) }; if edge.contains("s") { bottom = nearest(bottom,ys) }
        }
        var result = screen; result.x = left; result.y = top; result.setSize(width: max(1,right-left), height: max(1,bottom-top)); return result
    }
    public init(id: String, peerID: String, name: String, number: Int, pixelWidth: Int, pixelHeight: Int,
                primary: Bool, x: Double, y: Double, scale: Double = 1) {
        self.id = id; self.peerID = peerID; self.name = name; self.number = number
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.primary = primary
        self.x = x; self.y = y; self.scale = scale
    }
    public static func validLayout(_ screens: [ScreenGeometry]) -> Bool {
        guard !screens.isEmpty, Set(screens.map(\.id)).count == screens.count,
              screens.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.scale.isFinite && $0.scale > 0 && ($0.scaleX ?? $0.scale).isFinite && ($0.scaleX ?? $0.scale) > 0 && ($0.scaleY ?? $0.scale).isFinite && ($0.scaleY ?? $0.scale) > 0 && [0,90,180,270].contains($0.angle)
                && $0.pixelWidth > 0 && $0.pixelHeight > 0 && $0.width.isFinite && $0.height.isFinite && $0.width >= 1 && $0.height >= 1 }) else { return false }
        var connected: Set<Int> = [0]
        var pending = [0]
        while let index = pending.popLast() {
            for other in screens.indices where !connected.contains(other) {
                if touches(screens[index], screens[other]) { connected.insert(other); pending.append(other) }
            }
        }
        for a in screens.indices { for b in screens.indices where b > a {
            let left = screens[a], right = screens[b]
            if min(left.x + left.width, right.x + right.width) - max(left.x, right.x) > 0.01
                && min(left.y + left.height, right.y + right.height) - max(left.y, right.y) > 0.01 { return false }
        } }
        guard connected.count == screens.count else { return false }
        if Set(screens.map(\.peerID)).count > 1 {
            return Dictionary(grouping: screens, by: \.peerID).values.allSatisfy { validLayout($0) }
        }
        return true
    }
    // Preserve logical adjacency while converting each peer's rectangles to OS units.
    // A Retina display uses Quartz points here, rather than assuming physical pixels.
    public static func nativeLayout(_ logical: [ScreenGeometry], sizes: [String: (Double, Double)]) -> [ScreenGeometry]? {
        guard validLayout(logical), Set(logical.map(\.peerID)).count == 1, logical.allSatisfy({ screen in guard let size = sizes[screen.id] else { return false }; return size.0.isFinite && size.1.isFinite && (1...32768).contains(size.0) && (1...32768).contains(size.1) }), let root = logical.first(where: \.primary) ?? logical.first else { return nil }
        func native(_ screen: ScreenGeometry, x: Double, y: Double) -> ScreenGeometry {
            let size = sizes[screen.id]!
            return ScreenGeometry(id: screen.id, peerID: screen.peerID, name: screen.name, number: screen.number,
                pixelWidth: Int(size.0.rounded()), pixelHeight: Int(size.1.rounded()), primary: screen.primary, x: x.rounded(), y: y.rounded())
        }
        var result = [root.id: native(root,x: 0,y: 0)], pending = [root]
        while !pending.isEmpty {
            let current = pending.removeFirst(), placed = result[current.id]!
            for next in logical where result[next.id] == nil && touches(current,next) {
                let size = sizes[next.id]!
                var x = placed.x + (next.x-current.x)/current.width*placed.width
                var y = placed.y + (next.y-current.y)/current.height*placed.height
                if abs(current.x+current.width-next.x) < 0.01 { x = placed.x+placed.width }
                else if abs(next.x+next.width-current.x) < 0.01 { x = placed.x-size.0 }
                else if abs(current.y+current.height-next.y) < 0.01 { y = placed.y+placed.height }
                else { y = placed.y-size.1 }
                result[next.id] = native(next,x: x,y: y); pending.append(next)
            }
        }
        let values = logical.compactMap { result[$0.id] }
        return values.count == logical.count && validLayout(values) ? values : nil
    }
    public static func touches(_ a: ScreenGeometry, _ b: ScreenGeometry) -> Bool {
        let horizontal = abs(a.x + a.width - b.x) < 0.01 || abs(b.x + b.width - a.x) < 0.01
        let vertical = abs(a.y + a.height - b.y) < 0.01 || abs(b.y + b.height - a.y) < 0.01
        return horizontal && min(a.y + a.height, b.y + b.height) > max(a.y, b.y)
            || vertical && min(a.x + a.width, b.x + b.width) > max(a.x, b.x)
    }
    public static func snap(_ screen: ScreenGeometry, others: [ScreenGeometry], tolerance: Double) -> ScreenGeometry {
        var result = screen; var bestX = tolerance; var bestY = tolerance
        for other in others where other.id != screen.id {
            for candidate in [other.x + other.width, other.x - screen.width, other.x, other.x + other.width - screen.width] where abs(candidate - screen.x) < bestX {
                bestX = abs(candidate - screen.x); result.x = candidate
            }
            for candidate in [other.y + other.height, other.y - screen.height, other.y, other.y + other.height - screen.height] where abs(candidate - screen.y) < bestY {
                bestY = abs(candidate - screen.y); result.y = candidate
            }
        }
        return result
    }
}

public struct KeyboardConfig: Codable, Sendable, Equatable {
    public var id: String
    public var ownerPeerID: String
    public var name: String
    public var windowsToMac: [String: String]
    public var macToWindows: [String: String]
    public var revision: UInt64? = nil
    public var modified: Int64? = nil
}

public struct SharedGroup: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var leaderID: String
    public var revision: UInt64
    public var members: [GroupMember]
    public var layout: [ScreenGeometry]
    public var configs: [KeyboardConfig]
    public var currentConfigID: String
}

public struct GroupEditLock: Codable, Sendable, Equatable, Identifiable {
    public var resource: String
    public var ownerPeerID: String
    public var token: String
    public var baseRevision: UInt64
    public var id: String { token }
}

struct GroupStore: Codable {
    var groups: [SharedGroup]
    var activeGroupID: String?
}

struct GroupPacket: Codable, Sendable {
    var type: String
    var groupID: String?
    var requestID: String?
    var state: SharedGroup?
    var member: GroupMember?
    var screens: [ScreenGeometry]?
    var locks: [GroupEditLock]?
    var editLock: GroupEditLock?
    var resource: String?
    var approved: Bool?
    var error: String?
    var leaderID: String?
    var targetPeerID: String?
    var configs: [KeyboardConfig]?
    var currentConfigID: String?
    init(_ type: String) { self.type = type }
}

public enum GroupError: Error { case noActiveGroup, alreadyActive, offline, notLeader, denied, invalidState, busy }
