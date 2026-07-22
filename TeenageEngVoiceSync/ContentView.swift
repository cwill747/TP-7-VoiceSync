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
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recordings: return "Recordings"
        case .people: return "People"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .recordings: return "waveform"
        case .people: return "person.2"
        case .settings: return "gear"
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case storage
    case apiKeys
    case transcription
    case enhancement
    case vocabulary
    case advanced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .storage: return "Storage"
        case .apiKeys: return "API Keys"
        case .transcription: return "Transcription"
        case .enhancement: return "Enhancement"
        case .vocabulary: return "Dictionary"
        case .advanced: return "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gear"
        case .storage: return "externaldrive"
        case .apiKeys: return "key"
        case .transcription: return "text.bubble"
        case .enhancement: return "sparkles"
        case .vocabulary: return "text.book.closed"
        case .advanced: return "slider.horizontal.3"
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
    @State private var selectedRecordings: Set<Recording> = []
    @State private var selectedPerson: Person?
    @State private var selectedSettingsSection: SettingsSection = .general
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
                    selectedRecording: $selectedRecording,
                    selectedRecordings: $selectedRecordings
                )
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 400)
            case .people:
                PeopleScreen(selectedPerson: $selectedPerson)
            case .settings:
                List(SettingsSection.allCases, selection: $selectedSettingsSection) { section in
                    Label(section.label, systemImage: section.systemImage)
                        .tag(section)
                }
                .navigationSplitViewColumnWidth(min: 150, ideal: 200, max: 250)
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
            case .settings:
                settingsDetailView(for: selectedSettingsSection)
            }
        }
        .searchable(text: $searchText, prompt: "Search recordings")
        .toolbar {
            ToolbarItem(placement: .status) {
                StatusToolbarItem(appState: appState)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .onChange(of: selectedSection) { _, _ in
            // Reset detail selections when switching sections
            selectedRecording = nil
            selectedRecordings.removeAll()
            selectedPerson = nil
        }
        .onChange(of: appState.navigationTarget) { _, target in
            if let target {
                selectedSection = target
                appState.navigationTarget = nil
            }
        }
        .alert("Notice", isPresented: Bindable(appState).showError, presenting: appState.lastError) { _ in
            Button("OK") { appState.clearError() }
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private func settingsDetailView(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsView()
        case .storage:
            StorageSettingsView()
        case .apiKeys:
            APIKeysSettingsView()
        case .transcription:
            TranscriptionSettingsView()
        case .enhancement:
            EnhancementSettingsView()
        case .vocabulary:
            VocabularySettingsView()
        case .advanced:
            AdvancedSettingsView()
        }
    }

    private var filteredRecordings: [Recording] {
        guard !searchText.isEmpty else { return recordings }
        return recordings.filter { recording in
            recording.displayTitle.localizedCaseInsensitiveContains(searchText) ||
            recording.filename.localizedCaseInsensitiveContains(searchText) ||
            (recording.transcriptionText?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
}

struct StatusToolbarItem: View {
    let appState: AppState

    var body: some View {
        HStack(spacing: 6) {
            if let statusIcon {
                Image(systemName: statusIcon)
                    .imageScale(.medium)
                    .foregroundStyle(statusIconColor)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.variableColor, isActive: appState.isDownloadingFromDevice)
                    .symbolEffect(.pulse, isActive: appState.processingActivity != nil)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                    .shadow(color: statusColor.opacity(0.6), radius: 2)
            }

            Text(appState.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .animation(.easeInOut(duration: 0.2), value: appState.statusText)
    }

    private var statusColor: Color {
        if appState.isSyncing { return .orange }
        else if appState.pendingRemoteCount > 0 { return .yellow }
        else if appState.isDeviceConnected { return .green }
        else { return .gray }
    }

    private var statusIcon: String? {
        if appState.isDownloadingFromDevice { return "arrow.down.circle" }
        if let activity = appState.processingActivity { return activity.systemImage }
        if appState.isOffline { return "wifi.slash" }
        return nil
    }

    private var statusIconColor: Color {
        if appState.isDownloadingFromDevice { return .blue }
        if appState.isOffline { return .secondary }
        return .orange
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .modelContainer(for: [Recording.self, Device.self, Person.self, VoiceSample.self], inMemory: true)
}
