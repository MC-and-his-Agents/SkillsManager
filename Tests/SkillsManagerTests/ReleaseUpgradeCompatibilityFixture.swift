import Darwin
import Foundation
import Testing

@testable import SkillsManager

struct ReleaseV010Fixture {
    // v0.1.0 release commit: 480316947d5df2c95c5f3775c1ed991f4e9549bc.
    let workspace: WriterWorkspace
    let skillID = SkillID(UUID(uuidString: "00112233-4455-4677-8899-aabbccddeeff")!)
    let sourceID = SourceID(UUID(uuidString: "11112222-3333-4444-8555-666677778888")!)
    let operationID = SSOTOperationID(
        UUID(uuidString: "99990000-1111-4222-8333-444455556666")!
    )
    let backupID = SkillBackupID(
        UUID(uuidString: "aaaa0000-1111-4222-8333-444455556666")!
    )
    let slug = "release-fixture"
    let backupRecord: SkillBackupRecord
    var skillIDHex: String { skillID.bytes.hex }

    init() throws {
        workspace = try WriterWorkspace(distributionEnabled: true)
        let skillRoot = workspace.root.appendingPathComponent(
            skillID.directoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: false)
        guard Darwin.chmod(skillRoot.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        try Data("# v0.1.0 release fixture".utf8).write(
            to: skillRoot.appendingPathComponent("SKILL.md"),
            options: .atomic
        )
        let snapshot = try SkillContentSnapshot.capture(at: skillRoot)
        let payload = try ReleaseV010ArtifactBuilder.payload(
            skillID: skillID,
            sourceID: sourceID,
            slug: slug,
            snapshot: snapshot
        )
        backupRecord = try ReleaseV010ArtifactBuilder.createBackup(
            workspace: workspace,
            backupID: backupID,
            payload: payload,
            snapshot: snapshot,
            slug: slug
        )

        let globalRoot = workspace.distributionHomeURL
            .appendingPathComponent(".agents/skills", isDirectory: true)
        try FileManager.default.createDirectory(
            at: globalRoot,
            withIntermediateDirectories: true
        )
        let target = globalRoot.appendingPathComponent(slug)
        try FileManager.default.createSymbolicLink(
            atPath: target.path,
            withDestinationPath: skillRoot.path
        )

        let connection = try Self.createV11Database(at: workspace.database)
        try connection.execute("BEGIN IMMEDIATE")
        do {
            try insertBusinessRows(
                connection,
                snapshot: snapshot,
                skillRoot: skillRoot,
                globalRoot: globalRoot,
                target: target
            )
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
        try SkillSchemaMigrator.validateV11(connection)
        try connection.execute("PRAGMA journal_mode = WAL")
        try connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    func databaseSnapshot() throws -> [String] {
        let connection = try SQLiteConnection(url: workspace.database, accessMode: .readOnly)
        return [
            "\(try connection.querySingleInt("PRAGMA user_version") ?? -1)",
            try SkillSchemaInspection.schemaFingerprint(
                connection,
                objectNames: SkillSchemaV11.fingerprintedObjectNames
            ).base64EncodedString(),
            try rows(connection, "SELECT hex(skill_id)||'|'||display_name||'|'||hex(content_fingerprint)||'|'||status||'|'||db_revision FROM skills ORDER BY skill_id"),
            try rows(connection, "SELECT hex(source_id)||'|'||hex(skill_id)||'|'||normalized_repository_url||'|'||normalized_subpath||'|'||revision||'|'||version FROM sources ORDER BY source_id"),
            try rows(connection, "SELECT hex(source_id)||'|'||provider||'|'||provider_identifier FROM provider_aliases ORDER BY source_id, provider"),
            try rows(connection, "SELECT hex(skill_id)||'|'||provider||'|'||provider_identifier||'|'||provider_identifier_key||'|'||provider_version FROM provider_provenance ORDER BY skill_id, provider"),
            try rows(connection, "SELECT hex(skill_id)||'|'||target_scope_key||'|'||distribution_slug||'|'||sync_mode FROM distribution_bindings ORDER BY skill_id, target_scope_key"),
            try rows(connection, "SELECT hex(skill_id)||'|'||target_scope_key||'|'||hex(applied_operation_id)||'|'||hex(root_identity)||'|'||hex(entry_identity)||'|'||absolute_link_target FROM distribution_link_ownership ORDER BY skill_id, target_scope_key"),
            try rows(connection, "SELECT hex(backup_id)||'|'||hex(original_skill_id)||'|'||state||'|'||locator||'|'||pinned FROM skill_backups ORDER BY backup_id"),
            try rows(connection, "SELECT runtime_locator||'|'||last_published_hash||'|'||last_published_at_ms FROM publish_states ORDER BY runtime_locator"),
            try rows(connection, "SELECT hex(skill_id)||'|'||source_runtime_locator||'|'||last_published_hash||'|'||last_published_at_ms FROM managed_publish_states ORDER BY skill_id"),
            try rows(connection, "SELECT hex(operation_id)||'|'||hex(skill_id)||'|'||phase||'|'||outcome FROM distribution_operations ORDER BY operation_id"),
        ]
    }

    func fileTreeSnapshot() throws -> [String] {
        try treeSnapshot(workspace.root)
            + treeSnapshot(
                workspace.managementRoot.appendingPathComponent(
                    "skill-backups",
                    isDirectory: true
                )
            )
            + treeSnapshot(
                workspace.distributionHomeURL.appendingPathComponent(
                    ".agents",
                    isDirectory: true
                )
            )
    }

    func assertCatalogAndDomain(_ writer: JournaledSSOTWriter) async throws {
        let catalog = try await writer.managedLocalCatalogReadback()
        let local = try #require(catalog.skills.first)
        #expect(catalog.skills.count == 1)
        #expect(local.skill.skillID == skillID)
        #expect(local.skill.status == .managed)
        #expect(local.source?.repositoryURL.value == "https://github.com/example/release-skill")
        #expect(local.source?.subpath.value == "skills/release")
        #expect(local.providerProvenance.first?.identity.provider == "clawdhub")
        #expect(local.providerProvenance.first?.identity.identifier == slug)
        #expect(local.bindings.first?.scope == .global)
        #expect(local.bindings.first?.syncMode == .symlink)
        #expect(local.bindings.first?.copyBaseline == nil)
        #expect(local.forkLineage == nil)

        let domain = try #require(await writer.storedDomainReadback(skillID))
        #expect(domain.payload.providerAliases.first?.identity.identifier == slug)
        #expect(domain.payload.providerProvenance.first?.version?.value == "0.1.0")
        #expect(
            try await writer.providerProvenance(
                ProviderAliasIdentity(provider: "clawdhub", identifier: slug)
            )?.skillID == skillID
        )
        #expect(
            try await writer.loadManagedPublishState(skillID)
                == SQLitePublishState(
                    lastPublishedHash: "v0.1.0-release-hash",
                    lastPublishedAtMilliseconds: 100,
                    hashAlgorithmVersion: 1
                )
        )
    }

    func assertBackupIsRestorable(_ writer: JournaledSSOTWriter) async throws {
        let connection = try SQLiteConnection(url: workspace.database)
        let loaded = try SkillBackupStore(connection: connection).load(backupID)
        let stored = try #require(loaded)
        #expect(stored == backupRecord)

        let preview = try await writer.restorePreview(backupID)
        #expect(preview.backupID == backupID)
        #expect(preview.originalSkillID == skillID)
        #expect(preview.status == .noOp)
        #expect(preview.summary.content.displayName == "Release Fixture")
        #expect(
            preview.summary.sourceLocator
                == "https://github.com/example/release-skill#skills/release"
        )
        #expect(preview.summary.targets.count == 1)
    }

