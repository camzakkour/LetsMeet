import UIKit
import CoreLocation
import MapKit

class DetailViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {
    
    @IBOutlet weak var myTableView: UITableView!
    @IBOutlet weak var NameLabel: UILabel!
    @IBOutlet weak var CategoryLabel: UILabel!
    @IBOutlet weak var PriceLabel: UILabel!
    @IBOutlet weak var RatingLabel: UILabel!
    @IBOutlet weak var DirectMeButton: UIButton!
    
    var usersAddress: String?
    var buissnessAddress: String?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        myTableView.delegate = self
        myTableView.dataSource = self

        YelpManager.shared.searchBusiness { result in
            switch result {
            case .success:
                print("success")
                DispatchQueue.main.async {
                    self.myTableView.reloadData()
                }
            case .failure(let error):
                print(error)
            }
        }
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return YelpManager.shared.restaurants.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "businessCell", for: indexPath) as? BusinessCell else {
            return UITableViewCell()
        }
        
        let restaurant = YelpManager.shared.restaurants[indexPath.row]
        
        cell.nameLabel.text = restaurant.name
        let categoryTitles = restaurant.categories.map { $0.title }
        cell.categoryLabel.text = categoryTitles.joined(separator: ", ")
        cell.priceLabel.text = restaurant.price
        cell.ratingLabel.text = "Rating: \(restaurant.rating)/5"
        
        cell.directionButton.addTarget(self, action: #selector(DirectMeTapped(_:)), for: .touchUpInside)
        cell.directionButton.tag = indexPath.row
        
        return cell
    }
    
    @IBAction func DirectMeTapped(_ sender: UIButton) {
        guard let cell = sender.superview?.superview as? BusinessCell,
              let indexPath = myTableView.indexPath(for: cell),
              let restaurantAddress = YelpManager.shared.restaurants[indexPath.row].location?.display_address.joined(separator: " ")
        else {
            print("Failed to retrieve restaurant address.")
            return
        }

        startDirections(address: restaurantAddress)
        print("CGZ \(restaurantAddress)")
    }

    
    func startDirections(address: String) {
        let encodedAddress = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let mapsURLString = "http://maps.apple.com/?address=\(encodedAddress)"
        
        guard let mapsURL = URL(string: mapsURLString) else {
            print("Invalid URL for Maps.")
            return
        }
        
        UIApplication.shared.open(mapsURL)
    }

}
