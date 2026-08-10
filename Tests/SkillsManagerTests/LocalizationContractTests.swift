import Foundation
import Testing

@testable import SkillsManager

@Suite("Native localization contract")
@MainActor
struct LocalizationContractTests {
    @Test("catalog has complete Chinese and English values")
    func catalogCompleteness() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SkillsManager/Resources/Localizable.xcstrings")
        #expect(FileManager.default.fileExists(atPath: url.path))
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        #expect(object["sourceLanguage"] as? String == "zh-Hans")
        let strings = try #require(object["strings"] as? [String: Any])
        #expect(strings.isEmpty == false)
        #expect(strings.keys.allSatisfy { !$0.contains("%arg") && !$0.contains("%1$arg") })

        for (key, value) in strings {
            let entry = try #require(value as? [String: Any], "entry \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(entry["extractionState"] as? String == "manual")
            for language in ["zh-Hans", "en"] {
                let localization = try #require(localizations[language] as? [String: Any], "\(key) / \(language)")
                for unit in try localizationUnits(localization, key: key, language: language) {
                    #expect(unit["state"] as? String == "translated")
                    let value = try #require(unit["value"] as? String, "\(key) / \(language) value")
                    #expect(value.isEmpty == false)
                    #expect(!value.contains("%arg"))
                    #expect(!value.contains("%1$arg"))
                }
            }

            let zh = try localizationValues(strings, key: key, language: "zh-Hans")
            let en = try localizationValues(strings, key: key, language: "en")
            #expect(zh.map(placeholders).map(Array.init) == en.map(placeholders).map(Array.init), "placeholder mismatch for \(key)")
        }
    }

    @Test("Bundle.module exposes the native Chinese development locale")
    func bundleLookup() {
        let bundle = SkillsManagerLocalizationResources.bundle
        let zh = String(localized: LocalizedStringResource(
            "About Skills Manager",
            defaultValue: "About Skills Manager",
            locale: Locale(identifier: "zh-Hans"),
            bundle: bundle
        ))
        let en = String(localized: LocalizedStringResource(
            "About Skills Manager",
            defaultValue: "About Skills Manager",
            locale: Locale(identifier: "en"),
            bundle: bundle
        ))
        #expect(zh == "关于 Skills Manager")
        #expect(en == "About Skills Manager")
        #expect(bundle.developmentLocalization?.lowercased() == "zh-hans")
        #expect(bundle.localizations.map { $0.lowercased() }.contains("zh-hans"))
        #expect(bundle.localizations.map { $0.lowercased() }.contains("en"))
    }

    @Test("filter identity does not depend on localized display text")
    func stableFilterIdentity() {
        #expect(SkillListSourceFilter.all.id == "all")
        #expect(SkillListSourceFilter.source(.local).id == "source:local")
        #expect(SkillListAgentFilter.all.id == "all")
        #expect(SkillListAgentFilter.agent(.codex).id == "agent:codex")
    }

    @Test("localized quantity and date formatting preserve model values")
    func localizedQuantityAndDateFormatting() {
        let zh = Locale(identifier: "zh-Hans")
        let en = Locale(identifier: "en")
        #expect(SkillListAgentSummary.text(count: 1, locale: zh) == "1 个 Agent")
        #expect(SkillListAgentSummary.text(count: 2, locale: zh) == "2 个 Agent")
        #expect(SkillListAgentSummary.text(count: 1, locale: en) == "1 Agent")
        #expect(SkillListAgentSummary.text(count: 2, locale: en) == "2 Agents")

        let date = Date(timeIntervalSince1970: 0)
        let zhDate = date.formatted(
            .dateTime.year().month().day().locale(Locale(identifier: "zh-Hans"))
        )
        let enDate = date.formatted(
            .dateTime.year().month().day().locale(Locale(identifier: "en_US"))
        )
        #expect(zhDate != enDate)
        #expect(SkillListSourceFilter.source(.local).id == "source:local")
    }

    @Test("update badge accessibility localizes its prefix and preserves the version")
    func updateBadgeAccessibilityLocalization() {
        let badge = SkillRowBadge.updateAvailable(version: "1.0.1")
        let zh = SkillRowView.localizedBadgeAccessibilityText(
            badge,
            locale: Locale(identifier: "zh-Hans")
        )
        let en = SkillRowView.localizedBadgeAccessibilityText(
            badge,
            locale: Locale(identifier: "en")
        )

        #expect(zh.contains("有可用更新"))
        #expect(zh.contains("1.0.1"))
        #expect(en.contains("Update available"))
        #expect(en.contains("1.0.1"))
    }

    @Test("typed journey templates keep placeholder shape without legacy arg markers")
    func typedJourneyTemplates() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SkillsManager/Resources/Localizable.xcstrings")
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let strings = try #require(object["strings"] as? [String: Any])
        let keys = [
            "Update available, version %@",
            "%@ is ready.",
            "%lld candidates available · %lld selected",
            "%lld created · %lld claimed · %lld skipped · %lld failed",
            "%lld of %lld",
            "0 of %lld complete.",
            "%lld of %lld complete.",
            "%lld of %lld complete. %@",
            "Batch update summary: %@",
            "%lld item(s) need review.",
            "Result: %@",
        ]
        for key in keys {
            let zh = try localizationValues(strings, key: key, language: "zh-Hans")
            let en = try localizationValues(strings, key: key, language: "en")
            #expect(zh.count == en.count)
            #expect(zip(zh, en).allSatisfy { zhValue, enValue in
                !zhValue.contains("%arg")
                    && !enValue.contains("%arg")
                    && placeholders(in: zhValue).sorted() == placeholders(in: enValue).sorted()
            }, "legacy or placeholder mismatch for \(key)")
        }
    }

    private func localizationUnits(
        _ localization: [String: Any],
        key: String,
        language: String
    ) throws -> [[String: Any]] {
        if let unit = localization["stringUnit"] as? [String: Any] {
            return [unit]
        }
        let variations = try #require(localization["variations"] as? [String: Any], "\(key) / \(language) variations")
        let plural = try #require(variations["plural"] as? [String: Any], "\(key) / \(language) plural")
        return try plural.values.map { value in
            let variant = try #require(value as? [String: Any], "\(key) / \(language) variant")
            return try #require(variant["stringUnit"] as? [String: Any], "\(key) / \(language) variant unit")
        }
    }

    private func localizationValues(
        _ strings: [String: Any],
        key: String,
        language: String
    ) throws -> [String] {
        let entry = try #require(strings[key] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        let localization = try #require(localizations[language] as? [String: Any])
        return try localizationUnits(localization, key: key, language: language).map {
            try #require($0["value"] as? String)
        }
    }

    private func placeholders(in value: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:arg|@|lld)|%\([^)]*\)(?:lld|ld|d|@)"#)
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
            .map { match in
                String(value[Range(match.range, in: value)!])
            }
    }
}
