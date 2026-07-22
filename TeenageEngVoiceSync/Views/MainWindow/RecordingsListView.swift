//
//  RecordingsListView.swift
//  TeenageEngVoiceSync
//
//  List of recordings in the sidebar.
//

import SwiftUI
import SwiftData

struct RecordingsListView: View {
    @Environment(AppState.self) private var appState

    let recordings: [Recording]
    /// True when a search query is active, distinguishing "no matches" from
    /// "no recordings synced yet" in the empty state.
    var isSearching: Bool = false
    @Binding var selectedRecording: Recording?
    @Binding var selectedRecordings: Set<Recording>

    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false

    /// Live width of the list column, driving each row's responsive density.
    /// Measured on the container (an input independent of row heights) rather
    /// than per-row: a row that sized its own height from its own measured
    /// width would feed the List's self-sizing loop and crash with a layout
    /// recursion. Zero until measured.
    @State private var listWidth: CGFloat = 0

    var body: some View {
        List(recordings, selection: $selectedRecordings) { recording in
            RecordingRow(recording: recording, width: listWidth)
                .tag(recording)
        }
        .listStyle(.sidebar)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            listWidth = newWidth
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    if isDeleting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Delete Selected Recordings", systemImage: "trash")
                    }
                }
                .disabled(selectedRecordings.isEmpty || isDeleting)
                .help(deleteButtonLabel)
            }
        }
        .overlay {
            if recordings.isEmpty {
                if isSearching {
                    ContentUnavailableView.search
                } else {
                    ContentUnavailableView(
                        "No Recordings",
                        systemImage: "waveform.slash",
                        description: Text("Connect your TP-7 to sync recordings.")
                    )
                }
            }
        }
        .onChange(of: selectedRecordings) { _, selection in
            selectedRecording = selection.count == 1 ? selection.first : nil
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: $showDeleteConfirmation
        ) {
            Button(deleteButtonLabel, role: .destructive) {
                deleteSelectedRecordings()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will delete the selected recordings from S3 and mark them as deleted. Files may remain on your TP-7 device if they couldn't be removed.")
        }
    }

    private var deleteConfirmationTitle: String {
        selectedRecordings.count == 1
            ? "Delete Recording?"
            : "Delete \(selectedRecordings.count) Recordings?"
    }

    private var deleteButtonLabel: String {
        selectedRecordings.count == 1
            ? "Delete Recording"
            : "Delete \(selectedRecordings.count) Recordings"
    }

    private func deleteSelectedRecordings() {
        guard let syncService = appState.syncService else { return }

        let recordingsToDelete = selectedRecordings
        isDeleting = true

        Task {
            for recording in recordingsToDelete {
                await syncService.deleteRecording(recording)
            }
            selectedRecordings.removeAll()
            selectedRecording = nil
            isDeleting = false
        }
    }
}

struct RecordingRow: View {
    let recording: Recording

    /// Available width of the enclosing list column, supplied by the parent.
    /// Drives responsive density. Zero until the container is measured.
    var width: CGFloat = 0

    /// Below this, drop secondary metadata (file size) to keep the essentials
    /// (title, duration, date, status) readable.
    private var isNarrow: Bool { width > 0 && width < 240 }

