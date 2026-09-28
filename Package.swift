// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Yabaibye",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Yabaibye", targets: ["Yabaibye"])],
    targets: [
        .target(name: "YabaibyeCore"),
        .target(name: "SpaceBridge", linkerSettings: [.linkedFramework("AppKit")]),
        .executableTarget(name: "Yabaibye", dependencies: ["YabaibyeCore", "SpaceBridge"],
                          linkerSettings: [.linkedFramework("Carbon")]),
        .testTarget(name: "YabaibyeCoreTests", dependencies: ["YabaibyeCore"])
    ]
)
