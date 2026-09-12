// Malibu is licensed under CPAL-1.0.
// Copyright (c) 2026 Leon M'laiel. See LICENSE for required attribution.

import Foundation
import Network

private final class CompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}

struct SpectaclesClip: Identifiable {
    let contentID: String
    let files: [Int: Int]
    var id: String { contentID }

    var video: (type: Int, size: Int)? {
        if let size = files[4], size > 0 { return (4, size) }
        if let size = files[3], size > 0 { return (3, size) }
        return nil
    }

    var thumbnail: (type: Int, size: Int)? {
        guard let size = files[1], size > 0 else { return nil }
        return (1, size)
    }
}

final class AMBAClient {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "Malibu.media")
    private let encryptionKey: Data
    private var crypto: PacketCrypto?

    init(encryptionKey: Data) {
        self.encryptionKey = encryptionKey
    }

    func connectAndSetupWithRetry(maxAttempts: Int = 4) async throws {
        var lastError: Error = MalibuError.networkFailure("the glasses did not answer over Wi-Fi")
        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            resetConnection()
            do {
                try await connectOnce()
                try await setupEncryption()
                return
            } catch {
                lastError = Self.transportError(error, action: "connecting to the glasses")
                resetConnection()
                if attempt < maxAttempts - 1 {
                    try await Task.sleep(nanoseconds: 750_000_000)
                }
            }
        }
        throw lastError
    }

    func setupEncryption() async throws {
        let clientNonce = try Data.secureRandom(count: 16)
        let nonceMessage = Protobuf.bytes(1, clientNonce)
        var request = Protobuf.int(1, 0)
        request.append(Protobuf.bytes(2, nonceMessage))
        try await sendFrame(type: 2, body: request)
        let response = try await receiveFrame()
        guard response.type == 2 else {
            throw MalibuError.protocolFailure("unexpected media setup frame \(response.type)")
        }
        guard try Protobuf.firstInt(response.body, field: 2) == 0,
              let wrappedNonce = try Protobuf.firstBytes(response.body, field: 1),
              let peerNonce = try Protobuf.firstBytes(wrappedNonce, field: 1),
              peerNonce.count >= 16 else {
            throw MalibuError.protocolFailure("invalid media security response")
        }
        crypto = try PacketCrypto(
            key: encryptionKey,
            transmitNonce: clientNonce,
            receiveNonce: peerNonce.prefix(16)
        )
    }

    func listClips() async throws -> [SpectaclesClip] {
        var request = Protobuf.int(1, 1)
        request.append(Protobuf.int(2, 2))
        request.append(Protobuf.bytes(5, Protobuf.int(1, 0)))
        let response = try await exchange(request)
        if let status = try Protobuf.firstInt(response, field: 2), status != 0 {
            throw MalibuError.protocolFailure("media list failed with status \(status)")
        }
        guard let media = try Protobuf.firstBytes(response, field: 5) else {
            throw MalibuError.protocolFailure("media list contained no clips")
        }
        return try Protobuf.allBytes(media, field: 1).map { item in
            let content = try Protobuf.firstBytes(item, field: 1) ?? Data()
            let contentID = String(data: content, encoding: .utf8) ?? "clip"
            var files: [Int: Int] = [:]
            for file in try Protobuf.allBytes(item, field: 2) {
                let type = Int(try Protobuf.firstInt(file, field: 1) ?? 0)
                let size = Int(try Protobuf.firstInt(file, field: 2) ?? 0)
                files[type] = size
            }
            return SpectaclesClip(contentID: contentID, files: files)
        }
    }

    func listClipsWithRetry(maxAttempts: Int = 2) async throws -> [SpectaclesClip] {
        var lastError: Error = MalibuError.networkFailure("the glasses did not return their video list")
        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            do {
                return try await listClips()
            } catch {
                lastError = Self.transportError(error, action: "reading the video list")
                guard attempt < maxAttempts - 1 else { break }
                try await connectAndSetupWithRetry(maxAttempts: 2)
            }
        }
        throw lastError
    }

    func download(
        clip: SpectaclesClip,
        to destination: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard let video = clip.video else { return }
        let temporary = destination.appendingPathExtension("partial")
        let storedSize = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if storedSize < 0 || storedSize > video.size {
            try? FileManager.default.removeItem(at: temporary)
        }
        if !FileManager.default.fileExists(atPath: temporary.path) {
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw MalibuError.libraryFailure("could not create the partial video file")
            }
        }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }

        var offset = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        try handle.seek(toOffset: UInt64(offset))
        progress(min(1, Double(offset) / Double(video.size)))
        while offset < video.size {
            try Task.checkCancellation()
            let requested = min(1024 * 1024, video.size - offset)
            var block: Data?
            var lastError: Error = MalibuError.networkFailure("the glasses did not return video data")
            for attempt in 0..<2 {
                do {
                    block = try await downloadBlock(
                        clip: clip,
                        fileType: video.type,
                        offset: offset,
                        requested: requested
                    )
                    break
                } catch {
                    lastError = Self.transportError(error, action: "downloading byte \(offset)")
                    guard attempt < 1 else { break }
                    try await connectAndSetupWithRetry(maxAttempts: 2)
                }
            }
            guard let block else { throw lastError }
            guard block.count <= requested, block.count <= video.size - offset else {
                throw MalibuError.protocolFailure("the glasses returned too much video data at byte \(offset)")
            }
            try handle.write(contentsOf: block)
            offset += block.count
            progress(min(1, Double(offset) / Double(video.size)))
        }
        try handle.synchronize()
        try handle.close()
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        guard (attributes[.size] as? NSNumber)?.intValue == video.size else {
            throw MalibuError.protocolFailure("downloaded file size did not match the glasses")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    func thumbnailData(for clip: SpectaclesClip) async -> Data? {
        guard let thumbnail = clip.thumbnail, thumbnail.size <= 2 * 1024 * 1024 else {
            return nil
        }

        var result = Data()
        var offset = 0
        while offset < thumbnail.size {
            do {
                let requested = min(256 * 1024, thumbnail.size - offset)
                let block = try await downloadBlock(
                    clip: clip,
                    fileType: thumbnail.type,
                    offset: offset,
                    requested: requested
                )
                guard block.count <= requested, block.count <= thumbnail.size - offset else {
                    return nil
                }
                result.append(block)
                offset += block.count
            } catch {
                return nil
            }
        }
        return result
    }

    func close() {
        resetConnection()
    }

    private func connectOnce() async throws {
        guard let port = NWEndpoint.Port(rawValue: DeviceProfile.mediaPort) else {
            throw MalibuError.networkFailure("invalid media port")
        }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        let candidate = NWConnection(
            host: NWEndpoint.Host(DeviceProfile.mediaHost),
            port: port,
            using: parameters
        )
        connection = candidate
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = CompletionGate()
            candidate.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.claim() { continuation.resume() }
                case .failed(let error):
                    if gate.claim() {
                        continuation.resume(throwing: Self.transportError(error, action: "opening the media connection"))
                    }
                case .cancelled:
                    if gate.claim() {
                        continuation.resume(throwing: MalibuError.networkFailure("connection was cancelled"))
                    }
                default: break
                }
            }
            candidate.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) {
                guard gate.claim() else { return }
                candidate.cancel()
                continuation.resume(throwing: MalibuError.timeout("connecting to the glasses’ media service"))
            }
        }
    }

    private func exchange(_ request: Data) async throws -> Data {
        guard let crypto else { throw MalibuError.protocolFailure("media encryption is not initialized") }
        try await sendFrame(type: 1, body: try crypto.encrypt(request))
        let response = try await receiveFrame()
        switch response.type {
        case 1: return try crypto.decrypt(response.body)
        case 0: return response.body
        default: throw MalibuError.protocolFailure("unexpected media frame \(response.type)")
        }
    }

    private func sendFrame(type: UInt8, body: Data) async throws {
        guard body.count < 1 << 28 else { throw MalibuError.protocolFailure("media message is too large") }
        var frame = Data()
        frame.appendUInt32BE(UInt32(type) << 28 | UInt32(body.count))
        frame.append(body)
        try await send(frame)
    }

    private func receiveFrame() async throws -> (type: UInt8, body: Data) {
        let header = try await receiveExactly(4)
        let value = try header.uint32BE()
        let type = UInt8(value >> 28)
        let size = Int(value & 0x0FFF_FFFF)
        guard size <= 8 * 1024 * 1024 else {
            throw MalibuError.protocolFailure("implausible media frame size \(size)")
        }
        return (type, try await receiveExactly(size))
    }

    private func send(_ data: Data) async throws {
        guard let connection else { throw MalibuError.networkFailure("media socket is not connected") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = CompletionGate()
            connection.send(content: data, completion: .contentProcessed { error in
                guard gate.claim() else { return }
                if let error {
                    continuation.resume(throwing: Self.transportError(error, action: "sending a media request"))
                } else {
                    continuation.resume()
                }
            })
            queue.asyncAfter(deadline: .now() + 8) {
                guard gate.claim() else { return }
                connection.cancel()
                continuation.resume(throwing: MalibuError.timeout("sending a request to the glasses"))
            }
        }
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let part = try await receive(maximum: remaining)
            guard !part.isEmpty else { throw MalibuError.networkFailure("the glasses closed the media socket") }
            result.append(part)
        }
        return result
    }

    private func receive(maximum: Int) async throws -> Data {
        guard let connection else { throw MalibuError.networkFailure("media socket is not connected") }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let gate = CompletionGate()
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, complete, error in
                guard gate.claim() else { return }
                if let error {
                    continuation.resume(throwing: Self.transportError(error, action: "receiving video data"))
                } else if let data {
                    continuation.resume(returning: data)
                } else if complete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(throwing: MalibuError.networkFailure("the glasses returned an empty response"))
                }
            }
            queue.asyncAfter(deadline: .now() + 15) {
                guard gate.claim() else { return }
                connection.cancel()
                continuation.resume(throwing: MalibuError.timeout("waiting for video data from the glasses"))
            }
        }
    }

    private func downloadBlock(
        clip: SpectaclesClip,
        fileType: Int,
        offset: Int,
        requested: Int
    ) async throws -> Data {
        var range = Protobuf.int(1, UInt64(offset))
        range.append(Protobuf.int(2, UInt64(requested)))
        var file = Protobuf.string(1, clip.contentID)
        file.append(Protobuf.int(2, UInt64(fileType)))
        file.append(Protobuf.bytes(3, range))
        var media = Protobuf.int(1, 1)
        media.append(Protobuf.bytes(2, file))
        var request = Protobuf.int(1, 0)
        request.append(Protobuf.int(2, 2))
        request.append(Protobuf.bytes(5, media))

        let response = try await exchange(request)
        if let status = try Protobuf.firstInt(response, field: 2), status != 0 {
            throw MalibuError.protocolFailure("clip download failed with status \(status)")
        }
        guard let mediaResponse = try Protobuf.firstBytes(response, field: 5),
              let mediaData = try Protobuf.firstBytes(mediaResponse, field: 2),
              let block = try Protobuf.firstBytes(mediaData, field: 5),
              !block.isEmpty else {
            throw MalibuError.protocolFailure("empty clip block at byte \(offset)")
        }
        return block
    }

    private func resetConnection() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        crypto = nil
    }

    private static func transportError(_ error: Error, action: String) -> Error {
        if let malibuError = error as? MalibuError {
            return malibuError
        }
        if let networkError = error as? NWError,
           case .posix(let code) = networkError,
           code == .ETIMEDOUT {
            return MalibuError.networkFailure("the glasses stopped responding while \(action)")
        }
        return MalibuError.networkFailure("\(action) failed: \(error.localizedDescription)")
    }
}
