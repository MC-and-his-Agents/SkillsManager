import Foundation

@testable import SkillsManager

/// Coordinates real Foundation threads without making scheduler timing part of the assertion.
final class PromotionContentionTestGate: @unchecked Sendable {
    enum Role: Hashable, Sendable {
        case holder
        case contender
    }

    enum Event: Hashable {
        case holderCommit
        case contention
        case contenderCommit
    }

    enum GateError: Error, Equatable {
        case aborted
        case contenderEnteredBeforeHolderRelease
        case watchdogExpired(String)
        case missingResult(Role)
    }

    private let condition = NSCondition()
    private let watchdogInterval: TimeInterval
    private var events: Set<Event> = []
    private var releasedRoles: Set<Role> = []
    private var results: [Role: Result<SafeSkillInstallResult, Error>] = [:]
    private var activeWorkerCount = 0
    private var isAborted = false

    init(watchdogInterval: TimeInterval = 60) {
        self.watchdogInterval = watchdogInterval
    }

    func startPromotion(
        role: Role,
        source: URL,
        fingerprint: String,
        destination: URL,
        name: String,
        managedRoot: ManagedRootReference
    ) {
        condition.withLock { activeWorkerCount += 1 }
        Thread.detachNewThread { [self] in
            runPromotion(
                role: role,
                source: source,
                fingerprint: fingerprint,
                destination: destination,
                name: name,
                managedRoot: managedRoot
            )
        }
    }

    func wait(for event: Event) throws {
        try condition.withLock {
            try waitUntil("event \(event)") { events.contains(event) }
        }
    }

    func release(_ role: Role) {
        condition.withLock {
            releasedRoles.insert(role)
            condition.broadcast()
        }
    }

    func finish(
        workerWatchdogInterval: TimeInterval? = nil
    ) throws -> [SafeSkillInstallResult] {
        try waitForAllWorkers(watchdogInterval: workerWatchdogInterval)
        return try condition.withLock {
            try [Role.holder, .contender].map { role in
                guard let result = results[role] else { throw GateError.missingResult(role) }
                return try result.get()
            }
        }
    }

    func abortAndWait() throws {
        condition.withLock {
            isAborted = true
            condition.broadcast()
        }
        try waitForAllWorkers()
    }

    private func observeContention() {
        condition.withLock {
            events.insert(.contention)
            condition.broadcast()
        }
    }

    private func runPromotion(
        role: Role,
        source: URL,
        fingerprint: String,
        destination: URL,
        name: String,
        managedRoot: ManagedRootReference
    ) {
        let hooks = ManagedPathGuardTestHooks(
            beforeNoReplaceCommit: { try self.enterCommit(role) }
        )
        let stager = SafeSkillStager(
            guardFactory: { try ManagedPathGuard(rootURL: $0, hooks: hooks) },
            onPromotionLockContention: {
                if role == .contender { self.observeContention() }
            }
        )
        let result: Result<SafeSkillInstallResult, Error>
        do {
            result = .success(try stager.install(
                sourceRoot: source,
                expectedFingerprint: fingerprint,
                destinationRoot: destination,
                preferredName: name,
                conflictPolicy: .chooseUniqueName,
                managedRoot: managedRoot
            ))
        } catch {
            result = .failure(error)
        }
        complete(role, with: result)
    }

    private func enterCommit(_ role: Role) throws {
        try condition.withLock {
            if role == .contender, !releasedRoles.contains(.holder) {
                isAborted = true
                condition.broadcast()
                throw GateError.contenderEnteredBeforeHolderRelease
            }
            events.insert(role == .holder ? .holderCommit : .contenderCommit)
            condition.broadcast()
            try waitUntil("release \(role)") { releasedRoles.contains(role) }
        }
    }

    private func complete(
        _ role: Role,
        with result: Result<SafeSkillInstallResult, Error>
    ) {
        condition.withLock {
            results[role] = result
            if case .failure = result { isAborted = true }
            activeWorkerCount -= 1
            condition.broadcast()
        }
    }

    private func waitForAllWorkers(
        watchdogInterval: TimeInterval? = nil
    ) throws {
        try condition.withLock {
            // Fail-safe only: cleanup waits for every started Foundation thread.
            let deadline = Date().addingTimeInterval(watchdogInterval ?? self.watchdogInterval)
            var watchdogError: GateError?
            while activeWorkerCount != 0 && watchdogError == nil {
                guard condition.wait(until: deadline) else {
                    watchdogError = .watchdogExpired("worker completion")
                    isAborted = true
                    condition.broadcast()
                    break
                }
            }
            while activeWorkerCount != 0 {
                condition.wait()
            }
            if let watchdogError { throw watchdogError }
        }
    }

    private func waitUntil(
        _ description: String,
        predicate: () -> Bool
    ) throws {
        // Fail-safe only: event order, not elapsed time, defines the test semantics.
        let deadline = Date().addingTimeInterval(watchdogInterval)
        while !predicate() && !isAborted {
            guard condition.wait(until: deadline) else {
                isAborted = true
                condition.broadcast()
                throw GateError.watchdogExpired(description)
            }
        }
        guard !isAborted else { throw GateError.aborted }
    }
}
