import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// A GitHub release the app could update to.
class AppRelease {
  /// Version with any leading `v` stripped, e.g. `2.0.3`.
  final String version;

  /// Release body. Markdown from the release page, shown as plain text.
  final String notes;

  /// Direct download URL of the release's `.apk` asset.
  final String apkUrl;

  /// Human page (`html_url`) for "view on GitHub".
  final String pageUrl;

  const AppRelease({
    required this.version,
    required this.notes,
    required this.apkUrl,
    required this.pageUrl,
  });
}

/// Outcome of a single update check.
class UpdateResult {
  final String installedVersion;

  /// Newest release found, or null when GitHub could not be reached.
  final AppRelease? latest;

  final bool updateAvailable;

  const UpdateResult({
    required this.installedVersion,
    required this.latest,
    required this.updateAvailable,
  });
}

/// Checks the public GitHub Releases API for a newer build, and downloads the
/// APK when one exists.
///
/// Free and keyless: unauthenticated GitHub allows 60 requests/hour per IP,
/// which a manual "Check for updates" tap never approaches. Reads the releases
/// *list* rather than `/releases/latest` on purpose — the latest endpoint skips
/// prereleases, and every Atlas release is a beta, so it would report the wrong
/// version.
class UpdateService {
  static const _owner = 'myLastNeuron';
  static const _repo = 'Atlas-Music';
  static const _releasesUrl =
      'https://api.github.com/repos/$_owner/$_repo/releases';
  static const _ua = 'AtlasMusic (https://github.com/$_owner/$_repo)';
  static const _timeout = Duration(seconds: 15);

  final http.Client _http;
  final bool _owned;

  UpdateService({http.Client? client})
      : _http = client ?? http.Client(),
        _owned = client == null;

  /// The installed version name from the platform (e.g. `2.0.2`).
  Future<String> installedVersion() async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }

  /// Null when GitHub could not be reached (offline, rate-limited, non-200),
  /// so the UI can say that instead of claiming the app is up to date.
  Future<UpdateResult?> check() async {
    final installed = await installedVersion();
    AppRelease? latest;
    try {
      final res = await _http.get(
        Uri.parse(_releasesUrl),
        headers: const {
          'Accept': 'application/vnd.github+json',
          'User-Agent': _ua,
        },
      ).timeout(_timeout);
      if (res.statusCode != 200) return null;
      latest = parseNewestRelease(res.body);
    } catch (_) {
      // Offline / rate-limited / malformed body.
      return null;
    }
    final available =
        latest != null && (compareVersions(latest.version, installed) ?? 0) > 0;
    return UpdateResult(
      installedVersion: installed,
      latest: latest,
      updateAvailable: available,
    );
  }

  /// Downloads the release APK into the app cache, reporting progress 0..1.
  Future<File> downloadApk(
    String url, {
    void Function(double progress)? onProgress,
  }) async {
    final sep = Platform.pathSeparator;
    final dir = Directory('${(await getTemporaryDirectory()).path}${sep}updates');
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File('${dir.path}${sep}atlas-update.apk');

    final req = http.Request('GET', Uri.parse(url));
    req.headers['User-Agent'] = _ua;
    final res = await _http.send(req).timeout(_timeout);
    if (res.statusCode != 200) {
      throw HttpException('Download failed (HTTP ${res.statusCode})');
    }
    final total = res.contentLength ?? 0;
    final sink = file.openWrite();
    var received = 0;
    try {
      try {
        // The timeout also covers the body: a connection that stalls after
        // the response headers used to hang the caller forever.
        await for (final chunk in res.stream.timeout(_timeout)) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress?.call(received / total);
        }
      } finally {
        await sink.close();
      }
    } catch (e) {
      // Never leave a half-written APK behind for the installer to pick up.
      try {
        await file.delete();
      } catch (_) {
        // Nothing to clean up.
      }
      rethrow;
    }
    return file;
  }

  void dispose() {
    if (_owned) _http.close();
  }

  // ---- Pure helpers (unit-tested, no network) ----

  /// Compares two dotted versions, ignoring a leading `v` and any `+build`
  /// suffix. Returns >0 when [a] is newer, <0 when older, 0 when equal.
  /// Null when either side is not a dotted numeric version.
  static int? compareVersions(String a, String b) {
    final pa = _parts(a);
    final pb = _parts(b);
    if (pa == null || pb == null) return null;
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  static List<int>? _parts(String v) {
    var s = v.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    s = s.split('+').first; // drop build metadata ("+6")
    if (s.isEmpty) return null;
    final out = <int>[];
    for (final seg in s.split('.')) {
      final n = int.tryParse(seg.trim());
      if (n == null) return null;
      out.add(n);
    }
    return out;
  }

  /// Picks the newest published (non-draft) release that carries an `.apk`
  /// asset from the GitHub `/releases` list JSON. Prereleases are included on
  /// purpose. The asset is matched by extension, not filename: releases have
  /// shipped the APK under different names.
  static AppRelease? parseNewestRelease(String jsonBody) {
    try {
      final decoded = jsonDecode(jsonBody);
      if (decoded is! List) return null;
      for (final raw in decoded) {
        if (raw is! Map) continue;
        if (raw['draft'] == true) continue;
        final tag = raw['tag_name'];
        if (tag is! String || tag.isEmpty) continue;

        String? apkUrl;
        final assets = raw['assets'];
        if (assets is List) {
          for (final a in assets) {
            if (a is! Map) continue;
            final name = a['name'];
            if (name is String && name.toLowerCase().endsWith('.apk')) {
              apkUrl = a['browser_download_url'] as String?;
              if (apkUrl != null) break;
            }
          }
        }
        if (apkUrl == null) continue;

        return AppRelease(
          version: tag.startsWith('v') ? tag.substring(1) : tag,
          notes: (raw['body'] as String?)?.trim() ?? '',
          apkUrl: apkUrl,
          pageUrl: (raw['html_url'] as String?) ?? '',
        );
      }
    } catch (_) {
      // Malformed body → no release.
    }
    return null;
  }
}
