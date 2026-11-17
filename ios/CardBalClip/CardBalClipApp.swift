import SwiftUI

@main
struct CardBalClipApp: App {
    var body: some Scene {
        WindowGroup {
            QuickScanView()
                .tint(.primary)
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    // Navigation only, deliberately idempotent: never start NFC here.
                    if let url = activity.webpageURL { _ = ClipInvocation(url) }
                }
                .onAppear {
                    #if DEBUG
                    if let value = ProcessInfo.processInfo.environment["_XCAppClipURL"],
                       let url = URL(string: value) { _ = ClipInvocation(url) }
                    #endif
                }
        }
    }
}