    func assertOperationIsDecodable() throws {
        let record = try DistributionOperationStore(
            connection: SQLiteConnection(url: workspace.database)
        ).load(operationID)
        #expect(record.skillID == skillID)
        #expect(record.phase == .completed)
        #expect(record.outcome == .applied)
        #expect(record.planPayload != Data("{}".utf8))
    }

    private static func createV11Database(at url: URL) throws -> SQLiteConnection {
        let connection = try SQLiteConnection(url: url)
        for statement in SkillSchemaV1.statements { try connection.execute(statement) }
        try connection.execute(
            "INSERT INTO schema_metadata(singleton, schema_version) VALUES (1, 11)"
        )
        for statements in [
            SkillSchemaV2.statements,
            SkillSchemaV3.statements,
            SkillSchemaV4.statements,
            SkillSchemaV5.statements,
            SkillSchemaV6.statements,
            SkillSchemaV7.statements,
            SkillSchemaV8.statements,
            SkillSchemaV9.statements,
            SkillSchemaV10.statements,
            SkillSchemaV11.statements,
        ] {
            for statement in statements { try connection.execute(statement) }
        }
        try connection.execute("PRAGMA user_version = 11")
        return connection
    }

    private func insertBusinessRows(
        _ connection: SQLiteConnection,
        snapshot: SkillContentSnapshot,
        skillRoot: URL,
        globalRoot: URL,
        target: URL
    ) throws {
        try connection.execute(
            """
            INSERT INTO legacy_migration_ledger(
              singleton, migration_version, status, inventory_digest, inventory_entry_count,
              custom_paths_file_present, custom_path_count, publish_state_count, completed_at_ms
            ) VALUES (1, 1, 'completed', zeroblob(32), 0, 0, 0, 0, 1)
            """
        )
        try execute(
            connection,
            """
            INSERT INTO skills(
              skill_id, display_name, default_distribution_slug, default_slug_key,
              fingerprint_algorithm_version, content_fingerprint, status,
              created_at_ms, updated_at_ms, db_revision, restored_from_skill_id
            ) VALUES (?, 'Release Fixture', ?, ?, 1, ?, 'managed', 10, 20, 3, NULL)
            """,
            [.blob(skillID.bytes), .text(slug), .text(slug), .blob(snapshot.fingerprintDigest)]
        )
        try execute(
            connection,
            """
            INSERT INTO sources(
              source_id, skill_id, normalized_repository_url, normalized_subpath,
              revision, version, download_url
            ) VALUES (?, ?, 'https://github.com/example/release-skill',
              'skills/release', '480316947d5df2c95c5f3775c1ed991f4e9549bc',
              '0.1.0', 'https://github.com/example/release-skill/archive/4803169.zip')
            """,
            [.blob(sourceID.bytes), .blob(skillID.bytes)]
        )
        try execute(
            connection,
            "INSERT INTO provider_aliases(source_id, provider, provider_identifier) VALUES (?, 'clawdhub', ?)",
            [.blob(sourceID.bytes), .text(slug)]
        )
        try execute(
            connection,
            """
            INSERT INTO provider_provenance(
              skill_id, provider, provider_identifier, provider_identifier_key, provider_version
            ) VALUES (?, 'clawdhub', ?, ?, '0.1.0')
            """,
            [.blob(skillID.bytes), .text(slug), .text(slug)]
        )
        try execute(
            connection,
            """
            INSERT INTO distribution_bindings(
              skill_id, scope_kind, adapter_code, target_scope_key,
              distribution_slug, slug_key, sync_mode, created_at_ms, updated_at_ms
            ) VALUES (?, 'global', NULL, 'global', ?, ?, 'symlink', 30, 40)
            """,
            [.blob(skillID.bytes), .text(slug), .text(slug)]
        )
        try ReleaseV010ArtifactBuilder.insertCompletedOperation(
            connection: connection,
            operationID: operationID,
            skillID: skillID,
            skillRoot: skillRoot
        )
        try execute(
            connection,
            """
            INSERT INTO distribution_link_ownership(
              skill_id, target_scope_key, applied_operation_id, root_identity,
              entry_identity, absolute_link_target, verified_at_ms
            ) VALUES (?, 'global', ?, ?, ?, ?, 40)
            """,
            [
                .blob(skillID.bytes),
                .blob(operationID.bytes),
                .blob(try itemIdentity(at: globalRoot)),
                .blob(try itemIdentity(at: target)),
                .text(skillRoot.path),
            ]
        )
        try execute(
            connection,
            """
            INSERT INTO skill_backups(
              backup_id, format_version, original_skill_id, state, locator,
              directory_identity, manifest_digest, fingerprint_algorithm_version,
              content_fingerprint, pinned, created_at_ms, updated_at_ms
            ) VALUES (?, 1, ?, 'available', ?, ?, ?, 1, ?, 1, 50, 50)
            """,
            [
                .blob(backupID.bytes),
                .blob(skillID.bytes),
                .text(backupRecord.locator),
                .blob(try ManagedItemIdentityCodec.encode(backupRecord.directoryIdentity)),
                .blob(backupRecord.manifestDigest),
                .blob(snapshot.fingerprintDigest),
            ]
        )
        try connection.execute(
            """
            INSERT INTO publish_states(
              runtime_locator, source_legacy_locator, last_published_hash,
              last_published_at_ms, hash_algorithm_version
            ) VALUES ('skill-state/release-fixture.json', NULL, 'v0.1.0-release-hash', 100, 1)
            """
        )
        try execute(
            connection,
            """
            INSERT INTO managed_publish_states(
              skill_id, source_runtime_locator, last_published_hash,
              last_published_at_ms, hash_algorithm_version
            ) VALUES (?, 'skill-state/release-fixture.json', 'v0.1.0-release-hash', 100, 1)
            """,
            [.blob(skillID.bytes)]
        )
    }

}

