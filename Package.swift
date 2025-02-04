// swift-tools-version: 5.9
// This is free software: you can redistribute and/or modify it
// under the terms of the GNU General Public License 3.0
// as published by the Free Software Foundation https://fsf.org

import PackageDescription

let package = Package(
    name: "net-skip-app",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NetSkipApp", type: .dynamic, targets: ["NetSkip"]),
    ],
    dependencies: [
        .package(url: "https://github.com/appfair/appfair-app.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-foundation.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-ui.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-model.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-web.git", "0.0.0"..<"2.0.0"),
        .package(url: "https://source.skip.tools/skip-sql.git", "0.0.0"..<"2.0.0"),
        .package(url: "https://source.skip.tools/skip-script.git", "0.0.0"..<"2.0.0"),
//        .package(url: "https://source.skip.tools/skip-xml.git", "0.0.0"..<"2.0.0"),
//        .package(url: "https://source.skip.tools/skip-zip.git", "0.0.0"..<"2.0.0"),
    ],
    targets: [
        .target(name: "NetSkip", dependencies: [
            "NetSkipModel",
            .product(name: "AppFairApp", package: "appfair-app"),
            .product(name: "SkipUI", package: "skip-ui"),
            .product(name: "SkipWeb", package: "skip-web"),
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .testTarget(name: "NetSkipTests", dependencies: [
            "NetSkip",
            .product(name: "SkipTest", package: "skip")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),

        .target(name: "NetSkipModel", dependencies: [
            .product(name: "SkipFoundation", package: "skip-foundation"),
            .product(name: "SkipModel", package: "skip-model"),
            .product(name: "SkipWeb", package: "skip-web"),
            .product(name: "SkipSQL", package: "skip-sql"),
            .product(name: "SkipScript", package: "skip-script"),
//            .product(name: "SkipXML", package: "skip-xml"),
//            .product(name: "SkipZip", package: "skip-zip"),
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .testTarget(name: "NetSkipModelTests", dependencies: [
            "NetSkipModel",
            .product(name: "SkipTest", package: "skip")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
    ]
)
