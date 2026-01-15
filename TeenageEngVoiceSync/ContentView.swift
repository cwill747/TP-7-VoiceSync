//
//  ContentView.swift
//  TeenageEngVoiceSync
//
//  Main recordings window content.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @Query(filter: #Predicate<Recording> { $0.deletedAt == nil },
           sort: \Recording.recordedAt, order: .reverse)
    private var recordings: [Recording]

    @State private var selectedRecording: Recording?
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            // Sidebar - recordings list
            RecordingsListView(
                recordings: filteredRecordings,
                selectedRecording: $selectedRecording
            )
            .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 400)
        } detail: {
            // Detail panel
            if let recording = selectedRecording {
                RecordingDetailView(recording: recording, selectedRecording: $selectedRecording)
            } else {
                ContentUnavailableView(
                    "Select a Recording",
                    systemImage: "waveform",
                    description: Text("Choose a recording from the list to view its details.")
                )
            }
        }
        .searchable(text: $searchText, prompt: "Search recordings")
        .toolbar {
            ToolbarItem(placement: .status) {
                StatusToolbarItem(appState: appState)
            }
        }
    }

    private var filteredRecordings: [Recording] {
        if searchText.isEmpty {
            return recordings
        }
        return recordings.filter { recording in
            recording.filename.localizedCaseInsensitiveContains(searchText) ||
            (recording.transcriptionText?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
}

struct StatusToolbarItem: View {
    let appState: AppState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(appState.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

#Preview {
    ContentView()
        .environment(AppState())
        .modelContainer(for: [Recording.self, Device.self], inMemory: true)
}
