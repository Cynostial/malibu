// Malibu is licensed under CPAL-1.0.
// Copyright (c) 2026 Leon M'laiel. See LICENSE for required attribution.

import CoreBluetooth
import Foundation
import Security

enum MalibuError: LocalizedError {
    case bluetoothUnavailable(String)
    case glassesNotFound
    case pairingModeNotFound
    case disconnected
    case missingCharacteristic
    case busy
    case timeout(String)
    case protocolFailure(String)
    case networkFailure(String)
    case photoFailure(String)
    case libraryFailure(String)

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let detail): return "Bluetooth is unavailable: \(detail)"
        case .glassesNotFound: return "The paired Spectacles were not found. Unfold them, keep them close, and try again."
        case .pairingModeNotFound: return "The Spectacles did not enter pairing mode. Hold their only button continuously for 7 seconds, release it, then try again."
        case .disconnected: return "The Spectacles disconnected. Unfold them, keep them close, and try again."
        case .missingCharacteristic: return "The Spectacles Bluetooth control service is incomplete."
        case .busy: return "A Spectacles command is already in progress."
        case .timeout(let operation): return "Timed out while \(operation)."
        case .protocolFailure(let detail): return "Spectacles protocol error: \(detail)"
        case .networkFailure(let detail): return "Wi-Fi transfer error: \(detail)"
        case .photoFailure(let detail): return "Could not save to Photos: \(detail)"
        case .libraryFailure(let detail): return "Video library error: \(detail)"
        }
    }
}

extension Data {
    static func secureRandom(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw MalibuError.protocolFailure("secure random generation failed (\(status))")
        }
        return Data(bytes)
    }

    func uint16LE(at offset: Int) throws -> UInt16 {
        guard count >= offset + 2 else { throw MalibuError.protocolFailure("short 16-bit value") }
        let low = UInt16(self[index(startIndex, offsetBy: offset)])
        let high = UInt16(self[index(startIndex, offsetBy: offset + 1)]) << 8
        return low | high
    }

    func uint32BE(at offset: Int = 0) throws -> UInt32 {
        guard count >= offset + 4 else { throw MalibuError.protocolFailure("short 32-bit value") }
        var value: UInt32 = 0
        for byte in self[offset..<(offset + 4)] { value = (value << 8) | UInt32(byte) }
        return value
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}

func incrementBigEndian(_ data: inout Data) {
    guard !data.isEmpty else { return }
    for position in data.indices.reversed() {
        data[position] &+= 1
        if data[position] != 0 { break }
    }
}

func sanitizeFilename(_ value: String, fallback: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
    let result = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "._"))
    return result.isEmpty ? fallback : result
}
