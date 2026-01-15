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
            .symbolRenderingMode(.hierarchical)
    }

    private var iconName: String {
        if state.isSyncing {
            return "arrow.triangle.2.circlepath"
        } else if state.isDeviceConnected {
            return "waveform.circle.fill"
        } else {
            return "waveform.circle"
        }
    }
}
