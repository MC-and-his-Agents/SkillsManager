import Foundation
import Synchronization

private nonisolated enum SkillRootPromotionLocks {
    static let locks = Mutex<[ManagedItemIdentity: NSLock]>([:])

    static func withLock<T>(
        for rootIdentity: ManagedItemIdentity,
        onContention: () -> Void,
        _ body: () throws -> T
    ) rethrows -> T {
        let lock = locks.withLock { locks in
            if let existing = locks[rootIdentity] { return existing }
            let created = NSLock()
            locks[rootIdentity] = created
            return created
        }
        if !lock.try() {
            onContention()
            lock.lock()
        }
        defer { lock.unlock() }
        return try body()
    }
}

nonisolated extension SafeSkillStager {
    func withPromotionLock<T>(
        for rootIdentity: ManagedItemIdentity,
        _ body: () throws -> T
    ) rethrows -> T {
        try SkillRootPromotionLocks.withLock(
            for: rootIdentity,
            onContention: onPromotionLockContention,
            body
        )
    }

    func destinationURL(
        in root: URL,
        preferredName: String,
        conflictPolicy: SkillInstallConflictPolicy,
        guardrail: ManagedPathGuard
    ) throws -> URL {
        let children = try guardrail.managedItemNames()
            .filter { !$0.hasPrefix(".skillsmanager-tmp-") }
        let preferredKey = SkillContentPath.collisionKey(for: preferredName)
        let matches = children.filter {
            SkillContentPath.collisionKey(for: $0) == preferredKey
        }
        guard matches.count <= 1 else {
            throw SafeSkillStagingError.destinationPathCollision(matches[0], matches[1])
        }

        switch (conflictPolicy, matches.first) {
        case (.replaceExisting, let existing?):
            return root.appendingPathComponent(existing, isDirectory: true)
        case (.replaceExisting, nil), (.chooseUniqueName, nil):
            return root.appendingPathComponent(preferredName, isDirectory: true)
        case (.chooseUniqueName, .some):
            var suffix = 1
            while true {
                let candidateName = "\(preferredName)-\(suffix)"
                let candidateKey = SkillContentPath.collisionKey(for: candidateName)
                if !children.contains(where: { SkillContentPath.collisionKey(for: $0) == candidateKey }) {
                    return root.appendingPathComponent(candidateName, isDirectory: true)
                }
                suffix += 1
            }
        }
    }

    func validatedName(_ name: String) throws -> String {
        guard let normalized = SkillContentPath.visibleDirectoryName(name) else {
            throw SafeSkillStagingError.invalidDestinationName(name)
        }
        return normalized
    }
}
