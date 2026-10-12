import Foundation
@preconcurrency import Network

public struct LANCandidate: Identifiable, @unchecked Sendable {
    public let id: String
    public let endpoint: NWEndpoint
    public var peerID: String? = nil
    public var pairCode: String? = nil
}

public final class LANDiscovery: @unchecked Sendable {
    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "ShareMouse.Discovery")

    public init(changed: @escaping @Sendable ([LANCandidate]) -> Void, status: @escaping @Sendable (String) -> Void) {
        let parameters = NWParameters.tcp
        // LAN discovery must not activate Apple peer-to-peer Wi-Fi: its channel
        // switching adds latency to the infrastructure link used by Windows.
        parameters.includePeerToPeer = false
        browser = NWBrowser(for: .bonjour(type: "_sharemouse._tcp", domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { results, _ in
            changed(results.map { LANCandidate(id: String(describing: $0.endpoint), endpoint: $0.endpoint) })
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready: status("LANDiscoveryReady")
            case .failed: status("LANDiscoveryUnavailable")
            case .waiting: status("LANDiscoveryWaiting")
            default: break
            }
        }
    }
    public func start() { browser.start(queue: queue) }
    public func stop() { browser.cancel() }
}
