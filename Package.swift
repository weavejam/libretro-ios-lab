// swift-tools-version:5.9
import PackageDescription
// Mirrors desktop/plugins/tauri-plugin-libretro/ios/Package.swift in the classicgame repo,
// minus the Tauri dependency. LibretroHost.swift only imports CLibretro/Foundation/QuartzCore,
// so the exact shipping file compiles here unchanged — this is a real end-to-end check of
// that code, not a re-implementation of it.
//
// NOTE: retrocores.xcframework is produced by tools/build-cores.sh and is NOT committed.
// Run that script once before any swift/xcodebuild command, or resolution will fail.
//
// ONE binary target for ALL cores: each core is merged into a single symbol-prefixed
// object (fceumm.o, snes9x.o, ...) and they are archived together per slice, so adding
// a core never touches this manifest — only tools/cores.json and the generated registry.
let package = Package(
  name: "LibretroLab",
  platforms: [.macOS(.v12), .iOS(.v15)],
  products: [
    .library(name: "LibretroKit", targets: ["LibretroKit"])
  ],
  targets: [
    .target(name: "CLibretro", path: "Sources/CLibretro"),
    .binaryTarget(name: "retrocores", path: "retrocores.xcframework"),
    .target(
      name: "LibretroKit",
      dependencies: ["CLibretro", "retrocores"],
      path: "Sources/LibretroKit",
      // Static archives don't carry autolink info, and several cores are C++
      // (snes9x, gambatte, beetle-pce) — the client must link libc++ itself.
      linkerSettings: [.linkedLibrary("c++")]
    ),
    .testTarget(
      name: "LibretroKitTests",
      dependencies: ["LibretroKit", "CLibretro"],
      path: "Tests/LibretroKitTests",
      resources: [.copy("Resources/testrom.nes")]
    ),
  ]
)
