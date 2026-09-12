// Malibu is licensed under CPAL-1.0.
// Copyright (c) 2026 Leon M'laiel. See LICENSE for required attribution.

import AVFoundation
import Combine
import CryptoKit
import Foundation
import UIKit

enum ImportPhase: Equatable {
    case idle
    case pairing
    case locating
    case authenticating
    case switchingWiFi
    case reading
    case downloading
    case saving
    case complete
    case failed
}

@MainActor
final class SpectaclesController: ObservableObject {
    private struct ImportCredentials {
        let encryptionKey: Data
        let peripheralIdentifier: UUID
        let ssid: String
        let password: String
    }

    private struct VideoLibraryManifest: Codable {
        var renamedFiles: [String: String] = [:]
    }

    @Published var status = ""
    @Published var detail = ""
    @Published var isPaired = false
    @Published var isPairing = false
    @Published var progress: Double = 0
    @Published var isWorking = false
    @Published var needsWiFiJoin = false
    @Published var importedVideos: [URL] = []
    @Published var lastError: String?
    @Published var importPhase: ImportPhase = .idle
    @Published var currentClip = 0
    @Published var totalClips = 0
    @Published var clipProgress: Double = 0
    @Published var currentImportThumbnail: UIImage?

    private var operationTask: Task<Void, Never>?
    private var activeBLE: SpectaclesBLE?
    private var activeMedia: AMBAClient?
    private var didStartAutomatically = false

    init() {
        ProtocolSelfTest.run()
        isPaired = PairingKeyStore.loadKey() != nil && PairingKeyStore.loadPeripheralIdentifier() != nil
        if isPaired {
            status = "Ready to import"
            detail = "Unfold the glasses and keep them nearby. Malibu imports automatically."
        } else {
            status = "Pair your Spectacles"
            detail = "Hold their only button for 7 seconds, release it, then tap Pair Spectacles."
        }
        refreshLibrary()
    }

    func startAutomaticImportIfReady() {
        guard !didStartAutomatically else { return }
        didStartAutomatically = true
        guard isPaired else { return }
        importVideos()
    }

    func pairSpectacles() {
        guard !isWorking else { return }
        isWorking = true
        isPairing = true
        importPhase = .pairing
        lastError = nil
        progress = 0
        operationTask = Task { [weak self] in
            guard let self else { return }
            let paired = await self.runPairing()
            guard paired, !Task.isCancelled else { return }
            self.resetImportProgress()
            await self.runPreparedImport()
        }
    }

    func importVideos() {
        guard !isWorking else { return }
        isWorking = true
        lastError = nil
        progress = 0
        currentClip = 0
        totalClips = 0
        clipProgress = 0
        currentImportThumbnail = nil
        importPhase = .locating
        guard PairingKeyStore.loadKey() != nil,
              PairingKeyStore.loadPeripheralIdentifier() != nil
        else {
            status = "Pair your Spectacles first"
            detail = "Hold their only button for 7 seconds, release it, then tap Pair Spectacles."
            isWorking = false
            return
        }
        operationTask = Task { [weak self] in
            guard let self else { return }
            await self.runPreparedImport()
        }
    }

    func cancelOperation() {
        operationTask?.cancel()
        activeMedia?.close()
        activeBLE?.disconnect()
    }

    private func runPairing() async -> Bool {
        var ble: SpectaclesBLE?
        var paired = false
        do {
            let networkSSID: String
            if let existingKey = PairingKeyStore.loadKey(),
               let existingIdentifier = PairingKeyStore.loadPeripheralIdentifier() {
                networkSSID = makeImportCredentials(
                    encryptionKey: existingKey,
                    peripheralIdentifier: existingIdentifier
                ).ssid
            } else {
                networkSSID = try PairingKeyStore.makeNetworkSSID()
            }

            var selectedIdentifier: UUID?
            if #available(iOS 18.0, *) {
                status = "Choose your Spectacles once"
                detail = "Use the iPhone accessory card to give Malibu Bluetooth and Wi-Fi access."
                selectedIdentifier = try await AccessorySetupConnector.shared.selectSpectaclesForPairing(
                    ssid: networkSSID
                )
            }

            let connection = SpectaclesBLE()
            ble = connection
            activeBLE = connection
            status = "Looking for pairing mode…"
            detail = "Keep the glasses close. Their radio must be showing marker 050."
            try await connection.connect(forPairing: true, knownIdentifier: selectedIdentifier)
            guard let peripheralIdentifier = connection.connectedIdentifier else {
                throw MalibuError.protocolFailure("iOS did not provide a Bluetooth identifier")
            }

            status = "Pairing securely…"
            detail = "Exchanging keys with Spectacles 2. This can take a few seconds."
            let localUserID = try PairingKeyStore.localUserID()
            let key = try await connection.pair(localUserID: localUserID)
            try PairingKeyStore.save(
                key: key,
                peripheralIdentifier: peripheralIdentifier,
                networkSSID: networkSSID
            )

            if #available(iOS 18.0, *) {
                let credentials = makeImportCredentials(
                    encryptionKey: key,
                    peripheralIdentifier: peripheralIdentifier
                )
                try await AccessorySetupConnector.shared.ensureAuthorized(
                    peripheralIdentifier: peripheralIdentifier,
                    ssid: credentials.ssid
                )
            }

