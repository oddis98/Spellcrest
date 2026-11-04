// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spellcrest",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "Spellcrest", targets: ["Spellcrest"]),
        // The asset formats and the messages that tools, like the Spellcrest editor, share with games.
        .library(name: "SpellcrestProtocol", targets: ["SpellcrestProtocol"]),
        // Steam, for a game sold there: its achievements, stats and the player's name, through Steam's own library.
        .library(name: "SpellcrestSteam", targets: ["SpellcrestSteam"]),
    ],
    targets: [
        .target(name: "Spellcrest", dependencies: ["SpellcrestProtocol"]),
        // File formats the editor writes and games read.
        .target(name: "SpellcrestProtocol"),
        .target(name: "SpellcrestSteam"),
        .testTarget(name: "SpellcrestTests", dependencies: ["Spellcrest", "SpellcrestSteam"]),
    ]
)
