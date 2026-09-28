# Changelog

All notable changes to Atlas Music are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Release signing**: `android/app/build.gradle.kts` now reads
  `android/key.properties` and uses that keystore when present, falling back to
  the debug keystore otherwise. See the README's *Signing a release* section.
- `flutter analyze` is now clean (0 issues). The vendored `plugins/audio_service`
  copy is excluded from analysis, and the hand-written code was brought to zero
  lints: `const` constructors, curly braces in flow control, the deprecated
  `cacheExtent` → `scrollCacheExtent` migration, and 14 `BuildContext`-across-async-gap
  sites that now capture `Navigator`/`ScaffoldMessenger` before awaiting.
- `pubspec.lock` is committed (this is an app, not a library) so every contributor
  and release resolves identical dependency versions.

### Added
- `CHANGELOG.md`.
- GitHub Actions workflow running `flutter analyze` and `flutter test`.
- README badges, release-signing guide, and per-ABI build instructions.

### Fixed
- `test/download_policy_test.dart` mock server never truncated the response, so the
  "truncated connection" assertion could not fail; it now returns 416 after the
  first short read.
- `test/resolver_strategy_test.dart` asserted the string `bypassed` while the
  resolver emits `bypassing`.

### Removed
- Hardcoded InnerTube API key, all debug logging, dead source files, unused
  dependencies, and build artifacts. The repository is 1.1 MB.

## [1.0.1+2] - 2026-09-29

### Added
- Song search via YouTube Music, with a plain YouTube fallback for tracks
  that only exist as videos.
- Full-screen player: artwork, seek, shuffle, repeat, like, download.
- Background playback with notification and lock-screen controls.
- Offline downloads backed by a validated, size-capped cache.
- Synced lyrics from LRCLIB (no API key required).
- Playlists: create, import from YouTube, cover art, download whole playlist.
- Spotify playlist import using your own Client ID and secret.
- On-device recommendations (Quick Picks) with language and duration filters.
- Onboarding taste preferences and a profile screen.

### Notes
- **Android only.** There is no `ios/` folder and iOS builds are not supported.
- Release builds fall back to the debug keystore unless
  `android/key.properties` is present. See the README's *Releasing* section.

[Unreleased]: https://github.com/myLastNeuron/Atlas-Music/compare/v1.0.1...HEAD
[1.0.1+2]: https://github.com/myLastNeuron/Atlas-Music/releases/tag/v1.0.1
