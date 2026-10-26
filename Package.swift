// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cizeylem",
    platforms: [.iOS(.v15), .tvOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "Cizeylem", targets: ["Cizeylem"]),
        .library(name: "CizeylemAttribution", targets: ["CizeylemAttribution"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "Cizeylem"),
        .target(name: "CizeylemAttribution", dependencies: ["Cizeylem"]),
        .testTarget(name: "CizeylemTests", dependencies: ["Cizeylem"]),
        .testTarget(name: "CizeylemAttributionTests", dependencies: ["CizeylemAttribution"]),
    ]
)
