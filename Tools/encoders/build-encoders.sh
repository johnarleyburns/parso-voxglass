#!/bin/bash
# build-encoders.sh — Voxglass Studio encoder build recipe (spec §16.3, correction C-3).
#
# Builds the two required third-party encoders as macOS xcframeworks:
#   - libmp3lame 3.100  (LGPL-2.1)    — MP3, CBR capable
#   - libFLAC   1.4.3   (BSD-3-Clause) — FLAC, lossless
#
# Why these and only these: AVFoundation on macOS decodes MP3/FLAC but encodes
# neither (§16.3). AAC/ALAC/PCM come from AVFoundation and need no third party.
# The GPL-configured ffmpeg is explicitly forbidden here (§16.3, C-3): the App
# Store additional permission in LICENSE-APPSTORE-EXCEPTION.md is granted by this
# repository's copyright holder and cannot bind a GPL-configured ffmpeg's authors.
#
# Output (committed, so CI and SwiftPM link it without running this script):
#   Tools/encoders/Vendored/Lame.xcframework
#   Tools/encoders/Vendored/FLAC.xcframework
#
# Layout: one static *framework* slice (macos-arm64_x86_64) per library, holding a
# fat static lib (arm64+x86_64) plus Headers/ and Modules/module.modulemap. Static
# framework slices are importable by SwiftPM as binary targets and link into the
# Studio app binary, so no runtime framework loading is needed. The Info.plist is
# written by hand because `xcodebuild -create-xcframework` rejects two thin
# libraries of the same platform ("equivalent library definitions") and the
# -library form does not emit an importable module map.
#
# LGPL obligations (§16.3, §21.4) are met by shipping this recipe plus the written
# offer for the unmodified sources in Voxglass/Resources/ThirdPartyNotices.md.
#
# Requires: curl, tar, Xcode toolchain (clang/ar/lipo), and make. Idempotent.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/Tools/encoders/Vendored"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/voxglass-encoders.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

LAME_VERSION="3.100"
FLAC_VERSION="1.4.3"
MIN_MACOS="14.0"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

download() {
  local file="$1"
  shift
  if [ -f "$TMP/$file" ]; then return; fi
  say "Downloading $file"
  for url in "$@"; do
    if curl -fsSL --retry 3 --max-time 120 -o "$TMP/$file" "$url"; then
      return
    fi
    say "  mirror failed, trying next"
  done
  echo "error: could not download $file" >&2
  exit 1
}

make_lame() {
  say "Fetching LAME $LAME_VERSION"
  local src="$TMP/lame-$LAME_VERSION"
  if [ ! -d "$src" ]; then
    download "lame-$LAME_VERSION.tar.gz" \
      "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" \
      "https://phoenixnap.dl.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" \
      "https://kent.dl.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz"
    tar -xzf "$TMP/lame-$LAME_VERSION.tar.gz" -C "$TMP"
  fi

  local flags="--disable-shared --enable-static --disable-frontend --disable-decoder"
  for arch in arm64 x86_64; do
    local work="$TMP/lame-$LAME_VERSION-$arch"
    cp -R "$src" "$work"
    (
      cd "$work"
      # --host for x86_64 is REQUIRED: configure derives host_cpu from the
      # *build machine* (arm64 here), and LAME gates its SSE/vector code on
      # `case $host_cpu in x86_64|amd64`. Without it, HAVE_XMMINTRIN_H is
      # defined in quantize.c but xmm_quantize_sub.c is never built, producing
      # an archive with an undefined `init_xrpow_core_sse` that fails to link.
      local host_arg=""
      [ "$arch" = "x86_64" ] && host_arg="--host=x86_64-apple-darwin"
      ./configure $flags \
        --prefix="$work/prefix" \
        $host_arg \
        CFLAGS="-arch $arch -mmacosx-version-min=$MIN_MACOS -O2" \
        LDFLAGS="-arch $arch" >/dev/null
      make -j"$(sysctl -n hw.ncpu)" >/dev/null
    )
  done
  lipo -create \
    "$TMP/lame-$LAME_VERSION-arm64/libmp3lame/.libs/libmp3lame.a" \
    "$TMP/lame-$LAME_VERSION-x86_64/libmp3lame/.libs/libmp3lame.a" \
    -output "$TMP/libmp3lame-fat.a"
}

