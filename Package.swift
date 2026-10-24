// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UltimateFinder",
    platforms: [.macOS(.v13)],
    dependencies: [
        // ImageIO reads WebP but can't write it, so "Convert Image" encodes WebP with libwebp.
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", exact: "1.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "UltimateFinder",
            dependencies: [.product(name: "libwebp", package: "libwebp-Xcode")],
            path: "Sources/UltimateFinder",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Quartz"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
