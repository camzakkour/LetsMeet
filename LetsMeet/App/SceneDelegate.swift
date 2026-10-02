//
//  SceneDelegate.swift
//  LetsMeet
//
//  Created by Cameron Zakkour on 4/29/22.
//

import UIKit
import SwiftUI

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    /// Token for the UserDefaults observer that keeps `window.overrideUserInterfaceStyle`
    /// synced to the persisted appearance preference. `.preferredColorScheme` alone can't
    /// reach the real window here, since the SwiftUI root is hosted inside a
    /// UINavigationController rather than being the window's own rootViewController - so
    /// this bridges the preference to UIKit's trait system directly, which then cascades
    /// through the nav controller, hosting controller, and any presented sheets normally.
    private var appearanceObserver: NSObjectProtocol?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        let homeViewModel = HomeViewModel()
        let hostingController = UIHostingController(rootView: LaunchContainerView(homeViewModel: homeViewModel))
        let navigationController = UINavigationController(rootViewController: hostingController)
        navigationController.setNavigationBarHidden(true, animated: false)

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = navigationController
        self.window = window
        window.makeKeyAndVisible()

        applyAppearancePreference()

        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearancePreference()
        }
    }

    private func applyAppearancePreference() {
        let rawValue = UserDefaults.standard.string(forKey: "appAppearance")
        let appearance = rawValue.flatMap(AppAppearance.init(rawValue:)) ?? .system

        let style: UIUserInterfaceStyle
        switch appearance {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }

        window?.overrideUserInterfaceStyle = style
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
        // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
            self.appearanceObserver = nil
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Called when the scene has moved from an inactive state to an active state.
        // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
    }


}

