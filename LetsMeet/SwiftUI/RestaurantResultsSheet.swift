//
//  RestaurantResultsSheet.swift
//  LetsMeet
//

import SwiftUI

/// The draggable results sheet presented over HomeMapView once Yelp results load:
/// a vertically-scrolling list of restaurant cards between the meeting parties.
struct RestaurantResultsSheet: View {
    let restaurants: [Restaurant]

    var body: some View {
        VStack(spacing: 0) {
            header

            if restaurants.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(restaurants) { restaurant in
                            RestaurantCardView(restaurant: restaurant)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
        .background(Color(.systemBackground))
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
