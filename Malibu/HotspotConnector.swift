// Malibu is licensed under CPAL-1.0.
// Copyright (c) 2026 Leon M'laiel. See LICENSE for required attribution.

import Foundation
import NetworkExtension

enum HotspotJoinResult {
    case joined
    case requiresWiFiSettings
}

@MainActor
final class HotspotConnector {
    func join(
        ssid: String,
        password: String,
        peripheralIdentifier: UUID
    ) async throws -> HotspotJoinResult {
        do {
            try await AccessorySetupConnector.shared.join(
                peripheralIdentifier: peripheralIdentifier,
                ssid: ssid,
                password: password
            )
            return .joined
        } catch {
            let failure = error as NSError
            if failure.domain == NEHotspotConfigurationErrorDomain {
                if failure.code == 13 {
                    return .joined
                }
                if failure.code == 8 {
                    return .requiresWiFiSettings
                }
                throw MalibuError.networkFailure(
                    "iOS could not join the approved Specs Wi-Fi (Hotspot Configuration error \(failure.code))"
                )
            }
            throw MalibuError.networkFailure(
                "iOS could not join the approved Specs Wi-Fi: \(error.localizedDescription)"
            )
        }
    }
}
