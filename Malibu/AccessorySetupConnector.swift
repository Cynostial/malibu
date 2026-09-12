// Malibu is licensed under CPAL-1.0.
// Copyright (c) 2026 Leon M'laiel. See LICENSE for required attribution.

import AccessorySetupKit
import CoreBluetooth
import Foundation
import NetworkExtension
import UIKit

@available(iOS 18.0, *)
@MainActor
final class AccessorySetupConnector {
    static let shared = AccessorySetupConnector()

    private let session = ASAccessorySession()
    private var isActivated = false
    private var activationContinuation: CheckedContinuation<Void, Error>?
    private var eventAccessory: ASAccessory?
    private var eventError: Error?

    private init() {}

    func selectSpectaclesForPairing(ssid: String) async throws -> UUID {
        try await activate()

        if let existing = session.accessories.first(where: {
            $0.state == .authorized && $0.bluetoothIdentifier != nil && $0.ssid == ssid
        }),
           let identifier = existing.bluetoothIdentifier {
            return identifier
        }

        eventAccessory = nil
        eventError = nil

        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = DeviceProfile.bleService
        descriptor.ssid = ssid

        let displayItem = ASPickerDisplayItem(
            name: "Malibu Spectacles",
            productImage: productImage(),
            descriptor: descriptor
        )
        try await session.showPicker(for: [displayItem])

        if let identifier = try await waitForSelectedIdentifier() {
            return identifier
        }
        if let eventError {
            throw eventError
        }
        throw MalibuError.bluetoothUnavailable(
            "the one-time iPhone accessory setup was closed before the glasses were selected"
        )
    }

