//
//  RestaurantCardView.swift
//  LetsMeet
//

import SwiftUI
import UIKit

/// Yelp branding constants and asset lookup (assets under `Yelp/` in
/// Assets.xcassets are Yelp's official, unmodified files).
private enum YelpBranding {
    static let logoHeight: CGFloat = 15

    /// Yelp's star sprites exist for 0...5 in half-star steps, which is also
    /// the granularity of the rating the API returns; anything else snaps to
    /// the nearest half star and out-of-range values clamp.
    static func starsAssetName(for rating: Double) -> String {
        let steps = ["0", "0_5", "1", "1_5", "2", "2_5", "3", "3_5", "4", "4_5", "5"]
        let halfStars = Int((min(5, max(0, rating)) * 2).rounded())
        return "YelpStars_" + steps[halfStars]
    }
}

/// The "Let's Meet decision card" for one restaurant: hero photo, name,
/// rating/reviews/price, real bidirectional travel info for You/Friend,
/// address, a Directions action (with a map-app chooser when more than one
/// is available), and an expandable section with phone/Yelp link. Only one
/// card's expanded section can be open at a time - `isExpanded` and
/// `onToggleExpand` are driven by `RestaurantResultsSheet`.
struct RestaurantCardView: View {
    let restaurant: Restaurant
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    @State private var businessDetails: BusinessDetails?
    @State private var didStartDetailsFetch = false
    @State private var detailsFetchCompleted = false
    @State private var isShowingMapChooser = false
    @State private var showAddressCopiedConfirmation = false
    @State private var addressCopyToken = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RestaurantPhotoGalleryView(businessID: restaurant.id, fallbackImageURL: restaurant.imageURL)

            nameRow

