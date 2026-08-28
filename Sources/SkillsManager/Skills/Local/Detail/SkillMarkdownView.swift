import MarkdownUI
import SwiftUI

struct SkillMarkdownView: View {
    @Environment(SkillStore.self) private var store
    @Environment(RemoteSkillStore.self) private var remoteStore
    @Environment(SkillUpdateBadgeStore.self) private var badgeStore

    let skill: Skill
    let markdown: String

    @State private var needsPublish = false
    @State private var isOwned = false
    @State private var clawdhubOrigin: SkillStore.ClawdhubOrigin?
    @State private var installedVersion: String?
    @State private var latestVersion: String?
    @State private var updateAvailable = false
    @State private var isCheckingPublish = false
    @State private var publishSheetSkill: Skill?
    @State private var changelog = ""
    @State private var tags = "latest"
    @State private var bump: PublishBump = .patch
    @State private var publishedVersion: String?
    @State private var cliStatus = SkillStore.CliStatus(
        isInstalled: false,
        isLoggedIn: false,
        username: nil,
        errorMessage: nil
    )
    @State private var isCheckingCli = false

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                SkillDetailActionBar(
                    skill: skill,
                    onFullSettings: {
                        withAnimation {
                            proxy.scrollTo(
                                "skill-distribution-editor",
                                anchor: .top
                            )
                        }
                    }
                )
                SkillDetailFeedbackBanner(subject: .managed(skill.id))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if isOwned {
                            publishSection
                        } else if clawdhubOrigin != nil {
                            installSection
                        }
                        Markdown(markdown)
                            .textSelection(.enabled)

