// Malibu is licensed under CPAL-1.0.
// Copyright (c) 2026 Leon M'laiel. See LICENSE for required attribution.

import AVKit
import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var controller: SpectaclesController
    @State private var sortOrder = VideoSortOrder.newest
    @State private var renameTarget: VideoActionTarget?
    @State private var deleteTarget: VideoActionTarget?
    @State private var showingDeleteConfirmation = false
    @State private var showingDeleteAllConfirmation = false
    @State private var libraryError = ""
    @State private var showingLibraryError = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.03, green: 0.04, blue: 0.08), Color(red: 0.03, green: 0.11, blue: 0.16)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 22) {
                        if !controller.isPaired || controller.isPairing {
                            instructionCard
                        }
                        importCard
                        if controller.needsWiFiJoin { wifiCard }
                        library
                        Link("Created by Leon M'laiel (Cynostial)", destination: URL(string: "https://github.com/Cynostial")!)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Malibu")
            .navigationBarTitleDisplayMode(.large)
            .task {
                controller.startAutomaticImportIfReady()
            }
            .sheet(item: $renameTarget) { target in
                RenameVideoSheet(url: target.url) { newName in
                    try controller.renameVideo(target.url, to: newName)
                }
            }
            .confirmationDialog(
                "Delete this video?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete from Malibu", role: .destructive) {
                    guard let target = deleteTarget else { return }
                    performLibraryAction { try controller.deleteVideo(target.url) }
                    deleteTarget = nil
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: {
                Text("This deletes Malibu's local copy. Copies in Photos stay there. The video may be imported again if it is still on the glasses.")
            }
            .confirmationDialog(
                "Delete all imported videos?",
                isPresented: $showingDeleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete all from Malibu", role: .destructive) {
                    performLibraryAction { try controller.deleteAllVideos() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes every local Malibu copy. Copies in Photos stay there. Videos still on the glasses may be imported again.")
            }
            .alert("Video library error", isPresented: $showingLibraryError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(libraryError)
            }
        }
    }

    private var instructionCard: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Color.cyan)
                Text("1")
                    .font(.headline.bold())
                    .foregroundStyle(.black)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text("Hold the button for 7 seconds")
                    .font(.headline)
                Text("Hold their only button continuously for 7 seconds, then release it. Malibu waits up to two minutes for pairing mode.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var importCard: some View {
        VStack(spacing: 16) {
            ImportPortal(
                phase: controller.importPhase,
                progress: controller.clipProgress,
                thumbnail: controller.currentImportThumbnail,
                isActive: controller.isWorking
            )

            VStack(spacing: 5) {
                Text(controller.status)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                Text(controller.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            if controller.totalClips > 0 && controller.isWorking {
                HStack {
                    Text("Video \(controller.currentClip) of \(controller.totalClips)")
                    Spacer()
                    Text(controller.progress.formatted(.percent.precision(.fractionLength(0))))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            if controller.isWorking {
                Button(role: .cancel) {
                    controller.cancelOperation()
                } label: {
                    Label("Stop", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            } else {
                Button {
                    if !controller.isPaired {
                        controller.pairSpectacles()
                    } else {
                        controller.importVideos()
                    }
                } label: {
                    Label(
                        primaryButtonTitle,
                        systemImage: controller.isPaired ? "arrow.clockwise" : "link"
                    )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .foregroundStyle(.black)
            }

            if controller.isPaired && !controller.isWorking && !controller.needsWiFiJoin {
                Button("Pair again after a reset") {
                    controller.pairSpectacles()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var primaryButtonTitle: String {
        if !controller.isPaired { return "Pair Spectacles" }
        return controller.importPhase == .failed ? "Try again" : "Check for videos"
    }

    private var wifiCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Joining Specs Wi-Fi", systemImage: "wifi")
                .font(.headline)
            Text("iOS is connecting to the accessory network approved during setup.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.cyan.opacity(0.35)))
    }

    @ViewBuilder
    private var library: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Imported videos")
                        .font(.title3.bold())
                    if !controller.importedVideos.isEmpty {
                        Text(librarySummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !controller.importedVideos.isEmpty {
                    Menu {
                        Picker("Sort videos", selection: $sortOrder) {
                            ForEach(VideoSortOrder.allCases) { order in
                                Label(order.title, systemImage: order.symbol).tag(order)
                            }
                        }
                        Button {
                            controller.refreshLibrary()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        Divider()
                        Button(role: .destructive) {
                            showingDeleteAllConfirmation = true
                        } label: {
                            Label("Delete all", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Video library options")
                }
            }

            if controller.importedVideos.isEmpty {
                Text("Videos appear here after the first import and remain available in Photos and Files.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(sortedVideos, id: \.self) { url in
                        videoRow(url)
                    }
                }
            }
        }
    }

    private func videoRow(_ url: URL) -> some View {
        HStack(spacing: 12) {
            NavigationLink {
                VideoScreen(url: url)
            } label: {
                HStack(spacing: 12) {
                    CircularVideoThumbnail(url: url)
                        .frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(url.deletingPathExtension().lastPathComponent)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(videoDetails(url))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    renameTarget = VideoActionTarget(url: url)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                ShareLink(item: url) {
                    Label("Share or save", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive) {
                    deleteTarget = VideoActionTarget(url: url)
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Options for \(url.deletingPathExtension().lastPathComponent)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            Button {
                renameTarget = VideoActionTarget(url: url)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            ShareLink(item: url) {
                Label("Share or save", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                deleteTarget = VideoActionTarget(url: url)
                showingDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var sortedVideos: [URL] {
        switch sortOrder {
        case .newest:
            return controller.importedVideos.sorted { videoDate($0) > videoDate($1) }
        case .oldest:
            return controller.importedVideos.sorted { videoDate($0) < videoDate($1) }
        case .name:
            return controller.importedVideos.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        }
    }

    private var librarySummary: String {
        let count = controller.importedVideos.count
        let bytes = controller.importedVideos.reduce(Int64(0)) { result, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return result + Int64(size)
        }
        let total = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(count) video\(count == 1 ? "" : "s"), \(total)"
    }

    private func videoDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        return values?.contentModificationDate ?? values?.creationDate ?? .distantPast
    }

    private func videoDetails(_ url: URL) -> String {
        let size = fileSize(url)
        let date = videoDate(url)
        guard date != .distantPast else { return size }
        return "\(size) · \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func performLibraryAction(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            libraryError = error.localizedDescription
            showingLibraryError = true
        }
    }

    private func fileSize(_ url: URL) -> String {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "MP4" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

private struct ImportPortal: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let phase: ImportPhase
    let progress: Double
    let thumbnail: UIImage?
    let isActive: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [color.opacity(0.22), color.opacity(0.05), .clear],
                        center: .center,
                        startRadius: 30,
                        endRadius: 105
                    )
                )
                .frame(width: 198, height: 198)

            Circle()
                .fill(Color(red: 0.025, green: 0.07, blue: 0.10))
                .frame(width: 146, height: 146)
                .overlay {
                    portalContent
                        .clipShape(Circle())
                }
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.13), lineWidth: 1)
                }
                .shadow(color: color.opacity(0.28), radius: 24)

            Circle()
                .stroke(Color.white.opacity(0.09), lineWidth: 7)
                .frame(width: 164, height: 164)

            if phase == .downloading {
                Circle()
                    .trim(from: 0, to: boundedProgress)
                    .stroke(
                        AngularGradient(
                            colors: [Color.cyan, Color.mint, Color.white, Color.cyan],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 164, height: 164)

                progressHead
            } else if isActive {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
                    Circle()
                        .trim(from: 0.03, to: 0.29)
                        .stroke(
                            AngularGradient(colors: [.clear, color.opacity(0.45), color], center: .center),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                        .rotationEffect(.degrees(spinAngle(at: timeline.date)))
                        .frame(width: 164, height: 164)
                }
            } else if phase == .complete {
                Circle()
                    .trim(from: 0, to: 1)
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .frame(width: 164, height: 164)
            }

            if phase == .downloading {
                Text(boundedProgress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
                    .offset(y: 52)
            }

            if phase == .complete {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .foregroundStyle(.black)
                    .frame(width: 30, height: 30)
                    .background(Color.green, in: Circle())
                    .overlay(Circle().stroke(Color.black.opacity(0.16), lineWidth: 1))
                    .offset(x: 59, y: 59)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 198, height: 198)
        .animation(.easeInOut(duration: 0.35), value: boundedProgress)
        .animation(.spring(response: 0.45, dampingFraction: 0.76), value: phase)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var portalContent: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 146, height: 146)
                .overlay {
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.16), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 46)
                    .rotationEffect(.degrees(18))
                    .offset(x: -96 + 192 * boundedProgress)
                    .blendMode(.screen)
                }
                .overlay {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.28)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                }
        } else {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.14), lineWidth: 1)
                    .frame(width: 104, height: 104)
                Circle()
                    .stroke(color.opacity(0.10), lineWidth: 1)
                    .frame(width: 72, height: 72)
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(color)
            }
        }
    }

    private var progressHead: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 9, height: 9)
            .shadow(color: Color.cyan, radius: 7)
            .offset(y: -82)
            .rotationEffect(.degrees(360 * boundedProgress))
    }

    private var boundedProgress: Double {
        min(1, max(0, progress))
    }

    private func spinAngle(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 1.8) / 1.8 * 360
    }

    private var color: Color {
        switch phase {
        case .complete: return .green
        case .failed: return .red
        default: return .cyan
        }
    }

    private var symbol: String {
        switch phase {
        case .idle: return "circle.dotted"
        case .pairing: return "link"
        case .locating: return "dot.radiowaves.left.and.right"
        case .authenticating: return "lock.fill"
        case .switchingWiFi: return "wifi"
        case .reading: return "list.bullet"
        case .downloading: return "arrow.down"
        case .saving: return "square.and.arrow.down"
        case .complete: return "checkmark"
        case .failed: return "exclamationmark"
        }
    }
}

private struct CircularVideoThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.cyan.opacity(0.12))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }

            Circle()
                .stroke(Color.white.opacity(0.22), lineWidth: 1)

            Image(systemName: "play.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 4)
        }
        .clipShape(Circle())
        .task(id: url) {
            image = await makeThumbnail()
        }
        .accessibilityHidden(true)
    }

    private func makeThumbnail() async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 180, height: 180)
        let time = CMTime(seconds: 0.2, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: result.image)
    }
}

private enum VideoSortOrder: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .name: return "Name"
        }
    }

    var symbol: String {
        switch self {
        case .newest: return "clock.arrow.circlepath"
        case .oldest: return "clock"
        case .name: return "textformat"
        }
    }
}

private struct VideoActionTarget: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct RenameVideoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let rename: (String) throws -> Void
    @State private var name: String
    @State private var errorMessage = ""
    @State private var showingError = false

    init(url: URL, rename: @escaping (String) throws -> Void) {
        self.url = url
        self.rename = rename
        _name = State(initialValue: url.deletingPathExtension().lastPathComponent)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Video name") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled()
                }
                Section {
                    Text("The MP4 extension is added automatically. Copies already saved in Photos keep their existing name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Rename video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try rename(name)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                            showingError = true
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Could not rename video", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
        .presentationDetents([.medium])
    }
}

private struct VideoScreen: View {
    let url: URL
    @State private var player: AVPlayer

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .navigationTitle(url.deletingPathExtension().lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .onAppear { player.play() }
            .onDisappear { player.pause() }
            .background(Color.black)
    }
}
