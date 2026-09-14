// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CursorUsage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CursorUsage",
            path: "Sources/CursorUsage",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "CursorUsageTests",
            dependencies: ["CursorUsage"],
            path: "Tests/CursorUsageTests",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
