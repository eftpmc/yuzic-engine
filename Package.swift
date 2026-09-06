// swift-tools-version: 5.9
import PackageDescription

/**
 A SwiftPM package over the *core* of the iOS side — the model, the queue rules
 and the graph. Not the Expo module, which needs `ExpoModulesCore` and a React
 Native toolchain to build at all.

 The point is that the logic worth testing can be compiled and run by
 `swift test` on any Mac, with no Xcode project, no pod install and no app. The
 bridge stays in `ios/YuzicEngineModule.swift` and converts at the edge; the
 podspec picks up both directories, so this package existing costs the real
 build nothing.

 Written after both platforms' code had been reviewed but never compiled, which
 is a state worth not staying in.
 */
let package = Package(
  name: "YuzicEngineCore",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [
    .library(name: "YuzicEngineCore", targets: ["YuzicEngineCore"]),
  ],
  targets: [
    .target(name: "YuzicEngineCore", path: "ios/Core"),
    .testTarget(name: "CoreTests", dependencies: ["YuzicEngineCore"], path: "Tests/CoreTests"),
  ]
)
