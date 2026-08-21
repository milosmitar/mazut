//
//  StemActivityController.swift
//  Mazut
//
//  Manages the Live Activity card on the lock screen (song title +
//  per-channel buttons). The card itself (UI) lives in the MazutWidget
//  extension; the shared model is in MazutWidget/StemActivityShared.swift.
//

#if canImport(ActivityKit)
import ActivityKit

@MainActor
final class StemActivityController {

    private var activity: Activity<StemActivityAttributes>?

    init() {
        // Pick up and end any leftover cards from a previous app launch.
        for old in Activity<StemActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Show the card (or refresh the existing one). Called when playback starts.
    func start(state: StemActivityAttributes.ContentState) {
        guard activity == nil else {
            update(state: state)
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(
            attributes: StemActivityAttributes(),
            content: .init(state: state, staleDate: nil)
        )
    }

    func update(state: StemActivityAttributes.ContentState) {
        guard let activity else { return }
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// Remove the card from the lock screen (when leaving the player).
    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}

#else

/// macOS and other platforms don't have ActivityKit — empty implementation.
@MainActor
final class StemActivityController {
    func start(state: StemActivityAttributes.ContentState) {}
    func update(state: StemActivityAttributes.ContentState) {}
    func end() {}
}

#endif
