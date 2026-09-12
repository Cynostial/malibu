// Malibu is licensed under CPAL-1.0.
// Copyright (c) 2026 Leon M'laiel. See LICENSE for required attribution.

import SwiftUI

@main
struct MalibuApp: App {
    @StateObject private var controller = SpectaclesController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
                .preferredColorScheme(.dark)
        }
    }
}
