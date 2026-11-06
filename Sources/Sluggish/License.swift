import CryptoKit
import Foundation

let buyLine = "Your 10 free checks are used. Sluggish costs $12, one time, for all your Macs."
let licensePublicKey = try! Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: "6SVlYHjd2IChanneMdmTD6LsGd9KBcHm2Ts8n6NFric=")!)

// A key is "SLUG1-" + base64url(JSON payload) + "." + base64url(Ed25519 signature of the payload). Scripts/license.swift and server/worker.js make them.
func validLicense(_ key: String?, _ publicKey: Curve25519.Signing.PublicKey = licensePublicKey) -> Bool {
    let parts = key?.split(separator: ".", omittingEmptySubsequences: false) ?? []
    guard parts.count == 2, parts[0].hasPrefix("SLUG1-"), let payload = base64url(parts[0].dropFirst(6)), let signature = base64url(parts[1]) else { return false }
    return publicKey.isValidSignature(signature, for: payload)
}

private func base64url(_ s: Substring) -> Data? {
    let b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    return Data(base64Encoded: b + String(repeating: "=", count: (4 - b.count % 4) % 4))
}

func countCheck(_ d: UserDefaults = .standard) -> Int {
    d.set(d.integer(forKey: "checks") + 1, forKey: "checks")
    return d.integer(forKey: "checks")
}