make_flac() {
  say "Fetching FLAC $FLAC_VERSION"
  local src="$TMP/flac-$FLAC_VERSION"
  if [ ! -d "$src" ]; then
    download "flac-$FLAC_VERSION.tar.xz" \
      "https://downloads.xiph.org/releases/flac/flac-$FLAC_VERSION.tar.xz" \
      "https://ftp.osuosl.org/pub/xiph/releases/flac/flac-$FLAC_VERSION.tar.xz"
    tar -xJf "$TMP/flac-$FLAC_VERSION.tar.xz" -C "$TMP"
  fi

  local flags="--disable-shared --enable-static --disable-programs --disable-examples --disable-ogg --disable-cpplibs --disable-thorough-tests"
  for arch in arm64 x86_64; do
    local work="$TMP/flac-$FLAC_VERSION-$arch"
    cp -R "$src" "$work"
    (
      cd "$work"
      local host_arg=""
      [ "$arch" = "x86_64" ] && host_arg="--host=x86_64-apple-darwin"
      ./configure $flags \
        --prefix="$work/prefix" \
        $host_arg \
        CFLAGS="-arch $arch -mmacosx-version-min=$MIN_MACOS -O2" \
        LDFLAGS="-arch $arch" >/dev/null
      make -j"$(sysctl -n hw.ncpu)" >/dev/null
    )
  done
  lipo -create \
    "$TMP/flac-$FLAC_VERSION-arm64/src/libFLAC/.libs/libFLAC.a" \
    "$TMP/flac-$FLAC_VERSION-x86_64/src/libFLAC/.libs/libFLAC.a" \
    -output "$TMP/libFLAC-fat.a"
}

# assemble_xcframework <name> <fatlib> <umbrella-header> <extra-headers...>
assemble_xcframework() {
  local name="$1" fatlib="$2" umbrella="$3"
  shift 3
  local xcfw="$OUT/$name.xcframework"
  local fw="$TMP/$name/macos-arm64_x86_64/$name.framework"

  say "Assembling $name.xcframework"
  mkdir -p "$fw/Headers" "$fw/Modules"
  cp "$fatlib" "$fw/$name"
  cp "$umbrella" "$fw/Headers/"
  for h in "$@"; do
    cp "$h" "$fw/Headers/"
  done
  cat > "$fw/Modules/module.modulemap" <<MODULE
framework module $name {
    umbrella header "$(basename "$umbrella")"
    export *
    module * { export * }
}
MODULE

  rm -rf "$xcfw"
  mkdir -p "$xcfw"
  cp -R "$TMP/$name/macos-arm64_x86_64" "$xcfw/"
  # NOTE: do NOT emit a HeadersPath for a 'framework' slice — Xcode 26 rejects
  # it ("'HeadersPath' is not supported for a 'framework'"); headers are found
  # inside the framework slice's Headers/ dir via the module.modulemap.
  cat > "$xcfw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>$name.framework/$name</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64_x86_64</string>
			<key>LibraryPath</key>
			<string>$name.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
				<string>x86_64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
			<key>Type</key>
			<string>framework</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
PLIST
}

main() {
  say "Voxglass Studio encoders — building LAME $LAME_VERSION + FLAC $FLAC_VERSION for arm64+x86_64 macOS $MIN_MACOS+"
  mkdir -p "$OUT"

  make_lame
  make_flac

  assemble_xcframework "Lame" "$TMP/libmp3lame-fat.a" \
    "$TMP/lame-$LAME_VERSION/include/lame.h"

  assemble_xcframework "FLAC" "$TMP/libFLAC-fat.a" \
    "$TMP/flac-$FLAC_VERSION/include/FLAC/stream_encoder.h" \
    "$TMP/flac-$FLAC_VERSION/include/FLAC/all.h" \
    "$TMP/flac-$FLAC_VERSION/include/FLAC/assert.h" \
    "$TMP/flac-$FLAC_VERSION/include/FLAC/callback.h" \
    "$TMP/flac-$FLAC_VERSION/include/FLAC/export.h" \
    "$TMP/flac-$FLAC_VERSION/include/FLAC/format.h" \
    "$TMP/flac-$FLAC_VERSION/include/FLAC/ordinals.h" \
    "$TMP/flac-$FLAC_VERSION/include/FLAC/metadata.h" \
    "$TMP/flac-$FLAC_VERSION/include/FLAC/stream_decoder.h"
  # metadata.h is not included by stream_encoder.h, so it must be listed in the
  # module map explicitly or the metadata API (Vorbis comments) is invisible to
  # Swift. Patch the module map after assembly.
  python3 - "$OUT/FLAC.xcframework/macos-arm64_x86_64/FLAC.framework/Modules/module.modulemap" <<'PY'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
text = text.replace('    umbrella header "stream_encoder.h"\n', '    umbrella header "stream_encoder.h"\n    header "metadata.h"\n', 1)
with open(path, "w") as f:
    f.write(text)
PY

  say "Done. Vendored xcframeworks:"
  du -sh "$OUT"/*.xcframework
}

main "$@"
