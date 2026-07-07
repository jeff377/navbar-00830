// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "navbar-00830",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // The calculation layer ("the soul"): pure logic, no networking, no SwiftUI.
        // Any presentation shell (MenuBarExtra, CLI, web) links against this and nothing else.
        .library(name: "NAV830Core", targets: ["NAV830Core"]),
        // The data-source layer: concrete networking that conforms to NAV830Core protocols.
        .library(name: "NAV830Fetch", targets: ["NAV830Fetch"])
    ],
    targets: [
        .target(
            name: "NAV830Core",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "NAV830CoreTests",
            dependencies: ["NAV830Core"]
        ),
        .target(
            name: "NAV830Fetch",
            dependencies: ["NAV830Core"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "NAV830FetchTests",
            dependencies: ["NAV830Fetch", "NAV830Core"],
            resources: [.copy("Fixtures")]
        ),
        .executableTarget(
            name: "NAV830App",
            dependencies: ["NAV830Core", "NAV830Fetch"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ]
)
