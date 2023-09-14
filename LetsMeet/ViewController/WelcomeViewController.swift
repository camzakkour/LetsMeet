//
//  ViewController.swift
//  LetsMeet
//
//  Created by Cameron Zakkour on 4/29/22.
//

import UIKit
import CoreLocation

enum ConvertLocationError: Error {
    case failedToConvertAddressToLocation
}


class WelcomeViewController: UIViewController, CLLocationManagerDelegate, UITextFieldDelegate {

    @IBOutlet weak var AddressTextBox: UITextField!
    @IBOutlet weak var clearButton: UIButton!
    var isValid = false
    
    let locationManager = CLLocationManager()

    var userLocationCord: CLLocation?
    var friendsLocation: CLLocation?
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .darkContent
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        AddressTextBox.delegate = self
        
        locationManager.requestAlwaysAuthorization()
        
        if CLLocationManager.locationServicesEnabled() {
            locationManager.delegate = self
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.startUpdatingLocation()
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let userLocation = locations.first {
            print (userLocation.coordinate)
            YelpManager.shared.currentUserLocation = userLocation
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
            if(status == CLAuthorizationStatus.denied) {
                showLocationDisabledPopUp()
            }
        }
        
    func showLocationDisabledPopUp() {
        let alertController = UIAlertController(title: "Background Location Access Disabled",
                                                message: "In order to find the mid-point with your friend we need your location",
                                                preferredStyle: .alert)
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
        alertController.addAction(cancelAction)
        
        let openAction = UIAlertAction(title: "Open Settings", style: .default) { (action) in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }
        alertController.addAction(openAction)
        
        self.present(alertController, animated: true, completion: nil)
    }

    
    func convert(address: String, completion: @escaping (Result<CLLocation, ConvertLocationError>) -> Void) {
        let geoCoder = CLGeocoder()
        geoCoder.geocodeAddressString(address) { placemarks, error in
            if let error = error {
                self.badAddressError(usersAddress: address)
                print(error.localizedDescription)
                completion(.failure(.failedToConvertAddressToLocation))
            }

            guard let placemarks = placemarks,
                  let location = placemarks.first?.location else {
                self.badAddressError(usersAddress: address)
                return completion(.failure(.failedToConvertAddressToLocation))
            }
            completion(.success(location))
        }
    }

    func getFriendsLocation(completion: @escaping (Result<Void, ConvertLocationError>) -> Void) {
        guard let address = AddressTextBox.text, !address.isEmpty
        else {
            noAddressProvidedAlert()
            return
        }
        
        convert(address: address) { result in
            switch result {
            case .success(let location):
                YelpManager.shared.didCaptureFriendsLocation(location: location)
                completion(.success(()))
            case .failure: print("failure: failed to convert friends address")
                completion(.failure(.failedToConvertAddressToLocation))
            }
        }
        
    }
    
    func noAddressProvidedAlert() {
        
        let addressError = AlertController.presentAlertControllerWith(alertTitle: "Invalid Address", alertMessage: "Please enter a full address and try again", dismissActionTitle: "Retry")
        
        
        DispatchQueue.main.async {
            self.present(addressError, animated: true)
        }
    }

    func badAddressError(usersAddress: String) {
        
        let addressError = AlertController.presentAlertControllerWith(alertTitle: "\(usersAddress) Invalid Address", alertMessage: "Please enter a full address and try again", dismissActionTitle: "Cancel")
        

        let retryAction = UIAlertAction(title: "Retry", style: .default) { _ in
            YelpManager.shared.searchBusiness { result in
                switch result {
                case .failure(let error):
                    print(error.localizedDescription)
                case .success():
                    print("Successfully ran the search business function")
                }
            }
        }
        
        addressError.addAction(retryAction)
        
        DispatchQueue.main.async {
            self.present(addressError, animated: true)
        }
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        AddressTextBox.resignFirstResponder()
    }
    
    @IBAction func clearButtonTapped(_ sender: Any) {
        AddressTextBox.text = ""
    }
    

    
    @IBAction func MeetButtonTapped(_ sender: Any) {
        getFriendsLocation { result in
            switch result {
            case .success:
                self.performSegue(withIdentifier: "toResultsView", sender: self)
            case .failure(let error):
                self.noAddressProvidedAlert()
                print("Failure")
            }
        }
    }
}

