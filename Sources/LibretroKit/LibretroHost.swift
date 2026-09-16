import CLibretro
import Foundation
import QuartzCore

/// libretro environment command numbers (hardcoded from libretro.h to avoid relying on
/// C-macro import into Swift; the experimental-flagged ones we don't handle anyway).
private enum Env {
  static let getCanDupe: UInt32 = 3
  static let getSystemDirectory: UInt32 = 9
  static let setPixelFormat: UInt32 = 10
  static let getVariable: UInt32 = 15
  static let setVariables: UInt32 = 16
  static let getVariableUpdate: UInt32 = 17
  static let setSupportNoGame: UInt32 = 18
  static let getSaveDirectory: UInt32 = 31
  static let setCoreOptions: UInt32 = 53
  static let setCoreOptionsIntl: UInt32 = 54
  static let setCoreOptionsV2: UInt32 = 67
  static let setCoreOptionsV2Intl: UInt32 = 68
}

/// libretro pixel formats (enum retro_pixel_format).
enum PixelFormat: Int32 {
  case rgb1555 = 0  // 0RGB1555 (native endian)
  case xrgb8888 = 1 // XRGB8888 (native endian)
  case rgb565 = 2   // RGB565 (native endian)
}

/// A single decoded video frame handed off from the core's video_refresh callback.
struct VideoFrame {
  let data: UnsafeRawPointer
  let width: Int
  let height: Int
  let pitch: Int
  let format: PixelFormat
}

/// The active libretro host. libretro's C callbacks carry no user context, so we route
/// them through this file-private global. Only ONE core runs at a time (the spike loads
/// a single statically linked core, fceumm), which makes the singleton safe.
final class LibretroHost {
  /// Joypad button state, indexed by RETRO_DEVICE_ID_JOYPAD_* (0..15). Written by the
  /// input layer (touch overlay + GameController), read by the input_state callback.
  var buttons = [Int16](repeating: 0, count: 16)

  private(set) var pixelFormat: PixelFormat = .xrgb8888
  private(set) var avInfo = retro_system_av_info()
  private(set) var loaded = false

  /// Called (on the main/display-link thread) once per video_refresh with the new frame.
  var onVideo: ((VideoFrame?) -> Void)?
  /// Called with a pointer to interleaved S16 stereo samples and the frame count.
  var onAudio: ((UnsafePointer<Int16>, Int) -> Void)?

  // Sandbox dirs handed to the core via GET_SYSTEM_DIRECTORY / GET_SAVE_DIRECTORY.
  private let systemDir: String
  private let saveDir: String
  private var systemDirC: UnsafeMutablePointer<CChar>?
  private var saveDirC: UnsafeMutablePointer<CChar>?

  // Keep ROM bytes alive for the lifetime of the loaded game.
  private var romData: Data?

