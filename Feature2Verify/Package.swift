// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Feature2Verify",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "Feature2Verify", targets: ["Feature2Verify"])
    ],
    dependencies: [
        .package(url: "https://github.com/mnmly/SwiftIGL.git", from: "0.1.0"),
        .package(url: "https://github.com/tomasf/manifold-swift.git", from: "1.1.0")
    ],
    targets: [
        .target(
            name: "Feature2Verify",
            dependencies: [
                .product(name: "SwiftIGL", package: "SwiftIGL"),
                .product(name: "Manifold", package: "manifold-swift")
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        )
    ]
)
