// Malibu is licensed under CPAL-1.0.
// Copyright (c) 2026 Leon M'laiel. See LICENSE for required attribution.

import Foundation

@MainActor
final class HotspotConnector {
    func join(
        ssid: String,
        password: String,
        peripheralIdentifier: UUID
    ) async throws {
        try await AccessorySetupConnector.shared.join(
            peripheralIdentifier: peripheralIdentifier,
            ssid: ssid,
            password: password
        )
    }
}