private enum FixtureValue {
    case blob(Data)
    case text(String)
}

private func execute(
    _ connection: SQLiteConnection,
    _ sql: String,
    _ values: [FixtureValue]
) throws {
    let statement = try connection.prepare(sql)
    for (offset, value) in values.enumerated() {
        switch value {
        case .blob(let data): try statement.bind(data, at: Int32(offset + 1))
        case .text(let text): try statement.bind(text, at: Int32(offset + 1))
        }
    }
    _ = try statement.step()
}

private func itemIdentity(at url: URL) throws -> Data {
    var metadata = stat()
    guard Darwin.lstat(url.path, &metadata) == 0 else {
        throw CocoaError(.fileReadUnknown)
    }
    return try ManagedItemIdentityCodec.encode(ManagedItemIdentity(metadata))
}

private func rows(_ connection: SQLiteConnection, _ sql: String) throws -> String {
    try SkillSchemaInspection.textValues(connection, sql: sql).joined(separator: "\n")
}

private func treeSnapshot(_ root: URL) throws -> [String] {
    let urls = [root] + (FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil
    )?.compactMap { $0 as? URL } ?? [])
    return try urls.map { url in
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        let relative = url == root ? "." : String(url.path.dropFirst(root.path.count))
        let kind = metadata.st_mode & mode_t(S_IFMT)
        let payload: String
        if kind == S_IFREG {
            payload = try Data(contentsOf: url).base64EncodedString()
        } else if kind == S_IFLNK {
            payload = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        } else {
            payload = ""
        }
        return "\(relative)\u{0}\(kind)\u{0}\(try itemIdentity(at: url).base64EncodedString())\u{0}\(payload)"
    }.sorted()
}

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