  init() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let sys = base.appendingPathComponent("libretro/system", isDirectory: true)
    let sav = base.appendingPathComponent("libretro/saves", isDirectory: true)
    try? FileManager.default.createDirectory(at: sys, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: sav, withIntermediateDirectories: true)
    systemDir = sys.path
    saveDir = sav.path
    systemDirC = strdup(systemDir)
    saveDirC = strdup(saveDir)
  }

  deinit {
    free(systemDirC)
    free(saveDirC)
  }

  /// Boot the core and load the ROM. Returns false on failure.
  func start(romData data: Data, romPath: String) -> Bool {
    gLibretroHost = self

    retro_set_environment(environmentCallback)
    retro_set_video_refresh(videoRefreshCallback)
    retro_set_audio_sample(audioSampleCallback)
    retro_set_audio_sample_batch(audioSampleBatchCallback)
    retro_set_input_poll(inputPollCallback)
    retro_set_input_state(inputStateCallback)

    retro_init()

    self.romData = data
    var ok = false
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      romPath.withCString { pathC in
        var info = retro_game_info()
        info.path = pathC
        info.data = raw.baseAddress
        info.size = raw.count
        info.meta = nil
        ok = retro_load_game(&info)
      }
    }
    guard ok else {
      retro_deinit()
      gLibretroHost = nil
      return false
    }

    var av = retro_system_av_info()
    retro_get_system_av_info(&av)
    avInfo = av
    retro_set_controller_port_device(0, 1) // RETRO_DEVICE_JOYPAD
    loaded = true
    return true
  }

  /// Advance one frame. Must be called from the same thread throughout (the display link).
  func runFrame() {
    guard loaded else { return }
    retro_run()
  }

  func shutdown() {
    guard loaded else { return }
    loaded = false
    retro_unload_game()
    retro_deinit()
    romData = nil
    if gLibretroHost === self { gLibretroHost = nil }
  }

  // MARK: - Environment handling (called from the C callback)

  fileprivate func handleEnvironment(_ cmd: UInt32, _ data: UnsafeMutableRawPointer?) -> Bool {
    switch cmd {
    case Env.getCanDupe:
      data?.assumingMemoryBound(to: Bool.self).pointee = true
      return true
    case Env.setPixelFormat:
      guard let data = data else { return false }
      let raw = data.assumingMemoryBound(to: Int32.self).pointee
      if let fmt = PixelFormat(rawValue: raw) {
        pixelFormat = fmt
        return true
      }
      return false
    case Env.getSystemDirectory:
      data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee =
        UnsafePointer(systemDirC)
      return true
    case Env.getSaveDirectory:
      data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee =
        UnsafePointer(saveDirC)
      return true
    case Env.getVariableUpdate:
      data?.assumingMemoryBound(to: Bool.self).pointee = false
      return true
    case Env.getVariable:
      // Tell the core "no override" so it uses its built-in defaults.
      return false
    case Env.setVariables, Env.setCoreOptions, Env.setCoreOptionsIntl,
         Env.setCoreOptionsV2, Env.setCoreOptionsV2Intl, Env.setSupportNoGame:
      return true
    default:
      return false
    }
  }
}

/// The one active host, referenced by the C callbacks below.
private var gLibretroHost: LibretroHost?

// MARK: - libretro C callbacks (no captured context; route through gLibretroHost)

private func environmentCallback(_ cmd: UInt32, _ data: UnsafeMutableRawPointer?) -> Bool {
  return gLibretroHost?.handleEnvironment(cmd, data) ?? false
}

private func videoRefreshCallback(
  _ data: UnsafeRawPointer?, _ width: UInt32, _ height: UInt32, _ pitch: Int
) {
  guard let host = gLibretroHost else { return }
  guard let data = data else {
    host.onVideo?(nil) // duped frame: keep previous
    return
  }
  host.onVideo?(VideoFrame(
    data: data, width: Int(width), height: Int(height), pitch: pitch, format: host.pixelFormat))
}

private func audioSampleCallback(_ left: Int16, _ right: Int16) {
  guard let host = gLibretroHost else { return }
  var frame = (left, right)
  withUnsafePointer(to: &frame) {
    $0.withMemoryRebound(to: Int16.self, capacity: 2) { host.onAudio?($0, 1) }
  }
}

private func audioSampleBatchCallback(_ data: UnsafePointer<Int16>?, _ frames: Int) -> Int {
  guard let host = gLibretroHost, let data = data else { return frames }
  host.onAudio?(data, frames)
  return frames
}

private func inputPollCallback() {
  // Input is sampled continuously by the input layer; nothing to do here.
}

private func inputStateCallback(
  _ port: UInt32, _ device: UInt32, _ index: UInt32, _ id: UInt32
) -> Int16 {
  guard let host = gLibretroHost else { return 0 }
  guard port == 0, device == 1 /* RETRO_DEVICE_JOYPAD */, id < 16 else { return 0 }
  return host.buttons[Int(id)]
}
