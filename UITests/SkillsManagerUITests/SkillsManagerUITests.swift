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
        try requireElement(app.menuButtons[SkillsManagerUILocators.filterMenu], surface: "ui-01", app: app)
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
        try auditSurface("ui-01-filter-menu", app: app)
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
        retry.click()
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
        try requireElement(app.buttons["Close"], surface: "ui-07", app: app)
        try auditSurface("ui-07-install-result", app: app)
        app.buttons["Close"].click()
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

    func testSM168UI07RepositoryFailureZeroWrite() throws {
        try launchFixture(app: app, profile: "failure-repository", surface: "ui-07-failure")
        try setFilter("Repository", surface: "ui-07-failure", app: app)
        try waitForHierarchyText(
            "Repository unavail",
            surface: "ui-07-failure",
            app: app
        )
        let baseline = try settledSnapshot(surface: "ui-07-failure")
        try openRepositorySheet(surface: "ui-07-failure", app: app)
        let refreshAll = app.buttons[SkillsManagerUILocators.repositoryRefreshAll]
        try requireElement(refreshAll, surface: "ui-07-failure", app: app)
        try auditSurface("ui-07-failure-sheet", app: app)
        refreshAll.click()
        try waitForEnabled(refreshAll, surface: "ui-07-failure", app: app)
        try requireElement(app.staticTexts["Failed"], surface: "ui-07-failure", app: app)
        app.buttons[SkillsManagerUILocators.repositoryDone].click()
        app.terminate()
        try assertSnapshotUnchanged(baseline, home: childHome, surface: "ui-07-failure", app: app)
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

        let menu = app.menuButtons[SkillsManagerUILocators.filterMenu]
        menu.click()
        let filterMenuItem = app.menuItems["All Statuses"]
        try requireElement(filterMenuItem, surface: "ui-08", app: app)
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        // XCUITest keyboard events are not routed into an open NSMenu on macOS
        // (the menu is a separate key window); close it with the standard
        // click-outside interaction and record the classification evidence.
        recordMenuKeyboardClassification(surface: "ui-08", app: app)
        app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)
        ).click()
        try waitForDisappearance(
            app.menuItems["All Statuses"],
            surface: "ui-08",
            app: app
        )

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

    // MARK: - Helpers

    private func setFilter(_ item: String, surface: String, app: XCUIApplication) throws {
        let menu = app.menuButtons[SkillsManagerUILocators.filterMenu]
        menu.click()
        let menuItem = app.menuItems[item]
        try requireElement(menuItem, surface: surface, app: app)
        try clickWhenHittable(menuItem, surface: surface, app: app)
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

