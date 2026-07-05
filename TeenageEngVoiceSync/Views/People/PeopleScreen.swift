import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct PeopleScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Person.createdAt) private var persons: [Person]

    @State private var selectedPerson: Person?
    @State private var showAddPerson = false
    @State private var newPersonName = ""

    var body: some View {
        List(persons, selection: $selectedPerson) { person in
            PersonRowView(person: person)
                .tag(person)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddPerson = true
                } label: {
                    Label("Add Person", systemImage: "person.badge.plus")
                }
            }
        }
        .sheet(isPresented: $showAddPerson) {
            AddPersonSheet(isPresented: $showAddPerson, onAdd: addPerson)
        }
        .overlay {
            if persons.isEmpty {
                ContentUnavailableView(
                    "No People",
                    systemImage: "person.2",
                    description: Text("Add people to label who's speaking in recordings.")
                )
            }
        }
    }

    private func addPerson(name: String, isSelf: Bool) {
        let person = Person(name: name, isSelf: isSelf)
        modelContext.insert(person)
        try? modelContext.save()
        selectedPerson = person
    }
}

struct PersonRowView: View {
    let person: Person

    var body: some View {
        HStack {
            Image(systemName: person.isSelf ? "person.circle.fill" : "person.circle")
                .foregroundStyle(person.isSelf ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                Text(person.isEnrolled ? "\(person.samples.count) sample\(person.samples.count == 1 ? "" : "s")" : "Not enrolled")
                    .font(.caption)
                    .foregroundStyle(person.isEnrolled ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            }
        }
        .padding(.vertical, 2)
    }
}

struct AddPersonSheet: View {
    @Binding var isPresented: Bool
    let onAdd: (String, Bool) -> Void

    @State private var name = ""
    @State private var isSelf = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Person")
                .font(.headline)

            TextField("Name (e.g. Cameron)", text: $name)
                .textFieldStyle(.roundedBorder)

            Toggle("This is me", isOn: $isSelf)
                .help("Mark this person as yourself — useful when you appear in most recordings.")

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Add") {
                    onAdd(name.trimmingCharacters(in: .whitespaces), isSelf)
                    isPresented = false
                }
                .keyboardShortcut(.return)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}

struct PersonDetailView: View {
    @Bindable var person: Person
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @State private var isEnrolling = false
    @State private var enrollmentError: String?
    @State private var diarizerReady = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header — name editing
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Name", text: $person.name)
                            .font(.title)
                            .textFieldStyle(.plain)
                            .onSubmit { try? modelContext.save() }

                        if person.isSelf {
                            Text("(you)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Mark as myself", isOn: $person.isSelf)
                        .onChange(of: person.isSelf) { _, _ in try? modelContext.save() }
                        .font(.callout)
                }

                Divider()

                // Enrollment section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Voice Enrollment")
                            .font(.headline)
                        Spacer()
                        if person.isEnrolled {
                            Label("Enrolled", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.callout)
                        }
                    }

                    if !diarizerReady {
                        Label("Download the diarization model in Settings → Transcription first.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    } else {
                        Button {
                            addSampleFromFile()
                        } label: {
                            if isEnrolling {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Label("Add Voice Sample…", systemImage: "waveform.badge.plus")
                            }
                        }
                        .disabled(isEnrolling)
                        .help("Pick a recording where this person is the primary speaker.")
                    }

                    if let error = enrollmentError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }

                    Text("Pick recordings where this person is the only or primary speaker. The more samples you add, the more accurate speaker identification becomes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !person.samples.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Voice Samples")
                            .font(.headline)

                        ForEach(person.samples) { sample in
                            SampleRowView(sample: sample, onDelete: {
                                removeSample(sample)
                            })
                        }
                    }
                }

                Divider()

                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        deletePerson()
                    } label: {
                        Label("Delete Person", systemImage: "trash")
                    }
                }
            }
            .padding(24)
        }
        .onAppear { diarizerReady = ParakeetService.diarizerModelExists() }
    }

    private func addSampleFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Sample"
        panel.allowedContentTypes = [.audio]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        enrollmentError = nil
        isEnrolling = true

        Task {
            do {
                let embedding = try await ParakeetService.extractEmbedding(from: url.path)
                await MainActor.run {
                    let sample = VoiceSample(
                        recordingFilename: url.lastPathComponent,
                        startTime: 0,
                        endTime: 0,
                        embedding: embedding
                    )
                    sample.person = person
                    modelContext.insert(sample)
                    person.recomputeEmbedding()
                    try? modelContext.save()
                    isEnrolling = false

                    // Refresh speaker roster in the transcription pipeline
                    Task {
                        await appState.syncService?.refreshKnownSpeakers()
                    }
                }
            } catch {
                await MainActor.run {
                    enrollmentError = error.localizedDescription
                    isEnrolling = false
                }
            }
        }
    }

    private func removeSample(_ sample: VoiceSample) {
        modelContext.delete(sample)
        person.recomputeEmbedding()
        try? modelContext.save()
        Task { await appState.syncService?.refreshKnownSpeakers() }
    }

    private func deletePerson() {
        modelContext.delete(person)
        try? modelContext.save()
    }
}

struct SampleRowView: View {
    let sample: VoiceSample
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                if let filename = sample.recordingFilename {
                    Text(filename)
                        .font(.callout)
                } else {
                    Text("Voice sample")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text(sample.addedAt.formatted(.dateTime.month().day().year()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}
