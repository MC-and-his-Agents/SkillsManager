import Foundation
import XCTest

@MainActor
final class SkillsManagerUITests: XCTestCase {
    private var app: XCUIApplication!
    private var childHome: URL!
    private var runnerRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        guard let rootPath = ProcessInfo.processInfo.environment["SKILLS_MANAGER_UI_TEST_ROOT"],
              let appPath = ProcessInfo.processInfo.environment["TEST_APP_PATH"] else {
            throw XCTSkip("UI runner admission variables are missing")
        }
        runnerRoot = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let rootMetadata = try posixLstat(runnerRoot)
        guard rootMetadata.st_uid == Darwin.geteuid(),
              rootMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              rootMetadata.st_mode & 0o7777 == 0o700 else {
            throw XCTSkip("runner root is not an owner-only directory")
        }
        childHome = runnerRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard childHome.pathComponents.dropLast() == runnerRoot.pathComponents else {
            throw XCTSkip("child home is not a direct child of the runner root")
        }
        guard Darwin.mkdir(childHome.path, 0o700) == 0 else {
            throw XCTSkip("could not create owner-only child home")
        }
        let homeMetadata = try posixLstat(childHome)
        guard homeMetadata.st_uid == Darwin.geteuid(),
              homeMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              homeMetadata.st_mode & 0o7777 == 0o700 else {
            throw XCTSkip("child home is not an owner-only directory")
        }

