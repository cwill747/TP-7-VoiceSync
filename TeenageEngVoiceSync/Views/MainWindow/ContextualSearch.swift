//
//  ContextualSearch.swift
//  TeenageEngVoiceSync
//
//  Section-scoped search for the main window. The global toolbar search field is
//  shared across sidebar sections, so each section owns its own prompt and
//  filtering rules. The matching logic lives here as pure functions so it can be
//  unit-tested independently of the SwiftUI views.
//

import SwiftUI

extension SidebarItem {
    /// Prompt shown in the toolbar search field for this section, or `nil` when
    /// the section has no searchable content (the field is hidden entirely).
    var searchPrompt: String? {
        switch self {
        case .recordings: return "Search recordings"
        case .people: return "Search people"
        case .settings: return nil
        }
    }

    /// Whether the toolbar search field should be shown while this section is
    /// selected.
    var isSearchable: Bool { searchPrompt != nil }
}

/// Section-scoped filtering. Each `filter` returns the full collection when the
/// query is empty (after trimming), so an all-whitespace query is treated as "no
/// search" rather than matching nothing.
enum ContextualSearch {
    static func filter(recordings: [Recording], query: String) -> [Recording] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recordings }
        return recordings.filter { recording in
            recording.displayTitle.localizedCaseInsensitiveContains(trimmed) ||
            recording.filename.localizedCaseInsensitiveContains(trimmed) ||
            (recording.transcriptionText?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    static func filter(persons: [Person], query: String) -> [Person] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return persons }
        return persons.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    /// True when the trimmed query is non-empty, i.e. results are being filtered.
    /// Drives the "no matches" vs "no data" empty-state distinction.
    static func isActive(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Conditionally attaches `.searchable`. Toggling the modifier on/off lets the
/// toolbar search field appear only for sections that support search.
extension View {
    @ViewBuilder
    func contextualSearchable(text: Binding<String>, prompt: String?) -> some View {
        if let prompt {
            self.searchable(text: text, prompt: prompt)
        } else {
            self
        }
    }
}
