//
//  ContentView.swift
//  TeenageEngVoiceSync
//
//  Main recordings window — 3-column NavigationSplitView.
//

import SwiftUI
import SwiftData

enum SidebarItem: String, CaseIterable, Identifiable {
    case recordings
    case people

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recordings: return "Recordings"
        case .people: return "People"
        }
    }

    var systemImage: String {
        switch self {
        case .recordings: return "waveform"
        case .people: return "person.2"
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var appState

    @Query(filter: #Predicate<Recording> { $0.deletedAt == nil },
           sort: \Recording.recordedAt, order: .reverse)
    private var recordings: [Recording]

    @State private var selectedSection: SidebarItem = .recordings
    @State private var selectedRecording: Recording?
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selectedSection) { item in
                Label(item.label, systemImage: item.systemImage)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 200)
            .navigationTitle("TP-7 VoiceSync")
        } content: {
            switch selectedSection {
            case .recordings:
                RecordingsListView(
                    recordings: filteredRecordings,
                    selectedRecording: $selectedRecording
                )
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 400)
            case .people:
                List { }
                    .overlay {
                        ContentUnavailableView(
                            "No People Yet",
                            systemImage: "person.2",
                            description: Text("Speaker management is coming in a future update.")
                        )
                    }
            }
        } detail: {
            switch selectedSection {
            case .recordings:
                if let recording = selectedRecording {
                    RecordingDetailView(recording: recording, selectedRecording: $selectedRecording)
                } else {
                    ContentUnavailableView(
                        "Select a Recording",
                        systemImage: "waveform",
                        description: Text("Choose a recording from the list to view its details.")
                    )
                }
            case .people:
                ContentUnavailableView(
                    "Coming Soon",
                    systemImage: "person.2",
                    description: Text("Speaker management is coming in a future update.")
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
        guard !searchText.isEmpty else { return recordings }
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
        if appState.isSyncing { return .orange }
        else if appState.isDeviceConnected { return .green }
        else { return .gray }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .modelContainer(for: [Recording.self, Device.self], inMemory: true)
}
