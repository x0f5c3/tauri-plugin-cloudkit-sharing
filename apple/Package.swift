// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "CloudKitSharing",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [.library(name: "CloudKitSharing", type: .static, targets: ["CloudKitSharing"])],
    targets: [
        .target(name: "CloudKitSharingBootstrap", path: "Sources/CloudKitSharingBootstrap", publicHeadersPath: "include"),
        .target(name: "CloudKitSharing", dependencies: [.target(name: "CloudKitSharingBootstrap")]),
        .testTarget(name: "CloudKitSharingTests", dependencies: [.target(name: "CloudKitSharing")])
    ]
)
