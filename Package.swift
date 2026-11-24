// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DockDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DockDesk", targets: ["DockDesk"]),
        .executable(name: "dockdeskctl", targets: ["dockdeskctl"]),
        // Used only by the development launcher (scripts/build-app.sh --dev).
        .library(name: "DockDeskDev", type: .dynamic, targets: ["DockDeskApp"]),
    ],
    targets: [
        .target(name: "CDock", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation"), .linkedFramework("ApplicationServices")]),
        .target(name: "CVirtualDisplay", linkerSettings: [.linkedFramework("CoreGraphics")]),
        .target(name: "DockKit", dependencies: ["CDock"]),
        .target(name: "TwinKit", dependencies: ["CVirtualDisplay", "DockKit"]),
        .target(name: "FirmwareKit", dependencies: ["CDock", "DockKit"]),
        .testTarget(name: "FirmwareKitTests", dependencies: ["FirmwareKit"]),
        .executableTarget(name: "dockdeskctl", dependencies: ["CDock", "DockKit", "TwinKit", "FirmwareKit"]),
        .target(name: "DockDeskApp", dependencies: ["CDock", "DockKit", "TwinKit", "FirmwareKit"]),
        .executableTarget(name: "DockDesk", dependencies: ["DockDeskApp"]),
    ]
)
