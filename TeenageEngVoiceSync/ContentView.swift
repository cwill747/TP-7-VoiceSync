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

    @Query(sort: \Person.createdAt) private var persons: [Person]

    @State private var selectedSection: SidebarItem = .recordings
    @State private var selectedRecording: Recording?
    @State private var selectedPerson: Person?
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
                PeopleScreen(selectedPerson: $selectedPerson)
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
                if let person = selectedPerson {
                    PersonDetailView(person: person)
                } else {
                    ContentUnavailableView(
                        "Select a Person",
                        systemImage: "person",
                        description: Text("Choose a person to manage their voice samples.")
                    )
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search recordings")
        .toolbar {
            ToolbarItem(placement: .status) {
                StatusToolbarItem(appState: appState)
            }
        }
        .onChange(of: selectedSection) { _, _ in
            // Reset detail selections when switching sections
            selectedRecording = nil
            selectedPerson = nil
        }
        .alert("Notice", isPresented: Bindable(appState).showError, presenting: appState.lastError) { _ in
            Button("OK") { appState.clearError() }
        } message: { message in
            Text(message)
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
            if appState.isOffline {
                Image(systemName: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }

            Text(appState.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        if appState.isSyncing { return .orange }
        else if appState.pendingRemoteCount > 0 { return .yellow }
        else if appState.isDeviceConnected { return .green }
        else { return .gray }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .modelContainer(for: [Recording.self, Device.self, Person.self, VoiceSample.self], inMemory: true)
}
