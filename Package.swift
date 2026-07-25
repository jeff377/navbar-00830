// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "navbar-00830",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        // The calculation layer ("the soul"): pure logic, no networking, no SwiftUI.
        .library(name: "NAV830Core", targets: ["NAV830Core"]),
        // The data-source layer: concrete networking that conforms to NAV830Core protocols.
        .library(name: "NAV830Fetch", targets: ["NAV830Fetch"]),
        // Cross-platform SwiftUI: the store + detail view shared by the macOS shell and iOS app.
        .library(name: "NAV830UI", targets: ["NAV830UI"])
    ],
    targets: [
        .target(
            name: "NAV830Core",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "NAV830CoreTests",
            dependencies: ["NAV830Core"]
        ),
        .target(
            name: "NAV830Fetch",
            dependencies: ["NAV830Core"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            // Also covers ETFStore's assembly path: it duplicates DataFeed's wiring, so it needs
            // its own coverage against the same recorded fixtures (a fix applied only to DataFeed
            // once shipped with the app still showing the old number).
            name: "NAV830FetchTests",
            dependencies: ["NAV830Fetch", "NAV830Core", "NAV830UI"],
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "NAV830UI",
            dependencies: ["NAV830Core", "NAV830Fetch"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "NAV830UITests",
            dependencies: ["NAV830UI", "NAV830Core"]
        ),
        // macOS-only menu-bar shell. Its sources are guarded with `#if os(macOS)` so the package
        // still compiles when built for iOS (the iOS app/widget live in the Xcode project and link
        // only the library products above).
        .executableTarget(
            name: "NAV830App",
            dependencies: ["NAV830Core", "NAV830Fetch", "NAV830UI"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        )
    ]
)
