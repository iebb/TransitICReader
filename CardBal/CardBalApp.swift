import SwiftUI
import UIKit

@main
struct CardBalApp: App {
    init() {
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithDefaultBackground()

        UserDefaults.standard.register(defaults: [
            "scanOnLaunch": true,
            "dateFormat": "yyyy-MM-dd",
            "cardTimeZonePreference": CardTimeZonePreference.issuer.rawValue
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.primary)
        }
    }
}
