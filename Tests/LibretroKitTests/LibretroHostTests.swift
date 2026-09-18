import CLibretro
import Foundation
import XCTest

@testable import LibretroKit

/// Smoke tests for the statically linked, symbol-prefixed cores driven through the
/// registry vtables and LibretroHost.
///
/// libretro's C callbacks route through a file-private global inside LibretroHost, so only
/// one core may be live at a time. XCTest runs the methods of a class serially, and the one
/// test that boots a core tears it down again, so that constraint is respected.
final class LibretroHostTests: XCTestCase {

  // MARK: - Helpers

  private func testROM() throws -> Data {
    let url = Bundle.module.url(forResource: "testrom", withExtension: "nes", subdirectory: "Resources")
      ?? Bundle.module.url(forResource: "testrom", withExtension: "nes")
    let found = try XCTUnwrap(url, "testrom.nes missing from the test bundle")
    return try Data(contentsOf: found)
  }

  /// libretro wants a path even when the ROM is handed over as bytes.
  private func writeToTemp(_ data: Data) throws -> String {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("libretro-lab-\(UUID().uuidString).nes")
    try data.write(to: url)
    return url.path
  }

  /// retro_get_system_info is documented as safe to call before retro_init.
  private func systemInfo(_ core: String) throws -> (name: String, extensions: String) {
    let entry = try XCTUnwrap(libretro_core_lookup(core), "core \(core) not in the registry")
    var info = retro_system_info()
    entry.pointee.retro_get_system_info?(&info)
    return (
      info.library_name.map { String(cString: $0) } ?? "",
      info.valid_extensions.map { String(cString: $0) } ?? ""
    )
  }

  // MARK: - Registry

  /// Every core in cores.json is linked, reachable by its wire alias, and nothing else is.
  func testRegistryListsAllCores() {
    XCTAssertEqual(
      LibretroHost.linkedCores, ["fceumm", "snes9x", "segaMD", "gambatte", "pce"],
      "registry does not match tools/cores.json")
    XCTAssertNil(libretro_core_lookup("no-such-core"))
    XCTAssertNil(libretro_core_lookup(nil))
    XCTAssertNil(LibretroHost(core: "no-such-core"))
  }

  /// Each core identifies as itself through its own vtable — the whole point of the
  /// symbol prefixing. If two cores' symbols collapsed into one (the pre-prefix failure
  /// mode: the first archive member wins), these names would come back identical.
  func testEveryCoreIdentifiesItself() throws {
    let expectations: [(core: String, marker: String, ext: String)] = [
      ("fceumm", "fceumm", "nes"),
      ("snes9x", "snes9x", "sfc"),
      ("segaMD", "genesis", "md"),
      ("gambatte", "gambatte", "gb"),
      ("pce", "pce", "pce"),
    ]
    var seen = Set<String>()
    for e in expectations {
      let entry = try XCTUnwrap(libretro_core_lookup(e.core))
      XCTAssertEqual(entry.pointee.retro_api_version?(), 1, "\(e.core) API version")
      let info = try systemInfo(e.core)
      XCTAssertTrue(
        info.name.lowercased().contains(e.marker),
        "\(e.core) reported unexpected identity: \(info.name)")
      XCTAssertTrue(
        info.extensions.lowercased().contains(e.ext),
        "\(e.core) does not claim .\(e.ext), got: \(info.extensions)")
      XCTAssertFalse(seen.contains(info.name), "two cores share library_name \(info.name)")
      seen.insert(info.name)
    }
  }

  // MARK: - End to end

