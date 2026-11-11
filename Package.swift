// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ProcXRay",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ProcXRay",
            path: "Sources/ProcXRay",
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("AppKit")]
        )
    ]
)
