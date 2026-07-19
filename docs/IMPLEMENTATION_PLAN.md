# Voxglass Implementation Plan

Voxglass is a GPLv3, iOS-native, privacy-first public-domain audiobook app. It has no accounts, ads, analytics, tracking SDKs, or runtime Wikipedia fetches. Network access is reserved for Internet Archive and LibriVox search, metadata, streaming, and downloads.

## Phase 0: Foundation

- Create an iOS 17+ SwiftUI app target and unit test target.
- License the repository under GPLv3.
- Add tabs for Listen, Library, Discover, Search, and Settings.
- Establish a warm paper, ink, and glass-inspired native design system.
- Respect Reduce Transparency and Reduce Motion.
- Add SQLite-backed storage with migrations.
- Add core models: Book, Chapter, Source, PlaybackPosition, Bookmark, Playlist, and DownloadRecord.
- Keep a CI-friendly XcodeGen project manifest.

## Phase 1: Local Playback

- Define an AudioEngine protocol.
- Implement AVPlayerAudioEngine with AVFoundation.
- Add PlaybackCoordinator as the playback orchestration layer.
- Add PositionStore and persist playback progress.
- Save progress every 5 seconds during playback.
- Save immediately on pause, seek, skip, chapter change, app background, interruption, and route change.
- Import local MP3, M4A, M4B, and common audio files/folders.
- Add mini-player and full Now Playing screen.
- Configure background audio and Now Playing metadata.
- Add MediaPlayer remote command handling.
- Add unit tests for model behavior and position persistence.

## Phase 2: Internet Archive and LibriVox

- Add deterministic recorded fixtures for Internet Archive Advanced Search and Metadata API tests.
- Search LibriVox public-domain audiobooks through Internet Archive.
- Fetch item metadata through the Internet Archive Metadata API.
- Deduplicate IA audio derivatives while preferring playable originals and high-quality public derivatives.
- Apply natural chapter ordering to IA file lists.
- Add user-added Internet Archive item, list, and collection URLs.
- Keep all source lists, favorites, listening history, bookmarks, and recommendations on device.

## Phase 3: Offline Library

- Add background downloads for selected books and chapters.
- Track download state in DownloadRecord.
- Add cache controls and per-book storage management.
- Preserve playback behavior when moving between streamed and downloaded files.

## Phase 4: Public-Domain Experience

- Add bundled author metadata and author cards.
- Add explicit user-tapped external author links where available.
- Add recommendations generated from on-device library and bundled metadata.
- Add recommendations generated from on-device library and bundled metadata.

