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
                    RestaurantCardView(restaurant: restaurant)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollDisabled(!isExpanded)
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
