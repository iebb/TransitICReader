import SwiftUI
import UIKit
import FirebaseCore
import FirebaseAnalytics

@main
struct CardBalApp: App {
    init() {
        // AirFeedback crash reports: MetricKit hands a crash to a later launch,
        // which sends it (queued on disk when offline).
        AirCrashReports.start(
            apiKey: FeedbackConfig.appKey,
            endpoint: "https://apps.air.build/v1/ingest/crashes",
            teamID: FeedbackConfig.teamID
        )

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
            KoreanTripCrowdsourcingPreferences.enabledKey: true,
            OctopusOnlinePreferences.enabledKey: true,
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
