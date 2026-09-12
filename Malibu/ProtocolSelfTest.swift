// Malibu is licensed under CPAL-1.0.
// Copyright (c) 2026 Leon M'laiel. See LICENSE for required attribution.

import Foundation

enum ProtocolSelfTest {
    static func run() {
        #if DEBUG
        let key = Data((0..<16).map(UInt8.init))
        let transmit = Data((16..<32).map(UInt8.init))
        let receive = Data((32..<48).map(UInt8.init))
        let plaintext = Data((0..<64).map(UInt8.init))
        let expected = Data(base64Encoded: "xZ/1tXm3Io/eEcmJrSIh2OXsMox5E7HvsZ+djV9ebf8DBUkkxTxSacSsxvRXwSfVBFbHTUgd+yO6TmIdWDLQxJjFlfVj+AXH26DCg81QXaY=")!
        let cipher = try! PacketCrypto(key: key, transmitNonce: transmit, receiveNonce: receive)
        assert(try! cipher.encrypt(plaintext) == expected, "Spectacles AES-GCM compatibility test failed")
        let decipher = try! PacketCrypto(key: key, transmitNonce: receive, receiveNonce: transmit)
        assert(try! decipher.decrypt(expected) == plaintext, "Spectacles AES-GCM decryption test failed")
        assert(Protobuf.int(1, 1) + Protobuf.int(2, 2) + Protobuf.bytes(5, Protobuf.int(1, 0)) == Data([0x08, 0x01, 0x10, 0x02, 0x2A, 0x02, 0x08, 0x00]))
        let pairingProof = try! SpectaclesPairingCrypto.generateProof(
            clientNonce: Data((0..<16).map(UInt8.init)),
            peerNonce: Data((16..<32).map(UInt8.init)),
            sharedSecret: Data((0..<32).map(UInt8.init))
        )
        assert(
            pairingProof == Data(base64Encoded: "jxiX6B1s1UbUDoHLbzG7lzUamZ46JntKpY/EHw==")!,
            "Spectacles mutual-proof compatibility test failed"
        )
        #endif
    }
}
