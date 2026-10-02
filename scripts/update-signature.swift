// Ed25519 keys and signatures for Coucou's macOS updates, with Apple's CryptoKit
// (no OpenSSL needed, same algorithm the app checks with).
//
//   swift scripts/update-signature.swift generate      → prints "PRIVATE <b64>" and "PUBLIC <b64>"
//   MAC_UPDATE_KEY=<b64> swift scripts/update-signature.swift sign <file>   → prints the signature (b64)
//   swift scripts/update-signature.swift verify <public b64> <file> <signature b64>
import CryptoKit
import Foundation

let args = CommandLine.arguments
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

switch args.count > 1 ? args[1] : "" {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    print("PRIVATE \(key.rawRepresentation.base64EncodedString())")
    print("PUBLIC \(key.publicKey.rawRepresentation.base64EncodedString())")
case "sign":
    guard args.count == 3 else { fail("usage: sign <file>") }
    guard let b64 = ProcessInfo.processInfo.environment["MAC_UPDATE_KEY"],
          let raw = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("MAC_UPDATE_KEY is missing or invalid") }
    guard let data = FileManager.default.contents(atPath: args[2]) else { fail("can't read \(args[2])") }
    print(try key.signature(for: data).base64EncodedString())
case "verify":
    guard args.count == 5,
          let raw = Data(base64Encoded: args[2]),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
          let data = FileManager.default.contents(atPath: args[3]),
          let sig = Data(base64Encoded: args[4]) else { fail("usage: verify <public b64> <file> <signature b64>") }
    print(key.isValidSignature(sig, for: data) ? "valid" : "INVALID")
default:
    fail("usage: generate | sign <file> | verify <public> <file> <signature>")
}
