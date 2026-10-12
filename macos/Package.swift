// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShareMouseCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ShareMouseCore", targets: ["ShareMouseCore"]),
               .executable(name: "SessionProbe", targets: ["SessionProbe"])],
    targets: [
        .target(name: "ShareMouseCore"),
        .executableTarget(name: "SessionProbe", dependencies: ["ShareMouseCore"]),
        .testTarget(name: "ShareMouseCoreTests", dependencies: ["ShareMouseCore"])
    ]
)
