#!/usr/bin/env bash
# Build every core in tools/cores.json for macOS + iOS device + iOS simulator, prefix
# each core's libretro entry points, and package ONE combined retrocores.xcframework.
#
# Why one xcframework instead of one per core: the consumer (SwiftPM binaryTarget +
# the app repo's cargo link flags) then never changes when cores are added — only
# cores.json and the generated registry do.
#
# Per core and slice:
#   1. make (platform=osx CROSS_COMPILE=1 + LIBRETRO_APPLE_PLATFORM/ISYSROOT — the
#      one recipe that works for all three slices; see the fceumm notes below)
#   2. compile tools/core-shim.c with -DCORE_PREFIX=<name> → 25 prefixed wrappers
#   3. `ld -r` over all core .o + the shim → one relocatable object, with every
#      intra-core reference (shim → retro_*, core → its vendored libretro-common)
#      resolved internally. (No -d: ld-prime dropped it; clang defaults to
#      -fno-common since v11 so tentative definitions don't arise — asserted below,
#      because a surviving common would silently MERGE across cores at final link.)
#   4. `nmedit -s exported-<core>.txt` → every global except the 25 prefixed
#      wrappers becomes private extern
#   5. `ld -r` again → private externs become true statics (ld -r localizes private
#      externs by default), so two cores' identical libretro-common / zlib symbols
#      can neither collide nor cross-resolve in the final link
# Then per slice: ar every core object into libretrocores.a, and one
# xcodebuild -create-xcframework over the three slices.
#
# Carried over from the single-core recipe (proven on this CI):
#   - platform=osx + CROSS_COMPILE=1, NOT platform=ios-arm64: the osx branch appends
#     `-target <triple> -isysroot <sdk>` so slices get distinct LC_BUILD_VERSION
#     stamps (macOS/iOS/simulator = platform 1/2/7); ios-arm64 hardcodes -arch only
#     and -create-xcframework would reject device+simulator as duplicates.
#   - NO STATIC_LINKING=1: that assumes RetroArch supplies libretro-common; our host
#     doesn't, so each core must carry its own copy (which step 5 then makes private).
#   - make's exit code is not fatal (the final .dylib link step may fail when cross
#     compiling); the object-count and symbol assertions are the real gate.
#
# Env:
#   OUT=<path>           output xcframework (default ./retrocores.xcframework)
#   CORES="a b"          subset for machinery debugging only — the committed registry
#                        (cores_list.h) references ALL cores, so a subset build will
#                        fail at final link unless you trim cores.json too.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/retrocores.xcframework}"
ONLY="${CORES:-}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

RETRO_API=(
  retro_set_environment retro_set_video_refresh retro_set_audio_sample
  retro_set_audio_sample_batch retro_set_input_poll retro_set_input_state
  retro_init retro_deinit retro_api_version retro_get_system_info
  retro_get_system_av_info retro_set_controller_port_device retro_reset retro_run
  retro_serialize_size retro_serialize retro_unserialize retro_cheat_reset
  retro_cheat_set retro_load_game retro_load_game_special retro_unload_game
  retro_get_region retro_get_memory_data retro_get_memory_size
)

SLICES=(macos-arm64 ios-arm64 ios-arm64-simulator)
triple_for() {
  case "$1" in
    macos-arm64) echo arm64-apple-macosx12.0 ;;
    ios-arm64) echo arm64-apple-ios15.0 ;;
    ios-arm64-simulator) echo arm64-apple-ios15.0-simulator ;;
  esac
}
sdk_for() {
  case "$1" in
    macos-arm64) echo macosx ;;
    ios-arm64) echo iphoneos ;;
    ios-arm64-simulator) echo iphonesimulator ;;
  esac
}

for slice in "${SLICES[@]}"; do mkdir -p "$WORK/out-$slice"; done

# cores.json → one TAB-separated line per core (name repo ref dir makefile)
node -e '
  const fs = require("node:fs");
  const cores = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  for (const c of cores)
    console.log([c.name, c.repo, c.ref || "master", c.dir || ".", c.makefile || "Makefile.libretro"].join("\t"));
' "$ROOT/tools/cores.json" > "$WORK/cores.tsv"

