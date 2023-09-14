//
//  YelpController.swift
//  LetsMeet
//
//  Created by Cameron Zakkour on 5/5/22.
//

import UIKit

let app_id = "IeC3XoVHtyq5YyLql51bssX8i0D_8_lrI7c9mClqOUz0Cq0Gztkb-9mLa2L_cnn0Nscj_I30j-b3wz3jBEg0uOwe81Z4OXc0ik4DiEafmhK9ZmFHmoiDDzMwlB10YnYx"
let app_code = "pudxkSYxLCQw7dhupri24g"

if let url = URL(string: "https://places.cit.api.here.com/places/v1/discover/around?at=37.776169%2C-122.421267&app_id=\(app_id)&app_code=\(app_code)") {
    var request = URLRequest(url: url)
    // Set headers
    request.setValue("Accept-Language", forHTTPHeaderField: "en-us")
    request.setValue("Authorization", forHTTPHeaderField: "Bearer " + token, // Token here)

    print("Attempting to get places around location")
    let task = URLSession.shared.dataTask(with: url) { (data, response, error) in
        // ...