                        if !skill.references.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("References", bundle: SkillsManagerLocalizationResources.bundle)
                                    .font(.title2.bold())
                                ReferenceListView(references: skill.references)
                            }
                            .padding(.top, 8)
                        }

                        Divider()
                            .padding(.vertical, 4)

                        Text("Manage Skill", bundle: SkillsManagerLocalizationResources.bundle)
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)

                        SkillDistributionView()
                            .id("skill-distribution-editor")
                        SkillUpdateCheckView()
                        SkillDeletionView()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
        }
        .navigationTitle(skill.displayName)
        .navigationSubtitle(skill.folderPath)
        .toolbar {
            if clawdhubURL != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openClawdhubURL()
                    } label: {
                        Image(systemName: "globe")
                    }
                    .help(Text("Open on ClawHub", bundle: SkillsManagerLocalizationResources.bundle))
                }
            }
        }
        .task(id: skill.id) {
            await refreshPublishState()
        }
        .sheet(item: $publishSheetSkill, onDismiss: {
            Task { await refreshPublishState() }
        }) {
            PublishSkillSheet(
                skillID: $0.managedSkillID,
                displayName: $0.displayName,
                nextVersion: nextPublishVersion,
                publishedVersion: publishedVersion,
                bump: $bump,
                changelog: $changelog,
                tags: $tags
            )
            .environment(store)
        }
    }

    private var publishSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            publishHeader
            publishContent
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var publishHeader: some View {
        HStack(spacing: 8) {
            Text("ClawHub", bundle: SkillsManagerLocalizationResources.bundle)
                .font(.headline)
            Spacer()
            if isCheckingPublish || isCheckingCli {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
    }

    @ViewBuilder
    private var publishContent: some View {
        if skill.managedStatus == .needsRepair {
            Text("This managed Skill needs repair before it can be published.", bundle: SkillsManagerLocalizationResources.bundle)
                .foregroundStyle(.secondary)
        } else if isCheckingCli || isCheckingPublish {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking ClawHub status…", bundle: SkillsManagerLocalizationResources.bundle)
                    .foregroundStyle(.secondary)
            }
        } else {
            // 前置条件步骤化：安装 Bun → CLI 登录 → 发布；已完成步骤打勾，
            // 当前步骤给出可执行动作，避免"去终端跑命令"式的裸文案。
            VStack(alignment: .leading, spacing: 8) {
                publishStepRow(
                    index: 1,
                    title: Text("Install Bun", bundle: SkillsManagerLocalizationResources.bundle),
                    done: cliStatus.isInstalled,
                    detail: { publishInstallContent }
                )
                publishStepRow(
                    index: 2,
                    title: Text("Log in to the ClawHub CLI", bundle: SkillsManagerLocalizationResources.bundle),
                    done: cliStatus.isLoggedIn,
                    detail: { publishLoginContent }
                )
                if cliStatus.isInstalled && cliStatus.isLoggedIn {
                    publishStepRow(
                        index: 3,
                        title: Text("Publish or update", bundle: SkillsManagerLocalizationResources.bundle),
                        done: false,
                        detail: { publishReadyContent }
                    )
                }
            }
        }
    }

    private func publishStepRow(
        index: Int,
        title: Text,
        done: Bool,
        @ViewBuilder detail: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                title.font(.callout.weight(.medium))
                if !done {
                    detail()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var publishInstallContent: some View {
        Text("Install Bun to run the ClawHub CLI.", bundle: SkillsManagerLocalizationResources.bundle)
            .foregroundStyle(.secondary)
    }

    private var publishLoginContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run bunx clawdhub@latest login in Terminal, then check again.", bundle: SkillsManagerLocalizationResources.bundle)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    copyLoginCommand()
                } label: {
                    Text("Copy login command", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await refreshPublishState() }
                } label: {
                    Text("Check again", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .buttonStyle(.bordered)
                .disabled(isCheckingCli)
            }
        }
        .onAppear {
            // 复制命令后大概率已完成登录：到达该步骤时自动刷新一次状态，
            // 减少手动 Check again 轮询；失败时仍可手动重试。
            Task { await refreshPublishState() }
        }
    }

    private var publishReadyContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let username = cliStatus.username {
                Text(String(
                    localized: LocalizedStringResource(
            "Signed in as \(username)",
            bundle: SkillsManagerLocalizationResources.bundle
        )))
                    .foregroundStyle(.secondary)
            }

            if let publishedVersion {
                Text(String(
                    localized: LocalizedStringResource(
            "Latest version \(publishedVersion)",
            bundle: SkillsManagerLocalizationResources.bundle
        )))
                    .foregroundStyle(.secondary)
                Text(needsPublish
                    ? "Changes detected. Publish an update."
                    : "No unpublished changes.", bundle: SkillsManagerLocalizationResources.bundle)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not yet published on ClawHub.", bundle: SkillsManagerLocalizationResources.bundle)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    publishSheetSkill = skill
                } label: {
                    Text(publishedVersion == nil ? "Publish to ClawHub" : "Update on ClawHub", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .buttonStyle(.borderedProminent)

                if !needsPublish {
                    TagView(localized: "Up to date", tint: .green)
                }
            }
        }
    }

    private var installSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            publishHeader
            installContent
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    @ViewBuilder
    private var installContent: some View {
        if isCheckingPublish {
            Text("Checking ClawHub status…", bundle: SkillsManagerLocalizationResources.bundle)
                .foregroundStyle(.secondary)
        } else {
            if let installedVersion {
                Text(String(
                    localized: LocalizedStringResource(
            "Installed version \(installedVersion)",
            bundle: SkillsManagerLocalizationResources.bundle
        )))
                    .foregroundStyle(.secondary)
            }
            if let latestVersion, updateAvailable {
                Text(String(
                    localized: LocalizedStringResource(
            "Update available: v\(latestVersion)",
            bundle: SkillsManagerLocalizationResources.bundle
        )))
                    .foregroundStyle(.secondary)
            } else if latestVersion != nil {
                Text("You’re up to date.", bundle: SkillsManagerLocalizationResources.bundle)
                    .foregroundStyle(.secondary)
            }

        }
    }

    private func refreshPublishState() async {
        resetPublishState()
        let owned = store.isOwnedSkill(skill)
        isOwned = owned
        if owned {
            await refreshOwnedState()
        } else {
            await refreshInstalledState()
        }
    }

    private func refreshOwnedState() async {
        guard skill.managedStatus == .managed else { return }
        isCheckingCli = true
        cliStatus = await store.fetchClawdhubStatus()
        isCheckingCli = false
        if cliStatus.isInstalled && cliStatus.isLoggedIn {
            isCheckingPublish = true
            async let publishCheck = store.skillNeedsPublish(skill)
            async let versionCheck = fetchPublishedVersion()
            needsPublish = await publishCheck
            publishedVersion = await versionCheck
            isCheckingPublish = false
        }
    }

    private func refreshInstalledState() async {
        isCheckingPublish = true
        let origin = await store.clawdhubOrigin(for: skill)
        clawdhubOrigin = origin
        installedVersion = origin?.version
        guard let origin else {
            isCheckingPublish = false
            return
        }
        let badgeGeneration = badgeStore.refreshGeneration
        let latest = await fetchLatestVersion(slug: origin.slug)
        latestVersion = latest
        if let latest, let installed = installedVersion {
            updateAvailable = store.isNewerVersion(latest, than: installed)
        } else {
            updateAvailable = false
        }
        badgeStore.backfill(
            skill,
            latestVersion: latest,
            generation: badgeGeneration
        )
        isCheckingPublish = false
    }

    private func resetPublishState() {
        isOwned = false
        needsPublish = false
        clawdhubOrigin = nil
        installedVersion = nil
        latestVersion = nil
        updateAvailable = false
        publishedVersion = nil
        cliStatus = SkillStore.CliStatus(
            isInstalled: false,
            isLoggedIn: false,
            username: nil,
            errorMessage: nil
        )
        isCheckingCli = false
        isCheckingPublish = false
    }

    private func copyLoginCommand() {
        let command = "bunx clawdhub@latest login"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
            pasteboard.setString(command, forType: .string)
    }

    private func openInstallDocs() {
        guard let url = URL(string: "https://bun.sh") else { return }
        NSWorkspace.shared.open(url)
    }

    private var clawdhubURL: URL? {
        let slug = isOwned ? skill.name : clawdhubOrigin?.slug
        guard let slug else { return nil }
        return URL(string: "https://clawdhub.com/skills/\(slug)")
    }

    private func openClawdhubURL() {
        guard let url = clawdhubURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func fetchPublishedVersion() async -> String? {
        do {
            return try await remoteStore.client.fetchLatestVersion(skill.name)
        } catch {
            return nil
        }
    }

    private func fetchLatestVersion(slug: String) async -> String? {
        do {
            return try await remoteStore.client.fetchLatestVersion(slug)
        } catch {
            return nil
        }
    }

    private var nextPublishVersion: String {
        if let publishedVersion,
           let next = store.nextVersion(from: publishedVersion, bump: bump) {
            return next
        }
        return "1.0.0"
    }

}
