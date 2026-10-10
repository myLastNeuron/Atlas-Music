import 'package:flutter_test/flutter_test.dart';
import 'package:atlas_music/services/ytmusic_search.dart';

/// One `musicResponsiveListItemRenderer` row, shaped like the live response.
Map<String, dynamic> songRow({
  required String videoId,
  required String title,
  required String artist,
  String artistId = '',
  String duration = '4:18',
}) =>
    {
      'musicResponsiveListItemRenderer': {
        'flexColumns': [
          {
            'musicResponsiveListItemFlexColumnRenderer': {
              'text': {
                'runs': [
                  {
                    'text': title,
                    'navigationEndpoint': {
                      'watchEndpoint': {'videoId': videoId},
                    },
                  },
                ],
              },
            },
          },
          {
            'musicResponsiveListItemFlexColumnRenderer': {
              'text': {
                'runs': [
                  {
                    'text': artist,
                    if (artistId.isNotEmpty)
                      'navigationEndpoint': {
                        'browseEndpoint': {'browseId': artistId},
                      },
                  },
                  {'text': ' • '},
                  {'text': 'Album'},
                  {'text': ' • '},
                  {'text': duration},
                ],
              },
            },
          },
        ],
        'thumbnail': {
          'musicThumbnailRenderer': {
            'thumbnail': {
              'thumbnails': [
                {
                  'url': 'https://lh3.googleusercontent.com/cov=w60',
                  'width': 60,
                  'height': 60,
                },
              ],
            },
          },
        },
      },
    };

Map<String, dynamic> twoRow({
  required String title,
  required String year,
  required String browseId,
}) =>
    {
      'musicTwoRowItemRenderer': {
        'title': {
          'runs': [
            {'text': title},
          ],
        },
        'subtitle': {
          'runs': [
            {'text': year},
            {'text': ' • '},
            {'text': 'Album'},
          ],
        },
        'thumbnailRenderer': {
          'musicThumbnailRenderer': {
            'thumbnail': {
              'thumbnails': [
                {
                  'url': 'https://lh3.googleusercontent.com/alb=w120',
                  'width': 120,
                  'height': 120,
                },
              ],
            },
          },
        },
        'navigationEndpoint': {
          'browseEndpoint': {'browseId': browseId},
        },
      },
    };

Map<String, dynamic> artistFixture() => {
      'header': {
        'musicImmersiveHeaderRenderer': {
          'title': {
            'runs': [
              {'text': 'Oasis'},
            ],
          },
          'thumbnail': {
            'musicThumbnailRenderer': {
              'thumbnail': {
                'thumbnails': [
                  {
                    'url': 'https://lh3.googleusercontent.com/art=w60',
                    'width': 60,
                    'height': 60,
                  },
                ],
              },
            },
          },
        },
      },
      'contents': {
        'singleColumnBrowseResultsRenderer': {
          'tabs': [
            {
              'tabRenderer': {
                'content': {
                  'sectionListRenderer': {
                    'contents': [
                      {
                        'musicShelfRenderer': {
                          'contents': [
                            songRow(
                              videoId: 'vid1',
                              title: 'Wonderwall',
                              artist: 'Oasis',
                              artistId: 'UC_oasis',
                            ),
                          ],
                        },
                      },
                      {
                        'musicCarouselShelfRenderer': {
                          'header': {
                            'musicCarouselShelfBasicHeaderRenderer': {
                              'title': {
                                'runs': [
                                  {'text': 'Albums'},
                                ],
                              },
                            },
                          },
                          'contents': [
                            twoRow(
                              title: "What's The Story",
                              year: '1995',
                              browseId: 'MPREb_album1',
                            ),
                          ],
                        },
                      },
                      // Must be ignored: only album/single carousels count.
                      {
                        'musicCarouselShelfRenderer': {
                          'header': {
                            'musicCarouselShelfBasicHeaderRenderer': {
                              'title': {
                                'runs': [
                                  {'text': 'Related artists'},
                                ],
                              },
                            },
                          },
                          'contents': [
                            twoRow(
                              title: 'The Verve',
                              year: '1997',
                              browseId: 'UC_verve',
                            ),
                          ],
                        },
                      },
                    ],
                  },
                },
              },
            },
          ],
        },
      },
    };

Map<String, dynamic> albumFixture() => {
      'contents': {
        'twoColumnBrowseResultsRenderer': {
          'secondaryContents': {
            'sectionListRenderer': {
              'contents': [
                {
                  'musicShelfRenderer': {
                    'contents': [
                      songRow(
                        videoId: 't1',
                        title: 'Hello',
                        artist: 'Adele',
                        artistId: 'UC_adele',
                        duration: '4:55',
                      ),
                      songRow(
                        videoId: 't2',
                        title: 'Easy On Me',
                        artist: 'Adele',
                        artistId: 'UC_adele',
                        duration: '3:44',
                      ),
                    ],
                  },
                },
              ],
            },
          },
        },
      },
    };

