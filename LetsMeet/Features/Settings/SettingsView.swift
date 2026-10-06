//
//  SettingsView.swift
//  LetsMeet
//

import SwiftUI

/// Compact settings sheet for the app's two local V1 preferences: appearance
/// and map type. Both are read/written directly via `@AppStorage` - no
/// dedicated view model, since there's no behavior here beyond persisting a
/// selection. The visual cards below only change how a choice is presented;
/// tapping one writes the same stored value the old segmented pickers did.
struct SettingsView: View {
    @AppStorage("appAppearance") private var appAppearance: AppAppearance = .system
    @AppStorage("appMapStyle") private var mapStyle: AppMapStyle = .standard

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Preview sizes for the side-by-side layout, scaled with Dynamic Type.
    /// The accessibility-size row layout uses fixed sizes instead.
    @ScaledMetric(relativeTo: .body) private var swatchDiameter: CGFloat = 52
    @ScaledMetric(relativeTo: .body) private var mapPreviewHeight: CGFloat = 88

    private var usesRowLayout: Bool { dynamicTypeSize.isAccessibilitySize }
    private var cardLayout: SettingsCardLayout { usesRowLayout ? .row : .stacked }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    appearanceSection
                    mapTypeSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    private var appearanceSection: some View {
        section("Appearance") {
            ForEach(AppAppearance.allCases) { option in
                SettingsOptionCard(
                    title: option.cardTitle,
                    subtitle: option.cardSubtitle,
                    accessibilityLabel: option.cardAccessibilityLabel,
                    isSelected: appAppearance == option,
                    layout: cardLayout,
                    previewWidth: usesRowLayout ? 64 : nil,
                    previewHeight: usesRowLayout ? 52 : swatchDiameter,
                    action: { appAppearance = option }
                ) {
                    AppearanceSwatch(appearance: option, diameter: usesRowLayout ? 52 : swatchDiameter)
                }
            }
        }
    }

    private var mapTypeSection: some View {
        section("Map Type") {
            ForEach(AppMapStyle.allCases) { option in
                SettingsOptionCard(
                    title: option.title,
                    subtitle: nil,
                    accessibilityLabel: option.title,
                    isSelected: mapStyle == option,
                    layout: cardLayout,
                    previewWidth: usesRowLayout ? 88 : nil,
                    previewHeight: usesRowLayout ? 58 : mapPreviewHeight,
                    action: { mapStyle = option }
                ) {
                    MapStylePreview(style: option)
                }
            }
        }
    }

    /// A headed group of option cards: side by side at normal text sizes,
    /// stacked full-width at accessibility sizes so labels never get cramped.
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder cards: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if usesRowLayout {
                VStack(spacing: 12) { cards() }
            } else {
                HStack(alignment: .top, spacing: 12) { cards() }
            }
        }
    }
}

// MARK: - Presentation of the appearance preference

/// User-facing wording only. The stored values (`system` / `light` / `dark`)
/// and `AppAppearance.title` are untouched; "System" is simply presented as
/// "Automatic" here.
private extension AppAppearance {
    var cardTitle: String {
        switch self {
        case .system: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var cardSubtitle: String? {
        switch self {
        case .system: return "Matches iPhone"
        case .light, .dark: return nil
        }
    }

    var cardAccessibilityLabel: String {
        switch self {
        case .system: return "Automatic, matches iPhone"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

// MARK: - Option card

private enum SettingsCardLayout {
    /// Preview above the label, for the side-by-side layout.
    case stacked
    /// Preview beside the label, full width, for accessibility text sizes.
    case row
}

/// One selectable choice: a preview, a label, and a selected treatment (blue
/// outline plus a checkmark, so selection is never color alone). The selection
/// outline is drawn inside the card's bounds, so selecting never shifts layout.
private struct SettingsOptionCard<Preview: View>: View {
    let title: String
    let subtitle: String?
    let accessibilityLabel: String
    let isSelected: Bool
    let layout: SettingsCardLayout
    /// Fixed preview width in the row layout; nil lets it fill the card.
    let previewWidth: CGFloat?
    let previewHeight: CGFloat
    let action: () -> Void
    @ViewBuilder let preview: Preview

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let cornerRadius: CGFloat = 16

    var body: some View {
        Button(action: action) {
            content
                .padding(10)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: layout == .stacked ? .infinity : nil,
                    alignment: layout == .stacked ? .top : .leading
                )
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            isSelected ? LetsMeetColor.lightBlue : Color(.separator),
                            lineWidth: isSelected ? 3 : 1
                        )
                )
                .overlay(alignment: layout == .stacked ? .topTrailing : .trailing) {
                    checkmark
                        .padding(layout == .stacked ? 6 : 14)
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .stacked:
            VStack(spacing: 8) {
                preview
                    .frame(maxWidth: .infinity)
                    .frame(height: previewHeight)
                    .accessibilityHidden(true)
                labels
            }
        case .row:
            HStack(spacing: 12) {
                preview
                    .frame(width: previewWidth, height: previewHeight)
                    .accessibilityHidden(true)
                labels
                // Keeps text clear of the trailing checkmark.
                Spacer(minLength: 20)
            }
        }
    }

    private var labels: some View {
        VStack(alignment: layout == .stacked ? .center : .leading, spacing: 2) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(layout == .stacked ? .center : .leading)
        .frame(maxWidth: layout == .stacked ? .infinity : nil, alignment: layout == .stacked ? .center : .leading)
    }

    private var checkmark: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 22))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, LetsMeetColor.lightBlue)
            .opacity(isSelected ? 1 : 0)
            .scaleEffect(isSelected ? 1 : 0.6)
            .accessibilityHidden(true)
    }
}

