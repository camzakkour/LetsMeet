//
//  HomeMapView.swift
//  LetsMeet
//

import SwiftUI
import MapKit

struct HomeMapView: View {

    @ObservedObject var viewModel: HomeViewModel
    @StateObject private var locationProvider = LocationProvider()

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )
    @State private var hasCenteredOnUser = false
    @State private var resultsDetent: PresentationDetent = .medium

    var body: some View {
        ZStack(alignment: .top) {
            Map(coordinateRegion: $region, showsUserLocation: true, annotationItems: mappableRestaurants) { restaurant in
                MapAnnotation(coordinate: restaurant.coordinate!) {
                    RestaurantMapPin()
                }
            }
            .ignoresSafeArea()

            brandingBadge
                .padding(.top, 8)

            if !viewModel.isShowingResults {
                VStack {
                    Spacer()
                    bottomCard
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: viewModel.isShowingResults)
        .onAppear { locationProvider.requestLocation() }
        .onChange(of: locationProvider.currentCoordinate?.latitude) { _ in
            recenterOnUserIfNeeded()
        }
        .onChange(of: viewModel.restaurants) { _ in
            fitMapToRestaurants()
        }
        .alert(
            viewModel.errorTitle,
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { isPresented in if !isPresented { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(isPresented: $viewModel.isShowingResults) {
            RestaurantResultsSheet(restaurants: viewModel.restaurants)
                .presentationDetents([.medium, .large], selection: $resultsDetent)
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
    }

    /// Restaurants Yelp returned coordinates for - annotationItems/MapAnnotation
    /// both need a concrete, non-optional coordinate per item.
    private var mappableRestaurants: [Restaurant] {
        viewModel.restaurants.filter { $0.coordinate != nil }
    }

    /// Frames the map around the recommended restaurants (plus the midpoint and
    /// the user's own location, when available) using MapKit's own coordinate/
    /// region types rather than a hard-coded zoom level. The center is nudged
    /// south so the fitted area renders in the upper portion of the screen,
    /// since the medium results sheet covers roughly the bottom half.
    private func fitMapToRestaurants() {
        let coordinates = mappableRestaurants.map(\.coordinate!)
        guard !coordinates.isEmpty else { return }

        var mapRect = MKMapRect.null
        for coordinate in coordinates {
            let point = MKMapPoint(coordinate)
            mapRect = mapRect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        if let midpoint = YelpManager.shared.midPoint?.coordinate {
            let point = MKMapPoint(midpoint)
            mapRect = mapRect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        // Include the user's own location so the blue location indicator stays
        // visible on screen once the camera reframes to the restaurant area.
        if let userCoordinate = locationProvider.currentCoordinate {
            let point = MKMapPoint(userCoordinate)
            mapRect = mapRect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }

        var fitted = MKCoordinateRegion(mapRect)
        fitted.span.latitudeDelta = max(fitted.span.latitudeDelta * 1.5, 0.01)
        fitted.span.longitudeDelta = max(fitted.span.longitudeDelta * 1.5, 0.01)
        fitted.center.latitude -= fitted.span.latitudeDelta * 0.28

        region = fitted
    }

    private func recenterOnUserIfNeeded() {
        guard !hasCenteredOnUser, let coordinate = locationProvider.currentCoordinate else { return }
        hasCenteredOnUser = true
        region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
    }

    private var brandingBadge: some View {
        Text("Let's Meet")
            .font(.headline)
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(LetsMeetColor.lightBlue)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
    }

    private var bottomCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Who are you meeting?")
                    .font(.title3.bold())
                Text("Add your friend's address or location.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundColor(LetsMeetColor.orange)
                TextField("Friend's address", text: $viewModel.addressText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
            }
            .padding(12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 8) {
                Image(systemName: "location.fill")
                    .foregroundColor(LetsMeetColor.lightBlue)
                Text("Your location: Current Location")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
            }

            Button(action: viewModel.findAPlace) {
                HStack(spacing: 8) {
                    if viewModel.isSearching {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "fork.knife.circle.fill")
                        Text("Find a place")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .background(LetsMeetColor.lightBlue)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(LetsMeetColor.orange, lineWidth: 2)
            )
            .disabled(viewModel.isSearching)
        }
        .padding(20)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }
}

/// A simple, brand-colored pin marking one recommended restaurant on the map.
/// All restaurant pins share this same design for this pass.
private struct RestaurantMapPin: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            Image(systemName: "fork.knife.circle.fill")
                .font(.system(size: 26))
                .foregroundColor(LetsMeetColor.orange)
        }
    }
}