  /// The real end-to-end check: boot fceumm with our authored ROM, run frames, and prove
  /// the emulator actually produced picture and sound — through the prefixed symbols.
  func testRunsROMAndProducesVideoAndAudio() throws {
    let rom = try testROM()
    let path = try writeToTemp(rom)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let host = try XCTUnwrap(LibretroHost(core: "fceumm"))
    XCTAssertEqual(host.coreName, "fceumm")

    var frameCount = 0
    var lastFrame: [UInt32] = []
    var lastWidth = 0
    var lastHeight = 0
    var lastFormat: PixelFormat?

    // The frame pointer is only valid for the duration of the callback, so copy it out.
    host.onVideo = { frame in
      guard let frame = frame else { return } // duped frame: previous one still stands
      frameCount += 1
      lastWidth = frame.width
      lastHeight = frame.height
      lastFormat = frame.format
      guard frame.format == .xrgb8888 else { return }
      var pixels = [UInt32]()
      pixels.reserveCapacity(frame.width * frame.height)
      for y in 0..<frame.height {
        let row = frame.data.advanced(by: y * frame.pitch)
          .assumingMemoryBound(to: UInt32.self)
        for x in 0..<frame.width { pixels.append(row[x]) }
      }
      lastFrame = pixels
    }

    var audioFrames = 0
    var audioPeak: Int16 = 0
    host.onAudio = { samples, frames in
      audioFrames += frames
      for i in 0..<(frames * 2) {
        let v = samples[i]
        if abs(Int(v)) > abs(Int(audioPeak)) { audioPeak = v }
      }
    }

    XCTAssertTrue(host.start(romData: rom, romPath: path), "retro_load_game rejected the ROM")
    defer { host.shutdown() }

    // Geometry and timing come straight from the core.
    XCTAssertEqual(Int(host.avInfo.geometry.base_width), 256)
    XCTAssertEqual(Int(host.avInfo.geometry.base_height), 240)
    XCTAssertEqual(host.avInfo.timing.fps, 60.0, accuracy: 1.0)
    XCTAssertGreaterThan(host.avInfo.timing.sample_rate, 8000)

    // Two vblanks of init plus margin.
    for _ in 0..<60 { host.runFrame() }

    // Isolation while a core is LIVE: querying the other cores' identity must neither
    // disturb the running core nor come back with fceumm's strings.
    for other in ["snes9x", "segaMD", "gambatte", "pce"] {
      let info = try systemInfo(other)
      XCTAssertFalse(info.name.lowercased().contains("fceumm"),
        "\(other) answered with fceumm's identity while fceumm was running")
    }
    for _ in 0..<10 { host.runFrame() }

    XCTAssertGreaterThanOrEqual(frameCount, 55, "core emitted only \(frameCount) frames in 60+ runs")
    XCTAssertEqual(lastFormat, .xrgb8888, "expected XRGB8888 (WANT_32BPP build)")
    XCTAssertEqual(lastWidth, 256)
    XCTAssertEqual(lastHeight, 240)
    XCTAssertEqual(lastFrame.count, 256 * 240, "no full frame was captured")

    // Our ROM paints every pixel with the universal backdrop colour, so the frame must be
    // essentially uniform AND not black. Both halves matter: an all-black frame is exactly
    // what a core that loaded but never ran would hand back.
    var histogram: [UInt32: Int] = [:]
    for px in lastFrame { histogram[px, default: 0] += 1 }
    let (modal, modalCount) = try XCTUnwrap(histogram.max(by: { $0.value < $1.value }))
    let share = Double(modalCount) / Double(lastFrame.count)
    XCTAssertGreaterThan(share, 0.95, "frame is not uniform (dominant colour covers \(share))")

    let r = (modal >> 16) & 0xff
    let g = (modal >> 8) & 0xff
    let b = modal & 0xff
    XCTAssertGreaterThan(
      Int(r + g + b), 24,
      "frame is black — the core produced no picture (modal pixel 0x\(String(modal, radix: 16)))")

    XCTAssertGreaterThan(audioFrames, 0, "core produced no audio frames")
    XCTAssertNotEqual(audioPeak, 0, "core produced only silence")
  }

  /// The joypad state array the input_state callback reads is the contract the touch overlay
  /// and GameController layer write into.
  func testJoypadStateArrayShape() throws {
    let host = try XCTUnwrap(LibretroHost(core: "fceumm"))
    XCTAssertEqual(host.buttons.count, 16, "RETRO_DEVICE_ID_JOYPAD_* spans 0...15")
    XCTAssertTrue(host.buttons.allSatisfy { $0 == 0 })
    XCTAssertFalse(host.loaded)
  }
}
