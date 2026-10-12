import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import Network

public final class BLEDiscovery: NSObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate,
    CBPeripheralDelegate, @unchecked Sendable {
    public static let serviceUUID = CBUUID(string: "436CA682-AC49-45F2-95D4-D37B41130558")
    private static let receiveUUID = CBUUID(string: "436CA682-AC49-45F2-95D4-D37B4113055B")
    private static let transmitUUID = CBUUID(string: "436CA682-AC49-45F2-95D4-D37B4113055C")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheralManager!
    private let queue = DispatchQueue(label: "ShareMouse.BLE", qos: .userInteractive)
    private let status: @Sendable (String) -> Void
    private let found: @Sendable (String, String) -> Void
    private var candidates: [String: CBPeripheral] = [:]
    private var outgoing: [UUID: BLEByteBridge] = [:]
    private var incoming: [UUID: BLEByteBridge] = [:]
    private var incomingGeneration: [UUID: UUID] = [:]
    private var pending: [UUID: @Sendable (Result<NWEndpoint, Error>) -> Void] = [:]
    private var sendFramers: [UUID: BLEStreamFraming] = [:]
    private var notificationFramers: [UUID: BLEStreamFraming] = [:]
    private var lastNotificationProgress: [UUID: Date] = [:]
    private var receivers: [UUID: CBCharacteristic] = [:]
    private var writeCompletions: [UUID: @Sendable (Error?) -> Void] = [:]
    private var blockedWrites: [UUID: @Sendable () -> Void] = [:]
    private var manualScanRound = 0
    private var activeScanDeadline = Date.distantPast
    private var stopped = false
    private var realtimeInput = false
    public func setRealtimeInputEnabled(_ enabled: Bool) { queue.async { [self] in
        realtimeInput = enabled; refreshScanning()
    } }
    private func refreshScanning() {
        guard !stopped, central?.state == .poweredOn else { return }
        let pause = realtimeInput && (!outgoing.isEmpty || !incoming.isEmpty) && Date() >= activeScanDeadline
        if pause { if central.isScanning { central.stopScan(); status("BLEDiscoveryPausedForInput") } }
        else if !central.isScanning { central.scanForPeripherals(withServices:[Self.serviceUUID]); status("BLEBackgroundDiscovery") }
    }

    private var blockedNotifications: [UUID: @Sendable () -> Void] = [:]
    private var serverTX: CBMutableCharacteristic?
    private let serverPort: UInt16

    public init(serverPort: UInt16 = 49165, status: @escaping @Sendable (String) -> Void,
                found: @escaping @Sendable (String, String) -> Void) {
        self.serverPort = serverPort; self.status = status; self.found = found; super.init()
    }
    private var available = true
    private var pairCode = ""
    private var serviceReady = false
    public func updatePairCode(_ code: String) { queue.async { [self] in pairCode = code; advertise() } }
    private func advertise() {
        guard available, serviceReady, peripheral?.state == .poweredOn else { return }
        peripheral.stopAdvertising(); peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID], CBAdvertisementDataLocalNameKey: "SM" + pairCode])
    }
    public func setAvailable(_ enabled: Bool) { queue.async { [self] in
        available = enabled
        guard let peripheral, peripheral.state == .poweredOn else { return }
        if enabled { advertise() }
        else { peripheral.stopAdvertising() }
    } }
    public func start() {
        queue.async { [self] in
            guard central == nil else { return }
            central = CBCentralManager(delegate: self, queue: queue)
            peripheral = CBPeripheralManager(delegate: self, queue: queue)
        }
    }
    public func tryDiscovery() { queue.async { [self] in
        guard !stopped else { return }
        manualScanRound += 1; let round = manualScanRound; activeScanDeadline = Date().addingTimeInterval(60)
        if central?.state == .poweredOn { central.stopScan(); central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]); status("BLEActiveDiscovery") }
        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, !self.stopped, self.manualScanRound == round, self.central?.state == .poweredOn else { return }
            self.activeScanDeadline = .distantPast; self.central.stopScan(); self.refreshScanning()
        }
    } }
    public func stop() { queue.async { [self] in
        stopped = true; manualScanRound += 1; central?.stopScan(); peripheral?.stopAdvertising()
        let callbacks = Array(pending.values); pending = [:]; callbacks.forEach { $0(.failure(PairingError.disconnected)) }
        for candidate in candidates.values where candidate.state != .disconnected { central?.cancelPeripheralConnection(candidate) }
        Array(outgoing.values).forEach { $0.close() }; Array(incoming.values).forEach { $0.close() }
    } }
    public func connect(_ locator: String) async throws -> NWEndpoint {
        try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
            guard let candidate = candidates[locator], central.state == .poweredOn,
                  pending[candidate.identifier] == nil, outgoing[candidate.identifier] == nil else {
                continuation.resume(throwing: PairingError.disconnected); return
            }
            pending[candidate.identifier] = { continuation.resume(with: $0) }
            candidate.delegate = self; central.connect(candidate)
            queue.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, let completion = self.pending.removeValue(forKey: candidate.identifier) else { return }
                completion(.failure(PairingError.timedOut)); self.central.cancelPeripheralConnection(candidate)
            }
        } }
    }
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn && !stopped {
            let active = activeScanDeadline > Date()
            central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: active]); status(active ? "BLEActiveDiscovery" : "BLEScanReady")
        } else {
            Array(outgoing.values).forEach { $0.close() }
            let callbacks = Array(pending.values); pending = [:]; callbacks.forEach { $0(.failure(PairingError.disconnected)) }
            outgoing = [:]; receivers = [:]; sendFramers = [:]; blockedWrites = [:]
            status("BLEScanUnavailable state=\(central.state.rawValue)")
        }
    }
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            serviceReady = false
            Array(incoming.values).forEach { $0.close() }; incoming = [:]; incomingGeneration = [:]; notificationFramers = [:]; blockedNotifications = [:]; serverTX = nil
            status("BLEAdvertiseUnavailable state=\(peripheral.state.rawValue)"); return
        }
        peripheral.removeAllServices()
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        let rx = CBMutableCharacteristic(type: Self.receiveUUID, properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable])
        let tx = CBMutableCharacteristic(type: Self.transmitUUID, properties: [.notify], value: nil, permissions: [])
        service.characteristics = [rx, tx]; serverTX = tx; peripheral.add(service)
    }
    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else { status("BLEAdvertiseUnavailable"); return }
        serviceReady = true; advertise()
    }
    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        status(error == nil ? "BLEAdvertiseReady" : "BLEAdvertiseUnavailable")
    }
    public func centralManager(_ central: CBCentralManager, didDiscover peer: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        candidates[peer.identifier.uuidString] = peer
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        let code = serviceData?[Self.serviceUUID].flatMap { String(data: $0, encoding: .utf8) }
        let name = code.map { "SM" + $0 } ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peer.name ?? "ShareMouse 设备"
        found(peer.identifier.uuidString, name)
    }
    public func centralManager(_ central: CBCentralManager, didConnect peer: CBPeripheral) { peer.discoverServices([Self.serviceUUID]) }
    public func centralManager(_ central: CBCentralManager, didFailToConnect peer: CBPeripheral, error: Error?) { disconnected(peer) }
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peer: CBPeripheral, error: Error?) { disconnected(peer) }
    private func disconnected(_ peer: CBPeripheral) {
        pending.removeValue(forKey: peer.identifier)?(.failure(PairingError.disconnected))
        outgoing.removeValue(forKey: peer.identifier)?.close(); refreshScanning()
        writeCompletions.removeValue(forKey: peer.identifier)?(PairingError.disconnected)
        blockedWrites.removeValue(forKey: peer.identifier)
        receivers.removeValue(forKey: peer.identifier); sendFramers.removeValue(forKey: peer.identifier)
    }
    public func peripheral(_ peer: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peer.services?.first(where: { $0.uuid == Self.serviceUUID }) else { central.cancelPeripheralConnection(peer); return }
        peer.discoverCharacteristics([Self.receiveUUID, Self.transmitUUID], for: service)
    }
    public func peripheral(_ peer: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let rx = service.characteristics?.first(where: { $0.uuid == Self.receiveUUID }),
              let tx = service.characteristics?.first(where: { $0.uuid == Self.transmitUUID }) else { central.cancelPeripheralConnection(peer); return }
        receivers[peer.identifier] = rx; peer.setNotifyValue(true, for: tx)
        status("BLELinkParameters role=central writeBytes=\(peer.maximumWriteValueLength(for: .withoutResponse)) writeWithoutResponse=\(rx.properties.contains(.writeWithoutResponse))")
    }
    public func peripheral(_ peer: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.isNotifying, characteristic.uuid == Self.transmitUUID else { central.cancelPeripheralConnection(peer); return }
        guard outgoing[peer.identifier] == nil else { return }
        let bridge = BLEByteBridge(queue: queue, forward: { [weak self] bytes, done in
            guard let self else { done(PairingError.disconnected); return }; self.queue.async { self.write(bytes, peer: peer, done: done) }
        }, ended: { [weak self] in guard let self else { return }; self.queue.async { self.central.cancelPeripheralConnection(peer) } }, status: status)
        outgoing[peer.identifier] = bridge; refreshScanning()
        do { try bridge.listen { [weak self] result in
            guard let self else { return }
            self.pending.removeValue(forKey: peer.identifier)?(result)
        } } catch { pending.removeValue(forKey: peer.identifier)?(.failure(error)); bridge.close() }
    }
    public func peripheral(_ peer: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil { outgoing[peer.identifier]?.close() }
        else if let bytes = characteristic.value { outgoing[peer.identifier]?.receiveFragment(bytes) }
    }
    private func write(_ bytes: Data, peer: CBPeripheral, done: @escaping @Sendable (Error?) -> Void) {
        guard let rx = receivers[peer.identifier], peer.state == .connected else { done(PairingError.disconnected); return }
        if rx.properties.contains(.writeWithoutResponse) {
            guard peer.canSendWriteWithoutResponse else { blockedWrites[peer.identifier] = { [weak self] in self?.write(bytes, peer: peer, done: done) }; return }
            let count = min(bytes.count, min(512, peer.maximumWriteValueLength(for: .withoutResponse)) - 12)
            peer.writeValue(sendFramers[peer.identifier, default: BLEStreamFraming()].encode(Data(bytes.prefix(count))), for: rx, type: .withoutResponse)
            if count == bytes.count { done(nil) } else { queue.async { [weak self] in self?.write(Data(bytes.dropFirst(count)), peer: peer, done: done) } }
            return
        }
        let count = min(bytes.count, min(512, peer.maximumWriteValueLength(for: .withResponse)) - 12)
        writeCompletions[peer.identifier] = { [weak self] error in
            if let error { done(error) }
            else if count == bytes.count { done(nil) }
            else { self?.write(Data(bytes.dropFirst(count)), peer: peer, done: done) }
        }
        peer.writeValue(sendFramers[peer.identifier, default: BLEStreamFraming()].encode(Data(bytes.prefix(count))), for: rx, type: .withResponse)
    }
    public func peripheralIsReady(toSendWriteWithoutResponse peer: CBPeripheral) {
        blockedWrites.removeValue(forKey: peer.identifier)?()
    }
    public func peripheral(_ peer: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writeCompletions.removeValue(forKey: peer.identifier)?(error)
    }
    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.transmitUUID, incoming[central.identifier] == nil else { return }
        let generation = UUID(); incomingGeneration[central.identifier] = generation
        let bridge = BLEByteBridge(queue: queue, forward: { [weak self] bytes, done in
            guard let self else { done(PairingError.disconnected); return }; self.queue.async { self.notify(bytes, central: central, generation: generation, done: done) }
        }, ended: { [weak self] in
            guard let self else { return }; self.queue.async {
                guard self.incomingGeneration[central.identifier] == generation else { return }
                self.incomingGeneration.removeValue(forKey: central.identifier)
                self.incoming.removeValue(forKey: central.identifier); self.notificationFramers.removeValue(forKey: central.identifier); self.blockedNotifications.removeValue(forKey: central.identifier)
            }
        }, status: status)
        peripheral.setDesiredConnectionLatency(.low, for: central)
        status("BLELinkParameters role=peripheral notifyBytes=\(central.maximumUpdateValueLength)")
        incoming[central.identifier] = bridge; refreshScanning(); bridge.connect(port: serverPort)
    }
    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        incomingGeneration.removeValue(forKey: central.identifier)
        notificationFramers.removeValue(forKey: central.identifier); blockedNotifications.removeValue(forKey: central.identifier)
        incoming.removeValue(forKey: central.identifier)?.close(); refreshScanning()
    }
    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        // CoreBluetooth supplies an atomic batch and requires exactly one response.
        guard requests.allSatisfy({ $0.characteristic.uuid == Self.receiveUUID && $0.offset == 0
            && $0.value != nil && incoming[$0.central.identifier] != nil }) else {
            peripheral.respond(to: first, withResult: .unlikelyError); return
        }
        for request in requests { incoming[request.central.identifier]?.receiveFragment(request.value!) }
        peripheral.respond(to: first, withResult: .success)
    }

    private func notify(_ bytes: Data, central: CBCentral, generation: UUID, done: @escaping @Sendable (Error?) -> Void) {
        guard let tx = serverTX, incomingGeneration[central.identifier] == generation, incoming[central.identifier] != nil else { done(PairingError.disconnected); return }
        let count = min(bytes.count, min(512, central.maximumUpdateValueLength) - 12)
        var framer = notificationFramers[central.identifier, default: BLEStreamFraming()]
        let packet = framer.encode(Data(bytes.prefix(count)))
        if !peripheral.updateValue(packet, for: tx, onSubscribedCentrals: [central]) {
            if Date().timeIntervalSince(lastNotificationProgress[central.identifier] ?? .distantPast) >= 5 {
                lastNotificationProgress[central.identifier] = Date(); status("BLENotifyBlocked nextSequence=\(framer.nextSent - 1)")
            }
            blockedNotifications[central.identifier] = { [weak self] in self?.notify(bytes, central: central, generation: generation, done: done) }; return
        }
        notificationFramers[central.identifier] = framer
        if Date().timeIntervalSince(lastNotificationProgress[central.identifier] ?? .distantPast) >= 5 {
            lastNotificationProgress[central.identifier] = Date(); status("BLENotifyProgress nextSequence=\(framer.nextSent)")
        }
        if count == bytes.count { done(nil) }
        else { queue.async { [weak self] in self?.notify(Data(bytes.dropFirst(count)), central: central, generation: generation, done: done) } }
    }
    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        let retries = Array(blockedNotifications.values); blockedNotifications.removeAll(); retries.forEach { $0() }
    }
}
