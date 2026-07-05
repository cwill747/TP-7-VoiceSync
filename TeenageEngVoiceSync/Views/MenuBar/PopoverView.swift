//
//  PopoverView.swift
//  TeenageEngVoiceSync
//
//  Menu bar popover for quick access.
//

import SwiftUI
import SwiftData

struct PopoverView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @Query(filter: #Predicate<Recording> { $0.deletedAt == nil },
           sort: \Recording.recordedAt, order: .reverse)
    private var recentRecordings: [Recording]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status header
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(appState.statusText)
                    .font(.headline)

                Spacer()

                if appState.isSyncing {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Divider()

            // Recent recordings
            if recentRecordings.isEmpty {
                Text("No recordings yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Recordings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    ForEach(recentRecordings.prefix(5)) { recording in
                        RecordingRowCompact(recording: recording)
                    }
                }
            }

            Divider()

            // Actions
            HStack {
                Button("Open Recordings") {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openSettings()
                } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .frame(width: 300)
    }

    private var statusColor: Color {
        if appState.isSyncing {
            return .orange
        } else if appState.isDeviceConnected {
            return .green
        } else {
            return .gray
        }
    }
}

struct RecordingRowCompact: View {
    let recording: Recording

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.filename)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(recording.formattedDuration)
                    Text(recording.formattedFileSize)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            statusIcon
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusIcon: some View {
        if recording.isTranscribed {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if recording.isUploaded {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.blue)
        } else {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    PopoverView()
        .environment(AppState())
        .modelContainer(for: [Recording.self, Device.self], inMemory: true)
}
