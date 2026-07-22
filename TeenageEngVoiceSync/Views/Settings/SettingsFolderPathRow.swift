//
//  SettingsFolderPathRow.swift
//  TeenageEngVoiceSync
//
//  Reusable "current folder" row for Storage/Transcription settings. Long or
//  deeply nested paths wrap up to a couple of lines and fall back to middle
//  truncation, but stay fully readable via text selection or the tooltip.
//

import SwiftUI

struct SettingsFolderPathRow: View {
    let path: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("Current:")
            Text(path)
                .textSelection(.enabled)
                .truncationMode(.middle)
                .lineLimit(2)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(path)
    }
}

/// Folder-picker row (path field + Choose/Validate) that drops to a vertical
/// layout instead of squeezing the buttons off-balance when the field's
/// content is too wide for the available row.
struct SettingsFolderPickerRow: View {
    @Binding var path: String
    let placeholder: String
    let onChoose: () -> Void
    let onValidate: () -> Void
    let validateDisabled: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                field
                buttons
            }
            VStack(alignment: .leading, spacing: 8) {
                field
                buttons
            }
        }
    }

    private var field: some View {
        TextField(placeholder, text: $path)
            .textFieldStyle(.roundedBorder)
    }

    private var buttons: some View {
        HStack {
            Button("Choose…", action: onChoose)
            Button("Validate", action: onValidate)
                .disabled(validateDisabled)
        }
    }
}
