//
//  LocationManager.swift
//  LetsMeet
//
//  Created by Cameron Zakkour on 5/25/22.
//

import Foundation
import UIKit
import CoreLocation


////objective c - Determining Midpoint Between 2 Coordinates - Stack Overflow
//        /** Degrees to Radian **/

class LocationUtility {

  static  let shared = LocationUtility()

    func degreeToRadian(angle:CLLocationDegrees) -> CGFloat {
        return (  (CGFloat(angle)) / 180.0 * CGFloat(Double.pi)  )
    }

    //        /** Radians to Degrees **/
    func radianToDegree(radian:CGFloat) -> CLLocationDegrees {
        return CLLocationDegrees(  radian * CGFloat(180.0 / .pi)  )
    }

    func geographicMidpoint(betweenCoordinates coordinates: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {

        guard coordinates.count > 1 else {
            return coordinates.first ?? // return the only coordinate
                CLLocationCoordinate2D(latitude: 0, longitude: 0) // return null island if no coordinates were given
        }

        var x = Double(0)
        var y = Double(0)
        var z = Double(0)

        for coordinate in coordinates {
            let lat:CGFloat = degreeToRadian(angle: coordinate.latitude)
            let lon:CGFloat = degreeToRadian(angle: coordinate.longitude)
               x = x + cos(lat) * cos(lon)
               y = y + cos(lat) * sin(lon)
//               z = z + (sin(lat))
            z += sin(Double(lat))
           }

        x = x/CGFloat(coordinates.count)
        y = y/CGFloat(coordinates.count)
        z = z/CGFloat(coordinates.count)

        let resultLon: CGFloat = atan2(y, x)
        let resultHyp: CGFloat = sqrt(x*x+y*y)
        let resultLat:CGFloat = atan2(z, resultHyp)


        let newLat = radianToDegree(radian: resultLat)
        let newLon = radianToDegree(radian: resultLon)
        let result: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: newLat, longitude: newLon)

          return result
    }
}