        let appURL = URL(fileURLWithPath: appPath).standardizedFileURL
        guard appURL.deletingLastPathComponent().deletingLastPathComponent()
            .standardizedFileURL == runnerRoot,
              appURL.lastPathComponent == "SkillsManagerUITest.app",
              Bundle(url: appURL)?.bundleIdentifier == "com.mcandhisagents.skillsmanager.uitest",
              Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "SkillsManager" else {
            throw XCTSkip("test App URL handoff failed")
        }
        app = XCUIApplication(url: appURL)
        app.launchEnvironment["SKILLS_MANAGER_UI_TEST_ROOT"] = runnerRoot.path
        app.launchEnvironment["SKILLS_MANAGER_UI_TEST_HOME"] = childHome.path
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let childHome, childHome.path.hasPrefix(runnerRoot.path + "/") {
            try? FileManager.default.removeItem(at: childHome)
        }
        try super.tearDownWithError()
    }

    // MARK: - SM168-UI-01

    func testSM168UI01Baseline() throws {
        try launchFixture(app: app, profile: "baseline", surface: "ui-01")
        try requireElement(app.staticTexts["Skills"], surface: "ui-01", app: app)
        try requireElement(
            app.buttons[SkillsManagerUILocators.filterStatus("all")],
            surface: "ui-01",
            app: app
        )
        try requireElement(
            app.buttons[SkillsManagerUILocators.filterSource("local")],
            surface: "ui-01",
            app: app
        )
        try waitForShownCount(6, surface: "ui-01", app: app)

        let managed = row(label: "Fixture Managed", value: "Managed", app: app)
        try requireElement(managed, surface: "ui-01", app: app)
        let managedValue = managed.value as? String ?? ""
        XCTAssertTrue(
            managedValue.contains("Local") && managedValue.contains("Agent"),
            "managed row must read name, status, source, and Agent count; got: \(managedValue)"
        )
        let needsImport = row(label: "Needs Import One", value: "Unmanaged", app: app)
        try requireElement(needsImport, surface: "ui-01", app: app)
        XCTAssertTrue(
            (needsImport.value as? String)?.contains("0 Agents") == true,
            "discovery row must expose its Agent count"
        )
        try auditSurface("ui-01-main-window", app: app)
        try auditSurface("ui-01-filter-bar", app: app)
    }

    // MARK: - SM168-UI-02

    func testSM168UI02Filters() throws {
        try launchFixture(app: app, profile: "baseline", surface: "ui-02")
        try requireElement(app.staticTexts["Skills"], surface: "ui-02", app: app)

        try setFilter("Managed", surface: "ui-02", app: app)
        try setFilter("Local", surface: "ui-02", app: app)
        try requireElement(
            row(label: "Fixture Managed", value: "Managed", app: app),
            surface: "ui-02",
            app: app
        )
        try setFilter("Claude Code", surface: "ui-02", app: app)
        try requireElement(
            app.staticTexts["Select a skill"],
            surface: "ui-02",
            app: app
        )
        try auditSurface("ui-02-filtered-out", app: app)

        try setFilter("All Agents", surface: "ui-02", app: app)
        try setFilter("All Sources", surface: "ui-02", app: app)
        try setFilter("All Statuses", surface: "ui-02", app: app)
        try requireElement(
            row(label: "Fixture Managed", value: "Managed", app: app),
            surface: "ui-02",
            app: app
        )
        try waitForShownCount(6, surface: "ui-02", app: app)
        try auditSurface("ui-02-restored", app: app)
    }

    // MARK: - SM168-UI-03

    func testSM168UI03Pagination() throws {
        try launchFixture(app: app, profile: "baseline", surface: "ui-03")
        try waitForShownCount(6, surface: "ui-03", app: app)

        let latestLoadMore = app.buttons[SkillsManagerUILocators.clawHubLoadMore]
        try requireElement(latestLoadMore, surface: "ui-03", app: app)
        try clickWhenHittable(latestLoadMore, surface: "ui-03", app: app)
        try waitForProgressDisappearance("Loading more latest Skills", surface: "ui-03", app: app)
        try waitForShownCount(7, surface: "ui-03", app: app)
        XCTAssertFalse(
            app.buttons[SkillsManagerUILocators.clawHubLoadMore].exists,
            "ClawHub latest must enter stable finished after the second page"
        )
        try auditSurface("ui-03-clawhub-latest", app: app)

        let searchField = app.searchFields.firstMatch
        try requireElement(searchField, surface: "ui-03", app: app)
        searchField.click()
        searchField.typeText("fixture")
        try waitForShownCount(45, surface: "ui-03", app: app)
        try requireElement(
            app.buttons[SkillsManagerUILocators.clawHubLoadMore],
            surface: "ui-03",
            app: app
        )
        try requireElement(
            app.buttons[SkillsManagerUILocators.skillsShLoadMore],
            surface: "ui-03",
            app: app
        )
        try auditSurface("ui-03-search-loaded", app: app)
        try auditSurface("ui-03-search-pagination", app: app)
        try recordPaginationClassification(surface: "ui-03", app: app)
    }

    // MARK: - SM168-UI-04

    func testSM168UI04ClawHubFailure() throws {
        try launchFixture(app: app, profile: "failure-clawhub", surface: "ui-04-clawhub")
        try requireElement(app.staticTexts["ClawHub unavailable"], surface: "ui-04-clawhub", app: app)
        try requireElement(
            row(label: "Fixture Managed", value: "Managed", app: app),
            surface: "ui-04-clawhub",
            app: app
        )
        let before = try settledSnapshot(surface: "ui-04-clawhub")
        let retry = app.buttons["Retry ClawHub latest Skills"]
        try requireElement(retry, surface: "ui-04-clawhub", app: app)
        retry.click()
        try waitForProgressDisappearance("Loading latest ClawHub Skills", surface: "ui-04-clawhub", app: app)
        try requireElement(app.staticTexts["ClawHub unavailable"], surface: "ui-04-clawhub", app: app)
        try auditSurface("ui-04-clawhub-error", app: app)
        app.terminate()
        try assertSnapshotUnchanged(before, home: childHome, surface: "ui-04-clawhub", app: app)
    }

    func testSM168UI04SkillsShFailure() throws {
        try launchFixture(app: app, profile: "failure-skills-sh", surface: "ui-04-skills-sh")
        try requireElement(
            row(label: "Fixture Managed", value: "Managed", app: app),
            surface: "ui-04-skills-sh",
            app: app
        )
        let before = try settledSnapshot(surface: "ui-04-skills-sh")
        try setFilter("skills.sh", surface: "ui-04-skills-sh", app: app)
        let searchField = app.searchFields.firstMatch
        try requireElement(searchField, surface: "ui-04-skills-sh", app: app)
        searchField.click()
        searchField.typeText("fixture")
        try requireElement(app.staticTexts["skills.sh unavailable"], surface: "ui-04-skills-sh", app: app)
        let retry = app.buttons["Retry"]
        try requireElement(retry, surface: "ui-04-skills-sh", app: app)
        // 统一空状态组件让错误行更高，窄窗口下 Retry 可能落到视口边缘；
        // 使用带滚动重试的点击。
        try clickWhenHittable(retry, surface: "ui-04-skills-sh", app: app)
        try waitForProgressDisappearance("Searching skills.sh", surface: "ui-04-skills-sh", app: app)
        try requireElement(app.staticTexts["skills.sh unavailable"], surface: "ui-04-skills-sh", app: app)
        try auditSurface("ui-04-skills-sh-error", app: app)
        app.terminate()
        try assertSnapshotUnchanged(before, home: childHome, surface: "ui-04-skills-sh", app: app)
    }

    func testSM168UI04RepositoryFailure() throws {
        try launchFixture(app: app, profile: "failure-repository", surface: "ui-04-repository")
        try setFilter("Repository", surface: "ui-04-repository", app: app)
        try waitForHierarchyText(
            "Repository unavail",
            surface: "ui-04-repository",
            app: app
        )
        let before = try settledSnapshot(surface: "ui-04-repository")
        try openRepositorySheet(surface: "ui-04-repository", app: app)
        let refreshAll = app.buttons[SkillsManagerUILocators.repositoryRefreshAll]
        try requireElement(refreshAll, surface: "ui-04-repository", app: app)
        try auditSurface("ui-04-repository-sheet", app: app)
        refreshAll.click()
        try waitForEnabled(refreshAll, surface: "ui-04-repository", app: app)
        try requireElement(app.staticTexts["Failed"], surface: "ui-04-repository", app: app)
        app.buttons[SkillsManagerUILocators.repositoryDone].click()
        try waitForHierarchyText(
            "Repository unavail",
            surface: "ui-04-repository",
            app: app
        )
        app.terminate()
        try assertSnapshotUnchanged(before, home: childHome, surface: "ui-04-repository", app: app)
    }

    // MARK: - SM168-UI-05

    func testSM168UI05BatchImport() throws {
        try launchFixture(app: app, profile: "baseline", surface: "ui-05")
        let baseline = try settledSnapshot(surface: "ui-05")
        let batch = app.buttons[SkillsManagerUILocators.batchImport]
        try requireElement(batch, surface: "ui-05", app: app)
        batch.click()
        let checkboxOne = app.checkBoxes["Needs Import One"]
        let checkboxTwo = app.checkBoxes["Needs Import Two"]
        try requireElement(checkboxOne, surface: "ui-05", app: app)
        try requireElement(checkboxTwo, surface: "ui-05", app: app)
        app.buttons["Select safe"].click()
        try auditSurface("ui-05-selection", app: app)
        app.buttons["Preview selected"].click()
        try requireElement(app.buttons["Import selected"], surface: "ui-05", app: app)
        try auditSurface("ui-05-preview", app: app)
        app.buttons["Import selected"].click()
        try requireElement(app.staticTexts["Batch import finished."], surface: "ui-05", app: app)
        try waitForProgressDisappearance("Importing selected Skills…", surface: "ui-05", app: app)
        try auditSurface("ui-05-results", app: app)
        app.buttons["Close"].click()
        app.terminate()

        let after = try snapshotFilesystem(childHome)
        XCTAssertEqual(
            after.managedSkillCount - baseline.managedSkillCount,
            2,
            "batch import must add exactly two managed Skills"
        )
        XCTAssertTrue(after.managedSkillNames.contains("Needs Import One"))
        XCTAssertTrue(after.managedSkillNames.contains("Needs Import Two"))
    }

    // MARK: - SM168-UI-06

    func testSM168UI06ArchiveSubsetImport() throws {
        try launchFixture(app: app, profile: "baseline", surface: "ui-06")
        let baseline = try settledSnapshot(surface: "ui-06")
        try openImportSheet(surface: "ui-06", app: app)
        let candidateOne = app.checkBoxes["fixture-one"]
        let candidateTwo = app.checkBoxes["fixture-two"]
        try requireElement(candidateOne, surface: "ui-06", app: app)
        try requireElement(candidateTwo, surface: "ui-06", app: app)
        try auditSurface("ui-06-archive-preview", app: app)

        app.buttons[SkillsManagerUILocators.archiveClearSelection].click()
        candidateOne.click()
        app.buttons[SkillsManagerUILocators.archiveReviewSelected].click()
        try requireElement(
            app.buttons[SkillsManagerUILocators.archiveConfirm],
            surface: "ui-06",
            app: app
        )
        try auditSurface("ui-06-archive-ready", app: app)
        app.buttons[SkillsManagerUILocators.archiveConfirm].click()
        try requireElement(app.staticTexts["Batch import finished."], surface: "ui-06", app: app)
        try waitForProgressDisappearance("Importing selected Skills…", surface: "ui-06", app: app)
        app.buttons["Close"].click()
        app.terminate()

        let after = try snapshotFilesystem(childHome)
        XCTAssertEqual(after.managedSkillCount - baseline.managedSkillCount, 1)
        XCTAssertTrue(after.managedSkillNames.contains("fixture-one"))
        XCTAssertFalse(after.managedSkillNames.contains("fixture-two"))
    }

    func testSM168UI06ArchiveCancelZeroWrite() throws {
        try launchFixture(app: app, profile: "baseline", surface: "ui-06-cancel")
        try openImportSheet(surface: "ui-06-cancel", app: app)
        try requireElement(app.checkBoxes["fixture-one"], surface: "ui-06-cancel", app: app)
        try requireElement(app.checkBoxes["fixture-two"], surface: "ui-06-cancel", app: app)
        try auditSurface("ui-06-cancel-preview", app: app)
        let before = try settledSnapshot(surface: "ui-06-cancel")
        app.buttons["Cancel"].click()
        try waitForDisappearance(
            app.staticTexts["Import Skill"],
            surface: "ui-06-cancel",
            app: app
        )
        app.terminate()
        try assertSnapshotUnchanged(before, home: childHome, surface: "ui-06-cancel", app: app)
    }

    // MARK: - SM168-UI-07

    func testSM168UI07RepositoryInstall() throws {
        try launchFixture(app: app, profile: "baseline", surface: "ui-07")
        let baseline = try settledSnapshot(surface: "ui-07")
        try setFilter("Repository", surface: "ui-07", app: app)
        let candidate = row(label: "Repository Fixture Skill", value: "Repository", app: app)
        try requireElement(candidate, surface: "ui-07", app: app)
        try auditSurface("ui-07-candidates", app: app)
        candidate.click()
        let reviewInstall = app.buttons[SkillsManagerUILocators.repositoryReviewInstall]
        try requireElement(reviewInstall, surface: "ui-07", app: app)
        try auditSurface("ui-07-candidate-detail", app: app)
        reviewInstall.click()
        let resolveButton = app.buttons["Resolve and Review…"]
        try requireElement(resolveButton, surface: "ui-07", app: app)
        try clickWhenHittable(resolveButton, surface: "ui-07", app: app)
        try waitForProgressDisappearance(
            "Resolving and validating GitHub source…",
            surface: "ui-07",
            app: app
        )
        try requireElement(app.buttons["Import"], surface: "ui-07", app: app)
        try auditSurface("ui-07-install-preview", app: app)
        app.buttons["Import"].click()
        let closeInstallResult = app.buttons[SkillsManagerUILocators.installResultClose]
        try requireElement(closeInstallResult, surface: "ui-07", app: app)
        try auditSurface("ui-07-install-result", app: app)
        closeInstallResult.click()
        let dismissResult = app.buttons[SkillsManagerUILocators.resultDismiss]
        try requireElement(dismissResult, surface: "ui-07-result-banner", app: app)
        dismissResult.click()
        try waitForDisappearance(dismissResult, surface: "ui-07-result-banner", app: app)
        app.terminate()

        let after = try snapshotFilesystem(childHome)
        XCTAssertEqual(after.managedSkillCount - baseline.managedSkillCount, 1)
        XCTAssertEqual(after.agentTargetNames.count - baseline.agentTargetNames.count, 1)
    }

    func testSM168UI07RepositoryCancelZeroWrite() throws {
        try launchFixture(app: app, profile: "baseline", surface: "ui-07-cancel")
        let baseline = try settledSnapshot(surface: "ui-07-cancel")
        try setFilter("Repository", surface: "ui-07-cancel", app: app)
        let candidate = row(label: "Repository Fixture Skill", value: "Repository", app: app)
        try requireElement(candidate, surface: "ui-07-cancel", app: app)
        candidate.click()
        let reviewInstall = app.buttons[SkillsManagerUILocators.repositoryReviewInstall]
        try requireElement(reviewInstall, surface: "ui-07-cancel", app: app)
        reviewInstall.click()
        try requireElement(
            app.buttons["Resolve and Review…"],
            surface: "ui-07-cancel",
            app: app
        )
        app.buttons["Cancel"].click()
        try waitForDisappearance(
            app.buttons["Resolve and Review…"],
            surface: "ui-07-cancel",
            app: app
        )
        app.terminate()
        try assertSnapshotUnchanged(baseline, home: childHome, surface: "ui-07-cancel", app: app)
    }

    // MARK: - SM168-UI-08

    func testSM168UI08EmptyKeyboardAndFocus() throws {
        try launchFixture(app: app, profile: "empty", surface: "ui-08")
        try waitForHierarchyText("No Skills found", surface: "ui-08", app: app)
        try waitForHierarchyText("No latest Skills", surface: "ui-08", app: app)
        try waitForHierarchyText("No GitHub reposito", surface: "ui-08", app: app)
        try auditSurface("ui-08-empty", app: app)

        app.typeKey("f", modifierFlags: .command)
        let searchField = app.searchFields.firstMatch
        try requireElement(searchField, surface: "ui-08", app: app)
        searchField.click()
        searchField.typeText("xyz")
        try waitForHierarchyText("No ClawHub results.", surface: "ui-08", app: app)
        try waitForHierarchyText("No skills.sh resul", surface: "ui-08", app: app)
        try auditSurface("ui-08-empty-search", app: app)
        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeKey(.delete, modifierFlags: [])

        // Status 键盘切换（⌘2 Managed / ⌘1 All）替换原 filter menu 键盘验证
        app.typeKey("2", modifierFlags: .command)
        try waitForHierarchyText("No local matches", surface: "ui-08", app: app)
        app.typeKey("1", modifierFlags: .command)
        try waitForHierarchyText("No Skills found", surface: "ui-08", app: app)

        let addMenu = app.menuButtons[SkillsManagerUILocators.addMenu]
        try requireElement(addMenu, surface: "ui-08", app: app)
        addMenu.click()
        let importItem = app.menuItems["Import Skill..."]
        try requireElement(importItem, surface: "ui-08", app: app)
        importItem.click()
        try requireElement(app.staticTexts["Import Skill"], surface: "ui-08", app: app)
        try auditSurface("ui-08-import-sheet", app: app)
        app.buttons["Cancel"].click()
        try waitForDisappearance(app.staticTexts["Import Skill"], surface: "ui-08", app: app)
        // Focus returns to the main window: the Add menu becomes interactive again
        // (the macOS KVC `hasFocus` query throws on some elements, so interaction
        // is the verification).
        addMenu.click()
        try requireElement(app.menuItems["Import Skill..."], surface: "ui-08", app: app)
        app.typeKey(.escape, modifierFlags: [])
        try auditSurface("ui-08-final", app: app)
    }

    // MARK: - SM183-UI-09

    func testSM183UI09DetailActionBar() throws {
        try launchFixture(app: app, profile: "detail-action-bar", surface: "ui-09")

        // Managed Skill → 固定操作条可见：徽章/来源/Agent chips/更新/批量更新/Finder/完整设置/删除
        try selectRow(label: "Fixture Managed", value: "Managed", surface: "ui-09", app: app)
        let badge = element(identifier: SkillsManagerUILocators.detailBadge, app: app)
        try requireElement(badge, surface: "ui-09", app: app)
        XCTAssertTrue(
            badge.label.contains("Managed"),
            "managed badge must read Managed; got: \(badge.label)"
        )
        try requireElement(
            element(identifier: "skills.detail.source.Local", app: app),
            surface: "ui-09",
            app: app
        )
        for key in ["codex", "claude", "opencode", "copilot"] {
            try requireElement(
                app.checkBoxes[SkillsManagerUILocators.detailAgent(key)],
                surface: "ui-09",
                app: app
            )
        }
        try requireElement(
            app.buttons[SkillsManagerUILocators.detailUpdate],
            surface: "ui-09",
            app: app
        )
        try requireElement(
            app.buttons[SkillsManagerUILocators.detailBatchUpdates],
            surface: "ui-09",
            app: app
        )
        try requireElement(
            app.buttons[SkillsManagerUILocators.detailFinder],
            surface: "ui-09",
            app: app
        )
        try requireElement(
            app.buttons[SkillsManagerUILocators.detailFullSettings],
            surface: "ui-09",
            app: app
        )
        try requireElement(
            app.buttons[SkillsManagerUILocators.detailDelete],
            surface: "ui-09",
            app: app
        )
        try auditSurface("ui-09-managed", app: app)

        // Agent chip 切换只修改 draft，选择状态立即反映
        let claudeChip = app.checkBoxes[SkillsManagerUILocators.detailAgent("claude")]
        XCTAssertEqual(
            (claudeChip.value as? NSNumber)?.intValue ?? -1,
            0,
            "Claude Code chip must start unselected; got: \(claudeChip.value ?? "")"
        )
        claudeChip.click()
        let selectedPredicate = NSPredicate(format: "value == %d", 1)
        let chipExpectation = XCTNSPredicateExpectation(predicate: selectedPredicate, object: claudeChip)
        let chipResult = XCTWaiter().wait(for: [chipExpectation], timeout: 10)
        guard chipResult == .completed else {
            attachDiagnostics("ui-09", app: app)
            throw SkillsManagerUIError.elementMissing("Claude Code chip selected state")
        }
        try auditSurface("ui-09-chips", app: app)

        // Needs Attention Skill → 徽章与状态反映
        try selectRow(label: "Fixture Broken", value: "Needs Attention", surface: "ui-09", app: app)
        let needsAttention = NSPredicate { _, _ in
            badge.exists && badge.label.contains("Needs Attention")
        }
        let attentionExpectation = XCTNSPredicateExpectation(predicate: needsAttention, object: nil)
        let attentionResult = XCTWaiter().wait(for: [attentionExpectation], timeout: 10)
        guard attentionResult == .completed else {
            attachDiagnostics("ui-09", app: app)
            throw SkillsManagerUIError.elementMissing("Needs Attention badge")
        }
        try auditSurface("ui-09-needs-attention", app: app)

        // 非匹配 discovery 项 → 操作条消失
        try selectRow(label: "Needs Import One", value: "Unmanaged", surface: "ui-09", app: app)
        try waitForDisappearance(badge, surface: "ui-09", app: app)
        XCTAssertFalse(
            app.buttons[SkillsManagerUILocators.detailUpdate].exists,
            "unmanaged discovery detail must not show the action bar"
        )
        try auditSurface("ui-09-unmanaged", app: app)
    }

    // MARK: - SM184-UI-10

    func testSM184UI10FilterBarAndRows() throws {
        try launchFixture(app: app, profile: "baseline", surface: "ui-10")

        // 筛选区可见：Status 分段 + Source/Agent chips
        try requireElement(
            app.buttons[SkillsManagerUILocators.filterStatus("all")],
            surface: "ui-10",
            app: app
        )
        try requireElement(
            app.buttons[SkillsManagerUILocators.filterSource("local")],
            surface: "ui-10",
            app: app
        )
        try requireElement(
            app.buttons[SkillsManagerUILocators.filterSource("clawhub")],
            surface: "ui-10",
            app: app
        )
        try requireElement(
            app.buttons[SkillsManagerUILocators.filterAgent("codex")],
            surface: "ui-10",
            app: app
        )

        // Source chip：ClawHub → 仅 ClawHub 行
        try clickFilter(SkillsManagerUILocators.filterSource("clawhub"), surface: "ui-10", app: app)
        try requireElement(
            row(label: "ClawHub Fixture 1", value: "Available", app: app),
            surface: "ui-10",
            app: app
        )
        XCTAssertFalse(
            row(label: "Fixture Managed", value: "Managed", app: app).exists,
            "ClawHub source filter must hide local rows"
        )
        try auditSurface("ui-10-source-clawhub", app: app)
        try clickFilter(SkillsManagerUILocators.filterSource("all"), surface: "ui-10", app: app)

        // 组合：Managed + Local → 仅 Fixture Managed
        try clickFilter(SkillsManagerUILocators.filterStatus("managed"), surface: "ui-10", app: app)
        try clickFilter(SkillsManagerUILocators.filterSource("local"), surface: "ui-10", app: app)
        try requireElement(
            row(label: "Fixture Managed", value: "Managed", app: app),
            surface: "ui-10",
            app: app
        )
        XCTAssertFalse(
            row(label: "ClawHub Fixture 1", value: "Available", app: app).exists,
            "combined Managed + Local must hide remote rows"
        )
        try auditSurface("ui-10-combined", app: app)

        // 清空恢复
        try clickFilter(SkillsManagerUILocators.filterStatus("all"), surface: "ui-10", app: app)
        try clickFilter(SkillsManagerUILocators.filterSource("all"), surface: "ui-10", app: app)
        try waitForShownCount(6, surface: "ui-10", app: app)

        // 折叠 → 摘要；展开 → chips 恢复
        try clickFilter(SkillsManagerUILocators.filterCollapse, surface: "ui-10", app: app)
        try requireElement(
            element(identifier: SkillsManagerUILocators.filterSummary, app: app),
            surface: "ui-10",
            app: app
        )
        try clickFilter(SkillsManagerUILocators.filterCollapse, surface: "ui-10", app: app)
        try requireElement(
            app.buttons[SkillsManagerUILocators.filterSource("local")],
            surface: "ui-10",
            app: app
        )

        // ⌘2 / ⌘1 键盘切换 Status
        app.typeKey("2", modifierFlags: .command)
        try requireElement(
            row(label: "Fixture Managed", value: "Managed", app: app),
            surface: "ui-10",
            app: app
        )
        XCTAssertFalse(
            row(label: "Needs Import One", value: "Unmanaged", app: app).exists,
            "⌘2 Managed must hide discovery rows"
        )
        app.typeKey("1", modifierFlags: .command)
        try waitForShownCount(6, surface: "ui-10", app: app)
        try auditSurface("ui-10-final", app: app)
    }

    // MARK: - SM185-UI-11

    func testSM185UI11FeedbackBadgesAndBanner() throws {
        try launchFixture(app: app, profile: "feedback", surface: "ui-11")

        // 更新可用（ClawHub provenance v1.0.0 vs remote v1.0.1）→ 行内绿徽章
        let updateRow = row(label: "ClawHub Managed", value: "Update available", app: app)
        try requireElement(updateRow, surface: "ui-11", app: app)
        try auditSurface("ui-11-update-badge", app: app)

        // 需修复 Skill → 行内黄徽章
        let repairRow = row(label: "Fixture Broken", value: "Needs Repair", app: app)
        try requireElement(repairRow, surface: "ui-11", app: app)
        try auditSurface("ui-11-repair-badge", app: app)

        // 无更新 Skill 不显示徽章
        XCTAssertFalse(
            (row(label: "Fixture Managed", value: "Managed", app: app)
                .value as? String)?.contains("Update available") == true,
            "Fixture Managed has no ClawHub provenance and must not show an update badge"
        )

        // 分发应用成功 → 详情顶部绿 banner
        try selectRow(label: "ClawHub Managed", value: "Update available", surface: "ui-11", app: app)
        try requireElement(
            app.checkBoxes[SkillsManagerUILocators.detailAgent("claude")],
            surface: "ui-11",
            app: app
        )
        let claudeChip = app.checkBoxes[SkillsManagerUILocators.detailAgent("claude")]
        if (claudeChip.value as? NSNumber)?.intValue == 0 {
            claudeChip.click()
        }
        let previewButton = app.buttons["Preview changes"]
        try requireElement(previewButton, surface: "ui-11", app: app)
        if !previewButton.isHittable {
            scrollDetailToReveal(previewButton, app: app)
        }
        previewButton.click()
        try requireElement(
            app.buttons["Apply"],
            surface: "ui-11",
            app: app
        )
        app.buttons["Apply"].click()
        try waitForDisappearance(
            app.buttons["Apply"],
            surface: "ui-11",
            app: app
        )
        // macOS 26 谓词查询已知超时（见 waitForHierarchyText 注释），
        // banner 断言使用 accessibility 层级文本搜索；debugDescription 会
        // 截断长 value，匹配 banner 独有前缀 "Result: Distributi"。
        try waitForHierarchyText("Result: Distributi", surface: "ui-11", app: app)
        try auditSurface("ui-11-banner", app: app)
        let dismissResult = app.buttons[SkillsManagerUILocators.resultDismiss]
        try requireElement(dismissResult, surface: "ui-11", app: app)
        dismissResult.click()
        try waitForDisappearance(dismissResult, surface: "ui-11", app: app)
    }

    // MARK: - SM194-UI-12

    func testSM194UI12NativeLocalization() throws {
        try launchLocalizedFixture(language: "zh-Hans", profile: "baseline", surface: "ui-12-zh")
        try requireElement(app.staticTexts["技能"], surface: "ui-12-zh", app: app)
        let zhStatus = app.buttons[SkillsManagerUILocators.filterStatus("all")]
        try requireElement(zhStatus, surface: "ui-12-zh", app: app)
        XCTAssertTrue(zhStatus.label.contains("所有状态"), "zh-Hans status label must be localized")
        try selectRow(label: "Fixture Managed", value: "已托管", surface: "ui-12-zh", app: app)
        try requireElement(
            element(identifier: SkillsManagerUILocators.detailUpdate, app: app),
            surface: "ui-12-zh-detail",
            app: app
        )
        try requireElement(
            element(identifier: SkillsManagerUILocators.detailFinder, app: app),
            surface: "ui-12-zh-action",
            app: app
        )
        try selectRow(label: "ClawHub Fixture 1", value: "可用", surface: "ui-12-zh-install", app: app)
        try waitForHierarchyText("安装", surface: "ui-12-zh-install", app: app)
        let installButton = app.buttons["skills.remote.install"]
        try requireElement(installButton, surface: "ui-12-zh-install-action", app: app)
        XCTAssertTrue(installButton.label.contains("安装"), "zh-Hans install accessibility label must be localized")
        installButton.click()
        try waitForHierarchyText("安装或更新 Skill", surface: "ui-12-zh-install-review", app: app)
        let cancelInstall = app.buttons["取消"]
        try requireElement(cancelInstall, surface: "ui-12-zh-install-review", app: app)
        cancelInstall.click()
    }

    func testSM194UI12NativeLocalizationEnglish() throws {
        try launchLocalizedFixture(language: "en", profile: "baseline", surface: "ui-12-en")
        try requireElement(app.staticTexts["Skills"], surface: "ui-12-en", app: app)
        let enStatus = app.buttons[SkillsManagerUILocators.filterStatus("all")]
        try requireElement(enStatus, surface: "ui-12-en", app: app)
        XCTAssertTrue(enStatus.label.contains("All Statuses"), "English status label must remain stable")
        try waitForShownCount(6, surface: "ui-12-en", app: app)
        try selectRow(label: "Fixture Managed", value: "Managed", surface: "ui-12-en-detail", app: app)
        try requireElement(
            element(identifier: SkillsManagerUILocators.detailUpdate, app: app),
            surface: "ui-12-en-action",
            app: app
        )
    }

    func testSM194UI12NativeLocalizationError() throws {
        try launchLocalizedFixture(language: "zh-Hans", profile: "failure-clawhub", surface: "ui-12-zh-error")
        try waitForHierarchyText("ClawHub 不可用", surface: "ui-12-zh-error", app: app)
        try auditSurface("ui-12-zh-error-state", app: app)
    }

    func testSM194UI12NativeLocalizationFeedbackDistribution() throws {
        try launchLocalizedFixture(language: "zh-Hans", profile: "feedback", surface: "ui-12-zh-feedback")
        try selectRow(label: "ClawHub Managed", value: "有可用更新", surface: "ui-12-zh-feedback", app: app)
        let updateAction = element(identifier: SkillsManagerUILocators.detailUpdate, app: app)
        try requireElement(updateAction, surface: "ui-12-zh-feedback-action", app: app)
        XCTAssertTrue(updateAction.label.contains("检查更新"), "zh-Hans update action must be localized")
        try requireElement(
            app.checkBoxes[SkillsManagerUILocators.detailAgent("claude")],
            surface: "ui-12-zh-feedback-distribution",
            app: app
        )
        let claudeChip = app.checkBoxes[SkillsManagerUILocators.detailAgent("claude")]
        if (claudeChip.value as? NSNumber)?.intValue == 0 {
            claudeChip.click()
        }
        let previewButton = app.buttons["预览更改"]
        try requireElement(previewButton, surface: "ui-12-zh-feedback-preview", app: app)
        if !previewButton.isHittable {
            scrollDetailToReveal(previewButton, app: app)
        }
        previewButton.click()
        let applyButton = app.buttons["应用"]
        try requireElement(applyButton, surface: "ui-12-zh-feedback-apply", app: app)
        applyButton.click()
        try waitForDisappearance(applyButton, surface: "ui-12-zh-feedback-apply", app: app)
        try waitForHierarchyText("结果：", surface: "ui-12-zh-feedback-banner", app: app)
        try auditSurface("ui-12-zh-feedback-banner", app: app)
    }

    func testSM194UI12NativeLocalizationUnsupportedFallback() throws {
        // No in-app language picker is involved: an unsupported App Language
        // follows the bundle's zh-Hans development/fallback localization.
        try launchLocalizedFixture(language: "ja", profile: "empty", surface: "ui-12-fallback")
        try requireElement(app.staticTexts["技能"], surface: "ui-12-fallback", app: app)
        try waitForHierarchyText("没有找到技能", surface: "ui-12-fallback", app: app)
        try auditSurface("ui-12-fallback-empty", app: app)
    }

    private func launchLocalizedFixture(
        language: String,
        profile: String,
        surface: String
    ) throws {
        try launchFixture(app: app, profile: profile, surface: surface, language: language)
    }

    private func scrollDetailToReveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<14 {
            if element.isHittable { return }
            app.typeKey(.pageDown, modifierFlags: [])
            usleep(120_000)
        }
    }

    // MARK: - Helpers

    private static let statusFilterKeys = [
        "All Statuses": "all", "Managed": "managed",
        "Needs Import": "needs-import", "Available": "available",
    ]
    private static let sourceFilterKeys = [
        "All Sources": "all", "Local": "local", "Repository": "repository",
        "ClawHub": "clawhub", "skills.sh": "skills-sh",
    ]
    private static let agentFilterKeys = [
        "All Agents": "all", "Codex": "codex", "Claude Code": "claude",
        "OpenCode": "opencode", "GitHub Copilot": "copilot",
    ]

    private func clickFilter(_ identifier: String, surface: String, app: XCUIApplication) throws {
        let button = app.buttons[identifier]
        try requireElement(button, surface: surface, app: app)
        // 窄窗口下筛选 chips 行可横向滚动，最右 chip 初始不可点；先滚动到可见。
        if !button.isHittable {
            scrollFilterRowToReveal(button, app: app)
        }
        button.click()
    }

    private func scrollFilterRowToReveal(_ button: XCUIElement, app: XCUIApplication) {
        let containerID: String
        if button.identifier.hasPrefix(SkillsManagerUILocators.filterStatus("")) {
            containerID = SkillsManagerUILocators.filterStatus("")
        } else if button.identifier.hasPrefix(SkillsManagerUILocators.filterSource("")) {
            containerID = SkillsManagerUILocators.filterSource("")
        } else {
            containerID = SkillsManagerUILocators.filterAgent("")
        }
        let row = app.scrollViews.matching(identifier: containerID).firstMatch
        for _ in 0..<8 {
            if button.isHittable { return }
            if !row.exists { return }
            row.swipeLeft()
            usleep(150_000)
        }
    }

    private func selectRow(
        label: String,
        value: String,
        surface: String,
        app: XCUIApplication
    ) throws {
        let candidate = row(label: label, value: value, app: app)
        try requireElement(candidate, surface: surface, app: app)
        candidate.click()
    }

    private func element(
        identifier: String,
        app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func setFilter(_ item: String, surface: String, app: XCUIApplication) throws {
        let candidates: [String?] = [
            Self.statusFilterKeys[item].map(SkillsManagerUILocators.filterStatus),
            Self.sourceFilterKeys[item].map(SkillsManagerUILocators.filterSource),
            Self.agentFilterKeys[item].map(SkillsManagerUILocators.filterAgent),
        ]
        guard let identifier = candidates.compactMap({ $0 }).first else {
            XCTFail("unknown filter item: \(item)")
            throw SkillsManagerUIError.elementMissing("filter \(item)")
        }
        try clickFilter(identifier, surface: surface, app: app)
    }

    private func openImportSheet(surface: String, app: XCUIApplication) throws {
        let addMenu = app.menuButtons[SkillsManagerUILocators.addMenu]
        try requireElement(addMenu, surface: surface, app: app)
        addMenu.click()
        let importItem = app.menuItems["Import Skill..."]
        try requireElement(importItem, surface: surface, app: app)
        importItem.click()
        try requireElement(app.staticTexts["Import Skill"], surface: surface, app: app)
    }

    private func openRepositorySheet(surface: String, app: XCUIApplication) throws {
        let addMenu = app.menuButtons[SkillsManagerUILocators.addMenu]
        try requireElement(addMenu, surface: surface, app: app)
        addMenu.click()
        let repositoryItem = app.menuItems["GitHub Repository..."]
        try requireElement(repositoryItem, surface: surface, app: app)
        repositoryItem.click()
        try requireElement(app.staticTexts["GitHub Repositories"], surface: surface, app: app)
    }

    private func waitForDisappearance(
        _ element: XCUIElement,
        surface: String,
        app: XCUIApplication
    ) throws {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: 10)
        guard result == .completed else {
            attachDiagnostics(surface, app: app)
            throw SkillsManagerUIError.progressStillVisible(element.description)
        }
    }

    private func settledSnapshot(surface: String) throws -> SkillsManagerUISnapshot {
        var previous = try snapshotFilesystem(childHome)
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 1.0)
            let current = try snapshotFilesystem(childHome)
            if current == previous { return current }
            previous = current
        }
        return previous
    }
}

private func posixLstat(_ url: URL) throws -> stat {
    var value = stat()
    guard Darwin.lstat(url.path, &value) == 0 else {
        throw CocoaError(.fileReadNoSuchFile)
    }
    return value
}
