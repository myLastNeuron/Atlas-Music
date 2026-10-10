import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:atlas_music/services/lyrics_service.dart';

void main() {
  test('translate splits lines back and rejects a count mismatch', () async {
    final dir = Directory.systemTemp.createTempSync('lyrics_tr');
    final ok = LyricsService(
      dir: dir,
      client: MockClient((_) async => http.Response(
          jsonEncode([
            [
              ['Hola\n', 'Hello\n', null, null, 1],
              ['Mundo', 'World', null, null, 1],
            ],
          ]),
          200)),
    );
    expect(await ok.translate(['Hello', 'World'], 'es'), ['Hola', 'Mundo']);

    final bad = LyricsService(
      dir: dir,
      client: MockClient((_) async => http.Response(
          jsonEncode([
            [
              ['Solo una linea', 'Hello', null, null, 1]
            ],
          ]),
          200)),
    );
    expect(await bad.translate(['Hello', 'World'], 'es'), isNull);
  });
}
