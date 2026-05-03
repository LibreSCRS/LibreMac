// swift-tools-version: 6.0
// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import PackageDescription

let package = Package(
    name: "LibreMacShared",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LibreMacShared", targets: ["LibreMacShared"]),
    ],
    targets: [
        .target(
            name: "LibreMacShared",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "LibreMacSharedTests",
            dependencies: ["LibreMacShared"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
