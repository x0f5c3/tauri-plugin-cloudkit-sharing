// swift-tools-version:5.7
import PackageDescription
let package = Package(
    name: "tauri-plugin-cloudkit-sharing",
    platforms: [.iOS(.v15)],
    products: [.library(name: "tauri-plugin-cloudkit-sharing", type: .static, targets: ["CloudKitSharingPlugin"])],
    dependencies: [
        .package(name: "Tauri", path: "../.tauri/tauri-api"),
        .package(name: "CloudKitSharing", path: "../apple")
    ],
    targets: [.target(name: "CloudKitSharingPlugin", dependencies: [.byName(name: "Tauri"), .product(name: "CloudKitSharing", package: "CloudKitSharing")], path: "Sources")]
)
