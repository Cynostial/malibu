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
                if failure.code == 13 {
                    return
                }
                if failure.code == 8 {
                    throw MalibuError.networkFailure(
                        "automatic Specs Wi-Fi needs Apple's Hotspot Configuration capability, but the installed signing profile does not provide it"
                    )
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
