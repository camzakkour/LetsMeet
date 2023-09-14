//
//  YelpResults.swift
//  LetsMeet
//
//  Created by Cameron Zakkour on 5/5/22.
//

import Foundation

//Details to be shown: Name, Hours of Operation, and Price("$$")
struct TopLevelDictionary: Decodable {
    var businesses: [Restaurant]
}

struct Restaurant: Decodable {
    var name: String
    var price: String? = "0"
    var rating: Double
    var categories: [Categories]
    var location: Location?
}

struct Location: Decodable {
    var address1: String
    var city: String
    var zip_code: String
    var state: String
    var display_address: [String]
}

struct Categories: Decodable {
    var title: String
}
