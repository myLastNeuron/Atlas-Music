<div align="center">

<img src="https://img.shields.io/badge/Atlas-Music-7C5CFF?style=for-the-badge&logo=flutter&logoColor=white" alt="Atlas Music" height="40"/>

# 🎵 Atlas Music

### *Your music. No ads. No limits.*

**An open-source, ad-free music player built with Flutter — streaming from YouTube, with full offline support, background playback, synced & translated lyrics and a liquid-glass interface.**

[![Flutter](https://img.shields.io/badge/Flutter-3.0%2B-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.0%2B-0175C2?logo=dart&logoColor=white)](https://dart.dev)
![Platform](https://img.shields.io/badge/platform-Android%20only-3DDC84?logo=android&logoColor=white)
![Version](https://img.shields.io/badge/version-1.0.1%2B2-blue)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE.md)
![Tests](https://img.shields.io/badge/tests-151%20declared-brightgreen)

[**🆕 What's New**](#-whats-new) · [**🚀 Features**](#-features) · [**📱 Screens**](#-app-screens) · [**⚙️ How It Works**](#️-how-playback-works) · [**🛠️ Getting Started**](#️-getting-started) · [**🧪 Tests**](#-tests)

> [!IMPORTANT]
> **📱 Android only for now.** iOS builds **cannot** be made from this repo — the iOS project isn't scaffolded and won't be ready for a long while. Please be patient; see [iOS is not ready](#-prerequisites).

</div>

---

<details>
<summary><b>📑 Contents</b></summary>

1. [🆕 What's New](#-whats-new)
2. [✨ Features](#-features)
3. [📱 App Screens](#-app-screens)
4. [⚙️ How Playback Works](#️-how-playback-works)
5. [🎯 Content Rules](#-content-rules)
6. [🧱 Tech Stack](#-tech-stack)
7. [🗂️ Project Structure](#️-project-structure)
8. [🛠️ Getting Started](#️-getting-started)
9. [🧪 Tests](#-tests)
10. [🗺️ Roadmap](#️-roadmap)
11. [🤝 Contributing](#-contributing)
12. [📄 License](#-license)
13. [⚠️ Disclaimer](#️-disclaimer)

</details>

---

## 🆕 What's New

> [!TIP]
> The newest release of Atlas Music. Grab the latest APK and update in place (see [Signing a release](#-signing-a-release)).

| | Update | What it means for you |
|:--:|---|---|
| 📊 | **Read-only YT stats** | Likes are shown for the playing video. Dislikes appear only when YouTube still publishes them, otherwise they show as *N/A*. Values are never guessed. |
| 🫧 | **Real liquid glass** | Panels now use a light sheen, soft rim and drop shadow instead of a plain backdrop blur — a glossier, more physical look. |
| 🌐 | **Lyrics translation** | Translate synced lyrics with one tap from the lyrics sheet. Lines stay aligned with their timestamps. |
| 🎤 | **Artist pages** | Tap an artist's name in the full player to open their page — top songs and albums/singles, straight from YouTube Music. |
| 🐞 | **Major bug fixes & cleanup** | Fixed significant bugs and removed unused code for a leaner app. |
| 🔒 | **Loophole fixes & security patches** | Closed major gaps in app logic and applied security hardening. |
| 🚀 | **Performance boost** | An estimated **2.5–5%** better performance on some devices it may vary device to device some devices expect negative performance reduction of (-5% to 10%) in some devices. |

---

## 🚀 Features

### 🎵 Playback

| | Feature | Details |
|:--:|---|---|
| 📺 | **Ad-free streaming** | Audio is pulled straight from the source CDN — no ads ever play. |
| 🔀 | **Provider-agnostic architecture** | Everything sits behind one `MediaResolver` contract (`resolve → validate → download`). The player never knows which backend produced a stream, and new backends can be added without touching it. |
| 🏆 | **Reliability-first stream ranking** | Candidates are ranked MP4/AAC → WebM/Opus, then bitrate, then known length, then provider reliability. Every URL is validated (reachable, non-zero, unexpired, compatible container) before ExoPlayer sees it. |
| 📴 | **Background playback** | A `mediaPlayback` foreground service, partial wake lock and high-performance Wi-Fi lock keep music alive with the screen off. Audio focus **ducks, never pauses**, on transient loss. |
| ⏭️ | **Seamless auto-advance** | A track ending is a *transition*, not a stop — the notification and service never tear down between songs. |
| 📡 | **Auto-play / radio** | When a queue ends: related videos → artist search → title search → **your own liked/recent** (offline-safe). Playback never dead-ends. |
| 🎯 | **Quick Picks** | An on-device recommender using plays, skip timestamps, recency, top artists/genres, likes, session context and the current queue — with time-decayed skip penalties, per-artist diversity caps and a plain-English **"because you played…"** reason on each pick. |
| 🔁 | **Shuffle & repeat** | Shuffle, repeat-all and repeat-one — honored by next/previous prediction *and* the notification controls. |
| ⚡ | **Preloading & caching** | Every track plays from a **verified local file**. Up to 3 upcoming songs are pre-downloaded while you listen, so auto-advance starts instantly from disk. |
| 🩹 | **Offline self-heal** | Paused for connectivity in the background? It re-checks on a bounded backoff (5s → 2min) and resumes on its own. |
| 🔇 | **Never goes silent** | If nothing ahead can be resolved, a cached track is replayed instead of burning the queue. |
| 🛡️ | **Multi-provider failover** | Finite chain (P1 → P2 → FAIL) with per-provider cooldown: 3 consecutive *provider* failures → 2 min, doubling, capped at 15 min. One bad song can never strand playback. |
| 💾 | **Download for offline** | A length-scaled size floor (~24 kbps, min 16 KB) rejects truncated downloads, with a fresh-chain retry on rejection. Cache is capped at **1 GB** (oldest-first eviction, never evicting the playing queue) with a **7-day TTL**. |

### 🎤 Lyrics

- 🔎 **Synced lyrics from LRCLIB** — free, no API key.
- 🪜 **Four-step fallback chain** → exact `track + artist + duration` → `track + artist` → `track + duration` → fuzzy search.
- 🛑 **Wrong-lyrics guard** — a title-only match is accepted only if its duration is within tolerance *or* the artist overlaps. **A miss beats wrong lyrics.**
- 🌐 **Translation** — translate lyrics into your language from the lyrics sheet. The translated line count is checked against the original, so a mismatch is rejected instead of drifting out of sync.
- 🎨 **Beautiful sheet** — per-line highlighting driven by the ExoPlayer position stream, auto-scroll, and *tap any line to seek*. Plain-text fallback when no timestamps exist.

### 🎤 Artists & 📊 Video Stats

- 🧑‍🎤 **Artist pages** — header, top songs and an albums/singles rail, built from YouTube Music browse data on open. Nothing is stored, so it works for local, imported and cached songs alike.
- 👍 **Likes & dislikes** — read-only engagement for the playing video. Missing numbers show as *N/A*; Atlas never fabricates them.

### 📱 Notification & Lock Screen

- 🎛️ **Rich media controls** — prev / play-pause / next, ±10s fast-forward & rewind, seek, and full-size cover art.
- 🔗 **Wired to the real queue** — `AtlasAudioHandler` drives the actual app queue, so skip buttons walk it properly.
- 🖼️ **Sharp artwork** — resolver chain: upscaled Google thumbnail → song URL → ytimg `maxresdefault` / `hq720` → `sddefault` → `hqdefault`. A SOF-marker JPEG width reader rejects the 120×90 placeholder, then the art is cached locally.
- ✨ **Clean status icon** — monochrome vector, no white square.
- 📌 **Never drops** — persistent across pauses and track transitions; Android 13+ system actions (`skipToPrevious`, `skipToNext`, `seek`) are advertised so the media carousel works.

### 🔍 Search & Discovery

| Feature | Details |
|---|---|
| 🎤 **Song-first search** | Merges YouTube Music's InnerTube catalogue with plain YouTube results, so slowed/reverb, remix, lyric and sped-up uploads all appear. Trailers, movies, TV, podcasts and long-form uploads are stripped. |
| 📈 **Related & Autoplay** | Radio/autoplay continuations go through the same song-only path. |
| 🕘 **Recent searches** | History with one-tap re-query. |
| ➕ **Quick actions** | Play, or add to a playlist straight from results. |
| 🎛️ **Taste onboarding** | Pick from **23 languages**, **25 genres** and per-language curated artist lists to tune what you see. |

### 📚 Library

- 🎧 **Playlists** — create, rename, reorder, delete. Any song can go in any playlist.
- ❤️ **Liked Songs** — one tap from the player, live-updating everywhere.
- 🕘 **Recently Played** — listening history with a recency-weighted rail on Home.
- 📥 **Downloaded Music** — a system playlist of offline tracks, with per-song removal and "clear downloads".
- 🎛️ **Per-playlist tools** — in-dialog "Add Song" search, Play All, Shuffle, Download playlist, Change/Remove cover, Delete. Downloaded playlists are read-only to protect your offline files.
- 📥 **Playlist import**

  | Source | How it works |
  |---|---|
  | ▶️ **YouTube / YT Music** | Paste a URL or ID. Handles continuation actions *and* endpoints, both command names, legacy + new (ViewModel) wrappers, retries and a recursive token fallback — up to 25 pages. |
  | 🟢 **Spotify** | Read the track list via the Spotify Web API (your own Client ID/secret, stored on-device only) and match every track to a playable YouTube song, with progress. |
  | 📝 **Paste a track list** | Keyless: `"Title - Artist"` lines or raw Spotify desktop copy blocks. |

### 🎨 UI / UX

<table>
<tr>
<td width="50%">

**🫧 Liquid Glass Design System**
Deep neutral backdrop, glossy glass panels (sheen, rim light, soft shadow — no plain blur), white ink and one light primary action. One source of truth across every screen. **Dark-only by design** (no theme switcher).

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
Large artwork, seek bar, shuffle, prev/next, repeat, like, lyrics, download, and a tap-through to the artist page.

</td>
<td width="50%">

**✨ Polished Details**
Hand-rolled skeleton loaders, a friendly error screen, welcome flow with name + photo, press-and-repel touch feedback, and motion tuned to stay cheap on low-end hardware.

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
| ℹ️ **About** | Plain version info |

> [!IMPORTANT]
> Permissions are requested **once** — the notification permission on first run (Android 13+), and the battery-optimization exemption is opt-in or asked on first launch. **Starting music never interrupts with a dialog.**

---

## 📱 App Screens

| Screen | Purpose |
|---|---|
| 🏠 `home_screen.dart` | Recently Played rail · Quick Picks (refresh + play) · Your Playlists · Recommended For You |
| 🔍 `search_screen.dart` | Song search · recent searches (re-run / delete / clear all) · play / add-to-playlist · error snackbars |
| 📚 `library_screen.dart` | Liked Songs · playlists · quick actions (Import / Liked / Recent) · create & import dialogs |
| 📀 `playlist_detail_screen.dart` | Collapsing header with cover · Play All · Shuffle · Add Song · Download · Change/Remove cover · Delete |
| ❤️ `liked_songs_screen.dart` | Live list of liked songs — like/unlike reflects instantly everywhere |
| 🕘 `history_screen.dart` | Full listening history |
| 🧑‍🎤 `artist_screen.dart` | Artist header · top songs · albums & singles |
| ▶️ `player_screen.dart` | Full-screen player: artwork, seek, shuffle/repeat, like, lyrics, download, artist link, video stats, offline failure banners |
| 👤 `profile_screen.dart` | Avatar · stat cards · settings · offline contents · Spotify keys · about |
| 🎛️ `onboarding_preferences.dart` | Language / genre / artist taste selection |
| 👋 `welcome_flow.dart` | Name + photo setup, main navigation shell |

---

## ⚙️ How Playback Works

```text
  ① Metadata          ② Resolution          ③ Failover           ④ Cache
┌───────────────┐    ┌────────────────┐    ┌────────────────┐    ┌────────────────┐
│ YouTubeService│───▶│ MediaResolver  │───▶│ResolverStrategy│───▶│ CacheService   │
│ search        │    │ resolve        │    │ P1 → P2 → FAIL │    │ stage          │
│ related       │    │ validate       │    │ scoped cooldown│    │ validate       │
│ playlists     │    │ download       │    │ PlaybackReport │    │ atomic promote │
└───────────────┘    └────────────────┘    └────────────────┘    └───────┬────────┘
                                                                        │
  ⑦ UI               ⑥ Notification        ⑤ Player                       │
┌───────────────┐    ┌────────────────┐    ┌────────────────┐           │
│ mini player   │◀───│AtlasAudioHandler│◀──│AudioPlayerService│◀─────────┘
│ full player   │    │ audio_service  │    │ queue          │
│ nav bar       │    │ media carousel │    │ shuffle / loop │
└───────────────┘    └────────────────┘    │ preload        │
                                           │ offline self-heal│
                                           └────────────────┘
```

1. **Metadata** — `YouTubeService` handles search, related videos and playlists (InnerTube / `youtube_explode_dart`). Audio streams are *never* resolved here.
2. **Resolution** — `MediaResolver` implementations turn a `Song` into a validated `MediaSource`: `resolve → validate → play`, or `download` for offline. Failures are structured `ResolveFailure`s.
3. **Failover** — `ResolverStrategy` walks the provider chain within a time budget, with cooldowns and scoped retries, recording every attempt.
4. **Cache** — `CacheService` stages downloads, validates them, promotes them atomically and enforces a size cap — *without* evicting the song currently playing.
5. **Playback** — `AudioPlayerService` owns the queue, shuffle/loop prediction, preloading, watchdogs, offline self-heal and download triggers.
6. **Notification** — `AtlasAudioHandler` bridges the service to `audio_service`; `notifyListeners()` pushes state so the notification always mirrors the app.
7. **UI** — screens listen to the same `ChangeNotifier`, so the mini player, full player and notification never disagree.

---

## 🎯 Content Rules

`SongFilter` is a single, unit-tested enforcement point applied at every ingestion (search, popular, recommendations, autoplay, queue assignment) and every generated listing (liked/recent rails).

```text
  ⏱️ DURATION      00:45 ─────────────── 07:00       clips · intros · hour loops · livestreams  ✂️
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
<tr><td><b>YouTube</b></td><td>InnerTube (song-only search, browse for artists, video stats) + <code>youtube_explode_dart</code> for streams &amp; playlists</td></tr>
<tr><td><b>Lyrics</b></td><td>LRCLIB (no API key) · Google translate for lyric translation</td></tr>
<tr><td><b>State</b></td><td><code>provider</code></td></tr>
<tr><td><b>Storage</b></td><td><code>shared_preferences</code> — local, on-device</td></tr>
<tr><td><b>Images</b></td><td><code>cached_network_image</code></td></tr>
<tr><td><b>Connectivity</b></td><td><code>connectivity_plus</code></td></tr>
<tr><td><b>UI</b></td><td><code>google_fonts</code> (Plus Jakarta Sans) · hand-rolled liquid-glass &amp; skeleton widgets</td></tr>
</table>

<details>
<summary><b>🔐 Android permissions</b></summary>

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
│
├── models/
│   ├── song.dart                # Song data model
│   ├── playlist.dart            # Playlist model (+ download tracking)
│   ├── artist.dart              # Artist page model
│   └── video_stats.dart         # Read-only likes / dislikes
│
├── media/                       # 🔀 Stream resolution layer
│   ├── media_source.dart        # Normalized MediaSource + MediaProvider enum
│   ├── media_resolver.dart      # Provider contract (resolve/validate/download)
│   ├── resolver_strategy.dart   # Provider chain, cooldowns, failover
│   ├── cache_service.dart       # Offline cache: staging, validation, size cap
│   ├── lyrics_model.dart        # Synced lyric lines
│   ├── resolve_failure.dart     # Structured failure taxonomy
│   └── providers/
│       └── youtube_provider.dart   # stream resolution · 1MB chunked downloads
│
├── services/
│   ├── audio_service.dart       # AudioPlayerService: queue, preload, offline
│   ├── atlas_audio_handler.dart # audio_service ↔ app queue bridge
│   ├── youtube_service.dart     # Search, related, artists, playlists, video stats
│   ├── ytmusic_search.dart      # YouTube Music song-only search
│   ├── spotify_service.dart     # Spotify import / clone / parsing
│   ├── playlist_parser.dart     # YouTube playlist pagination
│   ├── lyrics_service.dart      # LRCLIB chain, wrong-lyrics guard, translation
│   ├── quick_picks.dart         # On-device recommendation ranking
│   ├── song_filter.dart         # Duration / language / discovery rules
│   ├── storage_service.dart     # Playlists, likes, history, downloads
│   ├── user_prefs.dart          # Onboarding taste preferences
│   └── system_permissions.dart  # Battery exemption bridge
│
├── screens/                     # home · search · library · artist · player · profile …
├── widgets/                     # mini_player · artwork · lyrics_sheet · video_stats_bar …
└── theme/app_theme.dart         # 🎨 Liquid-glass design system + AppMotion
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

Out of the box, release builds fall back to the **debug keystore**, so `flutter run --release` and CI work with no setup. Debug keystores are generated per machine, though — so APKs built on different computers can't update each other. That's fine for local testing, but not for handing builds to other people.

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
> Back up the keystore and its passwords. Losing them means you can **never update the app for existing users** — they would have to uninstall and reinstall first. `android/key.properties` is deliberately not committed: the app keeps your Spotify credentials on-device, and a public signing key would let anyone publish an update that could read them.

---

## 🧪 Tests

```bash
# Run the test suite
flutter test

# Check for lints — this must stay clean
flutter analyze
```

> [!TIP]
> `plugins/audio_service` is a vendored third-party copy and is excluded from analysis in `analysis_options.yaml`, so `flutter analyze` only reports on code owned by this project.

| Area | Test file |
|---|---|
| 🎯 Content rules — duration / language / discovery | `song_filter_test.dart` |
| 🎯 Recommendation filtering | `recommend_filter_test.dart` |
| 🎯 Quick Picks ranking | `quick_picks_test.dart` |
| 💾 Cache size floor / download policy | `cache_service_test.dart` · `download_policy_test.dart` |
| 🛡️ Provider failover + cooldowns | `resolver_strategy_test.dart` · `cooldown_scope_test.dart` |
| 🎤 Lyrics lookup, wrong-lyrics guard & translation | `lyrics_test.dart` · `lyrics_translate_test.dart` |
| 🧑‍🎤 Artist parsing & names | `artist_parse_test.dart` · `artist_names_test.dart` |
| 📊 Video stats | `video_stats_test.dart` |
| 🔍 YouTube search mapping | `youtube_search_test.dart` |
| 🟢 Spotify track-list parsing | `spotify_service_test.dart` |
| 📝 Playlist / media source parsing | `playlist_parser_test.dart` · `media_source_test.dart` |
| 👤 User preferences & storage | `user_prefs_test.dart` · `storage_service_test.dart` |
| 🎨 Motion, artwork, welcome flow | `app_motion_test.dart` · `artwork_test.dart` · `welcome_flow_test.dart` |

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
- **Dislike counts are usually unavailable** — YouTube stopped publishing them in 2021, so they show as *N/A*.
- **Release builds default to the debug keystore** — add `android/key.properties` to produce update-compatible APKs (see *Signing a release*).

---

## 🤝 Contributing

1. 🍴 Fork the repository
2. 🌿 Create a feature branch — `git checkout -b feature/amazing`
3. 💾 Commit your changes — `git commit -m 'Add amazing feature'`
4. 📤 Push to the branch — `git push origin feature/amazing`
5. 🔎 Open a Pull Request

Before opening a PR, make sure both of these pass — CI runs them on every push:

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

> [!CAUTION]
> ### 🤖 Mostly AI-generated — use at your own risk
> Built **mostly with AI** as a learning project, not audited software. Expect bugs, no formal security review, no warranty (Apache-2.0). It's a curious experiment, not something to depend on. Getting it polished enough to feel like a real app took a *lot* longer than expected — the AI wrote the bulk of the code, but every rough edge took rounds of back-and-forth to sand off.
>
> **Models used:**
>
> | Model | Share of work |
> |---|---|
> | Muse Spark 1.3 | 30–40% |
> | DeepSeek V4.1 Flash | 20–30% |
> | Muse Glimmer 30B | 10–15% |
> | Big Pickle, Nemotron & other misc models | the rest |
>
> ```mermaid
> pie showData
>     title Rough share of the work by model
>     "Muse Spark 1.3" : 35
>     "DeepSeek V4.1 Flash" : 25
>     "Misc (Big Pickle, Nemotron, etc.)" : 28
>     "Muse Glimmer 30B" : 12
> ```

<div align="center">

---

**If you enjoy Atlas Music, give it a ⭐ star!**

<sub>Made with ❤️ and Flutter</sub>

</div>
