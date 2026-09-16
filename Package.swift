// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BatLimit",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Обновления приложения — тем же механизмом, что у AlDente и большинства
        // программ вне App Store. Ветка 2.9: 2.10 слишком свежая.
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMinor(from: "2.9.6")),
    ],
    targets: [
        .target(name: "BatLimitCore"),
        .executableTarget(name: "batlimitd", dependencies: ["BatLimitCore"]),
        .executableTarget(name: "batlimit", dependencies: ["BatLimitCore"]),
        .executableTarget(
            name: "BatLimitApp",
            dependencies: ["BatLimitCore", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework build.sh кладёт в Contents/Frameworks — туда
            // и смотрит загрузчик.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
