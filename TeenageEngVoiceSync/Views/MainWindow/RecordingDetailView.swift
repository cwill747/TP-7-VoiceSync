//
//  RecordingDetailView.swift
//  TeenageEngVoiceSync
//
//  Detail view for a selected recording.
//

import SwiftUI
import os
import SwiftData
import AVFoundation

struct RecordingDetailView: View {
    let recording: Recording
    @Binding var selectedRecording: Recording?
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @State private var isRetranscribing = false
    @State private var isSendingToDestinations = false
    @State private var destinationStatus: DestinationStatus?

    enum DestinationStatus {
        case success
        case error(String)
    }

    /// Local file to play, if any: prefers the device cache (`localPath`) but
    /// falls back to a recovered local copy (`localCopyPath`).
    private var localAudioURL: URL? {
        let fm = FileManager.default
        if !recording.localPath.isEmpty, fm.fileExists(atPath: recording.localPath) {
            return URL(fileURLWithPath: recording.localPath)
        }
        if let copy = recording.localCopyPath, fm.fileExists(atPath: copy) {
            return URL(fileURLWithPath: copy)
        }
        return nil
    }

    private var canRetranscribe: Bool {
        guard SyncService.hasAudioSource(recording) else { return false }
        switch recording.transcriptionStatus {
        case .none, .completed, .failed: return true
        case .pending, .processing: return false
        }
    }

    private var retranscribeLabel: String {
        switch recording.transcriptionStatus {
        case .none: return "Transcribe"
        case .failed: return "Retry Transcription"
        default: return "Retranscribe"
        }
    }

    private var canSend: Bool {
        recording.transcriptionStatus == .completed && recording.transcriptionText != nil
    }

    private var sendDisabled: Bool {
        isSendingToDestinations
            || SyncService.hasPendingLLMProcessing(recording)
            || SyncService.needsSpeakerAssignment(recording)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text(recording.displayTitle)
                        .font(.title)
                        .textSelection(.enabled)

                    HStack(spacing: 16) {
                        Label(recording.formattedDuration, systemImage: "clock")
                        Label(recording.formattedFileSize, systemImage: "doc")
                        if let sampleRate = recording.sampleRate {
                            Label("\(sampleRate / 1000)kHz", systemImage: "waveform")
                        }
                    }
                    .foregroundStyle(.secondary)

                    if let pendingStatus {
                        Label(pendingStatus.text, systemImage: pendingStatus.systemImage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.top, 2)
                    }
                }

                Divider()

                // Audio player — only when the audio exists locally. Recovered
                // rows keep the file in localCopyPath (localPath may be empty), and
                // S3/Notion-only rows have no local file to play at all.
                if let audioURL = localAudioURL {
                    AudioPlayerView(url: audioURL)

                    Divider()
                }

                // Transcription
                VStack(alignment: .leading, spacing: 12) {
                    Text("Transcription")
                        .font(.headline)

                    transcriptionContent
                }

                Divider()

