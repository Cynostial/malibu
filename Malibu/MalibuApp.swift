// Malibu is licensed under CPAL-1.0.
// Copyright (c) 2026 Leon M'laiel. See LICENSE for required attribution.

import SwiftUI

@main
struct MalibuApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = SpectaclesController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        controller.sceneBecameActive()
                    case .background:
                        controller.sceneEnteredBackground()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
