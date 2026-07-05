//
//  ContentView.swift
//  TeenageEngVoiceSync
//
//  Main recordings window — outer section shell.
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
    @State private var selectedSection: SidebarItem = .recordings

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selectedSection) { item in
                Label(item.label, systemImage: item.systemImage)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 200)
            .navigationTitle("TP-7 VoiceSync")
        } detail: {
            switch selectedSection {
            case .recordings:
                RecordingsScreen()
            case .people:
                ContentUnavailableView(
                    "People",
                    systemImage: "person.2",
                    description: Text("Speaker management is coming in a future update.")
                )
            }
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
