//
//  LocationProvider.swift
//  LetsMeet
//

import Foundation
import CoreLocation

/// SwiftUI-facing wrapper around CLLocationManager. Handles permission
/// requests and location updates, and feeds
/// YelpManager.shared.currentUserLocation as the single source of truth
/// for the user's location.
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {

    private let locationManager = CLLocationManager()

    @Published var currentCoordinate: CLLocationCoordinate2D?
    @Published var isLocationDenied = false

    override init() {
        super.init()
        locationManager.delegate = self
    }

    func requestLocation() {
        locationManager.requestAlwaysAuthorization()

        if CLLocationManager.locationServicesEnabled() {
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else { return }
        currentCoordinate = location.coordinate
        YelpManager.shared.currentUserLocation = location
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if status == .denied {
            isLocationDenied = true
        }
    }
}
