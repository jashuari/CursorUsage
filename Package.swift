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
    ]
)
