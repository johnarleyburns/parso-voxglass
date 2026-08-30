# CLAUDE.md

## Swift 6 hard rule

Voxglass is fully on Swift 6 language mode with complete strict-concurrency checking and is kept as warning-free as the selected toolchain permits. Do not introduce or permit any deviation, mixed Swift modes, warning suppression, or unexplained concurrency escape hatch. A commit runs the wiring guards, logic tests, and simulator tests; a push runs no tests.

Read [`docs/iphone-watch-only-revised-mvp/AGENT_BRIEF.md`](docs/iphone-watch-only-revised-mvp/AGENT_BRIEF.md) for the full operating brief.

## Git hook timeouts

- Set the command timeout to at least **25 minutes (1500 seconds)** for `git commit`; the pre-commit hook runs the wiring guards, logic tests, and simulator UI smoke tests.
- Set the command timeout to about **2 minutes (120 seconds)** for `git push`; the pre-push hook runs no tests or guards (CI verifies pushed commits).

## Xcode simulator build commands (iPhone + Watch)

The `Voxglass` iPhone scheme embeds the `VoxglassWatch` app. Never pass a global
`-sdk iphonesimulator` override when building this scheme: Xcode applies it to
the Watch dependency too, which produces misleading `unable to resolve module
dependency: 'WatchKit'` and Watch `AppIcon` errors even though both are valid.

Also avoid the generic destination `generic/platform=iOS Simulator` for this
combined scheme. Its asset-thinning step has repeatedly evaluated the Watch
icon catalog as an iPhone asset catalog and reported that `AppIcon` has no
applicable content.

Use a concrete installed iPhone simulator and let Xcode choose the proper SDK
for each target:

```sh
xcodebuild \
  -scheme Voxglass \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -derivedDataPath /tmp/voxglass-derived \
  build CODE_SIGNING_ALLOWED=NO
```

To verify the Watch app independently, use a concrete Watch simulator and the
Watch scheme, again without `-sdk`:

```sh
xcodebuild \
  -scheme VoxglassWatch \
  -destination 'platform=watchOS Simulator,name=Voxglass-Agent-Watch,OS=latest' \
  -derivedDataPath /tmp/voxglass-watch-derived \
  build CODE_SIGNING_ALLOWED=NO
```

Simulator names vary by machine. If a named destination is unavailable, run
`xcodebuild -showdestinations -scheme Voxglass` or
`xcodebuild -showdestinations -scheme VoxglassWatch` and use one of the exact
listed destinations. Do not work around destination failures by adding `-sdk`.

For core-only verification, prefer `swift test`; it does not build the embedded
Watch app.
