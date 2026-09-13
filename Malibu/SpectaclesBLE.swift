// Malibu is licensed under CPAL-1.0.
// Copyright (c) 2026 Leon M'laiel. See LICENSE for required attribution.

@preconcurrency import CoreBluetooth
import CryptoKit
import Foundation

private struct MalibuFrame {
    let kind: UInt8
    let body: Data
}

private final class MalibuFrameReader {
    private var buffer = Data()

    func feed(_ fragment: Data) throws -> [MalibuFrame] {
        buffer.append(fragment)
        var frames: [MalibuFrame] = []
        while buffer.count >= 4 {
            let kind = buffer[0]
            let size = Int(buffer[1]) | Int(buffer[2]) << 8 | Int(buffer[3]) << 16
            guard size <= 16 * 1024 * 1024 else {
                throw MalibuError.protocolFailure("implausible Bluetooth frame size \(size)")
            }
            guard buffer.count >= 4 + size else { break }
            frames.append(MalibuFrame(kind: kind, body: buffer.subdata(in: 4..<(4 + size))))
            buffer.removeSubrange(0..<(4 + size))
        }
        return frames
    }
}

struct SpectaclesDeviceInfo: Equatable {
    var serialNumber: String?
    var firmwareVersion: String?
    var batteryPercent: Int?
    var batteryTemperatureCelsius: Int?
    var isCharging: Bool?
    var storageUsedPercent: Int?
    var frameName: String?
    var lastUpdated: Date?

    var hasDeviceData: Bool {
        serialNumber != nil
            || firmwareVersion != nil
            || batteryPercent != nil
            || storageUsedPercent != nil
            || frameName != nil
    }
}

