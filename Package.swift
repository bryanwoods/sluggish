// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Sluggish",
    platforms: [.macOS("14.0")],
    // The model framework exists only on macOS 26; a weak link lets the app start on macOS 14 and 15 without the AI line.
    targets: [.executableTarget(name: "Sluggish", linkerSettings: [.unsafeFlags(["-weak_framework", "FoundationModels"])])]
)
