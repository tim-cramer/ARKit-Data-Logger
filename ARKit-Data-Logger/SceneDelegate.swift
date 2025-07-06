// SceneDelegate.swift
import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        
        window = UIWindow(windowScene: windowScene)
        // Make sure your storyboard is named "Main" or update the name here.
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        // Make sure the initial ViewController has the storyboard ID "BV1-FR-VrT"
        let initialViewController = storyboard.instantiateViewController(withIdentifier: "BV1-FR-VrT")
        
        window?.rootViewController = initialViewController
        window?.makeKeyAndVisible()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // If you need to restart tasks when the scene becomes active, do it here.
        // For your app, ViewController's viewWillAppear is sufficient.
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // If you need to pause tasks when the scene is interrupted, do it here.
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
    }
}
