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

    /// Photos fetched from Business Details, cached by business ID for the
    /// session so scrolling a restaurant card away and back doesn't refetch.
    private var photoCache: [String: [URL]] = [:]
    /// Completions waiting on an in-flight Details request for a given ID,
    /// so two near-simultaneous card appearances don't fire duplicate requests.
    private var inFlightPhotoRequests: [String: [(Result<[URL], YelpManagerError>) -> Void]] = [:]

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
    func fetchPhotos(forBusinessID id: String, completion: @escaping (Result<[URL], YelpManagerError>) -> Void) {
        if let cached = photoCache[id] {
            return completion(.success(cached))
        }

        if inFlightPhotoRequests[id] != nil {
            inFlightPhotoRequests[id]?.append(completion)
            return
        }
        inFlightPhotoRequests[id] = [completion]

        guard let url = URL(string: NetworkURLConstants.businessDetails + id) else {
            let callbacks = inFlightPhotoRequests.removeValue(forKey: id) ?? []
            callbacks.forEach { $0(.failure(.failedToUnwrapData)) }
            return
        }

        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = YelpTokenConstants.headers

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            let callbacks = self.inFlightPhotoRequests.removeValue(forKey: id) ?? []

            func finish(_ result: Result<[URL], YelpManagerError>) {
                callbacks.forEach { $0(result) }
            }

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
                let photos = try JSONDecoder().decode(BusinessDetails.self, from: data).photos
                self.photoCache[id] = photos
                finish(.success(photos))
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
