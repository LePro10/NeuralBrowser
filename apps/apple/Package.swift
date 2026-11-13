// swift-tools-version: 6.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import PackageDescription

// The Rust core is built by core/build-apple.sh into core/dist/apple/. The C
// target exposes its header/module map (symlinks), NeuralCore holds the
// generated UniFFI Swift bindings, and the static library is linked into the app.
let coreLib = Context.packageDirectory + "/../../core/dist/apple"

let package = Package(
    name: "NeuralBrowser",
    platforms: [.macOS("15.4")],
    targets: [
        .target(name: "CNeuralCore", path: "Sources/CNeuralCore"),
        .target(
            name: "NeuralCore",
            dependencies: ["CNeuralCore"],
            path: "Sources/NeuralCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "NeuralBrowser",
            dependencies: ["NeuralCore"],
            path: "Sources/NeuralBrowser",
            swiftSettings: [
                // AppKit + WebKit delegates are main-thread only; Swift 5 mode
                // avoids Sendable friction without changing runtime behaviour.
                .swiftLanguageMode(.v5)
            ],
            // unsafeFlags are fine for a root package. Links the Rust static library;
            // `-w` silences ld's "built for newer macOS" notes: the prebuilt Rust std
            // objects carry the minimum version of the toolchain host, which we cannot change.
            linkerSettings: [.unsafeFlags([coreLib + "/libneural_core.a", "-Xlinker", "-w"])]
        )
    ]
)
