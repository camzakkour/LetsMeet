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

    var body: some View {
        ZStack(alignment: .top) {
            Map(coordinateRegion: $region, showsUserLocation: true)
                .ignoresSafeArea()

            brandingBadge
                .padding(.top, 8)

            VStack {
                Spacer()
                bottomCard
            }
        }
        .onAppear { locationProvider.requestLocation() }
        .onChange(of: locationProvider.currentCoordinate?.latitude) { _ in
            recenterOnUserIfNeeded()
        }
        .alert(
            "Invalid Address",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { isPresented in if !isPresented { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
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
