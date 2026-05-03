// swift-tools-version: 6.0
// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import PackageDescription

let package = Package(
    name: "ts2xcstrings",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "ts2xcstrings",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ts2xcstringsTests",
            dependencies: ["ts2xcstrings"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
