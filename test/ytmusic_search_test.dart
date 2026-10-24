import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:atlas_music/services/ytmusic_search.dart';

/// A search row: title, artist, video id and an optional length in the
/// subtitle.
Map<String, dynamic> row(
  String title,
  String artist,
  String videoId, {
  String? length,
}) {
  return {
    'musicResponsiveListItemRenderer': {
      'flexColumns': [
        {
          'musicResponsiveListItemFlexColumnRenderer': {
            'text': {
              'runs': [
                {'text': title}
              ]
            }
          }
        },
        {
          'musicResponsiveListItemFlexColumnRenderer': {
            'text': {
              'runs': [
                {'text': artist},
                {'text': ' • '},
                if (length != null) {'text': length},
              ]
            }
          }
        },
      ],
      'playlistItemData': {'videoId': videoId},
    }
  };
}

/// A row whose length sits in the fixed column instead of the subtitle.
Map<String, dynamic> rowWithFixedLength(String title, String length) {
  final r = row(title, 'Artist', 'fixed');
  r['musicResponsiveListItemRenderer']['fixedColumn'] = {
    'musicFixedColumnsRenderer': {
      'fixedColumn': {
        'text': {'simpleText': length}
      }
    }
  };
  return r;
}

/// A search response with one songs tab, optionally offering a continuation.
Map<String, dynamic> tabbed(List<Map<String, dynamic>> rows,
    {String? continuation}) {
  return {
    'contents': {
      'tabbedSearchResultsRenderer': {
        'tabs': [
          {
            'tabRenderer': {
              'content': {
                'sectionListRenderer': {
                  'contents': [
                    {
                      'musicShelfRenderer': {
                        'contents': rows,
                        if (continuation != null)
                          'continuations': [
                            {
                              'nextContinuationData': {
                                'continuation': continuation
                              }
                            }
                          ],
                      }
                    }
                  ]
                }
              }
            }
          }
        ]
      }
    }
  };
}

/// A continuation page: rows sit directly under the continuation action.
Map<String, dynamic> continuationPage(List<Map<String, dynamic>> rows) => {
      'contents': {
        'appendContinuationItemsAction': {'continuationItems': rows}
      }
    };

/// A continuation page that nests the rows under continuationContents, the
/// shape the real /youtubei/v1/search continuation returns.
Map<String, dynamic> shelfContinuationPage(List<Map<String, dynamic>> rows) => {
      'continuationContents': {
        'musicShelfContinuation': {'contents': rows}
      }
    };

/// A row whose length sits in the plural fixedColumns list, the shape real
/// album/artist browse rows use.
Map<String, dynamic> rowWithFixedColumnsLength(String title, String length) {
  final r = row(title, 'Artist', 'plural');
  r['musicResponsiveListItemRenderer']['fixedColumns'] = [
    {
      'musicResponsiveListItemFixedColumnRenderer': {
        'text': {
          'runs': [
            {'text': length}
          ]
        }
      }
    }
  ];
  return r;
}

http.Response jsonResponse(Object body) => http.Response(json.encode(body), 200,
    headers: {'content-type': 'application/json'});

Map<String, dynamic> radioItem(
  String title,
  String artist,
  String videoId, {
  String length = '3:30',
}) {
  return {
    'playlistPanelVideoRenderer': {
      'videoId': videoId,
      'title': {
        'runs': [
          {'text': title}
        ]
      },
      'longBylineText': {
        'runs': [
          {'text': artist},
          {'text': ' • '},
          {'text': 'Some Album'},
        ]
      },
      'lengthText': {'simpleText': length},
      'thumbnail': {
        'thumbnails': [
          {
            'url': 'https://i.ytimg.com/vi/$videoId/hq.jpg',
            'width': 60,
            'height': 60
          }
        ]
      },
    }
  };
}

Map<String, dynamic> radioPage(List<Map<String, dynamic>> items) => {
      'contents': {
        'singleColumnMusicWatchNextResultsRenderer': {
          'tabbedRenderer': {
            'watchNextTabbedResultsRenderer': {
              'tabs': [
                {
                  'tabRenderer': {
                    'content': {
                      'musicQueueRenderer': {
                        'content': {
                          'playlistPanelRenderer': {'contents': items}
                        }
                      }
                    }
                  }
                }
              ]
            }
          }
        }
      }
    };

