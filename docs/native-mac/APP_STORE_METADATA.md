# Voxglass — App Store Connect metadata (current)

This is the current metadata source for the shared Voxglass app record. It supersedes the older
Studio and Narration Pro drafts in the historical MVP folders. The shipped product is Voxglass for
iPhone, iPad, Apple Watch, CarPlay, and native macOS; it is not Voxglass Studio.

## Listing

- **Name:** Voxglass
- **Subtitle:** Private public-domain audiobooks
- **Primary category:** Books
- **Price:** Free
- **Bundle ID:** `guru.parso.voxglass`
- **Platforms:** iOS/iPadOS, watchOS companion, and macOS native app

## Description

Voxglass is a private audiobook player for the public-domain LibriVox catalog. Discover books,
search by title, author, or narrator, stream or download for offline listening, and resume at the
exact chapter and position where you stopped.

Playback includes speed control, sleep timers, bookmarks, playlists, favorites, narrator details,
lock-screen controls, and CarPlay. Your library, position, bookmarks, and favorites stay on your
devices and can sync through your own private iCloud account. Voxglass has no account requirement,
advertising, analytics, or cross-app tracking.

Voxglass also lets you create narration projects on iPhone, iPad, or Mac. Record paragraph by
paragraph, review takes, and export the files yourself for the destination you choose. The app does
not determine copyright status or upload your work to retailers.

Every Voxglass feature is available without a paid unlock. Settings includes an optional, one-time
“Contribute to Development” tip; it does not unlock features and is not required to listen,
download, sync, narrate, or export.

## Keywords

`audiobook, LibriVox, public domain, narrator, narration, offline player, CarPlay, iCloud, books`

## Privacy and review notes

- **Privacy policy URL:** `https://parso.guru/voxglass-privacy`
- **App privacy:** answer App Store Connect’s questions from the current policy and actual release
  behavior. Do not reuse the old “Studio Pro” or unconditional “Data Not Collected” draft: the app
  can sync library and narration data to the user’s private iCloud database, and catalog providers
  receive ordinary network request data when the user searches or downloads.
- No Parso account, advertising SDK, analytics SDK, or cross-app tracking is used.
- The microphone is used only when the user starts narration; `NSMicrophoneUsageDescription` is
  included in the iOS and macOS bundles.
- The app uses Apple system/CloudKit encryption and declares
  `ITSAppUsesNonExemptEncryption = false`; complete any App Store Connect export-compliance
  prompt for the uploaded build.
- Reviewers can browse the catalog without an account. To review narration, start New Narration and
  use the bundled or local manuscript flow; recording is optional and local until the user chooses
  to sync or export.

## Required submission checks

1. Add iOS/iPadOS and macOS platform metadata to the `Voxglass` App Store Connect record.
2. Set the privacy policy URL above and verify the App Privacy answers against the current policy.
3. Provide current screenshots of Listen, My Books, Discover, Now Playing, New Narration, and the
   native Mac library/narration workspace. Do not submit screenshots from the retired Studio mockups.
4. After processing, answer export compliance, select the processed build for the version, and test
   the release on an iPhone, iPad, CarPlay head unit, Apple Watch, and Mac where applicable.

The build-side requirements are automated by `scripts/audit_app_store_release.sh` and the iOS
workflow. The privacy policy and App Store Connect metadata remain account-side settings and must be
verified in App Store Connect before submission.
