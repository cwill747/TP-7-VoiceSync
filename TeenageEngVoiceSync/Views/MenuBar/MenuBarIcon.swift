//
//  MenuBarIcon.swift
//  TeenageEngVoiceSync
//
//  Menu bar status icon.
//

import SwiftUI

struct MenuBarIcon: View {
    let state: AppState

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(hasError ? .multicolor : .hierarchical)
            .foregroundStyle(hasError ? .red : .primary)
    }

    private var hasError: Bool {
        state.lastError != nil
    }

    private var iconName: String {
        if hasError {
            return "exclamationmark.circle.fill"
        } else if state.isSyncing {
            return "arrow.triangle.2.circlepath"
        } else if state.isDeviceConnected {
            return "waveform.circle.fill"
        } else {
            return "waveform.circle"
        }
    }
}
