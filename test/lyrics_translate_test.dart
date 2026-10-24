import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:atlas_music/services/lyrics_service.dart';

/// Google's shape: [[[translated, original, ...], ...], ...].
http.Response _reply(List<String> segments) => http.Response(
      jsonEncode([
        [
          for (final s in segments) [s, '', null, null, 1],
        ],
      ]),
      200,
      // Devanagari needs the charset: latin1 cannot encode it.
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

/// The `q` and `sl` a mock request carried.
({String text, String source}) _request(http.Request request) {
  final body = Uri.splitQueryString(request.body);
  return (
    text: body['q'] ?? '',
    source: request.url.queryParameters['sl'] ?? '',
  );
}

LyricsService _service(Future<http.Response> Function(http.Request) handler) =>
    LyricsService(
      dir: Directory.systemTemp.createTempSync('lyrics_tr'),
      client: MockClient(handler),
    );

void main() {
  test('keeps one line per lyric line', () async {
    final sends = <String>[];
    final service = _service((request) async {
      sends.add(_request(request).text);
      return _reply(['Hola\n', 'Mundo']);
    });

    expect(await service.translate(['Hello', 'World'], 'es'), ['Hola', 'Mundo']);
    // One request for the batch, not one per line.
    expect(sends.length, 1);
  });

  test('a merged reply falls back to one request per line', () async {
    final service = _service((request) async {
      final text = _request(request).text;
      if (text.contains('\n')) {
        // Google glued both lines into one sentence.
        return _reply(['Hola Mundo']);
      }
      return _reply([text == 'Hello' ? 'Hola' : 'Mundo']);
    });

    expect(await service.translate(['Hello', 'World'], 'es'), ['Hola', 'Mundo']);
  });

  test('blank lines are kept in place and never sent', () async {
    final sends = <String>[];
    final service = _service((request) async {
      sends.add(_request(request).text);
      return _reply(['Uno\n', 'Dos']);
    });

    expect(await service.translate(['One', '', 'Two'], 'es'), ['Uno', '', 'Dos']);
    expect(sends.single, 'One\nTwo');
  });

  test('Devanagari goes out as auto-detected', () async {
    final sources = <String>[];
    final service = _service((request) async {
      sources.add(_request(request).source);
      return _reply(['तुम ही हो']);
    });

    expect(await service.translate(['तुम ही हो'], 'en'), ['तुम ही हो']);
    expect(sources, ['auto']);
  });

  test('romanised Hindi is sent as Hindi, not as English', () async {
    final sources = <String>[];
    final service = _service((request) async {
      final req = _request(request);
      final text = req.text;
      final source = req.source;
      sources.add(source);
      // With `auto` the endpoint returns the input untouched — the old bug.
      if (source == 'auto') return _reply([text]);
      return _reply(['You are the one']);
    });

    expect(await service.translate(['tum hi ho, dil hai tera'], 'en'),
        ['You are the one']);
    expect(sources, ['hi']);
  });

  test('plain English lyrics are not mistaken for romanised Hindi', () {
    expect(LyricsService.looksRomanHindi('I will always love you'), isFalse);
    expect(LyricsService.looksRomanHindi('So tell me what you want'), isFalse);
    expect(LyricsService.looksRomanHindi('तुम ही हो'), isFalse);
    expect(LyricsService.looksRomanHindi('tum hi ho'), isTrue);
    expect(LyricsService.looksRomanHindi('dil hai ki manta nahi'), isTrue);
  });

  test('a dead endpoint reports nothing instead of misaligned text', () async {
    final service = _service((_) async => http.Response('nope', 500));
    expect(await service.translate(['Hello', 'World'], 'es'), isNull);
  });
}
