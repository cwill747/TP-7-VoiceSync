//
//  DeviceDownloadProgressView.swift
//  TeenageEngVoiceSync
//
//  Popover content shown when tapping the toolbar's "Downloading from TP-7"
//  status, breaking the aggregate count down into a per-file progress list.
//

import SwiftUI

struct DeviceDownloadProgressView: View {
    let files: [DeviceDownloadProgress]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Downloading from TP-7")
                .font(.headline)

            if files.isEmpty {
                Text("No files downloading")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(files) { file in
                        DeviceDownloadRow(file: file)
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 280, maxWidth: 340)
    }
}

private struct DeviceDownloadRow: View {
    let file: DeviceDownloadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(file.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                statusGlyph
            }
            ProgressView(value: fractionCompleted)
                .progressViewStyle(.linear)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(file.name), \(statusDescription)"))
    }

    private var statusDescription: String {
        switch file.state {
        case .queued: return "Queued"
        case .downloading(let sent, let total) where total > 0:
            return "\(Int((Double(sent) / Double(total)) * 100))% downloaded"
        case .downloading: return "Downloading"
        case .done: return "Download complete"
        case .failed: return "Download failed"
        }
    }

    private var fractionCompleted: Double? {
        switch file.state {
        case .queued: return 0
        case .downloading(let sent, let total):
            guard total > 0 else { return nil }
            return min(1, max(0, Double(sent) / Double(total)))
        case .done: return 1
        case .failed: return nil
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch file.state {
        case .queued:
            Text("Queued")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloading(let sent, let total) where total > 0:
            Text("\(Int((Double(sent) / Double(total)) * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloading:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

#Preview {
    DeviceDownloadProgressView(files: [
        DeviceDownloadProgress(name: "0001.wav", folder: "recordings", state: .done),
        DeviceDownloadProgress(name: "0002.wav", folder: "recordings", state: .downloading(bytesSent: 4_200_000, bytesTotal: 9_800_000)),
        DeviceDownloadProgress(name: "0003.wav", folder: "memo", state: .queued),
    ])
}
