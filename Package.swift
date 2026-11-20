// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "gamehost",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.122.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
        .package(url: "https://github.com/vapor/multipart-kit.git", from: "4.7.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
    ],
    targets: [
        .target(
            name: "GamehostCore",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "TOMLKit", package: "TOMLKit"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "MultipartKit", package: "multipart-kit"),
            ]
        ),
        .executableTarget(name: "gamehost", dependencies: ["GamehostCore"]),
        .testTarget(
            name: "GamehostCoreTests",
            dependencies: [
                "GamehostCore",
                .product(name: "XCTVapor", package: "vapor"),
            ]
        ),
    ]
)
