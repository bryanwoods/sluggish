#!/usr/bin/env swift
// Scripts/license.swift keygen        makes the signing key pair, once
// Scripts/license.swift issue <id>    prints a license key for <id>, for example a reviewer's name
import CryptoKit
import Foundation

let path = NSHomeDirectory() + "/.config/sluggish/license-signing.key"
// An Ed25519 private key in PKCS#8 is this fixed DER header and then the 32-byte seed.
let header = Data([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func base64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

let args = Array(CommandLine.arguments.dropFirst())
switch (args.first, args.count) {
case ("keygen", 1):
    let key = Curve25519.Signing.PrivateKey()
    let pkcs8 = (header + key.rawRepresentation).base64EncodedString()
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { fail("\(path) exists. Every key sold so far depends on it, so keygen does not replace it.") }
    FileHandle(fileDescriptor: fd, closeOnDealloc: true).write(Data((pkcs8 + "\n").utf8))
    print("Public key, for licensePublicKey in Sources/Sluggish/License.swift:\n" + key.publicKey.rawRepresentation.base64EncodedString())
    print("Private key, PKCS#8 base64, for the LICENSE_PRIVATE_KEY secret of the Worker:\n" + pkcs8)
case ("issue", 2):
    let id = args[1]
    guard id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { fail("Use only letters, digits, _ and - in the id.") }
    guard let der = Data(base64Encoded: (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
          der.count == 48, der.prefix(16) == header
    else { fail("No signing key at \(path). Run keygen first.") }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: der.suffix(32))
    let day = ISO8601DateFormatter.string(from: Date(), timeZone: TimeZone(identifier: "UTC")!, formatOptions: .withFullDate)
    let payload = Data(#"{"t":"\#(id)","d":"\#(day)"}"#.utf8)
    print("SLUG1-" + base64url(payload) + "." + base64url(try key.signature(for: payload)))
default:
    fail("usage: Scripts/license.swift keygen | Scripts/license.swift issue <id>")
}
