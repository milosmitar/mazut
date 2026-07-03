//
//  StemActivityController.swift
//  Mazut
//
//  Upravljanje Live Activity karticom na zaključanom ekranu (naslov pesme +
//  dugmići za kanale). Sama kartica (UI) živi u MazutWidget ekstenziji;
//  zajednički model je u MazutWidget/StemActivityShared.swift.
//

#if canImport(ActivityKit)
import ActivityKit

@MainActor
final class StemActivityController {

    private var activity: Activity<StemActivityAttributes>?

    init() {
        // Pokupi i ugasi zaostale kartice od prethodnog pokretanja aplikacije.
        for stara in Activity<StemActivityAttributes>.activities {
            Task { await stara.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Prikaži karticu (ili osveži postojeću). Poziva se kad krene reprodukcija.
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

    /// Skloni karticu sa zaključanog ekrana (kad se izađe iz plejera).
    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}

#else

/// macOS i ostale platforme nemaju ActivityKit — prazna implementacija.
@MainActor
final class StemActivityController {
    func start(state: StemActivityAttributes.ContentState) {}
    func update(state: StemActivityAttributes.ContentState) {}
    func end() {}
}

#endif
