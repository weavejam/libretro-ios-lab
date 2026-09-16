#!/usr/bin/env bash
#
# Builds the fceumm libretro core as a static library for every Apple slice we care about
# and packages them into fceumm.xcframework.
#
# Two decisions here are the whole point of this repo:
#
# 1. platform=osx + CROSS_COMPILE=1 instead of platform=ios-arm64.
#    fceumm's Makefile.libretro has an `ifeq ($(CROSS_COMPILE),1)` branch inside the osx
#    platform that appends `-target <triple> -isysroot <sdk>` to both CFLAGS and LDFLAGS.
#    That gives us one uniform recipe for macOS, iOS device AND iOS Simulator. The
#    platform=ios-arm64 branch hardcodes `cc -arch arm64 -isysroot $(IOSSDK)` with no
#    simulator option — and `-arch` alone does not stamp a distinct LC_BUILD_VERSION, which
#    is what makes `xcodebuild -create-xcframework` reject device+simulator slices as
#    duplicates. A real `-target` triple is what unlocks a runnable Simulator test.
#
# 2. No STATIC_LINKING=1.
#    fceumm's Makefile.common wraps the bundled libretro-common sources in
#    `ifneq ($(STATIC_LINKING),1)`, on the assumption that a RetroArch frontend already
#    provides filestream_*/path_is_valid/fill_pathname_join. Our Swift host does not, so
#    setting it produces undefined symbols at the final link. Leaving it off means those
#    objects are compiled and archived into the .a with everything else.
#
# The `make` exit code is deliberately not fatal: the Makefile's final step links a .dylib,
# which is meaningless (and may fail) when cross-compiling to iOS. We only want the object
# files. The authoritative checks are the nm symbol probes below plus the Swift link that
# follows in CI — a missing object shows up there immediately.

set -euo pipefail

FCEUMM_REPO="${FCEUMM_REPO:-https://github.com/libretro/libretro-fceumm.git}"
FCEUMM_REF="${FCEUMM_REF:-master}"
OUT="${OUT:-$PWD/fceumm.xcframework}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> cloning fceumm @ $FCEUMM_REF"
git clone --quiet --depth 1 --branch "$FCEUMM_REF" "$FCEUMM_REPO" "$WORK/src"
echo "    $(cd "$WORK/src" && git rev-parse HEAD)"

LIBS=()

build_slice() {
  local name="$1" triple="$2" sdk="$3"
  local dir="$WORK/build-$name"
  local lib="$WORK/libfceumm-$name.a"
  local isysroot
  isysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"

  echo "==> building slice '$name'  target=$triple  sdk=$sdk"
  cp -R "$WORK/src" "$dir"

  # Do not override CFLAGS/CC on the command line: that would clobber the -target/-isysroot
  # the Makefile itself appends from LIBRETRO_APPLE_*.
  if ! make -C "$dir" -f Makefile.libretro -j"$(sysctl -n hw.ncpu)" \
      platform=osx \
      CROSS_COMPILE=1 \
      LIBRETRO_APPLE_PLATFORM="$triple" \
      LIBRETRO_APPLE_ISYSROOT="$isysroot" > "$WORK/make-$name.log" 2>&1; then
    echo "    note: make exited non-zero (expected for iOS slices: the final .dylib link)."
    tail -n 15 "$WORK/make-$name.log" | sed 's/^/    | /'
  fi

  local objects
  objects=$(find "$dir" -name '*.o' | wc -l | tr -d ' ')
  echo "    $objects object files"
  if [ "$objects" -lt 50 ]; then
    echo "    FATAL: too few objects, the compile itself failed" >&2
    tail -n 60 "$WORK/make-$name.log" >&2
    exit 1
  fi

  find "$dir" -name '*.o' -print0 | xargs -0 ar rcs "$lib"

  # The core entry points must be present, and so must the libretro-common helpers that
  # STATIC_LINKING=1 would have removed.
  # Match on the symbol name only, not the type letter: cores built with hidden visibility
  # emit private-extern symbols, which nm prints in lowercase.
  local defined
  defined="$(nm -g --defined-only "$lib" 2>/dev/null | awk '{print $NF}')"
  echo "    $(printf '%s\n' "$defined" | grep -c . ) defined global symbols"
  for sym in _retro_run _retro_load_game _retro_get_system_av_info _filestream_open; do
    if ! printf '%s\n' "$defined" | grep -qx -- "$sym"; then
      echo "    FATAL: $sym missing from $lib" >&2
      echo "    nm lines mentioning ${sym#_}:" >&2
      nm -g "$lib" 2>&1 | grep -- "${sym#_}" | head -n 10 | sed 's/^/    | /' >&2
      exit 1
    fi
  done

  # Confirm the slice really is stamped for the platform we asked for.
  local firstobj
  # -print -quit rather than `| head -1`: closing the pipe early makes find fail under pipefail.
  firstobj=$(find "$dir" -name '*.o' -print -quit)
  echo "    $(otool -l "$firstobj" | grep -A3 LC_BUILD_VERSION | grep -E 'platform|minos' | tr -s ' ' | tr '\n' ' ')"

  echo "    ok: $lib ($(du -h "$lib" | cut -f1))"
  LIBS+=(-library "$lib")
}

build_slice "macos-arm64"        "arm64-apple-macosx12.0"           "macosx"
build_slice "ios-arm64"          "arm64-apple-ios15.0"              "iphoneos"
build_slice "ios-arm64-simulator" "arm64-apple-ios15.0-simulator"   "iphonesimulator"

echo "==> packaging $OUT"
rm -rf "$OUT"
# No -headers: the Swift side gets its declarations from the CLibretro module map, and
# bundling libretro.h here too would create a second, clashing module.
xcodebuild -create-xcframework "${LIBS[@]}" -output "$OUT"

echo "==> done"
find "$OUT" -name 'Info.plist' -maxdepth 2 -exec plutil -p {} \; | grep -E 'LibraryIdentifier|SupportedPlatform' || true
