// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaBoard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "QuotaBoard", targets: ["QuotaBoard"])
    ],
    targets: [
        .executableTarget(
            name: "QuotaBoard",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
    ]
)
