// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pulse",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Pulse",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Pulse",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                // Sparkle.framework is embedded in Pulse.app/Contents/Frameworks by build.sh
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
