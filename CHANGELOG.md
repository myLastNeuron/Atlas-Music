# Changelog

All notable changes to Atlas Music are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.3.0] - 2026-11-03

### Added
- **Video, inside the player**: every song has a **Song / Video** toggle. Video
  streams the track's real video over HLS (adaptive quality, master playlist),
  with fullscreen, and the choice is remembered per track — pick Video once and
  the next song stays in Video. The mini player's square shows the live video and
  the cover flight carries that same running video into the player and back, so
  closing the player keeps the video playing with sound. The timeline survives the
  switch in both directions (Video opens at the song's position; Song continues
  from it plus the time watched).
- **Real frosted glass, without the stutter**: the nav bar, mini player and
  sheets blur what is behind them. Panels inside the page keep the flat tint,
  because the page colour is all that is behind them — the filter there cost a
  repaint every frame and showed nothing.

### Fixed
- **Creating or renaming anything no longer crashes the app**: the text
  controllers were disposed the moment the dialog's future returned, while the
  field was still on screen for the exit animation — the framework's
  `_dependents.isEmpty` assertion killed the whole UI. They now live exactly as
  long as the dialog does (playlists, renames, imports, Spotify keys, add song).
- **Video mode with no video still has working controls**: while the video
  resolves (or when it fails) the play/pause button and the slider drive the
  song again, instead of sitting dead while the music plays on.
- **Leaving Video before the video appears no longer leaves the song silent**:
  the audio is now paused only when the first frame is ready, and a song paused
  for a video that never started is given back on the way to Song.
- **The background video loader can't hijack a song you took back**: opening
  the player cancels the mini player's in-flight video instead of pausing the
  song seconds later and taking over the bar.
- **Repeat-one works in Video mode**: the video repeats the song instead of
  advancing the queue.
- **Tapping the pinned *Play next* row plays it once**: it no longer replays
  itself when it ends.
- **Search in non-Latin languages returns the whole list**: the dedupe key kept
  only ASCII, so every Cyrillic/Japanese/Devanagari/Arabic title collapsed into
  one result.
- **Profile's playlist count ignores the system downloads playlist** (Library
  already hid it), so a first download no longer reads as "1 playlist".
- **Tapping a song the content filter excludes plays the right next track**: it
  was inserted at its raw queue index, which counts the dropped songs and left
  the playhead past the rows before it.
- **Listening stats credit the song you actually heard**: a skip used to be
  recorded against the incoming track, so recommendations avoided what you play.
- **One player at a time**: the mini bar no longer opens a second player over an
  artist page (two videos, doubled sound); it returns to the open one.
- **The video is the song or nothing**: a video upload that is another song, a
  slowed/lo-fi/synthwave/remix variant, a cover, or another creator's "version"
  is rejected instead of being shown for the track ("Kesariya (Synthwave)" and
  "Often (Ethan Swope Version)" were both served as official videos). A found
  video must also name the song's artist or come from a label channel.
- **"1 song" instead of "1 songs"** in the playlist header, the Library
  playlist rows and the add-to-playlist sheet.
- **The cover no longer ghosts on the way to the full player**: the flight used
  to stretch the 42 px mini thumbnail over the whole morph, so the artwork
  arrived as a blurred, washed-out copy and only sharpened on landing. It now
  carries the player's own cover bitmap, pre-warmed before the route opens, with
  no fade over a placeholder — crisp and fully opaque from the first frame, both
  directions.
- **Leaving Video for Song gives the album art back**: switching to Song
  disposed the video without telling the handoff, so the mini player kept
  painting the dead video's last frame instead of the song's artwork.
- **The white/grey video box is gone**: closing and reopening the player in
  Video mode used to throw (a notifier written while the widget tree was locked,
  and a cover flight that recreated the video widget and then disposed the
  controller the mini player was still drawing). The video now survives the
  trip in both directions — same controller, no restart, no disposed frames.
- **The mini player is the video in Video mode**: its square shows the live
  video, and the cover flight now carries that running video up into the player
  and back down on close — the same controller, so nothing restarts, pauses or
  doubles up during the transition.
- **Switching modes never changes the play state**: a paused song opens its
  video paused (first frame on screen), and a playing one keeps playing.
- **No more artwork ghosting on the open transition**: the mini player's thumb
  is hidden while the cover flies (it is still mounted, so it lands decoded),
  instead of showing as a second image behind the flying cover.
- **Paused stays paused across the mini player**: opening or closing the player
  no longer starts playback by itself — a paused video comes back paused, and a
  paused video hands back to a paused song.
- **The video keeps playing when you close the player**: going back to the
  mini player no longer hands playback back to the audio stream. The video
  keeps running (sound included), the mini player's play/pause and progress bar
  drive it, and reopening the player picks the same video up where it is.
- **The Song/Video choice is remembered**: pick Video once and it stays for the
  next track, for the trip through the mini player, and after a restart. The
  next song keeps playing in Video instead of flipping back to Song, and when a
  video ends the queue advances into the next song's video.
