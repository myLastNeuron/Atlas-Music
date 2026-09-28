import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'services/atlas_audio_handler.dart';
import 'services/audio_service.dart';
import 'services/youtube_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Foreground-service setup: keeps audio alive in background / screen-off.
  // The notification is driven by [AtlasAudioHandler], which bridges to the
  // app's own queue so previous/next walk the real queue rather than a single
  // loaded AudioSource.
  // androidStopForegroundOnPause MUST stay false: when true the service drops
  // out of the foreground on any paused/transition state, letting the OS kill
  // the process and remove the media notification, and SystemUI then shows its
  // "No media playing" placeholder even while audio is audible. The
  // notification is still removed on a real stop (playback state goes idle).
  final audioHandler = AtlasAudioHandler();
  await AudioService.init(
    builder: () => audioHandler,
    config: AudioServiceConfig(
      androidNotificationChannelId:
          'com.atlas.music.atlas_music.channel.audio',
      androidNotificationChannelName: 'Audio playback',
      androidNotificationChannelDescription:
          'Media playback controls and info',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: false,
      androidNotificationIcon: 'drawable/ic_stat_music',
      androidShowNotificationBadge: false,
    ),
  );
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Color(0xFF0E0E12),
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AudioPlayerService()),
        Provider(create: (_) => YouTubeService()),
      ],
      child: const AtlasMusicApp(),
    ),
  );
}