Map<String, dynamic> searchFixture() => {
      'contents': {
        'sectionListRenderer': {
          'contents': [
            {
              'musicShelfRenderer': {
                'contents': [
                  songRow(
                    videoId: 'a1',
                    title: 'Wonderwall',
                    artist: 'Oasis',
                    artistId: 'UC_oasis',
                  ),
                  songRow(
                    videoId: 'a2',
                    title: 'Champagne Supernova',
                    artist: 'Oasis',
                    artistId: 'UC_oasis',
                  ),
                  songRow(
                    videoId: 'a3',
                    title: 'Cover',
                    artist: 'Some Cover Band',
                    artistId: 'UC_cover',
                  ),
                ],
              },
            },
          ],
        },
      },
    };

void main() {
  test('parseArtistJson reads header, songs and album carousels', () {
    final page = YouTubeMusicSearch.parseArtistJson(artistFixture());
    expect(page.name, 'Oasis');
    expect(page.imageUrl, contains('w1080'));
    expect(page.songs.length, 1);
    expect(page.songs.first.title, 'Wonderwall');
    expect(page.songs.first.videoId, 'vid1');
    expect(page.songs.first.artist, 'Oasis');
    expect(page.songs.first.duration, const Duration(minutes: 4, seconds: 18));
    // "Related artists" carousel is skipped.
    expect(page.albums.length, 1);
    expect(page.albums.first.title, "What's The Story");
    expect(page.albums.first.year, '1995');
    expect(page.albums.first.browseId, 'MPREb_album1');
    expect(page.albums.first.thumbnailUrl, contains('w1080'));
  });

  test('parseArtistJson finds the "Songs" shelf full-list browse id', () {
    Map<String, dynamic> withSongsTitle(String browseId,
            [String title = 'Songs']) => {
          'contents': {
            'sectionListRenderer': {
              'contents': [
                {
                  'musicShelfRenderer': {
                    'title': {
                      'runs': [
                        {
                          'text': title,
                          'navigationEndpoint': {
                            'browseEndpoint': {'browseId': browseId},
                          },
                        },
                      ],
                    },
                    'contents': [
                      songRow(videoId: 'v1', title: 'Wonderwall', artist: 'Oasis'),
                    ],
                  },
                },
              ],
            },
          },
        };
    expect(YouTubeMusicSearch.parseArtistJson(withSongsTitle('VLOLAK5uy_songs'))
        .songsBrowseId, 'VLOLAK5uy_songs');
    expect(
        YouTubeMusicSearch.parseArtistJson(
                withSongsTitle('VLOLAK5uy_top', 'Top songs'))
            .songsBrowseId,
        'VLOLAK5uy_top');
    expect(YouTubeMusicSearch.parseArtistJson(artistFixture()).songsBrowseId,
        isNull);
  });

  test('parseAlbumJson reads the track shelf', () {
    final songs = YouTubeMusicSearch.parseAlbumJson(albumFixture());
    expect(songs.map((s) => s.title), ['Hello', 'Easy On Me']);
    expect(songs.first.duration, const Duration(minutes: 4, seconds: 55));
  });

  test('parseArtistJson never throws on hostile data', () {
    expect(() => YouTubeMusicSearch.parseArtistJson(const {}),
        returnsNormally);
    expect(() => YouTubeMusicSearch.parseAlbumJson(const {}),
        returnsNormally);
  });

  group('artistIdFromJson', () {
    test('exact artist-name match wins', () {
      expect(YouTubeMusicSearch.artistIdFromJson(searchFixture(), 'Oasis'),
          'UC_oasis');
      expect(
          YouTubeMusicSearch.artistIdFromJson(searchFixture(), 'Some Cover Band'),
          'UC_cover');
    });

    test('falls back to the most frequent browseId', () {
      expect(YouTubeMusicSearch.artistIdFromJson(searchFixture(), 'Nobody'),
          'UC_oasis');
    });

    test('returns null when no result carries a browse endpoint', () {
      expect(
          YouTubeMusicSearch.artistIdFromJson({
            'contents': {
              'sectionListRenderer': {
                'contents': [
                  {
                    'musicShelfRenderer': {
                      'contents': [
                        songRow(videoId: 'x', title: 'No Artist', artist: ''),
                      ],
                    },
                  },
                ],
              },
            },
          }, 'Anything'),
          isNull);
    });
  });
}
