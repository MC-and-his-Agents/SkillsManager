import Darwin
import Dispatch
import Foundation
import Testing

@testable import SkillsManager

@Suite("SSOT writer ownership")
struct SSOTWriterOwnershipTests {
    @Test("journaled writer keeps ownership in the management root")
    func journaledWriterUsesManagementRoot() async throws {
        let workspace = try WriterWorkspace()

        let writer = try await workspace.openWriter()
        _ = writer

        #expect(FileManager.default.fileExists(
            atPath: workspace.managementRoot
                .appendingPathComponent(SSOTWriterOwnership.lockFileName).path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: workspace.root
                .appendingPathComponent(SSOTWriterOwnership.lockFileName).path
        ))
    }

    @Test("journaled writer rejects a shared management and SSOT root")
    func journaledWriterRequiresDistinctRoots() async throws {
        let workspace = try WriterWorkspace()

        await #expect(throws: ManagedPathError.self) {
            _ = try await JournaledSSOTWriter.open(
                managementRoot: workspace.verifiedRoot,
                ssotRoot: workspace.verifiedRoot,
                databaseURL: workspace.database
            )
        }
    }

    @Test("journaled writer fails closed when the management lock is replaced")
    func journaledWriterRejectsReplacedManagementLock() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let snapshot = try workspace.snapshot(content: "# replacement\n")
        let payload = try workspace.payload(name: "replacement", snapshot: snapshot)
        let lock = workspace.managementRoot
            .appendingPathComponent(SSOTWriterOwnership.lockFileName)
        try FileManager.default.removeItem(at: lock)
        try Data("replacement\n".utf8).write(to: lock)
        #expect(Darwin.chmod(lock.path, 0o600) == 0)

        await #expect(throws: SSOTWriterOwnershipError.invalidLockFile) {
            _ = try await writer.create(payload: payload, sourceSnapshot: snapshot)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.root.path).isEmpty)
    }

    @Test("ownership fails closed when the management root is replaced")
    func ownershipRejectsReplacedManagementRoot() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let ownership = await writer.ownership
        let displaced = workspace.workspace.appendingPathComponent("displaced-management")
        try FileManager.default.moveItem(at: workspace.managementRoot, to: displaced)
        try FileManager.default.createDirectory(
            at: workspace.managementRoot,
            withIntermediateDirectories: false
        )
        #expect(Darwin.chmod(workspace.managementRoot.path, 0o700) == 0)

        #expect(throws: ManagedPathError.rootReplaced) {
            try ownership.validateForMutation()
        }
    }

    @Test("verified root retains and revalidates the supplied descriptor")
    func retainsVerifiedRootDescriptor() throws {
        try withTemporaryDirectory { root in
            let descriptor = Darwin.open(
                root.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            #expect(descriptor >= 0)
            let verified = try VerifiedSSOTRoot(
                existingRootURL: root,
                descriptor: descriptor
            )
            Darwin.close(descriptor)

            let guardValue = try ManagedPathGuard(verifiedRoot: verified)
            try guardValue.verifyRootIdentity(expected: verified.identity)
        }
    }

    @Test("verified root rejects non-owner-only permissions")
    func rejectsUnsafeRootPermissions() throws {
        try withTemporaryDirectory { root in
            #expect(Darwin.chmod(root.path, 0o1700) == 0)
            let descriptor = Darwin.open(
                root.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            #expect(descriptor >= 0)
            defer { Darwin.close(descriptor) }

            #expect(throws: ManagedPathError.self) {
                try VerifiedSSOTRoot(existingRootURL: root, descriptor: descriptor)
            }
        }
    }

    @Test("acquisition creates an owner-only regular lock and holds it")
    func createsAndHoldsLock() throws {
        try withTemporaryDirectory { root in
            let guardValue = try ManagedPathGuard(rootURL: root)
            let owner = SSOTWriterOwner(processID: 42)
            let ownership = try SSOTWriterOwnership.acquire(using: guardValue, owner: owner)
            _ = ownership
            let lockURL = root.appendingPathComponent(SSOTWriterOwnership.lockFileName)

            var metadata = stat()
            #expect(Darwin.lstat(lockURL.path, &metadata) == 0)
            #expect(metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
            #expect(metadata.st_mode & mode_t(0o777) == mode_t(0o600))
            #expect(try String(contentsOf: lockURL, encoding: .utf8) == "42\n")

            #expect(throws: SSOTWriterOwnershipError.busy(owner: owner)) {
                try SSOTWriterOwnership.acquire(
                    using: guardValue,
                    owner: SSOTWriterOwner(processID: 43)
                )
            }

            let contender = Process()
            contender.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            contender.standardError = Pipe()
            contender.arguments = [
                "-c",
                "import fcntl,sys; f=open(sys.argv[1], 'r+'); fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)",
                lockURL.path,
            ]
            try withExtendedLifetime(ownership) {
                try contender.run()
                contender.waitUntilExit()
                #expect(contender.terminationStatus != 0)
            }
        }
    }

    @Test("an external writer reports structured busy ownership")
    func reportsBusyOwner() throws {
        try withTemporaryDirectory { root in
            let lockURL = root.appendingPathComponent(SSOTWriterOwnership.lockFileName)
            try Data().write(to: lockURL)
            #expect(Darwin.chmod(lockURL.path, 0o600) == 0)

            try withExternalLockHolder(
                at: lockURL,
                script: Self.externalWriterScript
            ) {
                let guardValue = try ManagedPathGuard(rootURL: root)
                do {
                    _ = try SSOTWriterOwnership.acquire(using: guardValue)
                    Issue.record("Expected the external writer to own the lock")
                } catch let error as SSOTWriterOwnershipError {
                    guard case .busy(let owner) = error else {
                        Issue.record("Unexpected error: \(error)")
                        return
                    }
                    #expect(owner?.processID ?? 0 > 0)
                }
            }
        }
    }

    @Test("external writer handshake reports early exit diagnostics")
    func reportsExternalWriterStartupFailure() throws {
        try withTemporaryDirectory { root in
            let lockURL = root.appendingPathComponent(SSOTWriterOwnership.lockFileName)
            try Data().write(to: lockURL)
            #expect(Darwin.chmod(lockURL.path, 0o600) == 0)

            do {
                try withExternalLockHolder(
                    at: lockURL,
                    script: "import sys; sys.stderr.write('holder failed\\n'); sys.stderr.flush(); sys.exit(7)"
                ) {}
                Issue.record("Expected the external holder handshake to fail")
            } catch let error as ExternalLockHolderStartupError {
                #expect(error.status == 7)
                #expect(error.standardError == "holder failed\n")
            }

            do {
                try withExternalLockHolder(
                    at: lockURL,
                    script: "import signal; signal.pause()",
                    watchdogInterval: .milliseconds(10)
                ) {}
                Issue.record("Expected the stalled external holder to be reaped")
            } catch let error as ExternalLockHolderStartupError {
                #expect(error.status != 0)
            }
        }
    }

    @Test("unsafe lock entries fail closed")
    func rejectsUnsafeLockEntries() throws {
        try withTemporaryDirectory { root in
            let lockURL = root.appendingPathComponent(SSOTWriterOwnership.lockFileName)
            try Data().write(to: lockURL)
            #expect(Darwin.chmod(lockURL.path, 0o644) == 0)
            let guardValue = try ManagedPathGuard(rootURL: root)

            #expect(throws: SSOTWriterOwnershipError.invalidLockFile) {
                try SSOTWriterOwnership.acquire(using: guardValue)
            }

            try FileManager.default.removeItem(at: lockURL)
            try Data().write(to: lockURL)
            #expect(Darwin.chmod(lockURL.path, 0o4600) == 0)
            #expect(throws: SSOTWriterOwnershipError.invalidLockFile) {
                try SSOTWriterOwnership.acquire(using: guardValue)
            }

            try FileManager.default.removeItem(at: lockURL)
            let external = root.appendingPathComponent("external")
            try Data("keep".utf8).write(to: external)
            try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: external)
            #expect(throws: SSOTWriterOwnershipError.self) {
                try SSOTWriterOwnership.acquire(using: guardValue)
            }
            #expect(try String(contentsOf: external, encoding: .utf8) == "keep")
        }
    }

    private func withExternalLockHolder(
        at lockURL: URL,
        script: String,
        watchdogInterval: DispatchTimeInterval = .seconds(60),
        _ body: () throws -> Void
    ) throws {
        let holder = Process()
        let readyPipe = Pipe()
        let errorPipe = Pipe()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.standardOutput = readyPipe
        holder.standardError = errorPipe
        holder.arguments = ["-c", script, lockURL.path]
        try holder.run()
        var holderReaped = false
        func stopAndWaitForHolder() {
            guard !holderReaped else { return }
            if holder.isRunning { holder.terminate() }
            holder.waitUntilExit()
            holderReaped = true
        }
        defer { stopAndWaitForHolder() }
        let watchdog = DispatchWorkItem { [weak holder] in
            guard let holder, holder.isRunning else { return }
            holder.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + watchdogInterval,
            execute: watchdog
        )
        defer { watchdog.cancel() }

        try readyPipe.fileHandleForWriting.close()
        try errorPipe.fileHandleForWriting.close()
        let ready = try readyPipe.fileHandleForReading.readToEnd() ?? Data()
        guard ready == Data("ready\n".utf8) else {
            stopAndWaitForHolder()
            let errorData = try errorPipe.fileHandleForReading.readToEnd() ?? Data()
            throw ExternalLockHolderStartupError(
                status: holder.terminationStatus,
                standardError: String(data: errorData, encoding: .utf8) ?? "<non-UTF-8 stderr>"
            )
        }
        watchdog.cancel()
        try body()
    }

    private static let externalWriterScript =
        "import fcntl,os,signal,sys; f=open(sys.argv[1], 'r+'); "
        + "fcntl.flock(f, fcntl.LOCK_EX); f.seek(0); f.truncate(); "
        + "f.write(str(os.getpid()) + '\\n'); f.flush(); os.fsync(f.fileno()); "
        + "os.write(sys.stdout.fileno(), b'ready\\n'); "
        + "os.close(sys.stdout.fileno()); signal.pause()"

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(Darwin.chmod(url.path, 0o700) == 0)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}

private struct ExternalLockHolderStartupError: Error {
    let status: Int32
    let standardError: String
}
