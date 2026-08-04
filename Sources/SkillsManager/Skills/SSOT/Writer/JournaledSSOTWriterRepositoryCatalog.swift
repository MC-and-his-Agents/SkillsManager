import Foundation

extension JournaledSSOTWriter {
    func listCustomRepositories() throws -> [CustomRepositoryCatalogRecord] {
        try requireAuthority()
        return try RepositoryCatalogStore(connection: connection).list()
    }

    func loadCustomRepository(id: UUID) throws -> CustomRepositoryCatalogRecord? {
        try requireAuthority()
        return try RepositoryCatalogStore(connection: connection).load(id: id)
    }

    func insertCustomRepository(
        _ input: CustomRepositoryCatalogInput,
        id: UUID = UUID()
    ) throws -> CustomRepositoryCatalogRecord {
        try requireAuthority()
        return try RepositoryCatalogStore(connection: connection).insert(
            input,
            id: id,
            nowMilliseconds: initialTimestamp()
        )
    }

    func replaceCustomRepository(
        id: UUID,
        expectedRevision: Int64,
        input: CustomRepositoryCatalogInput
    ) throws -> CustomRepositoryCatalogRecord {
        try requireAuthority()
        return try RepositoryCatalogStore(connection: connection).replace(
            id: id,
            expectedRevision: expectedRevision,
            input: input,
            nowMilliseconds: initialTimestamp()
        )
    }

    func removeCustomRepository(id: UUID, expectedRevision: Int64) throws {
        try requireAuthority()
        try RepositoryCatalogStore(connection: connection).remove(
            id: id,
            expectedRevision: expectedRevision
        )
    }
}
