//
//  RestaurantResultsSheet.swift
//  LetsMeet
//

import SwiftUI

/// The draggable results sheet presented over HomeMapView once Yelp results load:
/// a vertically-scrolling list of restaurant cards between the meeting parties.
///
/// Always renders the same header + scrolling card list regardless of the
/// sheet's detent. At the small peek detent, the sheet's own height simply
/// clips this content so only the header and the top of the first card show
/// through - there is no separate condensed layout to swap in and out.
struct RestaurantResultsSheet: View {
    let restaurants: [Restaurant]

    /// Whether the sheet is at its `.large` detent. While false (peeked),
    /// the list's own ScrollView is disabled so vertical drags go to the
    /// sheet's native resize gesture instead of scrolling content - without
    /// this, iOS only hands drags to the sheet once the ScrollView's
    /// content offset is back at the top, which made peek/collapse feel
    /// inconsistent depending on prior scroll position.
    let isExpanded: Bool

    /// Whether the search that produced `restaurants` is still refining
    /// results in the background (progressive delivery). Drives a subtle
    /// trailing loading row - removed the instant the search reaches its
    /// terminal outcome, regardless of how it resolves.
    let isSearchInProgress: Bool

    /// Which restaurant's expanded ("More Info") section is open, if any -
    /// at most one at a time. Deliberately NOT reset when `isExpanded`
    /// toggles (the sheet's own peek/large detent): collapsing the sheet to
    /// look at the map and reopening it restores the same expanded card -
    /// its content is simply clipped out of view while peeked, same as the
    /// rest of this sheet's content. This View's identity is stable across
    /// those detent changes (same call site in HomeMapView's `.sheet`), so
    /// plain `@State` already persists correctly without extra plumbing.
    @State private var expandedRestaurantID: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            if restaurants.isEmpty {
                emptyState
            } else {
                fullList
            }
        }
        .background(Color(.systemBackground))
    }

    private var fullList: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(restaurants) { restaurant in
                    RestaurantCardView(
                        restaurant: restaurant,
                        isExpanded: expandedRestaurantID == restaurant.id,
                        onToggleExpand: { toggleExpansion(for: restaurant.id) }
                    )
                }
                if isSearchInProgress {
                    loadingRow
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollDisabled(!isExpanded)
    }

    private func toggleExpansion(for id: String) {
        expandedRestaurantID = (expandedRestaurantID == id) ? nil : id
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Finding more options…")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Restaurants near your midpoint")
                .font(.title3.bold())
            Text("\(restaurants.count) place\(restaurants.count == 1 ? "" : "s") found")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "fork.knife.circle")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No restaurants found near your midpoint.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}
