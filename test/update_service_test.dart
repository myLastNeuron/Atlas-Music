import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/services/update_service.dart';

void main() {
  group('UpdateService.compareVersions', () {
    test('orders major/minor/patch numerically, not lexically', () {
      expect(UpdateService.compareVersions('2.0.10', '2.0.9')!, greaterThan(0));
      expect(UpdateService.compareVersions('2.1.0', '2.0.9')!, greaterThan(0));
      expect(UpdateService.compareVersions('1.9.9', '2.0.0')!, lessThan(0));
    });

    test('treats a leading v and build metadata as the same version', () {
      expect(UpdateService.compareVersions('v2.0.2', '2.0.2'), 0);
      expect(UpdateService.compareVersions('2.0.2+6', '2.0.2'), 0);
      expect(UpdateService.compareVersions('2.0.2', '2.0.2+7'), 0);
    });

    test('pads missing segments with zero', () {
      expect(UpdateService.compareVersions('2.1', '2.0.9')!, greaterThan(0));
      expect(UpdateService.compareVersions('2', '2.0.1')!, lessThan(0));
    });

    test('returns null when either side is not a dotted version', () {
      expect(UpdateService.compareVersions('beta', '2.0.0'), isNull);
      expect(UpdateService.compareVersions('2.0.0', 'x.y.z'), isNull);
    });
  });

  group('UpdateService.parseNewestRelease', () {
    test('picks the first non-draft release and strips the v', () {
      const body = '''
      [
        {"tag_name":"v2.0.2","draft":false,"body":"notes 2","html_url":"u2",
         "assets":[{"name":"Atlas.Music.apk","browser_download_url":"a2"}]},
        {"tag_name":"v2.0.1","draft":false,"body":"notes 1","html_url":"u1",
         "assets":[{"name":"Atlas.Music.apk","browser_download_url":"a1"}]}
      ]''';
      final r = UpdateService.parseNewestRelease(body);
      expect(r, isNotNull);
      expect(r!.version, '2.0.2');
      expect(r.notes, 'notes 2');
      expect(r.apkUrl, 'a2');
      expect(r.pageUrl, 'u2');
    });

    test('skips drafts', () {
      const body = '''
      [
        {"tag_name":"v9.0.0","draft":true,
         "assets":[{"name":"x.apk","browser_download_url":"a"}]},
        {"tag_name":"v2.0.2","draft":false,
         "assets":[{"name":"x.apk","browser_download_url":"b"}]}
      ]''';
      expect(UpdateService.parseNewestRelease(body)!.version, '2.0.2');
    });

    test('matches the apk asset by extension, not filename', () {
      const body = '''
      [
        {"tag_name":"v1.0.4","draft":false,"body":"","html_url":"u",
         "assets":[
            {"name":"notes.txt","browser_download_url":"t"},
            {"name":"atlas-music-1.1.0.apk","browser_download_url":"apk"}
         ]}
      ]''';
      expect(UpdateService.parseNewestRelease(body)!.apkUrl, 'apk');
    });

    test('skips a release that carries no apk asset', () {
      const body = '''
      [
        {"tag_name":"v3.0.0","draft":false,
         "assets":[{"name":"src.zip","browser_download_url":"z"}]},
        {"tag_name":"v2.0.2","draft":false,
         "assets":[{"name":"a.apk","browser_download_url":"b"}]}
      ]''';
      expect(UpdateService.parseNewestRelease(body)!.version, '2.0.2');
    });

    test('returns null on empty or malformed input', () {
      expect(UpdateService.parseNewestRelease('[]'), isNull);
      expect(UpdateService.parseNewestRelease('not json'), isNull);
      expect(UpdateService.parseNewestRelease('{"a":1}'), isNull);
    });
  });
}
