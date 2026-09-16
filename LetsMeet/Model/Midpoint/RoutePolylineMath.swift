//
//  RoutePolylineMath.swift
//  LetsMeet
//

import CoreLocation
import MapKit

/// Pure geometry over an `MKRoute`'s polyline, shared by the route-seed
/// strategy (initial seed + bounded corrections) and the restaurant search
/// stage (bounded corridor shifts).
enum RoutePolylineMath {

    /// The point at `fraction` (0...1) of the way along `polyline`'s real
    /// road-network geometry, by cumulative distance, snapped to whichever
    /// of the bracketing segment's two endpoints is geographically closer
    /// to the interpolated target. Unlike a step endpoint, `MKPolyline`
    /// vertices are dense enough (tracking the road's actual curvature,
    /// not just maneuvers) that many different fractions don't collapse
    /// onto the same coordinate - a long, simple highway stretch is still
    /// many polyline vertices even though it's a single `MKRoute.Step`.
    /// The returned coordinate is always one of `polyline`'s own vertices,
    /// never an arbitrary chord-interpolated point. Uses only the
    /// already-fetched polyline - no additional MapKit requests.
    static func nearestVertexPoint(atFraction fraction: Double, along polyline: MKPolyline) -> CLLocationCoordinate2D {
        let count = polyline.pointCount
        guard count > 0 else { return polyline.coordinate }

        let points = polyline.points()
        guard count > 1 else { return points[0].coordinate }

        var cumulative = [Double](repeating: 0, count: count)
        for i in 1..<count {
            cumulative[i] = cumulative[i - 1] + points[i - 1].distance(to: points[i])
        }

        let totalDistance = cumulative[count - 1]
        guard totalDistance > 0 else { return points[0].coordinate }

        let target = totalDistance * min(max(fraction, 0), 1)
        for i in 1..<count {
            if cumulative[i] >= target {
                let segmentStart = cumulative[i - 1]
                let segmentEnd = cumulative[i]
                let segmentFraction = segmentEnd > segmentStart ? (target - segmentStart) / (segmentEnd - segmentStart) : 0
                return segmentFraction <= 0.5 ? points[i - 1].coordinate : points[i].coordinate
            }
        }
        return points[count - 1].coordinate
    }

    /// Straight-line distance between two coordinates, in meters. Shared
    /// helper so the seed-correction and corridor-shift "did this actually
    /// move" checks don't each re-derive `CLLocation` construction.
    static func metersBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
