#!/usr/bin/env swift

import CryptoKit
import Foundation

enum VerificationError: LocalizedError {
    case usage
    case invalidPublicKey
    case invalidSignature
    case signatureMismatch
    case selfTestFailed

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: verify_sparkle_signature.swift <archive> <signature-base64> <public-key-base64> | --self-test"
        case .invalidPublicKey:
            return "Sparkle public key is not valid base64."
        case .invalidSignature:
            return "Sparkle signature is not valid base64."
        case .signatureMismatch:
            return "Sparkle Ed25519 signature verification failed."
        case .selfTestFailed:
            return "Sparkle signature verifier self-test failed."
        }
    }
}

func verify(archive: Data, signature: String, publicKey: String) throws {
    guard let publicKeyData = Data(base64Encoded: publicKey) else {
        throw VerificationError.invalidPublicKey
    }
    guard let signatureData = Data(base64Encoded: signature) else {
        throw VerificationError.invalidSignature
    }

    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    guard key.isValidSignature(signatureData, for: archive) else {
        throw VerificationError.signatureMismatch
    }
}

func selfTest() throws {
    let privateKey = try Curve25519.Signing.PrivateKey(
        rawRepresentation: Data(repeating: 0x2A, count: 32)
    )
    let archive = Data("skills-manager-release".utf8)
    let signature = try privateKey.signature(for: archive)
    let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()

    try verify(
        archive: archive,
        signature: signature.base64EncodedString(),
        publicKey: publicKey
    )

    do {
        try verify(
            archive: Data("tampered-release".utf8),
            signature: signature.base64EncodedString(),
            publicKey: publicKey
        )
        throw VerificationError.selfTestFailed
    } catch VerificationError.signatureMismatch {
        // Expected.
    }

    var tamperedSignature = signature
    tamperedSignature[tamperedSignature.startIndex] ^= 0x01
    do {
        try verify(
            archive: archive,
            signature: tamperedSignature.base64EncodedString(),
            publicKey: publicKey
        )
        throw VerificationError.selfTestFailed
    } catch VerificationError.signatureMismatch {
        // Expected.
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--self-test"] {
        try selfTest()
        print("Sparkle signature verifier self-test passed.")
    } else {
        guard arguments.count == 3 else {
            throw VerificationError.usage
        }
        let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[0]))
        try verify(archive: archive, signature: arguments[1], publicKey: arguments[2])
        print("Sparkle Ed25519 signature verified.")
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
