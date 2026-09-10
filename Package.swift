// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BatLimit",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "BatLimitCore"),
        .executableTarget(name: "batlimitd", dependencies: ["BatLimitCore"]),
        .executableTarget(name: "batlimit", dependencies: ["BatLimitCore"]),
        .executableTarget(name: "BatLimitApp", dependencies: ["BatLimitCore"]),
    ]
)
