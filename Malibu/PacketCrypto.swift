// Malibu is licensed under CPAL-1.0.
// Copyright (c) 2026 Leon M'laiel. See LICENSE for required attribution.

import CryptoKit
import Foundation

final class PacketCrypto {
    private let key: SymmetricKey
    private var transmitNonce: Data
    private var receiveNonce: Data

    init(key: Data, transmitNonce: Data, receiveNonce: Data) throws {
        guard key.count == 16, transmitNonce.count == 16, receiveNonce.count == 16 else {
            throw MalibuError.protocolFailure("invalid AES-GCM key or nonce length")
        }
        self.key = SymmetricKey(data: key)
        self.transmitNonce = transmitNonce
        self.receiveNonce = receiveNonce
    }

    func encrypt(_ plaintext: Data) throws -> Data {
        let nonce = try AES.GCM.Nonce(data: transmitNonce)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        var result = sealed.ciphertext
        result.append(sealed.tag)
        incrementBigEndian(&transmitNonce)
        return result
    }

    func decrypt(_ packet: Data) throws -> Data {
        guard packet.count >= 16 else { throw MalibuError.protocolFailure("encrypted packet is too short") }
        let nonce = try AES.GCM.Nonce(data: receiveNonce)
        let ciphertext = packet.dropLast(16)
        let tag = packet.suffix(16)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext = try AES.GCM.open(box, using: key)
        incrementBigEndian(&receiveNonce)
        return plaintext
    }
}