    private func waitForSelectedIdentifier() async throws -> UUID? {
        for _ in 0..<20 {
            if let identifier = eventAccessory?.bluetoothIdentifier {
                return identifier
            }
            if eventError != nil {
                return nil
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private func waitForMatchingAccessory(
        peripheralIdentifier: UUID,
        ssid: String
    ) async throws -> ASAccessory? {
        for _ in 0..<20 {
            if let accessory = eventAccessory
                ?? matchingAccessory(peripheralIdentifier: peripheralIdentifier, ssid: ssid) {
                return accessory
            }
            if eventError != nil {
                return nil
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private func waitForAuthorizedAccessory(
        peripheralIdentifier: UUID,
        ssid: String
    ) async throws -> ASAccessory? {
        for _ in 0..<20 {
            if let accessory = authorizedAccessory(
                peripheralIdentifier: peripheralIdentifier,
                ssid: ssid
            ) {
                return accessory
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private func requireAuthorizationCompletion(
        peripheralIdentifier: UUID,
        ssid: String
    ) async throws {
        guard try await waitForAuthorizedAccessory(
            peripheralIdentifier: peripheralIdentifier,
            ssid: ssid
        ) != nil else {
            throw MalibuError.bluetoothUnavailable(
                "iOS did not finish the one-time Spectacles network authorization"
            )
        }
    }

    func isAuthorized(peripheralIdentifier: UUID, ssid: String) async throws -> Bool {
        try await activate()
        return authorizedAccessory(peripheralIdentifier: peripheralIdentifier, ssid: ssid) != nil
    }

    func ensureAuthorized(peripheralIdentifier: UUID, ssid: String) async throws {
        try await activate()
        if authorizedAccessory(peripheralIdentifier: peripheralIdentifier, ssid: ssid) != nil {
            return
        }

        if let existing = matchingAccessory(
            peripheralIdentifier: peripheralIdentifier,
            ssid: ssid
        ), existing.state == .awaitingAuthorization {
            try await finishAuthorization(for: existing, ssid: ssid)
            try await requireAuthorizationCompletion(
                peripheralIdentifier: peripheralIdentifier,
                ssid: ssid
            )
            return
        }

        eventAccessory = nil
        eventError = nil

        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = DeviceProfile.bleService
        descriptor.ssid = ssid

        let migration = ASMigrationDisplayItem(
            name: "Malibu Spectacles",
            productImage: productImage(),
            descriptor: descriptor
        )
        migration.peripheralIdentifier = peripheralIdentifier
        migration.hotspotSSID = ssid

        try await session.showPicker(for: [migration])
        if let eventError {
            throw eventError
        }

        guard let accessory = try await waitForMatchingAccessory(
            peripheralIdentifier: peripheralIdentifier,
            ssid: ssid
        )
        else {
            throw MalibuError.networkFailure(
                "the one-time iPhone accessory approval was closed before Malibu was authorized"
            )
        }

        if accessory.state == .awaitingAuthorization {
            try await finishAuthorization(for: accessory, ssid: ssid)
        }

        try await requireAuthorizationCompletion(
            peripheralIdentifier: peripheralIdentifier,
            ssid: ssid
        )
    }

    func join(peripheralIdentifier: UUID, ssid: String, password: String) async throws {
        try await activate()
        guard let accessory = authorizedAccessory(
            peripheralIdentifier: peripheralIdentifier,
            ssid: ssid
        ) else {
            throw MalibuError.networkFailure("the Spectacles accessory is not authorized on this iPhone")
        }

        try await NEHotspotConfigurationManager.shared.joinAccessoryHotspot(
            accessory,
            passphrase: password
        )
    }

    private func activate() async throws {
        if isActivated { return }

        try await withCheckedThrowingContinuation { continuation in
            activationContinuation = continuation
            session.activate(on: .main) { [weak self] event in
                Task { @MainActor in
                    self?.handle(event)
                }
            }
        }
    }

    private func handle(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated:
            isActivated = true
            activationContinuation?.resume()
            activationContinuation = nil
        case .accessoryAdded, .migrationComplete:
            eventAccessory = event.accessory
        case .pickerSetupFailed:
            eventError = event.error
        case .invalidated:
            isActivated = false
            if let continuation = activationContinuation {
                continuation.resume(
                    throwing: event.error
                        ?? MalibuError.networkFailure("the iPhone accessory session stopped")
                )
                activationContinuation = nil
            }
        default:
            break
        }
    }

    private func authorizedAccessory(peripheralIdentifier: UUID, ssid: String) -> ASAccessory? {
        matchingAccessory(peripheralIdentifier: peripheralIdentifier, ssid: ssid)
            .flatMap { accessory in
                accessory.state == .authorized && accessory.ssid == ssid ? accessory : nil
            }
    }

    private func matchingAccessory(peripheralIdentifier: UUID, ssid: String) -> ASAccessory? {
        session.accessories.first { accessory in
            accessory.bluetoothIdentifier == peripheralIdentifier || accessory.ssid == ssid
        }
    }

    private func finishAuthorization(for accessory: ASAccessory, ssid: String) async throws {
        let settings = ASAccessorySettings.default
        settings.ssid = ssid
        try await session.finishAuthorization(for: accessory, settings: settings)
    }

    private func productImage() -> UIImage {
        let size = CGSize(width: 540, height: 360)
        return UIGraphicsImageRenderer(size: size).image { context in
            let glassesColor = UIColor(red: 0.04, green: 0.72, blue: 0.94, alpha: 1)
            let lineWidth: CGFloat = 24
            let lensSize = CGSize(width: 148, height: 118)
            let leftLens = CGRect(x: 92, y: 112, width: lensSize.width, height: lensSize.height)
            let rightLens = CGRect(x: 300, y: 112, width: lensSize.width, height: lensSize.height)

            context.cgContext.setStrokeColor(glassesColor.cgColor)
            context.cgContext.setLineWidth(lineWidth)
            context.cgContext.setLineCap(.round)
            context.cgContext.strokeEllipse(in: leftLens)
            context.cgContext.strokeEllipse(in: rightLens)
            context.cgContext.move(to: CGPoint(x: leftLens.maxX, y: leftLens.midY))
            context.cgContext.addCurve(
                to: CGPoint(x: rightLens.minX, y: rightLens.midY),
                control1: CGPoint(x: 260, y: 142),
                control2: CGPoint(x: 280, y: 142)
            )
            context.cgContext.strokePath()
            context.cgContext.move(to: CGPoint(x: leftLens.minX, y: leftLens.midY - 10))
            context.cgContext.addLine(to: CGPoint(x: 30, y: 82))
            context.cgContext.move(to: CGPoint(x: rightLens.maxX, y: rightLens.midY - 10))
            context.cgContext.addLine(to: CGPoint(x: 510, y: 82))
            context.cgContext.strokePath()
        }
    }
}
