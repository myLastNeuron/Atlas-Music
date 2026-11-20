import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/auto_find.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../theme/app_theme.dart';
import 'glass_settings.dart';
import 'storage_service.dart';
import 'theme_settings.dart';
import 'user_prefs.dart';

/// How an export ended. A denied storage permission is not a write failure:
/// the user is told which one happened.
enum ExportOutcome { saved, permissionDenied, unsupported, failed }

class ExportResult {
  const ExportResult(this.outcome, [this.fileName]);

  final ExportOutcome outcome;

  /// The name the file actually got. MediaStore appends " (1)" to a same-name
  /// file, so this is not always the name that was requested.
  final String? fileName;
}

/// One imported/exported backup. Export writes every field; import tolerates
/// missing or malformed entries instead of failing the whole file.
class BackupData {
  final int version;

  /// When the file was written, in UTC. Shown in the import dialog so two
  /// `atlas-backup*.json` files in Downloads can be told apart; null when the
  /// file does not say (or says something that is not a date).
  final DateTime? exportedAt;

  final String? name;
  final String themeMode;
  final bool artworkColor;
  final double glassLevel;
  final bool videoMode;
  final String language;
  final Set<String> genres;
  final Set<String> artists;
  final List<Song> likes;
  final List<Song> recentlyPlayed;
  final Map<String, Map<String, dynamic>> listeningStats;
  final List<String> searchHistory;
  final List<AutoFind> fetchedSongs;
  final List<Playlist> playlists;

  /// Song id → {at, artist}: the "not interested" dismissals the
  /// recommendation rankers exclude songs and down-weight artists by.
  final Map<String, Map<String, dynamic>> notInterested;

  const BackupData({
    this.version = 1,
    this.exportedAt,
    this.name,
    this.themeMode = 'grey',
    this.artworkColor = false,
    this.glassLevel = GlassSettings.defaultLevel,
    this.videoMode = false,
    this.language = 'all',
    this.genres = const {},
    this.artists = const {},
    this.likes = const [],
    this.recentlyPlayed = const [],
    this.listeningStats = const {},
    this.searchHistory = const [],
    this.fetchedSongs = const [],
    this.playlists = const [],
    this.notInterested = const {},
  });

  int get playlistSongCount =>
      playlists.fold(0, (sum, p) => sum + p.songs.length);
}

