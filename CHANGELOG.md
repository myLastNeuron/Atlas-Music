# Changelog

All notable changes to Atlas Music are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Full player motion**: the mini-player cover flies into the full player as
  a shared-element (Hero) morph, while the page eases in behind it with a
  gentle rise (480 ms open / 420 ms close, emphasized curve). The earlier
  instant/short version read as a snap rather than a transition.
- **Ambient background**: the drifting washes no longer rebuild/relayout the
  blob stack every frame — each blob is prebuilt with a RepaintBoundary and
  only its transform updates, removing a constant per-frame cost on every
  screen.
- **Search is no longer song-catalogue-only**: it merges YouTube Music's
  "Songs" results with plain YouTube video results, so slowed/reverb, remix,
  cover, lyric and sped-up uploads are visible. Non-music (trailers, movies,
  TV, podcasts, interviews, long-form) is filtered out by the new
  `SongFilter.applySearch`.
- **RECOMMENDED FOR YOU** now fills to exactly 15 songs from the user's taste
  pool: a strict pass, then a relaxed pass (personal-signal gate and per-artist
  cap loosened) when the narrow pool falls short. Capped at 15.
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
- **First-run flow flashed the Home screen**: after entering a name,
  `WelcomeScreen` set `_name` while the preferences step was still unflagged,
  so `_stage()` briefly built the Home shell behind the avatar dialog before
  swapping to preferences. `_showHome` is now the single authority for the
  stage (the redundant `_showPreferences` flag is gone).
- **Entrance / onboarding jank**: `FadeSlideIn` (used by `Stagger`) and
  `fadeRiseTransition` animated `Opacity` over subtrees with no
  `RepaintBoundary`, so every frame of the entrance repainted the entire
  child. That is very expensive on the heavy first-run screens. The child's
  raster is now retained, so the fade/rise composites a cached layer instead.
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
