// Malibu is licensed under CPAL-1.0.
// Copyright (c) 2026 Leon M'laiel. See LICENSE for required attribution.

import CoreBluetooth
import Foundation

enum DeviceProfile {
    static let model = "Spectacles 2"
    static let pairingMarker = Data("050".utf8)

    static let bleService = CBUUID(string: "0000FE45-0000-1000-8000-00805F9B34FB")
    static let writeCharacteristic = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let notifyCharacteristic = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    static let mediaHost = "192.168.42.1"
    static let mediaPort: UInt16 = 1234
}
