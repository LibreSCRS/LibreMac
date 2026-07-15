// swift-tools-version: 6.0
// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import PackageDescription

let package = Package(
    name: "LibreMacAgentClient",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LibreMacAgentClient", targets: ["LibreMacAgentClient"]),
    ],
    targets: [
        .target(
            name: "LibreMacAgentClient",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "LibreMacAgentClientTests",
            dependencies: ["LibreMacAgentClient"],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
