// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Isometric",
    platforms: [.macOS(.v15), .iOS(.v18)],
    dependencies: [.package(name: "Spellcrest", path: "../..")],
    targets: [.executableTarget(name: "Isometric", dependencies: ["Spellcrest"])]
)