while IFS=$'\t' read -r name repo ref dir mkfile; do
  if [ -n "$ONLY" ]; then
    case " $ONLY " in *" $name "*) ;; *) echo "==> skipping $name (CORES filter)"; continue ;; esac
  fi

  echo "==> cloning $name @ $ref  ($repo)"
  git clone --quiet --depth 1 --branch "$ref" "$repo" "$WORK/src-$name"
  echo "    $(cd "$WORK/src-$name" && git rev-parse HEAD)"

  exported="$WORK/exported-$name.txt"
  : > "$exported"
  for f in "${RETRO_API[@]}"; do echo "_${name}_${f}" >> "$exported"; done

  for slice in "${SLICES[@]}"; do
    triple="$(triple_for "$slice")"
    sdk="$(sdk_for "$slice")"
    isysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    bdir="$WORK/build-$name-$slice"

    echo "==> $name / $slice  target=$triple"
    cp -R "$WORK/src-$name" "$bdir"

    # Do not override CFLAGS/CC on the command line: that would clobber the
    # -target/-isysroot the Makefile itself appends from LIBRETRO_APPLE_*.
    if ! make -C "$bdir/$dir" -f "$mkfile" -j"$(sysctl -n hw.ncpu)" \
        platform=osx CROSS_COMPILE=1 \
        LIBRETRO_APPLE_PLATFORM="$triple" \
        LIBRETRO_APPLE_ISYSROOT="$isysroot" > "$WORK/make-$name-$slice.log" 2>&1; then
      echo "    note: make exited non-zero (usually the final .dylib link — we only need the .o)"
      tail -n 10 "$WORK/make-$name-$slice.log" | sed 's/^/    | /'
    fi

    objects=$(find "$bdir" -name '*.o' | wc -l | tr -d ' ')
    echo "    $objects object files"
    if [ "$objects" -lt 15 ]; then
      echo "    FATAL: $name/$slice compile failed (too few objects)" >&2
      tail -n 60 "$WORK/make-$name-$slice.log" >&2
      exit 1
    fi

    xcrun clang -c -O2 -target "$triple" -isysroot "$isysroot" \
      -I "$ROOT/Sources/CLibretro/include" -DCORE_PREFIX="$name" \
      "$ROOT/tools/core-shim.c" -o "$bdir/core-shim-$name.o"

    find "$bdir" -name '*.o' > "$WORK/objs.txt"
    xcrun ld -r -arch arm64 -filelist "$WORK/objs.txt" -o "$bdir/merged.o"
    xcrun nmedit -s "$exported" "$bdir/merged.o" -o "$bdir/hidden.o"
    xcrun ld -r -arch arm64 "$bdir/hidden.o" -o "$WORK/out-$slice/$name.o"

    # The whole point: exactly the 25 prefixed wrappers survive as external symbols.
    defined="$(nm -g --defined-only "$WORK/out-$slice/$name.o" | awk '{print $NF}')"
    n="$(printf '%s\n' "$defined" | grep -c . || true)"
    echo "    $n external symbols after hiding"
    if [ "$n" -ne 25 ]; then
      echo "    FATAL: expected exactly 25 exported symbols, got $n:" >&2
      printf '%s\n' "$defined" | head -n 40 >&2
      exit 1
    fi
    printf '%s\n' "$defined" | grep -qx "_${name}_retro_run" \
      || { echo "    FATAL: _${name}_retro_run missing" >&2; exit 1; }
    if printf '%s\n' "$defined" | grep -qxE '_retro_run|_filestream_open'; then
      echo "    FATAL: unprefixed symbols leaked past nmedit" >&2
      exit 1
    fi
    # Tentative definitions (commons) would merge ACROSS cores at final link —
    # shared state between emulators. clang's default -fno-common should prevent
    # any; fail loudly if a core's build flags resurrect them.
    commons="$(nm -g "$WORK/out-$slice/$name.o" | awk '$2 == "C" { print $NF }')"
    if [ -n "$commons" ]; then
      echo "    FATAL: external common symbols survived (would merge across cores):" >&2
      printf '%s\n' "$commons" | head -n 20 >&2
      exit 1
    fi

    # Confirm the platform stamp survived the partial links (macOS/iOS/sim = 1/2/7).
    otool -l "$WORK/out-$slice/$name.o" \
      | grep -A3 LC_BUILD_VERSION | grep -E 'platform|minos' | tr -s ' ' | tr '\n' ' ' || true
    echo "    ok: $name.o ($(du -h "$WORK/out-$slice/$name.o" | cut -f1))"
  done

  rm -rf "$WORK/src-$name" "$WORK/build-$name-"*
done < "$WORK/cores.tsv"

LIBS=()
for slice in "${SLICES[@]}"; do
  lib="$WORK/out-$slice/libretrocores.a"
  ar rcs "$lib" "$WORK/out-$slice"/*.o
  echo "==> $slice: libretrocores.a ($(du -h "$lib" | cut -f1))"
  LIBS+=(-library "$lib")
done

echo "==> packaging $OUT"
rm -rf "$OUT"
# No -headers: the Swift side gets its declarations from the CLibretro module map, and
# bundling libretro.h here too would create a second, clashing module.
xcodebuild -create-xcframework "${LIBS[@]}" -output "$OUT"

echo "==> done"
find "$OUT" -name 'Info.plist' -maxdepth 2 -exec plutil -p {} \; | grep -E 'LibraryIdentifier|SupportedPlatform' || true
