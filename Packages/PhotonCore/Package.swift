// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhotonCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhotonCore", targets: ["PhotonCore"])
    ],
    targets: [
        .target(name: "PhotonCore"),
        .testTarget(name: "PhotonCoreTests", dependencies: ["PhotonCore"])
    ]
)
