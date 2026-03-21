import SwiftUI
import UIKit

@main
struct CardBalApp: App {
    init() {
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = UIColor.systemBackground

        let normalColor = UIColor.secondaryLabel
        let selectedColor = UIColor.label

        let inline = tabBarAppearance.stackedLayoutAppearance
        inline.normal.iconColor = normalColor
        inline.normal.titleTextAttributes = [.foregroundColor: normalColor]
        inline.selected.iconColor = selectedColor
        inline.selected.titleTextAttributes = [.foregroundColor: selectedColor]

        tabBarAppearance.inlineLayoutAppearance = inline
        tabBarAppearance.compactInlineLayoutAppearance = inline

        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
