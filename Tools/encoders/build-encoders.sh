#!/bin/bash
# build-encoders.sh — Voxglass encoder build recipe (spec §16.3, correction C-3).
#
# Builds the two required third-party encoders as multi-platform xcframeworks:
#   - libmp3lame 3.100  (LGPL-2.1)    — MP3, CBR capable
#   - libFLAC   1.4.3   (BSD-3-Clause) — FLAC, lossless
#
# Why these and only these: AVFoundation decodes MP3 but neither encodes MP3
# nor offers a deterministic FLAC path (§16.3). AAC/ALAC/PCM come from
# AVFoundation and need no third party. The GPL-configured ffmpeg is explicitly
# forbidden here (§16.3, C-3): the App Store additional permission in
# LICENSE-APPSTORE-EXCEPTION.md is granted by this repository's copyright
# holder and cannot bind a GPL-configured ffmpeg's authors.
#
# Output (committed, so CI and SwiftPM link it without running this script):
#   Tools/encoders/Vendored/Lame.xcframework
#   Tools/encoders/Vendored/FLAC.xcframework
#
# Required slices (§16.3) — every slice exposes the same Swift-importable
# modules `Lame` and `FLAC`:
#   - macos-arm64_x86_64               (macOS host for swift test)
#   - ios-arm64                        (physical iPhone, iOS 17+)
#   - ios-arm64_x86_64-simulator       (iOS simulator builds and tests)
#
# Layout: one framework slice per platform, holding a fat dynamic library
# (arm64+x86_64 where two architectures share the platform) plus Headers/ and
# Modules/module.modulemap. The iOS slices are shallow; the macOS slice uses
# the required Versions/Current layout. The framework slices are importable by
# SwiftPM as binary targets and link into both app binaries; no local/system
# codec is needed (§16.3). The Info.plist is written by hand because
# `xcodebuild -create-xcframework` rejects two thin libraries of the same
# platform ("equivalent library definitions") and the `-library` form does not
# emit an importable module map.
#
# LGPL obligations (§16.3, §21.4) are met by shipping this recipe plus the
# written offer for the unmodified sources in Voxglass/Resources/ThirdPartyNotices.md.
#
# Requires: curl, tar, xcrun (Xcode toolchain), clang, ar, lipo, make, python3.
# Does NOT require Homebrew or any system-installed codec. Idempotent.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/Tools/encoders/Vendored"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/voxglass-encoders.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

LAME_VERSION="3.100"
FLAC_VERSION="1.4.3"
MIN_MACOS="14.0"
MIN_IOS="17.0"

SDK_MACOS="$(xcrun --sdk macosx --show-sdk-path)"
SDK_IPHONEOS="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_IPHONESIM="$(xcrun --sdk iphonesimulator --show-sdk-path)"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

download() {
  local file="$1"
  shift
  if [ -f "$TMP/$file" ]; then return; fi
  say "Downloading $file"
  for url in "$@"; do
    if curl -fsSL --retry 3 --max-time 180 -o "$TMP/$file" "$url"; then
      return
    fi
    say "  mirror failed, trying next"
  done
  echo "error: could not download $file" >&2
  exit 1
}

# ──────────────────────────────────────────────────────────────
# Per-architecture library builds
# ──────────────────────────────────────────────────────────────

# lame_slice <arch> <platform> <host> <cflags-extra>
#   platform ∈ {macosx, iphoneos, iphonesimulator}
#   host empty means "native build-machine detection"
lame_slice() {
  local arch="$1" platform="$2" host="$3" extra="$4"
  local work="$TMP/lame-$arch-$platform"
  local sdk="$SDK_MACOS"
  [ "$platform" = "iphoneos" ] && sdk="$SDK_IPHONEOS"
  [ "$platform" = "iphonesimulator" ] && sdk="$SDK_IPHONESIM"
  local minver=""
  [ "$platform" = "macosx" ] && minver="-mmacosx-version-min=$MIN_MACOS"
  [ "$platform" = "iphoneos" ] && minver="-miphoneos-version-min=$MIN_IOS"
  [ "$platform" = "iphonesimulator" ] && minver="-mios-simulator-version-min=$MIN_IOS"

  cp -R "$TMP/lame-src" "$work"
  (
    cd "$work"
    # --host for x86_64 is REQUIRED: configure derives host_cpu from the
    # *build machine* (arm64 here), and LAME gates its SSE/vector code on
    # `case $host_cpu in x86_64|amd64`. Without it, HAVE_XMMINTRIN_H is
    # defined in quantize.c but xmm_quantize_sub.c is never built, producing
    # an archive with an undefined `init_xrpow_core_sse` that fails to link.
    ./configure --disable-shared --enable-static --disable-frontend --disable-decoder \
      --prefix="$work/prefix" \
      $host \
      CFLAGS="-arch $arch -isysroot $sdk $minver -O2 $extra" \
      LDFLAGS="-arch $arch -isysroot $sdk" >/dev/null
    make -j"$(sysctl -n hw.ncpu)" >/dev/null
  )
}

