import SwiftUI
import UIKit
import FirebaseCore
import FirebaseAnalytics

@main
struct CardBalApp: App {
    init() {
        if Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil {
            FirebaseApp.configure()
            Analytics.setAnalyticsCollectionEnabled(true)
        }

        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithDefaultBackground()

        UserDefaults.standard.register(defaults: [
            "scanOnLaunch": true,
            "dateFormat": "yyyy-MM-dd",
            "cardTimeZonePreference": CardTimeZonePreference.issuer.rawValue,
            DeveloperModePreferences.enabledKey: false,
            KoreanTripCrowdsourcingPreferences.enabledKey: false,
            KoreanTripCrowdsourcingPreferences.promptedKey: false,
            KoreanTripCrowdsourcingPreferences.endpointKey: "https://korean-trip-crowdsourcing.ieb.app/ingest/korean-trip-records"
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.primary)
        }
    }
}
