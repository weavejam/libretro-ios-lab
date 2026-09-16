// swift-tools-version:5.9
import PackageDescription

// Mirrors desktop/plugins/tauri-plugin-libretro/ios/Package.swift in the classicgame repo,
// minus the Tauri dependency. LibretroHost.swift only imports CLibretro/Foundation/QuartzCore,
// so the exact shipping file compiles here unchanged — this is a real end-to-end check of
// that code, not a re-implementation of it.
//
// NOTE: fceumm.xcframework is produced by tools/build-core.sh and is NOT committed.
// Run that script once before any swift/xcodebuild command, or resolution will fail.
let package = Package(
  name: "LibretroLab",
  platforms: [.macOS(.v12), .iOS(.v15)],
  products: [
    .library(name: "LibretroKit", targets: ["LibretroKit"])
  ],
  targets: [
    .target(name: "CLibretro", path: "Sources/CLibretro"),
    .binaryTarget(name: "fceumm", path: "fceumm.xcframework"),
    .target(
      name: "LibretroKit",
      dependencies: ["CLibretro", "fceumm"],
      path: "Sources/LibretroKit"
    ),
    .testTarget(
      name: "LibretroKitTests",
      dependencies: ["LibretroKit", "CLibretro"],
      path: "Tests/LibretroKitTests",
      resources: [.copy("Resources/testrom.nes")]
    ),
  ]
)
