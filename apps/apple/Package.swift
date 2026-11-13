// swift-tools-version: 6.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import PackageDescription

let package = Package(
    name: "NeuralBrowser",
    platforms: [.macOS("15.4")],
    targets: [
        .executableTarget(
            name: "NeuralBrowser",
            path: "Sources/NeuralBrowser",
            swiftSettings: [
                // AppKit + WebKit delegates are main-thread only; Swift 5 mode
                // avoids Sendable friction without changing runtime behaviour.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