            isPaired = true
            importPhase = .complete
            progress = 1
            status = "Spectacles paired"
            detail = "Pairing and network access are saved. Import is starting now."
            paired = true
            connection.disconnect()
        } catch {
            importPhase = .failed
            lastError = error.localizedDescription
            status = "Pairing stopped"
            detail = error.localizedDescription
            ble?.disconnect()
        }
        isPairing = false
        activeBLE = nil
        if !paired {
            isWorking = false
            operationTask = nil
        }
        return paired
    }

    private func runPreparedImport() async {
        guard let encryptionKey = PairingKeyStore.loadKey(),
              let peripheralIdentifier = PairingKeyStore.loadPeripheralIdentifier()
        else {
            status = "Pair your Spectacles first"
            detail = "The iPhone does not have a pairing key yet."
            isWorking = false
            operationTask = nil
            return
        }

        let credentials = makeImportCredentials(
            encryptionKey: encryptionKey,
            peripheralIdentifier: peripheralIdentifier
        )

        do {
            if #available(iOS 18.0, *) {
                let isAuthorized = try await AccessorySetupConnector.shared.isAuthorized(
                    peripheralIdentifier: peripheralIdentifier,
                    ssid: credentials.ssid
                )
                if !isAuthorized {
                    importPhase = .pairing
                    status = "Approve your Spectacles once"
                    detail = "Tap Continue on the iPhone accessory card. Malibu will join the glasses automatically after this."
                    try await AccessorySetupConnector.shared.ensureAuthorized(
                        peripheralIdentifier: peripheralIdentifier,
                        ssid: credentials.ssid
                    )
                }
            }
            try Task.checkCancellation()
            await runImport(credentials)
        } catch is CancellationError {
            importPhase = .idle
            status = "Import cancelled"
            detail = "Unfold the glasses and try again when you are ready."
            isWorking = false
            operationTask = nil
        } catch {
            importPhase = .failed
            lastError = error.localizedDescription
            status = "iPhone setup stopped"
            detail = error.localizedDescription
            isWorking = false
            operationTask = nil
        }
    }

    private func resetImportProgress() {
        lastError = nil
        progress = 0
        currentClip = 0
        totalClips = 0
        clipProgress = 0
        currentImportThumbnail = nil
        importPhase = .locating
    }

    func refreshLibrary() {
        do {
            let directory = try videoDirectory()
            importedVideos = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return leftDate > rightDate
            }
        } catch {
            importedVideos = []
        }
    }

    func renameVideo(_ source: URL, to requestedName: String) throws {
        let directory = try videoDirectory()
        try validateLibraryURL(source, directory: directory)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw MalibuError.libraryFailure("the video no longer exists")
        }

        let name = try normalizedVideoName(requestedName)
        let destination = directory.appendingPathComponent(name).appendingPathExtension("mp4")
        if source.lastPathComponent.caseInsensitiveCompare(destination.lastPathComponent) == .orderedSame {
            return
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw MalibuError.libraryFailure("a video named \(name).mp4 already exists")
        }

        var manifest = loadVideoLibraryManifest(in: directory)
        let sourceFilename = source.lastPathComponent
        let originalFilename = manifest.renamedFiles.first {
            $0.value.caseInsensitiveCompare(sourceFilename) == .orderedSame
        }?.key ?? sourceFilename

        try FileManager.default.moveItem(at: source, to: destination)
        manifest.renamedFiles[originalFilename] = destination.lastPathComponent
        do {
            try saveVideoLibraryManifest(manifest, in: directory)
        } catch {
            try? FileManager.default.moveItem(at: destination, to: source)
            throw error
        }
        refreshLibrary()
    }

    func deleteVideo(_ url: URL) throws {
        let directory = try videoDirectory()
        try validateLibraryURL(url, directory: directory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            refreshLibrary()
            return
        }

        try FileManager.default.removeItem(at: url)
        var manifest = loadVideoLibraryManifest(in: directory)
        manifest.renamedFiles = manifest.renamedFiles.filter {
            $0.key.caseInsensitiveCompare(url.lastPathComponent) != .orderedSame
                && $0.value.caseInsensitiveCompare(url.lastPathComponent) != .orderedSame
        }
        try saveVideoLibraryManifest(manifest, in: directory)
        refreshLibrary()
    }

    func deleteAllVideos() throws {
        let directory = try videoDirectory()
        let videos = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "mp4" }
        for video in videos {
            try FileManager.default.removeItem(at: video)
        }
        try saveVideoLibraryManifest(VideoLibraryManifest(), in: directory)
        refreshLibrary()
    }

    private func runImport(_ credentials: ImportCredentials) async {
        let encryptionKey = credentials.encryptionKey
        let peripheralIdentifier = credentials.peripheralIdentifier
        let ble = SpectaclesBLE()
        let media = AMBAClient(encryptionKey: encryptionKey)
        activeBLE = ble
        activeMedia = media

        do {
            importPhase = .locating
            status = "Looking for your Spectacles…"
            detail = "Keep them close to the iPhone."
            try await ble.connect(knownIdentifier: peripheralIdentifier)

            importPhase = .authenticating
            status = "Authenticating…"
            detail = "Using the pairing key stored securely on this iPhone."
            try await ble.enableSecurity(key: encryptionKey)

            let ssid = credentials.ssid
            let password = credentials.password
            status = "Starting Specs Wi-Fi"
            detail = "The saved network name and password are reused for this pairing."
            try await ble.startAccessPoint(ssid: ssid, password: password)

            needsWiFiJoin = true
            importPhase = .switchingWiFi
            status = "Joining Specs Wi-Fi"
            detail = "iOS is joining the accessory network approved during setup."

            try await HotspotConnector().join(
                ssid: ssid,
                password: password,
                peripheralIdentifier: peripheralIdentifier
            )

            do {
                try await media.connectAndSetupWithRetry(maxAttempts: 4)
            } catch {
                status = "Waiting for Specs Wi-Fi"
                detail = "The network is approved. iOS is finishing the connection."
                try await media.connectAndSetupWithRetry(maxAttempts: 4)
            }
            needsWiFiJoin = false

            importPhase = .reading
            status = "Reading the clip list…"
            detail = "The Bluetooth connection stays open during transfer."
            let clips = try await media.listClipsWithRetry().filter { $0.video != nil }
            totalClips = clips.count
            guard !clips.isEmpty else {
                importPhase = .complete
                status = "No clips found"
                detail = "Record a clip with one button press and try again."
                await cleanUp()
                isWorking = false
                activeBLE = nil
                activeMedia = nil
                operationTask = nil
                return
            }

            let directory = try videoDirectory()
            let manifest = loadVideoLibraryManifest(in: directory)
            var newlyImported: [URL] = []
            for (index, clip) in clips.enumerated() {
                guard let video = clip.video else { continue }
                let sourceFilename = sanitizeFilename(
                    clip.contentID,
                    fallback: String(format: "spectacles_%04d", index + 1)
                ) + ".mp4"
                let filename = manifest.renamedFiles[sourceFilename] ?? sourceFilename
                let destination = directory.appendingPathComponent(filename)
                let existingSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                if existingSize == video.size {
                    currentClip = index + 1
                    clipProgress = 1
                    progress = Double(index + 1) / Double(clips.count)
                    continue
                }

                importPhase = .downloading
                currentClip = index + 1
                clipProgress = 0
                currentImportThumbnail = nil
                status = "Importing \(index + 1) of \(clips.count)"
                detail = "Preparing \(filename)"
                if let thumbnailData = await media.thumbnailData(for: clip),
                   let thumbnail = UIImage(data: thumbnailData) {
                    currentImportThumbnail = thumbnail
                }
                detail = filename
                try await media.download(clip: clip, to: destination) { [weak self] clipProgress in
                    Task { @MainActor in
                        self?.clipProgress = clipProgress
                        self?.progress = (Double(index) + clipProgress) / Double(clips.count)
                    }
                }
                currentImportThumbnail = await videoThumbnail(for: destination) ?? currentImportThumbnail
                newlyImported.append(destination)
            }

            importPhase = .saving
            status = "Saving to Photos…"
            detail = newlyImported.isEmpty ? "Every clip was already imported." : "Allow add-only Photos access if iOS asks."
            let savedToPhotos = try await PhotosSaver.add(videos: newlyImported)
            refreshLibrary()
            progress = 1
            importPhase = .complete
            status = newlyImported.isEmpty ? "Everything is up to date" : "Import complete"
            detail = newlyImported.isEmpty
                ? "No new videos were copied."
                : "\(newlyImported.count) new video\(newlyImported.count == 1 ? "" : "s") imported; \(savedToPhotos) added to Photos."
            await cleanUp()
        } catch is CancellationError {
            importPhase = .idle
            status = "Import cancelled"
            detail = "Unfold the glasses and try again when you are ready."
            await cleanUp()
        } catch {
            importPhase = .failed
            lastError = error.localizedDescription
            status = "Import stopped"
            detail = error.localizedDescription
            await cleanUp()
        }

        isWorking = false
        activeBLE = nil
        activeMedia = nil
        operationTask = nil
    }

    private func cleanUp() async {
        activeMedia?.close()
        await activeBLE?.stopAccessPoint()
        activeBLE?.disconnect()
        needsWiFiJoin = false
    }

    private func makeImportCredentials(
        encryptionKey: Data,
        peripheralIdentifier: UUID
    ) -> ImportCredentials {
        let peripheralPart = peripheralIdentifier.uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(6)
            .uppercased()
        let keyPart = SHA256.hash(data: encryptionKey)
            .prefix(3)
            .map { String(format: "%02X", $0) }
            .joined()
        let legacySSID = "Malibu-\(peripheralPart)-\(keyPart)"
        let ssid = PairingKeyStore.loadNetworkSSID() ?? legacySSID
        let password = HMAC<SHA256>.authenticationCode(
            for: Data("Malibu Wi-Fi".utf8),
            using: SymmetricKey(data: encryptionKey)
        )
        .prefix(12)
        .map { String(format: "%02x", $0) }
        .joined()
        return ImportCredentials(
            encryptionKey: encryptionKey,
            peripheralIdentifier: peripheralIdentifier,
            ssid: ssid,
            password: password
        )
    }

    private func videoThumbnail(for url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 420, height: 420)
        let time = CMTime(seconds: 0.2, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: result.image)
    }

    private func videoDirectory() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Spectacles Videos", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func videoLibraryManifestURL(in directory: URL) -> URL {
        directory.appendingPathComponent(".malibu-library.json")
    }

    private func loadVideoLibraryManifest(in directory: URL) -> VideoLibraryManifest {
        let url = videoLibraryManifestURL(in: directory)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(VideoLibraryManifest.self, from: data)
        else {
            return VideoLibraryManifest()
        }
        return manifest
    }

    private func saveVideoLibraryManifest(_ manifest: VideoLibraryManifest, in directory: URL) throws {
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: videoLibraryManifestURL(in: directory), options: .atomic)
        } catch {
            throw MalibuError.libraryFailure("could not update the library index")
        }
    }

    private func validateLibraryURL(_ url: URL, directory: URL) throws {
        guard url.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL,
              url.pathExtension.lowercased() == "mp4" else {
            throw MalibuError.libraryFailure("the selected file is outside Malibu's video library")
        }
    }

    private func normalizedVideoName(_ requestedName: String) throws -> String {
        var name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".mp4") {
            name.removeLast(4)
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !name.isEmpty, name != ".", name != ".." else {
            throw MalibuError.libraryFailure("enter a name for the video")
        }
        guard name.count <= 120 else {
            throw MalibuError.libraryFailure("use a name with 120 characters or fewer")
        }
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "<>:\"/\\|?*"))
        guard name.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else {
            throw MalibuError.libraryFailure("the name contains a character that cannot be used in a file name")
        }
        return name
    }
}