// MARK: - Appearance previews

/// A circular swatch for one appearance choice. Uses fixed colors rather than
/// semantic ones, so "Light" always looks light and "Dark" always looks dark,
/// whichever appearance the app is currently in.
private struct AppearanceSwatch: View {
    let appearance: AppAppearance
    let diameter: CGFloat

    private let lightFill = Color(white: 0.97)
    private let darkFill = Color(white: 0.10)

    var body: some View {
        ZStack {
            switch appearance {
            case .light:
                Circle().fill(lightFill)
                sun(size: diameter * 0.42)
            case .dark:
                Circle().fill(darkFill)
                moon(size: diameter * 0.40)
            case .system:
                Circle().fill(lightFill)
                // A half disc, rotated so the split runs top-right to
                // bottom-left: light upper-left, dark lower-right.
                Circle()
                    .trim(from: 0, to: 0.5)
                    .fill(darkFill)
                    .rotationEffect(.degrees(-45))
                sun(size: diameter * 0.28)
                    .offset(x: -diameter * 0.17, y: -diameter * 0.17)
                moon(size: diameter * 0.26)
                    .offset(x: diameter * 0.17, y: diameter * 0.17)
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().strokeBorder(Color.gray.opacity(0.45), lineWidth: 1))
    }

    private func sun(size: CGFloat) -> some View {
        Image(systemName: "sun.max.fill")
            .font(.system(size: size))
            .foregroundStyle(LetsMeetColor.orange)
    }

    private func moon(size: CGFloat) -> some View {
        Image(systemName: "moon.fill")
            .font(.system(size: size))
            .foregroundStyle(Color(white: 0.95))
    }
}

// MARK: - Map type previews

/// Small thumbnails of each map type. Standard is a static SwiftUI drawing and
/// Satellite a bundled aerial photo: no MapKit, so no tile requests. Both are
/// fixed artwork, so each preview stays recognizable in Light and Dark.
private struct MapStylePreview: View {
    let style: AppMapStyle

    var body: some View {
        Group {
            switch style {
            case .standard: StandardMapIllustration()
            case .satellite: SatelliteMapPhoto()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
        )
    }
}

/// Aerial photo, aspect-filled and cropped to the preview frame. The clear
/// base takes the frame's size so the image's own size never affects layout.
private struct SatelliteMapPhoto: View {
    var body: some View {
        Color.clear
            .overlay(
                Image("SatelliteMapPreview")
                    .resizable()
                    .scaledToFill()
            )
            .clipped()
    }
}

/// A pale road map: street grid, a park, a bit of water, a few main roads.
private struct StandardMapIllustration: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }

            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(red: 0.95, green: 0.93, blue: 0.89))
            )

            // Minor streets, slightly off-grid so it reads as a real street plan.
            var minor = Path()
            for x in [0.14, 0.36, 0.60, 0.84] as [CGFloat] {
                minor.move(to: p(x, 0))
                minor.addLine(to: p(x + 0.04, 1))
            }
            for y in [0.20, 0.48, 0.76] as [CGFloat] {
                minor.move(to: p(0, y))
                minor.addLine(to: p(1, y - 0.04))
            }
            context.stroke(minor, with: .color(.white), lineWidth: 2)

            // Water, top right.
            var water = Path()
            water.move(to: p(0.60, 0))
            water.addCurve(to: p(1, 0.50), control1: p(0.68, 0.26), control2: p(0.88, 0.32))
            water.addLine(to: p(1, 0))
            water.closeSubpath()
            context.fill(water, with: .color(Color(red: 0.66, green: 0.82, blue: 0.95)))

            // Park, bottom left.
            context.fill(
                Path(roundedRect: CGRect(x: 0.05 * w, y: 0.56 * h, width: 0.30 * w, height: 0.34 * h), cornerRadius: 6),
                with: .color(Color(red: 0.77, green: 0.89, blue: 0.70))
            )

            // Main roads: gray casing under white fill.
            var main = Path()
            main.move(to: p(0, 0.92))
            main.addLine(to: p(0.70, 0.52))
            main.addLine(to: p(1, 0.66))
            main.move(to: p(0.48, 0))
            main.addLine(to: p(0.52, 1))
            context.stroke(main, with: .color(Color(white: 0.80)), lineWidth: 6.5)
            context.stroke(main, with: .color(.white), lineWidth: 5)

            // One highway in amber.
            var highway = Path()
            highway.move(to: p(0, 0.36))
            highway.addCurve(to: p(1, 0.84), control1: p(0.40, 0.30), control2: p(0.62, 0.86))
            context.stroke(highway, with: .color(Color(red: 0.86, green: 0.62, blue: 0.22)), lineWidth: 6.5)
            context.stroke(highway, with: .color(Color(red: 0.98, green: 0.80, blue: 0.45)), lineWidth: 5)
        }
    }
}