/// Exports the user's history, playlists, likes, name, fetched songs and
/// settings to a .json in the phone's Downloads folder, and restores that file.
///
/// Downloads are deliberately not part of a backup: audio files stay on the
/// device, and a playlist's downloaded flags/ids would point at files that do
/// not exist on another phone.
class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();

  static const _channel = MethodChannel('atlas/permissions');
  static const _appTag = 'atlas_music';
  static const _version = 1;

  /// The format this build writes. A file that says a higher number still
  /// imports — unknown keys are ignored — but the UI says so, because a newer
  /// Atlas may have changed what a known key means.
  static int get currentVersion => _version;

  /// Saves a backup to Downloads. The outcome separates a denied permission
  /// from a failed write, so the UI can name the real problem.
  Future<ExportResult> export({
    required String? name,
    required ThemeSettings theme,
    required GlassSettings? glass,
    required bool videoMode,
    required String language,
    required Set<String> genres,
    required Set<String> artists,
  }) async {
    final storage = StorageService.instance;
    final playlists = (await storage.getPlaylists())
        .where((p) => p.id != StorageService.downloadedPlaylistId)
        .map(_playlistForExport)
        .toList();
    final data = <String, dynamic>{
      'app': _appTag,
      'version': _version,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'name': name ?? '',
      'settings': {
        'themeMode': theme.mode.name,
        'artworkColor': theme.artworkColor,
        'glassLevel': glass?.level ?? GlassSettings.defaultLevel,
        'videoMode': videoMode,
        'language': language,
        'genres': genres.toList(),
        'artists': artists.toList(),
      },
      'likes': (await storage.getLikedSongs()).map((s) => s.toJson()).toList(),
      'notInterested': await storage.getNotInterested(),
      'history': {
        'recentlyPlayed':
            (await storage.getRecentlyPlayed()).map((s) => s.toJson()).toList(),
        'listeningStats': await storage.getListeningStats(),
        'searchHistory': await storage.getSearchHistory(),
      },
      'fetchedSongs':
          (await storage.getAutoFinds()).map((f) => f.toJson()).toList(),
      'playlists': playlists,
    };
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}-${two(now.month)}-${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}';
    return _saveToDownloads('atlas-backup-$stamp.json', jsonEncode(data));
  }

  /// Opens the system file picker and parses the chosen backup.
  /// Returns null when the user cancels. Throws [FormatException] when the
  /// picked file is not an Atlas backup.
  Future<BackupData?> pickAndParse() async {
    if (!Platform.isAndroid) return null;
    // The native picker caps the read at 20 MB while streaming it in, so the
    // text handed back here is already bounded.
    final raw = await _channel.invokeMethod<String>('pickJsonFile');
    if (raw == null) return null;
    return parse(raw);
  }

  Future<ExportResult> _saveToDownloads(String filename, String content) async {
    if (!Platform.isAndroid) {
      return const ExportResult(ExportOutcome.unsupported);
    }
    try {
      // No prompt on Android 10+; older versions ask for storage access.
      final granted =
          await _channel.invokeMethod<bool>('requestStoragePermission') ??
              false;
      if (!granted) {
        return const ExportResult(ExportOutcome.permissionDenied);
      }
      final saved = await _channel.invokeMethod<String>(
          'saveToDownloads', {'filename': filename, 'content': content});
      if (saved == null || saved.isEmpty) {
        return const ExportResult(ExportOutcome.failed);
      }
      return ExportResult(ExportOutcome.saved, saved);
    } on PlatformException {
      return const ExportResult(ExportOutcome.failed);
    } on MissingPluginException {
      return const ExportResult(ExportOutcome.failed);
    }
  }

  /// Applies a backup in place. Callers warn the user first: this replaces the
  /// current likes, playlists, history and settings by design.
  ///
  /// The replace runs as one unit: the current library and settings are read
  /// first and put back if any write throws, so a failed import is a no-op
  /// instead of a half-restored library.
  Future<void> apply(
    BackupData data, {
    required ThemeSettings theme,
    GlassSettings? glass,
  }) async {
    final storage = StorageService.instance;
    final prefs = UserPrefs();
    final before = await _snapshot(storage, prefs, theme, glass);
    try {
      await _replaceLibrary(storage, data);
      await _applySettings(prefs, theme, glass, data);
    } catch (_) {
      // Rethrow the original failure, but leave the phone as it was.
      try {
        await _replaceLibrary(storage, before);
        await _applySettings(prefs, theme, glass, before);
      } catch (_) {
        // Rollback is best-effort; the caller reports the failure either way.
      }
      rethrow;
    }
  }

  /// Reads everything [apply] overwrites, in the same shape, so it can be
  /// written back unchanged.
  static Future<BackupData> _snapshot(
    StorageService storage,
    UserPrefs prefs,
    ThemeSettings theme,
    GlassSettings? glass,
  ) async {
    return BackupData(
      version: _version,
      name: await prefs.getName(),
      themeMode: theme.mode.name,
      artworkColor: theme.artworkColor,
      glassLevel: glass?.level ?? GlassSettings.defaultLevel,
      videoMode: await prefs.getVideoMode(),
      language: (await prefs.getLanguage()).name,
      genres: await prefs.getGenres(),
      artists: await prefs.getArtists(),
      likes: await storage.getLikedSongs(),
      recentlyPlayed: await storage.getRecentlyPlayed(),
      listeningStats: await storage.getListeningStats(),
      searchHistory: await storage.getSearchHistory(),
      fetchedSongs: await storage.getAutoFinds(),
      playlists: await storage.getPlaylists(),
      notInterested: await storage.getNotInterested(),
    );
  }

  /// Dismissals land before likes on purpose: liking a song clears its
  /// dismissal everywhere else in the app, so a restored like must win over a
  /// dismissal the same file carried. [StorageService.replaceLikedSongs] does
  /// the clearing.
  static Future<void> _replaceLibrary(
      StorageService storage, BackupData data) async {
    await storage.replaceRecentlyPlayed(data.recentlyPlayed);
    await storage.replaceNotInterested(data.notInterested);
    await storage.replaceLikedSongs(data.likes);
    await storage.replacePlaylists(data.playlists);
    await storage.replaceAutoFinds(data.fetchedSongs);
    await storage.replaceListeningStats(data.listeningStats);
    await storage.replaceSearchHistory(data.searchHistory);
  }

  static Future<void> _applySettings(
    UserPrefs prefs,
    ThemeSettings theme,
    GlassSettings? glass,
    BackupData data,
  ) async {
    // A file with no name never clears the name this phone has. The entry
    // screen is gated on the name, so clearing it drops the user into
    // onboarding right after a restore and looks like everything was lost.
    final name = data.name;
    if (name != null && name.isNotEmpty) await prefs.setName(name);
    await prefs.setLanguage(MusicLanguage.values.firstWhere(
      (l) => l.name == data.language,
      orElse: () => MusicLanguage.all,
    ));
    await prefs.setGenres(data.genres);
    await prefs.setArtists(data.artists);
    await prefs.setVideoMode(data.videoMode);

    await theme.setMode(AppPalette.values.firstWhere(
      (m) => m.name == data.themeMode,
      orElse: () => AppPalette.grey,
    ));
    await theme.setArtworkColor(data.artworkColor);
    await glass?.setLevel(data.glassLevel);
  }

  /// Reads a backup file's text. Unknown keys are ignored, so a newer export
  /// still restores what this build understands.
  BackupData parse(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw const FormatException('This file is not valid JSON.');
    }
    if (decoded is! Map || decoded['app'] != _appTag) {
      throw const FormatException('This is not an Atlas Music backup file.');
    }
    final map = Map<String, dynamic>.from(decoded);
    final settings = map['settings'] is Map
        ? Map<String, dynamic>.from(map['settings'] as Map)
        : <String, dynamic>{};
    final history = map['history'] is Map
        ? Map<String, dynamic>.from(map['history'] as Map)
        : <String, dynamic>{};
    final stats = <String, Map<String, dynamic>>{};
    final rawStats = history['listeningStats'];
    if (rawStats is Map) {
      rawStats.forEach((key, value) {
        if (key is String && key.isNotEmpty) {
          final entry = _cleanStat(value);
          if (entry != null) stats[key] = entry;
        }
      });
    }
    final stringSet = <String>{};
    if (settings['genres'] is List) {
      for (final g in settings['genres'] as List) {
        if (g is String && g.isNotEmpty) stringSet.add(g);
      }
    }
    final artistSet = <String>{};
    if (settings['artists'] is List) {
      for (final a in settings['artists'] as List) {
        if (a is String && a.isNotEmpty) artistSet.add(a);
      }
    }
    final level = settings['glassLevel'];
    final name = map['name'];
    final version = map['version'];
    // Only for a human: a junk value reads as "when unknown", never a failure.
    final exportedAt = DateTime.tryParse(map['exportedAt']?.toString() ?? '');
    return BackupData(
      version: version is int && version > 0 ? version : 1,
      exportedAt: exportedAt?.toUtc(),
      name: name is String && name.trim().isNotEmpty ? name.trim() : null,
      themeMode: settings['themeMode'] is String
          ? settings['themeMode'] as String
          : 'grey',
      artworkColor: settings['artworkColor'] == true,
      glassLevel: level is num
          ? level.toDouble().clamp(0.0, 1.0).toDouble()
          : GlassSettings.defaultLevel,
      videoMode: settings['videoMode'] == true,
      language: settings['language'] is String
          ? settings['language'] as String
          : 'all',
      genres: stringSet,
      artists: artistSet,
      // A song listed twice cannot be un-liked in one tap (the toggle removes
      // the first match), so a restore keeps one entry per song.
      likes: _songs(map['likes'], dedupe: true),
      recentlyPlayed: _songs(history['recentlyPlayed']),
      listeningStats: stats,
      searchHistory: history['searchHistory'] is List
          ? (history['searchHistory'] as List)
              .whereType<String>()
              .where((q) => q.isNotEmpty)
              .toList()
          : const [],
      fetchedSongs: _autoFinds(map['fetchedSongs']),
      playlists: _playlists(map['playlists']),
      notInterested: _marks(map['notInterested']),
    );
  }

  /// Playlists are carried as their song lists only. Downloads and system
  /// management do not travel. The cover path does, and [parse] keeps it only
  /// when that file is still on the phone, so a same-device restore keeps its
  /// covers and a new phone does not inherit a path pointing at nothing.
  static Map<String, dynamic> _playlistForExport(Playlist p) {
    return p.toJson()
      ..['isDownloaded'] = false
      ..['downloadedSongIds'] = const <String>[]
      ..['isSystemManaged'] = false;
  }

  static List<Song> _songs(Object? raw, {bool dedupe = false}) {
    if (raw is! List) return const [];
    final out = <Song>[];
    final seen = <String>{};
    for (final item in raw.whereType<Map>()) {
      final song = _try(() => Song.fromJson(Map<String, dynamic>.from(item)));
      if (song == null || song.id.isEmpty) continue;
      if (dedupe && !seen.add(song.id)) continue;
      out.add(song);
    }
    return out;
  }

  static List<AutoFind> _autoFinds(Object? raw) {
    if (raw is! List) return const [];
    final out = <AutoFind>[];
    for (final item in raw.whereType<Map>()) {
      final find =
          _try(() => AutoFind.fromJson(Map<String, dynamic>.from(item)));
      if (find != null && find.song.id.isNotEmpty) out.add(find);
    }
    return out;
  }

  static List<Playlist> _playlists(Object? raw) {
    if (raw is! List) return const [];
    final out = <Playlist>[];
    for (final item in raw.whereType<Map>()) {
      final json = Map<String, dynamic>.from(item);
      // The device's own Downloaded Music list is never imported over.
      if (json['id'] == StorageService.downloadedPlaylistId) continue;
      // Keep the playlist when one of its songs is malformed; [Song.fromJson]
      // is not tolerant of a wrong field type. A playlist never holds the same
      // song twice either: adding a song already there is refused.
      json['songs'] =
          _songs(json['songs'], dedupe: true).map((s) => s.toJson()).toList();
      // A wrong type in any text field would make Playlist.fromJson throw and
      // drop the playlist, so unset it and let the model's default apply.
      for (final key in const [
        'id',
        'name',
        'description',
        'thumbnailUrl',
        'source',
      ]) {
        final value = json[key];
        if (value != null && value is! String) json[key] = null;
      }
      json['coverPath'] = _existingCover(json['coverPath']);
      if (DateTime.tryParse(json['createdAt']?.toString() ?? '') == null) {
        json['createdAt'] = DateTime.now().toIso8601String();
      }
      json['isDownloaded'] = false;
      json['downloadedSongIds'] = const <String>[];
      json['isSystemManaged'] = false;
      final playlist = _try(() => Playlist.fromJson(json));
      if (playlist != null && playlist.id.isNotEmpty) out.add(playlist);
    }
    return out;
  }

  /// A playlist cover is a file in this app's own storage, so it only means
  /// something where it was written. Kept when the file is still here.
  static String? _existingCover(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    final exists = _try(() => File(raw).existsSync());
    return exists == true ? raw : null;
  }

  /// Song id → {at, artist}, coerced to the types the rankers cast to so a
  /// hand-edited decimal cannot make a later read throw.
  static Map<String, Map<String, dynamic>> _marks(Object? raw) {
    final out = <String, Map<String, dynamic>>{};
    if (raw is! Map) return out;
    raw.forEach((key, value) {
      if (key is! String || key.isEmpty || value is! Map) return;
      final at = value['at'];
      final artist = value['artist'];
      out[key] = {
        'at': at is num ? at.toInt() : DateTime.now().millisecondsSinceEpoch,
        'artist': artist is String ? artist : '',
      };
    });
    return out;
  }

  /// Restores only the numeric fields [StorageService.recordListen] and the
  /// rankers cast to int. A hand-edited value such as `3.0` would otherwise
  /// make every later listen for that song throw and silently lose stats.
  static Map<String, dynamic>? _cleanStat(Object? raw) {
    if (raw is! Map) return null;
    int asInt(Object? v) => v is num ? v.toInt() : 0;
    final skipTimes = raw['skipTimes'];
    return {
      'playCount': asInt(raw['playCount']),
      'skipCount': asInt(raw['skipCount']),
      'totalMs': asInt(raw['totalMs']),
      'lastPlayed': asInt(raw['lastPlayed']),
      if (skipTimes is List)
        'skipTimes': skipTimes.whereType<num>().map((n) => n.toInt()).toList(),
    };
  }

  static T? _try<T>(T Function() build) {
    try {
      return build();
    } catch (_) {
      return null;
    }
  }
}
