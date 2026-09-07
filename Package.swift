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
    /**
     Xiph's reference decoders, vendored as one C target.

     One target rather than two, and one `include/` root holding both `ogg/`
     and `vorbis/`, because the podspec needs a single `header_mappings_dir`
     to stop CocoaPods flattening the headers — it puts every public header in
     one directory, and libvorbis includes `<ogg/os_types.h>` by path.
     Splitting them here and merging them there is how the app build failed
     while `swift build` was perfectly happy.

     It is a SwiftPM target at all so that `swift test` can reach the decoder.
     A decoder only the app build compiles is one no test can exercise, and
     this engine has already been bitten by exactly that.
     */
    .target(
      name: "CVorbis",
      path: "ios/Vendor",
      sources: ["ogg/src", "vorbis/lib"],
      publicHeadersPath: "include",
      cSettings: [
        // libvorbis's sources include their own internal headers by bare name.
        .headerSearchPath("vorbis/lib"),
        .headerSearchPath("ogg/src"),
      ]
    ),
    .target(name: "YuzicEngineCore", dependencies: ["CVorbis"], path: "ios/Core"),
    .testTarget(name: "CoreTests", dependencies: ["YuzicEngineCore"], path: "Tests/CoreTests"),
  ]
)
