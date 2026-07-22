import SwiftUI

struct VocabularySettingsView: View {
    @AppStorage(VocabularyStore.boostingEnabledDefaultsKey) private var boostingEnabled = true

    @State private var boostTerms: [VocabularyStore.BoostTerm] = []
    @State private var dictionaryEntries: [VocabularyStore.DictionaryEntry] = []
    @State private var showAddBoostSheet = false
    @State private var editingBoostTerm: IndexedBoostTerm?
    @State private var showAddDictionarySheet = false
    @State private var editingDictionaryEntry: VocabularyStore.DictionaryEntry?

    var body: some View {
        Form {
            Section {
                HStack {
                    Toggle("Vocabulary Boosting", isOn: $boostingEnabled)
                    Spacer()
                }
                Text("Helps Parakeet recognize names, products, and unusual terms by running a CTC pass over confirmed audio chunks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Custom Words")
            } footer: {
                if boostTerms.isEmpty {
                    Text("No custom words yet. Add a name or term that needs extra recognition help.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !boostTerms.isEmpty {
                Section {
                    ForEach(Array(boostTerms.enumerated()), id: \.offset) { index, term in
                        BoostTermRow(term: term) {
                            editingBoostTerm = IndexedBoostTerm(index: index, term: term)
                        } onDelete: {
                            deleteBoostTerm(at: index)
                        }
                    }
                }
            }

            Section {
                Button {
                    showAddBoostSheet = true
                } label: {
                    Label("Add Custom Word", systemImage: "plus")
                }
            }

            Section {
                if dictionaryEntries.isEmpty {
                    Text("No replacements yet. Add entries to correct words Parakeet consistently mishears.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dictionaryEntries) { entry in
                        DictionaryEntryRow(entry: entry) {
                            editingDictionaryEntry = entry
                        } onDelete: {
                            deleteDictionaryEntry(entry)
                        }
                    }
                }
            } header: {
                Text("Dictionary")
            }

            Section {
                Button {
                    showAddDictionarySheet = true
                } label: {
                    Label("Add Replacement", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .sheet(isPresented: $showAddBoostSheet) {
            AddBoostTermSheet(existingTerms: existingBoostTermKeys()) { term in
                boostTerms.append(term)
                saveBoostTerms()
            }
        }
        .sheet(item: $editingBoostTerm) { editable in
            EditBoostTermSheet(
                term: editable.term,
                existingTerms: existingBoostTermKeys(excludingIndex: editable.index)
            ) { updated in
                guard boostTerms.indices.contains(editable.index) else { return }
                boostTerms[editable.index] = updated
                saveBoostTerms()
            }
        }
        .sheet(isPresented: $showAddDictionarySheet) {
            AddDictionaryEntrySheet(existingTriggers: existingTriggers()) { entry in
                dictionaryEntries.insert(entry, at: 0)
                saveDictionaryEntries()
            }
        }
        .sheet(item: $editingDictionaryEntry) { entry in
            EditDictionaryEntrySheet(
                entry: entry,
                existingTriggers: existingTriggers(excluding: entry.id)
            ) { updated in
                if let idx = dictionaryEntries.firstIndex(where: { $0.id == updated.id }) {
                    dictionaryEntries[idx] = updated
                    saveDictionaryEntries()
                }
            }
        }
    }

    private func load() {
        boostTerms = (try? VocabularyStore.shared.loadBoostTerms()) ?? []
        dictionaryEntries = VocabularyStore.shared.loadDictionaryEntries()
    }

    private func saveBoostTerms() {
        try? VocabularyStore.shared.saveBoostTerms(boostTerms)
    }

    private func saveDictionaryEntries() {
        VocabularyStore.shared.saveDictionaryEntries(dictionaryEntries)
    }

    private func deleteBoostTerm(at index: Int) {
        guard boostTerms.indices.contains(index) else { return }
        boostTerms.remove(at: index)
        saveBoostTerms()
    }

    private func deleteDictionaryEntry(_ entry: VocabularyStore.DictionaryEntry) {
        dictionaryEntries.removeAll { $0.id == entry.id }
        saveDictionaryEntries()
    }

    private func existingBoostTermKeys(excludingIndex: Int? = nil) -> Set<String> {
        boostTerms.enumerated()
            .filter { $0.offset != excludingIndex }
            .reduce(into: Set<String>()) { $0.insert($1.element.text.lowercased()) }
    }

    private func existingTriggers(excluding entryId: UUID? = nil) -> Set<String> {
        dictionaryEntries
            .filter { $0.id != entryId }
            .flatMap(\.triggers)
            .reduce(into: Set<String>()) { $0.insert($1.lowercased()) }
    }
}

// MARK: - BoostTermRow

private struct BoostTermRow: View {
    let term: VocabularyStore.BoostTerm
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(term.text)
                    .font(.body)
                if let aliases = term.aliases.nilIfEmpty {
                    Text(aliases.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let weight = term.weight {
                let preset = BoostStrength.nearest(weight)
                Text(preset.label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(preset.color.opacity(0.2)))
                    .foregroundStyle(preset.color)
            }

            Menu {
                Button("Edit", action: onEdit)
                Divider()
                Button("Delete \"\(term.text)\"", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Options for \(term.text)")
            .accessibilityLabel(Text("Options for \(term.text)"))
        }
    }
}

// MARK: - DictionaryEntryRow

private struct DictionaryEntryRow: View {
    let entry: VocabularyStore.DictionaryEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.triggers.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(entry.replacement)
                        .font(.body)
                }
            }

            Spacer()

            Menu {
                Button("Edit", action: onEdit)
                Divider()
                Button("Delete \"\(entry.triggers.joined(separator: ", "))\"", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Options for \(entry.triggers.joined(separator: ", "))")
            .accessibilityLabel(Text("Options for \(entry.triggers.joined(separator: ", "))"))
        }
    }
}

// MARK: - Boost strength

enum BoostStrength {
    case mild, balanced, strong

    var label: String {
        switch self {
        case .mild: "Mild"
        case .balanced: "Balanced"
        case .strong: "Strong"
        }
    }

    var weight: Float {
        switch self {
        case .mild: 5.0
        case .balanced: 10.0
        case .strong: 13.0
        }
    }

    var hint: String {
        switch self {
        case .mild: "Very light nudge with minimal impact."
        case .balanced: "Best default for most names and product terms."
        case .strong: "Use when this word should win in noisy audio."
        }
    }

    var color: Color {
        switch self {
        case .mild: .blue
        case .balanced: .green
        case .strong: .orange
        }
    }

    static func nearest(_ weight: Float) -> Self {
        if weight < 8.5 { return .mild }
        if weight > 11.5 { return .strong }
        return .balanced
    }
}

// MARK: - Add/Edit Boost Term Sheet

struct AddBoostTermSheet: View {
    @Environment(\.dismiss) private var dismiss

    let existingTerms: Set<String>
    let onSave: (VocabularyStore.BoostTerm) -> Void

    @State private var text = ""
    @State private var strength: BoostStrength = .balanced

    private var normalized: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDuplicate: Bool { existingTerms.contains(normalized.lowercased()) }
    private var canSave: Bool { !normalized.isEmpty && !isDuplicate }

    var body: some View {
        boostTermForm(title: "Add Custom Word", saveLabel: "Add Word")
    }

    @ViewBuilder
    func boostTermForm(title: String, saveLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Word or Phrase").font(.subheadline.weight(.medium))
                TextField("VoiceSync", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveIfValid() }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Priority").font(.subheadline.weight(.medium))
                Picker("Priority", selection: $strength) {
                    Text("Mild").tag(BoostStrength.mild)
                    Text("Balanced").tag(BoostStrength.balanced)
                    Text("Strong").tag(BoostStrength.strong)
                }
                .pickerStyle(.segmented)
                Text(strength.hint).font(.caption).foregroundStyle(.secondary)
            }

            if isDuplicate {
                Text("This term already exists.")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                Spacer()
                Button(saveLabel) { saveIfValid() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 420, maxWidth: 480)
        .frame(minHeight: 260, idealHeight: 300, maxHeight: 380)
        .onAppear { text = ""; strength = .balanced }
    }

    func saveIfValid() {
        guard canSave else { return }
        onSave(VocabularyStore.BoostTerm(text: normalized, weight: strength.weight))
        dismiss()
    }
}

struct EditBoostTermSheet: View {
    @Environment(\.dismiss) private var dismiss

    let term: VocabularyStore.BoostTerm
    let existingTerms: Set<String>
    let onSave: (VocabularyStore.BoostTerm) -> Void

    @State private var text = ""
    @State private var strength: BoostStrength = .balanced

    private var normalized: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDuplicate: Bool { existingTerms.contains(normalized.lowercased()) }
    private var canSave: Bool { !normalized.isEmpty && !isDuplicate }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Custom Word").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Word or Phrase").font(.subheadline.weight(.medium))
                TextField("VoiceSync", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveIfValid() }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Priority").font(.subheadline.weight(.medium))
                Picker("Priority", selection: $strength) {
                    Text("Mild").tag(BoostStrength.mild)
                    Text("Balanced").tag(BoostStrength.balanced)
                    Text("Strong").tag(BoostStrength.strong)
                }
                .pickerStyle(.segmented)
                Text(strength.hint).font(.caption).foregroundStyle(.secondary)
            }

            if isDuplicate {
                Text("This term already exists.")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                Spacer()
                Button("Save") { saveIfValid() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 420, maxWidth: 480)
        .frame(minHeight: 260, idealHeight: 300, maxHeight: 380)
        .onAppear {
            text = term.text
            strength = BoostStrength.nearest(term.weight ?? BoostStrength.balanced.weight)
        }
    }

    func saveIfValid() {
        guard canSave else { return }
        onSave(VocabularyStore.BoostTerm(text: normalized, weight: strength.weight, aliases: term.aliases))
        dismiss()
    }
}

// MARK: - Add/Edit Dictionary Entry Sheet

struct AddDictionaryEntrySheet: View {
    @Environment(\.dismiss) private var dismiss

    let existingTriggers: Set<String>
    let onSave: (VocabularyStore.DictionaryEntry) -> Void

    @State private var triggersText = ""
    @State private var replacement = ""

    private var triggers: [String] {
        triggersText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
    private var duplicates: [String] { triggers.filter { existingTriggers.contains($0) } }
    private var canSave: Bool {
        !triggers.isEmpty &&
        !replacement.trimmingCharacters(in: .whitespaces).isEmpty &&
        duplicates.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Replacement").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("When Parakeet hears").font(.subheadline.weight(.medium))
                TextField("fluid voice, fluid boys", text: $triggersText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveIfValid() }
                Text("Separate multiple variations with commas.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Replace with").font(.subheadline.weight(.medium))
                TextField("VoiceSync", text: $replacement)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveIfValid() }
            }

            if !duplicates.isEmpty {
                Label("Already used: \(duplicates.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                Spacer()
                Button("Add") { saveIfValid() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 420, maxWidth: 480)
        .frame(minHeight: 260, idealHeight: 300, maxHeight: 380)
    }

    func saveIfValid() {
        guard canSave else { return }
        onSave(VocabularyStore.DictionaryEntry(
            triggers: triggers,
            replacement: replacement.trimmingCharacters(in: .whitespaces)
        ))
        dismiss()
    }
}

struct EditDictionaryEntrySheet: View {
    @Environment(\.dismiss) private var dismiss

    let entry: VocabularyStore.DictionaryEntry
    let existingTriggers: Set<String>
    let onSave: (VocabularyStore.DictionaryEntry) -> Void

    @State private var triggersText = ""
    @State private var replacement = ""

    private var triggers: [String] {
        triggersText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
    private var duplicates: [String] { triggers.filter { existingTriggers.contains($0) } }
    private var canSave: Bool {
        !triggers.isEmpty &&
        !replacement.trimmingCharacters(in: .whitespaces).isEmpty &&
        duplicates.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Replacement").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("When Parakeet hears").font(.subheadline.weight(.medium))
                TextField("fluid voice, fluid boys", text: $triggersText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveIfValid() }
                Text("Separate multiple variations with commas.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Replace with").font(.subheadline.weight(.medium))
                TextField("VoiceSync", text: $replacement)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveIfValid() }
            }

            if !duplicates.isEmpty {
                Label("Already used: \(duplicates.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                Spacer()
                Button("Save") { saveIfValid() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 420, maxWidth: 480)
        .frame(minHeight: 260, idealHeight: 300, maxHeight: 380)
        .onAppear {
            triggersText = entry.triggers.joined(separator: ", ")
            replacement = entry.replacement
        }
    }

    func saveIfValid() {
        guard canSave else { return }
        onSave(VocabularyStore.DictionaryEntry(
            id: entry.id,
            triggers: triggers,
            replacement: replacement.trimmingCharacters(in: .whitespaces)
        ))
        dismiss()
    }
}

// MARK: - Helpers

struct IndexedBoostTerm: Identifiable {
    var id: Int { index }
    let index: Int
    let term: VocabularyStore.BoostTerm
}

private extension Array where Element == String {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

#Preview {
    VocabularySettingsView()
}
