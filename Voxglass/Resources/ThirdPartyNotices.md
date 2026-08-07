# Third-Party Notices

Voxglass Studio is licensed under the GPLv3 with the App Store additional
permission in `LICENSE-APPSTORE-EXCEPTION.md`. This file lists the third-party
software linked into or shipped with the Studio app and the obligations that
come with each component (§16.3, §21.4).

## Audio codecs

Voxglass encodes MP3 and FLAC, and decodes FLAC, with two libraries built from
unmodified upstream sources by the recipe in `Tools/encoders/build-encoders.sh`.
The resulting xcframeworks are committed at `Tools/encoders/Vendored/` and
contain macOS, iOS device, and iOS simulator slices.

### LAME MP3 encoder — LGPL-2.1

- Component: `libmp3lame` 3.100
- Copyright: Copyright © 1999-2017 The LAME Project; Copyright © 1999, Mark Taylor
- License: GNU Lesser General Public License, version 2.1 (LGPL-2.1), or (at
  your option) any later version.
- Used for: MP3 encoding (128/192 kbps CBR) — the only MP3 path in the product.
- Recipe: `Tools/encoders/build-encoders.sh` (downloads and builds 3.100 from
  the unmodified upstream tarball).
- Source: <https://sourceforge.net/projects/lame/files/lame/3.100/>
- License text: <https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>

The LAME xcframework is linked through the shared `VoxglassEncoders` target.
For distributions in which the library is statically incorporated, LGPL-2.1
§6 requires the relinkable object files and link instructions. Voxglass offers
the following to anyone who received this software:

> **Written offer for the Corresponding Source of LAME.** For a period of three
> years after Voxglass Studio is distributed, Voxglass offers to give any third
> party a machine-readable copy of the Corresponding Source for LAME — the
> unmodified LAME 3.100 sources plus the build script
> `Tools/encoders/build-encoders.sh` — for a charge no more than the cost of
> physically performing source distribution, and to give the same party the
> object files and link instructions needed to relink a modified LAME against
> this program. Request it by opening an issue at
> <https://github.com/johnarleyburns/parso-voxglass> or by contacting the
> maintainer at the address on the repository.

### libFLAC — BSD-3-Clause

- Component: `libFLAC` 1.4.3
- Copyright: Copyright © 2000-2009 Josh Coalson; Copyright © 2011-2022 Xiph.Org
  Foundation
- License: BSD 3-Clause License
- Used for: FLAC encoding (lossless masters, Internet Archive lane).
- Recipe: `Tools/encoders/build-encoders.sh`.
- Source: <https://github.com/xiph/flac/releases/tag/1.4.3>
- License text: <https://opensource.org/license/bsd-3-clause/>

BSD-3-Clause attribution text:

```
Copyright (c) 2000-2009 Josh Coalson
Copyright (c) 2011-2022 Xiph.Org Foundation
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.
* Neither the name of the Xiph.org Foundation nor the names of its
  contributors may be used to endorse or promote products derived from this
  software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

## What is deliberately NOT shipped

- **ffmpeg.** A GPL-configured ffmpeg cannot ship through the Mac App Store
  (the App Store additional permission cannot bind ffmpeg's authors, §16.3
  correction C-3), so no ffmpeg binary is bundled.
- **libvorbis / libogg.** FLAC is built without Ogg container support.
- No speech synthesis, TTS, or machine-learning inference library is linked,
  built, downloaded, or invoked (see the product's "no AI in the pipeline"
  stance, §1.3).

## Verification

- `Tools/encoders/build-encoders.sh` downloads the exact LAME 3.100 and
  libFLAC 1.4.3 upstream tarballs, configures static library builds with
  `--disable-shared`, `--disable-frontend`/`--disable-programs`, and creates
  the three Apple platform slices without Homebrew or a system codec.
- The xcframeworks committed under `Tools/encoders/Vendored/` are the output of
  that recipe; their Info.plist records `macos-arm64_x86_64`, `ios-arm64`, and
  `ios-arm64_x86_64-simulator`, with importable Swift modules named `Lame` and
  `FLAC`.
