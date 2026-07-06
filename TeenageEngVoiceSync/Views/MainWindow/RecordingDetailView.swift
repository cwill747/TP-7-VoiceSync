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
    @Environment(\.modelContext) private var modelContext
    @State private var isRetranscribing = false
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    @State private var isSendingToNotes = false
    @State private var notesStatus: NotesStatus?

    enum NotesStatus {
        case success
        case error(String)
    }

    /// Local file to play, if any: prefers the device cache (`localPath`) but
    /// falls back to a recovered local copy (`localCopyPath`).
    private var localAudioURL: URL? {
        let fm = FileManager.default
        if !recording.localPath.isEmpty, fm.fileExists(atPath: recording.localPath) {
            return URL(fileURLWithPath: recording.localPath)
        }
        if let copy = recording.localCopyPath, fm.fileExists(atPath: copy) {
            return URL(fileURLWithPath: copy)
        }
        return nil
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

                    if SyncService.hasPendingRemoteWork(recording) {
                        Label("Waiting for connection to finish uploading", systemImage: "icloud.slash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.top, 2)
                    }
                }

                Divider()

                // Audio player — only when the audio exists locally. Recovered
                // rows keep the file in localCopyPath (localPath may be empty), and
                // S3/Notion-only rows have no local file to play at all.
                if let audioURL = localAudioURL {
                    AudioPlayerView(url: audioURL)

                    Divider()
                }

                // Transcription
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Transcription")
                            .font(.headline)

                        Spacer()

                        // Only offer retranscription when there's audio to work
                        // from — Notion-only recoveries have no audio source, and
                        // retranscribing would just fail and hide the transcript.
                        if recording.isTranscribed, SyncService.hasAudioSource(recording) {
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
            HStack {
                Text("Not transcribed")
                    .foregroundStyle(.secondary)
                    .italic()

                Spacer()

                // Recordings restored by startup recovery have audio (in S3 or a
                // local copy) but no transcription yet — let the user kick it off.
                if SyncService.hasAudioSource(recording) {
                    Button {
                        retranscribe()
                    } label: {
                        if isRetranscribing {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Label("Transcribe", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isRetranscribing)
                }
            }

        case .pending, .processing:
            HStack {
                ProgressView()
                Text("Transcribing...")
                    .foregroundStyle(.secondary)
            }

        case .completed:
            if let _ = recording.transcriptionText {
                VStack(alignment: .leading, spacing: 8) {
                    // Show diarized correction view if segment data is available
                    if let segData = recording.speakerSegmentsData,
                       let segments = try? JSONDecoder().decode([StoredSpeakerSegment].self, from: segData),
                       !segments.isEmpty {
                        DiarizedTranscriptView(
                            recording: recording,
                            segments: segments
                        )
                    } else {
                        PlainTranscriptView(
                            text: recording.transcriptionText ?? "",
                            language: recording.transcriptionLanguage
                        )
                    }

                    HStack {
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

// MARK: - Plain transcript (no diarization)

struct PlainTranscriptView: View {
    let text: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let lang = language {
                Text("Language: \(lang)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Diarized transcript with speaker correction

struct DiarizedTranscriptView: View {
    let recording: Recording
    let segments: [StoredSpeakerSegment]

    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Query(sort: \Person.createdAt) private var persons: [Person]

    @State private var localSegments: [StoredSpeakerSegment]

    init(recording: Recording, segments: [StoredSpeakerSegment]) {
        self.recording = recording
        self.segments = segments
        self._localSegments = State(initialValue: segments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Speakers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !persons.isEmpty {
                    Text("Tap a label to reassign")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 6)

            ForEach($localSegments) { $segment in
                SpeakerSegmentView(
                    segment: $segment,
                    persons: persons,
                    onReassign: { personId, personName in
                        reassign(segment: &segment, personId: personId, personName: personName)
                    },
                    onNewPerson: { name in
                        createAndAssign(segment: &segment, name: name)
                    }
                )
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: recording.persistentModelID) { _, _ in
            // Reset local state when the selected recording changes so stale
            // segments from the previous recording are never shown or persisted.
            if let fresh = recording.speakerSegmentsData,
               let decoded = try? JSONDecoder().decode([StoredSpeakerSegment].self, from: fresh) {
                localSegments = decoded
            } else {
                localSegments = []
            }
        }
    }

    private func reassign(segment: inout StoredSpeakerSegment, personId: String, personName: String) {
        segment.assignedPersonName = personName
        segment.assignedPersonId = personId

        // Add this segment's audio as a VoiceSample for the chosen Person
        if !segment.embedding.isEmpty, let person = persons.first(where: { $0.id == personId }) {
            let sample = VoiceSample(
                recordingFilename: recording.filename,
                startTime: segment.startTime,
                endTime: segment.endTime,
                embedding: segment.embedding
            )
            sample.person = person
            modelContext.insert(sample)
            person.recomputeEmbedding()
            try? modelContext.save()
            Task { await appState.syncService?.refreshKnownSpeakers() }
        }

        persistSegments()
    }

    private func createAndAssign(segment: inout StoredSpeakerSegment, name: String) {
        let person = Person(name: name)
        modelContext.insert(person)

        if !segment.embedding.isEmpty {
            let sample = VoiceSample(
                recordingFilename: recording.filename,
                startTime: segment.startTime,
                endTime: segment.endTime,
                embedding: segment.embedding
            )
            sample.person = person
            modelContext.insert(sample)
            person.recomputeEmbedding()
        }

        try? modelContext.save()

        segment.assignedPersonName = person.name
        segment.assignedPersonId = person.id
        persistSegments()
        Task { await appState.syncService?.refreshKnownSpeakers() }
    }

    private func persistSegments() {
        recording.speakerSegmentsData = try? JSONEncoder().encode(localSegments)
        recording.transcriptionText = localSegments
            .map { seg in
                let label = seg.assignedPersonName ?? seg.rawSpeakerId
                return "\(label): \(seg.text)"
            }
            .joined(separator: "\n\n")
        recording.updatedAt = Date()
        try? modelContext.save()
    }
}

struct SpeakerSegmentView: View {
    @Binding var segment: StoredSpeakerSegment
    let persons: [Person]
    let onReassign: (String, String) -> Void
    let onNewPerson: (String) -> Void

    @State private var showNewPersonPrompt = false
    @State private var newPersonName = ""

    private var displayLabel: String {
        segment.assignedPersonName ?? segment.rawSpeakerId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Menu {
                    if !persons.isEmpty {
                        Section("Assign to person") {
                            ForEach(persons) { person in
                                Button(person.name) {
                                    onReassign(person.id, person.name)
                                }
                            }
                        }
                        Divider()
                    }
                    Button("New person…") {
                        showNewPersonPrompt = true
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(displayLabel)
                            .font(.subheadline.bold())
                            .foregroundStyle(segment.assignedPersonName != nil ? .primary : .secondary)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Text(":")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
            }

            Text(segment.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider().padding(.top, 8)
        }
        .sheet(isPresented: $showNewPersonPrompt) {
            NewPersonPrompt(
                isPresented: $showNewPersonPrompt,
                initialName: newPersonName,
                onConfirm: { name in
                    onNewPerson(name)
                }
            )
        }
    }
}

struct NewPersonPrompt: View {
    @Binding var isPresented: Bool
    let initialName: String
    let onConfirm: (String) -> Void

    @State private var name: String

    init(isPresented: Binding<Bool>, initialName: String, onConfirm: @escaping (String) -> Void) {
        self._isPresented = isPresented
        self.initialName = initialName
        self.onConfirm = onConfirm
        self._name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("New Person")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Add") {
                    onConfirm(name.trimmingCharacters(in: .whitespaces))
                    isPresented = false
                }
                .keyboardShortcut(.return)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 300)
    }
}

// MARK: - Audio player

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
    .modelContainer(for: [Recording.self, Person.self, VoiceSample.self], inMemory: true)
}
