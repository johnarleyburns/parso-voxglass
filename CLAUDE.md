# CLAUDE.md

## Swift 6 hard rule

Voxglass is fully on Swift 6 language mode with complete strict-concurrency checking and is kept as warning-free as the selected toolchain permits. Do not introduce or permit any deviation, mixed Swift modes, warning suppression, or unexplained concurrency escape hatch. A commit runs the wiring guards, logic tests, and simulator tests; a push runs no tests.

Read [`docs/iphone-watch-only-revised-mvp/AGENT_BRIEF.md`](docs/iphone-watch-only-revised-mvp/AGENT_BRIEF.md) for the full operating brief.

## Git hook timeouts

- Set the command timeout to at least **25 minutes (1500 seconds)** for `git commit`; the pre-commit hook runs the wiring guards, logic tests, and simulator UI smoke tests.
- Set the command timeout to about **2 minutes (120 seconds)** for `git push`; the pre-push hook runs no tests or guards (CI verifies pushed commits).
