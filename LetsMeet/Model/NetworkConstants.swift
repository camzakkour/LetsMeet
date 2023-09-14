//
//  NetworkConstants.swift
//  LetsMeet
//
//  Created by Cameron Zakkour on 5/5/22.
//

import Foundation

struct YelpTokenConstants {
    static let clientID: String = {
        guard let path = Bundle.main.path(forResource: "config", ofType: "plist"),
            let configDict = NSDictionary(contentsOfFile: path) as? [String: Any],
            let clientID = configDict["Client ID"] as? String else {
                fatalError("Unable to read Yelp client ID from plist file")
        }
        return clientID
    }()

    static var apiKey: String {
        guard let path = Bundle.main.path(forResource: "config", ofType: "plist"),
            let configDict = NSDictionary(contentsOfFile: path) as? [String: Any],
            let apiKey = configDict["API Key"] as? String else {
                fatalError("Unable to read Yelp API key from plist file")
        }
        return apiKey
    }

    static let headers = ["Authorization": "Bearer " + YelpTokenConstants.apiKey]
}

struct NetworkURLConstants {
    static let businessSearch = "https://api.yelp.com/v3/businesses/search"
    static let businessDetails = "https://api.yelp.com/v3/businesses/"
}