- **Song → Video keeps the timeline too**: the video now opens at the song's
  position instead of restarting at 0:00, so the switch no longer looks like it
  lost the position and no longer pushes the song to its end on the way back.
- **Video → Song keeps the timeline**: the song now continues from its position
  plus the time watched in the video, including songs whose video is a separate
  music video, instead of dropping that watch time.
- **Playlist delete no longer lies**: a playlist that still holds downloads is
  protected, and the screen now says so instead of closing as if it were gone.
- **Changing a playlist cover shows the new image** immediately (the decoded
  image cache is dropped), and *Remove cover* actually clears it — `copyWith`
  could never clear a nullable field.
- **Wrong lyrics**: the cache key now uses the whole title, so two songs by the
  same artist no longer share one lyrics entry.
- **UP NEXT**: tapping the pending *Play next* row plays it instead of showing
  "Could not play that song".
- **Recently Played** no longer lags one song behind, and tapping a repeated
  row starts at the row you tapped.
- **Search**: clearing the field cancels the in-flight search; playlist
  download progress can no longer exceed 100%.
- **Player slider**: the elapsed clock follows the thumb while dragging, and a
  track change clears a half-finished drag.
- **Auto finds**: deleting a find removes the entry you picked (not a stale
  position), and *Today*/*Yesterday* grouping survives DST.
- **Update check** distinguishes "could not reach GitHub" from "you're on the
  latest version"; a stalled APK download times out and leaves no partial file.
- **Find song**: dismissing the sheet cancels the capture, so the next attempt
  records immediately; Auto-listen can no longer start twice.
- **Auto-listen**: swiping the app away stops the microphone service instead of
  leaving a phantom "listening" notification.
- **Full player**: the cover only flies from the mini bar that opened it (no
  more big-cover-into-thumb animation when opening an artist page), and the
  player no longer morphs out of a stale bar rect from an earlier screen.
- **YTMusic**: continuation pages are parsed (search pages past the first no
  longer come back empty) and album/artist rows get their real length.
- **Playback**: a superseded load can no longer evict a healthy cached file; a
  false "completed" event reloads instead of parking the player; an offline
  skip-search that a newer tap superseded no longer overrides it; resuming after
  connectivity returns plays the paused song, not whatever now sits at that
  queue index.
- **Auto-listen / playback service**: the wake + Wi-Fi locks are released on
  stop, and parked launch intents survive an activity recreate.

## [2.1.0] - 2026-10-22

### Added
- **Up next in the full player**: the upcoming song is now shown while the
  current track plays, so you can see what is coming without opening the queue.
- **Check for updates** (Profile): reads the newest release from the project's
  GitHub Releases, and when a newer version exists shows what changed, downloads
  the APK, and hands it to the Android installer. Free and keyless — no server,
  no API key. Includes the permanent release-signing setup (keystore +
  `release.yml` workflow) so updates install over previous versions.
- The Profile version label now comes from the platform (`package_info_plus`)
  instead of a hand-typed string, so it cannot drift from `pubspec.yaml`.

### Changed
- **The full player was remapped for a more premium feel**: cleaner layout,
  calmer spacing and a firmer visual hierarchy, with the controls and artwork
  reading as one surface instead of separate stacked blocks.
- **Smoother animations** across the full player and the app's navigation:
  the mini-player cover flies into the full player as a shared-element (Hero)
  morph, the page eases in behind it with a gentle rise (480 ms open / 420 ms
  close, emphasized curve), and the entrance/glass surfaces no longer stutter.
- **Full player motion** now reads as a transition, not a snap.
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
- The full player's artwork no longer pops into place on open: the landing
  spot stays empty while the mini-player cover morphs into it, so the cover
  arrives with the Hero instead of appearing instantly under the fading page.
- The mini player and the floating tab bar now follow the Transparency setting
  like every other glass surface (they were pinned to a solid tint).
- **UK playback stalled for 30s then failed with `manifest failed ...
  TimeoutException`**: the manifest resolve downloaded YouTube's watch page
  (~1 MB, UK consent path) before asking the player API, all under one 30s
  timeout. The watch page is no longer fetched, each YouTube client now gets
  a 10s budget inside a 25s total, and the failure detail names the client
  chain and elapsed time.
- **UK playback still failed after that (`No song playing` in ~1.5s)**: on UK
  IPs YouTube answers anonymous VISIONOS/ANDROID_VR player calls with
  `LOGIN_REQUIRED` ("Sign in to confirm you're not a bot"), and IOS returns
  only ciphered URLs. The provider now fetches a `visitorData` token once per
  run and injects it into the client payloads — measured: VISIONOS goes from
  `LOGIN_REQUIRED` to `OK` with direct audio URLs. IOS was dropped (no usable
  URLs). A first-load failure now also shows its real reason instead of only
  "No song playing": the player banner and the toast no longer depend on a
  song still being loaded.
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
- Codebase cleanup: removed dead code and unused helpers left behind by the
  player remap, and brought the touched screens back to a single, smaller shape.

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
