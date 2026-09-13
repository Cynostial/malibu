// Malibu is licensed under CPAL-1.0.
// Copyright (c) 2026 Leon M'laiel. See LICENSE for required attribution.

import Foundation
import NetworkExtension

@MainActor
final class HotspotConnector {
    func join(
        ssid: String,
        password: String,
        peripheralIdentifier: UUID
    ) async throws {
        do {
            try await AccessorySetupConnector.shared.join(
                peripheralIdentifier: peripheralIdentifier,
                ssid: ssid,
                password: password
            )
        } catch {
            let failure = error as NSError
            if failure.domain == NEHotspotConfigurationErrorDomain {
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
