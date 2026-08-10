@MainActor
enum ClawdhubAvailabilityPresentation {
    static var title: String {
        String(localized: "ClawHub unavailable", bundle: .module)
    }

    static var detail: String {
        String(localized: "Try again without affecting your local Skills.", bundle: .module)
    }

    static var cachedDetail: String {
        String(localized: "ClawHub unavailable — cached content may be out of date.", bundle: .module)
    }
}
