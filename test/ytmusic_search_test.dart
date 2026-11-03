import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:atlas_music/models/song.dart';
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

/// A Videos-filter row: the id and YouTube's classification sit in the
/// thumbnail overlay's play endpoint, as in the live response.
Map<String, dynamic> videoRow(
    String title, String artist, String videoId, String type) {
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
                {'text': '4M views'},
              ]
            }
          }
        },
      ],
      'overlay': {
        'musicItemThumbnailOverlayRenderer': {
          'content': {
            'musicPlayButtonRenderer': {
              'playNavigationEndpoint': {
                'watchEndpoint': {
                  'videoId': videoId,
                  'watchEndpointMusicSupportedConfigs': {
                    'watchEndpointMusicConfig': {'musicVideoType': type}
                  }
                }
              }
            }
          }
        }
      },
    }
  };
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

  test('searchVideos sends the videos filter and keeps each row type',
      () async {
    late Map<String, dynamic> body;
    final client = MockClient((request) async {
      body = json.decode(request.body) as Map<String, dynamic>;
      return jsonResponse(tabbed([
        videoRow('Blinding Lights (Official Video)', 'The Weeknd', 'omv',
            'MUSIC_VIDEO_TYPE_OMV'),
        videoRow('Blinding Lights (Bass Boosted)', 'Van Royals', 'ugc',
            'MUSIC_VIDEO_TYPE_UGC'),
        // No overlay block: YouTube left the row unclassified. It must be
        // kept (lowest rank) rather than disabling the whole fallback.
        row('Blinding Lights', 'The Weeknd', 'untyped'),
      ]));
    });

    final videos =
        await YouTubeMusicSearch(client: client).searchVideos('Blinding');

    expect(body['params'], 'EgWKAQIQAWoMEA4QChADEAQQCRAF');
    expect(videos.map((v) => v.videoId), ['omv', 'ugc', 'untyped']);
    expect(videos.map((v) => v.musicVideoType),
        ['MUSIC_VIDEO_TYPE_OMV', 'MUSIC_VIDEO_TYPE_UGC', '']);
    expect(videos.first.artist, 'The Weeknd');
  });

  group('bestMusicVideo', () {
    VideoCandidate c(String id, String type, String title,
            [String artist = '']) =>
        VideoCandidate(
            videoId: id, musicVideoType: type, title: title, artist: artist);

    test('an official video beats a better-titled upload', () {
      expect(
        YouTubeMusicSearch.bestMusicVideo(
          [
            c('ugc', 'MUSIC_VIDEO_TYPE_UGC', 'Blinding Lights', 'The Weeknd'),
            c('omv', 'MUSIC_VIDEO_TYPE_OMV', 'Blinding Lights (Official Video)',
                'The Weeknd'),
          ],
          title: 'Blinding Lights',
          artist: 'The Weeknd',
          excludeId: 'atv',
        ),
        'omv',
      );
    });

    test('the artist name breaks the OMV tie', () {
      expect(
        YouTubeMusicSearch.bestMusicVideo(
          [
            c('cover', 'MUSIC_VIDEO_TYPE_OMV', 'Kesariya (Cover)', 'Raag Band'),
            c('real', 'MUSIC_VIDEO_TYPE_OMV', 'Kesariya', 'Arijit Singh'),
          ],
          title: 'Kesariya (From "Brahmastra")',
          artist: 'Arijit Singh',
          excludeId: 'atv',
        ),
        'real',
      );
    });

    test('the art track itself and videos of other songs are skipped', () {
      expect(
        YouTubeMusicSearch.bestMusicVideo(
          [
            c('atv', 'MUSIC_VIDEO_TYPE_ATV', 'Kesariya'),
            c('other', 'MUSIC_VIDEO_TYPE_OMV', 'Perfect', 'Ed Sheeran'),
            c('cast', 'MUSIC_VIDEO_TYPE_PODCAST_EPISODE', 'Kesariya'),
          ],
          title: 'Kesariya',
          artist: 'Arijit Singh',
          excludeId: 'atv',
        ),
        isNull,
      );
    });

    test('no title match returns null instead of an unrelated video', () {
      expect(
        YouTubeMusicSearch.bestMusicVideo(
          [c('other', 'MUSIC_VIDEO_TYPE_OMV', 'Apna Bana Le', 'Arijit Singh')],
          title: 'Kesariya',
          artist: 'Arijit Singh',
          excludeId: 'atv',
        ),
        isNull,
      );
    });

    test('a non-Latin title still matches its video', () {
      expect(
        YouTubeMusicSearch.bestMusicVideo(
          [c('mv', 'MUSIC_VIDEO_TYPE_OMV', '夜に駆ける', 'YOASOBI')],
          title: '夜に駆ける',
          artist: 'YOASOBI',
          excludeId: 'atv',
        ),
        'mv',
      );
    });

    test('a fully bracketed title falls back to the original title', () {
      expect(
        YouTubeMusicSearch.bestMusicVideo(
          [c('mv', 'MUSIC_VIDEO_TYPE_OMV', '(Intro)', 'Arijit Singh')],
          title: '(Intro)',
          artist: 'Arijit Singh',
          excludeId: 'atv',
        ),
        'mv',
      );
    });

    test('an unclassified row is kept but ranks below UGC and OMV', () {
      final untyped = c('untyped', '', 'Kesariya', 'Arijit Singh');
      final ugc = c('ugc', 'MUSIC_VIDEO_TYPE_UGC', 'Kesariya', 'Arijit Singh');
      final omv = c('omv', 'MUSIC_VIDEO_TYPE_OMV', 'Kesariya', 'Arijit Singh');
      expect(
        YouTubeMusicSearch.bestMusicVideo(
          [untyped, ugc],
          title: 'Kesariya',
          artist: 'Arijit Singh',
          excludeId: 'atv',
        ),
        'ugc',
      );
      expect(
        YouTubeMusicSearch.bestMusicVideo(
          [untyped, omv],
          title: 'Kesariya',
          artist: 'Arijit Singh',
          excludeId: 'atv',
        ),
        'omv',
      );
      expect(
        YouTubeMusicSearch.bestMusicVideo(
          [untyped],
          title: 'Kesariya',
          artist: 'Arijit Singh',
          excludeId: 'atv',
        ),
        'untyped',
      );
    });

    test("the song's own id is skipped even when it arrives unclassified", () {
      expect(
        YouTubeMusicSearch.bestMusicVideo(
          [
            c('atv', '', 'Kesariya', 'Arijit Singh'),
            c('mv', 'MUSIC_VIDEO_TYPE_OMV', 'Kesariya', 'Arijit Singh'),
          ],
          title: 'Kesariya',
          artist: 'Arijit Singh',
          excludeId: 'atv',
        ),
        'mv',
      );
      // An unclassified echo of the song itself must not pass as its video.
      expect(
        YouTubeMusicSearch.bestMusicVideo(
          [c('atv', '', 'Kesariya', 'Arijit Singh')],
          title: 'Kesariya',
          artist: 'Arijit Singh',
          excludeId: 'atv',
        ),
        isNull,
      );
    });

    test('officialOnly skips a UGC upload', () {
      expect(
        YouTubeMusicSearch.bestMusicVideo(
          [
            c('lofi', 'MUSIC_VIDEO_TYPE_UGC', 'Kesariya', 'Chillouts'),
            c('mv', 'MUSIC_VIDEO_TYPE_OMV', 'Kesariya', 'Arijit Singh'),
          ],
          title: 'Kesariya',
          artist: 'Arijit Singh',
          excludeId: 'atv',
          officialOnly: true,
        ),
        'mv',
      );
      expect(
        YouTubeMusicSearch.bestMusicVideo(
          [c('lofi', 'MUSIC_VIDEO_TYPE_UGC', 'Kesariya', 'Chillouts')],
          title: 'Kesariya',
          artist: 'Arijit Singh',
          excludeId: 'atv',
          officialOnly: true,
        ),
        isNull,
      );
    });
  });

  group('isSameSong', () {
    test('a title that only contains the wanted one is another song', () {
      expect(
        YouTubeMusicSearch.isSameSong(
          candidate: 'Stay With Me (Official Video)',
          wantTitle: 'Stay',
          artist: 'The Kid LAROI',
        ),
        isFalse,
      );
    });

    test('release suffixes, artist and featured artists are allowed', () {
      expect(
        YouTubeMusicSearch.isSameSong(
          candidate: 'The Weeknd - Blinding Lights (Official Video) feat. Zara',
          wantTitle: 'Blinding Lights',
          artist: 'The Weeknd',
        ),
        isTrue,
      );
    });

    test('slowed, lofi and remix uploads are rejected', () {
      for (final suffix in [
        '(Slowed + Reverb)',
        '(Lofi Mix)',
        '(Speed Up)',
        '(Remix)',
        '(Cover)',
        '- S L O W E D',
        '- R E V E R B',
        '(Remixed by DJ X)',
        '- Bass Boosted',
        '- Female Version',
        '- Chill Mix',
        '(Synthwave)',
      ]) {
        expect(
          YouTubeMusicSearch.isSameSong(
            candidate: 'Kesariya $suffix',
            wantTitle: 'Kesariya',
            artist: 'Arijit Singh',
          ),
          isFalse,
          reason: suffix,
        );
      }
    });

    test('a song whose own title holds a variant word still matches', () {
      expect(
        YouTubeMusicSearch.isSameSong(
          candidate: 'Cover Me (Official Video)',
          wantTitle: 'Cover Me',
          artist: 'Bruce Springsteen',
        ),
        isTrue,
      );
    });

    test('another creator version is rejected, the official one is not', () {
      // Live data: the real video is "Often (NSFW) (Official Video)" by
      // TheWeekndVEVO; the wrong one was "The Weeknd - Often (Ethan Swope
      // Version)" on the fan's own channel.
      expect(
        YouTubeMusicSearch.isSameSong(
          candidate: 'Often (NSFW) (Official Video)',
          wantTitle: 'Often',
          artist: 'The Weeknd',
          channel: 'TheWeekndVEVO',
          requireArtist: true,
        ),
        isTrue,
      );
      expect(
        YouTubeMusicSearch.isSameSong(
          candidate: 'The Weeknd - Often (Ethan Swope Version)',
          wantTitle: 'Often',
          artist: 'The Weeknd',
          channel: 'Ethan Swope',
          requireArtist: true,
        ),
        isFalse,
      );
    });

    test('an upload that never names the artist is not the song video', () {
      // Seen live: a fan upload titled only "Often" was a slowed remix.
      expect(
        YouTubeMusicSearch.isSameSong(
          candidate: 'Often',
          wantTitle: 'Often',
          artist: 'The Weeknd',
          channel: 'Chill Vibes',
          requireArtist: true,
        ),
        isFalse,
      );
      expect(
        YouTubeMusicSearch.isSameSong(
          candidate: 'The Weeknd - Often (Official Video)',
          wantTitle: 'Often',
          artist: 'The Weeknd',
          channel: 'TheWeekndVEVO',
          requireArtist: true,
        ),
        isTrue,
      );
    });

    test('a remix that names the original artist is still rejected', () {
      // Seen live: YouTube classifies "Kesariya (Synthwave)" by
      // "VDJ Fly & Arijit Singh" as an official music video.
      expect(
        YouTubeMusicSearch.isSameSong(
          candidate: 'Kesariya (Synthwave)',
          wantTitle: 'Kesariya (From "Brahmastra")',
          artist: 'Arijit Singh',
          channel: 'VDJ Fly & Arijit Singh',
        ),
        isFalse,
      );
    });

    test('a release suffix on the song itself is not a version marker', () {
      expect(
        YouTubeMusicSearch.isSameSong(
          candidate: 'Kesariya (From "Brahmastra")',
          wantTitle: 'Kesariya (From "Brahmastra")',
          artist: 'Arijit Singh',
        ),
        isTrue,
      );
    });

    test('a non-Latin title matches its upload', () {
      expect(
        YouTubeMusicSearch.isSameSong(
          candidate: '夜に駆ける - YOASOBI (Official Video)',
          wantTitle: '夜に駆ける',
          artist: 'YOASOBI',
        ),
        isTrue,
      );
    });
  });

  group('bestPlainVideo', () {
    Song v(String id, String title, String channel) => Song(
          id: id,
          title: title,
          artist: channel,
          thumbnailUrl: '',
          duration: const Duration(minutes: 4),
          videoId: id,
          channel: channel,
        );

    test('prefers the artist-matched upload over a cover', () {
      expect(
        YouTubeMusicSearch.bestPlainVideo(
          [
            v('cover', 'Kesariya (Cover)', 'Raag Band'),
            v('official', 'Kesariya - Brahmastra | Arijit Singh',
                'Sony Music India'),
          ],
          title: 'Kesariya (From "Brahmastra")',
          artist: 'Arijit Singh',
          excludeId: 'atv',
        ),
        'official',
      );
    });

    test('skips Topic art tracks and the song itself', () {
      expect(
        YouTubeMusicSearch.bestPlainVideo(
          [
            v('atv', 'Kesariya', 'Arijit Singh - Topic'),
            v('self', 'Kesariya', 'Arijit Singh'),
            v('mv', 'Kesariya', 'Sony Music India'),
          ],
          title: 'Kesariya',
          artist: 'Arijit Singh',
          excludeId: 'self',
        ),
        'mv',
      );
    });

    test('no title match returns null', () {
      expect(
        YouTubeMusicSearch.bestPlainVideo(
          [v('other', 'Apna Bana Le', 'Sony Music India')],
          title: 'Kesariya',
          artist: 'Arijit Singh',
          excludeId: 'atv',
        ),
        isNull,
      );
    });
  });
}
