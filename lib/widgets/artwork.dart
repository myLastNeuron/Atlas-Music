import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../services/video_handoff.dart';
import '../theme/app_theme.dart';

/// Single cached artwork path. Memory + disk cache, bounded decode size,
/// no re-fetch on every 1/sec position tick. Gapless so song changes
/// don't flash. Square by default ([size]); pass [width]+[height] for
/// fixed-ratio boxes (rails, headers).
///
/// When [filePath] points at a downloaded high-resolution cover (the same
/// file the media notification uses), it is preferred over the network
/// [url] so large renderings — notably the full-screen player — stay sharp.
class Artwork extends StatelessWidget {
  final String url;
  final String? filePath;
  final double? size;
  final double? width;
  final double radius;
  final double? height;
  final BoxFit fit;
  final bool fillWidth;

  const Artwork(
    this.url, {
    super.key,
    this.filePath,
    this.size,
    this.width,
    this.radius = 12,
    this.height,
    this.fit = BoxFit.cover,
    this.fillWidth = false,
  });

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final computedSize = size ?? (mq.size.width * 0.4).clamp(100, 300);
    final w = width ?? computedSize;
    final h = height ?? (width ?? computedSize);
    final px = ((width ?? computedSize) * mq.devicePixelRatio).round();
    // Prefer a downloaded high-res cover (the notification's file) when
    // present; it is validated at 480px+ so large renderings stay sharp.
    final local = filePath;
    if (local != null && local.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          width: fillWidth ? double.infinity : w,
          height: h,
          color: AppColors.mist,
          child: Image.file(
            File(local),
            width: fillWidth ? null : w,
            height: fillWidth ? null : h,
            fit: fit,
            cacheWidth: px.clamp(96, 1024),
            // A corrupt/missing cover file falls back to the network thumbnail
            // it already has, not a blank note for the rest of the session.
            errorBuilder: (_, __, ___) => url.isEmpty
                ? _fallback(w, h)
                : _networkImage(url, px, w, h,
                    placeholder: () => const SizedBox.shrink(),
                    fallbackWidth: w),
          ),
        ),
      );
    }
    if (url.isEmpty) return _fallback(w, h);
    // Single decode per art over the mist fill. A prior double stack fetched
    // and decoded the same URL twice per large card.
    if (!fillWidth && w >= 70) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          width: w,
          height: h,
          color: AppColors.mist,
          child: _networkImage(url, px, w, h,
              placeholder: () => const SizedBox.shrink(), fallbackWidth: w),
        ),
      );
    }
    final imgW = fillWidth ? null : w;
    final imgH = fillWidth ? null : h;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: fillWidth ? double.infinity : w,
        height: h,
        child: _networkImage(url, px, imgW, imgH,
            placeholder: () => Container(
                  width: imgW,
                  height: h,
                  color: AppColors.mist,
                ),
            fallbackWidth: imgW ?? computedSize),
      ),
    );
  }

  Widget _networkImage(
    String url,
    int px,
    double? w,
    double? h, {
    required Widget Function() placeholder,
    required double fallbackWidth,
  }) {
    return CachedNetworkImage(
      imageUrl: url,
      // One disk entry per artwork, not per decode size: a size-tagged key made
      // every new rendering (the full player's cover) download the same image
      // again, so the cover flight had nothing to land on.
      cacheKey: url,
      width: w,
      height: h,
      fit: fit,
      memCacheWidth: px.clamp(96, 1024),
      fadeInDuration: const Duration(milliseconds: 150),
      fadeOutDuration: const Duration(milliseconds: 120),
      useOldImageOnUrlChange: true,
      placeholder: (_, __) => placeholder(),
      errorWidget: (_, __, ___) => _fallback(fallbackWidth, h ?? fallbackWidth),
    );
  }

  Widget _fallback(double w, double h) => Container(
        width: w,
        height: h,
        color: AppColors.mist,
        child: Icon(Icons.music_note, color: AppColors.mute),
      );
}

/// Artwork size the mini player renders at.
const double kMiniArtworkSize = 42;

/// Logical size of the full player cover on this device. Shared by
/// PlayerScreen and the hero flight landing on it so both decode one bitmap.
double coverLogicalSize(BuildContext context) =>
    (MediaQuery.sizeOf(context).width - 48).clamp(160.0, 512.0);