# flac_slice <arch> <platform> <host> <cflags-extra>
flac_slice() {
  local arch="$1" platform="$2" host="$3" extra="$4"
  local work="$TMP/flac-$arch-$platform"
  local sdk="$SDK_MACOS"
  [ "$platform" = "iphoneos" ] && sdk="$SDK_IPHONEOS"
  [ "$platform" = "iphonesimulator" ] && sdk="$SDK_IPHONESIM"
  local minver=""
  [ "$platform" = "macosx" ] && minver="-mmacosx-version-min=$MIN_MACOS"
  [ "$platform" = "iphoneos" ] && minver="-miphoneos-version-min=$MIN_IOS"
  [ "$platform" = "iphonesimulator" ] && minver="-mios-simulator-version-min=$MIN_IOS"

  cp -R "$TMP/flac-src" "$work"
  (
    cd "$work"
    ./configure --disable-shared --enable-static --disable-programs \
      --disable-examples --disable-ogg --disable-cpplibs --disable-thorough-tests \
      --prefix="$work/prefix" \
      $host \
      CFLAGS="-arch $arch -isysroot $sdk $minver -O2 $extra" \
      LDFLAGS="-arch $arch -isysroot $sdk" >/dev/null
    make -j"$(sysctl -n hw.ncpu)" >/dev/null
  )
}

