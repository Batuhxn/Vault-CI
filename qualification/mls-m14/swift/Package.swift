// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MLSAppleQualification",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MLSBridge", targets: ["MLSBridge"]),
        .library(name: "ProtectedStateStore", targets: ["ProtectedStateStore"]),
        .library(name: "MLSQualification", targets: ["MLSQualification"]),
    ],
    targets: [
        .binaryTarget(name: "mls_rs_uniffiFFI", path: "Artifacts/MLSBridgeFFI.xcframework"),
        .target(name: "MLSBridge", dependencies: ["mls_rs_uniffiFFI"]),
        .target(name: "ProtectedStateStore"),
        .target(name: "MLSQualification", dependencies: ["MLSBridge", "ProtectedStateStore"]),
    ]
)
