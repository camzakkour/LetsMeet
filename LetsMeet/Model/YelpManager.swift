//
//  YelpManager.swift
//  LetsMeet
//
//  Created by Cameron Zakkour on 5/5/22.
//

import Foundation
import CoreLocation

enum YelpManagerError: Error {
    case failedRequestWithError(Error)
    case invalidResponseCode
    case failedToDecodeRestaurants(Error)
    case failedToUnwrapData
    case failedToUnwrapMidpoint
}

class YelpManager {
    static let shared = YelpManager()
    
    var restaurants: [Restaurant] = []
    var currentUserLocation: CLLocation?
    var friendLocation: CLLocation?
    var midPoint: CLLocation?
    
    func didCaptureFriendsLocation(location: CLLocation) {
        friendLocation = location
        midPoint = findMidpoint()
    }

    func searchBusiness(completion: @escaping (Result<Void, YelpManagerError>) -> Void) {
        guard let midPoint = midPoint
        else { return completion(.failure(.failedToUnwrapMidpoint)) }

        let queryItems = [
            URLQueryItem(name: "latitude", value: String(midPoint.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(midPoint.coordinate.longitude)),
            URLQueryItem(name: "limit", value: "10")
        ]
        
        var components = URLComponents(string: NetworkURLConstants.businessSearch)!
        components.queryItems = queryItems
        guard let url = components.url else {return}

        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = YelpTokenConstants.headers
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                return completion(.failure(.failedRequestWithError(error)))
            }
            
            guard let responseCode = (response as? HTTPURLResponse)?.statusCode,
                  responseCode >= 200,
                  responseCode < 300
            else { return completion(.failure(.invalidResponseCode)) }
            
            guard let data = data
            else { return completion(.failure(.failedToUnwrapData)) }
            
            do {
                let restaurants = try JSONDecoder().decode(TopLevelDictionary.self, from: data).businesses
                self.restaurants = restaurants
                completion(.success(()))
                
                for item in restaurants {
                    print(item.name)
                    print(item.categories)
                    print(item.price)
                    print(item.rating)
                    
                    print("\n \(item.location?.address1)  \(item.location?.city)  \(item.location?.zip_code)  \(item.location?.state)\n")
                }
            } catch {
                print("*!*!*!*!!*!* Error fetching Restruatns \(error.localizedDescription)\n\(error)\n!*!*!*!*!")
                return completion(.failure(.failedToDecodeRestaurants(error)))
            }
        }.resume()
    }
    
    private func findMidpoint() -> CLLocation? {
        guard let currentUserCoordinate = currentUserLocation?.coordinate,
              let friendCoordinate = friendLocation?.coordinate
        else {
            return friendLocation
        }

        let coordinates: [CLLocationCoordinate2D] = [currentUserCoordinate, friendCoordinate]
        let midPointLocation = LocationUtility.shared.geographicMidpoint(betweenCoordinates: coordinates)
        print("This is the midpoint coordinates: \(midPointLocation)")

        return CLLocation(latitude: midPointLocation.latitude, longitude: midPointLocation.longitude)
    }
}
