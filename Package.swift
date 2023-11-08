// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "nio-http-performance-tests",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.61.0"),
    ],
    targets: [
        .executableTarget(name: "eventloop", dependencies: [
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ]),
        .executableTarget(name: "unstructured-tasks", dependencies: [
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ]),
        .executableTarget(name: "nio-async-channel", dependencies: [
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ]),
    ]
)
