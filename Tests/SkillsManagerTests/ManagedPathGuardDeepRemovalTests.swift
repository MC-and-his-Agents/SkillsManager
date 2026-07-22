import Darwin
import Foundation
import Testing

@testable import SkillsManager

extension ManagedPathGuardTests {
    @Test("legacy deep trees are removed without recursive Swift calls")
    func removesLegacyDeepTreeIteratively() throws {
        try withFixture { temporary, root, guardValue in
            let skill = root.appendingPathComponent("legacy-deep", isDirectory: true)
            try fileManager.createDirectory(at: skill, withIntermediateDirectories: false)

            var descriptor = Darwin.open(
                skill.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            #expect(descriptor >= 0)
            guard descriptor >= 0 else { return }
            defer { Darwin.close(descriptor) }

            for depth in 0..<128 {
                let name = "level-\(depth)"
                #expect(Darwin.mkdirat(descriptor, name, S_IRWXU) == 0)
                let next = Darwin.openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                #expect(next >= 0)
                guard next >= 0 else { return }
                Darwin.close(descriptor)
                descriptor = next
            }
            let marker = Darwin.openat(
                descriptor,
                "marker",
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            #expect(marker >= 0)
            if marker >= 0 { Darwin.close(marker) }

            try guardValue.removeItem(at: skill)

            #expect(!fileManager.fileExists(atPath: skill.path))
            #expect(fileManager.fileExists(atPath: temporary.path))
        }
    }

    @Test("iterative removal restores nested quarantines after failure")
    func iterativeRemovalRestoresNestedQuarantines() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent("managed", isDirectory: true)
            let skill = root.appendingPathComponent("skill", isDirectory: true)
            let nested = skill.appendingPathComponent("outer/inner", isDirectory: true)
            try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
            try "keep".write(
                to: nested.appendingPathComponent("blocked.txt"),
                atomically: true,
                encoding: .utf8
            )
            let hooks = ManagedPathGuardTestHooks(beforeQuarantineMove: { name in
                if name == "blocked.txt" {
                    throw ManagedPathError.posix(operation: "injected nested removal", code: EIO)
                }
            })

            #expect(throws: ManagedPathError.self) {
                try ManagedPathGuard(rootURL: root, hooks: hooks).removeItem(at: skill)
            }

            #expect(try String(
                contentsOf: nested.appendingPathComponent("blocked.txt"),
                encoding: .utf8
            ) == "keep")
            let enumerator = try #require(fileManager.enumerator(atPath: skill.path))
            let names = enumerator.compactMap { $0 as? String }
            #expect(!names.contains(where: { $0.contains(".skillsmanager-delete-") }))
        }
    }
}