    /// Only show a transcript preview when there's comfortable room; at narrow
    /// widths it competes with the metadata it can't fit beside.
    private var showsTranscriptPreview: Bool { width == 0 || width >= 260 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(recording.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                if let status {
                    statusBadge(status)
                }
            }

            HStack(spacing: 10) {
                Label(recording.formattedDuration, systemImage: "clock")

                if let date = recording.recordedAt as Date? {
                    Label(date.formatted(.dateTime.month().day()), systemImage: "calendar")
                }

                if !isNarrow {
                    Label(recording.formattedFileSize, systemImage: "doc")
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if showsTranscriptPreview, recording.isTranscribed, let text = recording.transcriptionText {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    /// Icon, tint, and human-readable label for the row's current sync/transcription
    /// state. Nil when the recording is purely local (no badge shown).
    private var status: RowStatus? {
        if recording.transcriptionStatus == .processing {
            return RowStatus(systemImage: "text.bubble", tint: .orange, label: "Transcribing", isAnimated: true)
        }
        if recording.transcriptionStatus == .pending {
            return RowStatus(systemImage: "clock", tint: .orange, label: "Waiting to transcribe", isAnimated: true)
        }
        if let step = SyncService.remainingRemoteSteps(for: recording).first {
            return RowStatus(systemImage: step.systemImage, tint: .orange, label: step.shortStatus)
        }
        if recording.isTranscribed {
            return RowStatus(systemImage: "text.bubble.fill", tint: .green, label: "Transcribed")
        }
        if recording.isUploaded {
            return RowStatus(systemImage: "checkmark.icloud.fill", tint: .blue, label: "Uploaded")
        }
        return nil
    }

    private func statusBadge(_ status: RowStatus) -> some View {
        Image(systemName: status.systemImage)
            .foregroundStyle(status.tint)
            .font(.caption)
            .symbolEffect(.pulse, options: .repeating, isActive: status.isAnimated)
            .help(status.label)
            .accessibilityLabel(Text("Status: \(status.label)"))
    }
}

/// A descriptor for a recording's row status badge. Keeping icon, tint, and a
/// spoken/tooltip label together ensures every state carries readable text, not
/// just a color or a tiny glyph.
private struct RowStatus {
    let systemImage: String
    let tint: Color
    let label: String
    var isAnimated: Bool = false
}

#Preview("Empty") {
    RecordingsListView(
        recordings: [],
        selectedRecording: .constant(nil),
        selectedRecordings: .constant([])
    )
    .environment(AppState())
    .modelContainer(for: Recording.self, inMemory: true)
}

#Preview("Rows") {
    List {
        ForEach(RecordingRow.previewSamples, id: \.filename) { recording in
            RecordingRow(recording: recording)
        }
    }
    .listStyle(.sidebar)
    .frame(width: 300, height: 520)
}

#Preview("Narrow") {
    List {
        ForEach(RecordingRow.previewSamples, id: \.filename) { recording in
            RecordingRow(recording: recording)
        }
    }
    .listStyle(.sidebar)
    .frame(width: 180, height: 520)
}

#Preview("Wide") {
    List {
        ForEach(RecordingRow.previewSamples, id: \.filename) { recording in
            RecordingRow(recording: recording)
        }
    }
    .listStyle(.sidebar)
    .frame(width: 460, height: 520)
}

extension RecordingRow {
    /// Sample recordings covering the tricky cases called out in TP-9: a long
    /// generated title, an untitled recording (date/time fallback), a missing
    /// transcript, and a very large file.
    static var previewSamples: [Recording] {
        func make(
            filename: String,
            title: String? = nil,
            fileSize: Int64 = 5 * 1024 * 1024,
            transcript: String? = "This is a short transcript preview of the recording.",
            status: TranscriptionStatus = .completed
        ) -> Recording {
            let recording = Recording(
                filename: filename,
                localPath: "/tmp/\(filename)",
                fileSize: fileSize,
                recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            recording.duration = 372
            recording.llmTitle = title
            recording.transcriptionText = transcript
            recording.transcriptionStatus = status
            return recording
        }

        return [
            make(
                filename: "0001.wav",
                title: "Weekly planning sync with the whole product and design team about Q3",
                transcript: "We covered the roadmap, upcoming launches, and open design questions."
            ),
            make(filename: "0002.wav", title: nil),
            make(
                filename: "0003.wav",
                title: "Voice memo",
                transcript: nil,
                status: .none
            ),
            make(
                filename: "memo-0004.wav",
                title: "Field recording",
                fileSize: 2 * 1024 * 1024 * 1024,
                transcript: "Ambient capture from the afternoon session."
            ),
            make(filename: "0005.wav", title: "Uploading", status: .pending),
        ]
    }
}
