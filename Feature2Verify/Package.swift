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
        .package(url: "https://github.com/heckj/Voxels.git", from: "0.2.6"),
        .package(url: "https://github.com/iShape-Swift/iTriangle.git", from: "1.17.0"),
        .package(url: "https://github.com/nicklockwood/Euclid.git", from: "0.8.20"),
        .package(url: "https://github.com/tomasf/manifold-swift.git", from: "1.1.0")
    ],
    targets: [
        .target(
            name: "Feature2Verify",
            dependencies: [
                .product(name: "Voxels", package: "Voxels"),
                .product(name: "iTriangle", package: "iTriangle"),
                .product(name: "Euclid", package: "Euclid"),
                .product(name: "Manifold", package: "manifold-swift")
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        )
    ]
)
