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

    private struct PendingClip {
        let clip: SpectaclesClip
        let filename: String
        let destination: URL
    }

    private struct SyncResult {
        let catalogueCount: Int
        let importedCount: Int
        let savedToPhotos: Int
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
    @Published var isSessionConnected = false
    @Published var isRefreshingDeviceInfo = false
    @Published var deviceInfo = SpectaclesDeviceInfo()
    @Published var lastSyncDate: Date?
    @Published var manualWiFiSSID: String?
    @Published var manualWiFiPassword: String?
    @Published var awaitingManualWiFi = false

    private var operationTask: Task<Void, Never>?
    private var liveSyncTask: Task<Void, Never>?
    private var activeBLE: SpectaclesBLE?
    private var activeMedia: AMBAClient?
    private var didStartAutomatically = false
    private var isForeground = true
    private var isSyncInFlight = false
    private var didLeaveForManualWiFi = false
    private var wiFiSettingsContinuation: CheckedContinuation<Void, Never>?

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

    func sceneBecameActive() {
        isForeground = true
        if awaitingManualWiFi && didLeaveForManualWiFi {
            resumeManualWiFiImport()
            return
        }
        if !didStartAutomatically {
            startAutomaticImportIfReady()
        } else if isSessionConnected {
            scheduleLiveSync()
        } else if isPaired {
            Task { [weak self] in
                guard let self else { return }
                for _ in 0..<50 {
                    if !self.isWorking && !self.isSyncInFlight {
                        self.importVideos()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard self.isForeground else { return }
                }
            }
        }
    }

    func sceneEnteredBackground() {
        isForeground = false
        if awaitingManualWiFi {
            didLeaveForManualWiFi = true
            return
        }
        liveSyncTask?.cancel()
        liveSyncTask = nil
        operationTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            await self.endSession()
        }
    }

    func pairSpectacles() {
        guard !isWorking else { return }
        liveSyncTask?.cancel()
        liveSyncTask = nil
        isWorking = true
        isPairing = true
        importPhase = .pairing
        lastError = nil
        progress = 0
        operationTask = Task { [weak self] in
            guard let self else { return }
            await self.endSession()
            let paired = await self.runPairing()
            guard paired, !Task.isCancelled else {
                self.isWorking = false
                self.isPairing = false
                self.operationTask = nil
                return
            }
            self.resetImportProgress()
            await self.runPreparedImport()
        }
    }

    func importVideos() {
        guard !isWorking, !isSyncInFlight else { return }
        liveSyncTask?.cancel()
        liveSyncTask = nil
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
        liveSyncTask?.cancel()
        liveSyncTask = nil
        resumeManualWiFiImport()
        activeMedia?.close()
        activeBLE?.disconnect()
    }

    func copyManualWiFiSSID() {
        guard let manualWiFiSSID else { return }
        UIPasteboard.general.string = manualWiFiSSID
    }

    func copyManualWiFiPassword() {
        guard let manualWiFiPassword else { return }
        UIPasteboard.general.string = manualWiFiPassword
    }

    func openWiFiSettings() {
        copyManualWiFiPassword()
        guard let settingsURL = URL(string: "prefs:root=WIFI") else { return }
        UIApplication.shared.open(settingsURL, options: [:]) { _ in }
    }

    func resumeManualWiFiImport() {
        guard awaitingManualWiFi else { return }
        awaitingManualWiFi = false
        didLeaveForManualWiFi = false
        let continuation = wiFiSettingsContinuation
        wiFiSettingsContinuation = nil
        continuation?.resume()
    }

    func refreshDeviceInfo() {
        guard isPaired, !isWorking, !isSyncInFlight, !isRefreshingDeviceInfo else { return }
        guard let ble = activeBLE, ble.isConnected, isSessionConnected else {
            importVideos()
            return
        }

        liveSyncTask?.cancel()
        liveSyncTask = nil
        isSyncInFlight = true
        isRefreshingDeviceInfo = true
        operationTask = Task { [weak self] in
            guard let self else { return }
            self.deviceInfo = await ble.readDeviceInfo(existing: self.deviceInfo)
            self.isRefreshingDeviceInfo = false
            self.isSyncInFlight = false
            self.operationTask = nil
            self.scheduleLiveSync()
        }
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
                let authorizedIdentifier = try await AccessorySetupConnector.shared.ensureAuthorized(
                    peripheralIdentifier: peripheralIdentifier,
                    ssid: credentials.ssid
                )
                if authorizedIdentifier != peripheralIdentifier {
                    try PairingKeyStore.save(
                        key: key,
                        peripheralIdentifier: authorizedIdentifier,
                        networkSSID: credentials.ssid
                    )
                }
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

        var credentials = makeImportCredentials(
            encryptionKey: encryptionKey,
            peripheralIdentifier: peripheralIdentifier
        )

        do {
            if #available(iOS 18.0, *) {
                let authorizedIdentifier: UUID
                if let currentIdentifier = try await AccessorySetupConnector.shared.authorizedBluetoothIdentifier(
                    peripheralIdentifier: peripheralIdentifier,
                    ssid: credentials.ssid
                ) {
                    authorizedIdentifier = currentIdentifier
                } else {
                    importPhase = .pairing
                    status = "Approve your Spectacles once"
                    detail = "Tap Continue on the iPhone accessory card. Malibu will join the glasses automatically after this."
                    authorizedIdentifier = try await AccessorySetupConnector.shared.ensureAuthorized(
                        peripheralIdentifier: peripheralIdentifier,
                        ssid: credentials.ssid
                    )
                }

                if authorizedIdentifier != peripheralIdentifier {
                    try PairingKeyStore.save(
                        key: encryptionKey,
                        peripheralIdentifier: authorizedIdentifier,
                        networkSSID: credentials.ssid
                    )
                    credentials = makeImportCredentials(
                        encryptionKey: encryptionKey,
                        peripheralIdentifier: authorizedIdentifier
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
        do {
            let media = try await establishSession(credentials)
            let result = try await syncClips(using: media, passive: false)
            finishSuccessfulSync(result)
            isWorking = false
            isSyncInFlight = false
            operationTask = nil
            scheduleLiveSync()
        } catch is CancellationError {
            importPhase = .idle
            status = "Import cancelled"
            detail = "Unfold the glasses and try again when you are ready."
            await endSession()
            isWorking = false
            isSyncInFlight = false
            operationTask = nil
        } catch {
            importPhase = .failed
            lastError = error.localizedDescription
            status = "Import stopped"
            detail = error.localizedDescription
            await endSession()
            isWorking = false
            isSyncInFlight = false
            operationTask = nil
        }
    }

    private func establishSession(_ credentials: ImportCredentials) async throws -> AMBAClient {
        if isSessionConnected,
           let ble = activeBLE,
           ble.isConnected,
           let media = activeMedia {
            return media
        }

        await endSession()
        let media = AMBAClient(encryptionKey: credentials.encryptionKey)
        activeMedia = media

        importPhase = .locating
        status = "Looking for your Spectacles…"
        detail = "Keep them close to the iPhone."
        let ble = try await connectToSpectaclesWithRetry(credentials.peripheralIdentifier)

        importPhase = .authenticating
        status = "Authenticating…"
        detail = "Using the pairing key stored securely on this iPhone."
        try await ble.enableSecurity(key: credentials.encryptionKey)

        isRefreshingDeviceInfo = true
        deviceInfo = await ble.readDeviceInfo(existing: deviceInfo)
        isRefreshingDeviceInfo = false
        try Task.checkCancellation()

        status = "Starting Specs Wi-Fi"
        detail = "Opening the saved private network for this iPhone."
        try await ble.startAccessPoint(ssid: credentials.ssid, password: credentials.password)

        needsWiFiJoin = true
        importPhase = .switchingWiFi
        status = "Joining Specs Wi-Fi"
        detail = "iOS is joining the accessory network approved during setup."
        let joinResult = try await HotspotConnector().join(
            ssid: credentials.ssid,
            password: credentials.password,
            peripheralIdentifier: credentials.peripheralIdentifier
        )

        if case .requiresWiFiSettings = joinResult {
            manualWiFiSSID = credentials.ssid
            manualWiFiPassword = credentials.password
            UIPasteboard.general.string = credentials.password
            status = "Connect to Specs Wi-Fi"
            detail = "The password is copied. Open Wi-Fi settings below, choose \(credentials.ssid), then return to Malibu."
            await waitForManualWiFiSelection()
            try Task.checkCancellation()
            status = "Connecting to Specs Wi-Fi"
            detail = "The network details stay below while Malibu continues the import."
        }

        do {
            try await media.connectAndSetupWithRetry(maxAttempts: 4)
        } catch {
            status = "Waiting for Specs Wi-Fi"
            detail = "The network is approved. iOS is finishing the connection."
            try await media.connectAndSetupWithRetry(maxAttempts: 4)
        }

        needsWiFiJoin = false
        manualWiFiSSID = nil
        manualWiFiPassword = nil
        isSessionConnected = true
        return media
    }

    private func connectToSpectaclesWithRetry(_ peripheralIdentifier: UUID) async throws -> SpectaclesBLE {
        var lastError: Error = MalibuError.glassesNotFound
        for attempt in 1...4 {
            try Task.checkCancellation()
            let ble = SpectaclesBLE()
            activeBLE = ble
            do {
                try await ble.connect(knownIdentifier: peripheralIdentifier)
                return ble
            } catch {
                lastError = error
                ble.disconnect()
                activeBLE = nil
                guard shouldRetryBluetooth(error), attempt < 4 else {
                    throw error
                }
                status = "Waking Bluetooth"
                detail = "iOS is still exposing the paired glasses. Retrying automatically (\(attempt + 1) of 4)."
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw lastError
    }

    private func shouldRetryBluetooth(_ error: Error) -> Bool {
        guard let malibuError = error as? MalibuError else {
            return false
        }
        switch malibuError {
        case .bluetoothUnavailable(let detail):
            return !detail.contains("turned off")
                && !detail.contains("denied")
                && !detail.contains("restricted")
                && !detail.contains("does not support")
        default:
            return false
        }
    }

    private func waitForManualWiFiSelection() async {
        awaitingManualWiFi = true
        didLeaveForManualWiFi = false
        await withCheckedContinuation { continuation in
            wiFiSettingsContinuation = continuation
        }
    }

    private func syncClips(using media: AMBAClient, passive: Bool) async throws -> SyncResult {
        isSyncInFlight = true
        if !passive {
            importPhase = .reading
            status = "Reading the clip list…"
            detail = "The connection stays open after this check."
        }

        let clips = try await media.listClipsWithRetry().filter { $0.video != nil }
        let directory = try videoDirectory()
        let manifest = loadVideoLibraryManifest(in: directory)
        var pending: [PendingClip] = []

        for (index, clip) in clips.enumerated() {
            guard let video = clip.video else { continue }
            let sourceFilename = sanitizeFilename(
                clip.contentID,
                fallback: String(format: "spectacles_%04d", index + 1)
            ) + ".mp4"
            let filename = manifest.renamedFiles[sourceFilename] ?? sourceFilename
            let destination = directory.appendingPathComponent(filename)
            let existingSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            if existingSize != video.size {
                pending.append(PendingClip(clip: clip, filename: filename, destination: destination))
            }
        }

        totalClips = pending.count
        guard !pending.isEmpty else {
            progress = 1
            currentClip = 0
            clipProgress = 0
            currentImportThumbnail = nil
            isSyncInFlight = false
            return SyncResult(catalogueCount: clips.count, importedCount: 0, savedToPhotos: 0)
        }

        isWorking = true
        var newlyImported: [URL] = []
        for (index, item) in pending.enumerated() {
            importPhase = .downloading
            currentClip = index + 1
            clipProgress = 0
            currentImportThumbnail = nil
            status = "Importing \(index + 1) of \(pending.count)"
            detail = "Preparing \(item.filename)"
            if let thumbnailData = await media.thumbnailData(for: item.clip),
               let thumbnail = UIImage(data: thumbnailData) {
                currentImportThumbnail = thumbnail
            }
            detail = item.filename
            try await media.download(clip: item.clip, to: item.destination) { [weak self] clipProgress in
                Task { @MainActor in
                    self?.clipProgress = clipProgress
                    self?.progress = (Double(index) + clipProgress) / Double(pending.count)
                }
            }
            currentImportThumbnail = await videoThumbnail(for: item.destination) ?? currentImportThumbnail
            newlyImported.append(item.destination)
        }

        importPhase = .saving
        status = "Saving to Photos…"
        detail = "Allow add-only Photos access if iOS asks."
        let savedToPhotos = try await PhotosSaver.add(videos: newlyImported)
        refreshLibrary()
        progress = 1
        isSyncInFlight = false
        return SyncResult(
            catalogueCount: clips.count,
            importedCount: newlyImported.count,
            savedToPhotos: savedToPhotos
        )
    }

    private func finishSuccessfulSync(_ result: SyncResult) {
        lastSyncDate = Date()
        progress = 1
        importPhase = .complete
        if result.importedCount > 0 {
            status = result.importedCount == 1 ? "1 new video imported" : "\(result.importedCount) new videos imported"
            detail = "\(result.savedToPhotos) added to Photos. Watching for new videos while Malibu stays open."
        } else if result.catalogueCount == 0 {
            status = "Connected"
            detail = "No videos are on the glasses yet. Malibu is watching for new recordings."
        } else {
            status = "Connected"
            detail = "Everything is up to date. New videos will import automatically."
        }
    }

    private func scheduleLiveSync() {
        liveSyncTask?.cancel()
        guard isForeground, isPaired, isSessionConnected else { return }
        liveSyncTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    try Task.checkCancellation()
                    guard self.isForeground,
                          self.isSessionConnected,
                          !self.isWorking,
                          !self.isSyncInFlight,
                          let media = self.activeMedia
                    else { continue }

                    let result = try await self.syncClips(using: media, passive: true)
                    self.finishSuccessfulSync(result)
                    self.isWorking = false

                    if let ble = self.activeBLE, ble.isConnected,
                       self.deviceInfo.lastUpdated.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                        self.isRefreshingDeviceInfo = true
                        self.deviceInfo = await ble.readDeviceInfo(existing: self.deviceInfo)
                        self.isRefreshingDeviceInfo = false
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self.lastError = error.localizedDescription
                    self.status = "Reconnecting…"
                    self.detail = "The glasses connection dropped. Malibu is rebuilding it automatically."
                    self.isWorking = false
                    self.isSyncInFlight = false
                    await self.endSession()
                    guard self.isForeground else { return }
                    self.liveSyncTask = nil
                    self.importVideos()
                    return
                }
            }
        }
    }

    private func endSession() async {
        let media = activeMedia
        let ble = activeBLE
        activeMedia = nil
        activeBLE = nil
        isSessionConnected = false
        isRefreshingDeviceInfo = false
        media?.close()
        await ble?.stopAccessPoint()
        ble?.disconnect()
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
