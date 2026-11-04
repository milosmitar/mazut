//
//  MazutApp.swift
//  Mazut
//
//  Created by Milos Mitrovic on 23. 6. 2026..
//

import SwiftUI

@main
struct MazutApp: App {
    /// Set once the user skips or finishes the intro; the intro never shows again.
    @AppStorage("hasSeenIntro") private var hasSeenIntro = false

    var body: some Scene {
        WindowGroup {
            if hasSeenIntro {
                ContentView()
            } else {
                OnboardingView {
                    withAnimation(.easeInOut) { hasSeenIntro = true }
                }
                .transition(.opacity)
            }
        }
    }
}
