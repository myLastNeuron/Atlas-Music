import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/services/playlist_parser.dart';

void main() {
  group('extractInitialData', () {
    test('parses minified single-line ytInitialData', () {
      const html = '<script>var ytInitialData = {"a":1};</script>';
      final data = PlaylistParser.extractInitialDataForTest(html);
      expect(data['a'], 1);
    });

    test('handles a brace pair inside a string value', () {
      // The old non-greedy regex stopped at the first `};` even when it was
      // inside a JSON string, then json.decode threw.
      const html =
          '<script>ytInitialData = {"title":"a }; b","n":{"x":2}};</script>';
      final data = PlaylistParser.extractInitialDataForTest(html);
      expect(data['title'], 'a }; b');
      expect((data['n'] as Map)['x'], 2);
    });

    test('handles newlines in a non-minified payload', () {
      const html = 'ytInitialData =\n{\n  "a": 1\n};\n';
      final data = PlaylistParser.extractInitialDataForTest(html);
      expect(data['a'], 1);
    });

    test('throws a clear error when the marker is absent', () {
      expect(
        () => PlaylistParser.extractInitialDataForTest('<html></html>'),
        throwsException,
      );
    });
  });
}
