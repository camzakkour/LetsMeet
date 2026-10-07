//
//  YelpManager.swift
//  LetsMeet
//
//  Created by Cameron Zakkour on 5/5/22.
//

import Foundation
import CoreLocation
import MapKit

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
    /// The already-fetched A(user)->B(friend) route, exposed as-is for map
    /// visualization. Pure data storage - set by MeetingPlaceFinder, not
    /// computed or mutated here.
    var route: MKRoute?
    /// The final search radius (in meters) used to find `restaurants`,
    /// exposed as-is for map visualization. Pure data storage - set by
    /// MeetingPlaceFinder, not computed or mutated here.
    var searchRadiusMeters: Double?

    /// Full Business Details response, cached in memory by business ID (for
    /// at most `YelpCachePolicy.maxAge`) so scrolling a restaurant card away
    /// and back doesn't refetch. Backs both `fetchPhotos` (photo gallery) and
    /// `fetchBusinessDetails` (phone, Yelp URL) from the same single
    /// request/cache entry per business. It is also the in-flight registry
    /// that stops two near-simultaneous card appearances from firing duplicate
    /// requests, and it is lock-protected because callers arrive on the main
    /// thread while URLSession completions arrive on its background queue.
    private let businessDetailsStore = BusinessDetailsStore<BusinessDetails, YelpManagerError>()

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
    
    /// Searches Yelp Business Search for restaurants near an explicit center
    /// and radius, used by the travel-time-fair midpoint flow (see
    /// MeetingPlaceFinder/RestaurantFairnessSelector). Unlike `searchBusiness`,
    /// this restricts results to restaurants and sets an explicit radius
    /// instead of relying on Yelp's default, and does not mutate `restaurants`
    /// or `midPoint` itself - the caller decides what to do with the results.
    func searchRestaurants(
        near center: CLLocationCoordinate2D,
        radiusMeters: Double,
        completion: @escaping (Result<[Restaurant], YelpManagerError>) -> Void
    ) {
        // Yelp's Business Search endpoint rejects radius values above 40,000m.
        let clampedRadius = min(radiusMeters, 40_000)

        let queryItems = [
            URLQueryItem(name: "latitude", value: String(center.latitude)),
            URLQueryItem(name: "longitude", value: String(center.longitude)),
            URLQueryItem(name: "radius", value: String(Int(clampedRadius))),
            URLQueryItem(name: "categories", value: "restaurants"),
            URLQueryItem(name: "limit", value: "20")
        ]

        var components = URLComponents(string: NetworkURLConstants.businessSearch)!
        components.queryItems = queryItems
        guard let url = components.url else { return completion(.failure(.failedToUnwrapData)) }

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
                completion(.success(restaurants))
            } catch {
                completion(.failure(.failedToDecodeRestaurants(error)))
            }
        }.resume()
    }

    /// Fetches the multi-photo gallery for one business from Business Details
    /// (GET /v3/businesses/{id}), the endpoint/field verified to return up to
    /// 3 photos on this app's current Yelp plan. Cached by business ID so
    /// repeat calls for the same restaurant resolve without a network request.
    /// Thin wrapper over `fetchBusinessDetails` so this call's existing
    /// signature/behavior is unchanged for `RestaurantPhotoGalleryView`.
    func fetchPhotos(forBusinessID id: String, completion: @escaping (Result<[URL], YelpManagerError>) -> Void) {
        fetchBusinessDetails(forBusinessID: id) { result in
            completion(result.map(\.photos))
        }
    }

    /// Fetches phone/Yelp-URL for one business from the same Business
    /// Details endpoint/cache `fetchPhotos` uses - never a second request for
    /// a business whose details (photos or otherwise) were already fetched.
    func fetchBusinessDetails(forBusinessID id: String, completion: @escaping (Result<BusinessDetails, YelpManagerError>) -> Void) {
        switch businessDetailsStore.begin(id: id, completion: completion) {
        case .cached(let cached):
            return completion(.success(cached))
        case .joined:
            return
        case .startRequest:
            break
        }

        // Stores a success, drops the in-flight entry and collects the waiting
        // completions under the store's lock, then runs them outside it.
        func finish(_ result: Result<BusinessDetails, YelpManagerError>) {
            businessDetailsStore.finish(id: id, result: result).forEach { $0(result) }
        }

        guard let url = URL(string: NetworkURLConstants.businessDetails + id) else {
            return finish(.failure(.failedToUnwrapData))
        }

        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = YelpTokenConstants.headers

        URLSession.shared.dataTask(with: request) { data, response, error in

            if let error = error {
                return finish(.failure(.failedRequestWithError(error)))
            }

            guard let responseCode = (response as? HTTPURLResponse)?.statusCode,
                  responseCode >= 200,
                  responseCode < 300
            else { return finish(.failure(.invalidResponseCode)) }

            guard let data = data
            else { return finish(.failure(.failedToUnwrapData)) }

            do {
                let details = try JSONDecoder().decode(BusinessDetails.self, from: data)
                finish(.success(details))
            } catch {
                finish(.failure(.failedToDecodeRestaurants(error)))
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