            metadataLine
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.tail)

            if let travelInfo = restaurant.travelInfo {
                travelInfoRow(travelInfo)
            }

            if let addressText {
                addressRow(addressText)
            }

            actionButtons

            if isExpanded {
                expandedDetails
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
        .onAppear(perform: fetchDetailsIfNeeded)
    }

    // MARK: - Name / share

    private var nameRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(restaurant.name)
                .font(.headline)
                .foregroundColor(.primary)
                .lineLimit(2)

            Spacer(minLength: 8)

            HStack(spacing: 14) {
                yelpLogo
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share restaurant")
            }
        }
    }

    /// Yelp's official logo (light/dark variants come from the asset
    /// catalog), required wherever Yelp content is shown. Links to this
    /// restaurant's Yelp page once the Business Details request has returned
    /// its URL; until then it simply isn't tappable.
    @ViewBuilder
    private var yelpLogo: some View {
        let logo = Image("YelpLogo")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(height: YelpBranding.logoHeight)
            .fixedSize()
        if let yelpURL = businessDetails?.yelpURL {
            Link(destination: yelpURL) { logo }
                .contentShape(Rectangle().inset(by: -6))
                .accessibilityLabel("Yelp")
                .accessibilityHint("Opens this restaurant on Yelp")
        } else {
            logo.accessibilityLabel("Yelp")
        }
    }

    /// Name, full address (if known), and the Yelp business page URL (if
    /// known) - deliberately never the current user's/friend's locations,
    /// ETA, or distance, since those are specific to this search and would
    /// be confusing to whoever receives the share. Degrades gracefully: a
    /// restaurant with no address and no Yelp URL yet still shares its name.
    private var shareText: String {
        var lines = [restaurant.name]
        if let addressText {
            lines.append(addressText)
        }
        if let yelpURL = businessDetails?.yelpURL {
            lines.append(yelpURL.absoluteString)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Metadata / travel info

    /// Yelp's branded star rating and review count, then price and categories
    /// on a single line. The rating group never shrinks; only the trailing
    /// price/categories text truncates with an ellipsis rather than wrapping.
    /// Each trailing piece is only included when present, so a missing price
    /// or category list never leaves behind a dangling "·" separator.
    private var metadataLine: some View {
        HStack(spacing: 6) {
            ratingSummary
            if !priceAndCategoryText.isEmpty {
                Text("· \(priceAndCategoryText)")
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var priceAndCategoryText: String {
        [priceText, categoryText.isEmpty ? nil : categoryText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Yelp requires its own branded stars (never a generic star) shown
    /// beside the review count they're based on, linking to the business's
    /// Yelp page. Tappable only once the Yelp URL has arrived.
    @ViewBuilder
    private var ratingSummary: some View {
        let summary = HStack(spacing: 5) {
            Image(YelpBranding.starsAssetName(for: restaurant.rating))
                .renderingMode(.original)
                .fixedSize()
            if let reviewCount = restaurant.reviewCount {
                Text("(\(reviewCount))")
                    .foregroundColor(.secondary)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ratingAccessibilityLabel)

        if let yelpURL = businessDetails?.yelpURL {
            Link(destination: yelpURL) { summary }
        } else {
            summary
        }
    }

    private var ratingAccessibilityLabel: String {
        let rating = String(format: "%.1f", restaurant.rating)
        guard let reviewCount = restaurant.reviewCount else {
            return "Rated \(rating) out of 5 on Yelp"
        }
        return "Rated \(rating) out of 5 on Yelp, \(reviewCount) review\(reviewCount == 1 ? "" : "s")"
    }

    /// Real bidirectional travel info, from the same MapKit routes already
    /// gathered during fairness verification - the headline reason this
    /// card exists, so it sits ahead of the secondary restaurant metadata
    /// above in visual weight even though it's laid out below it.
    private func travelInfoRow(_ info: Restaurant.TravelInfo) -> some View {
        HStack(alignment: .top, spacing: 14) {
            travelBadge(label: "You", eta: info.userETA, distanceMeters: info.userDistanceMeters, color: LetsMeetColor.lightBlue)
                .frame(maxWidth: .infinity, alignment: .leading)
            travelBadge(label: "Friend", eta: info.friendETA, distanceMeters: info.friendDistanceMeters, color: LetsMeetColor.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Label on its own line, "<eta> · <distance>" below it - rather than one
    /// long horizontal line - so a longer "1 hr 4 min · 65.9 mi" string (once
    /// ETAs cross 60 minutes) has a full half-card-width line to itself and
    /// can't crowd into the other badge or clip.
    private func travelBadge(label: String, eta: TimeInterval, distanceMeters: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.caption.bold())
                    .foregroundColor(color)
            }
            Text("\(etaText(eta)) · \(travelDistanceText(meters: distanceMeters))")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    /// Tapping the row copies the FULL address (never the visually-truncated
    /// line) to the clipboard and briefly swaps the row's own text/icon for a
    /// confirmation, reverting automatically - no separate Copy button and no
    /// persistent UI change. `addressCopyToken` guards the revert so rapid
    /// repeat taps don't let an earlier timer clear a later tap's confirmation.
    private func addressRow(_ text: String) -> some View {
        Button {
            copyAddress(text)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: showAddressCopiedConfirmation ? "checkmark.circle.fill" : "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundColor(showAddressCopiedConfirmation ? LetsMeetColor.lightBlue : .secondary)
                Text(showAddressCopiedConfirmation ? "Address Copied" : text)
                    .font(.caption)
                    .foregroundColor(showAddressCopiedConfirmation ? LetsMeetColor.lightBlue : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showAddressCopiedConfirmation ? "Address copied" : "Address: \(text)")
        .accessibilityHint(showAddressCopiedConfirmation ? "" : "Double tap to copy address")
        .accessibilityAddTraits(.isButton)
    }

    private func copyAddress(_ text: String) {
        UIPasteboard.general.string = text
        let token = UUID()
        addressCopyToken = token
        withAnimation {
            showAddressCopiedConfirmation = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard addressCopyToken == token else { return }
            withAnimation {
                showAddressCopiedConfirmation = false
            }
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 10) {
            if !availableMapApps.isEmpty {
                directionsButton
            }
            moreInfoButton
        }
    }

    private var directionsButton: some View {
        Button(action: handleDirectionsTap) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                Text("Directions")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .background(LetsMeetColor.lightBlue)
        .foregroundColor(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(LetsMeetColor.orange, lineWidth: 1.5)
        )
        .confirmationDialog("Get Directions", isPresented: $isShowingMapChooser, titleVisibility: .visible) {
            ForEach(availableMapApps) { app in
                Button(app.title) { app.open(for: restaurant) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var moreInfoButton: some View {
        Button(action: onToggleExpand) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                Text(isExpanded ? "Less Info" : "More Info")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .background(Color(.tertiarySystemFill))
        .foregroundColor(.primary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Opens directly when exactly one map app is available (always true
    /// unless Google Maps and/or Waze are also installed) rather than
    /// presenting a one-item chooser.
    private func handleDirectionsTap() {
        let apps = availableMapApps
        guard let onlyApp = apps.first, apps.count == 1 else {
            isShowingMapChooser = true
            return
        }
        onlyApp.open(for: restaurant)
    }

    private var availableMapApps: [MapApp] {
        MapApp.allCases.filter { $0.isAvailable(for: restaurant) }
    }

    // MARK: - Expanded details (phone / Yelp link)

    /// Phone and the Yelp business page URL - decoded from the same Business
    /// Details request `RestaurantPhotoGalleryView` already fires for
    /// photos, so this is almost always an instant cache hit, never a
    /// second network request. Yelp does not provide the restaurant's own
    /// independent website, so there is no Website action here.
    @ViewBuilder
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            if detailsFetchCompleted {
                if let phone = businessDetails?.displayPhone, let phoneURL = telURL(for: phone) {
                    phoneRow(phone: phone, url: phoneURL)
                }
                if let yelpURL = businessDetails?.yelpURL {
                    yelpLinkRow(yelpURL)
                }
                if businessDetails?.displayPhone == nil && businessDetails?.yelpURL == nil {
                    Text("No additional details available.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading details…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }

    private func phoneRow(phone: String, url: URL) -> some View {
        Button {
            UIApplication.shared.open(url)
        } label: {
            Label(phone, systemImage: "phone.fill")
                .font(.subheadline)
        }
        .foregroundColor(LetsMeetColor.lightBlue)
    }

    private func yelpLinkRow(_ url: URL) -> some View {
        Link(destination: url) {
            Label("View on Yelp", systemImage: "link")
                .font(.subheadline)
        }
        .foregroundColor(LetsMeetColor.lightBlue)
    }

    private func fetchDetailsIfNeeded() {
        guard !didStartDetailsFetch else { return }
        didStartDetailsFetch = true
        YelpManager.shared.fetchBusinessDetails(forBusinessID: restaurant.id) { result in
            DispatchQueue.main.async {
                businessDetails = try? result.get()
                detailsFetchCompleted = true
            }
        }
    }

    private func telURL(for phone: String) -> URL? {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel:\(digits)")
    }

    // MARK: - Formatting

    private var categoryText: String {
        restaurant.categories.map(\.title).joined(separator: ", ")
    }

    private var priceText: String? {
        guard let price = restaurant.price, !price.isEmpty, price != "0" else { return nil }
        return price
    }

    private var addressText: String? {
        guard let address = restaurant.location?.display_address, !address.isEmpty else { return nil }
        return address.joined(separator: ", ")
    }

    /// Formatting only - the underlying ETA value is untouched. Minutes under
    /// an hour read as before ("18 min"); 60+ switches to "<hr> hr[ <min> min]"
    /// since the travel badges have limited horizontal space for "hour(s)".
    private func etaText(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(1, Int((seconds / 60).rounded()))
        guard totalMinutes >= 60 else { return "\(totalMinutes) min" }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        guard minutes > 0 else { return "\(hours) hr" }
        return "\(hours) hr \(minutes) min"
    }

    private func travelDistanceText(meters: Double) -> String {
        let miles = meters / 1609.34
        return String(format: "%.1f mi", miles)
    }
}
