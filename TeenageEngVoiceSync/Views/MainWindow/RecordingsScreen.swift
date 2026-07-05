import SwiftUI
import SwiftData

struct RecordingsScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @Query(filter: #Predicate<Recording> { $0.deletedAt == nil },
           sort: \Recording.recordedAt, order: .reverse)
    private var recordings: [Recording]

    @State private var selectedRecording: Recording?
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            RecordingsListView(
                recordings: filteredRecordings,
                selectedRecording: $selectedRecording
            )
            .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 400)
        } detail: {
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
        guard !searchText.isEmpty else { return recordings }
        return recordings.filter { recording in
            recording.filename.localizedCaseInsensitiveContains(searchText) ||
            (recording.transcriptionText?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
}

#Preview {
    RecordingsScreen()
        .environment(AppState())
        .modelContainer(for: [Recording.self, Device.self], inMemory: true)
}
