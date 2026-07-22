import Darwin
import Foundation

nonisolated enum SSOTDurabilityError: LocalizedError, Equatable {
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .posix(let operation, let code):
            "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

nonisolated enum SSOTDurability {
    static func syncFile(_ descriptor: Int32) throws {
        try synchronize(descriptor, operation: "sync managed file")
    }

    static func syncDirectory(_ descriptor: Int32) throws {
        try synchronize(descriptor, operation: "sync managed directory")
    }

    private static func synchronize(
        _ descriptor: Int32,
        operation: String
    ) throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw SSOTDurabilityError.posix(operation: operation, code: errno)
        }
    }
}

nonisolated enum SSOTIdentityRevalidator {
    static func requireRoot(
        _ guardValue: ManagedPathGuard,
        expectedIdentity: ManagedItemIdentity
    ) throws {
        try guardValue.verifyRootIdentity(expected: expectedIdentity)
        try ManagedItemIdentityCodec.revalidate(
            descriptor: guardValue.rootDescriptor,
            expected: expectedIdentity
        )
    }

    static func requireItem(
        at itemURL: URL,
        in guardValue: ManagedPathGuard,
        expectedIdentity: ManagedItemIdentity
    ) throws {
        try guardValue.withItemDescriptor(at: itemURL, expectedIdentity: expectedIdentity) {
            try ManagedItemIdentityCodec.revalidate(
                descriptor: $0,
                expected: expectedIdentity
            )
        }
    }
}
