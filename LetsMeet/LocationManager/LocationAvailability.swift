//
//  LocationAvailability.swift
//  LetsMeet
//

import Foundation
import CoreLocation

/// What the app can currently do about the user's location. Derived (never
/// stored piecemeal) from the authorization status, the global Location
/// Services switch, and whether a usable fix has arrived.
enum LocationAvailability: Equatable {
    /// The permission prompt hasn't been answered yet.
    case notDetermined
    /// Location Services are switched off for the whole device.
    case servicesDisabled
    /// The user declined location access for this app.
    case denied
    /// Screen Time / device management blocks location; the user can't change it.
    case restricted
    /// Authorized, but no usable fix has arrived yet.
    case acquiring
    /// Authorized, but CoreLocation reported a real error and there is no fix.
    case failed
    /// Authorized and a usable fix is available.
    case available
}

/// Pure decision logic for `LocationProvider`. No CLLocationManager, no UI, no
/// singletons - only plain values - so it can be compiled and exercised
/// directly by `Scripts/location_logic_tests.swift`.
enum LocationAvailabilityLogic {

    /// A fix older than this is treated as cached/stale (CoreLocation commonly
    /// hands back a cached location immediately after updates start).
    static let maximumFixAge: TimeInterval = 60

    /// A fix less precise than this is rejected as not good enough to seed a
    /// meeting-point search. Adjust here if it proves too strict in practice.
    static let maximumHorizontalAccuracyMeters: CLLocationAccuracy = 1000

    static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    /// True when `location` is valid, fresh, and accurate enough to use.
    static func isUsable(_ location: CLLocation, now: Date = Date()) -> Bool {
        guard location.horizontalAccuracy >= 0 else { return false }
        guard location.horizontalAccuracy <= maximumHorizontalAccuracyMeters else { return false }
        return now.timeIntervalSince(location.timestamp) <= maximumFixAge
    }

    /// The newest location in a delivered batch (CoreLocation delivers them
    /// oldest-first), if it is usable. Older entries in the batch are never
    /// substituted for a rejected newest one.
    static func usableFix(from locations: [CLLocation], now: Date = Date()) -> CLLocation? {
        guard let newest = locations.last, isUsable(newest, now: now) else { return nil }
        return newest
    }

    /// `servicesEnabled` only matters when `status == .denied` (CoreLocation
    /// reports `.denied` both for a per-app refusal and for Location Services
    /// being off globally); pass `true` for every other status.
    static func resolve(
        status: CLAuthorizationStatus,
        servicesEnabled: Bool,
        hasUsableFix: Bool,
        hasFailure: Bool
    ) -> LocationAvailability {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return servicesEnabled ? .denied : .servicesDisabled
        case .authorizedWhenInUse, .authorizedAlways:
            if hasUsableFix { return .available }
            return hasFailure ? .failed : .acquiring
        @unknown default:
            return .acquiring
        }
    }
}
