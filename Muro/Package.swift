// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Muro",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "MuroKit",
            path: "Sources/MuroKit"
        ),
        .executableTarget(
            name: "muro-app",
            dependencies: ["MuroKit"],
            path: "Sources/MuroApp"
        ),
        .executableTarget(
            name: "muro-engine",
            dependencies: ["MuroKit"],
            path: "Sources/MuroEngine"
        ),
        .executableTarget(
            name: "muro-import",
            dependencies: ["MuroKit"],
            path: "Sources/MuroImport"
        ),
        .executableTarget(
            name: "muro-set",
            dependencies: ["MuroKit"],
            path: "Sources/MuroSet"
        ),
        .executableTarget(
            name: "muro-publish",
            dependencies: ["MuroKit"],
            path: "Sources/MuroPublish"
        ),
        .executableTarget(
            name: "muro-prepare",
            dependencies: ["MuroKit"],
            path: "Sources/MuroPrepare"
        )
    ]
)
