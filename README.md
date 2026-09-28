<div align="center">

# 🎵 Atlas Music

### *Your music. No ads. No limits.*

**An open-source, ad-free music player built with Flutter — streaming from YouTube, with full offline support, background playback and synced lyrics.**

[![Flutter](https://img.shields.io/badge/Flutter-3.0%2B-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.0%2B-0175C2?logo=dart&logoColor=white)](https://dart.dev)
![Platform](https://img.shields.io/badge/platform-Android%20only-3DDC84?logo=android&logoColor=white)
![Version](https://img.shields.io/badge/version-1.0.1%2B2-blue)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE.md)
![Tests](https://img.shields.io/badge/tests-101%20passing-brightgreen)

[**🚀 Features**](#-features) · [**📱 Screens**](#-app-screens) · [**⚙️ How It Works**](#-how-playback-works) · [**🛠️ Getting Started**](#%EF%B8%8F-getting-started) · [**🧪 Tests**](#-tests)

> [!IMPORTANT]
> **📱 Android only for now.** iOS builds **cannot** be made from this repo — the iOS project isn't scaffolded and won't be ready for a long while. Please be patient; see [iOS is not ready](#-prerequisites).

</div>

---

<details>
<summary><b>Contents</b></summary>

1. [✨ Features](#-features)
2. [📱 App Screens](#-app-screens)
3. [⚙️ How Playback Works](#-how-playback-works)
4. [🎯 Content Rules](#-content-rules)
5. [🧱 Tech Stack](#-tech-stack)
6. [🗂️ Project Structure](#%EF%B8%8F-project-structure)
7. [🛠️ Getting Started](#%EF%B8%8F-getting-started)
8. [🧪 Tests](#-tests)
9. [🗺️ Roadmap](#-roadmap)
10. [🤝 Contributing](#-contributing)
11. [⚠️ Disclaimer](#%EF%B8%8F-disclaimer)

</details>

---

## ✨ Features

### 🎵 Playback

| | Feature | Details |
|:--:|---|---|
| 📺 | **Ad-free streaming** | Audio is pulled straight from the source CDN — no ads ever play. |
| 🔀 | **Provider-agnostic architecture** | Everything behind one `MediaResolver` contract (`resolve → validate → download`), so the player never knows which backend produced a stream — and any backend can be added without touching the player. |
| 🏆 | **Reliability-first stream ranking** | Candidates are ranked MP4/AAC → WebM/Opus, then bitrate, then known content length, then provider reliability — and every URL is validated (reachable, non-zero, unexpired, compatible container) before it ever reaches ExoPlayer. |
| 📴 | **Background playback** | A `mediaPlayback` foreground service, partial wake lock and high-performance Wi-Fi lock keep music alive with the screen off. Audio focus **ducks, never pauses**, on transient loss. |
| ⏭️ | **Auto-advance** | A track ending is a *transition*, not a stop — the notification and service never tear down between songs. |
| 📡 | **Auto-play / radio** | When a queue ends: related videos → artist search → title search → **your own liked/recent** (offline-safe). Playback never dead-ends. |
| 🎯 | **Quick Picks** | An on-device recommender using plays, skip timestamps, recency, top artists/genres, likes, session context and the current queue — with time-decayed skip penalties, per-artist diversity caps, and a plain-English **"because you played…"** reason on each pick. |
| 🔁 | **Shuffle & repeat** | Shuffle, repeat-all and repeat-one — honored by next/previous prediction *and* the notification controls. |
| ⚡ | **Preloading & caching** | Streaming is disabled — every track plays from a **verified local file**. Up to 3 upcoming songs are pre-downloaded while you listen, so auto-advance starts instantly from disk. |
| 🩹 | **Offline self-heal** | Paused for connectivity in the background? It re-checks on a bounded backoff (5s → 2min) and resumes on its own. |
| 🔇 | **Never goes silent** | If nothing ahead can be resolved, a cached track is replayed instead of burning the queue. |
| 🛡️ | **Multi-provider failover** | Finite chain (P1 → P2 → FAIL) with per-provider cooldown: 3 consecutive *provider* failures → 2min doubling, 15min cap. One bad song can never strand playback. |
| 💾 | **Download for offline** | Length-scaled size floor (~24 kbps, min 16 KB) rejects truncated downloads, with a fresh-chain retry on rejection. Cache is capped at **1 GB** (oldest-first eviction, never evicting the playing queue) with a **7-day TTL**. |

### 📱 Notification & Lock Screen

- **Rich media controls** — prev / play-pause / next, ±10s fast-forward &amp; rewind, seek, and full-size cover art.
- **Wired to the real queue** — `AtlasAudioHandler` drives the actual app queue, not a single loaded audio source, so skip buttons walk the queue properly.
- **Sharp artwork** — resolver chain: upscaled Google thumbnail → song URL → ytimg `maxresdefault`/`hq720` → `sddefault` → `hqdefault`, validated with a SOF-marker JPEG width reader that rejects the 120×90 placeholder, then cached locally.
- **Clean status icon** — monochrome vector, no white square.
- **Never drops** — persistent across pauses and track transitions; Android 13+ system actions (`skipToPrevious`, `skipToNext`, `seek`) are advertised so the media carousel works.

### 🔍 Search & Discovery

| Feature | Details |
|---|---|
| 🎤 **Song-first search** | Queries YouTube Music's InnerTube endpoint with the "Songs" filter — real songs, not lyric re-uploads, covers or music videos. |
| 📈 **Related & Autoplay** | Radio/autoplay continuations are routed through the same song-only path. |
| 🕘 **Recent searches** | History with one-tap re-query. |
| ➕ **Quick actions** | Play, or add to playlist straight from results. |
| 🎛️ **Taste onboarding** | Pick from **23 languages**, **25 genres** and per-language curated artist lists to tune what you see. |

### 📚 Library

- **🎧 Playlists** — create, rename, reorder, delete. Any song can go in any playlist.
- **❤️ Liked Songs** — one tap from the player, live-updating everywhere.
- **🕘 Recently Played** — listening history with a recency-weighted rail on Home.
- **📥 Downloaded Music** — a system playlist of offline tracks, with per-song removal and "clear downloads".
- **🎛️ Per-playlist tools** — in-dialog "Add Song" search, Play All, Shuffle, Download playlist, Change/Remove cover, Delete (downloaded playlists are read-only to protect your offline files).
- **Playlist import:**
  <table>
  <tr><td><b>YouTube / YT Music</b></td><td>Paste a URL or ID. Handles continuation actions <i>and</i> endpoints, both command names, legacy + new (ViewModel) wrappers, retries and a recursive token fallback — up to 25 pages.</td></tr>
  <tr><td><b>Spotify clone</b></td><td>Read the track list via the Spotify Web API (your own Client ID/secret, stored on-device only) and match every track to a playable YouTube song, with progress.</td></tr>
  <tr><td><b>Paste a track list</b></td><td>Keyless: <code>"Title - Artist"</code> lines or raw Spotify desktop copy blocks.</td></tr>
  </table>

### 🎤 Lyrics

- **Synced lyrics from LRCLIB** — free, no API key.
- **Four-step fallback chain** → exact `track+artist+duration` → `track+artist` → `track+duration` → fuzzy search.
- **Wrong-lyrics guard** — a title-only match is accepted only if its duration is within tolerance *or* the artist overlaps. **A miss beats wrong lyrics.**
- **Beautiful sheet** — per-line highlighting driven by the ExoPlayer position stream, auto-scroll, and *tap any line to seek*. Plain-text fallback when no timestamps exist.

### 🎨 UI / UX

<table>
<tr>
<td width="50%">

**🖌️ Glass Design System**
Deep neutral backdrop, frosted-glass surfaces, white ink and one light primary action — one source of truth shared across every screen. **Dark-only by design** (there is no theme switcher).

**🌊 Liquid Background**
An animated backdrop that reacts across the whole app shell.

</td>
<td width="50%">

**🧭 Floating Glass Nav**
Home / Search / Library / Profile with smooth cubic easing.

**🎵 Persistent Mini Player**
Animates in above the nav bar whenever a song (or a load) is active.

</td>
</tr>
<tr>
<td width="50%">

**🖼️ Full-Screen Player**
Large artwork, seek bar, shuffle, prev/next, repeat, like, lyrics and download.

</td>
<td width="50%">

**✨ Polished Details**
Hand-rolled skeleton loaders, welcome flow with name + photo, press-and-repel touch feedback, and motion tuned to stay cheap on low-end hardware.

</td>
</tr>
</table>

### ⚙️ Settings (Profile)

| Setting | What it does |
|---|---|
| 📴 **Offline mode** | Prefer cached audio over the network |
| 🔔 **Notifications** | Playback updates toggle |
| 🔋 **Background playback** | Shows battery-optimization status, opens the system dialog on tap |
| 📂 **Offline Contents** | Manage and delete downloaded playlists / songs |
| 🟢 **Spotify keys** | Save Client ID / secret for playlist cloning |
| 👤 **Change name / photo** | Profile customisation |
| ℹ️ **About** | Version, build stamp |

> [!IMPORTANT]
> Permissions are requested **once** — the notification permission on first run (Android 13+), and the battery-optimization exemption is opt-in or asked on first launch. **Starting music never interrupts with a dialog.**

---

## 📱 App Screens

| Screen | Purpose |
|---|---|
| `home_screen.dart` | Recently Played rail · Quick Picks (refresh + play) · Your Playlists · Recommended For You |
| `search_screen.dart` | Song search · recent searches (re-run / delete / clear all) · play / add-to-playlist · error snackbars |
| `library_screen.dart` | Liked Songs · playlists · quick actions (Import / Liked / Recent) · create & import dialogs |
| `playlist_detail_screen.dart` | Collapsing header with cover · Play All · Shuffle · Add Song · Download playlist · Change/Remove cover · Delete |
| `liked_songs_screen.dart` | Live list of liked songs — like/unlike reflects instantly everywhere |
| `player_screen.dart` | Full-screen player: artwork, seek, shuffle/repeat, like, lyrics, download, offline failure banners |
| `profile_screen.dart` | Avatar · stat cards · settings · offline contents · Spotify keys · about |
| `onboarding_preferences.dart` | Language / genre / artist taste selection |
| `welcome_flow.dart` | Name + photo setup, main navigation shell |

---

## ⚙️ How Playback Works

```text
 ① Metadata          ② Resolution          ③ Failover           ④ Cache
┌──────────────┐    ┌────────────────┐    ┌────────────────┐    ┌────────────────┐
│ YouTubeService│───▶│ MediaResolver  │───▶│ResolverStrategy│───▶│ CacheService   │
│ search        │    │ resolve        │    │ P1 → P2 → FAIL │    │ stage          │
│ related       │    │ validate       │    │ scoped cooldown│    │ validate       │
│ playlists     │    │ download       │    │ PlaybackReport │    │ atomic promote │
└──────────────┘    └────────────────┘    └────────────────┘    └────────────────┘
                                                                 │
 ⑦ UI               ⑥ Notification        ⑤ Player              │
┌──────────────┐    ┌────────────────┐    ┌────────────────┐    │
│ mini player   │◀───│AtlasAudioHandler│◀───│AudioPlayerService│◀──┘
│ full player   │    │ audio_service  │    │ queue          │
│ nav bar       │    │ media carousel │    │ shuffle / loop │
└──────────────┘    └────────────────┘    │ preload        │
                                          │ offline self-heal│
                                          └────────────────┘
```

1. **Metadata** — `YouTubeService` handles search, related videos and playlists (InnerTube / `youtube_explode_dart`). Audio streams are *never* resolved here.
2. **Resolution** — `MediaResolver` implementations turn a `Song` into a validated `MediaSource`: `resolve → validate → play`, or `download` for offline. Failures are structured `ResolveFailure`s.
3. **Failover** — `ResolverStrategy` walks the provider chain in order within a time budget, with cooldowns and scoped retries, recording every attempt.
4. **Cache** — `CacheService` stages downloads, validates them, promotes them atomically, and enforces a size cap — *without* evicting the song currently playing.
5. **Playback** — `AudioPlayerService` owns the queue, shuffle/loop prediction, preloading, watchdogs, offline self-heal and download triggers.
6. **Notification** — `AtlasAudioHandler` bridges the service to `audio_service`; `notifyListeners()` pushes state so the notification always mirrors the app.
7. **UI** — screens listen to the same `ChangeNotifier`, so the mini player, full player and notification never disagree.

---

## 🎯 Content Rules

`SongFilter` is a single, unit-tested enforcement point applied at every ingestion (search, popular, recommendations, autoplay, queue assignment) and every generated listing (liked/recent rails).

```text
  ⏱️ DURATION      00:45 ─────────────── 07:00        clips · intros · hour loops · livestreams  ✂️
  🌐 LANGUAGE      script  >  artist anchors  >  allow unattributable Latin text
  🎬 DISCOVERY     music videos & long-form uploads are NOT recommendations
```

| Rule | Behaviour |
|---|---|
| ⏱️ **Duration** | Songs must last **00:45 – 07:00**. Clips, intros, hour-long loops, full movies and livestreams are removed. |
| 🌐 **Language** | When a language is selected, only matching music is shown (script detection → artist/channel anchors; unattributable Latin text is allowed). |
| 🎬 **Discovery** | Music-video uploads (`official video`, `music video`, …) and long-form uploads (`1 hour`, `full album`, `megamix`, …) are excluded. Discovery also **requires a known duration**; library listings stay lenient so stored songs never vanish. |

> [!NOTE]
> **Your library is never filtered.** Playlists you import are shown *as-is* — the filter governs discovery, not your own collection. Explicitly downloaded files are exempt so listings never orphan files on disk.

---

## 🧱 Tech Stack

<table>
<tr><td><b>Framework</b></td><td>Flutter — <b>Android only</b> (iOS not buildable) · Dart SDK <code>&gt;=3.0.0 &lt;4.0.0</code></td></tr>
<tr><td><b>Audio</b></td><td><code>just_audio</code> (ExoPlayer) + <code>audio_session</code></td></tr>
<tr><td><b>Background</b></td><td><code>audio_service</code> — <i>vendored</i> at <code>plugins/audio_service</code></td></tr>
<tr><td><b>YouTube</b></td><td>InnerTube (song-only search) + <code>youtube_explode_dart</code> for streams &amp; playlists</td></tr>
<tr><td><b>Lyrics</b></td><td>LRCLIB — no API key required</td></tr>
<tr><td><b>State</b></td><td><code>provider</code></td></tr>
<tr><td><b>Storage</b></td><td><code>shared_preferences</code> — local, on-device</td></tr>
<tr><td><b>Images</b></td><td><code>cached_network_image</code></td></tr>
<tr><td><b>Connectivity</b></td><td><code>connectivity_plus</code></td></tr>
<tr><td><b>UI</b></td><td><code>google_fonts</code> (Plus Jakarta Sans) · hand-rolled glass &amp; skeleton widgets</td></tr>
</table>

<details>
<summary><b>Android permissions</b></summary>

```xml
INTERNET · ACCESS_NETWORK_STATE · WAKE_LOCK
FOREGROUND_SERVICE · FOREGROUND_SERVICE_MEDIA_PLAYBACK
POST_NOTIFICATIONS · REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
```

</details>

---

## 🗂️ Project Structure

```text
lib/
├── main.dart                    # Entry point, AudioService init, providers
├── app.dart                     # MaterialApp, tab shell, mini player, glass nav
├── build_info.dart              # Release stamp (Profile → About)
│
├── models/
│   ├── song.dart                # Song data model
│   └── playlist.dart            # Playlist model (+ download tracking)
│
├── media/                       # 🔀 Stream resolution layer
│   ├── media_source.dart        # Normalized MediaSource + MediaProvider enum
│   ├── media_resolver.dart      # Provider contract (resolve/validate/download)
│   ├── resolver_strategy.dart   # Provider chain, cooldowns, failover
│   ├── cache_service.dart       # Offline cache: staging, validation, size cap
│   ├── resolve_failure.dart     # Structured failure taxonomy
│   └── providers/
│       └── youtube_provider.dart   # stream resolution · 1MB chunked downloads
│
├── services/
│   ├── audio_service.dart       # AudioPlayerService: queue, preload, offline
│   ├── atlas_audio_handler.dart # audio_service ↔ app queue bridge
│   ├── youtube_service.dart     # Search, related, trending, playlists
│   ├── ytmusic_search.dart      # YouTube Music song-only search
│   ├── spotify_service.dart     # Spotify import / clone / parsing
│   ├── playlist_parser.dart     # YouTube playlist pagination
│   ├── lyrics_service.dart      # LRCLIB fallback chain + wrong-lyrics guard
│   ├── quick_picks.dart         # On-device recommendation ranking
│   ├── song_filter.dart         # Duration / language / discovery rules
│   ├── storage_service.dart     # Playlists, likes, history, downloads
│   ├── user_preferences.dart    # Onboarding taste preferences
│   └── system_permissions.dart  # Battery exemption bridge
│
├── screens/                     # home · search · library · player · profile …
├── widgets/                     # mini_player · artwork · lyrics_sheet …
└── theme/app_theme.dart         # 🎨 Glass design system + AppMotion
```

---

## 🛠️ Getting Started

### 📋 Prerequisites

- **Flutter SDK** — stable channel (developed against 3.47.2 / Dart 3)
- **Android Studio**, or the Android SDK plus a JDK
- An Android device or emulator running **Android 7.0 (API 24)** or newer

> [!WARNING]
> ### 🍎 iOS is not ready — please be patient
> **You will not be able to build an iOS app from this repo, and it won't be possible for a while.** There is **no `ios/` folder at all** — no `Runner.xcodeproj`, no `Info.plist`, no CocoaPods setup — and several dependencies (vendored `audio_service`, the Android foreground-service/Wi-Fi-lock work) are Android-only right now.
>
> **Android is the only working target.** iOS support is a large, deliberate piece of work — not an oversight — so it is **not coming soon**. If you're here for iOS, we appreciate the interest, but please **stay patient**; asking "when iOS?" won't speed it up. This notice will change when real work begins.

### 📦 Installation

```bash
# 1 · Clone the repository
git clone https://github.com/myLastNeuron/Atlas-Music.git

# 2 · Enter the project
cd Atlas-Music

# 3 · Install dependencies
flutter pub get

# 4 · Run the app
flutter run
```

> [!WARNING]
> `audio_service` is vendored as a local path override (`plugins/audio_service`) — Android builds depend on it, so **don't remove the override**.

### 📦 Build APK

```bash
# Release build — one install-anywhere APK (about 58 MB)
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk

# Per-architecture APKs — smaller, recommended for GitHub releases
flutter build apk --release --split-per-abi
# → app-armeabi-v7a-release.apk · app-arm64-v8a-release.apk
```

### 🔑 Signing a release

Out of the box, release builds fall back to the **debug keystore**, so
`flutter run --release` and CI work with no setup. Debug keystores are generated
per machine, though — so APKs built on different computers can't update each
other. That's fine for local testing, but not for handing builds to other people.

For a stable signature that users can update in place, create your own keystore once:

```bash
keytool -genkey -v -keystore android/app/atlas-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias atlas
```

Then create `android/key.properties` (both files are git-ignored):

```properties
storePassword=<your store password>
keyPassword=<your key password>
keyAlias=atlas
storeFile=atlas-release.jks
```

The next `flutter build apk --release` picks it up automatically.

> [!IMPORTANT]
> Back up the keystore and its passwords. Losing them means you can **never update
> the app for existing users** — they would have to uninstall and reinstall first.
> `android/key.properties` is deliberately not committed: the app keeps your Spotify
> credentials on-device, and a public signing key would let anyone publish an update
> that could read them.

### 🏷️ Release stamp

Bump `buildStamp` in `lib/build_info.dart` on every release so *"stale install"* reports can be told apart from real regressions.

---

## 🧪 Tests

```bash
# Run the test suite (101 tests)
flutter test

# Check for lints — this must stay clean
flutter analyze
```

> [!TIP]
> `plugins/audio_service` is a vendored third-party copy and is excluded from
> analysis in `analysis_options.yaml`, so `flutter analyze` only reports on code
> owned by this project.

<table>
<tr><th>Area</th><th>Test file</th></tr>
<tr><td>Content rules — duration / language / discovery</td><td><code>song_filter_test.dart</code></td></tr>
<tr><td>Recommendation filtering</td><td><code>recommend_filter_test.dart</code></td></tr>
<tr><td>Quick Picks ranking</td><td><code>quick_picks_test.dart</code></td></tr>
<tr><td>Cache size floor / download policy</td><td><code>cache_service_test.dart</code> · <code>download_policy_test.dart</code></td></tr>
<tr><td>Provider failover + cooldowns</td><td><code>resolver_strategy_test.dart</code> · <code>cooldown_scope_test.dart</code></td></tr>
<tr><td>Lyrics lookup &amp; wrong-lyrics guard</td><td><code>lyrics_test.dart</code></td></tr>
<tr><td>YouTube search mapping</td><td><code>youtube_search_test.dart</code></td></tr>
<tr><td>Spotify track-list parsing</td><td><code>spotify_service_test.dart</code></td></tr>
<tr><td>Playlist / media source parsing</td><td><code>media_source_test.dart</code></td></tr>
<tr><td>Motion, artwork, welcome flow</td><td><code>app_motion_test.dart</code> · <code>artwork_test.dart</code> · <code>welcome_flow_test.dart</code></td></tr>
</table>

---

## 🗺️ Roadmap

- [ ] 🔊 Equalizer
- [ ] 🌙 Sleep timer
- [ ] 🔀 Crossfade between songs
- [ ] ☁️ Cloud sync for playlists
- [ ] 👤 User accounts
- [ ] 🍎 iOS support — **not started, not buildable, and not coming soon** (see [Prerequisites](#-prerequisites))

### 📌 Known Limitations

- **No "Up next" queue editor** — the queue comes from the context you tapped (playlist, liked, search, Quick Picks); next/previous walk it, but there's no reordering screen.
- **No playback restore across restarts** — position and queue are not persisted.
- **No theme switcher** — the app is dark-only by design.
- **Taste preferences are set once** during onboarding (no settings screen to re-edit them yet — `Reset name` re-runs setup).
- **Release builds default to the debug keystore** — add `android/key.properties` to produce update-compatible APKs (see *Signing a release*).

---

## 🤝 Contributing

1. 🍴 Fork the repository
2. 🌿 Create a feature branch — `git checkout -b feature/amazing`
3. 💾 Commit your changes — `git commit -m 'Add amazing feature'`
4. 📤 Push to the branch — `git push origin feature/amazing`
5. 🔎 Open a Pull Request

Before opening a PR, please make sure both of these pass — CI runs them on every push:

```bash
flutter analyze   # must report "No issues found!"
flutter test      # must report "All tests passed!"
```

---

## 📄 License

Licensed under the [Apache License, Version 2.0](LICENSE.md).

---

> [!WARNING]
> ### ⚠️ Disclaimer
> This app is for **educational purposes**. YouTube's Terms of Service may restrict direct audio extraction. **Use responsibly.**

---

> [!CAUTION]
> ### 🤖 Mostly AI-generated — use at your own risk
> I built this app **mostly with AI**, as a personal project to understand how AI works and what it can actually do. It is **not** a professional or audited piece of software.
>
> - **Assume there are loopholes, bugs and rough edges.** Some of them I know about (see *Known Limitations* above); plenty I don't.
> - **No security review has been done.** Don't treat it as hardened. Be careful about what you sign in to or store in it.
> - **No warranty of any kind**, in the spirit of the Apache-2.0 license. You use it at your own risk.
> - **It's a learning project first**, a music player second. If something breaks, that's the trade-off.
>
> Treat it as a curious experiment you're welcome to play with — not as software to depend on.

<div align="center">
<b>If you enjoy Atlas Music, give it a ⭐ star!</b>
<br><br>
<sub>Made with ❤️ and Flutter</sub>
</div>
