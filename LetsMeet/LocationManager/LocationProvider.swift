//
//  LocationProvider.swift
//  LetsMeet
//

import Foundation
import CoreLocation
#if DEBUG
import os.log
#endif

/// SwiftUI-facing wrapper around CLLocationManager. Handles permission
/// requests and location updates, publishes a `LocationAvailability` the UI can
/// act on, and feeds YelpManager.shared.currentUserLocation as the single
/// source of truth for the user's location.
///
/// `start()` is idempotent and safe to call repeatedly (launch, app
/// foregrounding, a retry), so a change made while the app is running -
/// permission granted, Location Services turned back on - is picked up the
/// next time it runs instead of requiring a relaunch.
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {

    #if DEBUG
    private static let logger = Logger(subsystem: "com.letsmeet.app", category: "Location")
    #endif

    private let locationManager = CLLocationManager()

    @Published var currentCoordinate: CLLocationCoordinate2D?
    @Published private(set) var availability: LocationAvailability = .notDetermined

    private var hasUsableFix = false
    private var hasFailure = false
    /// Invalidates an in-flight Location Services check when a newer one starts.
    private var servicesCheckGeneration = 0

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Requests permission if it hasn't been asked yet, starts updates when
    /// authorized, and refreshes `availability`. Idempotent.
    func start() {
        let status = locationManager.authorizationStatus
        #if DEBUG
        Self.logger.log("[Location] start() status=\(Self.describe(status))")
        #endif

        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if LocationAvailabilityLogic.isAuthorized(status) {
            locationManager.startUpdatingLocation()
        }
        refreshAvailability()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        #if DEBUG
        Self.logger.log("[Location] authorization changed status=\(Self.describe(status))")
        #endif

        if LocationAvailabilityLogic.isAuthorized(status) {
            hasFailure = false
            manager.startUpdatingLocation()
        } else if status == .denied || status == .restricted {
            // Never let a fix captured before the permission was revoked keep
            // seeding searches.
            manager.stopUpdatingLocation()
            clearFix()
        }
        refreshAvailability()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard LocationAvailabilityLogic.isAuthorized(manager.authorizationStatus) else { return }
        guard let fix = LocationAvailabilityLogic.usableFix(from: locations) else {
            #if DEBUG
            if let newest = locations.last {
                Self.logger.log("[Location] REJECTED fix accuracy=\(newest.horizontalAccuracy)m age=\(Date().timeIntervalSince(newest.timestamp))s")
            }
            #endif
            return
        }

        currentCoordinate = fix.coordinate
        YelpManager.shared.currentUserLocation = fix
        hasUsableFix = true
        hasFailure = false
        #if DEBUG
        Self.logger.log("[Location] ACCEPTED fix accuracy=\(fix.horizontalAccuracy)m age=\(Date().timeIntervalSince(fix.timestamp))s")
        #endif
        refreshAvailability()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        #if DEBUG
        Self.logger.log("[Location] didFailWithError: \(String(describing: error))")
        #endif

        if let clError = error as? CLError {
            switch clError.code {
            case .locationUnknown:
                // Transient: CoreLocation keeps trying on its own.
                return
            case .denied:
                // The authorization callback is the authority on permission.
                refreshAvailability()
                return
            default:
                break
            }
        }

        if !hasUsableFix { hasFailure = true }
        refreshAvailability()
    }

    // MARK: - Availability

    private func clearFix() {
        currentCoordinate = nil
        YelpManager.shared.currentUserLocation = nil
        hasUsableFix = false
        hasFailure = false
    }

    /// Recomputes `availability`. `.denied` additionally needs
    /// `locationServicesEnabled()` to tell a per-app refusal from Location
    /// Services being off globally; that call can block, so it runs off the
    /// main thread and only on this rare path. The provisional `.denied` it
    /// publishes first is refined once the check returns - except when already
    /// `.servicesDisabled`, which is kept as-is so it never flickers to
    /// `.denied` while the check is in flight.
    private func refreshAvailability() {
        let status = locationManager.authorizationStatus
        servicesCheckGeneration += 1
        let generation = servicesCheckGeneration

        if !(status == .denied && availability == .servicesDisabled) {
            setAvailability(LocationAvailabilityLogic.resolve(
                status: status,
                servicesEnabled: true,
                hasUsableFix: hasUsableFix,
                hasFailure: hasFailure
            ))
        }

        guard status == .denied else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let servicesEnabled = CLLocationManager.locationServicesEnabled()
            DispatchQueue.main.async {
                guard let self = self, generation == self.servicesCheckGeneration else { return }
                self.setAvailability(LocationAvailabilityLogic.resolve(
                    status: self.locationManager.authorizationStatus,
                    servicesEnabled: servicesEnabled,
                    hasUsableFix: self.hasUsableFix,
                    hasFailure: self.hasFailure
                ))
            }
        }
    }

    private func setAvailability(_ newValue: LocationAvailability) {
        guard newValue != availability else { return }
        #if DEBUG
        Self.logger.log("[Location] availability \(String(describing: self.availability)) -> \(String(describing: newValue))")
        #endif
        availability = newValue
    }

    #if DEBUG
    private static func describe(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown"
        }
    }
    #endif
}
