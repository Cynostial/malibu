// Malibu is licensed under CPAL-1.0.
// Copyright (c) 2026 Leon M'laiel. See LICENSE for required attribution.

import Foundation
import Photos

enum PhotosSaver {
    static func add(videos: [URL]) async throws -> Int {
        guard !videos.isEmpty else { return 0 }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return 0 }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                for url in videos {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            } completionHandler: { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: MalibuError.photoFailure("Photos rejected the videos")) }
            }
        }
        return videos.count
    }
}
