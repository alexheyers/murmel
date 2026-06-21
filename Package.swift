// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Murmel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Murmel",
            path: "Sources/Murmel",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "MurmelTests",
            dependencies: ["Murmel"],
            path: "Tests/MurmelTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
