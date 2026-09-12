// Malibu is licensed under CPAL-1.0.
// Copyright (c) 2026 Leon M'laiel. See LICENSE for required attribution.

import CryptoKit
import Foundation
import Security

struct SpectaclesPairingMaterial {
    let encryptionKey: Data
    let message: Data
    let tag: Data
}

enum SpectaclesPairingCrypto {
    private static let proofAsset: Data = {
        guard let url = Bundle.main.url(forResource: "ProofVM", withExtension: "bin"),
              let data = try? Data(contentsOf: url)
        else {
            fatalError("The Spectacles pairing engine is missing from this build.")
        }
        return data
    }()

    static func establish(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        clientNonce: Data,
        peerNonce: Data,
        peerPublicKey: Data
    ) throws -> SpectaclesPairingMaterial {
        guard clientNonce.count == 16, peerNonce.count == 16, peerPublicKey.count == 32 else {
            throw MalibuError.protocolFailure("invalid Spectacles pairing material")
        }
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let agreement = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let sharedSecret = agreement.withUnsafeBytes { Data($0) }
        guard sharedSecret.count == 32 else {
            throw MalibuError.protocolFailure("X25519 returned an invalid shared secret")
        }

        let derived = HMAC<SHA256>.authenticationCode(
            for: Data("v2".utf8),
            using: SymmetricKey(data: sharedSecret)
        )
        let encryptionKey = Data(derived.prefix(16))
        let proof = try generateProof(
            clientNonce: clientNonce,
            peerNonce: peerNonce,
            sharedSecret: sharedSecret
        )
        return SpectaclesPairingMaterial(
            encryptionKey: encryptionKey,
            message: proof.prefix(12),
            tag: proof.suffix(16)
        )
    }

    static func generateProof(
        clientNonce: Data,
        peerNonce: Data,
        sharedSecret: Data
    ) throws -> Data {
        guard clientNonce.count == 16, peerNonce.count == 16, sharedSecret.count == 32 else {
            throw MalibuError.protocolFailure("invalid pairing proof input")
        }
        var output = [UInt8](repeating: 0, count: 28)
        let status: Int32 = proofAsset.withUnsafeBytes { assetBuffer in
            clientNonce.withUnsafeBytes { clientBuffer in
                peerNonce.withUnsafeBytes { peerBuffer in
                    sharedSecret.withUnsafeBytes { sharedBuffer in
                        spectacles_proof_generate(
                            assetBuffer.bindMemory(to: UInt8.self).baseAddress,
                            proofAsset.count,
                            clientBuffer.bindMemory(to: UInt8.self).baseAddress,
                            peerBuffer.bindMemory(to: UInt8.self).baseAddress,
                            sharedBuffer.bindMemory(to: UInt8.self).baseAddress,
                            &output
                        )
                    }
                }
            }
        }
        guard status == 0 else {
            throw MalibuError.protocolFailure("pairing proof engine failed (\(status))")
        }
        return Data(output)
    }

    static func validatePeerProofEnvelope(message: Data, tag: Data) throws {
        guard tag.count == 16 else {
            throw MalibuError.protocolFailure("the glasses returned an invalid verification tag")
        }
        // Spectacles 2 sends an AMBA device-attestation message here. It is a
        // certificate-bearing blob (796 bytes on the tested 2018 firmware),
        // not the 12-byte application challenge that Malibu sends to command
        // 116. Its exact length can vary with the firmware's certificate data.
        guard message.count >= 256, message.count <= 4_096 else {
            throw MalibuError.protocolFailure(
                "the glasses returned an invalid verification message (\(message.count) bytes)"
            )
        }
    }
}

enum PairingKeyStore {
    private static let service = "io.github.cynostial.Malibu"
    private static let keyAccount = "packet-encryption-key"
    private static let peripheralAccount = "bluetooth-peripheral-identifier"
    private static let userAccount = "local-user-identifier"
    private static let networkAccount = "wifi-network-name"

    static func loadKey() -> Data? {
        guard let key = load(account: keyAccount), key.count == 16 else { return nil }
        return key
    }

    static func loadPeripheralIdentifier() -> UUID? {
        guard let data = load(account: peripheralAccount),
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return UUID(uuidString: value)
    }

    static func loadNetworkSSID() -> String? {
        guard let data = load(account: networkAccount),
              let value = String(data: data, encoding: .utf8),
              value.hasPrefix("Malibu-"),
              value.count <= 32
        else { return nil }
        return value
    }

    static func makeNetworkSSID() throws -> String {
        let suffix = try Data.secureRandom(count: 4)
            .map { String(format: "%02X", $0) }
            .joined()
        return "Malibu-\(suffix)"
    }

    static func localUserID() throws -> String {
        if let data = load(account: userAccount),
           let value = String(data: data, encoding: .utf8),
           value.count == 32 {
            return value
        }
        let value = try Data.secureRandom(count: 16)
            .map { String(format: "%02x", $0) }
            .joined()
        try save(Data(value.utf8), account: userAccount)
        return value
    }

    static func save(key: Data, peripheralIdentifier: UUID, networkSSID: String) throws {
        guard key.count == 16 else {
            throw MalibuError.protocolFailure("refusing to save an invalid Spectacles key")
        }
        guard networkSSID.hasPrefix("Malibu-"), networkSSID.count <= 32 else {
            throw MalibuError.protocolFailure("refusing to save an invalid Spectacles network name")
        }
        try save(Data(networkSSID.utf8), account: networkAccount)
        try save(key, account: keyAccount)
        try save(Data(peripheralIdentifier.uuidString.utf8), account: peripheralAccount)
    }

    private static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func save(_ value: Data, account: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(identity as CFDictionary)
        var item = identity
        item[kSecValueData as String] = value
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MalibuError.protocolFailure("could not save pairing data (\(status))")
        }
    }

    static func delete() {
        for account in [keyAccount, peripheralAccount, userAccount, networkAccount] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
