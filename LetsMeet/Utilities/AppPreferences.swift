//
//  AppPreferences.swift
//  LetsMeet
//

import SwiftUI
import MapKit

/// The user's app-wide appearance preference, persisted via `@AppStorage`.
/// `.system` (the default) tracks the device's own setting; `.light`/`.dark`
/// explicitly override it.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` tells SwiftUI's `.preferredColorScheme` to defer to the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// The user's map rendering preference, persisted via `@AppStorage`. Only
/// changes the base map's tile style - independent of search/results state,
/// pins, routes, and camera position.
enum AppMapStyle: String, CaseIterable, Identifiable {
    case standard
    case satellite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .satellite: return "Satellite"
        }
    }

    /// `.satellite` maps to MapKit's `.hybrid()` rather than `.imagery()` so
    /// roads and place labels stay visible over the satellite imagery -
    /// `.imagery()` alone would strip the road context this app's routes and
    /// pins rely on.
    var mapStyle: MapStyle {
        switch self {
        case .standard: return .standard()
        case .satellite: return .hybrid()
        }
    }
}
