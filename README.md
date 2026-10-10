<div align="center">

<img src="docs/media/banner.svg" alt="Atlas Music. Your music. Your library. Your rules." width="100%" />

<h1>Atlas Music</h1>

**A free, open-source Android music player built with Flutter.**<br />
Discover songs, build playlists, follow synced lyrics, and keep listening offline, all in a liquid-glass interface with background playback.

<br />

<p>
  <a href="https://flutter.dev"><img src="https://img.shields.io/badge/Flutter-3.47%2B-54C5F8?style=for-the-badge&logo=flutter&logoColor=white" alt="Flutter 3.47+" /></a>
  <a href="https://dart.dev"><img src="https://img.shields.io/badge/Dart-3-0175C2?style=for-the-badge&logo=dart&logoColor=white" alt="Dart 3" /></a>
  <img src="https://img.shields.io/badge/Platform-Android-3DDC84?style=for-the-badge&logo=android&logoColor=white" alt="Android" />
  <img src="https://img.shields.io/badge/Version-1.1.0%2B3-9B8CFF?style=for-the-badge" alt="Version 1.1.0+3" />
  <a href="LICENSE.md"><img src="https://img.shields.io/badge/License-Apache--2.0-white?style=for-the-badge" alt="Apache 2.0" /></a>
  <a href="https://github.com/myLastNeuron/Atlas-Music/actions/workflows/ci.yml"><img src="https://github.com/myLastNeuron/Atlas-Music/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
</p>

