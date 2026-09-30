//
//  GeographicMidpointStrategy.swift
//  LetsMeet
//

import Foundation
import CoreLocation
import os.log

/// Wraps today's existing pure-geographic midpoint behavior. Used both as
/// the explicit, non-fabricated fallback when traffic-aware routing is
/// unavailable, and - unchanged - as a directly-selectable strategy in its
/// own right.
struct GeographicMidpointStrategy: MidpointStrategy {

    #if DEBUG
    private static let logger = Logger(subsystem: "com.letsmeet.app", category: "Session9")
    #endif

    /// Pure geometry, no diagnostics or side effects - shared with
    /// `RouteSeededMidpointStrategy`'s fallback path so a failed
    /// traffic-aware attempt can drop into this without losing the
    /// diagnostics already gathered from the requests it did make.
    static func centerAndRadius(
        userLocation: CLLocation,
        friendLocation: CLLocation
    ) -> (center: CLLocationCoordinate2D, radiusMeters: Double) {
        let center = LocationUtility.shared.geographicMidpoint(
            betweenCoordinates: [userLocation.coordinate, friendLocation.coordinate]
        )
        let straightLineDistance = userLocation.distance(from: friendLocation)
        let radius = MidpointFairnessConfig.searchRadius(forStraightLineDistance: straightLineDistance)
        return (center, radius)
    }

    func findMeetingRegion(
        userLocation: CLLocation,
        friendLocation: CLLocation,
        searchID: String,
        completion: @escaping (MeetingRegion) -> Void
    ) {
        let (center, radius) = Self.centerAndRadius(userLocation: userLocation, friendLocation: friendLocation)

        let diagnostics = MidpointDiagnostics(searchID: searchID, originalGeographicMidpoint: center)
        diagnostics.usedTrafficAwareRouting = false
        diagnostics.selectedCenter = center
        diagnostics.searchRadiusMeters = radius

        #if DEBUG
        Self.logger.log("""
        [S9][\(searchID)] FINAL seed used for Yelp search (GeographicMidpointStrategy, no route): \
        coordinate=\(String(describing: center)) radiusMeters=\(radius)
        """)
        #endif

        completion(
            MeetingRegion(
                center: center,
                searchRadiusMeters: radius,
                userETA: nil,
                friendETA: nil,
                isTrafficAwareResult: false,
                corridor: nil,
                diagnostics: diagnostics
            )
        )
    }
}
