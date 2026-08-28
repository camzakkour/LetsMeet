//
//  HomeNavigationCoordinator.swift
//  LetsMeet
//

import UIKit

protocol HomeNavigating: AnyObject {
    func showResults()
}

/// Minimal, transitional bridge: lets the SwiftUI home screen request
/// navigation while the existing UIKit UINavigationController performs the
/// actual storyboard instantiation and push of the legacy results screen.
final class HomeNavigationCoordinator: HomeNavigating {

    private weak var navigationController: UINavigationController?

    init(navigationController: UINavigationController) {
        self.navigationController = navigationController
    }

    func showResults() {
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        guard let detailViewController = storyboard.instantiateViewController(withIdentifier: "DetailViewController") as? DetailViewController
        else { return }

        navigationController?.pushViewController(detailViewController, animated: true)
    }
}
