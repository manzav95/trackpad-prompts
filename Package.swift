// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EdgeControl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EdgeControl", targets: ["EdgeControl"])
    ],
    targets: [
        .target(name: "EdgeGesture"),
        .executableTarget(
            name: "EdgeControl",
            dependencies: ["EdgeGesture"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "EdgeGestureTests",
            dependencies: ["EdgeGesture"]
        ),
    ]
)
