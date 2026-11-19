// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Velyn",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(name: "Velyn", path: "Sources/Velyn"),
        // Run with ./tools/test.sh (Swift Testing; works with just the Command Line Tools)
        .testTarget(name: "VelynTests", dependencies: ["Velyn"], path: "Tests/VelynTests")
    ]
)
