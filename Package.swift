// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TransportSeam",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // Only libraries. No `.executableTarget` — the runnable app lives in Demo.xcodeproj.
        .library(name: "TransportSeam", targets: ["TransportSeam"]),
        .library(name: "TransportSeamURLSession", targets: ["TransportSeamURLSession"]),
        .library(name: "TransportSeamUI", targets: ["TransportSeamUI"])
    ],
    targets: [
        .target(name: "TransportSeam"),
        .target(name: "TransportSeamURLSession", dependencies: ["TransportSeam"]),
        .target(name: "TransportSeamUI", dependencies: ["TransportSeam"]),
        .testTarget(name: "TransportSeamTests", dependencies: ["TransportSeam"])
    ]
)
