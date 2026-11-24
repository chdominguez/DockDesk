// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TwinDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TwinDesk", targets: ["TwinDesk"]),
        .executable(name: "twindeskctl", targets: ["twindeskctl"]),
        // Used only by the development launcher (scripts/build-app.sh --dev).
        .library(name: "TwinDeskDev", type: .dynamic, targets: ["TwinDeskApp"]),
    ],
    targets: [
        .target(name: "CDock", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation"), .linkedFramework("ApplicationServices")]),
        .target(name: "CVirtualDisplay", linkerSettings: [.linkedFramework("CoreGraphics")]),
        .target(name: "DockKit", dependencies: ["CDock"]),
        .target(name: "TwinKit", dependencies: ["CVirtualDisplay", "DockKit"]),
        .target(name: "FirmwareKit", dependencies: ["CDock", "DockKit"]),
        .testTarget(name: "FirmwareKitTests", dependencies: ["FirmwareKit"]),
        .executableTarget(name: "twindeskctl", dependencies: ["CDock", "DockKit", "TwinKit", "FirmwareKit"]),
        .target(name: "TwinDeskApp", dependencies: ["CDock", "DockKit", "TwinKit", "FirmwareKit"]),
        .executableTarget(name: "TwinDesk", dependencies: ["TwinDeskApp"]),
    ]
)