**[Screenshots](#-screenshots) · [Features](#-features) · [Quick start](#-quick-start) · [Architecture](#-how-it-works) · [Contributing](#-contributing)**

</div>

> [!IMPORTANT]
> **Android only.** This repository has no iOS project, and iOS builds are not supported.

---

## 📱 Screenshots

<table align="center">
  <tr>
    <td align="center"><strong>🏠 HOME</strong><br /><a href="docs/media/home.png"><img src="docs/media/home.png" width="260" alt="Home screen with Quick Picks and playlist sections" /></a></td>
    <td align="center"><strong>🔎 SEARCH</strong><br /><a href="docs/media/search.png"><img src="docs/media/search.png" width="260" alt="Search results for Superman by Eminem" /></a></td>
  </tr>
  <tr>
    <td align="center"><strong>📚 LIBRARY</strong><br /><a href="docs/media/library.png"><img src="docs/media/library.png" width="260" alt="Library with import, liked songs, recent and offline music" /></a></td>
    <td align="center"><strong>👤 PROFILE</strong><br /><a href="docs/media/profile.png"><img src="docs/media/profile.png" width="260" alt="Profile and settings screen" /></a></td>
  </tr>
</table>

---

## ✨ Features

<table>
  <tr>
    <td width="33%" valign="top">

### 🎧 Listen
- Background playback with lock-screen and notification controls
- Offline downloads in a validated, size-capped cache
- Queue, shuffle, repeat, and preloading
- Automatic provider failover and offline recovery

</td>
    <td width="33%" valign="top">

### 🔍 Discover
- Search YouTube Music and YouTube video results
- Song-focused discovery, related tracks, and autoplay
- On-device Quick Picks shaped by your listening history
- Artist pages and read-only video engagement stats

</td>
    <td width="33%" valign="top">

### 🎨 Make it yours
- Playlists, liked songs, and listening history
- Import from YouTube, Spotify, or a pasted track list
- Synced lyrics with line-by-line highlighting and translation
- Dark liquid-glass design, animated backdrop, floating navigation

</td>
  </tr>
</table>

<details>
<summary><b>Playback that keeps going</b></summary>

- Audio continues with the screen off. The notification and in-app player share one queue.
- Upcoming tracks are preloaded and validated before they play. If one source fails, Atlas tries another provider.
- Auto-play explores related songs, artist and title searches, and your liked or recently played music.
- Downloads use an oldest-first cache capped at **1 GB** with a **7-day TTL**. The currently playing queue is never evicted.
- Quick Picks use on-device listening signals, with diversity controls and a short explanation for each pick.

</details>

<details>
<summary><b>Lyrics, playlists & library</b></summary>

- Synced lyrics come from [LRCLIB](https://lrclib.net/) with no API key. Tap a line to seek, and translate lyrics from the player.
- Create and edit playlists, add songs from search, change covers, and download a whole playlist for offline listening.
- Import YouTube and YouTube Music playlists, match Spotify playlists to playable tracks, or paste a track list.
- Spotify import uses **your own** Spotify API credentials, stored on-device. Atlas has no accounts and no cloud sync.

</details>

<details>
<summary><b>Discovery rules</b></summary>

Discovery filters out results with unknown duration and non-music or long-form content. Songs in your library and explicitly downloaded files are never removed by these filters. Search can still surface music uploads such as remixes, slowed versions, and lyric videos.

</details>

---

## 🚀 Quick start

### Requirements

| Tool | Version |
|---|---|
| Flutter | stable (developed with **3.47.2**) |
| Dart | 3 |
| Android | **7.0 (API 24)** or newer |
| Tooling | Android Studio, or Android SDK + JDK |

### Run it

```bash
git clone https://github.com/myLastNeuron/Atlas-Music.git
cd Atlas-Music
flutter pub get
flutter run
```

> [!NOTE]
> `audio_service` is vendored at `plugins/audio_service` and wired in through a local dependency override. Keep it in place for Android builds.

### Build an APK

```bash
# Universal APK
flutter build apk --release

# Smaller per-architecture APKs
flutter build apk --release --split-per-abi
```

Output goes to `build/app/outputs/flutter-apk/`.

<details>
<summary><b>🔐 Sign a release</b></summary>

<br />

Without a signing configuration, release builds use the machine's debug keystore. That is fine for local testing, but APKs signed on different machines cannot update each other. To publish update-compatible builds, create a private keystore:

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

> [!WARNING]
> Back up the keystore and its passwords. If you lose them, you cannot ship updates for existing installs.

</details>

---

## 🧭 How it works

<div align="center">
<img src="docs/media/architecture.svg" alt="Playback flow: metadata, stream resolution and failover, validated cache, audio player, notification and app UI" width="100%" />
</div>

| Step | Component | Responsibility |
|:-:|---|---|
| 1 | `YouTubeService` | Search, related tracks, artist data, playlist imports |
| 2 | `MediaResolver` · `ResolverStrategy` | Find and validate playable streams; provider order, retries, cooldowns |
| 3 | `CacheService` | Stage downloads, validate them, promote atomically, enforce the cache limit |
| 4 | `AudioPlayerService` | Queue, shuffle and repeat, preloading, offline recovery, downloads |
| 5 | `AtlasAudioHandler` | Bridge playback to Android media controls; screens follow shared state |

<details>
<summary><b>🧱 Tech stack</b></summary>

- **App:** Flutter and Dart, with Provider
- **Audio:** `just_audio`, `audio_session`, vendored `audio_service`
- **Metadata and streams:** YouTube Music / InnerTube and `youtube_explode_dart`
- **Lyrics:** LRCLIB; Google Translate for lyric translation
- **Local data:** `shared_preferences` and on-device files
- **UI:** Plus Jakarta Sans, custom liquid-glass surfaces, and motion

</details>

<details>
<summary><b>🗂️ Project map</b></summary>

```text
lib/
├── main.dart, app.dart     # Startup, providers, navigation shell
├── media/                  # Resolver contract, provider chain, offline cache
├── models/                 # Song, playlist, artist, video stats
├── screens/                # Home, search, library, player, profile, …
├── services/               # Playback, YouTube, lyrics, storage, recommendations
├── theme/                  # Colors, typography, motion, shared theme
└── widgets/                # Mini-player, lyrics, artwork, glass navigation
plugins/audio_service/      # Vendored audio_service Android implementation
docs/media/                 # Screenshots and architecture diagram
```

</details>

---

## 🧪 Checks

```bash
flutter analyze
flutter test
```

GitHub Actions runs both on every push and pull request. The test suite covers content filtering, recommendations, cache and download policy, resolver failover, lyrics, playlist parsing, storage, and UI helpers. The vendored `plugins/audio_service` copy is excluded from project analysis.

---

## 🗺️ Current limits

- Android only. iOS support has not started.
- No queue-reordering screen, and playback position is not restored after the app restarts.
- No cloud sync or user accounts. Library data stays on-device.
- The dark appearance is fixed; there is no theme switcher.
- YouTube does not publish dislike counts in general, so unavailable values show as `N/A`.

---

## 🤝 Contributing

1. Fork the repository and create a branch.
2. Make your change and add or update tests where they apply.
3. Run `flutter analyze` and `flutter test`.
4. Open a pull request with a short description and your test results.

Issues and pull requests are welcome. Keep platform claims accurate: **Android is the only supported target today.**

---

## 📄 License & disclaimer

Atlas Music is licensed under the [Apache License 2.0](LICENSE.md).

> [!CAUTION]
> This is a mostly AI-generated learning project and has **not** had a formal security audit. It is provided without warranty. YouTube's Terms of Service may restrict direct audio extraction. Use the app responsibly, and follow the terms and laws that apply to you.

---

<div align="center">

**If Atlas Music is useful to you, consider giving it a ⭐**

Made with Flutter · built for the love of music

</div>
