//
//  RecordingsListView.swift
//  TeenageEngVoiceSync
//
//  List of recordings in the sidebar.
//

import SwiftUI
import SwiftData

struct RecordingsListView: View {
    let recordings: [Recording]
    @Binding var selectedRecording: Recording?

    var body: some View {
        List(recordings, selection: $selectedRecording) { recording in
            RecordingRow(recording: recording)
                .tag(recording)
        }
        .listStyle(.sidebar)
        .overlay {
            if recordings.isEmpty {
                ContentUnavailableView(
                    "No Recordings",
                    systemImage: "waveform.slash",
                    description: Text("Connect your TP-7 to sync recordings.")
                )
            }
        }
    }
}

struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(recording.filename)
                    .font(.system(.body, design: .monospaced))
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
                .help("Transcribing")
        } else if recording.transcriptionStatus == .pending {
            Image(systemName: "clock")
                .foregroundStyle(.orange)
                .font(.caption)
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
        selectedRecording: .constant(nil)
    )
    .modelContainer(for: Recording.self, inMemory: true)
}