                // Metadata
                VStack(alignment: .leading, spacing: 8) {
                    Text("Details")
                        .font(.headline)

                    Grid(alignment: .leading, verticalSpacing: 8) {
                        GridRow {
                            Text("Recorded")
                                .foregroundStyle(.secondary)
                            Text(recording.recordedAt.formatted(.dateTime))
                        }

                        GridRow {
                            Text("Filename")
                                .foregroundStyle(.secondary)
                            Text(recording.filename)
                                .fontDesign(.monospaced)
                                .textSelection(.enabled)
                        }

                        if let serial = recording.deviceSerial {
                            GridRow {
                                Text("Device")
                                    .foregroundStyle(.secondary)
                                Text(serial)
                                    .fontDesign(.monospaced)
                            }
                        }

                        if let hash = recording.fileHash {
                            GridRow {
                                Text("SHA256")
                                    .foregroundStyle(.secondary)
                                Text(hash.prefix(16) + "...")
                                    .fontDesign(.monospaced)
                                    .textSelection(.enabled)
                            }
                        }

                        if let s3Key = recording.s3Key {
                            GridRow {
                                Text("S3 Key")
                                    .foregroundStyle(.secondary)
                                Text(s3Key)
                                    .fontDesign(.monospaced)
                                    .textSelection(.enabled)
                            }
                        }

                        if let uploadedAt = recording.s3UploadedAt {
                            GridRow {
                                Text("Uploaded")
                                    .foregroundStyle(.secondary)
                                Text(uploadedAt.formatted(.dateTime))
                            }
                        }
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                }

                Spacer()
            }
            .padding(24)
        }
        .frame(minWidth: 400)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if canRetranscribe {
                    Button {
                        retranscribe()
                    } label: {
                        Label(retranscribeLabel, systemImage: "arrow.clockwise")
                            .symbolEffect(.rotate, options: .repeating, isActive: isRetranscribing)
                    }
                    .disabled(isRetranscribing)
                    .help(retranscribeLabel)
                }

                if canSend {
                    Button {
                        sendToDestinations()
                    } label: {
                        Label("Send to Destinations", systemImage: "paperplane")
                            .symbolEffect(.pulse, isActive: isSendingToDestinations)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(sendDisabled)
                    .help("Send to Destinations")
                }
            }
        }
    }

    private var pendingStatus: (text: String, systemImage: String)? {
        if recording.transcriptionStatus == .pending {
            return ("Waiting to transcribe", "clock")
        }
        guard let step = SyncService.remainingRemoteSteps(for: recording).first else {
            return nil
        }
        return (step.shortStatus, step.systemImage)
    }

    @ViewBuilder
    private var transcriptionContent: some View {
        switch recording.transcriptionStatus {
        case .none:
            Text("Not transcribed")
                .foregroundStyle(.secondary)
                .italic()

        case .pending:
            HStack {
                Image(systemName: "clock")
                    .foregroundStyle(.orange)
                Text("Waiting to transcribe...")
                    .foregroundStyle(.secondary)
            }

        case .processing:
            HStack {
                ProgressView()
                Text("Transcribing...")
                    .foregroundStyle(.secondary)
            }

        case .completed:
            if let _ = recording.transcriptionText {
                VStack(alignment: .leading, spacing: 8) {
                    if SyncService.hasPendingLLMProcessing(recording) {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Processing with LLM...")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        TranscriptSection(recording: recording)
                    }

                    if let notesData = recording.overdubNotesData,
                       let overdubNotes = try? JSONDecoder().decode([OverdubNote].self, from: notesData),
                       !overdubNotes.isEmpty {
                        OverdubNotesView(notes: overdubNotes)
                    }

                    if SyncService.needsSpeakerAssignment(recording) && !SyncService.hasPendingLLMProcessing(recording) {
                        Label("Choose speakers before sending", systemImage: "person.2.badge.gearshape")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }

                    if let status = destinationStatus {
                        switch status {
                        case .success:
                            Label("Sent to destinations", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        case .error(let message):
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                }
            }

        case .failed:
            Label("Transcription failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private func retranscribe() {
        guard let syncService = appState.syncService else { return }
        isRetranscribing = true

        Task {
            await syncService.retranscribe(recording)
            await MainActor.run {
                isRetranscribing = false
            }
        }
    }

    private func sendToDestinations() {
        guard let syncService = appState.syncService else { return }
        isSendingToDestinations = true
        destinationStatus = nil

        Task {
            do {
                try await syncService.sendToDestinations(recording)
                await MainActor.run {
                    destinationStatus = .success
                    isSendingToDestinations = false
                }
            } catch {
                await MainActor.run {
                    destinationStatus = .error(error.localizedDescription)
                    isSendingToDestinations = false
                }
            }
        }
    }
}

// MARK: - Transcript section (reading + search + actions)

/// Per-block search state threaded into the plain/diarized renderers so both
/// highlight matches and expose scroll anchors the same way.
struct TranscriptSearchContext: Equatable {
    var query: String = ""
    /// Index of the block that owns the currently-focused match.
    var activeBlock: Int?
    /// Match index *within* `activeBlock` to emphasize.
    var activeLocalMatch: Int?
    /// Stable prefix for each block's scroll-anchor id (`"<prefix>-<index>"`).
    var anchorPrefix: String = "block"

    func anchorID(for block: Int) -> String { "\(anchorPrefix)-\(block)" }

    func activeMatch(for block: Int) -> Int? {
        activeBlock == block ? activeLocalMatch : nil
    }

    var activeAnchorID: String? {
        activeBlock.map(anchorID(for:))
    }
}

/// Wraps a completed transcript with reading-friendly layout plus Copy All and
/// Find affordances. Owns the Cleaned/Original toggle and search state so the
/// window can stay a plain `ScrollView` while search still scrolls to matches.
struct TranscriptSection: View {
    let recording: Recording

    @State private var showOriginal = false
    @State private var query = ""
    @State private var activeMatch = 0
    @State private var didCopy = false
    @FocusState private var searchFocused: Bool

    private var segments: [StoredSpeakerSegment] {
        guard let data = recording.speakerSegmentsData,
              let decoded = try? JSONDecoder().decode([StoredSpeakerSegment].self, from: data)
        else { return [] }
        return decoded
    }

    private var cleaned: String? { recording.formattedTranscriptionText }

    /// Whether the diarized turn-by-turn view is what's on screen.
    private var showsDiarized: Bool {
        guard !segments.isEmpty else { return false }
        // With no cleaned transcript the diarized view is the only representation;
        // otherwise it's the "Original" side of the toggle.
        return cleaned == nil || showOriginal
    }

    /// Whether a Cleaned/Original toggle is meaningful for this recording.
    private var hasToggle: Bool { cleaned != nil }

    /// The plain text currently shown when not in diarized mode.
    private var plainText: String {
        if let cleaned, !showOriginal { return cleaned }
        return recording.transcriptionText ?? cleaned ?? ""
    }

    /// Block texts backing the current view, in display order.
    private var blocks: [String] {
        showsDiarized
            ? segments.map(\.text)
            : TranscriptLayout.paragraphs(from: plainText)
    }

    /// Plain text to place on the pasteboard for Copy All. Diarized turns are
    /// prefixed with their start time so the copy carries timeline context.
    private var copyText: String {
        guard showsDiarized else { return plainText }
        return segments
            .map { segment in
                let label = segment.assignedPersonName ?? segment.rawSpeakerId
                return "[\(Self.timestamp(segment.startTime))] \(label): \(segment.text)"
            }
            .joined(separator: "\n\n")
    }

    private static func timestamp(_ time: TimeInterval) -> String {
        let total = Int(time.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var matchMap: TranscriptMatchMap {
        TranscriptMatchMap(blocks: blocks, query: query)
    }

    private var searchContext: TranscriptSearchContext {
        let map = matchMap
        let location = map.location(of: activeMatch)
        return TranscriptSearchContext(
            query: query,
            activeBlock: location?.block,
            activeLocalMatch: location?.localMatch,
            anchorPrefix: showsDiarized ? "seg" : "para"
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 10) {
                controls
                    .id("transcript-controls")

                transcriptBody
            }
            .onChange(of: query) { _, _ in activeMatch = 0 }
            .onChange(of: activeMatch) { _, _ in
                guard let target = searchContext.activeAnchorID else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
            .onChange(of: recording.persistentModelID) { _, _ in
                showOriginal = false
                query = ""
                activeMatch = 0
                searchFocused = false
            }
            .background {
                // Keyboard affordances remain reachable even when the top of the
                // transcript is scrolled off: ⌘F focuses Find, ⌘⇧C copies all.
                Group {
                    Button("") {
                        withAnimation { proxy.scrollTo("transcript-controls", anchor: .top) }
                        searchFocused = true
                    }
                    .keyboardShortcut("f", modifiers: .command)

                    Button("", action: copyAll)
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                }
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 12) {
            if hasToggle {
                Picker("Transcript", selection: $showOriginal) {
                    Text("Cleaned up").tag(false)
                    Text("Original").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
            }

            Spacer(minLength: 0)

            searchField

            Button(action: copyAll) {
                Label(didCopy ? "Copied" : "Copy All",
                      systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .help("Copy the full transcript (⌘⇧C)")
            .disabled(copyText.isEmpty)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .frame(minWidth: 120, maxWidth: 200)
                .focused($searchFocused)
                .onSubmit { goToMatch(offset: 1) }

            if !query.isEmpty {
                let total = matchMap.total
                Text(total == 0 ? "No results" : "\(activeMatch + 1) of \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button { goToMatch(offset: -1) } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(total == 0)
                .help("Previous match")

                Button { goToMatch(offset: 1) } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(total == 0)
                .help("Next match (Return)")

                Button {
                    query = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .help("Clear search")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
        .frame(maxWidth: 360)
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if showsDiarized {
            DiarizedTranscriptView(
                recording: recording,
                segments: segments,
                search: searchContext
            )
        } else {
            PlainTranscriptView(
                text: plainText,
                language: recording.transcriptionLanguage,
                search: searchContext
            )
        }
    }

    private func goToMatch(offset: Int) {
        let total = matchMap.total
        guard total > 0 else { return }
        activeMatch = ((activeMatch + offset) % total + total) % total
    }

    private func copyAll() {
        guard !copyText.isEmpty else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        #endif
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run { didCopy = false }
        }
    }
}

// MARK: - Plain transcript (no diarization)

struct PlainTranscriptView: View {
    let text: String
    let language: String?
    var search: TranscriptSearchContext = TranscriptSearchContext()

    private var paragraphs: [String] { TranscriptLayout.paragraphs(from: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let lang = language {
                Text("Language: \(lang)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if paragraphs.isEmpty {
                Text("No transcript text")
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                    Text(TranscriptSearch.highlighted(
                        paragraph,
                        query: search.query,
                        activeMatch: search.activeMatch(for: index)
                    ))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(search.anchorID(for: index))
                }
            }
        }
        .padding()
        .frame(maxWidth: TranscriptLayout.maxReadingWidth, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Overdub notes (memo tracks 1+)

struct OverdubNotesView: View {
    let notes: [OverdubNote]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Overdubbed notes")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(notes.sorted(by: { $0.startTime < $1.startTime })) { note in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(formatTime(note.startTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(note.text)
                        .textSelection(.enabled)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Diarized transcript with speaker correction

struct DiarizedTranscriptView: View {
    let recording: Recording
    let segments: [StoredSpeakerSegment]
    var search: TranscriptSearchContext

    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Query(sort: \Person.createdAt) private var persons: [Person]

    @State private var localSegments: [StoredSpeakerSegment]

    init(
        recording: Recording,
        segments: [StoredSpeakerSegment],
        search: TranscriptSearchContext = TranscriptSearchContext()
    ) {
        self.recording = recording
        self.segments = segments
        self.search = search
        self._localSegments = State(initialValue: segments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Speakers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !persons.isEmpty {
                    Text("Tap a label to reassign")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 6)

            ForEach(Array(localSegments.enumerated()), id: \.element.id) { index, _ in
                SpeakerSegmentView(
                    segment: $localSegments[index],
                    persons: persons,
                    query: search.query,
                    activeMatch: search.activeMatch(for: index),
                    onReassign: { personId, personName in
                        reassign(segment: &localSegments[index], personId: personId, personName: personName)
                    },
                    onNewPerson: { name in
                        createAndAssign(segment: &localSegments[index], name: name)
                    }
                )
                .id(search.anchorID(for: index))
            }
        }
        .padding()
        .frame(maxWidth: TranscriptLayout.maxReadingWidth, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: recording.persistentModelID) { _, _ in
            // Reset local state when the selected recording changes so stale
            // segments from the previous recording are never shown or persisted.
            if let fresh = recording.speakerSegmentsData,
               let decoded = try? JSONDecoder().decode([StoredSpeakerSegment].self, from: fresh) {
                localSegments = decoded
            } else {
                localSegments = []
            }
        }
    }

    private func reassign(segment: inout StoredSpeakerSegment, personId: String, personName: String) {
        let speakerHash = segment.effectiveSpeakerHash
        assignLocalSegments(matching: speakerHash, personId: personId, personName: personName)

        // Add this segment's audio as a VoiceSample for the chosen Person,
        // unless this exact segment is already enrolled (e.g. re-selecting the
        // same person for an already-assigned segment).
        if !segment.embedding.isEmpty, let person = persons.first(where: { $0.id == personId }) {
            let isDuplicate = VoiceSample.isDuplicate(
                sourceHash: recording.fileHash,
                recordingFilename: recording.filename,
                startTime: segment.startTime,
                endTime: segment.endTime,
                in: person.samples
            )
            if !isDuplicate {
                let sample = VoiceSample(
                    recordingFilename: recording.filename,
                    sourceHash: recording.fileHash,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    embedding: segment.embedding
                )
                sample.person = person
                modelContext.insert(sample)
                person.recomputeEmbedding()
                try? modelContext.save()
                Task { await appState.syncService?.refreshKnownSpeakers() }
            }
        }

        persistAssignment(matching: speakerHash, personId: personId, personName: personName)
    }

    private func createAndAssign(segment: inout StoredSpeakerSegment, name: String) {
        let person = Person(name: name)
        modelContext.insert(person)
        let speakerHash = segment.effectiveSpeakerHash

        if !segment.embedding.isEmpty {
            let sample = VoiceSample(
                recordingFilename: recording.filename,
                sourceHash: recording.fileHash,
                startTime: segment.startTime,
                endTime: segment.endTime,
                embedding: segment.embedding
            )
            sample.person = person
            modelContext.insert(sample)
            person.recomputeEmbedding()
        }

        try? modelContext.save()

        assignLocalSegments(matching: speakerHash, personId: person.id, personName: person.name)
        persistAssignment(matching: speakerHash, personId: person.id, personName: person.name)
        Task { await appState.syncService?.refreshKnownSpeakers() }
    }

    private func assignLocalSegments(matching speakerHash: String, personId: String, personName: String) {
        _ = StoredSpeakerSegment.applyAssignment(
            to: &localSegments,
            matching: speakerHash,
            personId: personId,
            personName: personName
        )
    }

    private func persistAssignment(matching speakerHash: String, personId: String, personName: String) {
        var recordingsToRefresh: [Recording] = []
        let descriptor = FetchDescriptor<Recording>()
        let allRecordings = (try? modelContext.fetch(descriptor)) ?? [recording]

        for candidate in allRecordings {
            guard let data = candidate.speakerSegmentsData,
                  var segments = try? JSONDecoder().decode([StoredSpeakerSegment].self, from: data) else { continue }

            if let cleanedTranscript = candidate.formattedTranscriptionText {
                candidate.formattedTranscriptionText = StoredSpeakerSegment.relabelTranscript(
                    cleanedTranscript,
                    matching: speakerHash,
                    in: segments,
                    to: personName
                )
            }
            let changed = StoredSpeakerSegment.applyAssignment(
                to: &segments,
                matching: speakerHash,
                personId: personId,
                personName: personName
            )

            guard changed else { continue }

            candidate.speakerSegmentsData = try? JSONEncoder().encode(segments)
            candidate.transcriptionText = StoredSpeakerSegment.transcript(from: segments)
            candidate.updatedAt = Date()
            recordingsToRefresh.append(candidate)
        }

        if recordingsToRefresh.isEmpty {
            recording.speakerSegmentsData = try? JSONEncoder().encode(localSegments)
            recording.transcriptionText = StoredSpeakerSegment.transcript(from: localSegments)
            recording.updatedAt = Date()
            recordingsToRefresh.append(recording)
        }

        try? modelContext.save()

        // Propagate the relabeled transcripts to each recording's Notion page in
        // place, so reassigning speakers (or merging two tracks onto one
        // speaker) is reflected without spawning duplicate pages.
        for edited in recordingsToRefresh {
            Task { await appState.syncService?.refreshNotionForEditedTranscript(edited) }
        }
    }
}

struct SpeakerSegmentView: View {
    @Binding var segment: StoredSpeakerSegment
    let persons: [Person]
    var query: String = ""
    var activeMatch: Int?
    let onReassign: (String, String) -> Void
    let onNewPerson: (String) -> Void

    @State private var showNewPersonPrompt = false
    @State private var newPersonName = ""

    private var displayLabel: String {
        segment.assignedPersonName ?? segment.rawSpeakerId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Menu {
                    if !persons.isEmpty {
                        Section("Assign to person") {
                            ForEach(persons) { person in
                                Button(person.name) {
                                    onReassign(person.id, person.name)
                                }
                            }
                        }
                        Divider()
                    }
                    Button("New person…") {
                        showNewPersonPrompt = true
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(displayLabel)
                            .font(.subheadline.bold())
                            .foregroundStyle(segment.assignedPersonName != nil ? .primary : .secondary)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Text(":")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
            }

            Text(TranscriptSearch.highlighted(
                segment.text,
                query: query,
                activeMatch: activeMatch
            ))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider().padding(.top, 8)
        }
        .sheet(isPresented: $showNewPersonPrompt) {
            NewPersonPrompt(
                isPresented: $showNewPersonPrompt,
                initialName: newPersonName,
                onConfirm: { name in
                    onNewPerson(name)
                }
            )
        }
    }
}

struct NewPersonPrompt: View {
    @Binding var isPresented: Bool
    let initialName: String
    let onConfirm: (String) -> Void

    @State private var name: String

    init(isPresented: Binding<Bool>, initialName: String, onConfirm: @escaping (String) -> Void) {
        self._isPresented = isPresented
        self.initialName = initialName
        self.onConfirm = onConfirm
        self._name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("New Person")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Add") {
                    onConfirm(name.trimmingCharacters(in: .whitespaces))
                    isPresented = false
                }
                .keyboardShortcut(.return)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 300)
    }
}

// MARK: - Audio player

struct AudioPlayerView: View {
    let url: URL
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 12) {
            // Progress bar
            Slider(value: $currentTime, in: 0...max(duration, 1)) { editing in
                if !editing {
                    player?.currentTime = currentTime
                }
            }

            // Controls
            HStack {
                Text(formatTime(currentTime))
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)

                Spacer()

                Text(formatTime(duration))
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            stopPlayback()
        }
    }

    private func setupPlayer() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            duration = player?.duration ?? 0
        } catch {
            AppLogger.app.error("Failed to setup audio player: \(String(describing: error), privacy: .public)")
        }
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        player?.play()
        isPlaying = true

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                currentTime = player?.currentTime ?? 0
                if !(player?.isPlaying ?? false) {
                    stopPlayback()
                }
            }
        }
    }

    private func stopPlayback() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    @Previewable @State var selected: Recording? = nil
    RecordingDetailView(
        recording: Recording(
            filename: "track_001.wav",
            localPath: "/path/to/file.wav",
            fileSize: 1024 * 1024 * 5,
            recordedAt: Date()
        ),
        selectedRecording: $selected
    )
    .modelContainer(for: [Recording.self, Person.self, VoiceSample.self], inMemory: true)
}

#if DEBUG
/// A multi-paragraph, multi-page transcript used to exercise the reading and
/// search layout without a real recording.
enum TranscriptPreviewFixture {
    static let multiPageText: String = {
        let paragraph = """
        We opened the session by walking through last quarter's numbers and where \
        the projections landed versus what actually shipped. The headline is that \
        adoption outpaced the forecast, but support load grew with it, so the net \
        picture is more nuanced than the top-line figure suggests.
        """
        // Repeat with distinct markers so search has scattered, countable matches.
        return (1...12)
            .map { "Section \($0). \(paragraph)" }
            .joined(separator: "\n\n")
    }()

    static let segments: [StoredSpeakerSegment] = (1...8).map { index -> StoredSpeakerSegment in
        let start = TimeInterval(index * 20)
        let speaker = index.isMultiple(of: 2) ? "Speaker 2" : "Speaker 1"
        let turnText = "Turn \(index): the projections landed close to plan, and the support load is the part we should keep watching next quarter."
        return StoredSpeakerSegment(
            startTime: start,
            endTime: start + 18,
            rawSpeakerId: speaker,
            text: turnText,
            embedding: []
        )
    }
}

#Preview("Plain — multi-page") {
    ScrollView {
        PlainTranscriptView(text: TranscriptPreviewFixture.multiPageText, language: "en")
            .padding()
    }
    .frame(width: 900, height: 600)
}

#Preview("Transcript section — searchable") {
    let recording = Recording(
        filename: "long_meeting.wav",
        localPath: "/path/to/file.wav",
        fileSize: 1024 * 1024 * 40,
        recordedAt: Date()
    )
    recording.transcriptionText = TranscriptPreviewFixture.multiPageText
    recording.transcriptionLanguage = "en"

    return ScrollView {
        TranscriptSection(recording: recording)
            .padding()
    }
    .frame(width: 900, height: 600)
    .environment(AppState())
    .modelContainer(for: [Recording.self, Person.self, VoiceSample.self], inMemory: true)
}

#Preview("Transcript section — diarized") {
    let recording = Recording(
        filename: "interview.wav",
        localPath: "/path/to/file.wav",
        fileSize: 1024 * 1024 * 20,
        recordedAt: Date()
    )
    recording.transcriptionText = StoredSpeakerSegment.transcript(from: TranscriptPreviewFixture.segments)
    recording.speakerSegmentsData = try? JSONEncoder().encode(TranscriptPreviewFixture.segments)

    return ScrollView {
        TranscriptSection(recording: recording)
            .padding()
    }
    .frame(width: 900, height: 600)
    .environment(AppState())
    .modelContainer(for: [Recording.self, Person.self, VoiceSample.self], inMemory: true)
}
#endif
