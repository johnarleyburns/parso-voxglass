#!/bin/bash
# build-encoders.sh — RETIRED (audio-engine unification, Phase 4).
#
# Voxglass no longer bundles binary encoder xcframeworks. MP3 encode (Glint)
# and FLAC decode/encode (libFLAC 1.4.3) now come from vendored *source* in
# parso-audio-engine (ParsoAudioCore), consumed through the VoxglassEncoders
# target. AAC/ALAC/PCM still come from AVFoundation.
#
# The former recipe built Lame.xcframework + FLAC.xcframework from libmp3lame
# 3.100 and libFLAC 1.4.3; it and the committed artifacts were removed once
# ParsoAudioCore's codecs passed the CBR-conformance and lossless round-trip
# acceptance tests (Voxglass/Core/Encoders + VoxglassTests/Production/Packaging).
#
# See parso-audio-engine/docs/UNIFICATION_PLAN.md §4 Phase 4.
echo "build-encoders.sh is retired — encoders come from parso-audio-engine (see header)." >&2
exit 0
