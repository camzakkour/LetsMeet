//
//  BusinessCell.swift
//  LetsMeet
//
//  Created by Cameron Zakkour on 5/25/22.
//

import Foundation
import UIKit

protocol MyCellDelegate: AnyObject {
    
    func btnCloseTapped(cell: BusinessCell)
}

class BusinessCell: UITableViewCell {
    
    @IBOutlet weak var nameLabel: UILabel!
    @IBOutlet weak var categoryLabel: UILabel!
    @IBOutlet weak var priceLabel: UILabel!
    @IBOutlet weak var ratingLabel: UILabel!
    @IBOutlet weak var directionButton: UIButton!
//    var address: String
    
    weak var delegate: MyCellDelegate?
    
}
