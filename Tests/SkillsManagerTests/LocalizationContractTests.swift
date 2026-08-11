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

    @Test("resource entry point exposes the native Chinese development locale")
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
        let zhCN = SkillRowView.localizedBadgeAccessibilityText(
            badge,
            locale: Locale(identifier: "zh_CN")
        )
        let en = SkillRowView.localizedBadgeAccessibilityText(
            badge,
            locale: Locale(identifier: "en")
        )

        #expect(zh.contains("有可用更新"))
        #expect(zhCN.contains("有可用更新"))
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

    @Test("typed interpolation renders inserted values for representative journeys")
    func typedInterpolationRendersValues() {
        let zh = Locale(identifier: "zh-Hans")
        let en = Locale(identifier: "en")
        let bundle = SkillsManagerLocalizationResources.bundle

        func assertRendered(
            _ value: String,
            contains inserted: String
        ) {
            #expect(value.contains(inserted))
            #expect(!value.contains("%@"))
            #expect(!value.contains("%lld"))
            #expect(!value.contains("%1$"))
        }

        let version = "9.8.7"
        let installName = "Probe Skill"
        let batchName = "Batch Skill"
        let resultMessage = "raw provider detail"
        let zhBadge = String(localized: LocalizedStringResource(
            "Update available, version \(version)",
            locale: zh,
            bundle: bundle
        ))
        let enBadge = String(localized: LocalizedStringResource(
            "Update available, version \(version)",
            locale: en,
            bundle: bundle
        ))
        let zhInstall = String(localized: LocalizedStringResource(
            "\(installName) is ready.",
            locale: zh,
            bundle: bundle
        ))
        let enInstall = String(localized: LocalizedStringResource(
            "\(installName) is ready.",
            locale: en,
            bundle: bundle
        ))
        let zhDiscovery = String(localized: LocalizedStringResource(
            "\(3) selected",
            locale: zh,
            bundle: bundle
        ))
        let enDiscovery = String(localized: LocalizedStringResource(
            "\(3) selected",
            locale: en,
            bundle: bundle
        ))
        let zhSummary = String(localized: LocalizedStringResource(
            "\(2) created · \(1) claimed · \(0) skipped · \(1) failed",
            locale: zh,
            bundle: bundle
        ))
        let enSummary = String(localized: LocalizedStringResource(
            "\(2) created · \(1) claimed · \(0) skipped · \(1) failed",
            locale: en,
            bundle: bundle
        ))
        let zhBatch = String(localized: LocalizedStringResource(
            "\(2) of \(4) complete. \(batchName)",
            locale: zh,
            bundle: bundle
        ))
        let enBatch = String(localized: LocalizedStringResource(
            "\(2) of \(4) complete. \(batchName)",
            locale: en,
            bundle: bundle
        ))
        let zhConsistency = String(localized: LocalizedStringResource(
            "\(5) item(s) need review.",
            locale: zh,
            bundle: bundle
        ))
        let enConsistency = String(localized: LocalizedStringResource(
            "\(5) item(s) need review.",
            locale: en,
            bundle: bundle
        ))
        let zhRemote = String(localized: LocalizedStringResource(
            "\(12) installs",
            locale: zh,
            bundle: bundle
        ))
        let enRemote = String(localized: LocalizedStringResource(
            "\(12) installs",
            locale: en,
            bundle: bundle
        ))
        let zhResult = String(localized: LocalizedStringResource(
            "Result: \(resultMessage)",
            locale: zh,
            bundle: bundle
        ))
        let enResult = String(localized: LocalizedStringResource(
            "Result: \(resultMessage)",
            locale: en,
            bundle: bundle
        ))

        for value in [zhBadge, enBadge] { assertRendered(value, contains: version) }
        for value in [zhInstall, enInstall] { assertRendered(value, contains: installName) }
        for value in [zhDiscovery, enDiscovery] { assertRendered(value, contains: "3") }
        for value in [zhSummary, enSummary] { assertRendered(value, contains: "1") }
        for value in [zhBatch, enBatch] { assertRendered(value, contains: batchName) }
        for value in [zhConsistency, enConsistency] { assertRendered(value, contains: "5") }
        for value in [zhRemote, enRemote] { assertRendered(value, contains: "12") }
        for value in [zhResult, enResult] { assertRendered(value, contains: resultMessage) }
        #expect(zhBadge.contains("有可用更新"))
        #expect(zhSummary.contains("已创建"))
        #expect(zhConsistency.contains("需要检查"))
        #expect(zhRemote.contains("安装"))
        #expect(zhResult.contains("结果"))
        #expect(enBadge.contains("Update available"))
        #expect(enSummary.contains("created"))
        #expect(enConsistency.contains("need review"))
        #expect(enRemote.contains("installs"))
        #expect(enResult.contains("Result"))
    }

    @Test("finite errors localize known cases and preserve raw details")
    func finiteErrorPresentation() {
        let rawPath = "/private/raw/SKILL.md"
        let rawDetail = "provider detail: 7"
        let packageMessage = localizedSkillPackageError(.unsafeManifest(rawPath))
        let validationMessage = localizedSkillImportValidationError(.archiveRejected(rawDetail))
        #expect(packageMessage.contains(rawPath))
        #expect(validationMessage.contains(rawDetail))

        let retryMessage = localizedManagedInstallError(
            SkillsShSearchError.rateLimited(retryAfterSeconds: 7)
        )
        #expect(retryMessage.contains("7"))
        #expect(localizedManagedInstallError(
            NSError(domain: "raw.provider", code: 1, userInfo: [
                NSLocalizedDescriptionKey: rawDetail,
            ])
        ) == rawDetail)

        #expect(localizedManagedSkillUpdateCapabilityReason("No provider") == "No provider")
        #expect(localizedManagedSkillImportError(.conflict).isEmpty == false)
        #expect(localizedSkillPublishError(.publishedButStateNotRecorded).isEmpty == false)

        if case .failed(let message) = SkillDistributionViewModel.problem(
            for: DistributionSymlinkFileSystemError.entryChanged
        ) {
            #expect(!message.isEmpty)
        } else {
            Issue.record("known distribution error was not presented as a failure")
        }
        if case .failed(let message) = SkillDistributionViewModel.problem(
            for: DistributionSymlinkFileSystemError.posix(operation: "raw operation", code: 2)
        ) {
            #expect(message.contains("raw operation"))
        } else {
            Issue.record("POSIX distribution error was not preserved")
        }

        #expect(localizedLibraryDiagnosticCode(.databaseBusy).isEmpty == false)
        #expect(localizedRecommendedActionCode("retryLater").isEmpty == false)
        #expect(localizedConsistencyDiscoveryReason(SkillDiscoveryReason.rootChanged.rawValue).isEmpty == false)
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
