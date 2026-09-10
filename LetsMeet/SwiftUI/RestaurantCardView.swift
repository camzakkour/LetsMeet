//
//  RestaurantCardView.swift
//  LetsMeet
//

import SwiftUI
import UIKit

/// A single restaurant result: hero photo, name, rating/reviews, price, categories,
/// distance from the midpoint, and one primary action (Directions).
struct RestaurantCardView: View {
    let restaurant: Restaurant

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            heroImage

            Text(restaurant.name)
                .font(.headline)
                .foregroundColor(.primary)
                .lineLimit(2)

            metadataRow

            if !categoryText.isEmpty {
                Text(categoryText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            directionsButton
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
    }

    private var heroImage: some View {
        AsyncImage(url: restaurant.imageURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure, .empty:
                placeholderImage
            @unknown default:
                placeholderImage
            }
        }
        .frame(height: 180)
        .frame(maxWidth: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var placeholderImage: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(LetsMeetColor.lightBlue.opacity(0.15))
            .overlay(
                Image(systemName: "fork.knife")
                    .font(.system(size: 36))
                    .foregroundColor(LetsMeetColor.lightBlue)
            )
    }

    private var metadataRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill")
                .font(.caption)
                .foregroundColor(.yellow)
            Text(String(format: "%.1f", restaurant.rating))
                .font(.subheadline.bold())

            if let reviewCount = restaurant.reviewCount {
                Text("(\(reviewCount))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if let priceText {
                bulletSeparator
                Text(priceText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if let distanceText {
                bulletSeparator
                Text(distanceText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var bulletSeparator: some View {
        Text("•")
            .font(.subheadline)
            .foregroundColor(.secondary)
    }

    private var directionsButton: some View {
        Button(action: openDirections) {
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
        .padding(.top, 2)
    }

    private var categoryText: String {
        restaurant.categories.map(\.title).joined(separator: ", ")
    }

    private var priceText: String? {
        guard let price = restaurant.price, !price.isEmpty, price != "0" else { return nil }
        return price
    }

    private var distanceText: String? {
        guard let distance = restaurant.distance else { return nil }
        let miles = distance / 1609.34
        return String(format: "%.1f mi", miles)
    }

    /// Preserves the exact existing Direct Me -> Apple Maps behavior from
    /// DetailViewController.startDirections(address:): same URL scheme, same
    /// address source (the Yelp display_address joined with spaces).
    private func openDirections() {
        guard let address = restaurant.location?.display_address.joined(separator: " ") else { return }
        let encodedAddress = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let mapsURL = URL(string: "http://maps.apple.com/?address=\(encodedAddress)") else { return }
        UIApplication.shared.open(mapsURL)
    }
}
