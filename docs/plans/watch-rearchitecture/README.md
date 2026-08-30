# Voxglass Apple Watch Rearchitecture

Status: **proposal — owner review required before implementation**

- [Implementation plan](IMPLEMENTATION_PLAN.md)
- [Acceptance matrix](ACCEPTANCE_MATRIX.md)
- [Review mockups](mockups/index.html)

This proposal makes the iPhone the sole library and CloudKit authority. The watch is a
projection-and-playback client: connected mode exposes the iPhone's My Books library;
disconnected mode exposes only complete, validated watch downloads.

No production source has been changed by this proposal.
