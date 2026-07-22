import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("SSOT writer ownership")
struct SSOTWriterOwnershipTests {
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
            let readyURL = root.appendingPathComponent("ready")
            try Data().write(to: lockURL)
            #expect(Darwin.chmod(lockURL.path, 0o600) == 0)

            let holder = Process()
            holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            holder.arguments = [
                "-c",
                "import fcntl,os,sys,time; f=open(sys.argv[1], 'r+'); fcntl.flock(f, fcntl.LOCK_EX); f.seek(0); f.truncate(); f.write(str(os.getpid()) + '\\n'); f.flush(); os.fsync(f.fileno()); open(sys.argv[2], 'w').close(); time.sleep(5)",
                lockURL.path,
                readyURL.path,
            ]
            try holder.run()
            defer {
                if holder.isRunning { holder.terminate() }
                holder.waitUntilExit()
            }
            try waitUntilExists(readyURL)

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

    private func waitUntilExists(_ url: URL) throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(Darwin.chmod(url.path, 0o700) == 0)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}