/// The bitmap behind the full player's cover.
///
/// One provider for the player's [Artwork], the cover flight and the mini
/// player's pre-cache, so a flight that starts on a decoded image stays crisp:
/// scaling the 42 px thumb up to the flight rect painted a blurred ghost of the
/// artwork for the first half of the morph.
ImageProvider playerCoverProvider(
  BuildContext context,
  String url, {
  String? filePath,
}) {
  final px =
      (coverLogicalSize(context) * MediaQuery.devicePixelRatioOf(context))
          .round()
          .clamp(96, 1024);
  final local = filePath;
  if (local != null && local.isNotEmpty) {
    return ResizeImage.resizeIfNeeded(px, null, FileImage(File(local)));
  }
  return ResizeImage.resizeIfNeeded(
      px, null, CachedNetworkImageProvider(url, cacheKey: url));
}

/// Hero rect tween for the full-player cover. Heroes are animated by the raw
/// route animation, skipping the curve [buildPlayerTransition] applies, so
/// the rect is curved here with the same constant. Without it the cover
/// travels linearly while its page eases and visibly lags behind.
class PlayerRectTween extends MaterialRectArcTween {
  PlayerRectTween({super.begin, super.end});

  @override
  Rect lerp(double t) => super.lerp(AppMotion.player.transform(t));
}

/// Full-bleed cover for a Hero flight between the mini player and the full
/// player. It fills whatever rect the flight animates, so the thumb can morph
/// into the large cover without [Artwork]'s fixed-size layout clipping or
/// overflowing.
///
/// One image, always the player's cover bitmap. The square is an opaque card
/// from the first frame, so nothing of the page behind it can show through and
/// nothing is scaled up from the thumb. The corner radius rides the flight too,
/// instead of snapping 10 → 20 on landing.
class CoverFlightShuttle extends StatelessWidget {
  final String url;
  final String? filePath;
  final Animation<double> animation;

  /// The song whose video may be the thing that should fly. When Video mode has
  /// a live video for it, the flight carries the running video instead of the
  /// cover, and it keeps running through the flight.
  final String? songId;

  /// Radius at the thumb end and the full player end of the flight.
  final double beginRadius;
  final double endRadius;

  const CoverFlightShuttle(
    this.url, {
    super.key,
    this.filePath,
    this.songId,
    required this.animation,
    this.beginRadius = 10,
    this.endRadius = 22,
  });

  /// The player's cover at flight resolution, over the shuttle's own card.
  ///
  /// A plain [Image] on purpose: the cached-image widget dissolves its frame
  /// over a placeholder, which paints the artwork at partial opacity while the
  /// flight is mid-air.
  Widget? _cover(BuildContext context) {
    if (url.isEmpty && (filePath == null || filePath!.isEmpty)) return null;
    const card = SizedBox.expand();
    return Image(
      image: playerCoverProvider(context, url, filePath: filePath),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      frameBuilder: (_, child, frame, ___) => frame == null ? card : child,
      errorBuilder: (_, __, ___) => card,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) => ClipRRect(
        borderRadius: BorderRadius.circular(beginRadius +
            (endRadius - beginRadius) *
                AppMotion.player.transform(animation.value)),
        child: child,
      ),
      // Listens, so a video that is dropped mid-flight (the audio took over)
      // falls back to the cover instead of drawing a disposed controller.
      child: ListenableBuilder(
        listenable: videoHandoff,
        builder: (context, _) {
          final video =
              videoHandoff.isLiveFor(songId) ? videoHandoff.controller : null;
          if (video != null) return VideoFrame(controller: video);
          // Loading mid-flight (or the player closed before the first frame):
          // carry the spinner, not a still cover that the landing page is not
          // showing any more.
          if (videoHandoff.isLoadingFor(songId)) {
            return const VideoLoadingFrame();
          }
          // Opaque card under the cover: the flight is never see-through.
          return ColoredBox(
            color: AppColors.mist,
            child: _cover(context) ?? const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

/// The black square shown while a video is being resolved/initialized, with
/// the same spinner the full player uses. Shared by the full player, the mini
/// square and the cover flight so a load that spans the transition looks like
/// one continuous surface.
class VideoLoadingFrame extends StatelessWidget {
  final String message;

  const VideoLoadingFrame({super.key, this.message = ''});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            if (message.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 12.5),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The video's frames filling whatever box it is given, letterboxed on black.
/// Two places can render the same controller at once (mini player and full
/// player): this is a view, never an owner.
class VideoFrame extends StatelessWidget {
  final VideoPlayerController controller;

  const VideoFrame({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: controller,
          builder: (context, value, child) => AspectRatio(
            // Letterbox: never crop or stretch the frame.
            aspectRatio: value.size.isEmpty
                ? 16 / 9
                : value.size.width / value.size.height,
            child: child,
          ),
          child: VideoPlayer(controller),
        ),
      ),
    );
  }
}
