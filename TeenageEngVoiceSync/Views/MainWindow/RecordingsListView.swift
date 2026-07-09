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
    @Binding var selectedRecording: Recording?
    @Binding var selectedRecordings: Set<Recording>

    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false

    var body: some View {
        List(recordings, selection: $selectedRecordings) { recording in
            RecordingRow(recording: recording)
                .tag(recording)
        }
        .listStyle(.sidebar)
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
                ContentUnavailableView(
                    "No Recordings",
                    systemImage: "waveform.slash",
                    description: Text("Connect your TP-7 to sync recordings.")
                )
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(recording.displayTitle)
                    .font(.body)
                    .lineLimit(1)

                Spacer()

                statusBadge
            }

            HStack(spacing: 12) {
                Label(recording.formattedDuration, systemImage: "clock")
                Label(recording.formattedFileSize, systemImage: "doc")

                if let date = recording.recordedAt as Date? {
                    Label(date.formatted(.dateTime.month().day()), systemImage: "calendar")
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)

            if recording.isTranscribed, let text = recording.transcriptionText {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if recording.transcriptionStatus == .processing {
            Image(systemName: "text.bubble")
                .foregroundStyle(.orange)
                .font(.caption)
                .symbolEffect(.pulse, options: .repeating)
                .help("Transcribing")
        } else if recording.transcriptionStatus == .pending {
            Image(systemName: "clock")
                .foregroundStyle(.orange)
                .font(.caption)
                .symbolEffect(.pulse, options: .repeating)
                .help("Waiting to transcribe")
        } else if let step = SyncService.remainingRemoteSteps(for: recording).first {
            Image(systemName: step.systemImage)
                .foregroundStyle(.orange)
                .font(.caption)
                .help(step.shortStatus)
        } else if recording.isTranscribed {
            Image(systemName: "text.bubble.fill")
                .foregroundStyle(.green)
                .font(.caption)
        } else if recording.isUploaded {
            Image(systemName: "checkmark.icloud.fill")
                .foregroundStyle(.blue)
                .font(.caption)
        }
    }
}

#Preview {
    RecordingsListView(
        recordings: [],
        selectedRecording: .constant(nil),
        selectedRecordings: .constant([])
    )
    .environment(AppState())
    .modelContainer(for: Recording.self, inMemory: true)
}