# relink_dylib <name> <thin-archive> <arch> <sdk> <minver> <output>
#   Re-links a thin static archive as a dynamic library for one architecture.
#   The library is built as a static archive by its autotools build so its
#   platform gates (SSE detection, feature macros) stay identical; the relink
#   simply produces the shared-library form the xcframework needs so Xcode
#   treats each platform slice as a distinct library (static slices with
#   overlapping architectures are rejected as "equivalent library definitions").
relink_dylib() {
  local name="$1" archive="$2" arch="$3" sdk="$4" minver="$5" output="$6"
  local objdir="$TMP/obj-$name-$arch"
  rm -rf "$objdir"
  mkdir -p "$objdir"
  (cd "$objdir" && ar -x "$archive")

  clang -dynamiclib \
    -arch "$arch" \
    -isysroot "$sdk" $minver \
    -Wl,-install_name,"@rpath/$name.framework/$name" \
    -Wl,-compatibility_version,1.0 \
    -Wl,-current_version,1.0 \
    -Wl,-single_module \
    -o "$output" "$objdir"/*.o
}

make_lame() {
  say "Fetching LAME $LAME_VERSION"
  local src="$TMP/lame-src"
  if [ ! -d "$src" ]; then
    download "lame-$LAME_VERSION.tar.gz" \
      "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" \
      "https://phoenixnap.dl.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" \
      "https://kent.dl.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz"
    tar -xzf "$TMP/lame-$LAME_VERSION.tar.gz" -C "$TMP"
    mv "$TMP/lame-$LAME_VERSION" "$src"
  fi

  lame_slice arm64 macosx "" ""
  lame_slice x86_64 macosx "--host=x86_64-apple-darwin" ""
  lame_slice arm64 iphoneos "--host=arm-apple-darwin" ""
  lame_slice arm64 iphonesimulator "--host=arm-apple-darwin" ""
  lame_slice x86_64 iphonesimulator "--host=x86_64-apple-darwin" ""

  relink_dylib "Lame" "$TMP/lame-arm64-macosx/libmp3lame/.libs/libmp3lame.a" arm64 "$SDK_MACOS" "-mmacosx-version-min=$MIN_MACOS" "$TMP/Lame-arm64-macos.dylib"
  relink_dylib "Lame" "$TMP/lame-x86_64-macosx/libmp3lame/.libs/libmp3lame.a" x86_64 "$SDK_MACOS" "-mmacosx-version-min=$MIN_MACOS" "$TMP/Lame-x86_64-macos.dylib"
  lipo -create "$TMP/Lame-arm64-macos.dylib" "$TMP/Lame-x86_64-macos.dylib" -output "$TMP/Lame-macos.dylib"
  relink_dylib "Lame" "$TMP/lame-arm64-iphoneos/libmp3lame/.libs/libmp3lame.a" arm64 "$SDK_IPHONEOS" "-miphoneos-version-min=$MIN_IOS" "$TMP/Lame-ios.dylib"
  relink_dylib "Lame" "$TMP/lame-arm64-iphonesimulator/libmp3lame/.libs/libmp3lame.a" arm64 "$SDK_IPHONESIM" "-mios-simulator-version-min=$MIN_IOS" "$TMP/Lame-arm64-ios-sim.dylib"
  relink_dylib "Lame" "$TMP/lame-x86_64-iphonesimulator/libmp3lame/.libs/libmp3lame.a" x86_64 "$SDK_IPHONESIM" "-mios-simulator-version-min=$MIN_IOS" "$TMP/Lame-x86_64-ios-sim.dylib"
  lipo -create "$TMP/Lame-arm64-ios-sim.dylib" "$TMP/Lame-x86_64-ios-sim.dylib" -output "$TMP/Lame-ios-sim.dylib"
}

make_flac() {
  say "Fetching FLAC $FLAC_VERSION"
  local src="$TMP/flac-src"
  if [ ! -d "$src" ]; then
    download "flac-$FLAC_VERSION.tar.xz" \
      "https://downloads.xiph.org/releases/flac/flac-$FLAC_VERSION.tar.xz" \
      "https://ftp.osuosl.org/pub/xiph/releases/flac/flac-$FLAC_VERSION.tar.xz"
    tar -xJf "$TMP/flac-$FLAC_VERSION.tar.xz" -C "$TMP"
    mv "$TMP/flac-$FLAC_VERSION" "$src"
  fi

  flac_slice arm64 macosx "" ""
  flac_slice x86_64 macosx "--host=x86_64-apple-darwin" ""
  flac_slice arm64 iphoneos "--host=arm-apple-darwin" ""
  flac_slice arm64 iphonesimulator "--host=arm-apple-darwin" ""
  flac_slice x86_64 iphonesimulator "--host=x86_64-apple-darwin" ""

  relink_dylib "FLAC" "$TMP/flac-arm64-macosx/src/libFLAC/.libs/libFLAC.a" arm64 "$SDK_MACOS" "-mmacosx-version-min=$MIN_MACOS" "$TMP/FLAC-arm64-macos.dylib"
  relink_dylib "FLAC" "$TMP/flac-x86_64-macosx/src/libFLAC/.libs/libFLAC.a" x86_64 "$SDK_MACOS" "-mmacosx-version-min=$MIN_MACOS" "$TMP/FLAC-x86_64-macos.dylib"
  lipo -create "$TMP/FLAC-arm64-macos.dylib" "$TMP/FLAC-x86_64-macos.dylib" -output "$TMP/FLAC-macos.dylib"
  relink_dylib "FLAC" "$TMP/flac-arm64-iphoneos/src/libFLAC/.libs/libFLAC.a" arm64 "$SDK_IPHONEOS" "-miphoneos-version-min=$MIN_IOS" "$TMP/FLAC-ios.dylib"
  relink_dylib "FLAC" "$TMP/flac-arm64-iphonesimulator/src/libFLAC/.libs/libFLAC.a" arm64 "$SDK_IPHONESIM" "-mios-simulator-version-min=$MIN_IOS" "$TMP/FLAC-arm64-ios-sim.dylib"
  relink_dylib "FLAC" "$TMP/flac-x86_64-iphonesimulator/src/libFLAC/.libs/libFLAC.a" x86_64 "$SDK_IPHONESIM" "-mios-simulator-version-min=$MIN_IOS" "$TMP/FLAC-x86_64-ios-sim.dylib"
  lipo -create "$TMP/FLAC-arm64-ios-sim.dylib" "$TMP/FLAC-x86_64-ios-sim.dylib" -output "$TMP/FLAC-ios-sim.dylib"
}

# ──────────────────────────────────────────────────────────────
# xcframework assembly
# ──────────────────────────────────────────────────────────────

# assemble_xcframework <name> <version> <macos-dylib> <ios-dylib> <ios-sim-dylib> <umbrella> <extra-headers...>
assemble_xcframework() {
  local name="$1" version="$2" maclib="$3" ioslib="$4" simlib="$5" umbrella="$6"
  shift 6
  local xcfw="$OUT/$name.xcframework"

  say "Assembling $name.xcframework"
  rm -rf "$xcfw"
  mkdir -p "$xcfw"

  local slice lib
  for slice in "macos-arm64_x86_64:$maclib:macos:arm64:x86_64:14.0" \
               "ios-arm64:$ioslib:ios:arm64::17.0" \
               "ios-arm64_x86_64-simulator:$simlib:ios:arm64:x86_64:17.0"; do
    IFS=: read -r ident lib platform arch1 arch2 minos <<< "$slice"
    local fw="$TMP/$name/$ident/$name.framework"
    if [ "$platform" = "macos" ]; then
      # macOS application embedding requires a versioned framework bundle.
      local v="$fw/Versions/A"
      mkdir -p "$v/Headers" "$v/Modules" "$v/Resources"
      cp "$lib" "$v/$name"
      write_framework_info_plist "$v/Resources" "$name" "$version" "$platform" "$minos"
      ln -s "A" "$fw/Versions/Current"
      ln -s "Versions/Current/Headers" "$fw/Headers"
      ln -s "Versions/Current/Modules" "$fw/Modules"
      ln -s "Versions/Current/Resources" "$fw/Resources"
      ln -s "Versions/Current/$name" "$fw/$name"
      local headers="$v/Headers" map="$v/Modules/module.modulemap"
    else
      mkdir -p "$fw/Headers" "$fw/Modules"
      cp "$lib" "$fw/$name"
      write_framework_info_plist "$fw" "$name" "$version" "$platform" "$minos"
      local headers="$fw/Headers" map="$fw/Modules/module.modulemap"
    fi
    cp "$umbrella" "$headers/"
    for h in "$@"; do
      cp "$h" "$headers/"
    done
    { echo "framework module $name {"; echo "    umbrella header \"$(basename "$umbrella")\""; echo "    export *"; echo "    module * { export * }"; echo "}"; } > "$map"
    if [ "$name" = "FLAC" ]; then
      # metadata.h is not included by stream_encoder.h, so it must be listed in
      # the module map explicitly or the metadata API (Vorbis comments) is
      # invisible to Swift. Patch the module map after assembly.
      python3 - "$map" <<'PY'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
text = text.replace('    umbrella header "stream_encoder.h"\n', '    umbrella header "stream_encoder.h"\n    header "metadata.h"\n', 1)
with open(path, "w") as f:
    f.write(text)
PY
    fi
  done
  cp -R "$TMP/$name/." "$xcfw/"

  cat > "$xcfw/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
PLIST
  local ident
  for ident in "macos-arm64_x86_64:macos:arm64:x86_64:14.0:" \
               "ios-arm64:ios:arm64::17.0:" \
               "ios-arm64_x86_64-simulator:ios:arm64:x86_64:17.0:simulator"; do
    IFS=: read -r ident platform arch1 arch2 minos variant <<< "$ident"
    cat >> "$xcfw/Info.plist" <<PLIST
		<dict>
			<key>BinaryPath</key>
			<string>$name.framework/$name</string>
			<key>LibraryIdentifier</key>
			<string>$ident</string>
			<key>LibraryPath</key>
			<string>$name.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>$arch1</string>
PLIST
    if [ -n "$arch2" ]; then
      cat >> "$xcfw/Info.plist" <<PLIST
				<string>$arch2</string>
PLIST
    fi
    cat >> "$xcfw/Info.plist" <<PLIST
			</array>
			<key>SupportedPlatform</key>
			<string>$platform</string>
PLIST
    if [ -n "$variant" ]; then
      cat >> "$xcfw/Info.plist" <<PLIST
			<key>SupportedPlatformVariant</key>
			<string>$variant</string>
PLIST
    fi
    cat >> "$xcfw/Info.plist" <<PLIST
		</dict>
PLIST
  done
  cat >> "$xcfw/Info.plist" <<'PLIST'
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
PLIST
}

# write_framework_info_plist <framework-dir> <name> <version> <platform> <minos>
write_framework_info_plist() {
  local fw="$1" name="$2" version="$3" platform="$4" minos="$5"
  cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$name</string>
	<key>CFBundleIdentifier</key>
	<string>guru.parso.encoders.$name</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$name</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>1.0</string>
	<key>MinimumOSVersion</key>
	<string>$minos</string>
</dict>
</plist>
PLIST
}

main() {
  say "Voxglass encoders — LAME $LAME_VERSION + FLAC $FLAC_VERSION"
  say "Slices: macos-arm64_x86_64, ios-arm64, ios-arm64_x86_64-simulator"
  mkdir -p "$OUT"

  make_lame
  make_flac

  assemble_xcframework "Lame" "$LAME_VERSION" \
    "$TMP/Lame-macos.dylib" "$TMP/Lame-ios.dylib" "$TMP/Lame-ios-sim.dylib" \
    "$TMP/lame-src/include/lame.h"

  assemble_xcframework "FLAC" "$FLAC_VERSION" \
    "$TMP/FLAC-macos.dylib" "$TMP/FLAC-ios.dylib" "$TMP/FLAC-ios-sim.dylib" \
    "$TMP/flac-src/include/FLAC/stream_encoder.h" \
    "$TMP/flac-src/include/FLAC/all.h" \
    "$TMP/flac-src/include/FLAC/assert.h" \
    "$TMP/flac-src/include/FLAC/callback.h" \
    "$TMP/flac-src/include/FLAC/export.h" \
    "$TMP/flac-src/include/FLAC/format.h" \
    "$TMP/flac-src/include/FLAC/ordinals.h" \
    "$TMP/flac-src/include/FLAC/metadata.h" \
    "$TMP/flac-src/include/FLAC/stream_decoder.h"

  say "Done. Vendored xcframeworks:"
  du -sh "$OUT"/*.xcframework
}

main "$@"
