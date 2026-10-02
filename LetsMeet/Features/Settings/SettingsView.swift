//
//  SettingsView.swift
//  LetsMeet
//

import SwiftUI

/// Compact settings sheet for the app's two local V1 preferences: appearance
/// and map style. Both are read/written directly via `@AppStorage` - no
/// dedicated view model, since there's no behavior here beyond persisting a
/// selection.
struct SettingsView: View {
    @AppStorage("appAppearance") private var appAppearance: AppAppearance = .system
    @AppStorage("appMapStyle") private var mapStyle: AppMapStyle = .standard

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $appAppearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section("Map Style") {
                    Picker("Map Style", selection: $mapStyle) {
                        ForEach(AppMapStyle.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
