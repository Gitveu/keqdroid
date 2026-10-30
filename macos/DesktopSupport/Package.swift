// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DesktopSupport",
    platforms: [.macOS(.v12)],
    products: [.library(name: "KEQDesktopSupport", targets: ["KEQDesktopSupport"]),
               .executable(name: "keqdroid-desktop-tests", targets: ["DesktopChecks"]),
               .executable(name: "keqdroid-status-preview", targets: ["StatusPreview"])],
    targets: [
        .target(name: "KEQDesktopSupport", linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ServiceManagement")]),
        .executableTarget(name: "DesktopChecks", dependencies: ["KEQDesktopSupport"]),
        .executableTarget(name: "StatusPreview", dependencies: ["KEQDesktopSupport"]),
        .testTarget(name: "KEQDesktopSupportTests", dependencies: ["KEQDesktopSupport"])
    ]
)