void main() {
  test('search follows the continuation token to later pages', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      final body = json.decode(request.body) as Map<String, dynamic>;
      if (body.containsKey('continuation')) {
        return jsonResponse(
            continuationPage([row('Second page', 'Artist', 'b')]));
      }
      return jsonResponse(
          tabbed([row('First page', 'Artist', 'a')], continuation: 'TOKEN'));
    });

    final songs = await YouTubeMusicSearch(client: client)
        .searchSongs('query', limit: 20);

    expect(songs.map((s) => s.title), ['First page', 'Second page']);
    expect(calls, 2, reason: 'the second page needs its own request');
  });

  test('a query with no catalogue entry still finds the upload', () async {
    final client = MockClient((request) async {
      final body = json.decode(request.body) as Map<String, dynamic>;
      if (body['params'] != null) {
        // The songs filter returns nothing.
        return jsonResponse(tabbed([]));
      }
      return jsonResponse(tabbed([row('Upload', 'Artist', 'u')]));
    });

    final songs = await YouTubeMusicSearch(client: client)
        .searchSongs('query', limit: 20);

    expect(songs.single.title, 'Upload');
  });

  test('the length is read from the fixed column', () async {
    final client = MockClient((request) async =>
        jsonResponse(tabbed([rowWithFixedLength('Song', '3:45')])));

    final songs = await YouTubeMusicSearch(client: client)
        .searchSongs('query', limit: 20);

    expect(songs.single.duration, const Duration(minutes: 3, seconds: 45));
  });

  test('the length is read from the plural fixedColumns list', () async {
    final client = MockClient((request) async =>
        jsonResponse(tabbed([rowWithFixedColumnsLength('Song', '4:05')])));

    final songs = await YouTubeMusicSearch(client: client)
        .searchSongs('query', limit: 20);

    expect(songs.single.duration, const Duration(minutes: 4, seconds: 5));
  });

  test('a continuation nested under continuationContents is parsed', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      final body = json.decode(request.body) as Map<String, dynamic>;
      if (body.containsKey('continuation')) {
        return jsonResponse(
            shelfContinuationPage([row('Second page', 'Artist', 'b')]));
      }
      return jsonResponse(
          tabbed([row('First page', 'Artist', 'a')], continuation: 'TOKEN'));
    });

    final songs = await YouTubeMusicSearch(client: client)
        .searchSongs('query', limit: 20);

    expect(songs.map((s) => s.title), ['First page', 'Second page']);
    expect(calls, 2);
  });

  test('a throttled request is retried instead of failing the search',
      () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (calls == 1) return http.Response('rate limited', 429);
      return jsonResponse(tabbed([row('Song', 'Artist', 'a')]));
    });

    final songs = await YouTubeMusicSearch(client: client)
        .searchSongs('query', limit: 20);

    expect(songs.single.title, 'Song');
    expect(calls, 2);
  });

  test('radio reads the up-next panel in YouTube order', () async {
    late Uri url;
    late Map<String, dynamic> body;
    final client = MockClient((request) async {
      url = request.url;
      body = json.decode(request.body) as Map<String, dynamic>;
      return jsonResponse(radioPage([
        radioItem('First', 'Artist One', 'a', length: '3:45'),
        radioItem('Second', 'Artist Two', 'b'),
      ]));
    });

    final songs = await YouTubeMusicSearch(client: client).radio('seed');

    expect(url.path, endsWith('/youtubei/v1/next'));
    expect(body['videoId'], 'seed');
    expect(body['playlistId'], 'RDAMVMseed');
    expect(songs.map((s) => s.title), ['First', 'Second']);
    expect(songs.first.artist, 'Artist One');
    expect(songs.first.duration, const Duration(minutes: 3, seconds: 45));
    expect(songs.first.thumbnailUrl, contains('hq.jpg'));
  });
}
