import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Signals same-process screens that the shared profile photo changed.
final userAvatarVersion = ValueNotifier<int>(0);

/// Deletes a previous local avatar file once a new one has replaced it, so
/// repeated photo changes do not pile up files on disk. Best-effort; remote
/// URLs and the just-saved file are skipped.
Future<void> removeOldAvatarFile(String? old, String keep) async {
  if (old == null || old.isEmpty || old == keep || old.startsWith('http')) {
    return;
  }
  try {
    final f = File(old);
    if (await f.exists()) await f.delete();
  } catch (_) {}
}

enum MusicLanguage {
  all,
  hindi,
  english,
  spanish,
  korean,
  japanese,
  portuguese,
  french,
  punjabi,
  arabic,
  german,
  italian,
  indonesian,
  turkish,
  tamil,
  telugu,
  russian,
  bengali,
  thai,
  filipino,
  dutch,
  kannada,
  marathi
}

/// Persists the onboarding name + music preferences (language, genres, artists).
/// First launch asks once, later launches reuse it. Profile screen can update/clear.
class UserPrefs {
  static const _nameKey = 'user_name';
  static const _avatarKey = 'user_avatar';
  static const _languageKey = 'music_language';
  static const _genresKey = 'music_genres';
  static const _artistsKey = 'music_artists';
  static const _doneKey = 'onboarding_done';

  Future<String?> getName() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_nameKey)?.trim();
    if (v == null || v.isEmpty) return null;
    return v;
  }

  Future<String?> getAvatar() async {
    final prefs = await SharedPreferences.getInstance();
    final avatar = prefs.getString(_avatarKey);
    // Older onboarding builds offered remote stock faces. Remove those legacy
    // choices so users now see initials until they choose their own photo.
    if (avatar != null && Uri.tryParse(avatar)?.host == 'i.pravatar.cc') {
      await prefs.remove(_avatarKey);
      return null;
    }
    return avatar;
  }

  Future<void> setAvatar(String? avatar) async {
    final prefs = await SharedPreferences.getInstance();
    if (avatar == null || avatar.isEmpty) {
      await prefs.remove(_avatarKey);
    } else {
      await prefs.setString(_avatarKey, avatar);
    }
    userAvatarVersion.value++;
  }

  Future<MusicLanguage> getLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_languageKey);
    if (value == null) return MusicLanguage.all;
    return MusicLanguage.values.firstWhere(
      (e) => e.name == value,
      orElse: () => MusicLanguage.all,
    );
  }

  Future<Set<String>> getGenres() async {
    final prefs = await SharedPreferences.getInstance();
    return _readStringSet(prefs.getString(_genresKey));
  }

  Future<Set<String>> getArtists() async {
    final prefs = await SharedPreferences.getInstance();
    return _readStringSet(prefs.getString(_artistsKey));
  }

  Future<void> setName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nameKey, name.trim());
  }

  Future<void> setLanguage(MusicLanguage lang) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languageKey, lang.name);
  }

  Future<void> setGenres(Set<String> genres) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_genresKey, json.encode(genres.toList()));
  }

  Future<void> setArtists(Set<String> artists) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_artistsKey, json.encode(artists.toList()));
  }

  /// Reads a stored string-set. New format is a JSON list; older builds stored
  /// comma-joined text (which corrupts any name containing a comma, e.g.
  /// "Tyler, The Creator"), so fall back to splitting for those. The next
  /// [setGenres]/[setArtists] rewrites the value in the new format.
  static Set<String> _readStringSet(String? raw) {
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = json.decode(raw);
      if (decoded is List) {
        return decoded.whereType<String>().where((s) => s.isNotEmpty).toSet();
      }
    } catch (_) {
      // Fall through to the legacy comma-separated format.
    }
    return raw.split(',').toSet();
  }

  Future<void> clearName() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_nameKey);
  }

  /// Explicit completion stamp. Language "all" is a legit choice, so
  /// boot must never infer "not onboarded" from it (that re-prompted
  /// every reopen for All-language users).
  Future<bool> isOnboardingDone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_doneKey) ?? false;
  }

  Future<void> setOnboardingDone() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_doneKey, true);
  }

  Future<void> clearPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_languageKey);
    await prefs.remove(_genresKey);
    await prefs.remove(_artistsKey);
  }
}
