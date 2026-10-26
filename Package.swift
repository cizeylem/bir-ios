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
        .target(
            name: "Cizeylem",
            // Privacy Manifest hedef kaynağı olarak bildirilir (SPEC §7). `.process`: Apple'ın
            // belgelediği ve gizlilik raporu/App Store doğrulamasının beklediği biçim.
            resources: [.process("Resources/PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "CizeylemAttribution",
            dependencies: ["Cizeylem"],
            // Attribution'ın kendi Privacy Manifest'i: IDFA beyanı çekirdekte değil burada durur.
            resources: [.process("Resources/PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "CizeylemTests", dependencies: ["Cizeylem"]),
        .testTarget(name: "CizeylemAttributionTests", dependencies: ["CizeylemAttribution", "Cizeylem"]),
    ]
)
