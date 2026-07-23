import Darwin
import Foundation

nonisolated enum LibraryHealthInspector {
    private struct StoredSkill {
        let id: SkillID
        let fingerprint: SkillContentFingerprint
        let status: ManagedSkillStatus
    }

    private struct CleanupItem {
        let subjectID: String
        let locator: String
        let itemIdentity: ManagedItemIdentity
        let fingerprint: SkillContentFingerprint
        let rootIdentity: ManagedItemIdentity
    }

    static func inspect(
        connection: SQLiteConnection,
        ssotRoot: VerifiedSSOTRoot
    ) throws -> [LibraryRuntimeDiagnostic] {
        try ssotRoot.revalidate()
        let rootDescriptor = try ssotRoot.duplicateDescriptor()
        defer { Darwin.close(rootDescriptor) }
        let skills = try storedSkills(connection)
        let cleanupItems = try cleanupItems(connection)
        var diagnostics = cleanupItems.map {
            LibraryRuntimeDiagnostic.make(
                .cleanupDebt,
                subjectKind: .cleanup,
                subjectID: $0.subjectID
            )
        }
        let excluded = try verifiedCleanupLocators(
            cleanupItems,
            rootDescriptor: rootDescriptor,
            rootIdentity: ssotRoot.identity
        )
        let names = try SafeSourceTree.names(in: rootDescriptor, displayPath: "skills")
            .map(\.precomposedStringWithCanonicalMapping)
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let skillsByName = Dictionary(uniqueKeysWithValues: skills.map { ($0.id.directoryName, $0) })

        for skill in skills {
            let name = skill.id.directoryName
            if skill.status == .needsRepair {
                diagnostics.append(.make(
                    .journalNeedsRepair,
                    subjectKind: .skill,
                    subjectID: name
                ))
            }
            guard names.contains(name) else {
                diagnostics.append(.make(
                    .databaseSkillMissingDirectory,
                    subjectKind: .skill,
                    subjectID: name
                ))
                continue
            }
            do {
                let snapshot = try validatedSnapshot(
                    name: name,
                    rootDescriptor: rootDescriptor
                )
                if snapshot.fingerprintDigest != skill.fingerprint.digest {
                    diagnostics.append(.make(
                        .contentFingerprintDrift,
                        subjectKind: .skill,
                        subjectID: name
                    ))
                }
            } catch let error as ManagedPathError {
                diagnostics.append(.make(
                    error == .rootReplaced ? .rootIdentityChanged : .permissionDenied,
                    subjectKind: .skill,
                    subjectID: name
                ))
            } catch {
                diagnostics.append(.make(
                    .contentFingerprintDrift,
                    subjectKind: .skill,
                    subjectID: name
                ))
            }
        }

        for name in names where skillsByName[name] == nil && !excluded.contains(name) {
            let code: LibraryDiagnosticCode
            if isLowercaseUUID(name), isDirectory(name, rootDescriptor: rootDescriptor) {
                code = .orphanSSOTDirectory
            } else {
                code = .unknownSSOTEntry
            }
            diagnostics.append(.make(code, subjectKind: .ssot, subjectID: name))
        }

        return LibraryRuntimeDiagnostic.normalized(diagnostics)
    }

    private static func storedSkills(_ connection: SQLiteConnection) throws -> [StoredSkill] {
        let statement = try connection.prepare(
            """
            SELECT skill_id, fingerprint_algorithm_version, content_fingerprint, status
            FROM skills ORDER BY skill_id
            """
        )
        var skills: [StoredSkill] = []
        while try statement.step() {
            guard let id = statement.blob(at: 0),
                  let digest = statement.blob(at: 2),
                  let statusValue = statement.text(at: 3),
                  let status = ManagedSkillStatus(rawValue: statusValue) else {
                throw SQLiteStoreError.invalidState("stored Skill health record is invalid")
            }
            skills.append(StoredSkill(
                id: try SkillID(bytes: id),
                fingerprint: try SkillContentFingerprint(
                    algorithmVersion: Int(statement.int64(at: 1)),
                    digest: digest
                ),
                status: status
            ))
        }
        return skills
    }

    private static func cleanupItems(_ connection: SQLiteConnection) throws -> [CleanupItem] {
        let statement = try connection.prepare(
            """
            SELECT cleanup_debt_id, recovery_locator, expected_item_identity,
              expected_fingerprint_algorithm_version, expected_content_fingerprint,
              expected_root_identity
            FROM cleanup_debts ORDER BY cleanup_debt_id
            """
        )
        var items: [CleanupItem] = []
        while try statement.step() {
            guard let debtID = statement.blob(at: 0),
                  let locator = statement.text(at: 1),
                  let itemIdentity = statement.blob(at: 2),
                  let digest = statement.blob(at: 4),
                  let rootIdentity = statement.blob(at: 5) else {
                throw SQLiteStoreError.invalidState("cleanup debt health record is invalid")
            }
            items.append(CleanupItem(
                subjectID: try SSOTCleanupDebtID(bytes: debtID).uuid.uuidString.lowercased(),
                locator: locator,
                itemIdentity: try ManagedItemIdentityCodec.decode(itemIdentity),
                fingerprint: try SkillContentFingerprint(
                    algorithmVersion: Int(statement.int64(at: 3)),
                    digest: digest
                ),
                rootIdentity: try ManagedItemIdentityCodec.decode(rootIdentity)
            ))
        }
        return items
    }

    private static func verifiedCleanupLocators(
        _ items: [CleanupItem],
        rootDescriptor: Int32,
        rootIdentity: ManagedItemIdentity
    ) throws -> Set<String> {
        var locators = Set<String>()
        for item in items where item.rootIdentity == rootIdentity {
            guard isDirectChild(item.locator) else { continue }
            var metadata = stat()
            guard Darwin.fstatat(
                rootDescriptor,
                item.locator,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0, ManagedItemIdentity(metadata) == item.itemIdentity else {
                continue
            }
            guard let snapshot = try? validatedSnapshot(
                name: item.locator,
                rootDescriptor: rootDescriptor
            ), snapshot.fingerprintDigest == item.fingerprint.digest else {
                continue
            }
            locators.insert(item.locator)
        }
        return locators
    }

    private static func validatedSnapshot(
        name: String,
        rootDescriptor: Int32
    ) throws -> SkillContentSnapshot {
        let descriptor = Darwin.openat(
            rootDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ManagedPathError.posix(operation: "open SSOT child", code: errno)
        }
        defer { Darwin.close(descriptor) }
        let identity = try ManagedItemIdentityCodec.capture(descriptor: descriptor)
        try VerifiedSSOTRoot.validateDescriptor(descriptor, expectedIdentity: identity)
        return try SkillContentSnapshot.capture(
            directoryDescriptor: descriptor,
            displayPath: name
        )
    }

    private static func isDirectory(_ name: String, rootDescriptor: Int32) -> Bool {
        var metadata = stat()
        return Darwin.fstatat(
            rootDescriptor,
            name,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0 && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private static func isLowercaseUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func isDirectChild(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }
}
