//
//  SettingsView.swift
//  TeenageEngVoiceSync
//
//  Main settings container with tabs.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            StorageSettingsView()
                .tabItem {
                    Label("Storage", systemImage: "externaldrive")
                }

            APIKeysSettingsView()
                .tabItem {
                    Label("API Keys", systemImage: "key")
                }

            TranscriptionSettingsView()
                .tabItem {
                    Label("Transcription", systemImage: "text.bubble")
                }

            AdvancedSettingsView()
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
        }
        .frame(width: 550, height: 500)
    }
}

#Preview {
    SettingsView()
}
