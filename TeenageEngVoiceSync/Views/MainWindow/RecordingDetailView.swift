//
//  RecordingDetailView.swift
//  TeenageEngVoiceSync
//
//  Detail view for a selected recording.
//

import SwiftUI
import os
import SwiftData
import AVFoundation

struct RecordingDetailView: View {
    let recording: Recording
    @Binding var selectedRecording: Recording?
    @Environment(AppState.self) private var appState
    @State private var isRetranscribing = false
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    @State private var isSendingToNotes = false
    @State private var notesStatus: NotesStatus?

    enum NotesStatus {
        case success
        case error(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text(recording.filename)
                        .font(.title)
                        .fontDesign(.monospaced)

                    HStack(spacing: 16) {
                        Label(recording.formattedDuration, systemImage: "clock")
                        Label(recording.formattedFileSize, systemImage: "doc")
                        if let sampleRate = recording.sampleRate {
                            Label("\(sampleRate / 1000)kHz", systemImage: "waveform")
                        }
                    }
                    .foregroundStyle(.secondary)
                }

                Divider()

                // Audio player
                AudioPlayerView(url: URL(fileURLWithPath: recording.localPath))

                Divider()

                // Transcription
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Transcription")
                            .font(.headline)

                        Spacer()

                        if recording.isTranscribed {
                            Button {
                                retranscribe()
                            } label: {
                                Label("Retranscribe", systemImage: "arrow.clockwise")
                            }
                            .disabled(isRetranscribing)
                        }
                    }

                    transcriptionContent
                }

                Divider()

                // Metadata
                VStack(alignment: .leading, spacing: 8) {
                    Text("Details")
                        .font(.headline)

                    Grid(alignment: .leading, verticalSpacing: 8) {
                        GridRow {
                            Text("Recorded")
                                .foregroundStyle(.secondary)
                            Text(recording.recordedAt.formatted(.dateTime))
                        }

                        if let serial = recording.deviceSerial {
                            GridRow {
                                Text("Device")
                                    .foregroundStyle(.secondary)
                                Text(serial)
                                    .fontDesign(.monospaced)
                            }
                        }

                        if let hash = recording.fileHash {
                            GridRow {
                                Text("SHA256")
                                    .foregroundStyle(.secondary)
                                Text(hash.prefix(16) + "...")
                                    .fontDesign(.monospaced)
                                    .textSelection(.enabled)
                            }
                        }

                        if let s3Key = recording.s3Key {
                            GridRow {
                                Text("S3 Key")
                                    .foregroundStyle(.secondary)
                                Text(s3Key)
                                    .fontDesign(.monospaced)
                                    .textSelection(.enabled)
                            }
                        }

                        if let uploadedAt = recording.s3UploadedAt {
                            GridRow {
                                Text("Uploaded")
                                    .foregroundStyle(.secondary)
                                Text(uploadedAt.formatted(.dateTime))
                            }
                        }
                    }
                    .font(.callout)
                }

                Divider()

                // Delete button
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        if isDeleting {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Label("Delete Recording", systemImage: "trash")
                        }
                    }
                    .disabled(isDeleting)
                }

                Spacer()
            }
            .padding(24)
        }
        .frame(minWidth: 400)
        .confirmationDialog("Delete Recording?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteRecording()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will delete the recording from S3 and mark it as deleted. The file may remain on your TP-7 device if it couldn't be removed.")
        }
    }

    @ViewBuilder
    private var transcriptionContent: some View {
        switch recording.transcriptionStatus {
        case .none:
            Text("Not transcribed")
                .foregroundStyle(.secondary)
                .italic()

        case .pending, .processing:
            HStack {
                ProgressView()
                Text("Transcribing...")
                    .foregroundStyle(.secondary)
            }

        case .completed:
            if let text = recording.transcriptionText {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text)
                        .textSelection(.enabled)

                    HStack {
                        if let language = recording.transcriptionLanguage {
                            Text("Language: \(language)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            sendToNotes()
                        } label: {
                            if isSendingToNotes {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Label("Send to Notes", systemImage: "note.text")
                            }
                        }
                        .disabled(isSendingToNotes)
                    }

                    if let status = notesStatus {
                        switch status {
                        case .success:
                            Label("Note created", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        case .error(let message):
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                }
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

        case .failed:
            HStack {
                Label("Transcription failed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)

                Spacer()

                Button {
                    retranscribe()
                } label: {
                    if isRetranscribing {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRetranscribing)
            }
        }
    }

    private func retranscribe() {
        guard let syncService = appState.syncService else { return }
        isRetranscribing = true

        Task {
            await syncService.retranscribe(recording)
            await MainActor.run {
                isRetranscribing = false
            }
        }
    }

    private func sendToNotes() {
        guard let syncService = appState.syncService else { return }
        isSendingToNotes = true
        notesStatus = nil

        Task {
            do {
                try await syncService.sendToAppleNotes(recording)
                await MainActor.run {
                    notesStatus = .success
                    isSendingToNotes = false
                }
            } catch {
                await MainActor.run {
                    notesStatus = .error(error.localizedDescription)
                    isSendingToNotes = false
                }
            }
        }
    }

    private func deleteRecording() {
        guard let syncService = appState.syncService else { return }
        isDeleting = true

        Task {
            await syncService.deleteRecording(recording)
            await MainActor.run {
                isDeleting = false
                selectedRecording = nil
            }
        }
    }
}

struct AudioPlayerView: View {
    let url: URL
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 12) {
            // Progress bar
            Slider(value: $currentTime, in: 0...max(duration, 1)) { editing in
                if !editing {
                    player?.currentTime = currentTime
                }
            }

            // Controls
            HStack {
                Text(formatTime(currentTime))
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                .buttonStyle(.plain)

                Spacer()

                Text(formatTime(duration))
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            stopPlayback()
        }
    }

    private func setupPlayer() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            duration = player?.duration ?? 0
        } catch {
            AppLogger.app.error("Failed to setup audio player: \(String(describing: error), privacy: .public)")
        }
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        player?.play()
        isPlaying = true

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            currentTime = player?.currentTime ?? 0
            if !(player?.isPlaying ?? false) {
                stopPlayback()
            }
        }
    }

    private func stopPlayback() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    @Previewable @State var selected: Recording? = nil
    RecordingDetailView(
        recording: Recording(
            filename: "track_001.wav",
            localPath: "/path/to/file.wav",
            fileSize: 1024 * 1024 * 5,
            recordedAt: Date()
        ),
        selectedRecording: $selected
    )
    .modelContainer(for: Recording.self, inMemory: true)
}