@MainActor
final class SpectaclesBLE: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private enum ScanMode {
        case pairedDevice
        case pairing
    }

    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private let frameReader = MalibuFrameReader()
    private var crypto: PacketCrypto?
    private var secure = false

    private var powerContinuation: CheckedContinuation<Void, Error>?
    private var scanContinuation: CheckedContinuation<CBPeripheral, Error>?
    private var scanToken: UUID?
    private var scanMode = ScanMode.pairedDevice
    private var expectedIdentifier: UUID?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var readyToken: UUID?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var pendingRequest: (token: UUID, command: UInt16, continuation: CheckedContinuation<Data, Error>)?

    var connectedIdentifier: UUID? { peripheral?.identifier }
    var isConnected: Bool { peripheral?.state == .connected }

    func connect(forPairing: Bool = false, knownIdentifier: UUID? = nil) async throws {
        try await waitForBluetooth()
        let mode = forPairing ? ScanMode.pairing : ScanMode.pairedDevice
        expectedIdentifier = knownIdentifier
        let found: CBPeripheral
        if let knownIdentifier,
           let restored = central.retrievePeripherals(withIdentifiers: [knownIdentifier]).first {
            found = restored
        } else {
            found = try await scanForGlasses(mode: mode)
        }
        peripheral = found
        found.delegate = self

        let token = UUID()
        try await withCheckedThrowingContinuation { continuation in
            readyToken = token
            readyContinuation = continuation
            central.connect(found)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard let self, self.readyToken == token else { return }
                self.readyToken = nil
                self.readyContinuation = nil
                continuation.resume(throwing: MalibuError.timeout("connecting to Bluetooth"))
            }
        }
    }

    func enableSecurity(key: Data) async throws {
        let clientNonce = try Data.secureRandom(count: 16)
        let response = try await request(command: 113, payload: Protobuf.bytes(1, clientNonce), encrypted: false)
        guard let peerNonce = try Protobuf.firstBytes(response, field: 1), peerNonce.count == 16 else {
            throw MalibuError.protocolFailure("the glasses returned an invalid security nonce")
        }
        crypto = try PacketCrypto(
            key: key,
            transmitNonce: clientNonce,
            receiveNonce: peerNonce
        )
        secure = true
    }

    func pair(localUserID: String) async throws -> Data {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let clientNonce = try Data.secureRandom(count: 16)
        var keyExchange = Protobuf.bytes(1, clientNonce)
        keyExchange.append(Protobuf.bytes(2, privateKey.publicKey.rawRepresentation))
        let keyResponse = try await request(command: 80, payload: keyExchange, encrypted: false)
        guard let peerNonce = try Protobuf.firstBytes(keyResponse, field: 1), peerNonce.count == 16 else {
            throw MalibuError.protocolFailure("the glasses returned an invalid pairing nonce")
        }
        guard let peerPublicKey = try Protobuf.firstBytes(keyResponse, field: 2), peerPublicKey.count == 32 else {
            throw MalibuError.protocolFailure("the glasses returned an invalid pairing public key")
        }

        let material = try SpectaclesPairingCrypto.establish(
            privateKey: privateKey,
            clientNonce: clientNonce,
            peerNonce: peerNonce,
            peerPublicKey: peerPublicKey
        )
        var verification = Protobuf.bytes(1, material.tag)
        verification.append(Protobuf.bytes(2, material.message))
        let verificationResponse = try await request(
            command: 116,
            payload: verification,
            encrypted: false
        )
        guard let peerTag = try Protobuf.firstBytes(verificationResponse, field: 1),
              let peerMessage = try Protobuf.firstBytes(verificationResponse, field: 2) else {
            throw MalibuError.protocolFailure("the glasses did not return their verification proof")
        }
        try SpectaclesPairingCrypto.validatePeerProofEnvelope(message: peerMessage, tag: peerTag)

        // The first encrypted identity response confirms that the glasses and
        // Malibu derived the same fresh session key during the proof exchange.
        try await enableSecurity(key: material.encryptionKey)
        _ = try await request(command: 16)
        let association = try await request(
            command: 115,
            payload: Protobuf.bytes(1, Data(localUserID.utf8)),
            timeout: 10
        )
        guard try Protobuf.firstInt(association, field: 1) == 1 else {
            throw MalibuError.protocolFailure("the glasses rejected the local user association")
        }
        return material.encryptionKey
    }

    func startAccessPoint(ssid: String, password: String) async throws {
        var payload = Protobuf.int(1, 1)
        payload.append(Protobuf.string(2, ssid))
        payload.append(Protobuf.string(3, password))
        payload.append(Protobuf.int(6, 1)) // 2.4 GHz for broad iPhone compatibility.
        _ = try await request(command: 21, payload: payload)
    }

    func readDeviceInfo(existing: SpectaclesDeviceInfo = SpectaclesDeviceInfo()) async -> SpectaclesDeviceInfo {
        var info = existing
        var receivedResponse = false

        do {
            // The retired Spectacles 2 client issues the same sequence after
            // every authenticated BLE connection.
            let battery = try await request(
                command: 42,
                payload: Protobuf.int(1, 1),
                timeout: 6
            )
            if let rawBattery = try Protobuf.firstInt(battery, field: 1) {
                let displayed = min(Float(100), Float(rawBattery) / Float(0.95))
                info.batteryPercent = max(0, Int(displayed))
            }
            info.batteryTemperatureCelsius = try Protobuf.firstInt32(battery, field: 3)
            receivedResponse = true

            let charger = try await request(command: 106, timeout: 6)
            if let chargerConnected = try Protobuf.firstInt(charger, field: 1) {
                info.isCharging = chargerConnected != 0
            }

            let serial = try await request(command: 16, timeout: 6)
            if let serialBytes = try Protobuf.firstBytes(serial, field: 1), serialBytes.count == 8 {
                info.serialNumber = serialBytes.map { String(format: "%02X", $0) }.joined()
            }

            let firmware = try await request(command: 0, timeout: 6)
            if let firmwareBytes = try Protobuf.firstBytes(firmware, field: 3),
               let version = String(data: firmwareBytes, encoding: .utf8),
               !version.isEmpty {
                info.firmwareVersion = version
            }

            let color = try await request(command: 37, timeout: 6)
            if let colorID = try Protobuf.firstInt(color, field: 1) {
                info.frameName = Self.frameName(for: colorID)
            }

            let storage = try await request(command: 150, timeout: 6)
            if let usedPercent = try Protobuf.firstInt(storage, field: 1) {
                info.storageUsedPercent = Int(min(UInt64(100), usedPercent))
            }
        } catch {
            // Device information is supplemental. A firmware variant that
            // omits one request must not prevent video import.
        }

        if receivedResponse {
            info.lastUpdated = Date()
        }
        return info
    }

    func stopAccessPoint() async {
        guard peripheral?.state == .connected else { return }
        _ = try? await request(command: 22, timeout: 5)
    }

    func disconnect() {
        central.stopScan()
        scanToken = nil
        if let continuation = scanContinuation {
            scanContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        readyToken = nil
        if let continuation = readyContinuation {
            readyContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        if let continuation = writeContinuation {
            writeContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        if let pending = pendingRequest {
            pendingRequest = nil
            pending.continuation.resume(throwing: CancellationError())
        }
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        secure = false
        crypto = nil
    }

    private static func frameName(for colorID: UInt64) -> String? {
        switch colorID {
        case 0: return "Onyx"
        case 1: return "Ruby"
        case 2: return "Sapphire"
        case 3: return "Veronica"
        case 4: return "Nico"
        default: return nil
        }
    }

    func request(
        command: UInt16,
        payload: Data = Data(),
        timeout: TimeInterval = 15,
        encrypted: Bool? = nil
    ) async throws -> Data {
        guard pendingRequest == nil else { throw MalibuError.busy }

        var body = Data()
        body.appendUInt16LE(command)
        body.append(0)
        body.append(payload)
        let useEncryption = encrypted ?? secure
        let kind: UInt8
        if useEncryption {
            guard let crypto else { throw MalibuError.protocolFailure("Bluetooth security is not initialized") }
            body = try crypto.encrypt(body)
            kind = 5
        } else {
            kind = 1
        }
        let packet = makeFrame(kind: kind, body: body)
        let token = UUID()

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequest = (token, command, continuation)
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.write(packet)
                } catch {
                    self.failRequest(token: token, error: error)
                }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.failRequest(token: token, error: MalibuError.timeout("waiting for command \(command)"))
            }
        }
    }

    private func waitForBluetooth() async throws {
        _ = central
        switch central.state {
        case .poweredOn: return
        case .unsupported: throw MalibuError.bluetoothUnavailable("this iPhone does not support Bluetooth LE")
        case .unauthorized: throw MalibuError.bluetoothUnavailable("permission was denied in Settings")
        case .poweredOff: throw MalibuError.bluetoothUnavailable("turn Bluetooth on, then try again")
        case .resetting, .unknown:
            try await withCheckedThrowingContinuation { continuation in
                powerContinuation = continuation
            }
        @unknown default:
            throw MalibuError.bluetoothUnavailable("unknown state")
        }
    }

    private func scanForGlasses(mode: ScanMode) async throws -> CBPeripheral {
        let token = UUID()
        let timeout: UInt64 = mode == .pairing ? 120_000_000_000 : 12_000_000_000
        return try await withCheckedThrowingContinuation { continuation in
            scanMode = mode
            scanToken = token
            scanContinuation = continuation
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeout)
                guard let self, self.scanToken == token else { return }
                self.central.stopScan()
                self.scanToken = nil
                self.scanContinuation = nil
                continuation.resume(throwing: mode == .pairing ? MalibuError.pairingModeNotFound : MalibuError.glassesNotFound)
            }
        }
    }

    private func write(_ packet: Data) async throws {
        guard let peripheral, let characteristic = writeCharacteristic else {
            throw MalibuError.missingCharacteristic
        }
        let limit = max(1, min(20, peripheral.maximumWriteValueLength(for: .withResponse)))
        var position = 0
        while position < packet.count {
            let end = min(position + limit, packet.count)
            let chunk = packet.subdata(in: position..<end)
            try await withCheckedThrowingContinuation { continuation in
                writeContinuation = continuation
                peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
            }
            position = end
        }
    }

    private func makeFrame(kind: UInt8, body: Data) -> Data {
        precondition(body.count < 1 << 24)
        var result = Data([kind, UInt8(body.count & 0xFF), UInt8((body.count >> 8) & 0xFF), UInt8((body.count >> 16) & 0xFF)])
        result.append(body)
        return result
    }

    private func manufacturerPayload(_ advertisement: [String: Any]) -> Data {
        guard let manufacturer = advertisement[CBAdvertisementDataManufacturerDataKey] as? Data else {
            return Data()
        }
        if manufacturer.count >= 2, manufacturer[0] == 0xC2, manufacturer[1] == 0x03 {
            return manufacturer.dropFirst(2)
        }
        return manufacturer
    }

    private func matchesThisPair(_ peripheral: CBPeripheral, advertisement: [String: Any]) -> Bool {
        let name = ((advertisement[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "").lowercased()
        let payload = manufacturerPayload(advertisement)
        if scanMode == .pairing { return payload == DeviceProfile.pairingMarker }
        if let expectedIdentifier { return peripheral.identifier == expectedIdentifier }
        return name.hasPrefix("specs")
    }

    private func completeReady() {
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        readyToken = nil
        continuation.resume()
    }

    private func failReady(_ error: Error) {
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        readyToken = nil
        continuation.resume(throwing: error)
    }

    private func failRequest(token: UUID, error: Error) {
        guard let pending = pendingRequest, pending.token == token else { return }
        pendingRequest = nil
        pending.continuation.resume(throwing: error)
    }

    private func consume(_ frame: MalibuFrame) throws {
        var body = frame.body
        if frame.kind == 4 || frame.kind == 5 {
            guard secure, let crypto else {
                throw MalibuError.protocolFailure("encrypted Bluetooth data arrived before setup")
            }
            body = try crypto.decrypt(body)
        }
        if frame.kind == 0 || frame.kind == 4 { return }
        guard frame.kind == 1 || frame.kind == 5, body.count >= 4 else { return }

        let status = body[0]
        let command = try body.uint16LE(at: 1)
        guard let pending = pendingRequest, pending.command == command else { return }
        pendingRequest = nil
        if status == 0 {
            pending.continuation.resume(returning: body.subdata(in: 4..<body.count))
        } else {
            pending.continuation.resume(throwing: MalibuError.protocolFailure("command \(command) failed with status \(status)"))
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let continuation = powerContinuation else { return }
        switch central.state {
        case .poweredOn:
            powerContinuation = nil
            continuation.resume()
        case .unsupported, .unauthorized, .poweredOff:
            powerContinuation = nil
            continuation.resume(throwing: MalibuError.bluetoothUnavailable("Bluetooth is not powered on or authorized"))
        default: break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard matchesThisPair(peripheral, advertisement: advertisementData), let continuation = scanContinuation else { return }
        central.stopScan()
        scanContinuation = nil
        scanToken = nil
        continuation.resume(returning: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([DeviceProfile.bleService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        failReady(error ?? MalibuError.disconnected)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        failReady(error ?? MalibuError.disconnected)
        if let pending = pendingRequest {
            pendingRequest = nil
            pending.continuation.resume(throwing: error ?? MalibuError.disconnected)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { failReady(error); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == DeviceProfile.bleService }) else {
            failReady(MalibuError.missingCharacteristic)
            return
        }
        peripheral.discoverCharacteristics(
            [DeviceProfile.writeCharacteristic, DeviceProfile.notifyCharacteristic],
            for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { failReady(error); return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == DeviceProfile.writeCharacteristic { writeCharacteristic = characteristic }
            if characteristic.uuid == DeviceProfile.notifyCharacteristic { notifyCharacteristic = characteristic }
        }
        guard writeCharacteristic != nil, let notifyCharacteristic else {
            failReady(MalibuError.missingCharacteristic)
            return
        }
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { failReady(error); return }
        characteristic.isNotifying ? completeReady() : failReady(MalibuError.missingCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let continuation = writeContinuation else { return }
        writeContinuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            if let pending = pendingRequest { failRequest(token: pending.token, error: error) }
            return
        }
        guard let value = characteristic.value else { return }
        do {
            for frame in try frameReader.feed(value) { try consume(frame) }
        } catch {
            if let pending = pendingRequest { failRequest(token: pending.token, error: error) }
        }
    }
}
