@MainActor
enum ClawdhubAvailabilityPresentation {
    static var title: String {
        String(localized: "ClawHub unavailable", bundle: SkillsManagerLocalizationResources.bundle)
    }

    static var detail: String {
        String(localized: "Try again without affecting your local Skills.", bundle: SkillsManagerLocalizationResources.bundle)
    }

    static var cachedDetail: String {
        String(localized: "ClawHub unavailable — cached content may be out of date.", bundle: SkillsManagerLocalizationResources.bundle)
    }
}
